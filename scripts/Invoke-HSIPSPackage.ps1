# ==========================================================
# HS_IP_PS Customer Packaging Engine
# Writes only inside the project root.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [string]$BuildId = "",

    [Parameter(Mandatory = $false)]
    [string]$CustomerName = "GENERIC",

    [Parameter(Mandatory = $false)]
    [string[]]$LicenseFiles = @(),

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$CreateEncrypted,

    [Parameter(Mandatory = $false)]
    [string]$ArchivePassword = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Customer Packaging Engine" -ForegroundColor Cyan

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

$rarExe = $config.tools.rar

$rarAvailable = $false
if (-not [string]::IsNullOrWhiteSpace($rarExe) -and (Test-Path $rarExe)) {
    $rarAvailable = $true
}

# ------------------------------------------------------------
# Resolve build
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($BuildId)) {
    $latestBuildPath = Join-Path $Root "build\$ProductCode\latest.json"

    if (-not (Test-Path $latestBuildPath)) {
        throw "Latest build not found. Run Invoke-HSIPSBuild.ps1 first."
    }

    $latestBuild = Get-Content -Path $latestBuildPath -Raw | ConvertFrom-Json
    $BuildId = $latestBuild.build_id
    $buildRoot = $latestBuild.build_root
} else {
    $buildRoot = Join-Path $Root "build\$ProductCode\$BuildId"
}

if (-not (Test-Path $buildRoot)) {
    throw "Build root not found: $buildRoot"
}

Write-Host "ProductCode : $ProductCode"
Write-Host "Build ID    : $BuildId"
Write-Host "Build root  : $buildRoot"

# ------------------------------------------------------------
# Locate compiled EX5
# ------------------------------------------------------------

$binaryDir = Join-Path $buildRoot "binary"

if (-not (Test-Path $binaryDir)) {
    throw "Binary directory not found: $binaryDir"
}

$ex5Files = Get-ChildItem -Path $binaryDir -Filter *.ex5

if ($ex5Files.Count -ne 1) {
    throw "Expected exactly one .ex5 file in $binaryDir"
}

$ex5Source = $ex5Files[0].FullName
$ex5Hash = (Get-FileHash -Path $ex5Source -Algorithm SHA256).Hash

Write-Host "Build binary: $ex5Source"
Write-Host "EX5 SHA-256 : $ex5Hash"

# ------------------------------------------------------------
# Sanitize customer ID
# ------------------------------------------------------------

$customerId = ($CustomerName -replace "[^A-Za-z0-9_\-]", "_").Trim().ToUpper()

if ([string]::IsNullOrWhiteSpace($customerId)) {
    $customerId = "GENERIC"
}

if ($customerId.Length -gt 32) {
    $customerId = $customerId.Substring(0, 32)
}

Write-Host "Customer ID : $customerId"

# ------------------------------------------------------------
# Validate license files EARLY (before any copying) so an invalid
# path (e.g. an un-substituted <stamp> placeholder, which contains
# illegal characters '<' and '>') fails with a clear, actionable
# message instead of a cryptic "Illegal characters in path".
# ------------------------------------------------------------

foreach ($licenseFile in $LicenseFiles) {
    if ([string]::IsNullOrWhiteSpace($licenseFile)) {
        continue
    }

    try {
        $licenseItem = Get-Item -LiteralPath $licenseFile -ErrorAction Stop
    } catch {
        throw "Invalid license file path: '$licenseFile'. It must be the actual generated .lic file (list them with: Get-ChildItem '$Root\licenses\$ProductCode'). Detail: $($_.Exception.Message)"
    }

    if ($licenseItem.PSIsContainer) {
        throw "License path points to a folder, not a .lic file: $licenseFile"
    }

    if ($licenseItem.Extension.ToLower() -ne ".lic") {
        throw "License file must have a .lic extension: $licenseFile"
    }
}

# ------------------------------------------------------------
# Prepare package folder
# ------------------------------------------------------------

$packageRoot = Join-Path $Root "customer_packages\$ProductCode\$BuildId\$customerId"

Assert-HSIPSWritePath -Path $packageRoot

if (Test-Path $packageRoot) {
    if (-not $Force) {
        throw "Package folder already exists: $packageRoot. Use -Force to overwrite."
    }

    Remove-Item -Path $packageRoot -Recurse -Force
}

