# ==============================================================================
# WinSux - Forked & Modified by Mauridian (ItsMauridian)
# BUILD MARKER: reliability13 2026-07-10 - persistent DDU resume handoff
# Repo: https://github.com/ItsMauridian/Custom-Windows-Setup
# Run: iwr https://winsetup.tsql.gg -useb | iex
#
# Original script by FR33THY: https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide
#
# Modifications in this fork:
#   - Windows activation via MAS (get.activated.win) added at start
#   - Removed: black lockscreen/wallpaper enforcement
#   - Removed: force left taskbar alignment (set to centered/default)
#   - Removed: hide recycle bin from desktop & start menu shortcut
#   - Removed: show all taskbar icons (restores pop-out arrow)
#   - Removed: 100% DPI scaling override (allows per-monitor scaling e.g. 125%)
#   - Removed: pause Windows Updates for 365 days
#   - Removed: disable automatic Microsoft Store app updates
#   - Removed: prevent driver downloads via Windows Update
#   - Removed: remove Scan with Defender from context menu
#   - Removed: disable YubiKey/FIDO2 passkey access
#   - Removed: force Windows Hello only sign-in (PasswordLess)
#   - Removed: remove security taskbar icon
#   - Removed: wipe Program Files (x86)\Microsoft folder (preserves WebView2)
#   - Changed: Microsoft Edge and WebView2 are preserved; only stale shortcuts are removed
#   - Changed: taskbar alignment set to centered (Windows 11 default)
#   - Changed: ColorPrevalence set to 0 (fixes unreadable text on Windows 10)
#   - Added: confirm file delete dialog
#   - Added: enable text suggestions on physical keyboard + multilingual suggestions
#   - Added: wsreset -i to reinstall Microsoft Store if missing
#   - Changed: Store initialization is non-interactive and protected by a timeout
#   - Added: NetworkThrottlingIndex + SystemResponsiveness tweaks
#   - Added: Nagle's algorithm disabled on all network adapters
#   - Added: SysMain (Superfetch) disabled
#   - Added: HPET disabled via bcdedit
#   - Added: Prefer IPv4 over IPv6 + Disable Teredo (DisabledComponents=0x21)
#   - Added: netsh teredo set state disabled
#   - Added: OneDrive leftover folder removal, startup removal, reinstall prevention
#   - Added: comprehensive telemetry block (DiagTrack, wermgr, AdvertisingInfo, TIPC,
#            OnlineSpeechPrivacy, SvcHostSplitThresholdInKB, PowerShell/dotnet telemetry)
#   - Added: Activity History disabled (EnableActivityFeed, UploadUserActivities)
#   - Added: Copilot deep removal (appx, IsCopilotAvailable, AllowCopilotRuntime, CoreAI)
#   - Changed: AppX removal uses an explicit consumer-app list and preserves frameworks
#   - Added: Widgets appx removal
#   - Changed: service baseline aligned to current WinUtil safe subset
#   - Added: Explorer Automatic Folder Discovery disabled
#   - Added: Background apps GlobalUserDisabled
#   - Added: Show hidden files (without system files)
#   - Added: Num Lock on startup
#   - Changed: MPO handling is OS-aware and only forced on Windows 10
#   - Added: Modern Standby fix (EnforceDisconnectedStandby)
#   - Added: Verbose logon/logoff messages
#   - Added: ShowHibernateOption=0
#   - Added: winget app installs refreshed from the selected package list
#            (Brave.Brave and PuTTY.PuTTY removed; Brave Origin is a manual vendor shortcut)
#   - Added: Brave debloat registry keys refreshed from current WinUtil
#   - Added: winget no longer uninstalled after use
#   - Added: New Outlook no longer removed
# ==============================================================================
#   - Changed: StepOne and StepTwo are now separate files under Scripts/Setup
#   - Changed: UAC, LSA protection, HVCI and Microsoft vulnerable driver blocklist are preserved by default
#   - Changed: 7-Zip, DDU and NVIDIA Profile Inspector URLs updated
# ==============================================================================


