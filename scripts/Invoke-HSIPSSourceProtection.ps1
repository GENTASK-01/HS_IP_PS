# ==========================================================
# HS_IP_PS Source Protection Orchestrator
# Regenerates source_work from source_original and applies
# sanitization, obfuscation, and string protection.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [ValidateSet("none", "sensitive_only", "all")]
    [string]$StringMode = "none"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Source Protection Orchestrator" -ForegroundColor Cyan

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

$configPath = Join-Path $Root "config\hsips.json"
$productConfigPath = Join-Path $Root "config\products\$ProductCode.json"

if (-not (Test-Path $configPath)) {
    throw "HS_IP_PS configuration not found: $configPath"
}

if (-not (Test-Path $productConfigPath)) {
    throw "Product configuration not found: $productConfigPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
$productConfig = Get-Content -Path $productConfigPath -Raw | ConvertFrom-Json

$pythonExe = $config.tools.python
if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path $pythonExe)) {
    $pythonExe = "python"
}

$scriptPath = Join-Path $Root "scripts\hsips_source_protect.py"

if (-not (Test-Path $scriptPath)) {
    throw "Python protection script not found: $scriptPath"
}

# ------------------------------------------------------------
# Define work paths
# ------------------------------------------------------------

$sourceOriginal = $productConfig.source.source_root
$entryFile = $productConfig.source.entry_file
$workRoot = Join-Path $Root "source_work\$ProductCode"
$workSrc = Join-Path $workRoot "src"

Assert-HSIPSWritePath -Path $workRoot
Assert-HSIPSWritePath -Path $workSrc

if (-not (Test-Path $sourceOriginal)) {
    throw "Original source root not found: $sourceOriginal"
}

# ------------------------------------------------------------
# Clean and recreate work folder
# ------------------------------------------------------------

if (Test-Path $workRoot) {
    Write-Host "Cleaning existing work folder: $workRoot"
    Remove-Item -Path $workRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $workSrc -Force | Out-Null

Write-Host "Copying source_original to source_work..."
Copy-Item -Path "$sourceOriginal\*" -Destination $workSrc -Recurse -Force

# ------------------------------------------------------------
# Determine prefix
# ------------------------------------------------------------

$prefix = ""

if ($productConfig.PSObject.Properties.Name -contains "protection") {
    if ($productConfig.protection.PSObject.Properties.Name -contains "identifier_prefix") {
        $prefix = [string]$productConfig.protection.identifier_prefix
    }
}

if ([string]::IsNullOrWhiteSpace($prefix)) {
    Write-Warning "No identifier_prefix configured. Identifier obfuscation will run in compatibility mode."
} else {
    Write-Host "Identifier prefix detected: $prefix"
}

# ------------------------------------------------------------
# Run Python protection engine
# ------------------------------------------------------------

& $pythonExe $scriptPath `
    --source-root $workSrc `
    --entry $entryFile `
    --product-code $ProductCode `
    --product-name $productConfig.product_name `
    --string-mode $StringMode `
    --audit-dir "$Root\audit" `
    $(if (-not [string]::IsNullOrWhiteSpace($prefix)) { @("--prefix", $prefix) } else { @() })

if ($LASTEXITCODE -ne 0) {
    throw "HS_IP_PS source protection failed. See output above."
}

Write-Host ""
Write-Host "Source protection completed." -ForegroundColor Green
Write-Host "Protected working source: $workSrc" -ForegroundColor Green
