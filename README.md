# Custom Windows Setup

A personal fork of FR33THY's WinSux focused on repeatable post-install setup for:

- **Primary target:** Windows 11 IoT Enterprise LTSC
- **Secondary targets:** Windows 10 IoT Enterprise LTSC, Windows 10 Pro

The goal is one script that applies the same overall setup philosophy on both Windows 10 and Windows 11, while using **OS-aware branches only where Windows shell behavior actually differs**.

## Current status

- **Current Win11 VM status:** confirmed working well in the latest test VM.
- **Current Win11 IoT Enterprise LTSC status on real hardware/base install:** LTSC winget/App Installer recovery is merged, and visual-effects handling is now narrowed further so classic context menus and modern apps keep normal rendering while animations are still turned off.
- **Animation policy:** disable system-wide animations while preserving font smoothing, icon-label shadows, window drop shadows, the translucent desktop selection rectangle, the user-facing Animation effects toggle behavior, showing window contents while dragging, and normal focus rendering in modern apps.
- **AppX removal noise:** known and intentionally left unchanged for now.
- **Structure:** StepOne and StepTwo are now real files under `Scripts/Setup`, while the main script remains the public bootstrap entrypoint.

That means the project is currently in a **functionally good state, with LTSC-specific winget/bootstrap handling merged and visual-effects handling narrowed to avoid unrelated UI regressions**.

## Run

Open an **elevated Administrator PowerShell** window and run:

```powershell
iwr https://winsetup.tsql.gg -useb | iex
```

## Core behavior

The script is intended to:

1. Run MAS activation at the start.
2. Repair/bootstrap Microsoft Store and `winget` if needed, including LTSC-safe App Installer recovery when required.
3. Install apps via `winget`.
4. Create a restore point at the start of setup, before driver cleanup and heavy registry changes.
5. Apply privacy, performance, and usability tweaks.
6. Remove or disable selected Microsoft/consumer features.
7. Clean up taskbar pins and duplicate shortcuts.
8. Generate a desktop setup log at the end.

## Version-aware design

### Shared behavior on both Windows 10 and Windows 11

These are intended to be common across both OS versions:

- MAS activation
- Store/`winget` bootstrap
- Windows Search de-webbed
- New Outlook preferred by default while still leaving user choice available
- `winget` app installation
- File Explorer opens to **This PC**
- Task View button hidden
- System-wide animations disabled
- OneDrive uninstall / leftover cleanup / startup removal / reinstall prevention
- Passkey / FIDO2 / YubiKey support preserved
- Windows Hello-only sign-in restriction removed
- Privacy / telemetry reductions while preserving core Windows security defaults such as UAC, SmartScreen, PUA protection, Defender scheduled scans, LSA protection, HVCI and the Microsoft vulnerable driver blocklist
- Brave debloat
- Taskbar pin cleanup and duplicate shortcut cleanup
- Setup log written to the desktop

### Same goal on both OSes, but may require different implementation

These should have the same visible result on both Windows 10 and Windows 11, but the script can branch internally if the OS requires it:

- **Animations off** across the shell and UI
- **Taskbar cleanup** without reintroducing unwanted shell defaults
- **Explorer defaults** such as opening to **This PC**
- **OneDrive removal/cleanup** while respecting version differences in shell integration

### Windows 11-only behavior

These should be gated to Windows 11:

- Install **StartAllBack** (`StartIsBack.StartAllBack`)
- Remove **Home** from Explorer navigation pane
- Remove **Gallery** from Explorer navigation pane
- Apply Windows 11-specific shell handling where shell state differs from Windows 10
- Apply actual taskbar alignment handling only if that setting exists on that OS

### Windows 10-specific handling

These are primarily relevant to Windows 10:

- `ColorPrevalence=0` readability fix for dark theme
- Avoid old black-background behavior that caused unreadable shell text

### LTSC / IoT-specific handling

These are especially important on Windows 11 IoT Enterprise LTSC and should stay explicit in the script:

