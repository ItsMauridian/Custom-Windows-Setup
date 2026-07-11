# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability16 2026-07-10 - read-only post-install verification
$ErrorActionPreference = 'Continue'
$workRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop 'CWS-Verification-Report.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text = '') [void]$lines.Add($Text) }
function Resolve-RegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '(?i)^HKLM:\\(.+)$') { return [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; SubKey=$matches[1] } }
    if ($Path -match '(?i)^HKCU:\\(.+)$') { return [pscustomobject]@{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser; SubKey=$matches[1] } }
    throw "Unsupported registry path: $Path"
}
function Read-RegValueView {
    param([string]$Path,[string]$Name,[Microsoft.Win32.RegistryView]$View)
    $baseKey=$null; $key=$null
    try {
        $resolved=Resolve-RegistryPath -Path $Path
        $baseKey=[Microsoft.Win32.RegistryKey]::OpenBaseKey($resolved.Hive,$View)
        $key=$baseKey.OpenSubKey($resolved.SubKey,$false)
        if (-not $key) { return '<missing>' }
        $value=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '<missing>' }
        return $value
    } catch { return '<missing>' }
    finally { if ($key) {$key.Dispose()}; if ($baseKey) {$baseKey.Dispose()} }
}
function Read-RegValue {
    param([string]$Path,[string]$Name)
    $view=if ([Environment]::Is64BitOperatingSystem) {[Microsoft.Win32.RegistryView]::Registry64} else {[Microsoft.Win32.RegistryView]::Default}
    return Read-RegValueView -Path $Path -Name $Name -View $view
}
function Add-Section { param([string]$Name) Add-Line ''; Add-Line ("=== {0} ===" -f $Name) }

Add-Line 'CWS Verification Report'
Add-Line ('Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('Computer: {0}' -f $env:COMPUTERNAME)
Add-Line ('Windows: {0}' -f ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption))
$processBits = if ([Environment]::Is64BitProcess) { 64 } else { 32 }
$osBits = if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }
Add-Line ('Process architecture: {0}-bit, OS architecture: {1}-bit' -f $processBits,$osBits)

Add-Section 'Setup state'
$marker = Join-Path $workRoot 'StepTwo.completed'
Add-Line ("Completion marker: {0}" -f (Test-Path -LiteralPath $marker))
Add-Line ("Options file: {0}" -f (Test-Path -LiteralPath (Join-Path $workRoot 'SetupOptions.json')))
Add-Line ("App results file: {0}" -f (Test-Path -LiteralPath (Join-Path $workRoot 'AppInstallResults.json')))
try {
    $optionsPath = Join-Path $workRoot 'SetupOptions.json'
    if (Test-Path -LiteralPath $optionsPath) {
        $options = Get-Content -LiteralPath $optionsPath -Raw | ConvertFrom-Json
        foreach ($property in $options.PSObject.Properties | Where-Object { $_.Name -ne 'CreatedAt' }) {
            Add-Line ("Option {0}: {1}" -f $property.Name,$property.Value)
        }
    }
} catch { Add-Line ("Options could not be read: {0}" -f $_.Exception.Message) }

