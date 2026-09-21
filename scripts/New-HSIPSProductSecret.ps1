# ==========================================================
# HS_IP_PS Product Secret Generator
# Creates a 32-byte random product secret.
# The secret is stored in keys\private and must never be distributed.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

$productConfigPath = Join-Path $Root "config\products\$ProductCode.json"

if (-not (Test-Path $productConfigPath)) {
    throw "Product configuration not found: $productConfigPath"
}

$privateKeyDir = Join-Path $Root "keys\private"
Assert-HSIPSWritePath -Path $privateKeyDir

if (-not (Test-Path $privateKeyDir)) {
    New-Item -ItemType Directory -Path $privateKeyDir -Force | Out-Null
}

$secretPath = Join-Path $privateKeyDir "${ProductCode}_product_secret.bin"

if (Test-Path $secretPath) {
    throw "Product secret already exists: $secretPath"
}

$secretBytes = New-Object byte[] 32

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($secretBytes)
$rng.Dispose()

Assert-HSIPSWritePath -Path $secretPath

# FIX B14: WriteAllBytes works on Windows PowerShell 5.1 AND PowerShell 7.
[System.IO.File]::WriteAllBytes($secretPath, $secretBytes)

Write-Host "Product secret created." -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Secret file : $secretPath"
Write-Host ""
Write-Host "WARNING: Never distribute this file." -ForegroundColor Yellow
