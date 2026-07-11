@echo off
setlocal
set "PS64=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS64=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    "%PS64%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
"%PS64%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Setup\Repair-Current-Install.ps1"
endlocal