$expertDir = Join-Path $packageRoot "ExpertAdvisors"
$licenseDir = Join-Path $packageRoot "HS_IP_PS"
$docsDir = Join-Path $packageRoot "Documentation"
$manifestDir = Join-Path $packageRoot "manifest"

New-Item -ItemType Directory -Path $expertDir -Force | Out-Null
New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

# ------------------------------------------------------------
# Copy protected EX5
# ------------------------------------------------------------

$ex5DestinationName = "$ProductCode.ex5"
$ex5Destination = Join-Path $expertDir $ex5DestinationName

Assert-HSIPSWritePath -Path $ex5Destination

Copy-Item -Path $ex5Source -Destination $ex5Destination -Force

Write-Host "Copied EX5 to: $ex5Destination"

# ------------------------------------------------------------
# Copy license files if provided
# ------------------------------------------------------------

$licenseIndex = 1

foreach ($licenseFile in $LicenseFiles) {
    if ([string]::IsNullOrWhiteSpace($licenseFile)) {
        continue
    }

    if ($LicenseFiles.Count -eq 1) {
        $licenseDestinationName = "license.lic"
    } else {
        $licenseDestinationName = "license_{0:D2}.lic" -f $licenseIndex
    }

    $licenseDestination = Join-Path $licenseDir $licenseDestinationName

    Assert-HSIPSWritePath -Path $licenseDestination

    Copy-Item -Path $licenseFile -Destination $licenseDestination -Force

    Write-Host "Copied license: $licenseDestination"

    $licenseIndex++
}

# ------------------------------------------------------------
# Generate documentation
# ------------------------------------------------------------

$productName = $productConfig.product_name
$productVersion = $productConfig.product_version

$installWindows = @"
$productName
Product Code : $ProductCode
Version      : $productVersion
Build ID     : $BuildId

WINDOWS INSTALLATION GUIDE

1. Open MetaTrader 5.
2. Click File.
3. Click Open Data Folder.
4. Open the MQL5 folder.
5. Open the Experts folder.
6. Copy $ex5DestinationName into the Experts folder.
7. Go back to the MQL5 folder.
8. Open the Files folder.
9. Create or open the HS_IP_PS folder.
10. Copy your license file into the HS_IP_PS folder.
11. Restart MetaTrader 5.
12. Attach the Expert Advisor to a chart.

If no license file was supplied, request a license from the developer.

Expected valid license status:
HS_IP_PS: LICENSE OK
"@

$installMac = @"
$productName
Product Code : $ProductCode
Version      : $productVersion
Build ID     : $BuildId

MACOS INSTALLATION GUIDE

1. Open MetaTrader 5.
2. Click File.
3. Click Open Data Folder.
4. Open the MQL5 folder.
5. Open the Experts folder.
6. Copy $ex5DestinationName into the Experts folder.
7. Go back to the MQL5 folder.
8. Open the Files folder.
9. Create or open the HS_IP_PS folder.
10. Copy your license file into the HS_IP_PS folder.
11. Restart MetaTrader 5.
12. Attach the Expert Advisor to a chart.

If the operating system asks for permission, allow MetaTrader 5 to access the required folder.

Expected valid license status:
HS_IP_PS: LICENSE OK
"@

$licenseTerms = @"
$productName
Product Code : $ProductCode
Version      : $productVersion
Build ID     : $BuildId

LICENSE TERMS SUMMARY

This Expert Advisor is protected by HS_IP_PS.

The license file is bound to the authorized MetaTrader account and server.

You may not:
- redistribute the Expert Advisor
- redistribute the license file
- reverse engineer the protected binary
- modify the protected binary
- share login credentials to bypass licensing
- remove or disable protection mechanisms

The software is provided as-is, without warranty of any kind.

For license support, contact the developer.
"@

$readmeText = @"
$productName
Product Code : $ProductCode
Version      : $productVersion
Build ID     : $BuildId

PACKAGE CONTENTS

ExpertAdvisors\$ex5DestinationName
HS_IP_PS\license file, if provided
Documentation\INSTALL_WINDOWS.txt
Documentation\INSTALL_MACOS.txt
Documentation\LICENSE_TERMS.txt
Documentation\CHECKSUMS.txt
manifest\package_manifest.json

