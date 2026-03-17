<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# do it for me

```markdown
<div align="center">

# Custom Windows Setup 🪟⚙️

**A repeatable post-install setup script for Windows 10/11 LTSC** with sane defaults, minimal surprises, and opinionated debloat.

[![PowerShell](https://img.shields.io/badge/PowerShell-539E43?style=for-the-badge&logo=powershell&logoColor=white)](https://aka.ms/powershell)
[![Windows 11 LTSC](https://img.shields.io/badge/Target-Win11%20IoT%20LTSC-00CC6A?style=for-the-badge&logo=windows11&logoColor=white)](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/deployment/ltsc-release)
[![Windows 10 LTSC](https://img.shields.io/badge/Supports-Win10%20LTSC%20%7C%20Pro-00BFFF?style=for-the-badge&logo=windows10&logoColor=white)](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/deployment/ltsc-release)
[![GitHub Repo stars](https://img.shields.io/github/stars/ItsMauridian/winsetup?style=social&logo=github)](https://github.com/ItsMauridian/winsetup)
[![Winget](https://img.shields.io/badge/Install%20via-winget-brightgreen?style=for-the-badge&logo=wingset&logoColor=white)](https://winget.run/)

</div>

---

## 🎯 Clean Windows LTSC in 1 command

![Clean Windows LTSC taskbar](https://images.unsplash.com/photo-1461749280684-dccba630e2f6?w=1200&h=600&fit=crop&crop=entropy)
*Optimized taskbar, animations off, privacy hardened, apps ready.*

---

## 🚀 Quick start

```powershell
# Elevated Administrator PowerShell
iwr https://winsetup.m05.dev -useb | iex
```

**Flow:**

```
1. MAS activation ✅
2. Store + winget bootstrap ✅  
3. Apps installed ✅
4. Tweaks & debloat ✅
5. Desktop log saved 📄
```


---

## 📊 Status

| Feature | Status | Notes |
| :-- | :-- | :-- |
| **Win11 IoT LTSC** | 🟢 Working | Latest test VM |
| **Animations** | 🟢 Fixed | Settings → Off |
| **AppX noise** | 🟡 Known | Design choice |
| **Win10 support** | 🟢 Stable | Branch-aware |


---

## 📦 Apps (~35 total)

```mermaid
graph LR
```

A[Essentials] --> B[Autoruns<br/>PowerShell<br/>PowerToys]

```
```

C[Gaming] --> D[EA Desktop<br/>Steam<br/>Ubisoft<br/>Epic]

```
```

E[Productivity] --> F[Discord<br/>Slack<br/>Telegram<br/>Obsidian]

```
```

G[Media] --> H[VLC<br/>iTunes<br/>Brave<br/>ShareX]

```
```

I[Dev/Tools] --> J[WinSCP<br/>PuTTY<br/>Sublime<br/>WingetUI]

```
K[Win11 Only] --> L[StartAllBack]

style A fill:#e1f5fe
style C fill:#f3e5f5
style E fill:#e8f5e8
style K fill:#fff3e0
```

**Gaming:** EA Desktop, Steam, Ubisoft Connect, Epic Launcher, Discord (stable+PTB)
**Media:** VLC, iTunes, Brave, ShareX, HWiNFO
**Productivity:** Obsidian, Telegram, Slack, PowerToys, Windows Terminal

*(Full list in log)*

---

## 🎨 Smart OS detection

```mermaid
flowchart TD
  Start((🔄 Start)) --> CheckOS{Win10 or Win11?}
  CheckOS -->|Win10| Win10[🖥️ Color fix<br/>Legacy BG fix]
  CheckOS -->|Win11| Win11[📱 StartAllBack<br/>Remove Home/Gallery]
```

Win10 --> Shared[⚙️ Animations Off<br/>Explorer→This PC<br/>OneDrive nuke]

```
Win11 --> Shared
Shared --> MAS[🔑 MAS activation]
Shared --> Winget[🛒 Store bootstrap]
Shared --> Apps[📦 App installs]
Shared --> Log((📄 Log))

style Start fill:#e3f2fd
style Log fill:#e8f5e8
```

**Always shared:** Privacy max, telemetry min, taskbar clean, passkeys preserved.

---

## ⚠️ Expected log noise

```
✅ Ignore:
❌ Missing files (already gone)
❌ VM GUID mismatches  
❌ AppX built-in errors
❌ Files temporarily locked

🛑 Real issues:
❌ MAS failed
❌ Winget bootstrap failed
❌ Animation didn't stick
```


---

## 🔄 vs Upstream WinSux

| Removed | Changed | Added |
| :-- | :-- | :-- |
| Black lockscreen | Taskbar: cleanup only | MAS first |
| YubiKey block | Edge: keep WebView2 | Store bootstrap |
| Forced alignment | Animations: SPI+reg | Desktop log |
| Hello-only login | Services: less aggressive | Brave debloat |


---

## 🛠️ GPU helpers included

| Script | Purpose |
| :-- | :-- |
| `Allow-PS-Scripts.cmd` | Enable execution policy |
| `DDU-Auto-GPU.ps1` | Automated driver wipe |
| `DDU-Manual-GPU.ps1` | Manual driver wipe |
| `Install-GPU.ps1` | Clean driver install |


---

## 🤝 Rules

1. **Minimal-diff** changes
2. No shell restarts unless required
3. Test Win10 + Win11 LTSC
4. Full files in PRs

---

<div align="center">

![Windows setup](https://images.unsplash.com/photo-1558494949-ef0d38d3ab69?w=400&h=200&fit=crop)  
**Forked from** [![FR33THY](https://img.shields.io/badge/Fork%20of-WinSux-black?style=for-the-badge&logo=github&logoColor=white)](https://github.com/FR33THY/WinSux)  
**Inspired by** [![Chris Titus](https://img.shields.io/badge/Inspired-Chris%20Titus%20WinUtil-blue?style=for-the-badge&logo=youtube&logoColor=white)](https://github.com/ChrisTitusTech/winutil)

</div>