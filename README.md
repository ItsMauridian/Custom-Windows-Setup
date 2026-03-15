# Custom Windows Setup
A personal fork of [FR33THY's WinSux](https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide) with additional tweaks, app installs, and personalizations for my own Windows setup.

## Run
Paste this into an elevated Administrator PowerShell window:
```
iwr https://winsetup.m05.dev -useb | iex
```

## What it does
- Runs Windows activation via MAS at the start
- Installs and configures apps via winget (Brave, Chrome, ShareX, Obsidian, Steam, Discord, and more)
- Applies privacy, performance, and usability tweaks
- Removes bloatware, OneDrive, Microsoft Edge, Copilot, Xbox components
- Configures Windows settings to personal preference

## Changes from original

### Removed
- Black lockscreen and wallpaper enforcement
- Force left taskbar alignment (set to centered/Windows 11 default)
- Hide recycle bin from desktop and start menu shortcut
- Show all taskbar icons (restores the pop-out arrow)
- 100% DPI scaling override (allows per-monitor scaling e.g. 125%)
- Pause Windows Updates for 365 days
- Disable automatic Microsoft Store app updates
- Prevent driver downloads via Windows Update
- Remove Scan with Defender from context menu
- Disable YubiKey/FIDO2 passkey access
- Force Windows Hello only sign-in
- Remove security taskbar icon
- Wipe entire Program Files (x86)\Microsoft folder (preserves WebView2 for apps like Snapchat)
- Winget being uninstalled after use
- New Outlook being removed

### Changed
- Edge folder removal now only targets Edge/EdgeUpdate/EdgeCore subfolders (preserves WebView2)
- Taskbar alignment set to centered
- ColorPrevalence set to 0 (fixes unreadable text on Windows 10)
- Removed black desktop background color setting (was causing invisible sidebar text on Windows 10)
- Brave, ShareX and Obsidian moved from direct download to winget

### Added
**Activation & Setup**
- Windows activation via MAS (get.activated.win) runs at the very start
- Warning prompt before Store settings page opens
- wsreset -i to reinstall Microsoft Store if missing

**Privacy & Telemetry**
- Comprehensive telemetry block: DiagTrack, wermgr, AdvertisingInfo, Input TIPC, OnlineSpeechPrivacy, SvcHostSplitThresholdInKB, PowerShell and .NET CLI telemetry
- Activity History disabled (EnableActivityFeed, UploadUserActivities)
- Copilot deep removal: appx packages, IsCopilotAvailable, AllowCopilotRuntime, CoreAI package
- Xbox & Gaming Components appx removal
- Widgets appx removal
- OneDrive: leftover folder removal, startup removal, reinstall prevention

**Performance**
- NetworkThrottlingIndex and SystemResponsiveness tweaks
- Nagle's algorithm disabled on all network adapters
- SysMain (Superfetch) disabled
- HPET disabled via bcdedit
- Prefer IPv4 over IPv6 + Disable Teredo (DisabledComponents=0x21)
- Services set to Manual (~100 services per CTT list)
- Disable Multiplane Overlay (MPO)
- Modern Standby fix (EnforceDisconnectedStandby)

**Network**
- netsh teredo set state disabled
- Prefer IPv4 over IPv6

**Usability**
- Confirm file delete dialog
- Enable text suggestions on physical keyboard + multilingual suggestions
- Show hidden files (without system files like desktop.ini)
- Num Lock on startup
- Centered taskbar alignment
- Verbose logon/logoff messages
- ShowHibernateOption=0
- Background apps GlobalUserDisabled
- Explorer Automatic Folder Discovery disabled

**Security**
- YubiKey/FIDO2 passkey access restored (removed original blocks)
- Windows Hello only sign-in removed (allows security key PIN prompt)
- Passkey and passkey enumeration access restored

**App Installs (via winget)**
Autoruns, Brave, Discord, EA App, EarTrumpet, Epic Games Launcher, HWiNFO, iTunes, MSEdgeRedirect, Obsidian, PowerToys, PuTTY, ShareX, Slack, Steam, Sublime Text, TagScanner, Telegram, Windows Terminal, Ubisoft Connect, VLC, UniGetUI, WinRAR, WinSCP, Zoom

**Brave**
- Debloat registry keys applied after install: Rewards, Wallet, VPN, AI Chat and Stats Ping all disabled

## Other Scripts
The `/Graphics` folder contains standalone tools for GPU driver management:
- **ItsMauridian-Allow-PowerShell-Scripts.cmd** — run this first on a fresh Windows install to allow PowerShell scripts to execute
- **ItsMauridian-DDU-Auto-Uninstall-GPU-Drivers.ps1** — automatically uninstalls GPU drivers via DDU in safe mode
- **ItsMauridian-DDU-Manual-Uninstall-GPU-Drivers.ps1** — opens DDU manually so you can choose what to uninstall
- **ItsMauridian-Install-And-Configure-GPU-Driver.ps1** — installs and configures your GPU driver with optimized settings

## Credits
Original script by [FR33THY](https://www.youtube.com/FR33THY)
