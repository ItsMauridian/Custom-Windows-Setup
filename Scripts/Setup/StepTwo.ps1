# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability16 2026-07-10 - official WinGet repair, runtime fallback and safe display scaling
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "Run this from an elevated Administrator PowerShell window." -ForegroundColor Red
    Pause
    Exit 1
}
# StepTwo is a best-effort configuration script. It deliberately handles optional
# Windows components itself instead of inheriting a caller-wide Stop preference.
# This is especially important in Windows PowerShell 5.1, where native stderr
# redirected with 2>&1 can become an ErrorRecord even when the native command succeeds.
$ErrorActionPreference = 'Continue'

$Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Administrator)"
$Host.UI.RawUI.BackgroundColor = "Black"
$Host.PrivateData.ProgressBackgroundColor = "Black"
$Host.PrivateData.ProgressForegroundColor = "White"
Clear-Host

# Prevent accidental mouse selection from pausing long-running console work.
# Microsoft documents that Quick Edit is disabled by keeping
# ENABLE_EXTENDED_FLAGS and clearing ENABLE_QUICK_EDIT_MODE.
function Disable-CwsQuickEditMode {
    try {
        if (-not ('CwsConsoleNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CwsConsoleNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@ -ErrorAction Stop
        }
        $inputHandle = [CwsConsoleNative]::GetStdHandle(-10)
        [uint32]$consoleMode = 0
        if ([CwsConsoleNative]::GetConsoleMode($inputHandle, [ref]$consoleMode)) {
            [uint32]$newMode = ($consoleMode -bor 0x0080) -band 0xFFFFFFBF
            [void][CwsConsoleNative]::SetConsoleMode($inputHandle, $newMode)
        }
    } catch { }
}
Disable-CwsQuickEditMode

$CwsStepTwoLog = Join-Path $env:SystemRoot "Temp\CWS-StepTwo.log"
$failedApps = @()
$verifiedApps = @()
$unverifiedApps = @()
$manualApps = @()
$selectedApps = @()
$setupNotes = @()
$setupWarnings = @()
$fatalErrors = @()
$script:skippedPowerSettings = 0
$script:powerSettingCache = @{}
$CwsWorkRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
$CwsSetupOptionsPath = Join-Path $CwsWorkRoot 'SetupOptions.json'

$CwsDefaultOptions = [pscustomobject]@{
    AggressivePrivacyPerformance = $true
    RemoveOneDrive = $true
    InstallUltimatePerformancePlan = $true
    DisableAppAutoStart = $true
    InstallRecommendedApps = $true
    InstallCommunicationApps = $true
    InstallGamingApps = $true
    InstallDeveloperTools = $true
    InstallHardwareUtilities = $true
    InstallStoreApps = $true
    InstallLegacyDotNet = $false
    InstallLegacyDeveloperPacks = $false
    EnableExperimentalTimerTweaks = $false
}
try {
    if (Test-Path -LiteralPath $CwsSetupOptionsPath) {
        $CwsSetupOptions = Get-Content -LiteralPath $CwsSetupOptionsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } else {
        $CwsSetupOptions = $CwsDefaultOptions
    }
} catch {
    $CwsSetupOptions = $CwsDefaultOptions
}
function Get-CwsOption {
    param([Parameter(Mandatory)][string]$Name, [bool]$Default = $false)
    $property = $CwsSetupOptions.PSObject.Properties[$Name]
    if ($property) { return [bool]$property.Value }
    return $Default
}

function Add-CwsNote {
    param([Parameter(Mandatory)][string]$Message)
    $script:setupNotes += $Message
    Write-Host "[NOTE] $Message" -ForegroundColor Cyan
}

function Add-CwsWarning {
    param([Parameter(Mandatory)][string]$Message)
    $script:setupWarnings += $Message
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Remove-CwsPathIfPresent {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$Recurse)
    if (Test-Path -LiteralPath $LiteralPath) {
        try {
            if ($Recurse) {
                Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
            }
        } catch {
            Add-CwsWarning ("Could not remove {0}: {1}" -f $LiteralPath, $_.Exception.Message)
        }
    }
}

function Stop-CwsProcessIfPresent {
    param([Parameter(Mandatory)][string]$Name)
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Invoke-CwsRegExe {
    param([Parameter(Mandatory)][string]$Arguments)

    try {
        $regProcess = Start-Process -FilePath "$env:SystemRoot\System32\reg.exe" `
            -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        return [int]$regProcess.ExitCode
    } catch {
        Add-CwsWarning ("reg.exe could not be started: {0}" -f $_.Exception.Message)
        return -1
    }
}

function Resolve-CwsRegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '(?i)^HKLM:\\(.+)$') {
        return [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; SubKey = $matches[1] }
    }
    if ($Path -match '(?i)^HKCU:\\(.+)$') {
        return [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; SubKey = $matches[1] }
    }
    throw "Unsupported registry path: $Path"
}

function Get-CwsRegistryView {
    if ([Environment]::Is64BitOperatingSystem) { return [Microsoft.Win32.RegistryView]::Registry64 }
    return [Microsoft.Win32.RegistryView]::Default
}

function Get-CwsRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $baseKey = $null
    $key = $null
    try {
        $resolved = Resolve-CwsRegistryPath -Path $Path
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive, (Get-CwsRegistryView))
        $key = $baseKey.OpenSubKey($resolved.SubKey, $false)
        if (-not $key) { return $null }
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Set-CwsRegistryDword {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    $baseKey = $null
    $key = $null
    try {
        $resolved = Resolve-CwsRegistryPath -Path $Path
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive, (Get-CwsRegistryView))
        $key = $baseKey.CreateSubKey($resolved.SubKey)
        if (-not $key) { throw 'The registry key could not be opened for writing.' }
        $key.SetValue($Name, [int]$Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
        $actual = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $actual -or [int]$actual -ne [int]$Value) {
            throw "Readback mismatch. Expected $Value, found $actual."
        }
        return $true
    } catch {
        Add-CwsWarning ("64-bit registry policy could not be applied: {0}\{1} ({2})" -f $Path, $Name, $_.Exception.Message)
        return $false
    } finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Set-CwsRegistryMultiString {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Value)
    $baseKey = $null
    $key = $null
    try {
        $resolved = Resolve-CwsRegistryPath -Path $Path
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive, (Get-CwsRegistryView))
        $key = $baseKey.CreateSubKey($resolved.SubKey)
        if (-not $key) { throw 'The registry key could not be opened for writing.' }
        $key.SetValue($Name, [string[]]$Value, [Microsoft.Win32.RegistryValueKind]::MultiString)
        $key.Flush()
        return $true
    } catch {
        Add-CwsWarning ("64-bit registry multi-string could not be applied: {0}\{1} ({2})" -f $Path, $Name, $_.Exception.Message)
        return $false
    } finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Remove-CwsRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $baseKey = $null
    $key = $null
    try {
        $resolved = Resolve-CwsRegistryPath -Path $Path
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive, (Get-CwsRegistryView))
        $key = $baseKey.OpenSubKey($resolved.SubKey, $true)
        if ($key) { $key.DeleteValue($Name, $false); $key.Flush() }
    } catch { }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Apply-CwsPrivacyProfile {
    param([switch]$FinalPass)

    if (-not (Get-CwsOption -Name 'AggressivePrivacyPerformance' -Default $true)) {
        return
    }

    $osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $diagnosticLevel = if ($osCaption -match 'Enterprise|Education|IoT') { 0 } else { 1 }

    $settings = @(
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Value=$diagnosticLevel },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='DoNotShowFeedbackNotifications'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='AllowRecallEnablement'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableClickToDo'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='RemoveMicrosoftCopilotApp'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot'; Value=1 },
        @{ Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableSoftLanding'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsSpotlightFeatures'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableThirdPartySuggestions'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableTailoredExperiencesWithDiagnosticData'; Value=1 },
        @{ Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableCloudOptimizedContent'; Value=1 },
        @{ Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsSpotlightFeatures'; Value=1 },
        @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name='DisableCocreator'; Value=1 },
        @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name='DisableGenerativeFill'; Value=1 },
        @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name='DisableImageCreator'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableActivityFeed'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='PublishUserActivities'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='UploadUserActivities'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='AllowCloudSearch'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='DisableWebSearch'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name='AllowNewsAndInterests'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name='LetAppsRunInBackground'; Value=2 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name='DODownloadMode'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name='StartupBoostEnabled'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name='BackgroundModeEnabled'; Value=0 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name='AllowGameDVR'; Value=0 }
    )

    foreach ($policyName in @(
        'LetAppsAccessAccountInfo','LetAppsAccessCalendar','LetAppsAccessCallHistory','LetAppsAccessContacts',
        'LetAppsAccessEmail','LetAppsAccessLocation','LetAppsAccessMessaging','LetAppsAccessMotion',
        'LetAppsAccessPhone','LetAppsAccessRadios','LetAppsAccessTasks','LetAppsAccessTrustedDevices',
        'LetAppsSyncWithDevices','LetAppsGetDiagnosticInfo'
    )) {
        $settings += @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name=$policyName; Value=2 }
    }
    foreach ($policyName in @('LetAppsAccessCamera','LetAppsAccessMicrophone','LetAppsAccessNotifications')) {
        $settings += @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name=$policyName; Value=0 }
    }

    $failedWrites = 0
    foreach ($setting in $settings) {
        if (-not (Set-CwsRegistryDword -Path $setting.Path -Name $setting.Name -Value $setting.Value)) {
            $failedWrites++
        }
    }

    $criticalChecks = @(
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Value=$diagnosticLevel },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableClickToDo'; Value=1 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name='LetAppsRunInBackground'; Value=2 },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name='DODownloadMode'; Value=0 }
    )
    $failedReadback = @()
    foreach ($check in $criticalChecks) {
        try {
            $actual = Get-CwsRegistryValue -Path $check.Path -Name $check.Name
            if ($null -eq $actual -or [int]$actual -ne [int]$check.Value) {
                $failedReadback += "$($check.Path)\$($check.Name)"
            }
        } catch {
            $failedReadback += "$($check.Path)\$($check.Name)"
        }
    }

    if ($failedWrites -gt 0 -or $failedReadback.Count -gt 0) {
        Add-CwsWarning ("Privacy policy verification failed for {0} critical entries. They will be retried at the final stage." -f $failedReadback.Count)
    } elseif ($FinalPass) {
        Add-CwsNote "Final privacy policy pass verified. Diagnostic data policy level: $diagnosticLevel."
    } else {
        Add-CwsNote "Aggressive privacy profile applied and verified. Diagnostic data policy level: $diagnosticLevel."
    }
}

function Invoke-CwsNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 120
    )
    $id = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "cws-$id.out"
    $stderrPath = Join-Path $env:TEMP "cws-$id.err"
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { Start-Process -FilePath taskkill.exe -ArgumentList @('/PID', $process.Id, '/T', '/F') -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null } catch { }
            return [pscustomobject]@{ ExitCode = 1460; Output = ''; Error = "Timed out after $TimeoutSeconds seconds"; TimedOut = $true }
        }
        $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = [string]$stdout; Error = [string]$stderr; TimedOut = $false }
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Output = ''; Error = $_.Exception.Message; TimedOut = $false }
    } finally {
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-CwsPowerSetting {
    param(
        [Parameter(Mandatory)][ValidateSet('AC','DC')][string]$Mode,
        [Parameter(Mandatory)][string]$Scheme,
        [Parameter(Mandatory)][string]$Subgroup,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$Value
    )

    try {
        if ($Value -match '^0x[0-9a-fA-F]+$') {
            $normalizedValue = [Convert]::ToUInt32($Value.Substring(2), 16).ToString()
        } elseif ($Value -match '^\d+$') {
            $normalizedValue = [Convert]::ToUInt64($Value, 10).ToString()
        } else {
            $script:skippedPowerSettings++
            return $false
        }
    } catch {
        $script:skippedPowerSettings++
        return $false
    }

    # Query the documented scheme/subgroup pair once. Hardware-specific settings
    # are skipped before a set command is attempted, avoiding noisy powercfg errors.
    if ($Subgroup -match '^[0-9a-fA-F-]{36}$' -and $Setting -match '^[0-9a-fA-F-]{36}$') {
        $cacheKey = "$Scheme|$Subgroup"
        if (-not $script:powerSettingCache.ContainsKey($cacheKey)) {
            $queryResult = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/query',$Scheme,$Subgroup) -TimeoutSeconds 30
            $script:powerSettingCache[$cacheKey] = ($queryResult.Output + "`n" + $queryResult.Error)
        }
        if ($script:powerSettingCache[$cacheKey] -notmatch [regex]::Escape($Setting)) {
            $script:skippedPowerSettings++
            return $false
        }
    }

    $command = if ($Mode -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $result = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @($command,$Scheme,$Subgroup,$Setting,$normalizedValue) -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) {
        $script:skippedPowerSettings++
        return $false
    }
    return $true
}

function Invoke-CwsProcessWithTimeout {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 180,
        [switch]$Hidden
    )

    try {
        $startParameters = @{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            PassThru = $true
            ErrorAction = 'Stop'
        }
        if ($Hidden) { $startParameters.WindowStyle = 'Hidden' }
        $process = Start-Process @startParameters
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & taskkill.exe /PID $process.Id /T /F *> $null } catch { }
            Add-CwsWarning "$FilePath timed out after $TimeoutSeconds seconds and was stopped."
            return [int]1460
        }
        return [int]$process.ExitCode
    } catch {
        Add-CwsWarning "$FilePath could not be started: $($_.Exception.Message)"
        return [int]1
    }
}

try { Start-Transcript -Path $CwsStepTwoLog -Append -ErrorAction SilentlyContinue | Out-Null } catch { }
trap {
    $message = $_.Exception.Message
    $script:fatalErrors += $message
    try { $_ | Out-String | Add-Content -Path $CwsStepTwoLog -ErrorAction SilentlyContinue } catch { }
    Write-Host "StepTwo failed. Details were written to $CwsStepTwoLog" -ForegroundColor Red
    Write-Host $message -ForegroundColor Red
    Pause
    Exit 1
}

        # SCRIPT SILENT
        $progresspreference = 'silentlycontinue'

        # SCRIPT CHECK INTERNET OVER HTTPS
        try {
        $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -UseBasicParsing -TimeoutSec 10
        } catch {
        Write-Host "Internet Connection Required`n" -ForegroundColor Red
        Pause
        Exit 1
        }

        # FUNCTION FASTER DOWNLOADS WITH OPTIONAL SHA256 VERIFICATION
        function Test-FileHashSha256 {
        param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedHash = ""
        )
        if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return $true }
        if (!(Test-Path $Path)) { return $false }
        $ActualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        return ($ActualHash -ieq $ExpectedHash)
        }

        function Get-FileFromWeb {
        param(
        [Parameter(Mandatory)][string]$URL,
        [Parameter(Mandatory)][string]$File,
        [string]$Sha256 = ""
        )
        $Response = $null
        $Reader = $null
        $Writer = $null
        try {
        $Request = [System.Net.HttpWebRequest]::Create($URL)
        $Request.UserAgent = "ItsMauridian-Custom-Windows-Setup"
        $Response = $Request.GetResponse()
        if ($Response.StatusCode -eq 401 -or $Response.StatusCode -eq 403 -or $Response.StatusCode -eq 404) { throw "401, 403 or 404 '$URL'." }
        if ($File -match '^\.\\') { $File = Join-Path (Get-Location -PSProvider 'FileSystem') ($File -Split '^\.')[1] }
        if ($File -and !(Split-Path $File)) { $File = Join-Path (Get-Location -PSProvider 'FileSystem') $File }
        if ($File) { $FileDirectory = $([System.IO.Path]::GetDirectoryName($File)); if (!(Test-Path($FileDirectory))) { [System.IO.Directory]::CreateDirectory($FileDirectory) | Out-Null } }
        [byte[]]$Buffer = New-Object byte[] 1048576
        [long]$Count = 0
        $Reader = $Response.GetResponseStream()
        $Writer = New-Object System.IO.FileStream $File, 'Create'
        do {
        $Count = $Reader.Read($Buffer, 0, $Buffer.Length)
        if ($Count -gt 0) { $Writer.Write($Buffer, 0, $Count) }
        } while ($Count -gt 0)
        }
        finally {
        if ($Writer) { $Writer.Close() }
        if ($Reader) { $Reader.Close() }
        if ($Response) { $Response.Close() }
        }
        if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        if (!(Test-FileHashSha256 -Path $File -ExpectedHash $Sha256)) {
        Remove-Item $File -Force -ErrorAction SilentlyContinue | Out-Null
        throw "SHA256 mismatch for $File"
        }
        }
        }

