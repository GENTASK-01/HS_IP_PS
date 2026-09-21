# ==========================================================
# HS_IP_PS Product Creator
# Creates a new protected product entry.
# Writes only inside the project root.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $true)]
    [string]$ProductName,

    [Parameter(Mandatory = $false)]
    [string]$Version = "1.0.0",

    [Parameter(Mandatory = $true)]
    [string]$EntryFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet(
        "TRIAL",
        "DEMO",
        "LIVE_SINGLE_ACCOUNT",
        "LIVE_MULTI_ACCOUNT",
        "PERPETUAL",
        "CUSTOM"
    )]
    [string]$LicenseProfile = "LIVE_SINGLE_ACCOUNT",

    [Parameter(Mandatory = $false)]
    [bool]$AllowDll = $false,

    [Parameter(Mandatory = $false)]
    [bool]$AllowWebRequest = $false
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Product Creator" -ForegroundColor Cyan

# ------------------------------------------------------------
# Validate inputs
# ------------------------------------------------------------

if ($ProductCode -notmatch "^[A-Z0-9][A-Z0-9_\-]{3,31}$") {
    throw "ProductCode must be 4-32 characters and use only A-Z, 0-9, underscore, and hyphen."
}

if ($Version -notmatch "^\d+\.\d+\.\d+$") {
    throw "Version must use semantic format MAJOR.MINOR.PATCH, for example 1.0.0."
}

if ($EntryFile -notmatch "^[A-Za-z0-9_\-\.]+\.mq5$") {
    throw "EntryFile must be a valid .mq5 file name without spaces or special characters."
}

$productConfigDir = Join-Path $Root "config\products"
$productConfigPath = Join-Path $productConfigDir "$ProductCode.json"

if (Test-Path $productConfigPath) {
    throw "Product already exists: $ProductCode"
}

# ------------------------------------------------------------
# Create source folders
# ------------------------------------------------------------

$sourceRoot = Join-Path $Root "source_original\$ProductCode"

$folders = @(
    "$sourceRoot\src",
    "$sourceRoot\resources",
    "$sourceRoot\docs",
    "$sourceRoot\meta"
)

foreach ($folder in $folders) {
    Assert-HSIPSWritePath -Path $folder

    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Host "Created: $folder"
    }
}

# ------------------------------------------------------------
# Build product configuration
# ------------------------------------------------------------

$productUuid = [guid]::NewGuid().ToString()

$product = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    product_uuid = $productUuid
    product_name = $ProductName
    product_version = $Version

    source = [ordered]@{
        source_root = "$sourceRoot\src"
        entry_file = $EntryFile
        entry_path = "$sourceRoot\src\$EntryFile"
    }

    license_profile = $LicenseProfile

    license_defaults = [ordered]@{
        license_required = $true
        fail_closed = $true
        allow_new_orders_without_license = $false
        trial_days = 0
        max_accounts = 1
        allow_demo_accounts = $true
        allow_live_accounts = $false
        allow_tester = $false
        allow_optimization = $false
        clock_rollback_tolerance_hours = 12
        account_binding_required = $true
        server_binding_required = $true
        broker_binding_required = $false
        terminal_binding_required = $false
        expiration_behavior = "BLOCK_NEW_ORDERS"
    }

    protection = [ordered]@{
        obfuscation_enabled = $true
        string_encryption_enabled = $true
        resource_encryption_enabled = $true
        anti_tamper_enabled = $true
        environment_binding_enabled = $true
        license_module_enabled = $true
        log_protection_events = $true
        reveal_internal_errors = $false
    }

    compatibility = [ordered]@{
        windows = $true
        macos = $true
        require_dll = $AllowDll
        allow_web_request = $AllowWebRequest
        pure_mql5_preferred = (-not $AllowDll)
    }

    build = [ordered]@{
        compile_timeout_seconds = 300
        fail_on_compile_error = $true
        max_warnings = 0
        clean_work_folder_before_build = $true
        generate_build_id = $true
        generate_obfuscation_map = $true
        hash_algorithm = "SHA256"
        package_format = "zip"
    }

    distribution = [ordered]@{
        include_source = $false
        include_mqh = $false
        include_private_keys = $false
        include_scripts = $false
        include_logs = $false
        include_audit = $false
        include_docs = $true
        include_checksums = $true
        include_license_template = $true
    }

    created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# ------------------------------------------------------------
# Save product configuration
# ------------------------------------------------------------

Assert-HSIPSWritePath -Path $productConfigDir

if (-not (Test-Path $productConfigDir)) {
    New-Item -ItemType Directory -Path $productConfigDir -Force | Out-Null
}

$productJson = $product | ConvertTo-Json -Depth 12
Set-Content -Path $productConfigPath -Value $productJson -Encoding UTF8

Write-Host "Created product config: $productConfigPath" -ForegroundColor Green

# ------------------------------------------------------------
# Update product registry
# ------------------------------------------------------------

$registryPath = Join-Path $Root "config\products.json"

$registryItem = [pscustomobject]@{
    product_code = $ProductCode
    product_uuid = $productUuid
    product_name = $ProductName
    product_version = $Version
    config_path = $productConfigPath
    source_path = "$sourceRoot\src"
    created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if (Test-Path $registryPath) {
    $registryRaw = Get-Content -Path $registryPath -Raw | ConvertFrom-Json

    if ($null -eq $registryRaw.products) {
        $registryRaw | Add-Member -NotePropertyName products -NotePropertyValue @() -Force
    }

    $existing = @($registryRaw.products) | Where-Object { $_.product_code -eq $ProductCode }

    if ($existing) {
        throw "Product already exists in registry: $ProductCode"
    }

    $newProducts = @($registryRaw.products) + $registryItem
    $registryRaw.products = $newProducts
    $registryRaw.updated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $registryRaw | ConvertTo-Json -Depth 12 | Set-Content -Path $registryPath -Encoding UTF8
} else {
    $registry = [ordered]@{
        schema_version = 1
        updated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        products = @($registryItem)
    }

    $registry | ConvertTo-Json -Depth 12 | Set-Content -Path $registryPath -Encoding UTF8
}

Write-Host "Updated product registry: $registryPath" -ForegroundColor Green

# ------------------------------------------------------------
# Create intake placeholder
# ------------------------------------------------------------

$intakeNote = @'
Place the Expert Advisor source code inside the src folder.

Required entry file location:
src\ENTRY_FILE

After copying source files, run intake validation.
'@

$intakeNote = $intakeNote.Replace("ENTRY_FILE", $EntryFile)

$intakeNotePath = Join-Path $sourceRoot "meta\INTAKE.txt"
Assert-HSIPSWritePath -Path $intakeNotePath
Set-Content -Path $intakeNotePath -Value $intakeNote -Encoding UTF8

Write-Host ""
Write-Host "Product created successfully." -ForegroundColor Green
Write-Host "ProductCode : $ProductCode" -ForegroundColor Green
Write-Host "ProductUUID : $productUuid" -ForegroundColor Green
Write-Host "Source path : $sourceRoot\src" -ForegroundColor Green
Write-Host ""
Write-Host "Next step:" -ForegroundColor Yellow
Write-Host "Copy your MQL5 source into: $sourceRoot\src" -ForegroundColor Yellow
