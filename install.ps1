# ═══════════════════════════════════════════════════════════════════════
#  install.ps1 — Windows PowerShell Installer
#  Configures Git Bash bridge, creates native dl.cmd and tiktok.cmd
# ═══════════════════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Media Pipeline Installer (Windows PowerShell)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate Git Bash
$gitBashPaths = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)

$bashExe = $null
foreach ($path in $gitBashPaths) {
    if (Test-Path $path) {
        $bashExe = $path
        break
    }
}

if (-not $bashExe) {
    $found = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($found) { $bashExe = $found.Source }
}

if (-not $bashExe) {
    Write-Error "Git Bash was not found. Please install Git for Windows (https://git-scm.com/download/win) and retry."
    exit 1
}

Write-Host "[✓] Git Bash found: $bashExe" -ForegroundColor Green

# 2. Run the bash installer
Write-Host "[*] Running environment configuration via Git Bash..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& $bashExe "$scriptDir/install.sh"

# 3. Create native Windows CLI wrappers in WindowsApps (already in PATH)
$windowsAppsDir = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
if (Test-Path $windowsAppsDir) {
    $dlCmd = @"
@echo off
setlocal
set "BASH_BIN=$bashExe"
"%BASH_BIN%" -c "export PATH=\"/c/Users/AVS/AppData/Local/Programs/Python/Python314/Lib/site-packages/static_ffmpeg/bin/win32:/c/Users/AVS/AppData/Local/Programs/Python/Python314/Scripts:`$HOME/.local/bin:`$PATH\"; dl %*"
"@
    Set-Content -Path "$windowsAppsDir\dl.cmd" -Value $dlCmd -Encoding ASCII

    $tiktokCmd = @"
@echo off
setlocal
set "BASH_BIN=$bashExe"
"%BASH_BIN%" -c "export PATH=\"/c/Users/AVS/AppData/Local/Programs/Python/Python314/Lib/site-packages/static_ffmpeg/bin/win32:/c/Users/AVS/AppData/Local/Programs/Python/Python314/Scripts:`$HOME/.local/bin:`$PATH\"; tiktok %*"
"@
    Set-Content -Path "$windowsAppsDir\tiktok.cmd" -Value $tiktokCmd -Encoding ASCII

    Write-Host "[✓] Windows commands registered in: $windowsAppsDir" -ForegroundColor Green
    Write-Host "    - dl.cmd" -ForegroundColor Green
    Write-Host "    - tiktok.cmd" -ForegroundColor Green
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete! You can now run directly in PowerShell:" -ForegroundColor Cyan
Write-Host "    dl <URL>" -ForegroundColor Yellow
Write-Host "    tiktok" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Cyan
