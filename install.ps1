<#
.SYNOPSIS
    Automated installer for the Media Processing Pipeline on Windows PowerShell.
.DESCRIPTION
    Configures the environment, bridges to Git Bash, and registers global native
    Windows commands ('dl' and 'tiktok') into the user's PATH.
.NOTES
    Author:  Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
    License: MIT
    Version: 2.1.0
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Media Pipeline Installer (Windows PowerShell)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ── 1. Locate Git Bash ────────────────────────────────────────────────────────
$knownBashPaths = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
    "$env:ProgramW6432\Git\bin\bash.exe"
)

$bashExe = $null
foreach ($path in $knownBashPaths) {
    if (Test-Path -LiteralPath $path) {
        $bashExe = $path
        break
    }
}

if (-not $bashExe) {
    $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cmd) { $bashExe = $cmd.Source }
}

if (-not $bashExe) {
    Write-Host ""
    Write-Error "Git Bash was not found on this system. Please install Git for Windows (https://git-scm.com/download/win) and rerun this installer."
    exit 1
}

Write-Host "[✓] Located Git Bash runtime: $bashExe" -ForegroundColor Green

# ── 2. Run Base Environment Configuration ────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "[*] Configuring workspace directories and scripts..." -ForegroundColor Yellow
& $bashExe "$scriptDir/install.sh"

# ── 3. Register Native Windows CLI Wrappers ──────────────────────────────────
$targetBinDir = "$env:LOCALAPPDATA\Microsoft\WindowsApps"

if (Test-Path -LiteralPath $targetBinDir) {
    Write-Host "[*] Creating native Windows CLI wrappers in $targetBinDir..." -ForegroundColor Yellow

    # dl.cmd wrapper
    $dlCmdContent = @"
@echo off
setlocal
set "BASH_BIN=$bashExe"
if not exist "%BASH_BIN%" (
    for /f "delims=" %%i in ('where bash 2^>nul') do set "BASH_BIN=%%i"
)
if not exist "%BASH_BIN%" (
    echo [ERROR] Git Bash was not found. Please install Git for Windows.
    exit /b 1
)
"%BASH_BIN%" -c "export PATH=\"/c/Users/AVS/AppData/Local/Programs/Python/Python314/Lib/site-packages/static_ffmpeg/bin/win32:/c/Users/AVS/AppData/Local/Programs/Python/Python314/Scripts:`$HOME/.local/bin:`$PATH\"; dl %*"
"@
    Set-Content -LiteralPath "$targetBinDir\dl.cmd" -Value $dlCmdContent -Encoding ASCII

    # tiktok.cmd wrapper
    $tiktokCmdContent = @"
@echo off
setlocal
set "BASH_BIN=$bashExe"
if not exist "%BASH_BIN%" (
    for /f "delims=" %%i in ('where bash 2^>nul') do set "BASH_BIN=%%i"
)
if not exist "%BASH_BIN%" (
    echo [ERROR] Git Bash was not found. Please install Git for Windows.
    exit /b 1
)
"%BASH_BIN%" -c "export PATH=\"/c/Users/AVS/AppData/Local/Programs/Python/Python314/Lib/site-packages/static_ffmpeg/bin/win32:/c/Users/AVS/AppData/Local/Programs/Python/Python314/Scripts:`$HOME/.local/bin:`$PATH\"; tiktok %*"
"@
    Set-Content -LiteralPath "$targetBinDir\tiktok.cmd" -Value $tiktokCmdContent -Encoding ASCII

    Write-Host "[✓] Successfully registered commands: 'dl' and 'tiktok'" -ForegroundColor Green
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete! You can now run in PowerShell:" -ForegroundColor Cyan
Write-Host "    dl <URL>" -ForegroundColor Yellow
Write-Host "    tiktok" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
