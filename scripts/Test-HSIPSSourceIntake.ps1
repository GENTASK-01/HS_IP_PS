# ==========================================================
# HS_IP_PS Source Intake Validator
# Validates original source before protection.
# Writes only inside the project root.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Source Intake Validator" -ForegroundColor Cyan

$productConfigPath = Join-Path $Root "config\products\$ProductCode.json"

if (-not (Test-Path $productConfigPath)) {
    throw "Product configuration not found: $productConfigPath"
}

$productConfig = Get-Content -Path $productConfigPath -Raw | ConvertFrom-Json

$sourceRoot = $productConfig.source.source_root
$entryPath = $productConfig.source.entry_path

Write-Host "ProductCode : $ProductCode"
Write-Host "Source root : $sourceRoot"
Write-Host "Entry file  : $entryPath"

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if (-not (Test-Path $sourceRoot)) {
    throw "Source root not found: $sourceRoot"
}

if (-not (Test-Path $entryPath)) {
    throw "Entry file not found: $entryPath"
}

# ------------------------------------------------------------
# Define intake policy
# ------------------------------------------------------------

$allowedExtensions = @(
    ".mq5",
    ".mqh",
    ".txt",
    ".md",
    ".json",
    ".csv",
    ".set",
    ".bmp",
    ".png",
    ".jpg",
    ".jpeg",
    ".wav"
)

$blockedExtensions = @(
    ".ex5",
    ".ex4",
    ".dll",
    ".exe",
    ".bat",
    ".cmd",
    ".ps1",
    ".py",
    ".pyc",
    ".pem",
    ".key",
    ".pfx",
    ".p12",
    ".jks",
    ".keystore"
)

$textExtensions = @(
    ".mq5",
    ".mqh",
    ".txt",
    ".md",
    ".json",
    ".csv",
    ".set"
)

$maxFileSizeMB = 10
$maxPathLength = 220

$errors = @()
$warnings = @()
$fileRecords = @()

# ------------------------------------------------------------
# Scan files
# ------------------------------------------------------------

$files = Get-ChildItem -Path $sourceRoot -Recurse -File

foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $extension = $file.Extension.ToLower()

    $fileRecord = [ordered]@{
        path = $relativePath
        size_kb = [math]::Round($file.Length / 1KB, 2)
        sha256 = ""
        status = "OK"
        messages = @()
    }

    # Hash file
    try {
        $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256
        $fileRecord.sha256 = $hash.Hash
    } catch {
        $errors += "Unable to hash file: $relativePath"
        $fileRecord.status = "ERROR"
    }

    # Blocked extension
    if ($blockedExtensions -contains $extension) {
        $errors += "Blocked file type detected: $relativePath"
        $fileRecord.status = "ERROR"
        $fileRecord.messages += "Blocked extension: $extension"
    }

    # Allowed extension
    if ($allowedExtensions -notcontains $extension) {
        $warnings += "File type not in allowed list: $relativePath"
        $fileRecord.messages += "Extension not in allowed list: $extension"
    }

    # File size
    if ($file.Length -gt ($maxFileSizeMB * 1MB)) {
        $warnings += "File larger than $($maxFileSizeMB) MB: $relativePath"
        $fileRecord.messages += "File exceeds size limit"
    }

    # Path length
    if ($file.FullName.Length -gt $maxPathLength) {
        $warnings += "Path length too long: $relativePath"
        $fileRecord.messages += "Path length exceeds recommended limit"
    }

    # Text content checks
    if ($textExtensions -contains $extension) {
        try {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop

            if ($content -match "#import\s+.*\.dll") {
                if ($productConfig.compatibility.require_dll -eq $false) {
                    $errors += "DLL import detected but DLL is not allowed: $relativePath"
                    $fileRecord.messages += "DLL import detected"
                    $fileRecord.status = "ERROR"
                } else {
                    $warnings += "DLL import detected: $relativePath"
                    $fileRecord.messages += "DLL import detected"
                }
            }

            if ($content -match "WebRequest\s*\(") {
                if ($productConfig.compatibility.allow_web_request -eq $false) {
                    $errors += "WebRequest detected but WebRequest is not allowed: $relativePath"
                    $fileRecord.messages += "WebRequest detected"
                    $fileRecord.status = "ERROR"
                } else {
                    $warnings += "WebRequest detected: $relativePath"
                    $fileRecord.messages += "WebRequest detected"
                }
            }

            if ($content -match "-----BEGIN\s+.*PRIVATE KEY-----") {
                $errors += "Private key material detected: $relativePath"
                $fileRecord.messages += "Private key material detected"
                $fileRecord.status = "ERROR"
            }

            if ($content -match "(?i)(api[_-]?key|secret[_-]?key|password)\s*=") {
                $warnings += "Possible hardcoded credential detected: $relativePath"
                $fileRecord.messages += "Possible hardcoded credential"
            }

            if ($content -match "(?i)debug\s*=\s*true") {
                $warnings += "Possible debug flag enabled: $relativePath"
                $fileRecord.messages += "Possible debug flag"
            }
        } catch {
            $warnings += "Unable to scan text content: $relativePath"
        }
    }

    $fileRecords += [pscustomobject]$fileRecord
}

# ------------------------------------------------------------
# Entry file content checks
# ------------------------------------------------------------

try {
    $entryContent = Get-Content -Path $entryPath -Raw -ErrorAction Stop

    if ($entryContent -notmatch "OnInit\s*\(") {
        $warnings += "Entry file does not appear to contain OnInit()."
    }

    if ($entryContent -notmatch "OnTick\s*\(" -and $entryContent -notmatch "OnTrade\s*\(" -and $entryContent -notmatch "OnTimer\s*\(") {
        $warnings += "Entry file does not appear to contain OnTick(), OnTrade(), or OnTimer()."
    }

    if ($entryContent -match "#import\s+.*\.dll" -and $productConfig.compatibility.require_dll -eq $false) {
        $errors += "Entry file imports a DLL but DLL is not allowed."
    }
} catch {
    $errors += "Unable to read entry file content."
}

# ------------------------------------------------------------
# Build report
# ------------------------------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$auditDir = Join-Path $Root "audit"
Assert-HSIPSWritePath -Path $auditDir

if (-not (Test-Path $auditDir)) {
    New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
}

$report = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    product_uuid = $productConfig.product_uuid
    scan_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    source_root = $sourceRoot
    entry_path = $entryPath
    total_files = $fileRecords.Count
    error_count = $errors.Count
    warning_count = $warnings.Count
    errors = $errors
    warnings = $warnings
    files = $fileRecords
}

$reportPath = Join-Path $auditDir "intake_${ProductCode}_${timestamp}.json"
Assert-HSIPSWritePath -Path $reportPath

$report | ConvertTo-Json -Depth 12 | Set-Content -Path $reportPath -Encoding UTF8

Write-Host ""
Write-Host "Intake report saved: $reportPath" -ForegroundColor Cyan
Write-Host "Files scanned : $($fileRecords.Count)"
Write-Host "Errors        : $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Warnings      : $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { "Yellow" } else { "Green" })

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "INTAKE FAILED" -ForegroundColor Red

    foreach ($errorItem in $errors) {
        Write-Host "ERROR: $errorItem" -ForegroundColor Red
    }

    throw "Source intake validation failed. Fix the errors before continuing."
}

Write-Host ""
Write-Host "INTAKE PASSED" -ForegroundColor Green

if ($warnings.Count -gt 0) {
    Write-Host "Review warnings before production release." -ForegroundColor Yellow
}