Add-Section 'Power plan'
try { Add-Line ((& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()) } catch { Add-Line $_.Exception.Message }
try { Add-Line 'Supported sleep states:'; Add-Line ((& powercfg.exe /a 2>&1 | Out-String).Trim()) } catch { }
try {
    $powerList = (& powercfg.exe /list 2>&1 | Out-String)
    Add-Line 'Available power plans:'
    Add-Line $powerList.Trim()
    $modernStandby = ((& powercfg.exe /a 2>&1 | Out-String) -match 'Standby \(S0 Low Power Idle\)')
    Add-Line ("Modern Standby detected: {0}" -f $modernStandby)
} catch { }

Add-Section 'Windows AI and privacy policies'
Add-Line ("Diagnostic data AllowTelemetry: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'))
Add-Line ("Recall availability: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement'))
Add-Line ("Recall snapshots disabled: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis'))
Add-Line ("Click to Do disabled: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo'))
Add-Line ("Copilot disabled policy: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'))
Add-Line ("Widgets disabled policy: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'))
Add-Line ("Packaged background apps policy: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground'))
foreach ($policyName in @(
    'LetAppsAccessAccountInfo','LetAppsAccessCalendar','LetAppsAccessCallHistory','LetAppsAccessContacts',
    'LetAppsAccessEmail','LetAppsAccessLocation','LetAppsAccessMessaging','LetAppsAccessMotion',
    'LetAppsAccessPhone','LetAppsAccessRadios','LetAppsAccessTasks','LetAppsAccessTrustedDevices',
    'LetAppsSyncWithDevices','LetAppsGetDiagnosticInfo','LetAppsAccessCamera','LetAppsAccessMicrophone',
    'LetAppsAccessNotifications'
)) {
    Add-Line (("AppPrivacy {0}: {1}" -f $policyName,(Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' $policyName)))
}
Add-Line ("Delivery Optimization mode: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'))
$copilotPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Copilot*' })
$widgetPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('MicrosoftWindows.Client.WebExperience','Microsoft.WidgetsPlatformRuntime') })
Add-Line ("Copilot packages remaining: {0}" -f $copilotPackages.Count)
Add-Line ("Widget packages remaining: {0}" -f $widgetPackages.Count)

if ([Environment]::Is64BitOperatingSystem) {
    Add-Line 'Critical policy 32-bit view comparison:'
    foreach ($viewCheck in @(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';Name='AllowTelemetry'},
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='DisableAIDataAnalysis'},
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';Name='DisableClickToDo'},
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';Name='LetAppsRunInBackground'}
    )) {
        $value32=Read-RegValueView -Path $viewCheck.Path -Name $viewCheck.Name -View ([Microsoft.Win32.RegistryView]::Registry32)
        Add-Line ("32-bit {0}\{1}: {2}" -f $viewCheck.Path,$viewCheck.Name,$value32)
    }
}

Add-Section 'Service baseline'
foreach ($name in @('DiagTrack','dmwappushservice','WerSvc','SysMain','CscService','MapsBroker','StorSvc','W32Time','BITS','wuauserv','AppXSvc','ClipSVC')) {
    $service = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if ($service) { Add-Line ("{0}: State={1}, StartMode={2}" -f $name,$service.State,$service.StartMode) }
    else { Add-Line ("{0}: not present" -f $name) }
}

Add-Section 'Security defaults preserved'
Add-Line ("UAC EnableLUA: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'))
Add-Line ("LSA RunAsPPL: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'))
Add-Line ("HVCI Enabled: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'))
Add-Line ("HVCI WasEnabledBy: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'WasEnabledBy'))
Add-Line ("HVCI EnabledBootId: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'EnabledBootId'))
try {
    $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    Add-Line ("VBS status: {0}" -f $deviceGuard.VirtualizationBasedSecurityStatus)
    Add-Line ("Security services configured: {0}" -f (@($deviceGuard.SecurityServicesConfigured) -join ','))
    Add-Line ("Security services running: {0}" -f (@($deviceGuard.SecurityServicesRunning) -join ','))
} catch { Add-Line ("Device Guard runtime status unavailable: {0}" -f $_.Exception.Message) }

Add-Line ("Vulnerable driver blocklist: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'))
try {
    $edgeSmartScreenDefault = (Get-Item -Path 'HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled' -ErrorAction Stop).GetValue('')
    if ($null -eq $edgeSmartScreenDefault) { $edgeSmartScreenDefault = '<missing>' }
} catch { $edgeSmartScreenDefault = '<missing>' }
Add-Line ("Edge SmartScreen override: {0}" -f $edgeSmartScreenDefault)
Add-Line ("AppHost web content evaluation override: {0}" -f (Read-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation'))
Add-Line ("Automatic Maintenance disabled override: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled'))
Add-Line ("Global toast notification override: {0}" -f (Read-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled'))
Add-Line ("HAGS policy override: {0}" -f (Read-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'))
Add-Line ("Chrome hardware acceleration policy override: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'HardwareAccelerationModeEnabled'))
try { Add-Line ("Memory compression: {0}" -f (Get-MMAgent -ErrorAction Stop).MemoryCompression) } catch { Add-Line 'Memory compression: unavailable' }

Add-Section 'Security and maintenance tasks'
foreach ($taskInfo in @(
    @{ Path='\Microsoft\Windows\ExploitGuard\'; Name='ExploitGuard MDM policy Refresh' },
    @{ Path='\Microsoft\Windows\Windows Defender\'; Name='Windows Defender Scheduled Scan' },
    @{ Path='\Microsoft\Windows\Defrag\'; Name='ScheduledDefrag' }
)) {
    $task = Get-ScheduledTask -TaskPath $taskInfo.Path -TaskName $taskInfo.Name -ErrorAction SilentlyContinue
    if ($task) { Add-Line ("{0}{1}: {2}" -f $taskInfo.Path,$taskInfo.Name,$task.State) }
    else { Add-Line ("{0}{1}: not present" -f $taskInfo.Path,$taskInfo.Name) }
}

Add-Section 'Background and update policies'
Add-Line ("Store AutoDownload override: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate' 'AutoDownload'))
Add-Line ("Store policy AutoDownload override: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload'))
Add-Line ("Edge Startup Boost policy: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled'))
Add-Line ("Edge background mode policy: {0}" -f (Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled'))
$allowList = Read-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground_ForceAllowTheseApps'
if ($allowList -eq '<missing>') { Add-Line 'Packaged background allowlist: <missing>' }
else { Add-Line ("Packaged background allowlist: {0}" -f (@($allowList) -join '; ')) }

Add-Section 'Core network bindings'
if (Get-Command Get-NetAdapterBinding -ErrorAction SilentlyContinue) {
    foreach ($componentId in @('ms_tcpip6','ms_server','ms_msclient','ms_pacer')) {
        $bindings = @(Get-NetAdapterBinding -ComponentID $componentId -ErrorAction SilentlyContinue)
        if ($bindings.Count -gt 0) {
            Add-Line ("{0}: {1}" -f $componentId, (($bindings | ForEach-Object { "{0}={1}" -f $_.Name,$_.Enabled }) -join '; '))
        }
    }
} else {
    Add-Line 'NetAdapter cmdlets unavailable.'
}

Add-Section 'Boot and resume state'
try { Add-Line ((& bcdedit.exe /enum '{current}' 2>&1 | Out-String).Trim()) } catch { }
$task = Get-ScheduledTask -TaskName 'ItsMauridian-Custom-Windows-Setup-StepTwo' -ErrorAction SilentlyContinue
Add-Line ("Resume scheduled task remains: {0}" -f [bool]$task)
Add-Line ("RunOnce resume remains: {0}" -f [bool](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!ItsMauridian-StepTwo' -ErrorAction SilentlyContinue))
Add-Line ("Persistent Run resume remains: {0}" -f [bool](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ItsMauridian-StepTwoResume' -ErrorAction SilentlyContinue))

Add-Section 'BitLocker'
if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
    foreach ($volume in @(Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Add-Line ("{0}: VolumeStatus={1}, ProtectionStatus={2}, Encryption={3}%" -f $volume.MountPoint,$volume.VolumeStatus,$volume.ProtectionStatus,$volume.EncryptionPercentage)
    }
} else { Add-Line 'BitLocker cmdlets unavailable.' }

Add-Section 'Display adapters'
foreach ($gpu in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
    Add-Line ("{0}: Driver={1}, Status={2}" -f $gpu.Name,$gpu.DriverVersion,$gpu.Status)
}

Add-Section 'WinGet and application results'
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $candidate = Join-Path $pkg.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $candidate) { $winget = [pscustomobject]@{ Source = $candidate } }
    }
}
if ($winget) {
    Add-Line ("WinGet path: {0}" -f $winget.Source)
    try { Add-Line ((& $winget.Source --version 2>&1 | Out-String).Trim()) } catch { }
} else { Add-Line 'WinGet not found.' }
$appResultsPath = Join-Path $workRoot 'AppInstallResults.json'
if (Test-Path -LiteralPath $appResultsPath) {
    try {
        $results = Get-Content -LiteralPath $appResultsPath -Raw | ConvertFrom-Json
        Add-Line ("Selected apps: {0}" -f @($results.Selected).Count)
        Add-Line ("Verified apps: {0}" -f @($results.Verified).Count)
        Add-Line ("Completed but unverified apps: {0}" -f @($results.Unverified).Count)
        Add-Line ("Failed apps: {0}" -f @($results.Failed).Count)
        foreach ($unverified in @($results.Unverified)) { Add-Line ("UNVERIFIED: {0}" -f $unverified) }
        foreach ($failure in @($results.Failed)) { Add-Line ("FAILED: {0}" -f $failure) }
        foreach ($manual in @($results.Manual)) { Add-Line ("MANUAL: {0}" -f $manual) }
    } catch { Add-Line ("App results could not be read: {0}" -f $_.Exception.Message) }
}

$lines | Out-File -LiteralPath $reportPath -Encoding UTF8 -Width 300 -Force
Write-Host "Verification report created: $reportPath" -ForegroundColor Green
