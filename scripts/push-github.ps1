# Push to https://github.com/AgpVectorial/agp_wearhub_ios

$ErrorActionPreference = "Continue"
$FlutterRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $FlutterRoot

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "Install GitHub CLI: winget install GitHub.cli" -ForegroundColor Red
    exit 1
}

gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Paste your GitHub Personal Access Token (starts with ghp_):" -ForegroundColor Yellow
    $token = Read-Host -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))
    $plain | gh auth login --hostname github.com --git-protocol https --with-token
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# Make git use the same account as gh (fixes 403 when wrong user is cached)
gh auth setup-git 2>$null | Out-Null

$remoteUrl = "https://github.com/AgpVectorial/agp_wearhub_ios.git"
$hasOrigin = git remote get-url origin 2>$null
if (-not $hasOrigin) {
    git remote add origin $remoteUrl
} else {
    git remote set-url origin $remoteUrl
}

# Use main branch (GitHub default)
git branch -M main

Write-Host "Pushing to $remoteUrl ..." -ForegroundColor Cyan
git push -u origin main 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "SUCCESS: https://github.com/AgpVectorial/agp_wearhub_ios" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Push failed. Run: gh auth setup-git" -ForegroundColor Red
    Write-Host "Then: git push -u origin main" -ForegroundColor Red
    exit 1
}