# FUNCTION MODERN FILE PICKER
    	function Show-ModernFilePicker {
    	param(
    	[ValidateSet('Folder', 'File')]
    	$Mode,
    	[string]$fileType
    	)
    	if ($Mode -eq 'Folder') {
    	$Title = 'Select Folder'
    	$modeOption = $false
    	$Filter = "Folders|`n"
    	}
    	else {
    	$Title = 'Select File'
    	$modeOption = $true
    	if ($fileType) {
    	$Filter = "$fileType Files (*.$fileType) | *.$fileType|All files (*.*)|*.*"
    	}
    	else {
    	$Filter = 'All Files (*.*)|*.*'
    	}
    	}
    	$AssemblyFullName = 'System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'
    	$Assembly = [System.Reflection.Assembly]::Load($AssemblyFullName)
    	$OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    	$OpenFileDialog.AddExtension = $modeOption
    	$OpenFileDialog.CheckFileExists = $modeOption
    	$OpenFileDialog.DereferenceLinks = $true
    	$OpenFileDialog.Filter = $Filter
    	$OpenFileDialog.Multiselect = $false
    	$OpenFileDialog.Title = $Title
    	$OpenFileDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    	$OpenFileDialogType = $OpenFileDialog.GetType()
    	$FileDialogInterfaceType = $Assembly.GetType('System.Windows.Forms.FileDialogNative+IFileDialog')
    	$IFileDialog = $OpenFileDialogType.GetMethod('CreateVistaDialog', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $null)
    	$null = $OpenFileDialogType.GetMethod('OnBeforeVistaDialog', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $IFileDialog)
    	if ($Mode -eq 'Folder') {
    	[uint32]$PickFoldersOption = $Assembly.GetType('System.Windows.Forms.FileDialogNative+FOS').GetField('FOS_PICKFOLDERS').GetValue($null)
    	$FolderOptions = $OpenFileDialogType.GetMethod('get_Options', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($OpenFileDialog, $null) -bor $PickFoldersOption
    	$null = $FileDialogInterfaceType.GetMethod('SetOptions', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $FolderOptions)
    	}
    	$VistaDialogEvent = [System.Activator]::CreateInstance($AssemblyFullName, 'System.Windows.Forms.FileDialog+VistaDialogEvents', $false, 0, $null, $OpenFileDialog, $null, $null).Unwrap()
    	[uint32]$AdviceCookie = 0
    	$AdvisoryParameters = @($VistaDialogEvent, $AdviceCookie)
    	$AdviseResult = $FileDialogInterfaceType.GetMethod('Advise', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $AdvisoryParameters)
    	$AdviceCookie = $AdvisoryParameters[1]
    	$Result = $FileDialogInterfaceType.GetMethod('Show', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, [System.IntPtr]::Zero)
    	$null = $FileDialogInterfaceType.GetMethod('Unadvise', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $AdviceCookie)
    	if ($Result -eq [System.Windows.Forms.DialogResult]::OK) {
    	$FileDialogInterfaceType.GetMethod('GetResult', @('NonPublic', 'Public', 'Static', 'Instance')).Invoke($IFileDialog, $null)
    	}
    	return $OpenFileDialog.FileName
    	}

        Write-Host "STORE SETTINGS`n"
        ## ms-windows-store:settings
Write-Host "Initializing Microsoft Store components. No input is required at this stage...`n" -ForegroundColor Cyan

# Initialize or repair Store registration, but never wait forever for wsreset.
$wsresetExitCode = Invoke-CwsProcessWithTimeout -FilePath 'wsreset.exe' -ArgumentList @('-i') -TimeoutSeconds 180 -Hidden
if ($wsresetExitCode -ne 0) {
    Add-CwsNote "Store initialization returned exit code $wsresetExitCode. WinGet has its own App Installer bootstrap later in the script."
}

# Verify the two package families that matter after the LTSC recovery attempt.
# Microsoft Store is useful, while Desktop App Installer is required for WinGet.
Start-Sleep -Seconds 3
$storePackage = Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $storePackage) {
    $storePackage = Get-AppxPackage -AllUsers -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue | Select-Object -First 1
}
$appInstallerPackage = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $appInstallerPackage) {
    $appInstallerPackage = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
}

if ($storePackage) {
    Add-CwsNote "Microsoft Store package detected after wsreset -i: $($storePackage.Version)."
} else {
    Add-CwsWarning 'Microsoft Store is still missing after wsreset -i. The setup will continue because App Installer and WinGet are bootstrapped separately.'
}

if ($appInstallerPackage) {
    Add-CwsNote "Desktop App Installer package detected after wsreset -i: $($appInstallerPackage.Version)."
} else {
    Add-CwsNote 'Desktop App Installer is still missing after wsreset -i. The dedicated WinGet bootstrap later in StepTwo will attempt to install it.'
}

# Leave Microsoft Store application preferences user-controlled. Private package
# settings.dat hives are intentionally not loaded or modified.
Add-CwsNote 'Microsoft Store private package settings were preserved.'

		Write-Host "WINDOWS SETTINGS`n"
Write-Host "Applying Windows privacy, shell and usability settings. This can take several minutes...`n" -ForegroundColor Cyan
		## regedit
		## control
        ## ms-settings:
        ## ms-settings:privacy
		## ms-settings:backup
		
# fix for disable windows backup
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\CDPUserSvc`" /v `"Start`" /t REG_DWORD /d `"4`" /f >nul 2>&1"

# create reg file
$regfilewindowssettings = @'
Windows Registry Editor Version 5.00

; --LEGACY CONTROL PANEL--




; EASE OF ACCESS
; leave accessibility, narrator, sticky keys, keyboard preference, and high contrast state
; under user control. Avoid forcing global accessibility/theme state here because it can
; leak into focus rendering in modern apps and produce white outline artifacts.

; CLOCK AND REGION
; disable notify me when the clock changes
[HKEY_CURRENT_USER\Control Panel\TimeDate]
"DstNotification"=dword:00000000




; APPEARANCE AND PERSONALIZATION
; open file explorer to this pc
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"LaunchTo"=dword:00000001

; hide frequent folders in quick access
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer]
"ShowFrequent"=dword:00000000

; show file name extensions
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"HideFileExt"=dword:00000000

; show hidden files
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Hidden"=dword:00000001

; num lock on startup
[HKEY_USERS\.DEFAULT\Control Panel\Keyboard]
"InitialKeyboardIndicators"="2"

[HKEY_CURRENT_USER\Control Panel\Keyboard]
"InitialKeyboardIndicators"="2"

; disable search history
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings]
"IsDeviceSearchHistoryEnabled"=dword:00000000

; disable show files from office.com
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer]
"ShowCloudFilesInQuickAccess"=dword:00000000

; disable display file size information in folder tips
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"FolderContentsInfoTip"=dword:00000000

; enable display full path in the title bar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState]
"FullPath"=dword:00000001

; disable show pop-up description for folder and desktop items
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowInfoTip"=dword:00000000

; disable show preview handlers in preview pane
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowPreviewHandlers"=dword:00000000

; disable show status bar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowStatusBar"=dword:00000000

; disable show sync provider notifications
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowSyncProviderNotifications"=dword:00000000

; disable use sharing wizard
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"SharingWizardOn"=dword:00000000

; disable show network
[HKEY_CURRENT_USER\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}]
"System.IsPinnedToNameSpaceTree"=dword:00000000




; HARDWARE AND SOUND
; disable lock
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings]
"ShowLockOption"=dword:00000000

; disable sleep
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings]
"ShowSleepOption"=dword:00000000

; sound communications do nothing
[HKEY_CURRENT_USER\Software\Microsoft\Multimedia\Audio]
"UserDuckingPreference"=dword:00000003

; disable startup sound
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation]
"DisableStartupSound"=dword:00000001

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\EditionOverrides]
"UserSetting_DisableStartupSound"=dword:00000001

; sound scheme none
[HKEY_CURRENT_USER\AppEvents\Schemes]
@=".None"

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\.Default\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\CriticalBatteryAlarm\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\DeviceFail\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\FaxBeep\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\LowBatteryAlarm\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\MailBeep\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\MessageNudge\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.IM\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.Mail\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.Proximity\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.Reminder\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\Notification.SMS\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\ProximityConnection\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\SystemExclamation\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\SystemHand\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\SystemNotification\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\.Default\WindowsUAC\.Current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\DisNumbersSound\.current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\HubOffSound\.current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\HubOnSound\.current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\HubSleepSound\.current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\MisrecoSound\.current]
@=""

[HKEY_CURRENT_USER\AppEvents\Schemes\Apps\sapisvr\PanelSound\.current]
@=""

; disable autoplay
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers]
"DisableAutoplay"=dword:00000001

; disable enhance pointer precision
[HKEY_CURRENT_USER\Control Panel\Mouse]
"MouseSpeed"="0"
"MouseThreshold1"="0"
"MouseThreshold2"="0"

; mouse pointers scheme none
[HKEY_CURRENT_USER\Control Panel\Cursors]
"AppStarting"=hex(2):00,00
"Arrow"=hex(2):00,00
"ContactVisualization"=dword:00000000
"Crosshair"=hex(2):00,00
"GestureVisualization"=dword:00000000
"Hand"=hex(2):00,00
"Help"=hex(2):00,00
"IBeam"=hex(2):00,00
"No"=hex(2):00,00
"NWPen"=hex(2):00,00
"Scheme Source"=dword:00000000
"SizeAll"=hex(2):00,00
"SizeNESW"=hex(2):00,00
"SizeNS"=hex(2):00,00
"SizeNWSE"=hex(2):00,00
"SizeWE"=hex(2):00,00
"UpArrow"=hex(2):00,00
"Wait"=hex(2):00,00
@=""

; disable device installation settings
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata]
"PreventDeviceMetadataFromNetwork"=dword:00000001




; NETWORK AND INTERNET
; disable allow other network users to control or disable the shared internet connection
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Network\SharedAccessConnection]
"EnableControl"=dword:00000000

; Windows multimedia scheduling defaults are preserved.

; SYSTEM AND SECURITY
; animation-related visual effects are applied below with SystemParametersInfo
; on Windows 10/11 to avoid bundled registry writes that also affect shadows,
; ClearType behavior, classic context-menu rendering, desktop selection visuals,
; modern app window-frame rendering, or the user-facing Animation effects toggle.

; disable animate windows when minimizing and maximizing
[HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics]
"MinAnimate"="0"

; disable animations in the taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAnimations"=dword:0

; disable enable peek
[HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM]
"EnableAeroPeek"=dword:0

; disable save taskbar thumbnail previews
[HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM]
"AlwaysHibernateThumbnails"=dword:0

; enable show thumbnails instead of icons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"IconsOnly"=dword:0

; enable show translucent selection rectangle
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ListviewAlphaSelect"=dword:1

; enable show window contents while dragging
[HKEY_CURRENT_USER\Control Panel\Desktop]
"DragFullWindows"="1"

; enable smooth edges of screen fonts
[HKEY_CURRENT_USER\Control Panel\Desktop]
"FontSmoothing"="2"

; enable use drop shadows for icon labels on the desktop
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ListviewShadow"=dword:1

; Windows scheduler defaults are preserved.

; disable remote assistance
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Remote Assistance]
"fAllowToGetHelp"=dword:00000000




; TROUBLESHOOTING
; Automatic Maintenance remains enabled so Windows can service, optimize and verify the system.



; SECURITY AND MAINTENANCE
; disable report problems
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting]
"Disabled"=dword:00000001




; --IMMERSIVE CONTROL PANEL--




; WINDOWS UPDATE
; disable delivery optimization
[HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings]
"DownloadMode"=dword:00000000




; PRIVACY
; disable find my device
[HKEY_LOCAL_MACHINE\Software\Microsoft\MdmCommon\SettingValues]
"LocationSyncEnabled"=dword:00000000

; disable show me notification in the settings app
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications]
"EnableAccountNotifications"=dword:00000000

; disable tailored experiences
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled]
"Value"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Privacy]
"TailoredExperiencesWithDiagnosticDataEnabled"=dword:00000000

; Windows app privacy access is configured after import using supported AppPrivacy policies.

; disable let websites show me locally relevant content by accessing my language list 
[HKEY_CURRENT_USER\Control Panel\International\User Profile]
"HttpAcceptLanguageOptOut"=dword:00000001

; disable let windows improve start and search results by tracking app launches  
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\EdgeUI]
"DisableMFUTracking"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\EdgeUI]
"DisableMFUTracking"=dword:00000001

; disable personal inking and typing dictionary
[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization]
"RestrictImplicitInkCollection"=dword:00000001
"RestrictImplicitTextCollection"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization\TrainedDataStore]
"HarvestContacts"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Personalization\Settings]
"AcceptedPrivacyPolicy"=dword:00000000

; enable text suggestions on physical keyboard
; enable multilingual text suggestions
[HKEY_CURRENT_USER\Software\Microsoft\Input\Settings]
"EnableHwkbTextPrediction"=dword:00000001
"MultilingualTextSuggestions"=dword:00000001

; disable sending required data
[HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\Windows\DataCollection]
"AllowTelemetry"=dword:00000000

; disable advertising id
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo]
"Enabled"=dword:00000000

; disable input telemetry
[HKEY_CURRENT_USER\Software\Microsoft\Input\TIPC]
"Enabled"=dword:00000000

; disable online speech privacy
[HKEY_CURRENT_USER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy]
"HasAccepted"=dword:00000000

; disable app launch tracking
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_TrackProgs"=dword:00000000

; feedback frequency never
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Siuf\Rules]
"NumberOfSIUFInPeriod"=dword:00000000
"PeriodInNanoSeconds"=-

; disable activity history
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System]
"EnableActivityFeed"=dword:00000000
"PublishUserActivities"=dword:00000000
"UploadUserActivities"=dword:00000000




; SEARCH
; disable search highlights
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SearchSettings]
"IsDynamicSearchBoxEnabled"=dword:00000000

; disable safe search
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings]
"SafeSearchMode"=dword:00000000

; disable cloud content search for work or school account
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SearchSettings]
"IsAADCloudSearchEnabled"=dword:00000000

; disable cloud content search for microsoft account
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SearchSettings]
"IsMSACloudSearchEnabled"=dword:00000000




; EASE OF ACCESS
; disable magnifier settings 
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\ScreenMagnifier]
"FollowCaret"=dword:00000000
"FollowNarrator"=dword:00000000
"FollowMouse"=dword:00000000
"FollowFocus"=dword:00000000

; disable narrator settings
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator]
"IntonationPause"=dword:00000000
"ReadHints"=dword:00000000
"ErrorNotificationType"=dword:00000000
"EchoChars"=dword:00000000
"EchoWords"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator\NarratorHome]
"MinimizeType"=dword:00000000
"AutoStart"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator\NoRoam]
"EchoToggleKeys"=dword:00000000

; disable use the print screen key to open screen capture
[HKEY_CURRENT_USER\Control Panel\Keyboard]
"PrintScreenKeyForSnippingEnabled"=dword:00000000




; GAMING
; disable game bar
[HKEY_CURRENT_USER\System\GameConfigStore]
"GameDVR_Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AppCaptureEnabled"=dword:00000000

; disable enable open xbox game bar using game controller
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"UseNexusForGameBarEnabled"=dword:00000000

; disable use view + menu as guide button in apps
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"GamepadNexusChordEnabled"=dword:00000000

; enable game mode
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"AutoGameModeEnabled"=dword:00000001

; other settings
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AudioEncodingBitrate"=dword:0001f400
"AudioCaptureEnabled"=dword:00000000
"CustomVideoEncodingBitrate"=dword:003d0900
"CustomVideoEncodingHeight"=dword:000002d0
"CustomVideoEncodingWidth"=dword:00000500
"HistoricalBufferLength"=dword:0000001e
"HistoricalBufferLengthUnit"=dword:00000001
"HistoricalCaptureEnabled"=dword:00000000
"HistoricalCaptureOnBatteryAllowed"=dword:00000001
"HistoricalCaptureOnWirelessDisplayAllowed"=dword:00000001
"MaximumRecordLength"=hex(b):00,D0,88,C3,10,00,00,00
"VideoEncodingBitrateMode"=dword:00000002
"VideoEncodingResolutionMode"=dword:00000002
"VideoEncodingFrameRateMode"=dword:00000000
"EchoCancellationEnabled"=dword:00000001
"CursorCaptureEnabled"=dword:00000000
"VKToggleGameBar"=dword:00000000
"VKMToggleGameBar"=dword:00000000
"VKSaveHistoricalVideo"=dword:00000000
"VKMSaveHistoricalVideo"=dword:00000000
"VKToggleRecording"=dword:00000000
"VKMToggleRecording"=dword:00000000
"VKTakeScreenshot"=dword:00000000
"VKMTakeScreenshot"=dword:00000000
"VKToggleRecordingIndicator"=dword:00000000
"VKMToggleRecordingIndicator"=dword:00000000
"VKToggleMicrophoneCapture"=dword:00000000
"VKMToggleMicrophoneCapture"=dword:00000000
"VKToggleCameraCapture"=dword:00000000
"VKMToggleCameraCapture"=dword:00000000
"VKToggleBroadcast"=dword:00000000
"VKMToggleBroadcast"=dword:00000000
"MicrophoneCaptureEnabled"=dword:00000000
"SystemAudioGain"=hex(b):10,27,00,00,00,00,00,00
"MicrophoneGain"=hex(b):10,27,00,00,00,00,00,00




; TIME & LANGUAGE 
; disable show the voice typing mic button
[HKEY_CURRENT_USER\Software\Microsoft\input\Settings]
"IsVoiceTypingKeyEnabled"=dword:00000000

; disable capitalize the first letter of each sentence
; disable play key sounds as i type
; disable add a period after i double-tap the spacebar
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"EnableAutoShiftEngage"=dword:00000000
"EnableKeyAudioFeedback"=dword:00000000
"EnableDoubleTapSpace"=dword:00000000

; disable typing insights
[HKEY_CURRENT_USER\Software\Microsoft\input\Settings]
"InsightsEnabled"=dword:00000000

; show the touch keyboard never
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"TouchKeyboardTapInvoke"=dword:00000000

; disable language bar
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\CTF\LangBar]
"ExtraIconsOnMinimized"=dword:00000000
"Label"=dword:00000000
"ShowStatus"=dword:00000003
"Transparency"=dword:000000ff

; disable language hotkey
[HKEY_CURRENT_USER\Keyboard Layout\Toggle]
"Language Hotkey"="3"
"Hotkey"="3"
"Layout Hotkey"="3"




; ACCOUNTS
; disable dynamic lock
[HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\Winlogon]
"EnableGoodbye"=dword:00000000

; disable use my sign in info after restart
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System]
"DisableAutomaticRestartSignOn"=dword:00000001


