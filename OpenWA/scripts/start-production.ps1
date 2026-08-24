# =============================================================================
# OpenWA - Production Startup & Verification Script (Windows Server / PowerShell)
# =============================================================================

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  🚀 OpenWA - Production Service Startup Checks (Windows)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Check Node.js
try {
    $nodeVer = node -v
    Write-Host "✓ Node.js version: $nodeVer" -ForegroundColor Green
} catch {
    Write-Host "✗ Node.js is not found in PATH!" -ForegroundColor Red
    Exit 1
}

# 2. Check and load .env
if (Test-Path ".env") {
    Write-Host "✓ Found .env file" -ForegroundColor Green
} else {
    if (Test-Path ".env.production.example") {
        Write-Host "⚠ .env not found. Copying from .env.production.example..." -ForegroundColor Yellow
        Copy-Item ".env.production.example" ".env"
    } elseif (Test-Path ".env.example") {
        Write-Host "⚠ .env not found. Copying from .env.example..." -ForegroundColor Yellow
        Copy-Item ".env.example" ".env"
    }
}

# 3. Create required directories
$dirs = @("data\sessions", "data\media", "data\plugins", "data\logs")
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
Write-Host "✓ Data directories verified (data\sessions, data\media, data\logs)" -ForegroundColor Green

# 4. Check Backend Build
if (-not (Test-Path "dist\main.js")) {
    Write-Host "⚡ dist\main.js not found. Building Backend..." -ForegroundColor Yellow
    npm run build
}
Write-Host "✓ Backend build verified" -ForegroundColor Green

# 5. Check Dashboard Build
if ((Test-Path "dashboard") -and (-not (Test-Path "dashboard\dist\index.html"))) {
    Write-Host "⚡ dashboard\dist not found. Building Dashboard..." -ForegroundColor Yellow
    npm run dashboard:build
}

# 6. Start the Service
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Starting OpenWA Service in Production Mode...        " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green

$env:NODE_ENV = "production"

if (Get-Command pm2 -ErrorAction SilentlyContinue) {
    Write-Host "ℹ PM2 detected. Starting via PM2..." -ForegroundColor Cyan
    pm2 start ecosystem.config.js --env production
    pm2 save
    Write-Host "✓ OpenWA running under PM2. Run 'pm2 logs openwa-service' to monitor." -ForegroundColor Green
} else {
    node dist\main.js
}
