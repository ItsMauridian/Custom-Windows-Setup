# Reliability14 code review checks

## Parser and archive

- [ ] Every `.ps1` parses with Windows PowerShell 5.1.
- [ ] Every `.ps1` parses with PowerShell 7.
- [ ] Here-strings and delimiters are balanced.
- [ ] The zip opens successfully and contains repository files at its root.
- [ ] No parent directory is added inside the zip.

## DDU and resume

- [ ] SetupOptions.json is written before Safe Mode.
- [ ] StepOne, StepTwo, Resume-StepTwo and Verify-Setup are parsed before Safe Mode.
- [ ] Handoff scripts are stored under ProgramData.
- [ ] Scheduled task registration is verified.
- [ ] HKLM RunOnce and persistent HKLM Run fallbacks are present.
- [ ] Resume-StepTwo launches StepTwo in an isolated Windows PowerShell process.
- [ ] The global mutex prevents duplicate StepTwo runs.
- [ ] Resume entries remain until the completion marker exists.
- [ ] Recover-StepTwo downloads and parses fresh files.
- [ ] DDU failure cannot leave the system permanently in Safe Mode.

## WinGet

- [ ] The real package-local winget.exe path is resolved and validated.
- [ ] Repair-WinGetPackageManager is present and bounded by a timeout.
- [ ] Windows App Runtime 1.8 fallback precedes App Installer fallback.
- [ ] Normal packages use the winget source.
- [ ] Selected Store packages use msstore.
- [ ] Every install has a timeout and heartbeat.
- [ ] Every install is verified after completion.
- [ ] WinGet output is not mistaken for an exit code.
- [ ] No security hash bypass is present.
- [ ] App Installer frameworks are not ordinary app-list entries.
- [ ] Perplexity uses Microsoft Store product ID XP8JNQFBQH6PVF and falls back to an official manual shortcut.
- [ ] Rockstar failures create an official manual shortcut.

## Applications

- [ ] .NET 8 and .NET 10 are default.
- [ ] .NET 3.1, 5, 6, 7 and developer packs are opt-in.
- [ ] Warframe is absent.
- [ ] Brave.Brave is absent.
- [ ] PuTTY.PuTTY is absent.
- [ ] Brave Origin is manual-only.
- [ ] StartAllBack is Windows 11-only.
- [ ] Known heavy app startup entries are removed only when selected.

## Privacy and background activity

- [ ] Copilot, Recall, Click to Do, Widgets and selected Paint AI policies are present.
- [ ] Consumer content, Spotlight, web search and activity history are disabled.
- [ ] Diagnostic data is edition-aware.
- [ ] AppPrivacy uses documented policy values.
- [ ] Camera, microphone and notifications remain user controlled.
- [ ] Packaged background default-deny has a PFN allowlist.
- [ ] No private settings.dat hive is loaded.
- [ ] No opaque start2.bin state is imported.
- [ ] No CapabilityAccessManager consent database is deleted.
- [ ] No global toast-notification disable is applied.

## Power and performance

- [ ] The native Ultimate Performance template GUID is duplicated first.
- [ ] The actual created GUID is parsed and activated.
- [ ] Modern Standby fallback is derived from Balanced.
- [ ] Active plan is verified after activation.
- [ ] Unsupported power settings are skipped before setting.
- [ ] Experimental timer and BCD changes default to off.
- [ ] SysMain remains Automatic.
- [ ] Memory compression remains enabled.
- [ ] IPv6 and core network bindings remain enabled.
- [ ] Chrome hardware acceleration is not forced off.
- [ ] HAGS and VRR remain user or driver controlled.
- [ ] Automatic Maintenance remains enabled.

## Security preserved

- [ ] No disabling writes for UAC.
- [ ] No disabling writes for RunAsPPL.
- [ ] No disabling writes for HVCI.
- [ ] No disabling writes for the vulnerable driver blocklist.
- [ ] Defender real-time protection remains enabled.
- [ ] SmartScreen remains enabled or unforced.
- [ ] Windows Update, BITS, Store updates and browser updates remain available.
- [ ] Defender, Exploit Guard and ScheduledDefrag tasks remain enabled.
- [ ] No TrustedInstaller service binPath mutation exists.
- [ ] WebView2, Windows Hello, passkeys and FIDO2 remain available.

## Reports

- [ ] WinSux-Setup-Log.txt categorizes failures, notes and warnings.
- [ ] AppInstallResults.json records selected, verified, failed and manual packages.
- [ ] CWS-Verification-Report.txt covers options, power, privacy, services, security, boot state, BitLocker, GPU and WinGet.

A clean Windows hardware run remains required for final end-to-end validation of servicing commands, Store registration, DDU and third-party installers.
- [ ] No Microsoft Store private `settings.dat` hive is loaded or modified.
- [ ] No undefined `Add-Note` helper call remains.
- [ ] Verification report helper methods do not emit internal list indexes.