; disable windows backup
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\SettingSync]
"DisableAccessibilitySettingSync"=dword:00000002
"DisableAccessibilitySettingSyncUserOverride"=dword:00000001
"DisableAppSyncSettingSync"=dword:00000002
"DisableAppSyncSettingSyncUserOverride"=dword:00000001
"DisableApplicationSettingSync"=dword:00000002
"DisableApplicationSettingSyncUserOverride"=dword:00000001
"DisableCredentialsSettingSync"=dword:00000002
"DisableCredentialsSettingSyncUserOverride"=dword:00000001
"DisableDesktopThemeSettingSync"=dword:00000002
"DisableDesktopThemeSettingSyncUserOverride"=dword:00000001
"DisableLanguageSettingSync"=dword:00000002
"DisableLanguageSettingSyncUserOverride"=dword:00000001
"DisablePersonalizationSettingSync"=dword:00000002
"DisablePersonalizationSettingSyncUserOverride"=dword:00000001
"DisableSettingSync"=dword:00000002
"DisableSettingSyncUserOverride"=dword:00000001
"DisableStartLayoutSettingSync"=dword:00000002
"DisableStartLayoutSettingSyncUserOverride"=dword:00000001
"DisableSyncOnPaidNetwork"=dword:00000001
"DisableWebBrowserSettingSync"=dword:00000002
"DisableWebBrowserSettingSyncUserOverride"=dword:00000001
"DisableWindowsSettingSync"=dword:00000002
"DisableWindowsSettingSyncUserOverride"=dword:00000001
"EnableWindowsBackup"=dword:00000000




; APPS
; disable automatically update maps
[HKEY_LOCAL_MACHINE\SYSTEM\Maps]
"AutoUpdateEnabled"=dword:00000000

; disable archive apps
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Appx]
"AllowAutomaticAppArchiving"=dword:00000000




; PERSONALIZATION
; dark theme & transparency on
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"AppsUseLightTheme"=dword:00000000
"EnableTransparency"=dword:00000001
"SystemUsesLightTheme"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"AppsUseLightTheme"=dword:00000000



; always hide most used list in start menu
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"ShowOrHideMostUsedApps"=dword:00000002

[HKEY_CURRENT_USER\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"ShowOrHideMostUsedApps"=-

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoStartMenuMFUprogramsList"=-
"NoInstrumentation"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoStartMenuMFUprogramsList"=-
"NoInstrumentation"=-

; start menu hide recommended
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Start]
"HideRecommendedSection"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"HideRecommendedSection"=dword:00000001

; more pins personalization start
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_Layout"=dword:00000001

; disable show recently added apps
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"HideRecentlyAddedApps"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideRecentlyAddedApps"=dword:00000001

; disable show account-related notifications
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_AccountNotifications"=dword:00000000

; disable show websites from your browsing history
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_RecoPersonalizedSites"=dword:00000000

; disable show recently opened items in start, jump lists and file explorer
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_TrackDocs"=dword:00000000 

; touch keyboard never
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"TipbandDesiredVisibility"=dword:00000000

; show smaller taskbar icons never
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"IconSizePreference"=dword:00000001

; centered taskbar alignment
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAl"=dword:00000001

; disable desktop preview
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarSd"=dword:00000000

; remove chat from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarMn"=dword:00000000

; remove task view from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowTaskViewButton"=dword:00000000

; remove search from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

; remove windows widgets from taskbar
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh] 
"AllowNewsAndInterests"=dword:00000000

; remove copilot from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowCopilotButton"=dword:00000000

; remove meet now
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideSCAMeetNow"=dword:00000001

; remove news and interests
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds]
"EnableFeeds"=dword:00000000


; disable use dynamic lighting on my devices
[HKEY_CURRENT_USER\Software\Microsoft\Lighting]
"AmbientLightingEnabled"=dword:00000000

; disable compatible apps in the foreground always control lighting 
[HKEY_CURRENT_USER\Software\Microsoft\Lighting]
"ControlledByForegroundApp"=dword:00000000

; disable match my windows accent color 
[HKEY_CURRENT_USER\Software\Microsoft\Lighting]
"UseSystemAccentColor"=dword:00000000

; disable show key background
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"IsKeyBackgroundEnabled"=dword:00000000

; disable show recommendations for tips shortcuts new apps and more
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_IrisRecommendations"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"ShowRecentList"=dword:00000000

; disable share any window from my taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarSn"=dword:00000000

; disable device usage
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment]
"Intent"=dword:00000000
"Priority"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business]
"Intent"=dword:00000000
"Priority"=dword:00000000




; DEVICES
; disable usb issues notify
[HKEY_CURRENT_USER\Software\Microsoft\Shell\USB]
"NotifyOnUsbErrors"=dword:00000000

; disable let windows manage my default printer
[HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\Windows]
"LegacyDefaultPrinterMode"=dword:00000001

; disable write with your fingertip
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\EmbeddedInkControl]
"EnableInkingWithTouch"=dword:00000000




; SYSTEM

; Hardware accelerated GPU scheduling, VRR and windowed-game optimizations remain user controlled.

; preserve normal application and security notifications
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested]
"Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp]
"Enabled"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement]
"ScoobeSystemSettingEnabled"=dword:00000000

; disable suggested actions
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard]
"Disabled"=dword:00000001

; Focus Assist and Do Not Disturb remain user controlled.

; battery options optimize for video quality
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\VideoSettings]
"VideoQualityOnBattery"=dword:00000001

; disable storage sense
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\StorageSense]
"AllowStorageSenseGlobal"=dword:00000000

; disable keep windows running smoothly
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\StorageSense]

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters]

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\CachedSizes]

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy]
; disable storage sense
"04"=dword:00000000
; don't auto delete temp files
"2048"=dword:00000000
; don't auto empty recycle bin
"08"=dword:00000000
; don't auto delete downloads
"256"=dword:00000000
; never auto run storage sense
"32"=dword:00000000
; settings set
"StoragePoliciesChanged"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]
; confirm file delete dialog
"ConfirmFileDelete"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy\SpaceHistory]

; disable drag tray
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CDP]
"DragTrayEnabled"=dword:00000000

; disable snap window settings
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"SnapAssist"=dword:00000000
"DITest"=dword:00000000
"EnableSnapBar"=dword:00000000
"EnableTaskGroups"=dword:00000000
"EnableSnapAssistFlyout"=dword:00000000
"SnapFill"=dword:00000000
"JointResize"=dword:00000000

; enable endtask menu taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings]
"TaskbarEndTask"=dword:00000001

; enable long paths
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem]
"LongPathsEnabled"=dword:00000001

; alt tab open windows only
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"MultiTaskingAltTabFilter"=dword:00000003

; disable share across devices
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CDP]
"RomeSdkChannelUserAuthzPolicy"=dword:00000000
"CdpSessionUserAuthzPolicy"=dword:00000000

; disable recommended troubleshooter preferences
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsMitigation]
"UserPreference"=dword:00000001




; --OTHER--





; EDGE
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge]
"StartupBoostEnabled"=dword:00000000
"BackgroundModeEnabled"=dword:00000000




; NVIDIA
; disable nvidia tray icon
[HKEY_CURRENT_USER\Software\NVIDIA Corporation\NvTray]
"StartOnLogin"=dword:00000000




; --CAN'T DO NATIVELY--




; Start menu behavior uses supported policy and user settings only.

; set start menu apps view to list
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"AllAppsViewMode"=dword:00000002




; UWP APPS
; disable background apps
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsRunInBackground"=dword:00000002

; Windows input, emoji and IME infrastructure remains available.

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Dsh]
"IsPrelaunchEnabled"=dword:00000000

; disable web search in start menu / taskbar search
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001

; disable bing / internet results in windows search
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search]
"BingSearchEnabled"=dword:00000000

; new outlook default on, but keep the toggle/user choice available
[HKEY_CURRENT_USER\Software\Microsoft\Office\16.0\Outlook\Preferences]
"UseNewOutlook"=dword:00000001

; disable copilot & ai
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowCopilotButton"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI]
"DisableAIDataAnalysis"=dword:00000001
"AllowRecallEnablement"=dword:00000000
"DisableClickToDo"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint]
"DisableGenerativeFill"=dword:00000001
"DisableCocreator"=dword:00000001
"DisableImageCreator"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\WindowsNotepad]
"DisableAIFeatures"=dword:00000001

; disable widgets
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests]
"value"=dword:00000000

; Game DVR and Game Bar capture are disabled with supported policies and user settings.


; NVIDIA
; NVIDIA
; enable old nvidia legacy sharpening
; old location
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS]
"EnableGR535"=dword:00000000

; new location
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS]
"EnableGR535"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS]
"EnableGR535"=dword:00000000




; POWER
; disable fast boot
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power]
"HiberbootEnabled"=dword:00000000

; enable safe & safe network boot fix for new nvme driver
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\{75416E63-5912-4DFA-AE8F-3EFACCAFFB14}]
@="Storage disks"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\{75416E63-5912-4DFA-AE8F-3EFACCAFFB14}]
@="Storage disks"




; DISABLE ADVERTISING & PROMOTIONAL
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"ContentDeliveryAllowed"=dword:00000000
"FeatureManagementEnabled"=dword:00000000
"OemPreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEverEnabled"=dword:00000000
"RotatingLockScreenEnabled"=dword:00000000
"RotatingLockScreenOverlayEnabled"=dword:00000000
"SilentInstalledAppsEnabled"=dword:00000000
"SlideshowEnabled"=dword:00000000
"SoftLandingEnabled"=dword:00000000
"SubscribedContent-310093Enabled"=dword:00000000
"SubscribedContent-314563Enabled"=dword:00000000
"SubscribedContent-338388Enabled"=dword:00000000
"SubscribedContent-338389Enabled"=dword:00000000
"SubscribedContent-338393Enabled"=dword:00000000
"SubscribedContent-353694Enabled"=dword:00000000
"SubscribedContent-353696Enabled"=dword:00000000
"SubscribedContent-353698Enabled"=dword:00000000
"SubscribedContentEnabled"=dword:00000000
"SystemPaneSuggestionsEnabled"=dword:00000000




; OTHER
; remove 3d objects
[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}]

[-HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}]

; remove quick access
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"HubMode"=dword:00000001

; remove home
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}]
@="CLSID_MSGraphHomeFolder"
"HiddenByDefault"=dword:00000001
[-HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}]
[HKEY_CURRENT_USER\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}]
@="CLSID_MSGraphHomeFolder"
"System.IsPinnedToNameSpaceTree"=dword:00000000

; remove gallery
[HKEY_CURRENT_USER\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}]
@="{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
"System.IsPinnedToNameSpaceTree"=dword:00000000

; remove onedrive from sidebar
[HKEY_CURRENT_USER\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}]
"System.IsPinnedToNameSpaceTree"=dword:00000000
[HKEY_CURRENT_USER\Software\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}]
"System.IsPinnedToNameSpaceTree"=dword:00000000

; restore the classic context menu
[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""

; disable menu show delay
[HKEY_CURRENT_USER\Control Panel\Desktop]
"MenuShowDelay"="0"

; disable driver searching & updates
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching]
"SearchOrderConfig"=dword:00000000

; mouse fix (no accel with epp on)
[HKEY_CURRENT_USER\Control Panel\Mouse]
"MouseSensitivity"="10"
"SmoothMouseXCurve"=hex:\
	00,00,00,00,00,00,00,00,\
	C0,CC,0C,00,00,00,00,00,\
	80,99,19,00,00,00,00,00,\
	40,66,26,00,00,00,00,00,\
	00,33,33,00,00,00,00,00
"SmoothMouseYCurve"=hex:\
	00,00,00,00,00,00,00,00,\
	00,00,38,00,00,00,00,00,\
	00,00,70,00,00,00,00,00,\
	00,00,A8,00,00,00,00,00,\
	00,00,E0,00,00,00,00,00

[HKEY_USERS\.DEFAULT\Control Panel\Mouse]
"MouseSpeed"="0"
"MouseThreshold1"="0"
"MouseThreshold2"="0"

; disable phone companion in start menu
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"RightCompanionToggledOpen"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe]
"IsEnabled"=dword:00000000
"IsAvailable"=dword:00000000

; more info on bsod
[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl]
"DisplayParameters"=dword:00000001
"DisableEmoticon"=dword:00000001

; disable multiplane overlay (mpo) -- Win10 only by post-import OS-aware logic
; leaving the static reg payload out prevents Win11 DWM border artifacts.

; modern standby fix - disable network connectivity during s0 sleep
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power]
"EnforceDisconnectedStandby"=dword:00000001

; verbose messages during logon/logoff/startup/shutdown
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System]
"VerboseStatus"=dword:00000001

; disable windows platform binary table
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager]
"DisableWpbtExecution"=dword:00000001

; no web services in explorer
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoWebServices"=dword:00000001

; disable cross device resume
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration]
"IsResumeAllowed"=dword:00000000
"IsOneDriveResumeAllowed"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume]
"value"=dword:00000001

; hide home in settings
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"SettingsPageVisibility"="hide:home;hide:aicomponents;"

; black powershell console
[HKEY_CURRENT_USER\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe]
"ScreenColors"=dword:0000000F
'@
Set-Content -Path "$env:SystemRoot\Temp\WindowsSettings.reg" -Value $regfilewindowssettings -Force

# edit reg file
$path = "$env:SystemRoot\Temp\WindowsSettings.reg"
(Get-Content $path) -replace "\?","$" | Out-File $path

# import reg file
Write-Host "Importing the main Windows settings registry file..." -ForegroundColor Cyan
$regImportExitCode = Invoke-CwsProcessWithTimeout -FilePath 'regedit.exe' -ArgumentList @('/S', "$env:SystemRoot\Temp\WindowsSettings.reg") -TimeoutSeconds 180 -Hidden
if ($regImportExitCode -ne 0) {
    Add-CwsWarning "The main Windows settings registry import returned exit code $regImportExitCode."
} else {
    Write-Host "Main Windows settings import completed.`n" -ForegroundColor Green


Apply-CwsPrivacyProfile
}

