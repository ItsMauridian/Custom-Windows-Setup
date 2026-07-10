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

        # FUNCTION RUN AS TRUSTED INSTALLER
        function Run-Trusted([String]$command) {
        try {
    	Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop
  		}
  		catch {
    	taskkill /im trustedinstaller.exe /f >$null
  		}
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrustedInstaller'"
        $DefaultBinPath = $service.PathName
  		$trustedInstallerPath = "$env:SystemRoot\servicing\TrustedInstaller.exe"
  		if ($DefaultBinPath -ne $trustedInstallerPath) {
    	$DefaultBinPath = $trustedInstallerPath
  		}
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
        $base64Command = [Convert]::ToBase64String($bytes)
        sc.exe config TrustedInstaller binPath= "cmd.exe /c powershell.exe -encodedcommand $base64Command" | Out-Null
        sc.exe start TrustedInstaller | Out-Null
        sc.exe config TrustedInstaller binpath= "`"$DefaultBinPath`"" | Out-Null
        try {
    	Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop
  		}
  		catch {
    	taskkill /im trustedinstaller.exe /f >$null
  		}
        }

        # Clean up legacy builds that used Winlogon Userinit for StepOne.
        # New builds use RunOnce with the Safe Mode * prefix instead of replacing Userinit.
        try {
        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $currentUserinit = (Get-ItemProperty -Path $winlogonPath -Name Userinit -ErrorAction SilentlyContinue).Userinit
        if ($currentUserinit -and $currentUserinit -match "StepOne\.ps1" -and $currentUserinit -notmatch "userinit\.exe") {
        Set-ItemProperty -Path $winlogonPath -Name Userinit -Value "$env:SystemRoot\system32\userinit.exe," -ErrorAction SilentlyContinue
        }
        } catch { }

        Write-Host "DEFENDER SETTINGS`n"
        ## windowsdefender:
		## windowsdefender://threatsettings
		## windowsdefender://ransomwareprotection
		## windowsdefender://settings
		## windowsdefender://smartapp
		## windowsdefender://smartscreenpua
		## windowsdefender://exploitprotection
		## windowsdefender://coreisolation

$windowssecuritysettings = @(
# Keep Defender real-time protection enabled. This intentionally replaces the inherited security-downgrade block.
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection`" /v `"DisableRealtimeMonitoring`" /t REG_DWORD /d `"0`" /f >nul 2>&1"',

# Defender and firewall notification noise reduction only. SmartScreen, PUA protection, phishing protection,
# Tamper Protection, Controlled Folder Access, HVCI, LSA protection, exploit mitigations and the vulnerable
# driver blocklist are left under Windows defaults/user control.
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications`" /v `"DisableEnhancedNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"NoActionNotificationDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"SummaryNotificationDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"FilesBlockedNotificationDisabled`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableDynamiclockNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableWindowsHelloNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\DomainProfile`" /v `"DisableNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile`" /v `"DisableNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"',
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile`" /v `"DisableNotifications`" /t REG_DWORD /d `"1`" /f >nul 2>&1"'
)

# run $windowssecuritysettings as function with trusted installer
foreach ($command in $windowssecuritysettings) {
    Run-Trusted $command
}

# run $windowssecuritysettings as admin
foreach ($command in $windowssecuritysettings) {
    Invoke-Expression $command
}

# UAC is intentionally preserved.


function Get-CwsDduExecutable {
    $pathFile = "$env:SystemRoot\Temp\DDU.path"
    if (Test-Path $pathFile) {
        $savedPath = (Get-Content -Path $pathFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($savedPath -and (Test-Path $savedPath)) { return $savedPath }
    }

    $candidate = Get-ChildItem -Path "$env:SystemRoot\Temp\DDU" -Recurse -File -Filter "Display Driver Uninstaller.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) {
        Write-Host "DDU executable was not found under $env:SystemRoot\Temp\DDU." -ForegroundColor Red
        Write-Host "Safe Mode will be disabled now. Re-run setup after uploading the fixed files." -ForegroundColor Yellow
        cmd /c "bcdedit /deletevalue {current} safeboot >nul 2>&1"
        Pause
        Exit 1
    }
    return $candidate.FullName
}

# remove safe mode boot
cmd /c "bcdedit /deletevalue {current} safeboot >nul 2>&1"

        Write-Host "DDU & RESTARTING`n" -ForegroundColor Red

# uninstall soundblaster realtek intel amd nvidia drivers & restart
$DduExePath = Get-CwsDduExecutable
Start-Process -FilePath $DduExePath -ArgumentList "-CleanSoundBlaster -CleanRealtek -CleanAllGpus -Restart" -Wait
