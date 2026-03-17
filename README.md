# Custom Windows Setup

A personal fork of FR33THY's WinSux focused on repeatable post-install setup for:

- **Primary target:** Windows 11 IoT Enterprise LTSC
- **Secondary targets:** Windows 10 IoT Enterprise LTSC, Windows 10 Pro

The goal is one script that applies the same overall setup philosophy on both Windows 10 and Windows 11, while using **OS-aware branches only where Windows shell behavior actually differs**.

## Current status

- **Current Win11 VM status:** confirmed working well in the latest test VM.
- **Animation policy:** the intended result is the Windows UI toggle **Animation effects = Off**.
- **AppX removal noise:** known and intentionally left unchanged for now.

That means the project is currently in a **functionally good, still partially noisy in the log, but not blocked** state.

## Run

Open an **elevated Administrator PowerShell** window and run:

```powershell
iwr https://winsetup.m05.dev -useb | iex
```

## Core behavior

The script is intended to:

1. Run MAS activation at the start.
2. Repair/bootstrap Microsoft Store and `winget` if needed.
3. Install apps via `winget`.
4. Apply privacy, performance, and usability tweaks.
5. Remove or disable selected Microsoft/consumer features.
6. Clean up taskbar pins and duplicate shortcuts.
7. Generate a desktop setup log at the end.

## Version-aware design

### Shared behavior on both Windows 10 and Windows 11

These are intended to be common across both OS versions:

- MAS activation
- Store/`winget` bootstrap
- `winget` app installation
- File Explorer opens to **This PC**
- Task View button hidden
- System-wide animations disabled
- OneDrive uninstall / leftover cleanup / startup removal / reinstall prevention
- Passkey / FIDO2 / YubiKey support preserved
- Windows Hello-only sign-in restriction removed
- Privacy / telemetry reductions
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

## Animation policy

The intended outcome on **both Windows 10 and Windows 11** is:

- **Settings > Accessibility > Visual effects > Animation effects = Off**

Implementation rule:

- The script should not rely on registry changes alone.
- It should also apply the corresponding `SystemParametersInfo` animation/UI-effects calls so the change actually sticks on Windows 11.
- The animation fix should remain scoped to animation state only and must not alter unrelated taskbar or Explorer behavior.
- No shell restart should be used for this unless testing proves it is strictly required.

## App installs via `winget`

The current desired install set is:

- `Sysinternals.Autoruns`
- `Brave.Brave`
- `Discord.Discord`
- `Discord.Discord.PTB`
- `ElectronicArts.EADesktop`
- `File-New-Project.EarTrumpet`
- `EpicGames.EpicGamesLauncher`
- `REALiX.HWiNFO`
- `Apple.iTunes`
- `rcmaehl.MSEdgeRedirect`
- `Microsoft.EdgeWebView2Runtime`
- `Microsoft.PowerShell`
- `Microsoft.PowerToys`
- `PuTTY.PuTTY`
- `SlackTechnologies.Slack`
- `Valve.Steam`
- `SublimeHQ.SublimeText.4`
- `SergeySerkov.TagScanner`
- `Telegram.TelegramDesktop`
- `Microsoft.WindowsTerminal`
- `Ubisoft.Connect`
- `VideoLAN.VLC`
- `MartiCliment.UniGetUI`
- `RARLab.WinRAR`
- `WinSCP.WinSCP`
- `Zoom.Zoom`
- `ShareX.ShareX`
- `Obsidian.Obsidian`
- `Proton.ProtonDrive`
- `Proton.ProtonMail`
- `Bambulab.BambuStudio`
- `Elgato.StreamDeck`
- `Logitech.GHUB`
- `RevoUninstaller.RevoUninstallerPro`
- `RockstarGames.Launcher`
- `StartIsBack.StartAllBack` (**Windows 11 only**)

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
- `AssignedAccessManagerSvc` is not redundantly demoted
- Animation handling is explicit and aimed at both Windows 10 and Windows 11

### Added / preserved

- MAS activation at the start
- Store reinstall/bootstrap safeguards
- Desktop setup log
- Deeper telemetry/privacy reductions
- OneDrive leftover cleanup and reinstall prevention
- Passkey/FIDO2 preservation
- Brave debloat after install

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

The repository also includes standalone GPU-driver helper scripts:

- `ItsMauridian-Allow-PowerShell-Scripts.cmd`
- `ItsMauridian-DDU-Auto-Uninstall-GPU-Drivers.ps1`
- `ItsMauridian-DDU-Manual-Uninstall-GPU-Drivers.ps1`
- `ItsMauridian-Install-And-Configure-GPU-Driver.ps1`

## Project rule for future changes

Changes should be **minimal-diff by default**:

- do not change unrelated code
- do not restart the shell unless strictly required
- patch only the block that is actually broken
- provide full updated files when the main file changes

## Credits

- Original script base: FR33THY / WinSux
- Some service-baseline ideas sourced from Chris Titus Tech WinUtil
