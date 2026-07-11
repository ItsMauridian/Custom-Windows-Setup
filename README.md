# ItsMauridian Custom Windows Setup

A Windows 10 and Windows 11 setup script based on FR33THY WinSux, adapted for a privacy-focused and performance-focused daily driver.

The primary target is Windows 11 IoT Enterprise LTSC. Windows 10 IoT Enterprise LTSC and Windows 10 Pro are secondary targets.

## Run

Open Windows PowerShell as administrator and run:

```powershell
iwr https://winsetup.tsql.gg -UseBasicParsing | iex
```

The setup creates a restore point first, asks for installation choices, prepares DDU, restarts into Safe Mode, removes display and audio drivers, returns to normal Windows, then continues with StepTwo.

Know your Windows account password before the Safe Mode restart. A PIN may not work in Safe Mode.

## Reliability14

Reliability14 is built from the successful reliability13 hardware test and its full transcript.

Main changes:

- Setup choices are saved before DDU in `C:\ProgramData\ItsMauridian\Custom-Windows-Setup\SetupOptions.json`.
- StepOne, StepTwo, the resume wrapper and the verifier are parsed before Safe Mode is enabled.
- Reboot handoff uses a scheduled task, HKLM RunOnce and a persistent HKLM Run recovery fallback.
- A global mutex prevents duplicate StepTwo runs.
- WinGet is resolved from the registered App Installer package and repaired through Microsoft.WinGet.Client when necessary.
- Windows App Runtime 1.8 and App Installer are used as the LTSC fallback.
- Every WinGet install has a timeout and is checked afterwards with an exact package lookup.
- Perplexity uses its Microsoft Store product ID, with an official manual shortcut as fallback. Rockstar failures also create an official manual shortcut instead of blocking setup.
- Legacy .NET runtimes and developer packs are optional and off by default.
- Quick Edit is disabled so mouse selection cannot pause the console.
- A read-only verification report is created on the desktop.

## Default privacy and performance profile

The aggressive profile is always enabled. It applies supported policies and removes selected consumer packages for:

- Windows Copilot and the Copilot app
- Recall snapshots and Recall availability
- Click to Do and selected Paint AI features
- Widgets and Windows Web Experience packages
- Windows Spotlight, consumer suggestions, tips and cloud-optimized content
- Start menu web search, cloud search and search highlights
- Advertising ID, tailored experiences and activity history
- Optional telemetry and feedback prompts
- Delivery Optimization peer uploads
- Game DVR background capture
- Edge Startup Boost and Edge background mode
- Packaged app background execution, with an allowlist for selected Store infrastructure and notification apps
- OneDrive removal and reinstall prevention when selected
- Known heavy application auto-start entries when selected

Camera, microphone and notification permissions remain user controlled. Security notifications remain enabled.

## Security and platform components preserved

The setup does not disable:

- UAC
- LSA protection and RunAsPPL
- HVCI and Memory Integrity
- Microsoft vulnerable driver blocklist
- Microsoft Defender and its scheduled scans
- SmartScreen and web-content evaluation
- Windows Update and BITS
- Microsoft Store updates
- Edge and browser update services
- AppXSvc, ClipSVC, InstallService and Store infrastructure
- StorSvc and W32Time
- SysMain
- IPv6 and core Microsoft network bindings
- Memory compression
- Hibernation
- WebView2
- Windows Hello, passkeys and FIDO2

Fast Startup is disabled, but hibernation remains available.

## Power plan

When selected, the setup first tries to duplicate and activate Microsoft's native Ultimate Performance template.

On Modern Standby hardware, Windows only permits Balanced or plans derived from Balanced. In that case the setup creates and activates:

```text
ItsMauridian Ultimate Performance
```

That fallback is derived from Balanced, uses maximum AC performance settings where the hardware exposes them, and keeps laptop-safe DC values. Unsupported hardware-specific settings are detected and skipped without failing setup.

Experimental timer service and BCD timer changes are off by default.

## Installation choices

All normal app groups default to Yes. Legacy groups default to No.

### Recommended utilities and supported runtimes

- 7-Zip
- DirectX legacy runtime
- Google Chrome
- HWiNFO
- Java 8
- .NET 8 and .NET 10 runtimes
- Microsoft Edge and WebView2
- Microsoft Visual C++ redistributables
- MSEdgeRedirect
- Obsidian
- PowerShell 7
- PowerToys
- Proton Drive and Proton VPN
- ShareX
- Tailscale
- VLC
- Windows Terminal
- Winhance
- WinRAR
- WinSCP
- UniGetUI
- Sysinternals Autoruns
- StartAllBack on Windows 11