# CONFIG
$CwsRepoRawBase = "https://raw.githubusercontent.com/ItsMauridian/Custom-Windows-Setup/refs/heads/main"
$CwsDependencies = @{
    SevenZip = @{ Url = "https://www.7-zip.org/a/7z2602-x64.exe"; File = "$env:SystemRoot\Temp\7 Zip.exe"; Sha256 = "" }
    DDU = @{ Url = "https://download.wagnardsoft.com/DDU/DDU%20v18.1.5.5.exe"; File = "$env:SystemRoot\Temp\DDU.exe"; Sha256 = "F5A5095018EA5641B68DC622570770C5815FA73ECBF053018925FBB126CBC3B9" }
    DirectX = @{ Url = "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"; File = "$env:SystemRoot\Temp\DirectX.exe"; Sha256 = "053F76DCBB28802E23341B6A787E3B0791C0FA5C8D4D011B1044172DBF89C73B" }
}

# SCRIPT RUN AS ADMIN
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "Run this from an elevated Administrator PowerShell window." -ForegroundColor Red
    Pause
    Exit 1
}
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

# SCRIPT SILENT
$progresspreference = 'silentlycontinue'

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

# FUNCTION FASTER DOWNLOADS WITH OPTIONAL SHA256 VERIFICATION
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
        if ($File) {
            $FileDirectory = $([System.IO.Path]::GetDirectoryName($File))
            if (!(Test-Path($FileDirectory))) { [System.IO.Directory]::CreateDirectory($FileDirectory) | Out-Null }
        }
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

function Test-CwsInternet {
    try {
        $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -UseBasicParsing -TimeoutSec 10
        return $true
    } catch {
        return $false
    }
}

function New-CwsRestorePoint {
    param([string]$Description = "Before Custom Windows Setup")
    try {
        Write-Host "RESTORE POINT`n"
        cmd /c "reg add `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`" /v `"SystemRestorePointCreationFrequency`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue | Out-Null
        Checkpoint-Computer -Description $Description -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue | Out-Null
        cmd /c "reg delete `"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`" /v `"SystemRestorePointCreationFrequency`" /f >nul 2>&1"
    } catch { }
}

function Disable-CwsBitLockerForSetup {
    try {
        if (!(Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return }
        if (Get-Command Clear-BitLockerAutoUnlock -ErrorAction SilentlyContinue) {
            Clear-BitLockerAutoUnlock -ErrorAction SilentlyContinue | Out-Null
        }
        $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.MountPoint }
        foreach ($vol in $volumes) {
            $mountPoint = $vol.MountPoint
            $needsAction = ($vol.ProtectionStatus -eq 'On' -or $vol.VolumeStatus -match 'Encrypted|Encryption|Decryption')
            if ($needsAction) {
                Write-Host "BITLOCKER`n" -ForegroundColor Yellow
                Write-Host "Disabling BitLocker on $mountPoint and starting decryption if needed.`n" -ForegroundColor Yellow
                Disable-BitLocker -MountPoint $mountPoint -ErrorAction SilentlyContinue | Out-Null
                Suspend-BitLocker -MountPoint $mountPoint -RebootCount 3 -ErrorAction SilentlyContinue | Out-Null
                cmd /c "manage-bde -protectors -disable $mountPoint -RebootCount 3 >nul 2>&1"
            }
        }
    } catch { }
}

function Get-CwsDduExecutable {
    param([string]$ExtractRoot = "$env:SystemRoot\Temp\DDU")

    $candidate = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter "Display Driver Uninstaller.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) {
        throw "DDU executable not found under $ExtractRoot after extraction."
    }
    return $candidate.FullName
}

function Set-CwsDduConfig {
    param(
        [string]$ExtractRoot = "$env:SystemRoot\Temp\DDU",
        [Parameter(Mandatory)][string]$ConfigXml
    )

    $dduExePath = Get-CwsDduExecutable -ExtractRoot $ExtractRoot
    $dduRoot = Split-Path -Path $dduExePath -Parent
    $settingsDir = Join-Path $dduRoot "Settings"
    $settingsFile = Join-Path $settingsDir "Settings.xml"

    New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
    if (Test-Path $settingsFile) {
        Set-ItemProperty -Path $settingsFile -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    }
    Set-Content -Path $settingsFile -Value $ConfigXml -Encoding UTF8 -Force
    Set-ItemProperty -Path $settingsFile -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
    Set-Content -Path "$env:SystemRoot\Temp\DDU.path" -Value $dduExePath -Encoding ASCII -Force

    return $dduExePath
}

