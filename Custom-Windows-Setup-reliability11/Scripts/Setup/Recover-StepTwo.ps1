# SCRIPT RUN AS ADMIN
# BUILD MARKER: reliability11 2026-07-10 - one-command StepTwo recovery
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host 'Open PowerShell as Administrator and run the recovery command again.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$rawBase = 'https://raw.githubusercontent.com/ItsMauridian/Custom-Windows-Setup/refs/heads/main'
$workRoot = Join-Path $env:ProgramData 'ItsMauridian\Custom-Windows-Setup'
$stepTwoPath = Join-Path $workRoot 'StepTwo.ps1'
$resumePath = Join-Path $workRoot 'Resume-StepTwo.ps1'
$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

New-Item -Path $workRoot -ItemType Directory -Force | Out-Null

# Ensure the next restart is a normal Windows boot. It is harmless when no
# safeboot value is present.
& "$env:SystemRoot\System32\bcdedit.exe" /deletevalue '{current}' safeboot 2>$null | Out-Null

$downloads = @(
    @{ Uri = "$rawBase/Scripts/Setup/StepTwo.ps1?nocache=$stamp"; Path = $stepTwoPath },
    @{ Uri = "$rawBase/Scripts/Setup/Resume-StepTwo.ps1?nocache=$stamp"; Path = $resumePath }
)

foreach ($download in $downloads) {
    $temporaryPath = "$($download.Path).download"
    Invoke-WebRequest -Uri $download.Uri -UseBasicParsing -TimeoutSec 90 -OutFile $temporaryPath
    Move-Item -LiteralPath $temporaryPath -Destination $download.Path -Force
}

foreach ($scriptPath in @($stepTwoPath, $resumePath)) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object {
            "Line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber): $($_.Message)"
        }) -join [Environment]::NewLine
        throw ("Downloaded script failed syntax validation: {0}{1}{2}" -f $scriptPath, [Environment]::NewLine, $details)
    }
}

if (-not (Select-String -Path $stepTwoPath -Pattern 'BUILD MARKER: reliability11' -Quiet)) {
    throw 'GitHub is not serving the reliability11 StepTwo.ps1 file yet.'
}
if (-not (Select-String -Path $resumePath -Pattern 'BUILD MARKER: reliability11' -Quiet)) {
    throw 'GitHub is not serving the reliability11 Resume-StepTwo.ps1 file yet.'
}

Remove-Item -LiteralPath (Join-Path $workRoot 'StepTwo.completed') -Force -ErrorAction SilentlyContinue
Write-Host 'Recovery files downloaded and validated. Starting StepTwo now.' -ForegroundColor Green
& $resumePath
