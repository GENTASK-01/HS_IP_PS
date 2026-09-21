# ==========================================================
# HS_IP_PS Obfuscation Prefix Setter
# Sets protection.identifier_prefix in product config.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $true)]
    [string]$Prefix
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

if ($Prefix -notmatch "^[A-Z][A-Z0-9]{1,11}_$") {
    throw "Prefix must be 3-12 characters, start with A-Z, use A-Z or 0-9, and end with underscore. Example: NSX_"
}

$configPath = Join-Path $Root "config\products\$ProductCode.json"

if (-not (Test-Path $configPath)) {
    throw "Product configuration not found: $configPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

if (-not ($config.PSObject.Properties.Name -contains "protection")) {
    $config | Add-Member -NotePropertyName protection -NotePropertyValue @{} -Force
}

if ($config.protection -is [System.Management.Automation.PSCustomObject]) {
    $config.protection | Add-Member -NotePropertyName identifier_prefix -NotePropertyValue $Prefix -Force
} else {
    $newProtection = [pscustomobject]@{
        identifier_prefix = $Prefix
    }

    $config.protection = $newProtection
}

$configJson = $config | ConvertTo-Json -Depth 12
Assert-HSIPSWritePath -Path $configPath

Set-Content -Path $configPath -Value $configJson -Encoding UTF8

Write-Host "Obfuscation prefix configured." -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Prefix      : $Prefix"
