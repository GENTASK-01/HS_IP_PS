# ==========================================================
# HS_IP_PS Product Version Setter
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

if ($Version -notmatch "^\d+\.\d+\.\d+$") {
    throw "Version must be MAJOR.MINOR.PATCH, for example 1.0.0."
}

$configPath = Join-Path $Root "config\products\$ProductCode.json"

if (-not (Test-Path $configPath)) {
    throw "Product configuration not found: $configPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

$config.product_version = $Version

Assert-HSIPSWritePath -Path $configPath

$config | ConvertTo-Json -Depth 12 | Set-Content -Path $configPath -Encoding UTF8

Write-Host "Product version updated." -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Version     : $Version"
