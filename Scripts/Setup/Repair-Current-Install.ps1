# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability16 2026-07-11 - explicit 64-bit registry repair and diagnostics
$ErrorActionPreference = 'Continue'

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $nativePowerShell) {
        Start-Process -FilePath $nativePowerShell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath)) -Verb RunAs -Wait
        exit $LASTEXITCODE
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host 'Run this script from an elevated Administrator PowerShell window.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

$workRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
$desktop = [Environment]::GetFolderPath('Desktop')
$logPath = Join-Path $desktop 'CWS-Reliability16-Repair-Log.txt'
$notes = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$details = New-Object System.Collections.Generic.List[string]
function Add-RepairNote { param([string]$Message) [void]$notes.Add($Message); Write-Host "[NOTE] $Message" -ForegroundColor Cyan }
function Add-RepairWarning { param([string]$Message) [void]$warnings.Add($Message); Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Add-RepairDetail { param([string]$Message) [void]$details.Add($Message); Write-Host "  $Message" -ForegroundColor DarkGray }

function Resolve-RegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '(?i)^HKLM:\\(.+)$') { return [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; SubKey=$matches[1] } }
    if ($Path -match '(?i)^HKCU:\\(.+)$') { return [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser; SubKey=$matches[1] } }
    throw "Unsupported registry path: $Path"
}
function Get-RegistryView64 { if ([Environment]::Is64BitOperatingSystem) { return [Microsoft.Win32.RegistryView]::Registry64 }; return [Microsoft.Win32.RegistryView]::Default }
function Get-RegistryValue64 {
    param([string]$Path,[string]$Name)
    $baseKey=$null; $key=$null
    try {
        $resolved=Resolve-RegistryPath -Path $Path
        $baseKey=[Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive,(Get-RegistryView64))
        $key=$baseKey.OpenSubKey($resolved.SubKey,$false)
        if (-not $key) { return $null }
        return $key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { if ($key) {$key.Dispose()}; if ($baseKey) {$baseKey.Dispose()} }
}
function Set-RegistryValue64 {
    param([string]$Path,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind)
    $baseKey=$null; $key=$null
    try {
        $resolved=Resolve-RegistryPath -Path $Path
        $baseKey=[Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive,(Get-RegistryView64))
        $key=$baseKey.CreateSubKey($resolved.SubKey)
        if (-not $key) { throw 'Registry key could not be opened for writing.' }
        $key.SetValue($Name,$Value,$Kind)
        $key.Flush()
        $actual=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) {
            $ok=((@($actual) -join "`n") -eq (@($Value) -join "`n"))
        } else { $ok=($null -ne $actual -and [int]$actual -eq [int]$Value) }
        if (-not $ok) { throw "Readback mismatch. Expected $Value, found $actual." }
        Add-RepairDetail ("OK {0}\{1} = {2}" -f $Path,$Name,(@($actual) -join '; '))
        return $true
    } catch {
        Add-RepairWarning ("FAILED {0}\{1}: {2}" -f $Path,$Name,$_.Exception.Message)
        return $false
    } finally { if ($key) {$key.Dispose()}; if ($baseKey) {$baseKey.Dispose()} }
}

Write-Host 'RELIABILITY16 POST-INSTALL REPAIR' -ForegroundColor Cyan
$processBits = if ([Environment]::Is64BitProcess) { 64 } else { 32 }
$osBits = if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }
Write-Host ("PowerShell process: {0}-bit, Windows: {1}-bit" -f $processBits,$osBits)
Write-Host ''

