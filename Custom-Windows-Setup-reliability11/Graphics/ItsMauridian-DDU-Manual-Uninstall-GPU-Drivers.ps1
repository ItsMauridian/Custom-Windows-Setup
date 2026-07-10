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

# SCRIPT CHECK INTERNET
try {
    $null = Invoke-WebRequest -Uri "https://github.com" -Method Head -UseBasicParsing -TimeoutSec 10
} catch {
    Write-Host "Internet Connection Required`n" -ForegroundColor Red
    Pause
    Exit 1
}

# SCRIPT SILENT
$progresspreference = 'silentlycontinue'

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

        Write-Host "youtube.com/FR3" -ForegroundColor White -NoNewline; Write-Host "3THY`n" -ForegroundColor Cyan

        Write-Host "7Z`n"
        ## explorer "https://www.7-zip.org"

# download 7zip
Get-FileFromWeb -URL "https://www.7-zip.org/a/7z2602-x64.exe" -File "$env:SystemRoot\Temp\7 Zip.exe"

# install 7zip
Start-Process -Wait "$env:SystemRoot\Temp\7 Zip.exe" -ArgumentList "/S"

# set config for 7zip
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"ContextMenu`" /t REG_DWORD /d `"259`" /f >nul 2>&1"
cmd /c "reg add `"HKEY_CURRENT_USER\Software\7-Zip\Options`" /v `"CascadedMenu`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# cleaner 7zip start menu shortcut path
Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null


function Disable-CwsBitLockerForSetup {
    try {
        if (!(Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return }
        if (Get-Command Clear-BitLockerAutoUnlock -ErrorAction SilentlyContinue) { Clear-BitLockerAutoUnlock -ErrorAction SilentlyContinue | Out-Null }
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

        Write-Host "DDU`n"
        ## explorer "https://www.wagnardsoft.com/display-driver-uninstaller-ddu"

# download ddu
Get-FileFromWeb -URL "https://download.wagnardsoft.com/DDU/DDU%20v18.1.5.5.exe" -File "$env:SystemRoot\Temp\DDU.exe" -Sha256 "F5A5095018EA5641B68DC622570770C5815FA73ECBF053018925FBB126CBC3B9"

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

# prevent downloads of drivers from windows update
cmd /c "reg add `"HKLM\Software\Microsoft\Windows\CurrentVersion\DriverSearching`" /v `"SearchOrderConfig`" /t REG_DWORD /d `"0`" /f >nul 2>&1"

# create ddu ps1 file
$DDU = @'
    # remove legacy Winlogon handoff only if an older script left DDU.ps1 there
    try {
        $WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $CurrentUserinit = (Get-ItemProperty -Path $WinlogonPath -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($CurrentUserinit -and $CurrentUserinit -match "DDU\.ps1" -and $CurrentUserinit -notmatch "userinit\.exe") {
            Set-ItemProperty -Path $WinlogonPath -Name Userinit -Value "$env:SystemRoot\system32\userinit.exe," -ErrorAction SilentlyContinue
        }
    } catch { }

    function Get-CwsDduExecutable {
        $pathFile = "$env:SystemRoot\Temp\DDU.path"
        if (Test-Path $pathFile) {
            $savedPath = (Get-Content -Path $pathFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($savedPath -and (Test-Path $savedPath)) { return $savedPath }
        }

        $candidate = Get-ChildItem -Path "$env:SystemRoot\Temp\DDU" -Recurse -File -Filter "Display Driver Uninstaller.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $candidate) {
            Write-Host "DDU executable was not found under $env:SystemRoot\Temp\DDU." -ForegroundColor Red
            cmd /c "bcdedit /deletevalue {current} safeboot >nul 2>&1"
            Pause
            Exit 1
        }
        return $candidate.FullName
    }

# remove safe mode boot
cmd /c "bcdedit /deletevalue {current} safeboot >nul 2>&1"

        Write-Host "DDU`n"

# open ddu
$DduExePath = Get-CwsDduExecutable
Start-Process -FilePath $DduExePath
'@
Set-Content -Path "$env:SystemRoot\Temp\DDU.ps1" -Value $DDU -Force

# use RunOnce with a safe-mode prefix instead of replacing Winlogon Userinit
cmd /c "reg add `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"*!DDU`" /t REG_SZ /d `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$env:SystemRoot\Temp\DDU.ps1`"`" /f >nul 2>&1"

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