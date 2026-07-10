# Reliability8 code review checks

## Source-based design checks

- WinGet registration uses the Microsoft-supported `Add-AppxPackage -RegisterByFamilyName` command.
- App Installer fallback uses signed packages from Microsoft and Microsoft.UI.Xaml from NuGet.
- The real `winget.exe` is resolved from the registered App Installer package and validated with `--version`.
- WinGet output is not returned as function data, so exit-code logging remains numeric.
- AppX removal uses `Main` and `Bundle` package types and an explicit consumer-app list.
- AppX frameworks and protected system packages are not blanket-removed.
- Windows capabilities and optional features use explicit target lists and one inventory query per stage.
- Quick Edit mode is disabled in the main, setup and standalone GPU scripts.
- Store initialization and the main registry import have timeouts.
- PowerCfg values are normalized to decimal integers and unsupported settings are counted instead of logged as errors.
- OEM and built-in power plans are preserved.

## Regression checks

- `DigitalExtremes.Warframe`: absent.
- `Brave.Brave`: absent from the WinGet list.
- `PuTTY.PuTTY`: absent from the WinGet list.
- Legacy PowerShellGet WinGet bootstrap: absent.
- Broad AppX removal: absent.
- Broad capability removal: absent.
- Broad optional-feature removal: absent.
- Destructive Edge and WebView2 uninstall block: absent.
- Full C drive `desktop.ini` recursion: absent.
- Full Run and RunOnce key deletion: absent.
- `Wait-Process -Name chrome`: absent from StepTwo and the standalone GPU installer.
- WinGet source package removal: absent from the standalone GPU installer.
- Active transcript deletion during Windows Temp cleanup: prevented.
- Interactive Microsoft Store settings opening: absent.
- Deletion of all power plans: absent.

## Validation included in the repository

`.github/workflows/powershell-parse.yml` runs:

- PowerShell parsing with Windows PowerShell 5.1,
- PowerShell parsing with PowerShell 7,
- static regression checks for known failures.

## Local validation in the build environment

- All PowerShell files passed a lexical delimiter and here-string balance scan.
- Repository static checks passed.
- Zip integrity is checked after packaging.

A real Windows rerun is still required to validate OS servicing, Store access, hardware drivers and vendor installers end to end.

- Confirmed `wsreset.exe -i` is bounded by a 180-second timeout.
- Confirmed StepTwo verifies Microsoft Store and Desktop App Installer after Store recovery.
- Confirmed a missing Store package does not prevent the separate WinGet bootstrap.
