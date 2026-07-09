# Patch summary

This package updates the Custom Windows Setup repo with:

- Split StepOne and StepTwo into Scripts/Setup files.
- Early restore point before activation, downloads, DDU and registry changes.
- Admin check changed to explicit elevated-shell requirement, safe for iwr | iex.
- Internet check changed from ICMP ping to HTTPS.
- BitLocker disable for protected volumes before Safe Mode, plus temporary protector disable for reboot safety.
- 7-Zip 26.02, DDU 18.1.5.5 and NVIDIA Profile Inspector 3.0.2.1 URLs.
- Optional SHA256 verification helper, DirectX SHA256 pin, and official DDU 18.1.5.5 portable SHA256 pin.
- StepOne no longer disables UAC, RunAsPPL, HVCI, Microsoft vulnerable driver blocklist or kernel mitigation options by default.
- WinUtil safe subset additions for Brave, Windows AI/Recall, WPBT, detailed BSoD and service baseline.
- Winget install failures are collected and surfaced at the top of the desktop log.
- GitHub Actions parse check for all ps1 files.

Manual follow-up recommended:

- After downloading 7-Zip 26.02 and NVIDIA Profile Inspector 3.0.2.1 on your machine, calculate SHA256 hashes and fill the empty Sha256 fields if you want strict pinning. DDU is already pinned to the official Wagnardsoft portable SHA256.
- Test DDU 18.1.5.5 on one disposable Windows install before making it your only path.
- Update winsetup.tsql.gg so the structured files are available in the GitHub repo before using the public one-liner.

Additional app-list update:

- Removed Brave.Brave from winget and added direct Brave Origin installer URL.
- Removed PuTTY.PuTTY.
- Expanded the winget app/runtime list to match the user's selected package list, including Balena.Etcher, Element.Element, Microsoft.DirectX, Elgato.StreamDeck, Oracle.JavaRuntimeEnvironment, Logitech.GHUB, ProtonVPN, Tailscale, Termius, Winhance, Windows App Runtime packages and related runtimes.
Code review fixes in this package:

- Fixed invalid StepTwo here-string terminators created by splitting the old embedded here-string.
- Fixed the Add-Type C# source block so it parses as normal PowerShell.
- Changed winget installs to exact ID matching with `-e`.
- Changed NVIDIA Control Panel install to exact Store ID with `--source msstore`.
- Fixed the CMD helper to unblock files using `%~dp0` instead of `$PSScriptRoot`.
- Added `CODE-REVIEW-CHECKS.md`.

Extra hardening pass:

- Replaced the legacy Winlogon Userinit StepOne launch with the current upstream-style Safe Mode RunOnce approach using the `*` prefix.
- Added guarded cleanup for legacy Userinit entries only when they point to this setup's StepOne file.
- Preserved SmartScreen, PUA protection, phishing protection, Tamper Protection, Controlled Folder Access, Defender scheduled tasks and Exploit Guard by default.
- Added Clear-BitLockerAutoUnlock before BitLocker disable attempts so Disable-BitLocker is less likely to be blocked by auto-unlock protectors.
- Kept WinUtil service refresh narrow: CscService, DiagTrack, MapsBroker and SvcHostSplitThresholdInKB only, with StorSvc, W32Time and SharedAccess left alone.


## Extra hardening pass

- Replaced the standalone DDU helper launch method with Safe Mode RunOnce instead of replacing `Winlogon\Userinit`.
- Left guarded legacy cleanup for older builds that may have written `StepOne.ps1` or `DDU.ps1` into `Userinit`.
- Preserved Chrome and Brave update mechanisms instead of deleting browser update tasks/services.
- Changed the main setup registry pass so Windows driver searching is enabled again after setup. DDU can still temporarily block Windows Update during cleanup.
- Rebuilt the deliverable as one GitHub-ready zip with repository contents at the archive root.
- Removed duplicate GPU helper copies; GPU helper scripts now live only in `Graphics/` to match the current GitHub layout.

- Fixed DDU 18.1.5.5 extraction path handling: the scripts now search for the real `Display Driver Uninstaller.exe`, create the `Settings` folder if needed, and reuse the detected path in Safe Mode.


## Resume fix after DDU
- Fixed remaining escaped here-string terminators in `Scripts/Setup/StepTwo.ps1` left over from the old monolithic embedded script.
- Moved the visual-effects Add-Type ErrorAction onto the Add-Type call instead of the here-string closing delimiter.
- Replaced normal-boot StepTwo resume with a highest-privilege scheduled task at next logon, with HKLM RunOnce only as fallback.
- Added `C:\Windows\Temp\CWS-StepTwo.log` transcript/error logging so a failed resume no longer disappears silently.

- Follow-up: removed leftover Brave/Chrome update scheduled task deletion lines.

## Hotfix: StepTwo app and NVIDIA handling

- Removed `DigitalExtremes.Warframe` from the winget app list.
- Made SHA256 verification skip cleanly when no hash is intentionally configured.
- Guarded the NVIDIA DRS unblock step so missing `C:\ProgramData\NVIDIA Corporation\Drs` does not stop StepTwo.


## Hotfix 2

- Kept `DigitalExtremes.Warframe` removed.
- Changed UniGetUI to `Devolutions.UniGetUI`.
- Changed Autoruns to `Microsoft.Sysinternals.Autoruns`.
- Added a central `Invoke-CwsWinGetInstall` helper that uses exact winget IDs and explicit source handling for Microsoft Store packages.
- Kept empty SHA256 fields non-fatal and NVIDIA DRS import guarded when the folder does not exist.


## Hotfix 3 - Brave Origin timeout guard

- Brave Origin still uses the requested vendor URL: `https://laptop-updates.brave.com/latest/origin`.
- The direct installer is now non-fatal and limited to 300 seconds.
- If the installer shows an HTTP error dialog or hangs, the process is killed, StepTwo continues, and a desktop shortcut named `Install Brave Origin.url` is created for manual install.
## Hotfix 4 - Brave Origin manual-only

- Changed Brave Origin from attempted unattended installation to manual-only by default.
- The vendor URL is still preserved: `https://laptop-updates.brave.com/latest/origin`.
- StepTwo now creates `Install Brave Origin.url` on the desktop and continues immediately.
- This avoids the Brave installer error dialog `0x80040C01` and other HTTP/web-installer hangs.


## Hotfix 5

- Removed an extra closing brace in `Scripts/Setup/StepTwo.ps1` after the winget app install loop.
- This fixes the PowerShell parse error at line 2835: `Unexpected token '}' in expression or statement`.
- Re-ran the static brace and here-string scan across all PowerShell files.
