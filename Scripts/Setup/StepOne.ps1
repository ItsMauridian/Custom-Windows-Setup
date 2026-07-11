# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability16 2026-07-10 - validated isolated DDU restart handoff
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
# Keep Defender real-time protection enabled. Remove notification-suppression values
# left by older builds so security and firewall alerts return to Windows defaults.
'cmd /c "reg add `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection`" /v `"DisableRealtimeMonitoring`" /t REG_DWORD /d `"0`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications`" /v `"DisableEnhancedNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"NoActionNotificationDisabled`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"SummaryNotificationDisabled`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection`" /v `"FilesBlockedNotificationDisabled`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableDynamiclockNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows Defender Security Center\Account protection`" /v `"DisableWindowsHelloNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\DomainProfile`" /v `"DisableNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile`" /v `"DisableNotifications`" /f >nul 2>&1"',
'cmd /c "reg delete `"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile`" /v `"DisableNotifications`" /f >nul 2>&1"'
)

# Apply the security defaults as administrator. No TrustedInstaller service changes are needed.
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
$dduProcess = Start-Process -FilePath $DduExePath -ArgumentList "-CleanSoundBlaster -CleanRealtek -CleanAllGpus -Restart" -PassThru -Wait

# Normally DDU restarts Windows itself. If it returns instead, force the normal
# reboot so the already-registered StepTwo handoff can continue the setup.
if ($dduProcess -and $dduProcess.ExitCode -ne 0) {
    Write-Host ("DDU returned exit code {0}. Windows will still restart so setup can continue." -f $dduProcess.ExitCode) -ForegroundColor Yellow
}
Start-Sleep -Seconds 5
shutdown.exe /r /t 0 /f