- Preserve the AppX families required for `winget` / App Installer recovery (`Microsoft.DesktopAppInstaller`, `Microsoft.UI.Xaml`, `Microsoft.VCLibs`, `Microsoft.WindowsAppRuntime`)
- Use the LTSC-safe App Installer / WinGet bootstrap path when `winget` is missing instead of assuming normal Microsoft Store-backed registration behavior
- Resolve and call the real `winget.exe` path after bootstrap instead of assuming the PATH alias is already valid

## Animation policy

The intended outcome on **both Windows 10 and Windows 11** is:

- system-wide animations disabled
- font smoothing / ClearType preserved
- icon-label shadows preserved
- window drop shadows preserved
- the translucent desktop selection rectangle preserved
- **Show window contents while dragging** preserved
- the user-facing **Animation effects** setting should still remain user-changeable after the script runs

Implementation rule:

- The script should not rely on registry changes alone.
- It should apply the needed `SystemParametersInfo` calls so the change actually sticks on Windows 11.
- It should avoid broad bundled writes such as `UserPreferencesMask` changes for this purpose, because those can also affect non-animation visuals.
- It should not disable the broad UI-effects master to achieve this.
- It should not turn off `ListviewAlphaSelect` or desktop icon-label shadows, because that creates the dotted white desktop-icon outline and flatter desktop text.
- It should not use a broad visual-effects change that leaves classic context menus or modern windows with unwanted white borders.
- The animation fix should remain scoped to animation behavior only and must not alter unrelated taskbar or Explorer behavior.
- No shell restart should be used for this unless testing proves it is strictly required.

## App installs via `winget`

Brave is not installed via `winget`. Brave Origin is intentionally left as a manual installer link because the vendor web installer is not reliable unattended:

```text
https://laptop-updates.brave.com/latest/origin
```

The current desired `winget` install set is:

- `7zip.7zip`
- `Microsoft.AppInstaller`
- `Balena.Etcher`
- `Bambulab.Bambustudio`
- `Apple.Bonjour`
- `Anthropic.Claude`
- `Microsoft.DirectX`
- `Discord.Discord`
- `Discord.Discord.PTB`
- `File-New-Project.EarTrumpet`
- `Element.Element`
- `Elgato.StreamDeck`
- `EpicGames.EpicGamesLauncher`
- `Futuremark.FuturemarkSystemInfo`
- `Google.Chrome`
- `REALiX.HWiNFO`
- `Oracle.JavaRuntimeEnvironment`
- `Logitech.GHUB`
- `Microsoft.DotNet.Framework.DeveloperPack.4.5`
- `Microsoft.DotNet.Framework.DeveloperPack_4`
- `Microsoft.DotNet.Native.Runtime`
- `Microsoft.DotNet.Runtime.3_1`
- `Microsoft.DotNet.Runtime.5`
- `Microsoft.DotNet.Runtime.6`
- `Microsoft.DotNet.Runtime.7`
- `Microsoft.DotNet.Runtime.8`
- `Microsoft.Edge`
- `Microsoft.EdgeWebView2Runtime`
- `Microsoft.VCRedist.2005.x86`
- `Microsoft.VCRedist.2005.x64`
- `Microsoft.VCRedist.2008.x64`
- `Microsoft.VCRedist.2008.x86`
- `Microsoft.VCRedist.2010.x64`
- `Microsoft.VCRedist.2010.x86`
- `Microsoft.VCRedist.2012.x64`
- `Microsoft.VCRedist.2012.x86`
- `Microsoft.VCRedist.2013.x64`
- `Microsoft.VCRedist.2013.x86`
- `Microsoft.VCLibs.Desktop.14`
- `Microsoft.VCLibs.14`
- `Microsoft.VCRedist.2015+.x64`
- `Microsoft.VCRedist.2015+.x86`
- `Microsoft.UI.Xaml.2.8`
- `rcmaehl.MSEdgeRedirect`
- `Nvidia.PhysX`
- `Obsidian.Obsidian`
- `Microsoft.OpenSSH.Preview`
- `Perplexity.Perplexity`
- `Microsoft.PowerShell`
- `Microsoft.PowerToys`
- `Proton.ProtonDrive`
- `Proton.ProtonMail`
- `Proton.ProtonVPN`
- `RaspberryPiFoundation.RaspberryPiImager`
- `RevoUninstaller.RevoUninstallerPro`
- `RockstarGames.Launcher`
- `ShareX.ShareX`
- `SlackTechnologies.Slack`
- `Valve.Steam`
- `SublimeHQ.SublimeText.4`
- `SergeySerkov.TagScanner`
- `Tailscale.Tailscale`
- `Telegram.TelegramDesktop`
- `Termius.Termius`
- `Ubisoft.Connect`
- `VideoLAN.VLC`
- `Microsoft.WindowsApp`
- `Microsoft.WindowsAppRuntime.1.6`
- `Microsoft.WindowsAppRuntime.1.7`
- `Microsoft.WindowsAppRuntime.1.8`
- `Microsoft.WindowsTerminal`
- `memstechtips.Winhance`
- `RARLab.WinRAR`
- `WinSCP.WinSCP`
- `Zoom.Zoom`
- `Devolutions.UniGetUI`
- `Apple.iTunes`
- `ElectronicArts.EADesktop`
- `Microsoft.Sysinternals.Autoruns`
- `StartIsBack.StartAllBack` (**Windows 11 only**)