Do not modify the protected EX5 file.
Do not redistribute this package.
"@

Set-Content -Path (Join-Path $docsDir "INSTALL_WINDOWS.txt") -Value $installWindows -Encoding UTF8
Set-Content -Path (Join-Path $docsDir "INSTALL_MACOS.txt") -Value $installMac -Encoding UTF8
Set-Content -Path (Join-Path $docsDir "LICENSE_TERMS.txt") -Value $licenseTerms -Encoding UTF8
Set-Content -Path (Join-Path $packageRoot "README.txt") -Value $readmeText -Encoding UTF8

Write-Host "Documentation generated."

# ------------------------------------------------------------
# Generate checksums
# ------------------------------------------------------------

$checksumLines = @()

$checksumFiles = Get-ChildItem -Path $packageRoot -Recurse -File |
    Where-Object {
        $_.Name -ne "CHECKSUMS.txt" -and
        $_.FullName -notmatch "\\manifest\\package_manifest\.json$"
    } |
    Sort-Object FullName

foreach ($file in $checksumFiles) {
    $relativePath = $file.FullName.Substring($packageRoot.Length).TrimStart("\")
    $fileHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
    $checksumLines += "$fileHash  $relativePath"
}

$checksumPath = Join-Path $docsDir "CHECKSUMS.txt"

Assert-HSIPSWritePath -Path $checksumPath

Set-Content -Path $checksumPath -Value ($checksumLines -join "`r`n") -Encoding UTF8

Write-Host "Checksums generated: $checksumPath"

# ------------------------------------------------------------
# Generate package manifest (FIX B1: correct hash value)
# ------------------------------------------------------------

$packageUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$packageId = "${ProductCode}_${BuildId}_${customerId}"

$manifestFiles = @()

$allPackageFiles = Get-ChildItem -Path $packageRoot -Recurse -File |
    Where-Object {
        $_.FullName -notmatch "\\manifest\\package_manifest\.json$"
    } |
    Sort-Object FullName

foreach ($file in $allPackageFiles) {
    $relativePath = $file.FullName.Substring($packageRoot.Length).TrimStart("\")
    $fileHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash

    $manifestFiles += [pscustomobject]@{
        path = $relativePath
        sha256 = $fileHash
        size = $file.Length
    }
}

$packageManifest = [ordered]@{
    schema_version = 1
    package_id = $packageId
    product_code = $ProductCode
    product_name = $productName
    product_version = $productVersion
    build_id = $BuildId
    customer_id = $customerId
    created_utc = $packageUtc

    source_build = [ordered]@{
        build_root = $buildRoot
        ex5_source = $ex5Source
        ex5_sha256 = $ex5Hash
    }

    license = [ordered]@{
        included = ($LicenseFiles.Count -gt 0)
        count = $LicenseFiles.Count
    }

    files = $manifestFiles

    warnings = @(
        "Do not redistribute this package.",
        "Do not include source code, scripts, keys, logs, or audit files."
    )
}

$packageManifestPath = Join-Path $manifestDir "package_manifest.json"

Assert-HSIPSWritePath -Path $packageManifestPath

$packageManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $packageManifestPath -Encoding UTF8

Write-Host "Package manifest generated: $packageManifestPath"

# ------------------------------------------------------------
# Safety scan
# ------------------------------------------------------------

$forbiddenExtensions = @(
    ".mq5",
    ".mqh",
    ".ps1",
    ".py",
    ".bat",
    ".cmd",
    ".log",
    ".pem",
    ".key",
    ".bin",
    ".pfx",
    ".p12"
)

$packageFiles = Get-ChildItem -Path $packageRoot -Recurse -File

foreach ($file in $packageFiles) {
    if ($forbiddenExtensions -contains $file.Extension.ToLower()) {
        throw "Packaging safety scan failed. Forbidden file type found: $($file.FullName)"
    }

    if ($file.FullName -match "\\source|\\scripts|\\keys|\\logs|\\audit|\\source_work|\\source_original") {
        throw "Packaging safety scan failed. Forbidden path pattern found: $($file.FullName)"
    }
}

Write-Host "Packaging safety scan passed." -ForegroundColor Green

# ------------------------------------------------------------
# Create ZIP archive
# ZIP is always built with the built-in Compress-Archive: it is
# dependency-free, cross-version-safe, and cannot fail due to a
# missing/incompatible external archiver. WinRAR (Rar.exe) is
# reserved exclusively for the OPTIONAL encrypted RAR archive below.
# ------------------------------------------------------------

$packageBase = Join-Path $Root "customer_packages"
$zipName = "${ProductCode}_${BuildId}_${customerId}.zip"
$zipPath = Join-Path $packageBase $zipName

Assert-HSIPSWritePath -Path $zipPath

if (Test-Path $zipPath) {
    if (-not $Force) {
        throw "ZIP already exists: $zipPath. Use -Force to overwrite."
    }

    Remove-Item -Path $zipPath -Force
}

Write-Host "Creating ZIP with PowerShell Compress-Archive..."
Compress-Archive -Path "$packageRoot\*" -DestinationPath $zipPath -CompressionLevel Optimal

$zipHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash

Set-Content -Path "$zipPath.sha256" -Value "$zipHash  $zipName" -Encoding UTF8

Write-Host "ZIP created: $zipPath"
Write-Host "ZIP SHA-256: $zipHash"

# ------------------------------------------------------------
# Optional encrypted RAR archive (WinRAR cannot write 7z; RAR -hp
# encrypts headers + data, equivalent to 7z header encryption)
# ------------------------------------------------------------

if ($CreateEncrypted) {
    if (-not $rarAvailable -or (Split-Path $rarExe -Leaf) -ne "Rar.exe") {
        throw "Encrypted archive requires the WinRAR console tool Rar.exe (not WinRAR.exe)."
    }

    $plainPassword = $ArchivePassword

    if ([string]::IsNullOrWhiteSpace($plainPassword)) {
        $securePassword = Read-Host -Prompt "Enter archive password" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $rarPath = [System.IO.Path]::ChangeExtension($zipPath, ".rar")

    if (Test-Path $rarPath) {
        if (-not $Force) {
            throw "Encrypted RAR already exists: $rarPath. Use -Force to overwrite."
        }

        Remove-Item -Path $rarPath -Force
    }

    Push-Location $packageRoot
    # -hp = encrypt file names AND data (header encryption).
    $rarOutput = & $rarExe a -ep1 -m5 -hp"$plainPassword" -y $rarPath * 2>&1
    Pop-Location

    if ($LASTEXITCODE -ne 0) {
        $plainPassword = $null
        throw "Encrypted RAR packaging failed. Rar.exe exit code: $LASTEXITCODE. Output: $rarOutput"
    }

    $rarHash = (Get-FileHash -Path $rarPath -Algorithm SHA256).Hash

    Set-Content -Path "$rarPath.sha256" -Value "$rarHash  $([System.IO.Path]::GetFileName($rarPath))" -Encoding UTF8

    Write-Host "Encrypted RAR created: $rarPath"
    Write-Host "RAR SHA-256: $rarHash"

    $plainPassword = $null
}

# ------------------------------------------------------------
# Latest package pointer
# ------------------------------------------------------------

$productPackageDir = Join-Path $Root "customer_packages\$ProductCode"

Assert-HSIPSWritePath -Path $productPackageDir

$latestPackage = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    package_id = $packageId
    build_id = $BuildId
    customer_id = $customerId
    package_root = $packageRoot
    zip_path = $zipPath
    zip_sha256 = $zipHash
    created_utc = $packageUtc
}

$latestPackagePath = Join-Path $productPackageDir "latest_package.json"

Assert-HSIPSWritePath -Path $latestPackagePath

$latestPackage | ConvertTo-Json -Depth 12 | Set-Content -Path $latestPackagePath -Encoding UTF8

Write-Host "Latest package pointer saved: $latestPackagePath"

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "HS_IP_PS PACKAGE CREATED SUCCESSFULLY" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Build ID    : $BuildId"
Write-Host "Customer ID : $customerId"
Write-Host "Package root: $packageRoot"
Write-Host "ZIP file    : $zipPath"
Write-Host "ZIP SHA-256 : $zipHash"
