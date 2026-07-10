# Reliability 12 patch

- Fixed preference-variable leakage from `Resume-StepTwo.ps1` into `StepTwo.ps1`.
- StepTwo now runs in a separate Windows PowerShell process after DDU.
- StepTwo explicitly sets `$ErrorActionPreference = 'Continue'`.
- Recovery invokes `bcdedit.exe` through `Start-Process` and ignores the expected missing-safeboot result.
- Added regression checks that reject an in-process `& $stepTwoPath` handoff.

# Reliability 12

- Fixed the PowerShell parser error caused by `$LiteralPath:` in an expandable string.
- Added a pre-DDU parser gate. StepOne, StepTwo and Resume-StepTwo must all pass the real Windows PowerShell parser before the machine can enter Safe Mode.
- Added `Scripts/Setup/Recover-StepTwo.ps1` for one-command recovery of a machine that stopped after DDU.
- Kept the highest-privilege Task Scheduler logon task and HKLM RunOnce handoff.
- Added a persistent HKLM Run fallback that remains until StepTwo creates its completion marker.
- Resume logic can recover a missing local StepTwo from Windows Temp or GitHub.
- Resume logic keeps a global mutex so duplicate triggers cannot start two StepTwo instances.
- StepOne now forces a normal reboot if DDU exits without performing its requested restart.
- StepTwo and the wrapper remove all resume entries only after completion.
- GitHub Actions still parses every PowerShell file with Windows PowerShell 5.1 and PowerShell 7.

# Reliability8 patch summary

This build is based on the completed Windows 11 VM and laptop test logs from 10 July 2026. It focuses on observed failures, misleading logs, long silent stages and hardware-specific assumptions.

## Main fixes

- Quick Edit selection is disabled while the scripts run, preventing an accidental console click from pausing the process in Select mode.
- Store initialization now has a three-minute timeout and no longer opens the interactive Microsoft Store settings page.
- Long Windows settings, AppX, capability and optional-feature stages now print explicit progress.
- AppX inventory is read once and only an explicit consumer-app list is processed.
- AppX frameworks, Windows App Runtime, App Installer dependencies and protected Windows system packages are preserved.
- Windows capabilities and optional features are read once and only explicit targets are removed or disabled.
- WinGet registration and bootstrap use App Installer, signed Microsoft dependencies and the real package-local `winget.exe`.
- The legacy PowerShellGet and `Microsoft.WinGet.Client` bootstrap route remains removed.
- WinGet output is displayed while the helper returns only a numeric exit code.
- A post-install `winget list` check distinguishes a real failure from an already-installed package.
- Microsoft Edge and WebView2 are preserved instead of being removed and reinstalled in the same run.
- Remote Desktop Connection, Snipping Tool, Microsoft GameInput and unrelated startup entries are preserved.
- GPU vendor pages use the default browser and driver selection is validated before extraction.
- NVIDIA registry changes target NVIDIA adapter keys and optional DRS/scaling paths are guarded.
- PowerCfg values are normalized to integers, unsupported settings are skipped, and existing OEM/built-in plans are no longer deleted.
- The timer-resolution service uses its internal service name `STR` consistently.
- Temp cleanup preserves StepTwo and its live transcript.
- The desktop log is categorized instead of dumping the global PowerShell error buffer.
- GitHub Actions parses every PowerShell file with Windows PowerShell 5.1 and PowerShell 7 and runs regression checks.

## Intentionally unchanged

- MAS activation flow.
- Safe Mode and DDU handoff design.
- The requested WinGet app list, except Warframe remains removed.
- Visual-effects policy.
- OneDrive removal policy.
- Brave Origin remains a manual desktop shortcut.

## Build marker

```text
# BUILD MARKER: reliability12 2026-07-10 - persistent DDU resume handoff and recovery
```

## Reliability9 Store verification

- Keeps `wsreset.exe -i` as the LTSC Store recovery attempt.
- Enforces a 180-second timeout so Store recovery cannot block StepTwo forever.
- Verifies `Microsoft.WindowsStore` and `Microsoft.DesktopAppInstaller` after the recovery attempt.
- Continues to the dedicated App Installer and WinGet bootstrap when either package is still missing.
