# Code review checks

This pass focused on stability, security defaults, current upstream patterns, and packaging the repository back in its original GitHub-ready structure.

## Static checks performed in this sandbox

- Checked for remaining active old security downgrade writes:
  - `EnableLUA=0`
  - `RunAsPPL=0`
  - `VulnerableDriverBlocklistEnable=0`
  - HVCI disable writes
  - kernel `MitigationOptions` overwrites
  - SmartScreen, PUA, WTDS, phishing, Tamper Protection, Controlled Folder Access and Exploit Guard disable writes
- Checked for old download references:
  - 7-Zip 23.01
  - DDU 18.1.4.2
- Checked for old connectivity checks:
  - `Test-Connection 8.8.8.8`
- Checked for removed app IDs:
  - `Brave.Brave`
  - `PuTTY.PuTTY`
- Checked for active `reg add ... Userinit` handoffs. None remain.
- Checked here-string headers and terminators for obvious split/extraction damage.
- Removed duplicate GPU helper copies; GPU helper scripts now exist only in `Graphics/`.
- Tested the final zip integrity with `unzip -t`.

## Important limitation

This Linux sandbox does not have Windows PowerShell or PowerShell 7 installed, so I could not run a real Windows PowerShell AST parser or a VM execution test here. The repository includes `.github/workflows/powershell-parse.yml`, which runs parser checks on `windows-latest` after you push.

## Extra review improvements in this pass

- Replaced the remaining standalone DDU helper `Winlogon\Userinit` handoff with `HKCU\...\RunOnce` using the Safe Mode `*` prefix.
- Kept a guarded cleanup path for old builds that may have left `DDU.ps1` or `StepOne.ps1` in `Userinit`.
- Preserved Chrome and Brave update tasks/services so installed browsers do not become stale.
- Restored Windows driver searching to enabled after the main setup registry pass. DDU still handles temporary Windows Update blocking during driver cleanup.

- Fixed DDU 18.1.5.5 extraction path handling: the scripts now search for the real `Display Driver Uninstaller.exe`, create the `Settings` folder if needed, and reuse the detected path in Safe Mode.