# keep MPO disable OS-aware: OverlayTestMode=5 can help on some systems, but on
# Win11 it can also interfere with DWM/composition and show light frame borders
# on modern apps. Keep it Win10-only unless explicitly requested otherwise.
try {
    $isWin11 = [Environment]::OSVersion.Version.Build -ge 22000
    if ($isWin11) {
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
    }
    else {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -PropertyType DWord -Value 5 -Force -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# keep window-border theming OS-aware: ColorPrevalence=0 is a Win10 readability fix,
# but on Win11 it can contribute to the light DWM frame outline around modern apps.
try {
    $isWin11 = [Environment]::OSVersion.Version.Build -ge 22000
    if ($isWin11) {
        Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -ErrorAction SilentlyContinue
    }
    else {
        New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# force-apply the specific visual-effect settings we actually want via SystemParametersInfo
# instead of relying on bundled registry values that also affect unrelated UI visuals.
$CwsVisualFxTypeDefinition = @"
using System;
using System.Runtime.InteropServices;
public class WinSuxVisualFx {
    [StructLayout(LayoutKind.Sequential)]
    public struct ANIMATIONINFO {
        public uint cbSize;
        public int iMinAnimate;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, bool pvParam, uint fWinIni);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, uint pvParam, uint fWinIni);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref ANIMATIONINFO pvParam, uint fWinIni);

    private const uint SPIF_UPDATEINIFILE = 0x01;
    private const uint SPIF_SENDCHANGE = 0x02;
    private const uint SPIF_FLAGS = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE;

    public static void Apply() {
        var animationInfo = new ANIMATIONINFO();
        animationInfo.cbSize = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
        animationInfo.iMinAnimate = 0;

        // disable window minimize/maximize animation
        SystemParametersInfo(0x0049, animationInfo.cbSize, ref animationInfo, SPIF_FLAGS);
        // disable client-area animation inside windows
        SystemParametersInfo(0x1043, 0, false, SPIF_FLAGS);
        // disable menu fade/slide animation
        SystemParametersInfo(0x1003, 0, false, SPIF_FLAGS);
        // disable combo box animation (slide open)
        SystemParametersInfo(0x1005, 0, false, SPIF_FLAGS);
        // disable smooth-scroll list boxes
        SystemParametersInfo(0x1007, 0, false, SPIF_FLAGS);
        // disable selection fade
        SystemParametersInfo(0x1015, 0, false, SPIF_FLAGS);
        // disable tooltip animation
        SystemParametersInfo(0x1017, 0, false, SPIF_FLAGS);
        // disable tooltip fade
        SystemParametersInfo(0x1019, 0, false, SPIF_FLAGS);
        // keep show window contents while dragging enabled
        SystemParametersInfo(0x0025, 1, false, SPIF_FLAGS);
        // keep drop shadows under windows enabled
        SystemParametersInfo(0x1025, 0, true, SPIF_FLAGS);
        // keep font smoothing / ClearType enabled
        SystemParametersInfo(0x004B, 1, 0u, SPIF_FLAGS);
        SystemParametersInfo(0x200B, 0, 2u, SPIF_FLAGS);
        // do not force keyboard preference/focus cues on
        SystemParametersInfo(0x0046, 0, 0u, SPIF_FLAGS);
    }
}
"@
try { Add-Type -TypeDefinition $CwsVisualFxTypeDefinition -ErrorAction SilentlyContinue } catch { }
try { [WinSuxVisualFx]::Apply() } catch { }

# keep the broad UI-effects master enabled so non-animation visuals and the
# user-facing Animation effects toggle keep behaving normally. Also leave
# accessibility/high-contrast state alone; this script should not force global
# focus/keyboard cue behavior.
New-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'UIEffects' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothingType' -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null

# remove Home and Gallery from navigation pane - cover both NameSpace and NameSpace_41040327 (varies by Win11 build)
$namespaces = @(
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
)
foreach ($ns in $namespaces) {
    cmd /c "reg delete `"$ns`" /f >nul 2>&1"
}
# also set IsPinnedToNameSpaceTree=0 in HKCU for both (covers per-user override)
cmd /c "reg add `"HKCU\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}`" /v `"System.IsPinnedToNameSpaceTree`" /t REG_DWORD /d 0 /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}`" /v `"System.IsPinnedToNameSpaceTree`" /t REG_DWORD /d 0 /f >nul 2>&1"

# Preserve Windows security, networking, memory management and maintenance defaults.
# Older builds disabled these components, so this block also repairs machines that
# were previously configured by an earlier release.
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null } catch { }
Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost' -Name 'EnableWebContentEvaluation' -ErrorAction SilentlyContinue
try { Invoke-CwsRegExe -Arguments 'delete "HKCU\SOFTWARE\Microsoft\Edge\SmartScreenEnabled" /ve /f' | Out-Null } catch { }
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate' -Name 'AutoDownload' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'WHQLSettings' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -Name '735209102' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -Name 'MaintenanceDisabled' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name 'GlobalUserDisabled' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\input' -Name 'IsInputAppPreloadEnabled' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance' -Name 'Enabled' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue
if (-not (Get-CwsOption -Name 'EnableExperimentalTimerTweaks' -Default $false)) {
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name 'GlobalTimerResolutionRequests' -ErrorAction SilentlyContinue
}

# Keep hibernation available on laptops while leaving Fast Startup disabled below.
Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/hibernate','on') -TimeoutSeconds 30 | Out-Null

# Restore Microsoft security and drive-maintenance tasks that older builds disabled.
$tasksToEnable = @(
    @{ Path='\Microsoft\Windows\ExploitGuard\'; Name='ExploitGuard MDM policy Refresh' },
    @{ Path='\Microsoft\Windows\Windows Defender\'; Name='Windows Defender Cache Maintenance' },
    @{ Path='\Microsoft\Windows\Windows Defender\'; Name='Windows Defender Cleanup' },
    @{ Path='\Microsoft\Windows\Windows Defender\'; Name='Windows Defender Scheduled Scan' },
    @{ Path='\Microsoft\Windows\Windows Defender\'; Name='Windows Defender Verification' },
    @{ Path='\Microsoft\Windows\Defrag\'; Name='ScheduledDefrag' }
)
foreach ($taskInfo in $tasksToEnable) {
    $task = Get-ScheduledTask -TaskPath $taskInfo.Path -TaskName $taskInfo.Name -ErrorAction SilentlyContinue
    if ($task) { $task | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
}

# Restore core Windows network bindings. Do not force optional third-party bindings.
if ((Get-Command Get-NetAdapterBinding -ErrorAction SilentlyContinue) -and
    (Get-Command Enable-NetAdapterBinding -ErrorAction SilentlyContinue)) {
    $coreBindings = @('ms_tcpip6','ms_server','ms_msclient','ms_pacer','ms_lldp','ms_lltdio','ms_rspndr')
    foreach ($componentId in $coreBindings) {
        foreach ($binding in @(Get-NetAdapterBinding -ComponentID $componentId -ErrorAction SilentlyContinue)) {
            if (-not $binding.Enabled) {
                Enable-NetAdapterBinding -Name $binding.Name -ComponentID $componentId -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
} else {
    Add-CwsNote 'NetAdapter cmdlets are unavailable on this image. Core network binding repair was skipped.'
}
Invoke-CwsNativeCommand -FilePath netsh.exe -ArgumentList @('interface','teredo','set','state','default') -TimeoutSeconds 30 | Out-Null
foreach ($interface in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty -Path $interface.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $interface.PSPath -Name 'TCPNoDelay' -ErrorAction SilentlyContinue
}

# Restore Edge update services while retaining Startup Boost and background mode policies.
try { & sc.exe config MicrosoftEdgeElevationService start= demand 2>$null | Out-Null } catch { }
try { & sc.exe config edgeupdate start= delayed-auto 2>$null | Out-Null } catch { }
try { & sc.exe config edgeupdatem start= demand 2>$null | Out-Null } catch { }

# disable bitlocker
        ## control /name microsoft.bitlockerdriveencryption
try {
Get-BitLockerVolume |
Where-Object {
$_.ProtectionStatus -eq "On" -or $_.VolumeStatus -ne "FullyDecrypted"
} |
ForEach-Object {
Disable-BitLocker -MountPoint $_.MountPoint -ErrorAction SilentlyContinue | Out-Null
}
} catch { }

# Preserve SysMain. Windows manages its prefetching behavior and it is not telemetry.
try { Set-Service -Name 'SysMain' -StartupType Automatic -ErrorAction SilentlyContinue } catch { }
try { Start-Service -Name 'SysMain' -ErrorAction SilentlyContinue } catch { }

# disable telemetry services
Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null
Stop-Service -Name "dmwappushservice" -Force -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name "WerSvc" -StartupType Manual -ErrorAction SilentlyContinue | Out-Null

# disable powershell telemetry
[System.Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', [System.EnvironmentVariableTarget]::Machine)

# set service baseline aligned with current WinUtil, without demoting StorSvc, W32Time or SharedAccess
$manualServices = @("MapsBroker")
$disabledServices = @("CscService","DiagTrack","dmwappushservice","WSAIFabricSvc")
foreach ($svc in $manualServices) {
Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
}
foreach ($svc in $disabledServices) {
Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}

# Resume sign-in requirements and Do Not Disturb remain user controlled.
Add-CwsNote 'Sign-in-on-resume and notification-priority settings were preserved.'

# App Actions, Paint and Photos package settings are not modified through private settings.dat hives.
Add-CwsNote 'Private App Actions package-hive modifications were skipped.'

# Hardware device power behavior is controlled by the selected power plan.
Add-CwsNote 'Adapter and device power-saving driver registry defaults were preserved.'

# Notepad AI is disabled through supported policy. Private Notepad package settings are preserved.
Add-CwsNote 'Private Notepad package-hive modifications were skipped.'

# unpin all taskbar items
cmd /c "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband /f >nul 2>&1"
Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -ErrorAction SilentlyContinue | Out-Null

# desktop.ini files keep their Windows-managed attributes. Avoid a full C:\ crawl.

# disable explorer automatic folder type discovery
$bags = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags"
$bagMRU = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU"
Remove-Item -Path $bags -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path $bagMRU -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
$allFolders = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
if (!(Test-Path $allFolders)) { New-Item -Path $allFolders -Force -ErrorAction SilentlyContinue | Out-Null }
New-ItemProperty -Path $allFolders -Name "FolderType" -Value "NotSpecified" -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
	

# remove context menu items
# restore the classic context menu
cmd /c "reg add `"HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32`" /ve /t REG_SZ /d `"`" /f >nul 2>&1"

# remove customize this folder
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer`" /v `"NoCustomizeThisFolder`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# remove pin to quick access
cmd /c "reg delete `"HKCR\Folder\shell\pintohome`" /f >nul 2>&1"

# remove add to favorites
cmd /c "reg delete `"HKCR\*\shell\pintohomefile`" /f >nul 2>&1"

# remove troubleshoot compatibility
cmd /c "reg delete `"HKCR\exefile\shellex\ContextMenuHandlers\Compatibility`" /f >nul 2>&1"

# remove open in terminal
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`" /v `"{9F156763-7844-4DC4-B2B1-901F640F5155}`" /t REG_SZ /d `"`" /f >nul 2>&1"

# remove give access to
cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`" /v `"{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}`" /t REG_SZ /d `"`" /f >nul 2>&1"

# remove include in library
cmd /c "reg delete `"HKCR\Folder\ShellEx\ContextMenuHandlers\Library Location`" /f >nul 2>&1"

# remove share
cmd /c "reg delete `"HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing`" /f >nul 2>&1"

# Preserve the Previous Versions page for recovery.
cmd /c "reg delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v `"NoPreviousVersionsPage`" /f >nul 2>&1"

# remove send to
cmd /c "reg delete `"HKCR\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo`" /f >nul 2>&1"
cmd /c "reg delete `"HKCR\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo`" /f >nul 2>&1"

# Apply a small Start layout with supported, OS-aware layout files only.
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    $layoutFile = Join-Path $env:SystemRoot 'StartMenuLayout.xml'
    $windows10Layout = @'
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
    <LayoutOptions StartTileGroupCellWidth="6" />
    <DefaultLayoutOverride>
        <StartLayoutCollection>
            <defaultlayout:StartLayout GroupCellWidth="6">
                <start:Group Name="">
                    <start:DesktopApplicationTile Size="2x2" Column="0" Row="0" DesktopApplicationID="Microsoft.Windows.Explorer" />
                    <start:Tile Size="2x2" Column="2" Row="0" AppUserModelID="windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" />
                </start:Group>
            </defaultlayout:StartLayout>
        </StartLayoutCollection>
    </DefaultLayoutOverride>
</LayoutModificationTemplate>
'@
    Set-Content -LiteralPath $layoutFile -Value $windows10Layout -Encoding ASCII -Force
    foreach ($policyRoot in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer','HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer')) {
        New-Item -Path $policyRoot -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $policyRoot -Name 'LockedStartLayout' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $policyRoot -Name 'StartLayoutFile' -PropertyType String -Value $layoutFile -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    foreach ($policyRoot in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer','HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer')) {
        New-ItemProperty -Path $policyRoot -Name 'LockedStartLayout' -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-ItemProperty -Path $policyRoot -Name 'StartLayoutFile' -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $layoutFile -Force -ErrorAction SilentlyContinue
} else {
    $shellFolder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell'
    New-Item -Path $shellFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $layoutJson = @'
{
  "pinnedList": [
    { "desktopAppId": "Microsoft.Windows.Explorer" },
    { "packagedAppId": "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" }
  ]
}
'@
    Set-Content -LiteralPath (Join-Path $shellFolder 'LayoutModification.json') -Value $layoutJson -Encoding UTF8 -Force
}

# No helper shortcuts are added to the Start menu or Startup folders.

# Accessibility and Accessories entries are preserved. They do not consume resources when unused.

# set start menu apps view to list
cmd /c "reg add `"HKCU\Software\Microsoft\Windows\CurrentVersion\Start`" /v `"AllAppsViewMode`" /t REG_DWORD /d `"2`" /f >nul 2>&1"

        Write-Host "EDGE AND WEBVIEW2`n"
Write-Host "Preserving Microsoft Edge and WebView2 because both are in the desired app set and Windows components can depend on WebView2.`n" -ForegroundColor Cyan

# Remove only stale Edge shortcuts. Do not remove Edge, Edge Update, WebView2, services or registry state.
$edgeShortcutPaths = @(
    "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
    "$env:USERPROFILE\Desktop\Microsoft Edge.lnk"
)
foreach ($edgeShortcut in $edgeShortcutPaths) {
    Remove-CwsPathIfPresent -LiteralPath $edgeShortcut
}

        Write-Host "REMOVE UWP APPS`n"
        ## ms-settings:appsfeatures
        ## powershell -noexit -command "get-appxpackage | select name | format-table -autosize"
Write-Host "Removing only explicitly selected consumer AppX packages. Frameworks and protected Windows system apps are preserved.`n" -ForegroundColor Cyan

$appxRemovalPatterns = @(
    'Clipchamp.Clipchamp',
    'Microsoft.549981C3F5F10',
    'Microsoft.BingFinance',
    'Microsoft.BingFoodAndDrink',
    'Microsoft.BingHealthAndFitness',
    'Microsoft.BingNews',
    'Microsoft.BingSports',
    'Microsoft.BingTravel',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.XboxApp',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.GamingApp',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MicrosoftTeams',
    'MSTeams',
    'Microsoft.WidgetsPlatformRuntime',
    'MicrosoftWindows.Client.WebExperience',
    '*Copilot*'
)

Write-Host "Reading installed and provisioned AppX inventories once..." -ForegroundColor Cyan
$installedAppxInventory = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle -ErrorAction SilentlyContinue)
$provisionedAppxInventory = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
$appxRemovedCount = 0
$appxProvisionedRemovedCount = 0

foreach ($pattern in $appxRemovalPatterns) {
    $packages = @($installedAppxInventory | Where-Object { $_.Name -like $pattern } | Sort-Object PackageFullName -Unique)
    $provisioned = @($provisionedAppxInventory | Where-Object { $_.DisplayName -like $pattern } | Sort-Object PackageName -Unique)
    if ($packages.Count -eq 0 -and $provisioned.Count -eq 0) { continue }

    Write-Host "  AppX pattern: $pattern"
    foreach ($package in $packages) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            $appxRemovedCount++
        } catch {
            Add-CwsWarning "AppX package was kept: $($package.Name) ($($_.Exception.Message))"
        }
    }

    foreach ($package in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            $appxProvisionedRemovedCount++
        } catch {
            Add-CwsWarning "Provisioned AppX package was kept: $($package.DisplayName) ($($_.Exception.Message))"
        }
    }
}
Add-CwsNote "Removed $appxRemovedCount installed AppX package entries and $appxProvisionedRemovedCount provisioned package entries from the explicit consumer list."
Write-Host "Selected AppX cleanup finished.`n" -ForegroundColor Green

        Write-Host "REMOVE UWP FEATURES`n"
        ## ms-settings:optionalfeatures
        ## powershell -noexit -command "dism /online /get-capabilities /format:table"
Write-Host "Removing only explicitly selected optional capabilities. Permanent capabilities are not touched.`n" -ForegroundColor Cyan

$capabilityPatterns = @(
    'App.Support.QuickAssist*',
    'Browser.InternetExplorer*',
    'Microsoft.Windows.WordPad*',
    'StepsRecorder*',
    'XPS.Viewer*'
)
Write-Host "Reading installed Windows capabilities once. This can take several minutes..." -ForegroundColor Cyan
$installedCapabilities = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Installed' })
$capabilitiesRemovedCount = 0
foreach ($pattern in $capabilityPatterns) {
    $capabilities = @($installedCapabilities | Where-Object { $_.Name -like $pattern })
    foreach ($capability in $capabilities) {
        Write-Host "  Capability: $($capability.Name)"
        try {
            Remove-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null
            $capabilitiesRemovedCount++
        } catch {
            Add-CwsWarning "Capability was kept: $($capability.Name) ($($_.Exception.Message))"
        }
    }
}
Add-CwsNote "Removed $capabilitiesRemovedCount installed optional capabilities from the explicit list."
Write-Host "Selected capability cleanup finished.`n" -ForegroundColor Green

        Write-Host "REMOVE LEGACY FEATURES`n"
        ## c:\windows\system32\optionalfeatures.exe
        ## powershell -noexit -command "dism /online /get-features /format:table"
Write-Host "Disabling only explicitly selected legacy features when present.`n" -ForegroundColor Cyan

$optionalFeatures = @(
    'MicrosoftWindowsPowerShellV2',
    'MicrosoftWindowsPowerShellV2Root',
    'Printing-XPSServices-Features',
    'SMB1Protocol',
    'WorkFolders-Client',
    'Recall'
)
Write-Host "Reading enabled Windows optional features once..." -ForegroundColor Cyan
$enabledOptionalFeatures = @(Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
$featuresDisabledCount = 0
foreach ($featureName in $optionalFeatures) {
    $feature = $enabledOptionalFeatures | Where-Object { $_.FeatureName -eq $featureName } | Select-Object -First 1
    if ($feature) {
        Write-Host "  Feature: $featureName"
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
            $featuresDisabledCount++
        } catch {
            Add-CwsWarning "Optional feature was kept: $featureName ($($_.Exception.Message))"
        }
    }
}
Add-CwsNote "Disabled $featuresDisabledCount enabled legacy optional features from the explicit list."
Write-Host "Selected legacy feature cleanup finished.`n" -ForegroundColor Green

		Write-Host "REMOVE LEGACY APPS`n"
		## appwiz.cpl

# Microsoft GameInput is preserved because games and input devices can depend on it.
Add-CwsNote 'Microsoft GameInput was preserved.'

if (Get-CwsOption -Name 'RemoveOneDrive' -Default $true) {
    # stop and uninstall OneDrive if present
    Stop-CwsProcessIfPresent -Name 'OneDrive'
    $oneDriveInstallers = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )
    foreach ($installer in $oneDriveInstallers) {
        if (Test-Path -LiteralPath $installer) {
            try { Start-Process -FilePath $installer -ArgumentList '/uninstall' -Wait -WindowStyle Hidden -ErrorAction Stop } catch { }
        }
    }

    Get-ChildItem -Path "C:\Program Files*\Microsoft OneDrive", "$env:LOCALAPPDATA\Microsoft\OneDrive" -Filter 'OneDriveSetup.exe' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { try { Start-Process -FilePath $_.FullName -ArgumentList '/uninstall /allusers' -Wait -WindowStyle Hidden -ErrorAction Stop } catch { } }

    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'OneDrive' } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\Run`" /v `"OneDrive`" /f >nul 2>&1"
    cmd /c "reg delete `"HKLM\Software\Microsoft\Windows\CurrentVersion\Run`" /v `"OneDrive`" /f >nul 2>&1"
    cmd /c "reg add `"HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v `"DisableFileSyncNGSC`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
    cmd /c "reg add `"HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v `"DisableFileSync`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

    foreach ($oneDrivePath in @("$env:USERPROFILE\OneDrive", "$env:LOCALAPPDATA\Microsoft\OneDrive", "$env:PROGRAMDATA\Microsoft OneDrive")) {
        Remove-CwsPathIfPresent -LiteralPath $oneDrivePath -Recurse
    }

} else {
    Add-CwsNote 'OneDrive removal was not selected.'
}

# Preserve Remote Desktop Connection and Snipping Tool. They are Windows features and should not be uninstalled by a general setup script.
Add-CwsNote 'Remote Desktop Connection and Snipping Tool were preserved.'

# Microsoft Update Health Tools is preserved because it supports Windows Update remediation.
Add-CwsNote 'Microsoft Update Health Tools was preserved.'

$plugScheduler = Get-ScheduledTask -TaskName 'PLUGScheduler' -ErrorAction SilentlyContinue
if ($plugScheduler) {
    Unregister-ScheduledTask -TaskName 'PLUGScheduler' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

# Preserve unrelated Run, RunOnce and Startup entries. Only known unwanted entries are removed above.
Add-CwsNote 'Existing third-party startup entries were preserved.'

        Write-Host "INSTALLING APPS`n"

# WinGet bootstrap helpers
function Get-CwsDesktopAppInstallerPackage {
    $packages = @()
    $packages += @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)
    $packages += @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)
    return $packages | Where-Object { $_.InstallLocation } | Sort-Object Version -Descending | Select-Object -First 1
}

function Get-WinGetExePath {
    $candidates = New-Object System.Collections.Generic.List[string]

    $package = Get-CwsDesktopAppInstallerPackage
    if ($package) {
        $candidates.Add((Join-Path $package.InstallLocation 'winget.exe'))
    }

    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $candidates.Add($command.Source) }

    $aliasCandidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $aliasCandidate) { $candidates.Add($aliasCandidate) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $versionOutput = & $candidate --version 2>&1
            $exitCode = [int]$LASTEXITCODE
            if ($exitCode -eq 0 -and (($versionOutput | Out-String) -match '\d+\.\d+')) {
                return $candidate
            }
        } catch { }
    }
    return $null
}

function Register-CwsWinGetForCurrentUser {
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        return [bool](Get-WinGetExePath)
    } catch {
        return $false
    }
}

function Repair-CwsWinGetWithOfficialModule {
    $repairScriptPath = Join-Path $env:SystemRoot 'Temp\CWS-Repair-WinGet.ps1'
    $repairScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Install-PackageProvider -Name NuGet -Force | Out-Null
if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
    Register-PSRepository -Default
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -AllowClobber -Confirm:$false
Import-Module Microsoft.WinGet.Client -Force
Repair-WinGetPackageManager -AllUsers -Force -Latest
'@

    try {
        Set-Content -LiteralPath $repairScriptPath -Value $repairScript -Encoding UTF8 -Force
        Write-Host 'Trying Microsoft official Repair-WinGetPackageManager method. This can take several minutes...'
        $repairExit = Invoke-CwsProcessWithTimeout `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $repairScriptPath) `
            -TimeoutSeconds 600
        if ($repairExit -notin @(0, 3010)) {
            Add-CwsWarning "Official WinGet repair returned exit code $repairExit. Trying the signed runtime fallback."
            return $false
        }
        Start-Sleep -Seconds 5
        return [bool](Get-WinGetExePath)
    } catch {
        Add-CwsWarning ("Official WinGet repair failed: {0}" -f $_.Exception.Message)
        return $false
    } finally {
        Remove-Item -LiteralPath $repairScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-CwsWindowsAppRuntime18 {
    $bootstrapDir = Join-Path $env:SystemRoot 'Temp\CWS-WinGet'
    New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null

    $architecture = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
        'ARM64' { 'arm64' }
        'X86'   { 'x86' }
        default { 'x64' }
    }
    $runtimeInstaller = Join-Path $bootstrapDir "WindowsAppRuntimeInstall-$architecture.exe"
    $runtimeUri = "https://aka.ms/windowsappsdk/1.8/1.8.260529003/windowsappruntimeinstall-$architecture.exe"

    try {
        Write-Host "Downloading the signed Windows App Runtime 1.8 installer for $architecture..."
        Invoke-WebRequest -Uri $runtimeUri -UseBasicParsing -OutFile $runtimeInstaller -ErrorAction Stop
        $runtimeExit = Invoke-CwsProcessWithTimeout -FilePath $runtimeInstaller -TimeoutSeconds 300 -Hidden
        if ($runtimeExit -notin @(0, 3010)) {
            Add-CwsWarning "Windows App Runtime 1.8 installer returned exit code $runtimeExit."
            return $false
        }
        Start-Sleep -Seconds 3
        $runtimePackage = Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $runtimePackage) {
            Add-CwsWarning 'Windows App Runtime 1.8 was not detected after its installer completed.'
            return $false
        }
        Add-CwsNote "Windows App Runtime 1.8 detected: $($runtimePackage.Version)."
        return $true
    } catch {
        Add-CwsWarning ("Windows App Runtime 1.8 installation failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Install-CwsAppInstallerBundle {
    $bootstrapDir = Join-Path $env:SystemRoot 'Temp\CWS-WinGet'
    New-Item -Path $bootstrapDir -ItemType Directory -Force | Out-Null
    $appInstallerPath = Join-Path $bootstrapDir 'Microsoft.DesktopAppInstaller.msixbundle'

    try {
        Write-Host 'Downloading the current signed App Installer bundle from Microsoft...'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -UseBasicParsing -OutFile $appInstallerPath -ErrorAction Stop
        Add-AppxPackage -Path $appInstallerPath -ForceApplicationShutdown -ErrorAction SilentlyContinue
        Register-CwsWinGetForCurrentUser | Out-Null
        Start-Sleep -Seconds 5
        $resolved = Get-WinGetExePath
        if (-not $resolved) { Add-CwsWarning 'App Installer bundle completed but WinGet was still unavailable.' }
        return [bool]$resolved
    } catch {
        Add-CwsWarning ("App Installer bundle installation failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Install-CwsWinGetBootstrap {
    # Microsoft documents Repair-WinGetPackageManager as the supported repair/bootstrap path.
    if (Repair-CwsWinGetWithOfficialModule) { return $true }

    # Current App Installer packages depend on Windows App Runtime 1.8. Install that
    # signed Microsoft runtime first, then install the current App Installer bundle.
    if (-not (Install-CwsWindowsAppRuntime18)) { return $false }
    return (Install-CwsAppInstallerBundle)
}

Register-CwsWinGetForCurrentUser | Out-Null
$script:wingetExe = Get-WinGetExePath
if (-not $script:wingetExe) {
    Write-Host "WinGet is missing. Starting the supported repair/bootstrap sequence...`n" -ForegroundColor Yellow
    Install-CwsWinGetBootstrap | Out-Null
    $script:wingetExe = Get-WinGetExePath
}

$wingetWorks = [bool]$script:wingetExe
if ($wingetWorks) {
    Write-Host "Using WinGet: $script:wingetExe`n" -ForegroundColor Green
    $sourceResult = Invoke-CwsNativeCommand -FilePath $script:wingetExe -ArgumentList @('source','update','--disable-interactivity') -TimeoutSeconds 180
    if ($sourceResult.Output) { $sourceResult.Output -split "`r?`n" | ForEach-Object { if ($_){ Write-Host $_ } } }
    if ($sourceResult.Error) { $sourceResult.Error -split "`r?`n" | ForEach-Object { if ($_){ Write-Host $_ -ForegroundColor DarkGray } } }
    if ($sourceResult.ExitCode -ne 0) { Add-CwsWarning "WinGet source update returned exit code $($sourceResult.ExitCode)." }
} else {
    Add-CwsWarning 'WinGet could not be repaired. App installs were skipped, but the rest of StepTwo will continue.'
}

function Invoke-CwsWinGetCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(30,3600)][int]$TimeoutSeconds = 600,
        [string]$Activity = 'WinGet command'
    )
    if (-not $script:wingetExe) {
        return [pscustomobject]@{ ExitCode = 1; Output = 'WinGet is unavailable.'; TimedOut = $false }
    }

    $id = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "winget-$id.out"
    $stderrPath = Join-Path $env:TEMP "winget-$id.err"
    try {
        $process = Start-Process -FilePath $script:wingetExe -ArgumentList $Arguments -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 30
        while (-not $process.HasExited) {
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try { Start-Process -FilePath taskkill.exe -ArgumentList @('/PID',$process.Id,'/T','/F') -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null } catch { }
                $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
                $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
                return [pscustomobject]@{ ExitCode = 1460; Output = ($stdout + "`n" + $stderr).Trim(); TimedOut = $true }
            }
            if ($stopwatch.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                Write-Host ("  {0} is still running ({1}s)..." -f $Activity, [int]$stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
                $nextHeartbeat += 30
            }
            Start-Sleep -Seconds 2
            $process.Refresh()
        }
        $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($stdout + "`n" + $stderr).Trim(); TimedOut = $false }
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message; TimedOut = $false }
    } finally {
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CwsWinGetErrorText {
    param([int]$ExitCode)
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ExitCode),0)
    $hex = '0x{0:X8}' -f $unsigned
    $description = switch ($hex) {
        '0x00000000' { 'Success' }
        '0x8A150006' { 'Installer could not be started by ShellExecute' }
        '0x8A150011' { 'Installer hash mismatch' }
        '0x80073D06' { 'A newer package version is already installed' }
        '0x80073CF3' { 'Package dependency or validation failure' }
        '0x000005B4' { 'Installation timed out' }
        default { 'WinGet or installer returned an error' }
    }
    return "$hex - $description"
}

function Test-CwsWinGetInstalled {
    param([Parameter(Mandatory)][string]$Id)
    $result = Invoke-CwsWinGetCommand -Arguments @('list','--id',$Id,'-e','--accept-source-agreements','--disable-interactivity') -TimeoutSeconds 120 -Activity "Verifying $Id"
    return ($result.ExitCode -eq 0 -and $result.Output -match [regex]::Escape($Id))
}

function New-CwsInternetShortcut {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Url)
    try {
        $path = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.url"
        Set-Content -LiteralPath $path -Value "[InternetShortcut]`r`nURL=$Url`r`n" -Encoding ASCII -Force
        $script:manualApps += "$Name - $Url"
        return $true
    } catch {
        Add-CwsWarning ("Manual shortcut could not be created for {0}: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

function Invoke-CwsWinGetInstall {
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateRange(60,3600)][int]$TimeoutSeconds = 600,
        [string]$Source = ''
    )

    if (Test-CwsWinGetInstalled -Id $Id) {
        return [pscustomobject]@{ Id = $Id; Success = $true; Verified = $true; ExitCode = 0; Detail = 'Already installed' }
    }

    $arguments = @('install','--id',$Id,'-e','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity','--no-upgrade')
    if (-not [string]::IsNullOrWhiteSpace($Source)) { $arguments += @('--source',$Source) }
    $result = Invoke-CwsWinGetCommand -Arguments $arguments -TimeoutSeconds $TimeoutSeconds -Activity "Installing $Id"
    if ($result.Output) { $result.Output -split "`r?`n" | ForEach-Object { if ($_){ Write-Host $_ } } }

    for ($verifyAttempt = 1; $verifyAttempt -le 4; $verifyAttempt++) {
        if (Test-CwsWinGetInstalled -Id $Id) {
            return [pscustomobject]@{ Id = $Id; Success = $true; Verified = $true; ExitCode = 0; Detail = 'Verified after install' }
        }
        if ($verifyAttempt -lt 4) { Start-Sleep -Seconds 5 }
    }

    if ([int]$result.ExitCode -eq 0) {
        return [pscustomobject]@{
            Id = $Id
            Success = $true
            Verified = $false
            ExitCode = 0
            Detail = 'Installer completed successfully, but the package was not yet visible to winget list'
        }
    }

    return [pscustomobject]@{
        Id = $Id
        Success = $false
        Verified = $false
        ExitCode = [int]$result.ExitCode
        Detail = (Get-CwsWinGetErrorText -ExitCode $result.ExitCode)
    }
}

$recommendedApps = @(
    '7zip.7zip','Microsoft.DirectX','Google.Chrome','REALiX.HWiNFO','Oracle.JavaRuntimeEnvironment',
    'Microsoft.DotNet.Runtime.8','Microsoft.DotNet.Runtime.10','Microsoft.Edge','Microsoft.EdgeWebView2Runtime',
    'Microsoft.VCRedist.2005.x86','Microsoft.VCRedist.2005.x64','Microsoft.VCRedist.2008.x64','Microsoft.VCRedist.2008.x86',
    'Microsoft.VCRedist.2010.x64','Microsoft.VCRedist.2010.x86','Microsoft.VCRedist.2012.x64','Microsoft.VCRedist.2012.x86',
    'Microsoft.VCRedist.2013.x64','Microsoft.VCRedist.2013.x86','Microsoft.VCRedist.2015+.x64','Microsoft.VCRedist.2015+.x86',
    'rcmaehl.MSEdgeRedirect','Obsidian.Obsidian','Microsoft.PowerShell','Microsoft.PowerToys','Proton.ProtonDrive',
    'Proton.ProtonVPN','ShareX.ShareX','Tailscale.Tailscale','VideoLAN.VLC','Microsoft.WindowsTerminal',
    'memstechtips.Winhance','RARLab.WinRAR','WinSCP.WinSCP','Devolutions.UniGetUI','Microsoft.Sysinternals.Autoruns'
)
$communicationApps = @(
    'Anthropic.Claude','Discord.Discord','Discord.Discord.PTB','Element.Element','XP8JNQFBQH6PVF',
    'Proton.ProtonMail','SlackTechnologies.Slack','Telegram.TelegramDesktop','Termius.Termius','Zoom.Zoom'
)
$gamingApps = @(
    'EpicGames.EpicGamesLauncher','Nvidia.PhysX','RockstarGames.Launcher','Valve.Steam','Ubisoft.Connect','ElectronicArts.EADesktop'
)
$developerApps = @(
    'Balena.Etcher','Microsoft.OpenSSH.Preview','RaspberryPiFoundation.RaspberryPiImager','SublimeHQ.SublimeText.4'
)
$hardwareApps = @(
    'Bambulab.Bambustudio','Apple.Bonjour','File-New-Project.EarTrumpet','Elgato.StreamDeck',
    'Futuremark.FuturemarkSystemInfo','Logitech.GHUB','RevoUninstaller.RevoUninstallerPro',
    'SergeySerkov.TagScanner','Apple.iTunes'
)
$storeApps = @('Microsoft.WindowsApp')
$legacyDotNetApps = @(
    'Microsoft.DotNet.Native.Runtime','Microsoft.DotNet.Runtime.3_1','Microsoft.DotNet.Runtime.5',
    'Microsoft.DotNet.Runtime.6','Microsoft.DotNet.Runtime.7'
)
$legacyDeveloperPacks = @('Microsoft.DotNet.Framework.DeveloperPack.4.5','Microsoft.DotNet.Framework.DeveloperPack_4')

$apps = @()
if (Get-CwsOption -Name 'InstallRecommendedApps' -Default $true) { $apps += $recommendedApps }
if (Get-CwsOption -Name 'InstallCommunicationApps' -Default $true) { $apps += $communicationApps }
if (Get-CwsOption -Name 'InstallGamingApps' -Default $true) { $apps += $gamingApps }
if (Get-CwsOption -Name 'InstallDeveloperTools' -Default $true) { $apps += $developerApps }
if (Get-CwsOption -Name 'InstallHardwareUtilities' -Default $true) { $apps += $hardwareApps }
if (Get-CwsOption -Name 'InstallStoreApps' -Default $true) { $apps += $storeApps }
if (Get-CwsOption -Name 'InstallLegacyDotNet' -Default $false) { $apps += $legacyDotNetApps }
if (Get-CwsOption -Name 'InstallLegacyDeveloperPacks' -Default $false) { $apps += $legacyDeveloperPacks }
if ([Environment]::OSVersion.Version.Build -ge 22000 -and (Get-CwsOption -Name 'InstallRecommendedApps' -Default $true)) { $apps += 'StartIsBack.StartAllBack' }
$apps = @($apps | Select-Object -Unique)
$selectedApps = @($apps)

# Brave Origin remains manual because its vendor installer is unreliable unattended.
Write-Host "BRAVE ORIGIN`n"
New-CwsInternetShortcut -Name 'Install Brave Origin' -Url 'https://laptop-updates.brave.com/latest/origin' | Out-Null
Add-CwsNote 'Brave Origin was left as a manual desktop shortcut.'

if ($wingetWorks) {
    $appNumber = 0
    foreach ($app in $apps) {
        $appNumber++
        $timeout = if ($app -match 'Launcher|Steam|Bambustudio|StreamDeck|GHUB|iTunes|EADesktop') { 1200 } else { 600 }
        $source = if ($app -in @('Microsoft.WindowsApp','XP8JNQFBQH6PVF')) { 'msstore' } else { 'winget' }
        Write-Host "[$appNumber/$($apps.Count)] Installing $app" -ForegroundColor Cyan
        $installResult = Invoke-CwsWinGetInstall -Id $app -TimeoutSeconds $timeout -Source $source
        if ($installResult.Success) {
            if ($installResult.Verified) {
                $verifiedApps += $app
            } else {
                $unverifiedApps += "$app ($($installResult.Detail))"
                if ($app -eq 'XP8JNQFBQH6PVF') {
                    New-CwsInternetShortcut -Name 'Install Perplexity' -Url 'https://www.perplexity.ai/download' | Out-Null
                }
                if ($app -eq 'RockstarGames.Launcher') {
                    New-CwsInternetShortcut -Name 'Install Rockstar Games Launcher' -Url 'https://www.rockstargames.com/downloads' | Out-Null
                }
            }
        } else {
            $failedApps += "$app ($($installResult.Detail))"
            if ($app -eq 'XP8JNQFBQH6PVF') {
                New-CwsInternetShortcut -Name 'Install Perplexity' -Url 'https://www.perplexity.ai/download' | Out-Null
            }
            if ($app -eq 'RockstarGames.Launcher') {
                New-CwsInternetShortcut -Name 'Install Rockstar Games Launcher' -Url 'https://www.rockstargames.com/downloads' | Out-Null
            }
        }
    }
}

# Default-deny packaged background activity, but preserve selected Store-based apps
# that rely on background notifications or servicing. Per-app entries override the
# documented default policy.
try {
    $backgroundAllowPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('Microsoft.WindowsStore','Microsoft.DesktopAppInstaller','MicrosoftCorporationII.WindowsApp') -or
        $_.Name -like '*EarTrumpet*'
    })
    $backgroundAllowPfns = @($backgroundAllowPackages.PackageFamilyName | Where-Object { $_ } | Sort-Object -Unique)
    $appPrivacyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    if ($backgroundAllowPfns.Count -gt 0) {
        if (Set-CwsRegistryMultiString -Path $appPrivacyPath -Name 'LetAppsRunInBackground_ForceAllowTheseApps' -Value $backgroundAllowPfns) {
            Add-CwsNote ("Packaged background allowlist applied for {0} package family names." -f $backgroundAllowPfns.Count)
        }
    } else {
        Remove-CwsRegistryValue -Path $appPrivacyPath -Name 'LetAppsRunInBackground_ForceAllowTheseApps'
    }
} catch {
    Add-CwsWarning ("Packaged background allowlist could not be applied: {0}" -f $_.Exception.Message)
}

