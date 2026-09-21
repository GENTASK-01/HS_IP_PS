# ==========================================================
# HS_IP_PS License Generator Wrapper
# Generates customer license files using product config,
# product secret, and the self-contained Python generator.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $true)]
    [long]$AccountLogin,

    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $false)]
    [string]$Broker = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet(
        "",
        "TRIAL",
        "DEMO",
        "LIVE_SINGLE_ACCOUNT",
        "LIVE_MULTI_ACCOUNT",
        "PERPETUAL",
        "CUSTOM"
    )]
    [string]$Profile = "",

    [Parameter(Mandatory = $false)]
    [int]$ExpiryDays = 0,

    [Parameter(Mandatory = $false)]
    [string]$ExpiryDate = "",

    [Parameter(Mandatory = $false)]
    [switch]$NoExpiry,

    [Parameter(Mandatory = $false)]
    [switch]$AllowTester,

    [Parameter(Mandatory = $false)]
    [switch]$AllowOptimization,

    [Parameter(Mandatory = $false)]
    [switch]$BrokerBound,

    [Parameter(Mandatory = $false)]
    [int]$MaxAccounts = 0,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS License Generator" -ForegroundColor Cyan

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

$secretFile = Join-Path $Root "keys\private\${ProductCode}_product_secret.bin"
$generatorScript = Join-Path $Root "scripts\hsips_license_generate.py"

if (-not (Test-Path $secretFile)) {
    throw "Product secret not found: $secretFile. Run New-HSIPSProductSecret.ps1 first."
}

if (-not (Test-Path $generatorScript)) {
    throw "License generator script not found: $generatorScript"
}

# ------------------------------------------------------------
# Determine profile
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = [string]$productConfig.license_profile
}

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = "LIVE_SINGLE_ACCOUNT"
}

Write-Host "License profile: $Profile"

# ------------------------------------------------------------
# Profile defaults
# ------------------------------------------------------------

$allowDemo = $false
$allowLive = $false
$serverBound = $true
$maxAccountsEffective = 1

switch ($Profile) {
    "TRIAL" {
        $allowDemo = $true
        if ($ExpiryDays -le 0 -and [string]::IsNullOrWhiteSpace($ExpiryDate) -and -not $NoExpiry) {
            $ExpiryDays = 14
        }
    }

    "DEMO" {
        $allowDemo = $true
        if ($ExpiryDays -le 0 -and [string]::IsNullOrWhiteSpace($ExpiryDate) -and -not $NoExpiry) {
            $ExpiryDays = 30
        }
    }

    "LIVE_SINGLE_ACCOUNT" {
        $allowLive = $true
        $maxAccountsEffective = 1

        if ($ExpiryDays -le 0 -and [string]::IsNullOrWhiteSpace($ExpiryDate) -and -not $NoExpiry) {
            $ExpiryDays = 365
        }
    }

    "LIVE_MULTI_ACCOUNT" {
        $allowLive = $true

        if ($MaxAccounts -gt 0) {
            $maxAccountsEffective = $MaxAccounts
        } else {
            $maxAccountsEffective = 5
        }

        if ($ExpiryDays -le 0 -and [string]::IsNullOrWhiteSpace($ExpiryDate) -and -not $NoExpiry) {
            $ExpiryDays = 365
        }
    }

    "PERPETUAL" {
        $allowLive = $true
        $NoExpiry = $true
    }

    "CUSTOM" {
        if ($MaxAccounts -gt 0) {
            $maxAccountsEffective = $MaxAccounts
        }
    }

    default {
        throw "Unknown license profile: $Profile"
    }
}

if ($MaxAccounts -gt 0) {
    $maxAccountsEffective = $MaxAccounts
}

# ------------------------------------------------------------
# Calculate expiry
# ------------------------------------------------------------

function Get-UnixTimeUtc {
    param([datetime]$UtcDate)
    $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [long]($UtcDate.ToUniversalTime() - $epoch).TotalSeconds
}

$nowUtc = [datetime]::UtcNow
$expiryUnix = 0

if ($NoExpiry) {
    $expiryUnix = 0
} elseif (-not [string]::IsNullOrWhiteSpace($ExpiryDate)) {
    $expiryDateTime = [datetime]::Parse($ExpiryDate)
    $expiryUnix = Get-UnixTimeUtc -UtcDate $expiryDateTime
} elseif ($ExpiryDays -gt 0) {
    $expiryDateTime = $nowUtc.AddDays($ExpiryDays)
    $expiryUnix = Get-UnixTimeUtc -UtcDate $expiryDateTime
}

# ------------------------------------------------------------
# Calculate flags
# ------------------------------------------------------------

$flags = 0

if ($allowDemo) {
    $flags = $flags -bor 1
}

if ($allowLive) {
    $flags = $flags -bor 2
}

if ($AllowTester) {
    $flags = $flags -bor 4
}

if ($AllowOptimization) {
    $flags = $flags -bor 8
}

if ($serverBound) {
    $flags = $flags -bor 16
}

if ($BrokerBound) {
    $flags = $flags -bor 32
}

if ($expiryUnix -ne 0) {
    $flags = $flags -bor 64
}

# ------------------------------------------------------------
# Validate inputs
# ------------------------------------------------------------

if (($flags -band 16) -ne 0 -and [string]::IsNullOrWhiteSpace($Server)) {
    throw "Server is required because this license is server-bound."
}

if (($flags -band 32) -ne 0 -and [string]::IsNullOrWhiteSpace($Broker)) {
    throw "Broker is required because this license is broker-bound."
}

# ------------------------------------------------------------
# Output path
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $licenseDir = Join-Path $Root "licenses\$ProductCode"

    Assert-HSIPSWritePath -Path $licenseDir

    if (-not (Test-Path $licenseDir)) {
        New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputFile = Join-Path $licenseDir "${AccountLogin}_${stamp}.lic"
}

Assert-HSIPSWritePath -Path $OutputFile

# ------------------------------------------------------------
# Generate license (self-contained cipher, no OpenSSL)
# ------------------------------------------------------------

# Build args via splatting so empty optional values (e.g. Broker) are omitted
# rather than passed as empty strings, which PowerShell drops for native
# commands and which makes argparse fail with "expected one argument".
$genArgs = @(
    $generatorScript,
    "--product-code", $ProductCode,
    "--product-uuid", $productConfig.product_uuid,
    "--secret-file", $secretFile,
    "--root", $Root,
    "--login", $AccountLogin,
    "--server", $Server
)

if (-not [string]::IsNullOrWhiteSpace($Broker)) {
    $genArgs += @("--broker", $Broker)
}

$genArgs += @(
    "--flags", $flags,
    "--expiry-unix", $expiryUnix,
    "--max-accounts", $maxAccountsEffective,
    "--output", $OutputFile,
    "--log-dir", (Join-Path $Root "logs")
)

& $pythonExe @genArgs

if ($LASTEXITCODE -ne 0) {
    throw "License generation failed."
}

Write-Host ""
Write-Host "License generation completed." -ForegroundColor Green
Write-Host "License file: $OutputFile" -ForegroundColor Green