### Communication and productivity

- Claude
- Discord and Discord PTB
- Element
- Perplexity, installed from Microsoft Store
- Proton Mail
- Slack
- Telegram Desktop
- Termius
- Zoom

### Gaming

- Epic Games Launcher
- NVIDIA PhysX
- Rockstar Games Launcher
- Steam
- Ubisoft Connect
- EA app

### Developer and remote tools

- balenaEtcher
- OpenSSH Preview
- Raspberry Pi Imager
- Sublime Text 4

### Hardware, media and device utilities

- Bambu Studio
- Apple Bonjour
- EarTrumpet
- Elgato Stream Deck
- Futuremark SystemInfo
- Logitech G HUB
- Revo Uninstaller Pro
- TagScanner
- iTunes

### Store apps

- Windows App

### Optional legacy packages

These are off by default because they are unsupported or development-only:

- .NET Core 3.1
- .NET 5
- .NET 6
- .NET 7
- .NET Native Runtime
- .NET Framework 4.5 Developer Pack
- .NET Framework 4.8.1 Developer Pack

Brave Origin is not installed unattended. The setup creates an official vendor shortcut on the desktop.

Warframe, normal Brave and PuTTY are not installed.

## BitLocker

This fork intentionally starts BitLocker decryption and disables protectors because that was explicitly requested for this setup workflow. This reduces disk protection. Do not use this behavior on a device where BitLocker must remain enabled.

## Logs and verification

The setup writes:

```text
C:\Windows\Temp\CWS-StepTwo.log
Desktop\WinSux-Setup-Log.txt
Desktop\CWS-Verification-Report.txt
C:\ProgramData\ItsMauridian\Custom-Windows-Setup\AppInstallResults.json
```

The verification report checks:

- completion and resume state
- saved setup choices
- active power plan and Modern Standby
- Copilot, Recall, Widgets and AppPrivacy policies
- service startup state
- UAC, RunAsPPL, HVCI and the driver blocklist
- SmartScreen and maintenance overrides
- Store, Edge and browser update policies
- memory compression and network bindings
- Safe Mode, BitLocker and display drivers
- WinGet version and app results

## Recovery after DDU

Upload the current repository files first. Then run this from an administrator PowerShell window:

```powershell
iwr "https://raw.githubusercontent.com/ItsMauridian/Custom-Windows-Setup/main/Scripts/Setup/Recover-StepTwo.ps1?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -UseBasicParsing -OutFile "$env:TEMP\Recover-StepTwo.ps1"; powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Recover-StepTwo.ps1"
```

Do not run DDU again when only StepTwo needs recovery.

## Repository structure

```text
ItsMauridian-WinSux.ps1
ItsMauridian-Allow-PowerShell-Scripts.cmd
README.md
PATCH-SUMMARY.md
CODE-REVIEW-CHECKS.md
Graphics/
Scripts/Setup/
.github/workflows/
```

## Validation

The GitHub Action parses every PowerShell file using both Windows PowerShell 5.1 and PowerShell 7. It also checks for known security, resume, WinGet, power, AppX and application-list regressions.

A clean Windows hardware installation is still the final end-to-end test for driver installers, Store availability and third-party vendor installers.

## Credits

- FR33THY WinSux
- Chris Titus Tech WinUtil policy and service-baseline ideas
- Microsoft Windows and WinGet documentation


## Reliability 15

Reliability 15 incorporates the first clean-install verification from 2026-07-11.

- Critical privacy policies are applied through one function, read back immediately and applied again at the final stage.
- Resume scheduled tasks and registry handoff entries are removed before the verification report is generated.
- WinGet exit code 0 is no longer reported as a failure solely because `winget list` has not refreshed yet.
- Successful but not yet visible packages are reported separately as unverified.
- WinGet verification retries for up to 15 seconds after each successful installer.
- NVIDIA Control Panel result objects are handled correctly instead of being compared with an integer.
- Final application results are written after GPU installation, so the verification report sees the complete result set.
- `Repair-Current-Install.ps1` repairs an existing reliability14 installation without reinstalling Windows.


## Reliability 16

Reliability 16 uses explicit 64-bit registry access for machine policies, verifies every critical policy immediately, restores SysMain, memory compression and hibernation after vendor installers, and reports detailed HVCI/VBS runtime state without forcing HVCI on incompatible hardware.