try {
    [pscustomobject]@{
        GeneratedAt = (Get-Date -Format o)
        Selected = $selectedApps
        Verified = $verifiedApps
        Unverified = $unverifiedApps
        Failed = $failedApps
        Manual = $manualApps
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $CwsWorkRoot 'AppInstallResults.json') -Encoding UTF8 -Force
} catch { }

# Remove only known heavy application auto-start entries. Update services and
# scheduled update tasks are deliberately preserved.
if (Get-CwsOption -Name 'DisableAppAutoStart' -Default $true) {
    $startupPattern = 'Discord|Slack|Teams|Epic|Steam|EA|Ubisoft|Rockstar|Claude|Perplexity|Logi|GHUB|iTunesHelper|Telegram|Termius|Zoom|OneDrive'
    $removedStartupEntries = 0
    foreach ($runPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )) {
        $item = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($property in $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
            if ($property.Name -match $startupPattern -or [string]$property.Value -match $startupPattern) {
                Remove-ItemProperty -Path $runPath -Name $property.Name -ErrorAction SilentlyContinue
                $removedStartupEntries++
            }
        }
    }
    foreach ($startupFolder in @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )) {
        if (-not (Test-Path -LiteralPath $startupFolder)) { continue }
        Get-ChildItem -LiteralPath $startupFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $startupPattern } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $removedStartupEntries++ }
    }
    Add-CwsNote "$removedStartupEntries known application auto-start entries were removed."
}