## Search / Outlook defaults

The current intended defaults are:

- Windows Search de-webbed (`DisableSearchBoxSuggestions=1`, `BingSearchEnabled=0`, and cloud/highlights search surfaces already disabled elsewhere in the script)
- New Outlook preferred by default via `UseNewOutlook=1`
- The script should **not** force-hide the new/classic Outlook toggle, so classic Outlook remains available if installed
- The script should **not** force accessibility/high-contrast/keyboard-preference state, because those broader profile-level writes can leak into white focus/border artifacts in modern apps.

## AppX removal note

When the log mentions **AppX**, it is talking about Microsoft Store / UWP / inbox package families handled by the Windows app deployment system.

The current Windows 11 logs still show removal attempts against some built-in package families that modern Windows treats as part of the OS. That produces predictable noise, but this project is **not changing that list right now by explicit decision**.

So the current stance is:

- leave AppX removal behavior as-is for now,
- treat that part of the log as known noise,
- do not let that distract from functional regressions.

## Major changes from upstream WinSux

### Removed from the inherited behavior

- Black lockscreen / wallpaper enforcement
- Forced left taskbar alignment as a blanket rule
- YubiKey / FIDO2 / passkey blocking
- Windows Hello-only sign-in enforcement
- Broad deletion of the entire `Program Files (x86)\Microsoft` tree
- Winget uninstall-after-use behavior
- New Outlook removal

### Changed

- Edge cleanup is narrowed so **WebView2 is preserved**
- Taskbar work is **cleanup-first**, not forced repinning
- `W32Time` is not demoted to Manual
- `StorSvc` is not demoted to Manual
- `SharedAccess` is not disabled by the WinUtil service refresh
- StepOne is launched through Safe Mode RunOnce instead of replacing the Winlogon `Userinit` value
- Standalone DDU helper scripts also use Safe Mode RunOnce instead of replacing Winlogon `Userinit`
- `AssignedAccessManagerSvc` is not redundantly demoted
- Animation handling is explicit and aimed at both Windows 10 and Windows 11, while preserving non-animation visuals like ClearType, icon-label shadows, the translucent selection rectangle, drop shadows, and DragFullWindows

### Added / preserved

