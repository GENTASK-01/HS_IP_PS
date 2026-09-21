# ==========================================================
# HS_IP_PS Automated Build Pipeline
# Writes only inside the project root.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [ValidateSet("none", "sensitive_only", "all")]
    [string]$StringMode = "none",

    [Parameter(Mandatory = $false)]
    [int]$MaxWarningsOverride = -1,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSourceProtection,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLicenseInjection
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\HSIPS-Guard.ps1"

$Root = $global:HSIPS_ROOT

Assert-HSIPSWritePath -Path $Root

Write-Host "HS_IP_PS Automated Build Pipeline" -ForegroundColor Cyan
Write-Host "ProductCode: $ProductCode" -ForegroundColor Cyan

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

$configPath = Join-Path $Root "config\hsips.json"
$productConfigPath = Join-Path $Root "config\products\$ProductCode.json"
$buildPolicyPath = Join-Path $Root "config\build_policy.json"

if (-not (Test-Path $configPath)) {
    throw "HS_IP_PS configuration not found: $configPath"
}

if (-not (Test-Path $productConfigPath)) {
    throw "Product configuration not found: $productConfigPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
$productConfig = Get-Content -Path $productConfigPath -Raw | ConvertFrom-Json

$buildPolicy = $null
if (Test-Path $buildPolicyPath) {
    $buildPolicy = Get-Content -Path $buildPolicyPath -Raw | ConvertFrom-Json
}

$metaEditorExe = $config.metatrader.metaeditor_exe

if ([string]::IsNullOrWhiteSpace($metaEditorExe) -or -not (Test-Path $metaEditorExe)) {
    throw "MetaEditor not found. Check metatrader.metaeditor_exe in $configPath"
}

$pythonExe = $config.tools.python

if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path $pythonExe)) {
    $pythonExe = "python"
}

$sourceWorkRoot = Join-Path $Root "source_work\$ProductCode"
$sourceWorkSrc = Join-Path $sourceWorkRoot "src"
$entryFile = $productConfig.source.entry_file
$entryWorkPath = Join-Path $sourceWorkSrc $entryFile

# ------------------------------------------------------------
# Warning policy
# ------------------------------------------------------------

$maxWarnings = 0

if ($MaxWarningsOverride -ge 0) {
    $maxWarnings = $MaxWarningsOverride
} elseif ($null -ne $buildPolicy -and $null -ne $buildPolicy.compile.max_warnings) {
    $maxWarnings = [int]$buildPolicy.compile.max_warnings
}

# ------------------------------------------------------------
# Step 1: Source protection
# ------------------------------------------------------------