# clean up taskbar - remove all pins, clear stale layout XMLs, remove duplicate shortcuts
# works on both Windows 10 and Windows 11

# remove all pinned shortcut files
$taskBarFolder = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
if (Test-Path $taskBarFolder) {
    Get-ChildItem $taskBarFolder -Filter "*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# clear auto-pinned items
$implicitFolder = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\ImplicitAppShortcuts"
if (Test-Path $implicitFolder) {
    Remove-Item "$implicitFolder\*" -Recurse -Force -ErrorAction SilentlyContinue
}

# remove stale LayoutModification.xml files (user + Default profile + temp)
if (Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Shell\LayoutModification.xml") { Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Shell\LayoutModification.xml" -Force }
if (Test-Path "$env:SystemDrive\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml") { Remove-Item "$env:SystemDrive\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml" -Force }
if (Test-Path "$env:SystemRoot\Temp\WinSuxTaskbar.xml") { Remove-Item "$env:SystemRoot\Temp\WinSuxTaskbar.xml" -Force }

# wipe Taskband registry to clear stale "(2)" / "(3)" entries
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Start-Process explorer
Start-Sleep -Seconds 4

# remove duplicate shortcuts across Start Menu and Desktop locations
$dupeLocations = @(
    @{ Path = "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs"; Priority = 1 },
    @{ Path = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs";         Priority = 2 },
    @{ Path = "$env:PUBLIC\Desktop";                                        Priority = 3 },
    @{ Path = "$env:USERPROFILE\Desktop";                                   Priority = 4 }
)

$dupeWsh = New-Object -ComObject WScript.Shell
$dupeAllShortcuts = @()

foreach ($dupeLoc in $dupeLocations) {
    if (-not (Test-Path $dupeLoc.Path)) { continue }
    Get-ChildItem -Path $dupeLoc.Path -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $dupeShortcut = $dupeWsh.CreateShortcut($_.FullName)
            $dupeTarget = $dupeShortcut.TargetPath
            if ($dupeTarget) {
                $dupeTarget = [System.Environment]::ExpandEnvironmentVariables($dupeTarget).ToLower().TrimEnd('\')
            }
            $dupeAllShortcuts += [PSCustomObject]@{
                FullPath  = $_.FullName
                Target    = $dupeTarget
                Priority  = $dupeLoc.Priority
                SubFolder = $_.DirectoryName.Replace($dupeLoc.Path, "").TrimStart('\')
            }
        } catch { }
    }
}

$dupeGrouped = $dupeAllShortcuts | Where-Object { $_.Target -and $_.Target -ne "" } | Group-Object -Property Target
$dupeGrouped | Where-Object { $_.Count -gt 1 } | ForEach-Object {
    $_.Group | Sort-Object Priority, { $_.SubFolder.Length } | Select-Object -Skip 1 | ForEach-Object {
        Remove-Item $_.FullPath -Force -ErrorAction SilentlyContinue
    }
}

# brave debloat - disable rewards, wallet, vpn, ai chat, stats ping
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveRewardsDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveWalletDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveVPNDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveAIChatEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveStatsPingEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveNewsDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveTalkDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"TorDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"BraveP3AEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"UrlKeyedAnonymizedDataCollectionEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"SafeBrowsingExtendedReportingEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\BraveSoftware\Brave`" /v `"MetricsReportingEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# keep Brave update scheduled tasks intact so the browser can stay current.

        # FUNCTION SHOW-MENU
        function Show-Menu {
        Clear-Host
        Write-Host "INSTALL GRAPHICS DRIVERS" -ForegroundColor Yellow
        Write-Host "SELECT YOUR SYSTEM'S GPU`n" -ForegroundColor Yellow
        Write-Host " 1.  NVIDIA" -ForegroundColor Green
        Write-Host " 2.  AMD" -ForegroundColor Red
        Write-Host " 3.  INTEL" -ForegroundColor Blue
        Write-Host " 4.  SKIP`n"
        }
        :MainLoop while ($true) {
        Show-Menu
        $choice = Read-Host " "
        if ($choice -match '^[1-4]$') {
        switch ($choice) {
        1 {

        Clear-Host

        Write-Host "DOWNLOAD NVIDIA GPU DRIVER`n" -ForegroundColor Yellow
    	## explorer "https://www.nvidia.com/en-us/drivers"
		## shell:appsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel

# open the official NVIDIA driver page in the default browser
Start-Process 'https://www.nvidia.com/en-us/drivers'
Read-Host 'Download the correct NVIDIA driver, then press Enter to select the downloaded installer'

        Write-Host "SELECT DOWNLOADED DRIVER`n" -ForegroundColor Yellow

$InstallFile = Show-ModernFilePicker -Mode File
if ([string]::IsNullOrWhiteSpace($InstallFile) -or -not (Test-Path -LiteralPath $InstallFile)) {
    Add-CwsWarning 'No NVIDIA driver installer was selected. NVIDIA installation was skipped.'
    break
}

$sevenZipExe = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZipExe)) {
    throw '7-Zip is required to extract the NVIDIA driver, but 7z.exe was not found.'
}

        Write-Host "DEBLOATING DRIVER`n"

$driverExtractPath = Join-Path $env:SystemRoot 'Temp\NvidiaDriver'
Remove-CwsPathIfPresent -LiteralPath $driverExtractPath -Recurse
& $sevenZipExe x $InstallFile "-o$driverExtractPath" -y | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $driverExtractPath 'setup.exe'))) {
    throw 'The NVIDIA driver could not be extracted or setup.exe was not found.'
}

# debloat nvidia driver
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\Display.Nview" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\FrameViewSDK" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\HDAudio" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\MSVCRT" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp.MessageBus" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvBackend" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvContainer" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvCpl" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvDLISR" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NVPCF" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvTelemetry" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvVAD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\PhysX" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\PPC" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\ShadowPlay" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\CEF" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\osc" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\Plugins" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\UpgradeConsent" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\www" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\7z.dll" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\7z.exe" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\DarkModeCheck.exe" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\InstallerExtension.dll" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\NvApp.nvi" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\NvAppApi.dll" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\NvAppExt.dll" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemRoot\Temp\NvidiaDriver\NvApp\NvConfigGenerator.dll" -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Host "INSTALLING DRIVER`n"

# install nvidia driver
Start-Process (Join-Path $driverExtractPath 'setup.exe') -ArgumentList '-s -noreboot -noeula -clean' -Wait -NoNewWindow

# install nvidia control panel
try {
if ($wingetWorks) {
    $nvcplResult = Invoke-CwsWinGetInstall -Id '9NF8H0H7WMLT' -Source 'msstore'
    if ($nvcplResult.Success) {
        if ($nvcplResult.Verified) {
            $verifiedApps += 'NVIDIA Control Panel 9NF8H0H7WMLT'
        } else {
            $unverifiedApps += "NVIDIA Control Panel 9NF8H0H7WMLT ($($nvcplResult.Detail))"
        }
    } else {
        $failedApps += "NVIDIA Control Panel 9NF8H0H7WMLT ($($nvcplResult.Detail))"
    }
}
} catch { }

# delete download
Remove-CwsPathIfPresent -LiteralPath $InstallFile

# delete old driver files
Remove-CwsPathIfPresent -LiteralPath "$env:SystemDrive\NVIDIA" -Recurse

        Write-Host "IMPORTING SETTINGS`n"

function Get-CwsNvidiaDisplayRegistryKeys {
    $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path $classPath)) { return @() }
    return @(Get-ChildItem -Path $classPath -ErrorAction SilentlyContinue | Where-Object {
        $properties = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        $properties.DriverDesc -match 'NVIDIA' -or $properties.ProviderName -match 'NVIDIA'
    })
}

$nvidiaRegistryKeys = Get-CwsNvidiaDisplayRegistryKeys

# turn on disable dynamic pstate
foreach ($key in $nvidiaRegistryKeys) {
    try { New-ItemProperty -Path $key.PSPath -Name 'DisableDynamicPstate' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null } catch { Add-CwsWarning "NVIDIA DisableDynamicPstate was not applied to $($key.PSChildName)." }
}

# disable HDCP for NVIDIA adapters only
foreach ($key in $nvidiaRegistryKeys) {
    try { New-ItemProperty -Path $key.PSPath -Name 'RMHdcpKeyglobZero' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null } catch { Add-CwsWarning "NVIDIA HDCP setting was not applied to $($key.PSChildName)." }
}

# unblock drs files
$path = "C:\ProgramData\NVIDIA Corporation\Drs"
if (Test-Path $path) {
    Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
}

# set physx to gpu
cmd /c "reg add `"HKLM\System\CurrentControlSet\Services\nvlddmkm\Parameters\Global\NVTweak`" /v `"NvCplPhysxAuto`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# enable developer settings
cmd /c "reg add `"HKLM\System\CurrentControlSet\Services\nvlddmkm\Parameters\Global\NVTweak`" /v `"NvDevToolsVisible`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# allow access to NVIDIA GPU performance counters for all users
foreach ($key in $nvidiaRegistryKeys) {
    try { New-ItemProperty -Path $key.PSPath -Name 'RmProfilingAdminOnly' -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null } catch { Add-CwsWarning "NVIDIA profiling setting was not applied to $($key.PSChildName)." }
}
cmd /c "reg add `"HKLM\System\CurrentControlSet\Services\nvlddmkm\Parameters\Global\NVTweak`" /v `"RmProfilingAdminOnly`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# disable show notification tray icon
cmd /c "reg add `"HKCU\Software\NVIDIA Corporation\NvTray`" /v `"StartOnLogin`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# enable nvidia legacy sharpen
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS`" /v `"EnableGR535`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS`" /v `"EnableGR535`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# turn on no scaling for all displays
$configKeys = Get-ChildItem -Path "HKLM:\System\CurrentControlSet\Control\GraphicsDrivers\Configuration" -Recurse -ErrorAction SilentlyContinue
foreach ($key in $configKeys) {
try {
$scalingProperties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
} catch {
continue
}
if ($scalingProperties.PSObject.Properties.Name -contains 'Scaling') {
$regPath = $key.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', '').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
Invoke-CwsRegExe -Arguments ("add `"{0}`" /v Scaling /t REG_DWORD /d 2 /f" -f $regPath) | Out-Null
}
}

# turn on override the scaling mode set by games and programs for all displays
# perform scaling on display
$displayDbPath = "HKLM:\System\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase"
if (Test-Path $displayDbPath) {
$displays = Get-ChildItem -Path $displayDbPath -ErrorAction SilentlyContinue
foreach ($display in $displays) {
$regPath = $display.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', '').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
Invoke-CwsRegExe -Arguments ("add `"{0}`" /v ScalingConfig /t REG_BINARY /d DB02000010000000200100000E010000 /f" -f $regPath) | Out-Null
}
}

# download inspector
Get-FileFromWeb -URL "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip" -File "$env:SystemRoot\Temp\Inspector.zip"

# extract inspector with 7zip
& "C:\Program Files\7-Zip\7z.exe" x "$env:SystemRoot\Temp\Inspector.zip" -o"$env:SystemRoot\Temp\Inspector" -y | Out-Null

# set config for inspector
$nipfile = @'
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executables/>
    <Settings>
      <ProfileSetting>
        <SettingNameInfo>Frame Rate Limiter V3</SettingNameInfo>
        <SettingID>277041154</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>GSYNC - Application Mode</SettingNameInfo>
        <SettingID>294973784</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>GSYNC - Application State</SettingNameInfo>
        <SettingID>279476687</SettingID>
        <SettingValue>4</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>GSYNC - Global Feature</SettingNameInfo>
        <SettingID>278196567</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>GSYNC - Global Mode</SettingNameInfo>
        <SettingID>278196727</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>GSYNC - Indicator Overlay</SettingNameInfo>
        <SettingID>268604728</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Maximum Pre-Rendered Frames</SettingNameInfo>
        <SettingID>8102046</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Preferred Refresh Rate</SettingNameInfo>
        <SettingID>6600001</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Ultra Low Latency - CPL State</SettingNameInfo>
        <SettingID>390467</SettingID>
        <SettingValue>2</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Ultra Low Latency - Enabled</SettingNameInfo>
        <SettingID>277041152</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Vertical Sync</SettingNameInfo>
        <SettingID>11041231</SettingID>
        <SettingValue>138504007</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Vertical Sync - Smooth AFR Behavior</SettingNameInfo>
        <SettingID>270198627</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Vertical Sync - Tear Control</SettingNameInfo>
        <SettingID>5912412</SettingID>
        <SettingValue>2525368439</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Vulkan/OpenGL Present Method</SettingNameInfo>
        <SettingID>550932728</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Antialiasing - Gamma Correction</SettingNameInfo>
        <SettingID>276652957</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Antialiasing - Mode</SettingNameInfo>
        <SettingID>276757595</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Antialiasing - Setting</SettingNameInfo>
        <SettingID>282555346</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Anisotropic Filter - Optimization</SettingNameInfo>
        <SettingID>8703344</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Anisotropic Filter - Sample Optimization</SettingNameInfo>
        <SettingID>15151633</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Anisotropic Filtering - Mode</SettingNameInfo>
        <SettingID>282245910</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Anisotropic Filtering - Setting</SettingNameInfo>
        <SettingID>270426537</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Texture Filtering - Negative LOD Bias</SettingNameInfo>
        <SettingID>1686376</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Texture Filtering - Quality</SettingNameInfo>
        <SettingID>13510289</SettingID>
        <SettingValue>20</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Texture Filtering - Trilinear Optimization</SettingNameInfo>
        <SettingID>3066610</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>CUDA - Force P2 State</SettingNameInfo>
        <SettingID>1343646814</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
	  <ProfileSetting>
        <SettingNameInfo>CUDA - Sysmem Fallback Policy</SettingNameInfo>
        <SettingID>283962569</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Power Management - Mode</SettingNameInfo>
        <SettingID>274197361</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Shader Cache - Cache Size</SettingNameInfo>
        <SettingID>11306135</SettingID>
        <SettingValue>4294967295</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Threaded Optimization</SettingNameInfo>
        <SettingID>549528094</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>OpenGL GDI Compatibility</SettingNameInfo>
        <SettingID>544392611</SettingID>
        <SettingValue>0</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Preferred OpenGL GPU</SettingNameInfo>
        <SettingID>550564838</SettingID>
        <SettingValue>id,2.0:268410DE,00000100,GF - (400,2,161,24564) @ (0)</SettingValue>
        <ValueType>String</ValueType>
      </ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
'@
Set-Content -Path "$env:SystemRoot\Temp\Inspector.nip" -Value $nipfile -Force

# import nip
Start-Process -wait "$env:SystemRoot\Temp\Inspector\nvidiaProfileInspector.exe" -ArgumentList "-silentImport -silent $env:SystemRoot\Temp\Inspector.nip"

        break MainLoop

          }
    	2 {

        Clear-Host

        Write-Host "DOWNLOAD AMD GPU DRIVER`n" -ForegroundColor Yellow
		## explorer "https://www.amd.com/en/support/download/drivers.html"
		## C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe

# open the official AMD driver page in the default browser
Start-Process 'https://www.amd.com/en/support/download/drivers.html'
Read-Host 'Download the correct AMD driver, then press Enter to select the downloaded installer'

        Write-Host "SELECT DOWNLOADED DRIVER`n" -ForegroundColor Yellow

$InstallFile = Show-ModernFilePicker -Mode File
if ([string]::IsNullOrWhiteSpace($InstallFile) -or -not (Test-Path -LiteralPath $InstallFile)) {
    Add-CwsWarning 'No AMD driver installer was selected. AMD installation was skipped.'
    break
}

$sevenZipExe = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZipExe)) { throw '7-Zip is required to extract the AMD driver.' }
$amdDriverPath = Join-Path $env:SystemRoot 'Temp\AmdDriver'
Remove-CwsPathIfPresent -LiteralPath $amdDriverPath -Recurse
& $sevenZipExe x $InstallFile "-o$amdDriverPath" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The AMD driver could not be extracted.' }

        Write-Host "DEBLOATING DRIVER`n"

