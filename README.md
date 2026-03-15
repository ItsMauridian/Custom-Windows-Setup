# Custom Windows Setup
A personal fork of [FR33THY's WinSux](https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide) with additional tweaks, app installs, and personalizations for my own Windows setup.

## Run
Paste this into an elevated Administrator PowerShell window:
```
iwr https://winsetup.m05.dev -useb | iex
```

## What it does
- Runs Windows activation via MAS
- Installs and configures apps (Brave, Chrome, ShareX, Obsidian, Steam, Discord, and more)
- Applies privacy, performance, and usability tweaks
- Removes bloatware, OneDrive, Microsoft Edge, Copilot, Xbox components
- Configures Windows settings to personal preference

## Other Scripts
The `/Graphics` folder contains standalone tools for GPU driver management:
- **ItsMauridian-Allow-PowerShell-Scripts.cmd** — run this first to allow PowerShell scripts to execute
- **ItsMauridian-DDU-Auto-Uninstall-GPU-Drivers.ps1** — automatically uninstalls GPU drivers via DDU in safe mode
- **ItsMauridian-DDU-Manual-Uninstall-GPU-Drivers.ps1** — opens DDU manually so you can choose what to uninstall
- **ItsMauridian-Install-And-Configure-GPU-Driver.ps1** — installs and configures your GPU driver with optimized settings

## Credits
Original script by [FR33THY](https://www.youtube.com/FR33THY)