function Repair-CwsLegacyUserinit {
    try {
        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $currentUserinit = (Get-ItemProperty -Path $winlogonPath -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($currentUserinit -and $currentUserinit -match "StepOne\.ps1" -and $currentUserinit -notmatch "userinit\.exe") {
            Set-ItemProperty -Path $winlogonPath -Name Userinit -Value "$env:SystemRoot\system32\userinit.exe," -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Save-CwsRepoFile {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Destination
    )
    $localPath = $null
    if ($PSScriptRoot) { $localPath = Join-Path $PSScriptRoot $RelativePath }
    if ($localPath -and (Test-Path $localPath)) {
        Copy-Item -Path $localPath -Destination $Destination -Force
        return
    }
    $url = "$CwsRepoRawBase/$($RelativePath -replace '\\','/')"
    Get-FileFromWeb -URL $url -File $Destination
}

function Assert-CwsPowerShellSyntax {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object {
            "Line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber): $($_.Message)"
        }) -join [Environment]::NewLine
        throw ("PowerShell syntax validation failed for {0}:{1}{2}" -f $Path, [Environment]::NewLine, $details)
    }
}

New-CwsRestorePoint -Description "Before Custom Windows Setup"

# SCRIPT CHECK INTERNET
if (!(Test-CwsInternet)) {
    Write-Host "Internet Connection Required`n" -ForegroundColor Red
    Pause
    Exit 1
}

Write-Host "WINDOWS ACTIVATION`n"

# run microsoft activation scripts
irm https://get.activated.win | iex

        Write-Host "WinSux - Forked & Modified" -ForegroundColor Cyan
        Write-Host "Original script by " -ForegroundColor White -NoNewline; Write-Host "FR33THY" -ForegroundColor Cyan -NoNewline; Write-Host " (youtube.com/FR33THY)" -ForegroundColor White
        Write-Host "Fork includes additional tweaks, app installs, and personalizations`n" -ForegroundColor Gray
        Write-Host "Press Enter to continue..." -ForegroundColor Yellow
        Read-Host | Out-Null

        Write-Host "7Z`n"
        ## explorer "https://www.7-zip.org"

# download 7zip
Get-FileFromWeb -URL $CwsDependencies.SevenZip.Url -File $CwsDependencies.SevenZip.File -Sha256 $CwsDependencies.SevenZip.Sha256

# install 7zip
Start-Process -Wait "$env:SystemRoot\Temp\7 Zip.exe" -ArgumentList "/S"

# set config for 7zip
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"ContextMenu`" /t REG_DWORD /d `"259`" /f >nul 2>&1"
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"CascadedMenu`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# cleaner 7zip start menu shortcut path
Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Host "C++`n"
		## explorer "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170"

# download c++
Get-FileFromWeb -URL "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE" -File "$env:SystemRoot\Temp\vcredist2005_x86.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE" -File "$env:SystemRoot\Temp\vcredist2005_x64.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe" -File "$env:SystemRoot\Temp\vcredist2008_x86.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe" -File "$env:SystemRoot\Temp\vcredist2008_x64.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe" -File "$env:SystemRoot\Temp\vcredist2010_x86.exe" 
Get-FileFromWeb -URL "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe" -File "$env:SystemRoot\Temp\vcredist2010_x64.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe" -File "$env:SystemRoot\Temp\vcredist2012_x86.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe" -File "$env:SystemRoot\Temp\vcredist2012_x64.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/2/e/6/2e61cfa4-993b-4dd4-91da-3737cd5cd6e3/vcredist_x86.exe" -File "$env:SystemRoot\Temp\vcredist2013_x86.exe"
Get-FileFromWeb -URL "https://download.microsoft.com/download/2/e/6/2e61cfa4-993b-4dd4-91da-3737cd5cd6e3/vcredist_x64.exe" -File "$env:SystemRoot\Temp\vcredist2013_x64.exe"
Get-FileFromWeb -URL "https://aka.ms/vs/17/release/vc_redist.x86.exe" -File "$env:SystemRoot\Temp\vcredist2015_2017_2019_2022_x86.exe"
Get-FileFromWeb -URL "https://aka.ms/vs/17/release/vc_redist.x64.exe" -File "$env:SystemRoot\Temp\vcredist2015_2017_2019_2022_x64.exe"

# install c++
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2005_x86.exe" -ArgumentList "/Q /C:`"msiexec /i vcredist.msi /qn /norestart`"" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2005_x64.exe" -ArgumentList "/Q /C:`"msiexec /i vcredist.msi /qn /norestart`"" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2008_x86.exe" -ArgumentList "/q" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2008_x64.exe" -ArgumentList "/q" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2010_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2010_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2012_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2012_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2013_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2013_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2015_2017_2019_2022_x86.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
Start-Process -Wait "$env:SystemRoot\Temp\vcredist2015_2017_2019_2022_x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden 

        Write-Host "DDU`n"
        ## explorer "https://www.wagnardsoft.com/display-driver-uninstaller-ddu"

# download ddu
Get-FileFromWeb -URL $CwsDependencies.DDU.Url -File $CwsDependencies.DDU.File -Sha256 $CwsDependencies.DDU.Sha256

# extract ddu with 7zip
& "C:\Program Files\7-Zip\7z.exe" x "$env:SystemRoot\Temp\DDU.exe" -o"$env:SystemRoot\Temp\DDU" -y | Out-Null

# set config for ddu
$DduConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<DisplayDriverUninstaller Version="18.1.5.5">
	<Settings>
		<SelectedLanguage>en-US</SelectedLanguage>
		<RemoveMonitors>True</RemoveMonitors>
		<RemoveCrimsonCache>True</RemoveCrimsonCache>
		<RemoveAMDDirs>True</RemoveAMDDirs>
		<RemoveAudioBus>True</RemoveAudioBus>
		<RemoveAMDKMPFD>True</RemoveAMDKMPFD>
		<RemoveNvidiaDirs>True</RemoveNvidiaDirs>
		<RemovePhysX>True</RemovePhysX>
		<Remove3DTVPlay>True</Remove3DTVPlay>
		<RemoveGFE>True</RemoveGFE>
		<RemoveNVBROADCAST>True</RemoveNVBROADCAST>
		<RemoveNVCP>True</RemoveNVCP>
		<RemoveINTELCP>True</RemoveINTELCP>
		<RemoveINTELIGS>True</RemoveINTELIGS>
		<RemoveOneAPI>True</RemoveOneAPI>
		<RemoveEnduranceGaming>True</RemoveEnduranceGaming>
		<RemoveIntelNpu>True</RemoveIntelNpu>
		<RemoveAMDCP>True</RemoveAMDCP>
		<UseRoamingConfig>False</UseRoamingConfig>
		<CheckUpdates>False</CheckUpdates>
		<CreateRestorePoint>False</CreateRestorePoint>
		<SaveLogs>False</SaveLogs>
		<RemoveVulkan>True</RemoveVulkan>
		<ShowOffer>False</ShowOffer>
		<EnableSafeModeDialog>False</EnableSafeModeDialog>
		<PreventWinUpdate>True</PreventWinUpdate>
		<UsedBCD>False</UsedBCD>
		<KeepNVCPopt>False</KeepNVCPopt>
		<RememberLastChoice>False</RememberLastChoice>
		<LastSelectedGPUIndex>0</LastSelectedGPUIndex>
		<LastSelectedTypeIndex>0</LastSelectedTypeIndex>
	</Settings>
</DisplayDriverUninstaller>
'@
# write DDU config next to the real extracted executable.
# New DDU builds can extract into a versioned subfolder, so do not assume a fixed path.
$DduExePath = Set-CwsDduConfig -ExtractRoot "$env:SystemRoot\Temp\DDU" -ConfigXml $DduConfig

        Write-Host "CHROME`n"
        ## explorer "https://www.google.com/intl/en_us/chrome"

# download google chrome
Get-FileFromWeb -URL "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" -File "$env:SystemRoot\Temp\Chrome.msi"

# install google chrome
Start-Process -Wait "$env:SystemRoot\Temp\Chrome.msi" -ArgumentList "/quiet"

# install ublock origin lite
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist`" /v `"1`" /t REG_SZ /d `"ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx`" /f >nul 2>&1"

# add chrome policies
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Google\Chrome`" /v `"HardwareAccelerationModeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Google\Chrome`" /v `"BackgroundModeEnabled`" /t REG_DWORD /d `"0`" /f >nul 2>&1"
cmd /c "reg add `"HKLM\SOFTWARE\Policies\Google\Chrome`" /v `"HighEfficiencyModeEnabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"

# keep Chrome update services and scheduled tasks intact.
# Previous builds removed Google update plumbing here, but that can leave an installed browser outdated.

        ## explorer "https://www.microsoft.com/en-au/download/details.aspx?id=35"

# download direct x
Get-FileFromWeb -URL $CwsDependencies.DirectX.Url -File $CwsDependencies.DirectX.File -Sha256 $CwsDependencies.DirectX.Sha256

# extract directx with 7zip
& "C:\Program Files\7-Zip\7z.exe" x "$env:SystemRoot\Temp\DirectX.exe" -o"$env:SystemRoot\Temp\DirectX" -y | Out-Null

# install direct x
Start-Process -Wait "$env:SystemRoot\Temp\DirectX\DXSETUP.exe" -ArgumentList "/silent" -WindowStyle Hidden


function Register-CwsStepTwoResumeHandoff {
    param(
        [Parameter(Mandatory)][string]$ResumeScriptPath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $taskName = "ItsMauridian-Custom-Windows-Setup-StepTwo"
    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$ResumeScriptPath`""

    try {
        New-Item -Path (Split-Path -Path $LogPath -Parent) -ItemType Directory -Force | Out-Null
        "[$(Get-Date -Format o)] Registering StepTwo resume handoff." | Add-Content -Path $LogPath -Encoding UTF8

        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }

        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principalUser = $identity.User.Value
        $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 20)
        $principal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        Register-ScheduledTask -TaskName $taskName -Description "Resume Custom Windows Setup StepTwo after DDU" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

        $registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $registeredAction = $registeredTask.Actions | Where-Object { $_.Arguments -and $_.Arguments -like "*$ResumeScriptPath*" }
        if (-not $registeredTask -or -not $registeredAction) { throw "The StepTwo scheduled task could not be verified after registration." }
        "[$(Get-Date -Format o)] Scheduled task registered for SID $principalUser." | Add-Content -Path $LogPath -Encoding UTF8
    } catch {
        "[$(Get-Date -Format o)] Scheduled task registration failed: $($_.Exception.Message)" | Add-Content -Path $LogPath -Encoding UTF8
        Write-Host "Scheduled Task resume registration failed. RunOnce remains available as fallback." -ForegroundColor Yellow
    }

    # Add two independent registry fallbacks. RunOnce is the immediate handoff.
    # Run is deliberately persistent until StepTwo marks completion, so a missed
    # task trigger or failed elevation can recover automatically at the next sign-in.
    $resumeCommand = "`"$powerShellPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$ResumeScriptPath`""

    try {
        $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
        New-Item -Path $runOncePath -Force | Out-Null
        New-ItemProperty -Path $runOncePath -Name "!ItsMauridian-StepTwo" -PropertyType String -Value $resumeCommand -Force | Out-Null
        "[$(Get-Date -Format o)] HKLM RunOnce fallback registered." | Add-Content -Path $LogPath -Encoding UTF8
    } catch {
        "[$(Get-Date -Format o)] HKLM RunOnce registration failed: $($_.Exception.Message)" | Add-Content -Path $LogPath -Encoding UTF8
        Write-Host "RunOnce resume registration failed. See $LogPath" -ForegroundColor Yellow
    }

    try {
        $runPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        New-Item -Path $runPath -Force | Out-Null
        New-ItemProperty -Path $runPath -Name "ItsMauridian-StepTwoResume" -PropertyType String -Value $resumeCommand -Force | Out-Null
        "[$(Get-Date -Format o)] Persistent HKLM Run recovery fallback registered." | Add-Content -Path $LogPath -Encoding UTF8
    } catch {
        "[$(Get-Date -Format o)] HKLM Run recovery registration failed: $($_.Exception.Message)" | Add-Content -Path $LogPath -Encoding UTF8
        Write-Host "Persistent resume fallback registration failed. See $LogPath" -ForegroundColor Yellow
    }
}

$CwsWorkRoot = Join-Path $env:ProgramData "ItsMauridian\Custom-Windows-Setup"
$CwsStepOnePath = Join-Path $CwsWorkRoot "StepOne.ps1"
$CwsStepTwoPath = Join-Path $CwsWorkRoot "StepTwo.ps1"
$CwsResumePath = Join-Path $CwsWorkRoot "Resume-StepTwo.ps1"
$CwsResumeLogPath = Join-Path $CwsWorkRoot "Resume-StepTwo.log"
New-Item -Path $CwsWorkRoot -ItemType Directory -Force | Out-Null

# Keep the critical handoff scripts outside Windows Temp. Temp files are not a
# reliable reboot boundary and can be removed by cleanup tools or maintenance.
Save-CwsRepoFile -RelativePath "Scripts/Setup/StepOne.ps1" -Destination $CwsStepOnePath
Save-CwsRepoFile -RelativePath "Scripts/Setup/StepTwo.ps1" -Destination $CwsStepTwoPath
Save-CwsRepoFile -RelativePath "Scripts/Setup/Resume-StepTwo.ps1" -Destination $CwsResumePath

# Do not enter Safe Mode until every reboot-boundary script has passed the real
# Windows PowerShell parser. This prevents a half-completed machine after DDU.
foreach ($scriptPath in @($CwsStepOnePath, $CwsStepTwoPath, $CwsResumePath)) {
    Assert-CwsPowerShellSyntax -Path $scriptPath
}
if (-not (Select-String -Path $CwsStepTwoPath -Pattern 'BUILD MARKER: reliability13' -Quiet)) {
    throw 'The downloaded StepTwo.ps1 is not the reliability13 build.'
}
if (-not (Select-String -Path $CwsResumePath -Pattern 'BUILD MARKER: reliability13' -Quiet)) {
    throw 'The downloaded Resume-StepTwo.ps1 is not the reliability13 build.'
}
Write-Host "DDU continuation scripts validated successfully.`n" -ForegroundColor Green