# debloat amd driver
$path = "$env:SystemRoot\Temp\AmdDriver\Packages\Drivers\Display\WT6A_INF"
if (Test-Path -LiteralPath $path) {
Get-ChildItem $path -Directory | Where-Object {
    $_.Name -notlike "B*" -and
    $_.Name -ne "amdvlk" -and
    $_.Name -ne "amdogl" -and
	$_.Name -ne "amdocl"
} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# edit xml files, set enabled & hidden to false
$xmlFiles = @(
"$env:SystemRoot\Temp\AmdDriver\Config\AMDAUEPInstaller.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDCOMPUTE.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDLinkDriverUpdate.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDRELAUNCHER.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDScoSupportTypeUpdate.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDUpdater.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\AMDUWPLauncher.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\EnableWindowsDriverSearch.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\InstallUEP.xml"
"$env:SystemRoot\Temp\AmdDriver\Config\ModifyLinkUpdate.xml"
)
foreach ($file in $xmlFiles) {
if (Test-Path $file) {
$content = Get-Content $file -Raw
$content = $content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>'
$content = $content -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
Set-Content $file -Value $content -NoNewline
}
}

# edit json files, set installbydefault to no
$jsonFiles = @(
"$env:SystemRoot\Temp\AmdDriver\Config\InstallManifest.json"
"$env:SystemRoot\Temp\AmdDriver\Bin64\cccmanifest_64.json"
)
foreach ($file in $jsonFiles) {
if (Test-Path $file) {
$content = Get-Content $file -Raw
$content = $content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
Set-Content $file -Value $content -NoNewline
}
}

        Write-Host "INSTALLING DRIVER`n"

# install amd driver
if (Test-Path -LiteralPath (Join-Path $amdDriverPath 'Bin64\ATISetup.exe')) {
    Start-Process -Wait (Join-Path $amdDriverPath 'Bin64\ATISetup.exe') -ArgumentList '-INSTALL -VIEW:2' -WindowStyle Hidden
} else { throw 'AMD ATISetup.exe was not found after extraction.' }

# delete amdnoisesuppression startup
cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\Run`" /v `"AMDNoiseSuppression`" /f >nul 2>&1"

# delete startrsx startup
cmd /c "reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"StartRSX`" /f >nul 2>&1"

# delete startcn task
Unregister-ScheduledTask -TaskName "StartCN" -Confirm:$false -ErrorAction SilentlyContinue

# delete amd audio coprocessr dsp driver
cmd /c "sc stop `"amdacpbus`" >nul 2>&1"
cmd /c "sc delete `"amdacpbus`" >nul 2>&1"

# delete amd streaming audio function driver
cmd /c "sc stop `"AMDSAFD`" >nul 2>&1"
cmd /c "sc delete `"AMDSAFD`" >nul 2>&1"

# delete amd function driver for hd audio service driver
cmd /c "sc stop `"AtiHDAudioService`" >nul 2>&1"
cmd /c "sc delete `"AtiHDAudioService`" >nul 2>&1"

# delete amd bug report tool
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null

# uninstall amd install manager
$findamdinstallmanager = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
$amdinstallmanager = Get-ItemProperty $findamdinstallmanager -ErrorAction SilentlyContinue |
Where-Object { $_.DisplayName -like "*AMD Install Manager*" }
if ($amdinstallmanager) {
$guid = $amdinstallmanager.PSChildName
Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
}

# delete download
Remove-CwsPathIfPresent -LiteralPath $InstallFile

# cleaner start menu shortcut path
$folderName = "AMD Software$([char]0xA789) Adrenalin Edition"
Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$folderName\$folderName.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$folderName" -Recurse -Force -ErrorAction SilentlyContinue

# delete old driver files
Remove-CwsPathIfPresent -LiteralPath "$env:SystemDrive\AMD" -Recurse

# wait incase driver timeout or installer bugs

        80..0 | % { Write-Host "`rIMPORTING SETTINGS $_   " -NoNewline; Start-Sleep 1 }; Write-Host "`n"

# open & close amd software adrenalin edition settings page so settings stick
Start-Process "C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
Start-Sleep -Seconds 30
Stop-Process -Name "RadeonSoftware" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# import amd software adrenalin edition settings
# system
# manual check for updates
cmd /c "reg add `"HKCU\Software\AMD\CN`" /v `"AutoUpdate`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# graphics
# graphics profile - custom
cmd /c "reg add `"HKCU\Software\AMD\CN`" /v `"WizardProfile`" /t REG_SZ /d `"PROFILE_CUSTOM`" /f >nul 2>&1"

# wait for vertical refresh - always off
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "UMD" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"VSyncControl`" /t REG_BINARY /d `"3000`" /f >nul 2>&1"
}

# texture filtering quality - performance
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "UMD" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"TFQ`" /t REG_BINARY /d `"3200`" /f >nul 2>&1"
}

# tessellation mode - override application settings
# maximum tessellation level - off
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "UMD" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"Tessellation`" /t REG_BINARY /d `"3100`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"Tessellation_OPTION`" /t REG_BINARY /d `"3200`" /f >nul 2>&1"
}

# display
# accept custom resolution eula
cmd /c "reg add `"HKCU\Software\AMD\CN\CustomResolutions`" /v `"EulaAccepted`" /t REG_SZ /d `"true`" /f >nul 2>&1"

# accept overrides eula
cmd /c "reg add `"HKCU\Software\AMD\CN\DisplayOverride`" /v `"EulaAccepted`" /t REG_SZ /d `"true`" /f >nul 2>&1"

# disable hdcp support
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$edidKeysWithSuffix = $allKeys | Where-Object { $_.PSChildName -match '^EDID_[A-F0-9]+_[A-F0-9]+_[A-F0-9]+$' }
foreach ($edidKey in $edidKeysWithSuffix) {
if ($edidKey.PSChildName -match '^(EDID_[A-F0-9]+_[A-F0-9]+)_[A-F0-9]+$') {
$baseEdidName = $matches[1]
$parentPath = Split-Path $edidKey.PSPath
$baseEdidPath = Join-Path $parentPath $baseEdidName
if (!(Test-Path $baseEdidPath)) {
New-Item -Path $baseEdidPath -Force -ErrorAction SilentlyContinue | Out-Null
}   
$optionPathNew = Join-Path $baseEdidPath "Option"
if (!(Test-Path $optionPathNew)) {
New-Item -Path $optionPathNew -Force -ErrorAction SilentlyContinue | Out-Null
}
$regPath = $optionPathNew.Replace('Microsoft.PowerShell.Core\Registry::', '').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
cmd /c "reg add `"$regPath`" /v `"All_nodes`" /t REG_BINARY /d `"50726F74656374696F6E436F6E74726F6C00`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"default`" /t REG_BINARY /d `"64`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"ProtectionControl`" /t REG_BINARY /d `"0100000001000000`" /f >nul 2>&1"
}
}

# vari-bright - maximize brightness
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "power_v1" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"abmlevel`" /t REG_BINARY /d `"00000000`" /f >nul 2>&1"
}

# preferences
# disable system tray menu
cmd /c "reg add `"HKCU\Software\AMD\CN`" /v `"SystemTray`" /t REG_SZ /d `"false`" /f >nul 2>&1"

# disable toast notifications
cmd /c "reg add `"HKCU\Software\AMD\CN`" /v `"CN_Hide_Toast_Notification`" /t REG_SZ /d `"true`" /f >nul 2>&1"

# disable animation & effects
cmd /c "reg add `"HKCU\Software\AMD\CN`" /v `"AnimationEffect`" /t REG_SZ /d `"false`" /f >nul 2>&1"

# notifications - remove
cmd /c "reg delete `"HKCU\Software\AMD\CN\Notification`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\AMD\CN\Notification`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\AMD\CN\FreeSync`" /v `"AlreadyNotified`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\AMD\CN\OverlayNotification`" /v `"AlreadyNotified`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Software\AMD\CN\VirtualSuperResolution`" /v `"AlreadyNotified`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

        break MainLoop

          }
    	3 {

        Clear-Host
        
        Write-Host "DOWNLOAD INTEL GPU DRIVER`n" -ForegroundColor Yellow
		## explorer "https://www.intel.com/content/www/us/en/search.html#sortCriteria=%40lastmodifieddt%20descending&f-operatingsystem_en=Windows%2011%20Family*&f-downloadtype=Drivers&cf-tabfilter=Downloads&cf-downloadsppth=Graphics"
		## shell:appsFolder\AppUp.IntelGraphicsExperience_8j3eq9eme6ctt!App
		## C:\Program Files\Intel\Intel Graphics Software\IntelGraphicsSoftware.exe

# open the official Intel driver page in the default browser
$intelDriverUrl = 'https://www.intel.com/content/www/us/en/download-center/home.html'
Start-Process $intelDriverUrl
Read-Host 'Download the correct Intel graphics driver, then press Enter to select the downloaded installer'

        Write-Host "SELECT DOWNLOADED DRIVER`n" -ForegroundColor Yellow

$InstallFile = Show-ModernFilePicker -Mode File
if ([string]::IsNullOrWhiteSpace($InstallFile) -or -not (Test-Path -LiteralPath $InstallFile)) {
    Add-CwsWarning 'No Intel driver installer was selected. Intel installation was skipped.'
    break
}

$sevenZipExe = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZipExe)) { throw '7-Zip is required to extract the Intel driver.' }
$intelDriverPath = Join-Path $env:SystemDrive 'IntelDriver'
Remove-CwsPathIfPresent -LiteralPath $intelDriverPath -Recurse
& $sevenZipExe x $InstallFile "-o$intelDriverPath" -y | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $intelDriverPath 'Installer.exe'))) {
    throw 'The Intel driver could not be extracted or Installer.exe was not found.'
}

        Write-Host "DEBLOATING DRIVER`n"

        Write-Host "INSTALLING DRIVER`n"

# install intel driver
Start-Process 'cmd.exe' -ArgumentList "/c `"$intelDriverPath\Installer.exe`" -f --noExtras --terminateProcesses -s" -WindowStyle Hidden -Wait

# install intel control panel
$IntelGraphicsSoftware = Get-ChildItem (Join-Path $intelDriverPath 'Resources\Extras\IntelGraphicsSoftware_*.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
if ($IntelGraphicsSoftware) {
Start-Process $IntelGraphicsSoftware.FullName -ArgumentList '/s' -Wait -NoNewWindow
}

# delete intel® graphics software startup
$FileName = "Intel$([char]0xAE) Graphics Software"
cmd /c "reg delete `"HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`" /v `"$FileName`" /f >nul 2>&1"

# delete intelgfxfwupdatetool service
cmd /c "sc stop `"IntelGFXFWupdateTool`" >nul 2>&1"
cmd /c "sc delete `"IntelGFXFWupdateTool`" >nul 2>&1"

# delete intel® content protection hdcp service
cmd /c "sc stop `"cplspcon`" >nul 2>&1"
cmd /c "sc delete `"cplspcon`" >nul 2>&1"

# delete intel(r) cta child driver driver
cmd /c "sc stop `"CtaChildDriver`" >nul 2>&1"
cmd /c "sc delete `"CtaChildDriver`" >nul 2>&1"

# delete intel(r) graphics system controller auxiliary firmware interface driver
cmd /c "sc stop `"GSCAuxDriver`" >nul 2>&1"
cmd /c "sc delete `"GSCAuxDriver`" >nul 2>&1"

# delete intel(r) graphics system controller firmware interface driver
cmd /c "sc stop `"GSCx64`" >nul 2>&1"
cmd /c "sc delete `"GSCx64`" >nul 2>&1"

# stop intelgraphicssoftware presentmonservice running
$stop = "IntelGraphicsSoftware", "PresentMonService"
$stop | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# delete presentmonservice.exe
Remove-Item "$env:SystemDrive\Program Files\Intel\Intel Graphics Software\PresentMonService.exe" -Force -ErrorAction SilentlyContinue | Out-Null 

# delete download
Remove-CwsPathIfPresent -LiteralPath $InstallFile

# cleaner start menu shortcut path
$FileName = "Intel$([char]0xAE) Graphics Software"
Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Intel\Intel Graphics Software\$FileName.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Intel" -Recurse -Force -ErrorAction SilentlyContinue

# delete old driver files
Remove-Item "$env:SystemDrive\Intel" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\IntelDriver" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Host "IMPORTING SETTINGS`n"

# create 3dkeys key
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$adapterKeys = Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue
foreach ($key in $adapterKeys) {
if ($key.PSChildName -match '^\d{4}$') {
$regPath = $key.Name
cmd /c "reg add `"$regPath\3DKeys`" /f >nul 2>&1"
}
}

# display
# variable refresh rate mode - disabled
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "3DKeys" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"Global_VRRWindowedBLT`" /t REG_DWORD /d `"2`" /f >nul 2>&1"
}

# variable refresh rate - disabled
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$adapterKeys = Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue
foreach ($key in $adapterKeys) {
if ($key.PSChildName -match '^\d{4}$') {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"AdaptiveVsyncEnableUserSetting`" /t REG_BINARY /d `"00000000`" /f >nul 2>&1"
}
}

# graphics
# frame synchronization - vsync off
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "3DKeys" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"Global_AsyncFlipMode`" /t REG_DWORD /d `"2`" /f >nul 2>&1"
}

# low latency mode - off
$basePath = "HKLM:\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$allKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
$optionKeys = $allKeys | Where-Object { $_.PSChildName -eq "3DKeys" }
foreach ($key in $optionKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"Global_LowLatency`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

        break MainLoop

          }
        4 {

        Clear-Host

        break MainLoop

          }
          }
          } else {
          Write-Host "Invalid input. Please select a valid option (1-4).`n" -ForegroundColor Yellow
          Pause
          Show-Menu
          }
          }

        Clear-Host
        Write-Host "SET" -ForegroundColor Yellow
        Write-Host "- SOUND" -ForegroundColor Yellow
        Write-Host "- RESOLUTION" -ForegroundColor Yellow
        Write-Host "- REFRESH RATE" -ForegroundColor Yellow
        Write-Host "- PRIMARY DISPLAY`n" -ForegroundColor Yellow
		## shell:appsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel
    	## ms-settings:display
		## mmsys.cpl

# open display, nvidia & sound panels
try {
Start-Process "ms-settings:display"
} catch { }
try {
Start-Process shell:appsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel
} catch { }
Start-Process mmsys.cpl
Read-Host 'Configure display and sound settings if needed, then press Enter to continue'

        Clear-Host

# disable automatically manage color for apps
$basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore"
$monitorKeys = Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue
foreach ($key in $monitorKeys) {
$regPath = $key.Name
cmd /c "reg add `"$regPath`" /v `"AutoColorManagementEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"$regPath`" /v `"AutoColorManagementSupported`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
}