if (-not $SkipSourceProtection) {
    Write-Host ""
    Write-Host "STEP 1: Source protection" -ForegroundColor Yellow

    $protectScript = Join-Path $Root "scripts\Invoke-HSIPSSourceProtection.ps1"

    if (-not (Test-Path $protectScript)) {
        throw "Source protection script not found: $protectScript"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $protectScript `
        -ProductCode $ProductCode `
        -StringMode $StringMode

    if ($LASTEXITCODE -ne 0) {
        throw "Source protection failed."
    }
} else {
    Write-Warning "SkipSourceProtection enabled. Using existing source_work."
}

# ------------------------------------------------------------
# Step 2: License injection
# ------------------------------------------------------------

if (-not $SkipLicenseInjection) {
    Write-Host ""
    Write-Host "STEP 2: License injection" -ForegroundColor Yellow

    $secretFile = Join-Path $Root "keys\private\${ProductCode}_product_secret.bin"
    $templateFile = Join-Path $Root "templates\HSIPS_LICENSE.mqh.template"
    $injectScript = Join-Path $Root "scripts\hsips_inject_license.py"

    if (-not (Test-Path $secretFile)) {
        throw "Product secret not found: $secretFile. Run New-HSIPSProductSecret.ps1 first."
    }

    if (-not (Test-Path $templateFile)) {
        throw "License template not found: $templateFile"
    }

    if (-not (Test-Path $injectScript)) {
        throw "License injector not found: $injectScript"
    }

    & $pythonExe $injectScript `
        --source-root $sourceWorkSrc `
        --entry $entryFile `
        --product-code $ProductCode `
        --product-version $productConfig.product_version `
        --product-uuid $productConfig.product_uuid `
        --secret-file $secretFile `
        --template $templateFile

    if ($LASTEXITCODE -ne 0) {
        throw "License injection failed."
    }
} else {
    Write-Warning "SkipLicenseInjection enabled. Build may not contain license protection."
}

# ------------------------------------------------------------
# Step 3: Prepare build folder
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 3: Prepare build folder" -ForegroundColor Yellow

if (-not (Test-Path $entryWorkPath)) {
    throw "Entry file not found in protected working source: $entryWorkPath"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$versionSafe = $productConfig.product_version -replace "[^0-9A-Za-z]+", "_"
$randomSuffix = -join ((65..90) + (48..57) | Get-Random -Count 8 | ForEach-Object { [char]$_ })

$buildId = "${timestamp}_${versionSafe}_${randomSuffix}"

$buildRoot = Join-Path $Root "build\$ProductCode\$buildId"
$binaryDir = Join-Path $buildRoot "binary"
$logsDir = Join-Path $buildRoot "logs"
$manifestDir = Join-Path $buildRoot "manifest"

Assert-HSIPSWritePath -Path $buildRoot

New-Item -ItemType Directory -Path $binaryDir -Force | Out-Null
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

Write-Host "Build ID: $buildId"

# ------------------------------------------------------------
# Step 4: Compile with MetaEditor (FIX B7: explicit include root)
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 4: Compile with MetaEditor" -ForegroundColor Yellow

$compileLogPath = Join-Path $logsDir "compile.log"

# No /include: flag — MetaEditor resolves relative #include "..." against the
# source file's own folder and #include <...> against the terminal's MQL5\Include
# (standard library) automatically. An explicit /include: can break the latter.
$arguments = "/compile:`"$entryWorkPath`" /log:`"$compileLogPath`""

Write-Host "MetaEditor: $metaEditorExe"
Write-Host "Arguments : $arguments"

$timeoutSeconds = 300
if ($null -ne $buildPolicy -and $null -ne $buildPolicy.compile.metaeditor_timeout_seconds) {
    $timeoutSeconds = [int]$buildPolicy.compile.metaeditor_timeout_seconds
}

$timeoutMs = $timeoutSeconds * 1000

$processInfo = New-Object System.Diagnostics.ProcessStartInfo
$processInfo.FileName = $metaEditorExe
$processInfo.Arguments = $arguments
$processInfo.UseShellExecute = $false
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::Start($processInfo)

if (-not $process.WaitForExit($timeoutMs)) {
    try {
        $process.Kill()
    } catch {}

    throw "MetaEditor compilation timed out after $timeoutSeconds seconds."
}

$compileExitCode = $process.ExitCode

Start-Sleep -Seconds 2

Write-Host "MetaEditor exit code: $compileExitCode"

# ------------------------------------------------------------
# Step 5: Parse compile log (FIX B22: robust regex + fallback)
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 5: Parse compile log" -ForegroundColor Yellow

function Get-LogText {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -eq 0) {
        return ""
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
    }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    return [System.Text.Encoding]::Default.GetString($bytes)
}

$logCandidates = @(
    $compileLogPath,
    ([System.IO.Path]::ChangeExtension($entryWorkPath, ".log")),
    "$entryWorkPath.log",
    (Join-Path $sourceWorkRoot "compile.log"),
    (Join-Path $sourceWorkSrc "compile.log")
)

$logText = ""
$foundLogPath = ""

foreach ($candidate in $logCandidates) {
    $candidateText = Get-LogText -Path $candidate

    if (-not [string]::IsNullOrWhiteSpace($candidateText)) {
        $logText = $candidateText
        $foundLogPath = $candidate
        break
    }
}

$errorCount = 0
$warningCount = 0
$summaryFound = $false

# Accepts "N errors, M warnings" AND "N error(s), M warning(s)".
$summaryMatches = [regex]::Matches($logText, "(?i)(\d+)\s+error(?:s|\(s\))?\s*,\s*(\d+)\s+warning(?:s|\(s\))?")

if ($summaryMatches.Count -gt 0) {
    $lastSummary = $summaryMatches[$summaryMatches.Count - 1]
    $errorCount = [int]$lastSummary.Groups[1].Value
    $warningCount = [int]$lastSummary.Groups[2].Value
    $summaryFound = $true
} else {
    # Only treat a NON-zero error count as an error (never a clean "0 error(s)").
    if ($logText -match "(?i)[1-9]\d*\s+error") {
        $errorCount = 1
    }

    $warningMatches = [regex]::Matches($logText, "(?i)warning")
    $warningCount = $warningMatches.Count
}

Write-Host "Log file  : $foundLogPath"
Write-Host "Errors    : $errorCount"
Write-Host "Warnings  : $warningCount"
Write-Host "Summary   : $summaryFound"

# ------------------------------------------------------------
# Step 6: Validate compilation
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 6: Validate compilation" -ForegroundColor Yellow

$ex5SourcePath = [System.IO.Path]::ChangeExtension($entryWorkPath, ".ex5")

function Show-LastLogLines {
    param(
        [string]$Text,
        [int]$Count = 40
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Host "No compile log text available." -ForegroundColor Yellow
        return
    }

    $lines = $Text -split "`r?`n"
    $lines | Select-Object -Last $Count | ForEach-Object {
        Write-Host $_
    }
}

if ($errorCount -gt 0) {
    Write-Host "Compilation failed with errors." -ForegroundColor Red
    Show-LastLogLines -Text $logText
    throw "Compilation failed with $errorCount error(s)."
}

if ($warningCount -gt $maxWarnings) {
    Write-Host "Compilation exceeded warning limit." -ForegroundColor Red
    Show-LastLogLines -Text $logText
    throw "Compilation produced $warningCount warning(s). Allowed maximum is $maxWarnings."
}

if (-not (Test-Path $ex5SourcePath)) {
    Write-Host "Compiled .ex5 file not found." -ForegroundColor Red
    Show-LastLogLines -Text $logText
    throw "Compiled file not found: $ex5SourcePath"
}

if ($compileExitCode -ne 0) {
    Write-Warning "MetaEditor exit code was $compileExitCode, but no compile errors were detected."
}

$ex5Size = (Get-Item $ex5SourcePath).Length

if ($ex5Size -lt 1024) {
    throw "Compiled .ex5 file is too small. Build rejected."
}

Write-Host "Compilation validation passed." -ForegroundColor Green

# ------------------------------------------------------------
# Step 7: Store build artifacts
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 7: Store build artifacts" -ForegroundColor Yellow

$binaryDestination = Join-Path $binaryDir ([System.IO.Path]::GetFileName($ex5SourcePath))

Assert-HSIPSWritePath -Path $binaryDestination

Copy-Item -Path $ex5SourcePath -Destination $binaryDestination -Force

$ex5Hash = (Get-FileHash -Path $binaryDestination -Algorithm SHA256).Hash

Write-Host "Stored binary: $binaryDestination"
Write-Host "SHA-256      : $ex5Hash"

# ------------------------------------------------------------
# Step 8: Source hashes (FIX B1: correct hash value)
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 8: Generate protected source hashes" -ForegroundColor Yellow

$sourceHashList = @()

$sourceFiles = Get-ChildItem -Path $sourceWorkSrc -Recurse -File

foreach ($file in $sourceFiles) {
    $relativePath = $file.FullName.Substring($sourceWorkSrc.Length).TrimStart("\")
    $fileHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash

    $sourceHashList += [pscustomobject]@{
        path = $relativePath
        sha256 = $fileHash
        size = $file.Length
    }
}

$sourceHashPath = Join-Path $manifestDir "source_hashes.json"

@($sourceHashList) | ConvertTo-Json -Depth 12 | Set-Content -Path $sourceHashPath -Encoding UTF8

Write-Host "Source hashes saved: $sourceHashPath"

# ------------------------------------------------------------
# Step 9: Build report
# ------------------------------------------------------------

Write-Host ""
Write-Host "STEP 9: Generate build report" -ForegroundColor Yellow

$buildUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$buildReport = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    product_uuid = $productConfig.product_uuid
    product_name = $productConfig.product_name
    product_version = $productConfig.product_version
    build_id = $buildId
    build_utc = $buildUtc

    pipeline = [ordered]@{
        source_protection_skipped = [bool]$SkipSourceProtection
        license_injection_skipped = [bool]$SkipLicenseInjection
        string_mode = $StringMode
        max_warnings = $maxWarnings
    }

    compiler = [ordered]@{
        metaeditor_path = $metaEditorExe
        entry_file = $entryFile
        entry_work_path = $entryWorkPath
        arguments = $arguments
        exit_code = $compileExitCode
        timeout_seconds = $timeoutSeconds
    }

    compile_result = [ordered]@{
        summary_found = $summaryFound
        errors = $errorCount
        warnings = $warningCount
        log_path = $foundLogPath
        log_sha256 = $(
            if (Test-Path $foundLogPath) {
                (Get-FileHash -Path $foundLogPath -Algorithm SHA256).Hash
            } else {
                ""
            }
        )
    }

    output = [ordered]@{
        ex5_path = $binaryDestination
        ex5_sha256 = $ex5Hash
        ex5_size = $ex5Size
    }

    paths = [ordered]@{
        build_root = $buildRoot
        binary_dir = $binaryDir
        logs_dir = $logsDir
        manifest_dir = $manifestDir
    }

    success = $true
}

$buildReportPath = Join-Path $manifestDir "build_report.json"

$buildReport | ConvertTo-Json -Depth 12 | Set-Content -Path $buildReportPath -Encoding UTF8

Write-Host "Build report saved: $buildReportPath"

# ------------------------------------------------------------
# Step 10: Checksum manifest
# ------------------------------------------------------------

$checksumManifest = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    build_id = $buildId
    generated_utc = $buildUtc

    files = @(
        [pscustomobject]@{
            path = "binary\$([System.IO.Path]::GetFileName($binaryDestination))"
            sha256 = $ex5Hash
        },
        [pscustomobject]@{
            path = "manifest\build_report.json"
            sha256 = (Get-FileHash -Path $buildReportPath -Algorithm SHA256).Hash
        },
        [pscustomobject]@{
            path = "manifest\source_hashes.json"
            sha256 = (Get-FileHash -Path $sourceHashPath -Algorithm SHA256).Hash
        }
    )
}

$checksumPath = Join-Path $manifestDir "checksums.json"

$checksumManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $checksumPath -Encoding UTF8

Write-Host "Checksum manifest saved: $checksumPath"

# ------------------------------------------------------------
# Step 11: Latest build pointer
# ------------------------------------------------------------

$latestPath = Join-Path $Root "build\$ProductCode\latest.json"

$latest = [ordered]@{
    schema_version = 1
    product_code = $ProductCode
    build_id = $buildId
    product_version = $productConfig.product_version
    build_utc = $buildUtc
    build_root = $buildRoot
    ex5_path = $binaryDestination
    ex5_sha256 = $ex5Hash
}

Assert-HSIPSWritePath -Path $latestPath

$latest | ConvertTo-Json -Depth 12 | Set-Content -Path $latestPath -Encoding UTF8

Write-Host "Latest build pointer saved: $latestPath"

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "HS_IP_PS BUILD COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "ProductCode : $ProductCode"
Write-Host "Build ID    : $buildId"
Write-Host "Binary      : $binaryDestination"
Write-Host "SHA-256     : $ex5Hash"
Write-Host "Build root  : $buildRoot"
