# Reliability14 patch summary

## Grounding from reliability13

The successful hardware run reached the final stage without a fatal PowerShell error. WinGet was repaired, most requested applications installed, NVIDIA driver setup completed and the machine restarted normally.

The remaining observed issues were:

- Perplexity WinGet EXE installer failure
- Rockstar Games Launcher manifest hash mismatch
- .NET Framework developer pack failure
- four unsupported power settings
- locked temp files during cleanup
- inherited transcript noise from earlier failed attempts

Reliability14 addresses these without reintroducing the destructive behavior removed in earlier builds.

## Resume and DDU

- Saves all choices before Safe Mode.
- Keeps reboot-boundary scripts under ProgramData.
- Parses StepOne, StepTwo, Resume-StepTwo and Verify-Setup before enabling Safe Mode.
- Uses scheduled task, HKLM RunOnce and persistent HKLM Run recovery paths.
- Uses an isolated StepTwo PowerShell process and a global mutex.
- Keeps Recover-StepTwo.ps1 for one-command recovery.
- Keeps the Safe Mode password warning.

## WinGet and applications

- Uses the package-local WinGet executable instead of relying on PATH aliases.
- Registers App Installer for the current user when possible.
- Uses Microsoft.WinGet.Client and Repair-WinGetPackageManager as the primary repair path.
- Installs Windows App Runtime 1.8 before the current App Installer bundle as fallback.
- Adds per-package timeouts and progress heartbeats.
- Uses the `winget` source for normal packages and `msstore` only for selected Store packages.
- Verifies each selected package after installation.
- Translates important WinGet exit codes to readable text.
- Installs Perplexity through its Microsoft Store product ID and adds an official manual shortcut on failure.
- Adds an official manual shortcut for Rockstar failures.
- Keeps package hash verification enabled.
- Keeps .NET 8 and .NET 10 as defaults.
- Moves .NET 3.1, 5, 6, 7, .NET Native and developer packs to opt-in groups.
- Keeps Warframe, normal Brave and PuTTY removed.
- Keeps Brave Origin manual-only.

## Privacy and Windows AI

- Disables Windows Copilot through policy and selected package removal.
- Applies RemoveMicrosoftCopilotApp where supported.
- Disables Recall availability, Recall snapshots and Click to Do.
- Disables selected Paint AI features.
- Removes selected Widgets and Web Experience packages.
- Disables Spotlight, consumer experiences, suggestions, web search and activity history.
- Uses edition-aware diagnostic-data values.
- Disables telemetry services and feedback prompts.
- Applies supported AppPrivacy policies.
- Keeps camera, microphone and notifications user controlled.
- Denies packaged background activity by default with a selected PFN allowlist.
- Disables Edge Startup Boost and background mode while preserving Edge updates.
- Removes known heavy application auto-start entries when selected.

## Performance and power

- Duplicates and activates the native Ultimate Performance template when supported.
- Falls back to an activatable Balanced-derived `ItsMauridian Ultimate Performance` plan on Modern Standby.
- Applies maximum AC values and laptop-safe DC values only when settings exist.
- Detects and reports unsupported settings without failing.
- Keeps experimental timer and BCD changes disabled by default.
- Preserves SysMain, memory compression, IPv6 and core network bindings.
- Removes inherited undocumented multimedia scheduler, network-throttling, service-host and driver-feature overrides.
- Stops forcing Chrome hardware acceleration off.

## Security and reliability audit

- Preserves UAC, RunAsPPL, HVCI and the vulnerable driver blocklist.
- Preserves Defender, SmartScreen, Windows Update, Store updates and browser updates.
- Preserves Defender, Exploit Guard and drive-optimization scheduled tasks.
- Removes private package-hive modifications and opaque Start-menu binary state.
- Removes global notification suppression and protected consent-database deletion.
- Avoids TrustedInstaller service binPath changes.
- Avoids destructive core network binding changes.
- Keeps hibernation available and disables only Fast Startup.
- Keeps WebView2, passkeys, Windows Hello and FIDO2 support.

## Verification

- Adds a desktop CWS-Verification-Report.txt.
- Records saved options, active power plan, Modern Standby, AI and privacy policies, services, security settings, maintenance overrides, network bindings, boot state, BitLocker, GPU drivers and application results.
- Extends GitHub Actions regression checks.
- Adds a SHA256 pin for 7-Zip 26.02, alongside the existing DDU and DirectX pins.

## Final archive corrections

- Removed the remaining direct Microsoft Store `settings.dat` hive mutation so private package state is no longer loaded or edited.
- Corrected the undefined `Add-Note` call to `Add-CwsNote`.
- Suppressed internal list indexes from the verification report writer.
- Restored the repository PowerShell validation workflow in the archive.



## Reliability 15

- Fixed false WinGet failures with exit code `0x00000000`.
- Added a separate completed-but-unverified result category.
- Fixed NVIDIA Control Panel object-to-integer comparison.
- Added delayed WinGet inventory verification.
- Reapplied and verified privacy policies at the final setup stage.
- Moved resume cleanup before report generation.
- Added a post-install repair script for reliability14 systems.


## Reliability 16

- Replaced PowerShell provider policy writes with explicit Registry64 access and immediate readback.
- Added 32-bit versus 64-bit policy-view diagnostics.
- Added a final repair pass for SysMain, memory compression and hibernation.
- Added detailed HVCI and VBS diagnostics without forcibly changing the security state.
- Added AppX fallback verification for Microsoft Windows App.