- MAS activation at the start
- Store reinstall/bootstrap safeguards
- Desktop setup log
- Deeper telemetry/privacy reductions
- OneDrive leftover cleanup and reinstall prevention
- Passkey/FIDO2 preservation
- Core Windows security defaults preserved by default, including UAC, SmartScreen, PUA protection, Defender scheduled scans, LSA protection, HVCI and the Microsoft vulnerable driver blocklist
- Brave Origin manual desktop shortcut via `https://laptop-updates.brave.com/latest/origin`
- Brave debloat after install
- WinUtil safe subset refreshed: Brave extra policy keys, Windows AI/Recall disable, detailed BSoD emoticon disable, WPBT preserved

## Current known log behavior

A setup log can contain some entries that are often noise rather than real failure, especially on VMs or on already-clean systems. Typical examples include:

- Missing files or folders that were already absent
- Missing processes that were not running
- Missing registry keys on a given Windows edition/build
- Files temporarily in use during cleanup
- VM-specific power-plan GUID mismatches
- AppX removal errors from built-in modern Windows package families

These should be treated differently from real script breakage.

## Current priorities

- Keep the script functionally stable.
- Keep changes minimal-diff by default.
- Keep AppX removal behavior untouched for now.
- Do a fuller Windows 10 / Windows 11 branch audit later, only where behavior genuinely differs.

## Other scripts

The repository also includes standalone GPU-driver helper scripts in `Graphics/`:

- `ItsMauridian-Allow-PowerShell-Scripts.cmd`
- `Graphics/ItsMauridian-DDU-Auto-Uninstall-GPU-Drivers.ps1`
- `Graphics/ItsMauridian-DDU-Manual-Uninstall-GPU-Drivers.ps1`
- `Graphics/ItsMauridian-Install-And-Configure-GPU-Driver.ps1`

## Project rule for future changes

Changes should be **minimal-diff by default**:

- do not change unrelated code
- do not restart the shell unless strictly required
- patch only the block that is actually broken
- provide full updated files when the main file changes

## Credits

- Original script base: FR33THY / WinSux
- Some service-baseline ideas sourced from Chris Titus Tech WinUtil


## Structure

```text
ItsMauridian-WinSux.ps1
ItsMauridian-Allow-PowerShell-Scripts.cmd
Graphics/ItsMauridian-DDU-Auto-Uninstall-GPU-Drivers.ps1
Graphics/ItsMauridian-DDU-Manual-Uninstall-GPU-Drivers.ps1
Graphics/ItsMauridian-Install-And-Configure-GPU-Driver.ps1
Scripts/Setup/StepOne.ps1
Scripts/Setup/StepTwo.ps1
```

`ItsMauridian-WinSux.ps1` remains the entrypoint. When run from a local clone it copies the local StepOne and StepTwo files. When run through `iwr | iex` it downloads them from the GitHub raw base configured near the top of the script. The GPU helper scripts stay in the root to match the original repository layout and avoid duplicate copies.

## Updated dependency notes

- 7-Zip updated to 26.02.
- DDU updated to 18.1.5.5.
- NVIDIA Profile Inspector updated to 3.0.2.1.
- Static Microsoft DirectX redist download uses SHA256 verification.
- 7-Zip, DDU, Chrome and dynamic VC++ aka.ms downloads are left with empty hash placeholders unless you choose to pin exact binaries after locally verifying hashes.


## Additional safety notes

- Browser update services/tasks are preserved so installed browsers can continue receiving security updates.
- Windows driver searching is enabled after the main setup registry pass; DDU still temporarily blocks Windows Update during driver cleanup.

- Fixed DDU 18.1.5.5 extraction path handling: the scripts now search for the real `Display Driver Uninstaller.exe`, create the `Settings` folder if needed, and reuse the detected path in Safe Mode.


### Brave Origin note

Brave Origin unattended install is intentionally skipped. The script creates an `Install Brave Origin.url` desktop shortcut pointing to `https://laptop-updates.brave.com/latest/origin`, because the vendor web installer can fail with `0x80040C01` or hang behind an HTTP error dialog.