$osCaption=(Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$diagnosticLevel=if ($osCaption -match 'Enterprise|Education|IoT') {0} else {1}
$settings=@(
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';Name='AllowTelemetry';Value=$diagnosticLevel},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';Name='DoNotShowFeedbackNotifications';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='AllowRecallEnablement';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='DisableAIDataAnalysis';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='DisableClickToDo';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='RemoveMicrosoftCopilotApp';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';Name='TurnOffWindowsCopilot';Value=1},
    @{Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';Name='TurnOffWindowsCopilot';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableWindowsConsumerFeatures';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableSoftLanding';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableWindowsSpotlightFeatures';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableConsumerAccountStateContent';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableThirdPartySuggestions';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableTailoredExperiencesWithDiagnosticData';Value=1},
    @{Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableCloudOptimizedContent';Value=1},
    @{Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableWindowsSpotlightFeatures';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='EnableActivityFeed';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='PublishUserActivities';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';Name='UploadUserActivities';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';Name='AllowCloudSearch';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';Name='DisableWebSearch';Value=1},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';Name='AllowNewsAndInterests';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';Name='LetAppsRunInBackground';Value=2},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';Name='DODownloadMode';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='StartupBoostEnabled';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';Name='BackgroundModeEnabled';Value=0},
    @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';Name='AllowGameDVR';Value=0}
)
foreach ($name in @('LetAppsAccessAccountInfo','LetAppsAccessCalendar','LetAppsAccessCallHistory','LetAppsAccessContacts','LetAppsAccessEmail','LetAppsAccessLocation','LetAppsAccessMessaging','LetAppsAccessMotion','LetAppsAccessPhone','LetAppsAccessRadios','LetAppsAccessTasks','LetAppsAccessTrustedDevices','LetAppsSyncWithDevices','LetAppsGetDiagnosticInfo')) {
    $settings += @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';Name=$name;Value=2}
}
foreach ($name in @('LetAppsAccessCamera','LetAppsAccessMicrophone','LetAppsAccessNotifications')) {
    $settings += @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';Name=$name;Value=0}
}
$policyFailures=0
foreach ($setting in $settings) {
    if (-not (Set-RegistryValue64 -Path $setting.Path -Name $setting.Name -Value ([int]$setting.Value) -Kind DWord)) {$policyFailures++}
}

try {
    $allowPackages=@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {$_.Name -in @('Microsoft.WindowsStore','Microsoft.DesktopAppInstaller','MicrosoftCorporationII.WindowsApp') -or $_.Name -like '*EarTrumpet*'})
    $allowPfns=@($allowPackages.PackageFamilyName | Where-Object {$_} | Sort-Object -Unique)
    if ($allowPfns.Count -gt 0) {
        if (-not (Set-RegistryValue64 -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsRunInBackground_ForceAllowTheseApps' -Value ([string[]]$allowPfns) -Kind MultiString)) {$policyFailures++}
    }
} catch { Add-RepairWarning "Background allowlist failed: $($_.Exception.Message)" }
if ($policyFailures -eq 0) { Add-RepairNote "All privacy policy writes passed immediate 64-bit readback. Diagnostic data level: $diagnosticLevel." }
else { Add-RepairWarning "$policyFailures policy values failed immediate 64-bit readback." }

try { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null; Add-RepairNote ("Memory compression requested. Current value: {0}" -f (Get-MMAgent).MemoryCompression) } catch { Add-RepairWarning "Memory compression could not be enabled: $($_.Exception.Message)" }
try { Set-Service SysMain -StartupType Automatic -ErrorAction Stop; Start-Service SysMain -ErrorAction SilentlyContinue; $svc=Get-CimInstance Win32_Service -Filter "Name='SysMain'"; Add-RepairNote ("SysMain restored: State={0}, StartMode={1}" -f $svc.State,$svc.StartMode) } catch { Add-RepairWarning "SysMain could not be restored: $($_.Exception.Message)" }
try { & powercfg.exe /hibernate on | Out-Null; if ($LASTEXITCODE -eq 0) { Add-RepairNote 'Hibernation was enabled.' } else { Add-RepairWarning "powercfg /hibernate on returned $LASTEXITCODE." } } catch { Add-RepairWarning "Hibernation could not be enabled: $($_.Exception.Message)" }
[void](Set-RegistryValue64 -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Kind DWord)

try { Unregister-ScheduledTask -TaskName 'ItsMauridian-Custom-Windows-Setup-StepTwo' -TaskPath '\ItsMauridian\' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
try { Unregister-ScheduledTask -TaskName 'ItsMauridian-Custom-Windows-Setup-StepTwo' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!ItsMauridian-StepTwo' -ErrorAction SilentlyContinue } catch { }
try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ItsMauridian-StepTwoResume' -ErrorAction SilentlyContinue } catch { }
Add-RepairNote 'StepTwo resume handoff entries were removed.'

# Preserve HVCI rather than forcing it. Capture enough state to diagnose why it changed after reboot.
$hvciPath='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
Add-RepairDetail ("HVCI Enabled={0}, WasEnabledBy={1}, EnabledBootId={2}" -f (Get-RegistryValue64 $hvciPath 'Enabled'),(Get-RegistryValue64 $hvciPath 'WasEnabledBy'),(Get-RegistryValue64 $hvciPath 'EnabledBootId'))
try {
    $dg=Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    Add-RepairDetail ("VBS status={0}; configured={1}; running={2}" -f $dg.VirtualizationBasedSecurityStatus,(@($dg.SecurityServicesConfigured)-join ','),(@($dg.SecurityServicesRunning)-join ','))
} catch { Add-RepairDetail "Device Guard runtime query unavailable: $($_.Exception.Message)" }

# Recheck prior app results, then improve Store-app verification.
$appResultsPath=Join-Path $workRoot 'AppInstallResults.json'
$winget=Get-Command winget.exe -ErrorAction SilentlyContinue
if ((Test-Path $appResultsPath) -and $winget) {
    try {
        $results=Get-Content $appResultsPath -Raw | ConvertFrom-Json
        $verified=New-Object System.Collections.Generic.List[string]
        foreach ($item in @($results.Verified)) {if ($item){[void]$verified.Add([string]$item)}}
        $unverified=New-Object System.Collections.Generic.List[string]
        foreach ($item in @($results.Unverified)) {
            $text=[string]$item
            $id=($text -replace ' \(installer returned success.*$','')
            $list=(& $winget.Source list --id $id -e --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
            $isInstalled=($LASTEXITCODE -eq 0 -and $list -match [regex]::Escape($id))
            if (-not $isInstalled -and $id -eq 'Microsoft.WindowsApp') {
                $isInstalled=[bool](Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq 'MicrosoftCorporationII.WindowsApp'})
            }
            if ($isInstalled) {[void]$verified.Add($id)} else {[void]$unverified.Add($text)}
        }
        [pscustomobject]@{GeneratedAt=(Get-Date -Format o);Selected=@($results.Selected);Verified=@($verified|Select-Object -Unique);Unverified=@($unverified|Select-Object -Unique);Failed=@($results.Failed);Manual=@($results.Manual)} | ConvertTo-Json -Depth 5 | Set-Content $appResultsPath -Encoding UTF8 -Force
        Add-RepairNote 'Application results were rechecked.'
    } catch { Add-RepairWarning "Application results could not be rechecked: $($_.Exception.Message)" }
}

$sourceVerify=Join-Path $PSScriptRoot 'Verify-Setup.ps1'
$targetVerify=Join-Path $workRoot 'Verify-Setup.ps1'
if (Test-Path $sourceVerify) { Copy-Item $sourceVerify $targetVerify -Force }
if (Test-Path $targetVerify) {
    $ps64=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $targetVerify
    Add-RepairNote 'A fresh verification report was generated.'
}

$log=@('CWS Reliability16 post-install repair',"Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",("Process: {0}-bit; OS: {1}-bit" -f $processBits,$osBits),'')
if ($notes.Count) {$log+='Notes:';$log+=@($notes|ForEach-Object{"[NOTE] $_"});$log+=''}
if ($warnings.Count) {$log+='Warnings:';$log+=@($warnings|ForEach-Object{"[WARNING] $_"});$log+=''}
if ($details.Count) {$log+='Diagnostics:';$log+=@($details|ForEach-Object{"[DETAIL] $_"});$log+=''}
$log | Out-File $logPath -Encoding UTF8 -Force
Write-Host ''; Write-Host "Repair finished. Log: $logPath" -ForegroundColor Green
Read-Host 'Press Enter to close'