# reapply for nvidia cards after changing resolution
# turn on no scaling for all displays
$configKeys = Get-ChildItem -Path "HKLM:\System\CurrentControlSet\Control\GraphicsDrivers\Configuration" -Recurse -ErrorAction SilentlyContinue
foreach ($key in $configKeys) {
try {
$scalingProperties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
} catch {
continue
}
if ($scalingProperties.PSObject.Properties.Name -contains 'Scaling') {
$regPath = $key.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', '').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
Invoke-CwsRegExe -Arguments ("add `"{0}`" /v Scaling /t REG_DWORD /d 2 /f" -f $regPath) | Out-Null
}
}

# enable msi mode for all gpus
$gpuDevices = Get-PnpDevice -Class Display
foreach ($gpu in $gpuDevices) {
$instanceID = $gpu.InstanceId
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Enum\$instanceID\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties`" /v `"MSISupported`" /t REG_DWORD /d `"1`" /f >nul 2>&1"
}

        Write-Host "POWER PLAN`n"
        ## powercfg.cpl

function Get-CwsGuidFromText {
    param([string]$Text)
    $match = [regex]::Match([string]$Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($match.Success) { return $match.Value }
    return $null
}

function New-CwsUltimatePerformancePlan {
    $planName = 'ItsMauridian Ultimate Performance'
    $listResult = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/list') -TimeoutSeconds 30
    foreach ($line in ($listResult.Output -split "`r?`n")) {
        if ($line -like "*$planName*") {
            $existingGuid = Get-CwsGuidFromText -Text $line
            if ($existingGuid) {
                $activate = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/setactive',$existingGuid) -TimeoutSeconds 30
                if ($activate.ExitCode -eq 0) { return $existingGuid }
            }
        }
    }

    $createdGuid = $null
    $nativeUltimate = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/duplicatescheme','e9a42b02-d5df-448d-aa00-03f14749eb61') -TimeoutSeconds 30
    if ($nativeUltimate.ExitCode -eq 0) {
        $createdGuid = Get-CwsGuidFromText -Text ($nativeUltimate.Output + "`n" + $nativeUltimate.Error)
        if ($createdGuid) {
            Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/changename',$createdGuid,"`"$planName`"",'"Maximum AC performance with laptop-safe DC settings"') -TimeoutSeconds 30 | Out-Null
            $activate = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/setactive',$createdGuid) -TimeoutSeconds 30
            if ($activate.ExitCode -eq 0) { return $createdGuid }
            Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/delete',$createdGuid) -TimeoutSeconds 30 | Out-Null
            $createdGuid = $null
        }
    }

    # Modern Standby systems can reject the native Ultimate template. A duplicate
    # of Balanced remains activatable and can still receive the performance values.
    $fallback = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/duplicatescheme','381b4222-f694-41f0-9685-ff5bb260df2e') -TimeoutSeconds 30
    if ($fallback.ExitCode -eq 0) {
        $createdGuid = Get-CwsGuidFromText -Text ($fallback.Output + "`n" + $fallback.Error)
        if ($createdGuid) {
            Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/changename',$createdGuid,"`"$planName`"",'"Modern Standby compatible performance plan"') -TimeoutSeconds 30 | Out-Null
            $activate = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/setactive',$createdGuid) -TimeoutSeconds 30
            if ($activate.ExitCode -eq 0) {
                Add-CwsNote 'The performance plan uses a Balanced-derived fallback for Modern Standby compatibility.'
                return $createdGuid
            }
        }
    }
    return $null
}

$cwsPowerScheme = 'SCHEME_CURRENT'
if (Get-CwsOption -Name 'InstallUltimatePerformancePlan' -Default $true) {
    $createdPowerPlan = New-CwsUltimatePerformancePlan
    if ($createdPowerPlan) {
        $cwsPowerScheme = $createdPowerPlan
        Add-CwsNote "Active performance plan GUID: $cwsPowerScheme."
    } else {
        Add-CwsWarning 'A dedicated performance plan could not be activated. The current plan was preserved.'
    }
} else {
    Add-CwsNote 'Custom performance plan creation was not selected.'
}

# AC power: maximum performance. DC power: responsive but battery-safe.
$powerSettings = @(
    @{ Mode='AC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='893dee8e-2bef-41e0-89c6-b55d0929964c'; Value='100' },
    @{ Mode='AC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='bc5038f7-23e0-4960-96da-33abaf5935ec'; Value='100' },
    @{ Mode='AC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Value='0' },
    @{ Mode='AC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='0cc5b647-c1df-4637-891a-dec35c318583'; Value='100' },
    @{ Mode='DC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='893dee8e-2bef-41e0-89c6-b55d0929964c'; Value='5' },
    @{ Mode='DC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='bc5038f7-23e0-4960-96da-33abaf5935ec'; Value='100' },
    @{ Mode='DC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Value='50' },
    @{ Mode='DC'; Sub='54533251-82be-4824-96c1-47b60b740d00'; Setting='0cc5b647-c1df-4637-891a-dec35c318583'; Value='10' },
    @{ Mode='AC'; Sub='501a4d13-42af-4429-9fd1-a8218c268e20'; Setting='ee12f906-d277-404b-b6da-e5fa1a576df5'; Value='0' },
    @{ Mode='DC'; Sub='501a4d13-42af-4429-9fd1-a8218c268e20'; Setting='ee12f906-d277-404b-b6da-e5fa1a576df5'; Value='1' },
    @{ Mode='AC'; Sub='2a737441-1930-4402-8d77-b2bebba308a3'; Setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value='0' },
    @{ Mode='DC'; Sub='2a737441-1930-4402-8d77-b2bebba308a3'; Setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value='1' },
    @{ Mode='AC'; Sub='19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting='12bbebe6-58d6-4636-95bb-3217ef867c1a'; Value='0' },
    @{ Mode='DC'; Sub='19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting='12bbebe6-58d6-4636-95bb-3217ef867c1a'; Value='2' },
    @{ Mode='AC'; Sub='0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting='6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value='0' },
    @{ Mode='DC'; Sub='0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting='6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value='1200' },
    @{ Mode='AC'; Sub='238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting='29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Value='0' },
    @{ Mode='DC'; Sub='238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting='29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Value='1800' },
    @{ Mode='AC'; Sub='7516b95f-f776-4464-8c53-06167f40cc99'; Setting='3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Value='600' },
    @{ Mode='DC'; Sub='7516b95f-f776-4464-8c53-06167f40cc99'; Setting='3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Value='300' },
    @{ Mode='AC'; Sub='7516b95f-f776-4464-8c53-06167f40cc99'; Setting='fbd9aa66-9553-4097-ba44-ed6e9d65eab8'; Value='0' },
    @{ Mode='DC'; Sub='7516b95f-f776-4464-8c53-06167f40cc99'; Setting='fbd9aa66-9553-4097-ba44-ed6e9d65eab8'; Value='1' }
)
foreach ($powerSetting in $powerSettings) {
    Set-CwsPowerSetting -Mode $powerSetting.Mode -Scheme $cwsPowerScheme -Subgroup $powerSetting.Sub -Setting $powerSetting.Setting -Value $powerSetting.Value | Out-Null
}
if ($cwsPowerScheme -ne 'SCHEME_CURRENT') {
    Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/setactive',$cwsPowerScheme) -TimeoutSeconds 30 | Out-Null
}
Set-CwsRegistryDword -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 | Out-Null

if (Get-CwsOption -Name 'EnableExperimentalTimerTweaks' -Default $false) {
        Write-Host "TIMER RESOLUTION`n"
        ## services.msc

# create .cs file
$csfile = @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.ComponentModel;
using System.Configuration.Install;
using System.Collections.Generic;
using System.Reflection;
using System.IO;
using System.Management;
using System.Threading;
using System.Diagnostics;
[assembly: AssemblyVersion("2.1")]
[assembly: AssemblyProduct("Set Timer Resolution service")]
namespace WindowsService
{
    class WindowsService : ServiceBase
    {
        public WindowsService()
        {
            this.ServiceName = "STR";
            this.EventLog.Log = "Application";
            this.CanStop = true;
            this.CanHandlePowerEvent = false;
            this.CanHandleSessionChangeEvent = false;
            this.CanPauseAndContinue = false;
            this.CanShutdown = false;
        }
        static void Main()
        {
            ServiceBase.Run(new WindowsService());
        }
        protected override void OnStart(string[] args)
        {
            base.OnStart(args);
            ReadProcessList();
            NtQueryTimerResolution(out this.MinimumResolution, out this.MaximumResolution, out this.DefaultResolution);
            if(null != this.EventLog)
                try { this.EventLog.WriteEntry(String.Format("Minimum={0}; Maximum={1}; Default={2}; Processes='{3}'", this.MinimumResolution, this.MaximumResolution, this.DefaultResolution, null != this.ProcessesNames ? String.Join("','", this.ProcessesNames) : "")); }
                catch {}
            if(null == this.ProcessesNames)
            {
                SetMaximumResolution();
                return;
            }
            if(0 == this.ProcessesNames.Count)
            {
                return;
            }
            this.ProcessStartDelegate = new OnProcessStart(this.ProcessStarted);
            try
            {
                String query = String.Format("SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE (TargetInstance isa \"Win32_Process\") AND (TargetInstance.Name=\"{0}\")", String.Join("\" OR TargetInstance.Name=\"", this.ProcessesNames));
                this.startWatch = new ManagementEventWatcher(query);
                this.startWatch.EventArrived += this.startWatch_EventArrived;
                this.startWatch.Start();
            }
            catch(Exception ee)
            {
                if(null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Error); }
                    catch {}
            }
        }
        protected override void OnStop()
        {
            if(null != this.startWatch)
            {
                this.startWatch.Stop();
            }

            base.OnStop();
        }
        ManagementEventWatcher startWatch;
        void startWatch_EventArrived(object sender, EventArrivedEventArgs e) 
        {
            try
            {
                ManagementBaseObject process = (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                UInt32 processId = (UInt32)process.Properties["ProcessId"].Value;
                this.ProcessStartDelegate.BeginInvoke(processId, null, null);
            } 
            catch(Exception ee) 
            {
                if(null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}

            }
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern Int32 WaitForSingleObject(IntPtr Handle, Int32 Milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(UInt32 DesiredAccess, Int32 InheritHandle, UInt32 ProcessId);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern Int32 CloseHandle(IntPtr Handle);
        const UInt32 SYNCHRONIZE = 0x00100000;
        delegate void OnProcessStart(UInt32 processId);
        OnProcessStart ProcessStartDelegate = null;
        void ProcessStarted(UInt32 processId)
        {
            SetMaximumResolution();
            IntPtr processHandle = IntPtr.Zero;
            try
            {
                processHandle = OpenProcess(SYNCHRONIZE, 0, processId);
                if(processHandle != IntPtr.Zero)
                    WaitForSingleObject(processHandle, -1);
            } 
            catch(Exception ee) 
            {
                if(null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}
            }
            finally
            {
                if(processHandle != IntPtr.Zero)
                    CloseHandle(processHandle); 
            }
            SetDefaultResolution();
        }
        List<String> ProcessesNames = null;
        void ReadProcessList()
        {
            String iniFilePath = Assembly.GetExecutingAssembly().Location + ".ini";
            if(File.Exists(iniFilePath))
            {
                this.ProcessesNames = new List<String>();
                String[] iniFileLines = File.ReadAllLines(iniFilePath);
                foreach(var line in iniFileLines)
                {
                    String[] names = line.Split(new char[] {',', ' ', ';'} , StringSplitOptions.RemoveEmptyEntries);
                    foreach(var name in names)
                    {
                        String lwr_name = name.ToLower();
                        if(!lwr_name.EndsWith(".exe"))
                            lwr_name += ".exe";
                        if(!this.ProcessesNames.Contains(lwr_name))
                            this.ProcessesNames.Add(lwr_name);
                    }
                }
            }
        }
        [DllImport("ntdll.dll", SetLastError=true)]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
        [DllImport("ntdll.dll", SetLastError=true)]
        static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint ActualResolution);
        uint DefaultResolution = 0;
        uint MinimumResolution = 0;
        uint MaximumResolution = 0;
        long processCounter = 0;
        void SetMaximumResolution()
        {
            long counter = Interlocked.Increment(ref this.processCounter);
            if(counter <= 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.MaximumResolution, true, out actual);
                if(null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }
        void SetDefaultResolution()
        {
            long counter = Interlocked.Decrement(ref this.processCounter);
            if(counter < 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.DefaultResolution, true, out actual);
                if(null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }
    }
    [RunInstaller(true)]
    public class WindowsServiceInstaller : Installer
    {
        public WindowsServiceInstaller()
        {
            ServiceProcessInstaller serviceProcessInstaller = 
                               new ServiceProcessInstaller();
            ServiceInstaller serviceInstaller = new ServiceInstaller();
            serviceProcessInstaller.Account = ServiceAccount.LocalSystem;
            serviceProcessInstaller.Username = null;
            serviceProcessInstaller.Password = null;
            serviceInstaller.DisplayName = "Set Timer Resolution Service";
            serviceInstaller.StartType = ServiceStartMode.Automatic;
            serviceInstaller.ServiceName = "STR";
            this.Installers.Add(serviceProcessInstaller);
            this.Installers.Add(serviceInstaller);
        }
    }
}
'@
Set-Content -Path "$env:SystemDrive\Windows\SetTimerResolutionService.cs" -Value $csfile -Force

# compile and create service
Start-Process -Wait "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -ArgumentList "-out:C:\Windows\SetTimerResolutionService.exe C:\Windows\SetTimerResolutionService.cs" -WindowStyle Hidden

# remove cs file
Remove-Item "$env:SystemDrive\Windows\SetTimerResolutionService.cs" -ErrorAction SilentlyContinue | Out-Null

# remove old service if exists
if (Get-Service -Name "STR" -ErrorAction SilentlyContinue) {
    Stop-Service -Name "STR" -Force -ErrorAction SilentlyContinue | Out-Null
    sc.exe delete "STR" | Out-Null
    # wait for SCM to fully release the service before recreating
    $timeout = 30
    while ((Get-Service -Name "STR" -ErrorAction SilentlyContinue) -and $timeout -gt 0) {
        Start-Sleep -Seconds 1
        $timeout--
    }
    Start-Sleep -Seconds 2
}

# install and start service only if exe was successfully compiled
if (Test-Path "$env:SystemDrive\Windows\SetTimerResolutionService.exe") {
    New-Service -Name "STR" -DisplayName "Set Timer Resolution Service" -BinaryPathName "$env:SystemDrive\Windows\SetTimerResolutionService.exe" -ErrorAction SilentlyContinue | Out-Null
    Set-Service -Name "STR" -StartupType Auto -ErrorAction SilentlyContinue | Out-Null
    Set-Service -Name "STR" -Status Running -ErrorAction SilentlyContinue | Out-Null
}

# enable global timer resolution requests
cmd /c "reg add `"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel`" /v `"GlobalTimerResolutionRequests`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# disable hpet
cmd /c "bcdedit /deletevalue useplatformclock >nul 2>&1"
cmd /c "bcdedit /set useplatformtick yes >nul 2>&1"
cmd /c "bcdedit /set disabledynamictick yes >nul 2>&1"

} else {
    Add-CwsNote 'Experimental timer service and BCD timer changes were skipped.'
}

# rebuild performance counters
        ## perfmon.msc
cmd /c "cd /d %systemroot%\system32 && lodctr /R >nul 2>&1"
cmd /c "cd /d %systemroot%\sysWOW64 && lodctr /R >nul 2>&1"

# Late AppX cleanup is intentionally omitted. The explicit package list above is the single source of truth.

            Write-Host "DISK CLEANUP`n"
		## cleanmgr.exe
		## %temp%
		## temp

# clear user temp while preserving files currently locked by running applications
Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Temp" -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# clear Windows temp selectively. Preserve this script, transcript and handoff files while StepTwo is running.
$protectedTempNames = @('CWS-StepTwo.log', 'StepOne.ps1', 'StepTwo.ps1', 'DDU.ps1', 'DDU.path')
Get-ChildItem -LiteralPath "$env:SystemRoot\Temp" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $protectedTempNames } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

try { Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/autoclean /d C:' -Wait -WindowStyle Hidden -ErrorAction Stop } catch { }

foreach ($cleanupPath in @(
    "$env:SystemDrive\inetpub",
    "$env:SystemDrive\PerfLogs",
    "$env:SystemDrive\XboxGames",
    "$env:SystemDrive\Windows.old",
    "$env:SystemDrive\DumpStack.log"
)) {
    Remove-CwsPathIfPresent -LiteralPath $cleanupPath -Recurse
}

        Write-Host "RESTORE POINT`n"
try {
    cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`" /v `"SystemRestorePointCreationFrequency`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue | Out-Null
    Checkpoint-Computer -Description 'After Custom Windows Setup' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue | Out-Null
    cmd /c "reg delete `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`" /v `"SystemRestorePointCreationFrequency`" /f >nul 2>&1"
} catch { Add-CwsWarning "Final restore point was not created: $($_.Exception.Message)" }

        Write-Host "RESTARTING`n" -ForegroundColor Red

# Mark the main flow complete before removing resume handoff entries.
$cwsWorkRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
try { Set-Content -Path (Join-Path $cwsWorkRoot 'StepTwo.completed') -Value (Get-Date -Format o) -Encoding ASCII -Force } catch { }

# Remove the resume handoff before verification so the report reflects the final state.
try { Unregister-ScheduledTask -TaskName 'ItsMauridian-Custom-Windows-Setup-StepTwo' -TaskPath '\ItsMauridian\' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
try { Unregister-ScheduledTask -TaskName 'ItsMauridian-Custom-Windows-Setup-StepTwo' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!ItsMauridian-StepTwo' -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ItsMauridian-StepTwoResume' -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!StepTwo' -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!StepTwo' -ErrorAction SilentlyContinue } catch { }

# Restore the supported Windows performance and security baseline one final time after
# all installers have completed. Some vendor installers can alter these settings.
try { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null } catch { Add-CwsWarning "Memory compression could not be enabled: $($_.Exception.Message)" }
try {
    Set-Service -Name 'SysMain' -StartupType Automatic -ErrorAction Stop
    Start-Service -Name 'SysMain' -ErrorAction SilentlyContinue
} catch { Add-CwsWarning "SysMain could not be restored: $($_.Exception.Message)" }
$hibernateResult = Invoke-CwsNativeCommand -FilePath powercfg.exe -ArgumentList @('/hibernate','on') -TimeoutSeconds 30
if ($hibernateResult.ExitCode -ne 0) { Add-CwsWarning 'Hibernation could not be enabled.' }
Set-CwsRegistryDword -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 | Out-Null

# Reapply and read back critical policies after all installers and Windows components
# have finished, then persist the final app result arrays.
Apply-CwsPrivacyProfile -FinalPass
try {
    [pscustomobject]@{
        GeneratedAt = (Get-Date -Format o)
        Selected = $selectedApps
        Verified = @($verifiedApps | Select-Object -Unique)
        Unverified = @($unverifiedApps | Select-Object -Unique)
        Failed = @($failedApps | Select-Object -Unique)
        Manual = @($manualApps | Select-Object -Unique)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $cwsWorkRoot 'AppInstallResults.json') -Encoding UTF8 -Force
} catch { }

$verifyScriptPath = Join-Path $cwsWorkRoot 'Verify-Setup.ps1'
if (Test-Path -LiteralPath $verifyScriptPath) {
    try {
        $verifyProcess = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifyScriptPath) -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($verifyProcess.ExitCode -ne 0) { Add-CwsWarning "Verification report returned exit code $($verifyProcess.ExitCode)." }
    } catch {
        Add-CwsWarning ("Verification report could not be generated: {0}" -f $_.Exception.Message)
    }
}

# Write a concise, categorized log. The detailed transcript remains in C:\Windows\Temp.
$logPath = "$env:USERPROFILE\Desktop\WinSux-Setup-Log.txt"
$logContent = @(
    "WinSux Setup Log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    ('=' * 60),
    "Detailed transcript: $CwsStepTwoLog",
    ''
)

if ($failedApps.Count -gt 0) {
    $logContent += 'Failed winget installs:'
    foreach ($failed in $failedApps) { $logContent += "[WINGET] $failed" }
    $logContent += ''
} else {
    $logContent += 'No WinGet installer returned a failure exit code.'
    $logContent += ''
}

if ($unverifiedApps.Count -gt 0) {
    $logContent += 'Completed but not yet verified by winget list:'
    foreach ($unverified in $unverifiedApps) { $logContent += "[UNVERIFIED] $unverified" }
    $logContent += ''
} else {
    $logContent += 'All successful WinGet installs were verified.'
    $logContent += ''
}

if ($script:skippedPowerSettings -gt 0) {
    $setupNotes += "$script:skippedPowerSettings unsupported hardware-specific power settings were skipped."
}

if ($setupNotes.Count -gt 0) {
    $logContent += 'Notes:'
    foreach ($note in $setupNotes) { $logContent += "[NOTE] $note" }
    $logContent += ''
}

if ($setupWarnings.Count -gt 0) {
    $logContent += 'Warnings:'
    foreach ($warning in $setupWarnings) { $logContent += "[WARNING] $warning" }
    $logContent += ''
}

if ($fatalErrors.Count -gt 0) {
    $logContent += 'Fatal errors:'
    foreach ($fatal in $fatalErrors) { $logContent += "[FATAL] $fatal" }
} else {
    $logContent += 'Setup reached the final stage without a fatal PowerShell error.'
}

$logContent | Out-File -FilePath $logPath -Encoding UTF8 -Force

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

# restart
Start-Sleep -Seconds 5
shutdown -r -t 00