# Keep compatibility copies for diagnostics and older recovery instructions.
Copy-Item -Path $CwsStepOnePath -Destination "$env:SystemRoot\Temp\StepOne.ps1" -Force
Copy-Item -Path $CwsStepTwoPath -Destination "$env:SystemRoot\Temp\StepTwo.ps1" -Force


# Clean up legacy Winlogon Userinit method used by older builds.
Repair-CwsLegacyUserinit

# Run StepOne in Safe Mode. The * prefix forces RunOnce execution in Safe Mode,
# while ! defers deletion until after the command has run.
$stepOneRunOnce = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$CwsStepOnePath`""
New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Force | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "*!ItsMauridian-StepOne" -PropertyType String -Value $stepOneRunOnce -Force | Out-Null

# Register two independent normal-boot continuation paths. The resume wrapper
# uses a global mutex, so Task Scheduler and RunOnce cannot run StepTwo twice.
Register-CwsStepTwoResumeHandoff -ResumeScriptPath $CwsResumePath -LogPath $CwsResumeLogPath

# disable open terminal by default
cmd /c "reg add `"HKCU\Console\%%Startup`" /v `"DelegationConsole`" /t REG_SZ /d `"{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}`" /f >nul 2>&1"
cmd /c "reg add `"HKCU\Console\%%Startup`" /v `"DelegationTerminal`" /t REG_SZ /d `"{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}`" /f >nul 2>&1"

Write-Host "Safe Mode warning:" -ForegroundColor Yellow
Write-Host "Make sure you know your Windows account password, not only your PIN." -ForegroundColor Yellow
Write-Host "PIN sign-in can fail in Safe Mode on some Windows 11 installs.`n" -ForegroundColor Yellow
Pause

Disable-CwsBitLockerForSetup

# turn on safe boot
cmd /c "bcdedit /set {current} safeboot minimal >nul 2>&1"

Write-Host "RESTARTING`n" -ForegroundColor Red

# restart
Start-Sleep -Seconds 5
shutdown -r -t 00
