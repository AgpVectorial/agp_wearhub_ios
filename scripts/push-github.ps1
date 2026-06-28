# Push to https://github.com/AgpVectorial/agp_wearhub_ios
# GitHub needs a Personal Access Token, not your password.
# Create one at: https://github.com/settings/tokens/new (scope: repo)

$ErrorActionPreference = "Stop"
$FlutterRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $FlutterRoot

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "Install GitHub CLI: winget install GitHub.cli" -ForegroundColor Red
    exit 1
}

$loggedIn = $false
try {
    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $loggedIn = $true }
} catch {
    $loggedIn = $false
}

if (-not $loggedIn) {
    Write-Host "Paste your GitHub Personal Access Token (starts with ghp_):" -ForegroundColor Yellow
    $token = Read-Host -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))
    $plain | gh auth login --hostname github.com --git-protocol https --with-token
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

Write-Host "Creating repo AgpVectorial/agp_wearhub_ios..." -ForegroundColor Cyan
gh repo create AgpVectorial/agp_wearhub_ios --public --source=. --remote=origin --push --description "AGP Wear Hub iOS QCBandSDK" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Repo may already exist, trying push..." -ForegroundColor Yellow
    $hasOrigin = git remote get-url origin 2>$null
    if (-not $hasOrigin) {
        git remote add origin https://github.com/AgpVectorial/agp_wearhub_ios.git
    }
    git branch -M main
    git push -u origin main
}

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "SUCCESS: https://github.com/AgpVectorial/agp_wearhub_ios" -ForegroundColor Green
} else {
    Write-Host "Push failed. Check your token has repo scope and you are logged into AgpVectorial." -ForegroundColor Red
    exit 1
}
