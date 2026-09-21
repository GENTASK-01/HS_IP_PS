# ==========================================================
# HS_IP_PS Single-Customer Release Orchestrator
# Runs: protected build -> license generation -> customer packaging
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [string]$CustomerName = "GENERIC",

    [Parameter(Mandatory = $false)]
    [long]$AccountLogin = 0,

    [Parameter(Mandatory = $false)]
    [string]$Server = "",

    [Parameter(Mandatory = $false)]
    [string]$Broker = "",

    [Parameter(Mandatory = $false)]
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
    [ValidateSet("none", "sensitive_only", "all")]
    [string]$StringMode = "none",

    [Parameter(Mandatory = $false)]
    [switch]$SkipBuild,

    [Parameter(Mandatory = $false)]
    [switch]$NoLicense
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Single-Customer Release Orchestrator" -ForegroundColor Cyan

# ------------------------------------------------------------
# Step 1: Build
# ------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Host ""
    Write-Host "RELEASE STEP 1: Protected build" -ForegroundColor Yellow

    & powershell -NoProfile -ExecutionPolicy Bypass -File "$Root\scripts\Invoke-HSIPSBuild.ps1" `
        -ProductCode $ProductCode `
        -StringMode $StringMode

    if ($LASTEXITCODE -ne 0) {
        throw "Protected build failed."
    }
} else {
    Write-Warning "SkipBuild enabled. Using latest existing build."
}

# ------------------------------------------------------------
# Step 2: License
# ------------------------------------------------------------

$licenseFiles = @()

if (-not $NoLicense) {
    if ($AccountLogin -le 0 -or [string]::IsNullOrWhiteSpace($Server)) {
        throw "AccountLogin and Server are required unless -NoLicense is used."
    }

    Write-Host ""
    Write-Host "RELEASE STEP 2: License generation" -ForegroundColor Yellow

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $licenseDir = Join-Path $Root "licenses\$ProductCode"
    $licenseOutput = Join-Path $licenseDir "${AccountLogin}_${stamp}.lic"

    Assert-HSIPSWritePath -Path $licenseDir

    if (-not (Test-Path $licenseDir)) {
        New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
    }

    $licenseArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "$Root\scripts\New-HSIPSLicense.ps1",
        "-ProductCode", $ProductCode,
        "-AccountLogin", $AccountLogin,
        "-Server", $Server,
        "-OutputFile", $licenseOutput
    )

    if (-not [string]::IsNullOrWhiteSpace($Broker)) {
        $licenseArgs += @("-Broker", $Broker)
    }

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $licenseArgs += @("-Profile", $Profile)
    } else {
        $licenseArgs += @("-Profile", "LIVE_SINGLE_ACCOUNT")
    }

    if ($ExpiryDays -gt 0) {
        $licenseArgs += @("-ExpiryDays", $ExpiryDays)
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpiryDate)) {
        $licenseArgs += @("-ExpiryDate", $ExpiryDate)
    }

    if ($NoExpiry) {
        $licenseArgs += @("-NoExpiry")
    }

    if ($AllowTester) {
        $licenseArgs += @("-AllowTester")
    }

    if ($AllowOptimization) {
        $licenseArgs += @("-AllowOptimization")
    }

    if ($BrokerBound) {
        $licenseArgs += @("-BrokerBound")
    }

    if ($MaxAccounts -gt 0) {
        $licenseArgs += @("-MaxAccounts", $MaxAccounts)
    }

    & powershell @licenseArgs

    if ($LASTEXITCODE -ne 0) {
        throw "License generation failed."
    }

    $licenseFiles += $licenseOutput

    Write-Host "License generated: $licenseOutput" -ForegroundColor Green
} else {
    Write-Warning "NoLicense enabled. Package will not include a license."
}

# ------------------------------------------------------------
# Step 3: Package
# ------------------------------------------------------------

Write-Host ""
Write-Host "RELEASE STEP 3: Customer packaging" -ForegroundColor Yellow

$packageArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "$Root\scripts\Invoke-HSIPSPackage.ps1",
    "-ProductCode", $ProductCode,
    "-CustomerName", $CustomerName,
    "-Force"
)

if ($licenseFiles.Count -gt 0) {
    $packageArgs += @("-LicenseFiles", $licenseFiles)
}

& powershell @packageArgs

if ($LASTEXITCODE -ne 0) {
    throw "Customer packaging failed."
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "HS_IP_PS RELEASE COMPLETED" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Customer    : $CustomerName"
