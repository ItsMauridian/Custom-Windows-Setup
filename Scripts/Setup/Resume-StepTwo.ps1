# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability11 2026-07-10 - persistent DDU resume wrapper
$ErrorActionPreference = 'Stop'
$workRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
$logPath = Join-Path $workRoot 'Resume-StepTwo.log'
$stepTwoPath = Join-Path $workRoot 'StepTwo.ps1'
$rawStepTwoUrl = 'https://raw.githubusercontent.com/ItsMauridian/Custom-Windows-Setup/refs/heads/main/Scripts/Setup/StepTwo.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

New-Item -Path $workRoot -ItemType Directory -Force | Out-Null

function Write-CwsResumeLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[$(Get-Date -Format o)] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host $Message
}

function Remove-CwsResumeHandoff {
    $taskName = 'ItsMauridian-Custom-Windows-Setup-StepTwo'
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!ItsMauridian-StepTwo' -ErrorAction SilentlyContinue } catch { }
    try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ItsMauridian-StepTwoResume' -ErrorAction SilentlyContinue } catch { }
}

function Ensure-CwsRegistryFallbacks {
    $resumeCommand = "`"$powerShellPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$PSCommandPath`""
    try {
        $runPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        New-Item -Path $runPath -Force | Out-Null
        New-ItemProperty -Path $runPath -Name 'ItsMauridian-StepTwoResume' -PropertyType String -Value $resumeCommand -Force | Out-Null
    } catch {
        Write-CwsResumeLog ("Could not refresh the persistent resume fallback: {0}" -f $_.Exception.Message)
    }
}

function Ensure-CwsRetryTask {
    $taskName = 'ItsMauridian-Custom-Windows-Setup-StepTwo'
    try {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            $correctAction = $existingTask.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*$PSCommandPath*" }
            if ($correctAction) { return }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-CwsResumeLog 'Replaced a stale StepTwo scheduled task from an older build.'
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principalUser = $identity.User.Value
        $actionArguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$PSCommandPath`""
        $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 20)
        $principal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Description 'Resume Custom Windows Setup StepTwo after DDU' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-CwsResumeLog 'Created a retry task for the next sign-in.'
    } catch {
        Write-CwsResumeLog "Could not create the retry task: $($_.Exception.Message)"
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-CwsResumeLog 'Resume wrapper was not elevated. Requesting Administrator approval.'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$PSCommandPath`""
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs
    exit 0
}

$completedMarker = Join-Path $workRoot 'StepTwo.completed'
if (Test-Path -LiteralPath $completedMarker) {
    Remove-CwsResumeHandoff
    Write-CwsResumeLog 'StepTwo was already completed. Removed stale resume entries.'
    exit 0
}

Ensure-CwsRetryTask
Ensure-CwsRegistryFallbacks

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\ItsMauridian-CWS-StepTwo', [ref]$createdNew)
if (-not $createdNew) {
    Write-CwsResumeLog 'Another StepTwo resume process is already running. This duplicate handoff is exiting.'
    $mutex.Dispose()
    exit 0
}

try {
    Write-CwsResumeLog 'StepTwo resume wrapper started.'

    # Task Scheduler can fire during a Safe Mode sign-in. Do not start StepTwo
    # until Windows has returned to normal mode. The task remains registered for
    # the next normal sign-in.
    $safeBootOption = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -Name OptionValue -ErrorAction SilentlyContinue
    $isSafeMode = [bool]$env:SAFEBOOT_OPTION -or [bool]($safeBootOption -and $safeBootOption.OptionValue)
    if ($isSafeMode) {
        Write-CwsResumeLog 'Safe Mode is still active. StepTwo will wait for the next normal Windows sign-in.'
        exit 0
    }

    Start-Sleep -Seconds 10

    if (-not (Test-Path -LiteralPath $stepTwoPath)) {
        $legacyStepTwo = Join-Path $env:SystemRoot 'Temp\StepTwo.ps1'
        if (Test-Path -LiteralPath $legacyStepTwo) {
            Copy-Item -LiteralPath $legacyStepTwo -Destination $stepTwoPath -Force
            Write-CwsResumeLog 'Recovered StepTwo from the legacy Windows Temp copy.'
        }
    }

    if (-not (Test-Path -LiteralPath $stepTwoPath)) {
        Write-CwsResumeLog 'StepTwo is missing locally. Downloading a fresh copy from GitHub.'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $downloadPath = "$stepTwoPath.download"
        Invoke-WebRequest -Uri "${rawStepTwoUrl}?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -UseBasicParsing -TimeoutSec 60 -OutFile $downloadPath
        Move-Item -LiteralPath $downloadPath -Destination $stepTwoPath -Force
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($stepTwoPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $parseText = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "StepTwo parser validation failed: $parseText"
    }

    Set-Content -Path (Join-Path $workRoot 'StepTwo.started') -Value (Get-Date -Format o) -Encoding ASCII -Force
    Write-CwsResumeLog "Starting StepTwo from $stepTwoPath"
    & $stepTwoPath
    Write-CwsResumeLog 'StepTwo returned to the resume wrapper.'
    if (Test-Path -LiteralPath $completedMarker) {
        Remove-CwsResumeHandoff
        Write-CwsResumeLog 'StepTwo completed and all resume entries were removed.'
    } else {
        Write-CwsResumeLog 'StepTwo returned without creating its completion marker. Resume entries remain enabled.'
    }
} catch {
    Write-CwsResumeLog "StepTwo resume failed: $($_.Exception.Message)"
    Write-Host ''
    Write-Host "The setup continuation did not complete. Log: $logPath" -ForegroundColor Red
    Write-Host 'The scheduled task was intentionally left in place so it can retry at the next sign-in.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close this window'
    exit 1
} finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
