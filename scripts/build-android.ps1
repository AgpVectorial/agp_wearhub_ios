# Build AGP Wear Hub APK on Windows
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build-android.ps1

$ErrorActionPreference = "Stop"
$Flutter = "C:\flutter\bin\flutter.bat"

if (-not (Test-Path $Flutter)) {
    Write-Host "Flutter not found at C:\flutter. Install from https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Red
    exit 1
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

Write-Host "==> flutter pub get" -ForegroundColor Cyan
& $Flutter pub get

Write-Host "==> flutter build apk --release" -ForegroundColor Cyan
& $Flutter build apk --release

$Apk = Join-Path $Root "build\app\outputs\flutter-apk\app-release.apk"
if (Test-Path $Apk) {
    Write-Host ""
    Write-Host "SUCCESS: $Apk" -ForegroundColor Green
    Write-Host "Install on phone: adb install -r `"$Apk`"" -ForegroundColor Yellow
} else {
    Write-Host "Build finished but APK not found at expected path." -ForegroundColor Red
    exit 1
}
