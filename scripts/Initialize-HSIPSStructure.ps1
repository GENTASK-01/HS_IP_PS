# ==========================================================
# HS_IP_PS Bootstrap Initializer
# Creates the secure workspace skeleton under the project root
# and writes machine-specific configuration. Idempotent — safe
# to re-run. Scripts, templates, and launchers ship in the
# bundle and are not regenerated here (no drift risk).
# Writes only inside the project root.
# ==========================================================

$ErrorActionPreference = "Stop"

# Resolve the project root: HSIPS_HOME env var, then this script's own
# location (scripts/ is directly under the root), then a safe default.
$Root = [Environment]::GetEnvironmentVariable("HSIPS_HOME", "Machine")

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path $PSScriptRoot -Parent
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = "E:\HS_IP_PS"
}

Write-Host "HS_IP_PS Bootstrap Initializer" -ForegroundColor Cyan
Write-Host "Project root: $Root" -ForegroundColor Cyan

# ------------------------------------------------------------
# 1. Verify drive
# ------------------------------------------------------------

$driveLetter = ($Root -split ':')[0] + ':'

if (-not (Test-Path "$driveLetter\")) {
    throw "Project drive not found: $driveLetter"
}

$volume = Get-Volume -DriveLetter ($driveLetter -replace ':', '') -ErrorAction SilentlyContinue
if ($null -eq $volume) {
    throw "Unable to read $driveLetter volume information."
}

Write-Host "Drive $driveLetter found." -ForegroundColor Green
Write-Host ("File system: {0}" -f $volume.FileSystemType)
Write-Host ("Free space: {0:N2} GB" -f ($volume.SizeRemaining / 1GB))

# ------------------------------------------------------------
# 2. Create folder structure
# ------------------------------------------------------------

$folders = @(
    "",
    "bin",
    "config",
    "keys",
    "keys\public",
    "keys\private",
    "keys\shards",
    "templates",
    "scripts",
    "source_original",
    "source_work",
    "include_work",
    "build",
    "dist",
    "licenses",
    "logs",
    "audit",
    "backup",
    "customer_packages"
)

foreach ($folder in $folders) {
    $path = Join-Path $Root $folder
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "Created: $path"
    } else {
        Write-Host "Exists:  $path" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------
# 3. Detect installed tools
# ------------------------------------------------------------

function Get-FirstExistingPath {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if (Test-Path $path) { return $path }
    }
    return ""
}

$metaEditorCandidates = @(
    "C:\Program Files\Vantage International MT5\metaeditor64.exe",
    "C:\MetaTrader5\metaeditor64.exe",
    "C:\Program Files\MetaTrader 5\metaeditor64.exe"
)

$terminalCandidates = @(
    "C:\Program Files\Vantage International MT5\terminal64.exe",
    "C:\MetaTrader5\terminal64.exe",
    "C:\Program Files\MetaTrader 5\terminal64.exe"
)

$pythonCandidates = @(
    "C:\Python314\python.exe",
    "C:\Python312\python.exe",
    "C:\Program Files\Python314\python.exe",
    "C:\Program Files\Python312\python.exe"
)

$gitCandidates = @(
    "C:\Program Files\Git\cmd\git.exe",
    "C:\Program Files\Git\bin\git.exe"
)

$rarCandidates = @(
    "C:\Program Files\WinRAR\Rar.exe",
    "C:\Program Files\WinRAR\WinRAR.exe"
)

$metaEditorExe = Get-FirstExistingPath -Paths $metaEditorCandidates
$terminalExe   = Get-FirstExistingPath -Paths $terminalCandidates
$pythonExe     = Get-FirstExistingPath -Paths $pythonCandidates
$gitExe        = Get-FirstExistingPath -Paths $gitCandidates
$rarExe        = Get-FirstExistingPath -Paths $rarCandidates

$mt5Path = ""
if ($metaEditorExe -ne "") {
    $mt5Path = Split-Path $metaEditorExe
}

if ($metaEditorExe -eq "") {
    Write-Warning "metaeditor64.exe was not found in the known HS_IP_PS paths."
    Write-Warning "Update $Root\config\hsips.json later with the correct path."
}

if ($rarExe -eq "") {
    Write-Warning "WinRAR console (Rar.exe) not found. ZIP packaging uses Compress-Archive;"
    Write-Warning "encrypted RAR archives will be unavailable until Rar.exe is installed."
}

# ------------------------------------------------------------
# 4. Create main configuration file
# ------------------------------------------------------------

$config = [ordered]@{
    system = "HS_IP_PS"
    version = "1.2.0"
    schema_version = 1
    created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    developer_os = "Windows 10 Pro"

    target_os = @(
        "Windows 10 and later",
        "macOS 26 Tahoe and later"
    )

    metatrader = [ordered]@{
        required_build_min = 6090
        metaeditor_exe = $metaEditorExe
        terminal_exe = $terminalExe
        mt5_root = $mt5Path
    }

    tools = [ordered]@{
        python = $pythonExe
        git = $gitExe
        rar = $rarExe
    }

    drives = [ordered]@{
        software_drive = "C:"
        project_drive = $driveLetter
    }

    paths = [ordered]@{
        root = $Root
        bin = "$Root\bin"
        config = "$Root\config"
        keys = "$Root\keys"
        keys_public = "$Root\keys\public"
        keys_private = "$Root\keys\private"
        keys_shards = "$Root\keys\shards"
        templates = "$Root\templates"
        scripts = "$Root\scripts"
        source_original = "$Root\source_original"
        source_work = "$Root\source_work"
        include_work = "$Root\include_work"
        build = "$Root\build"
        dist = "$Root\dist"
        licenses = "$Root\licenses"
        logs = "$Root\logs"
        audit = "$Root\audit"
        backup = "$Root\backup"
        customer_packages = "$Root\customer_packages"
    }

    policy = [ordered]@{
        allow_write_outside_project = $false
        allowed_write_root = $Root
        block_c_drive_write_by_pipeline = $true
        allow_paid_services = $false
        allow_paid_servers = $false
        require_free_tooling_only = $true
        network_required = $false
        distribute_source = $false
        distribute_private_keys = $false
        distribute_scripts_to_customer = $false
        distribute_logs_to_customer = $false
        distribute_audit_to_customer = $false
    }
}

$configJson = $config | ConvertTo-Json -Depth 12
$configPath = Join-Path $Root "config\hsips.json"
Set-Content -Path $configPath -Value $configJson -Encoding UTF8
Write-Host "Created: $configPath"

# ------------------------------------------------------------
# 5. Create security policy file
# ------------------------------------------------------------

$securityPolicy = [ordered]@{
    schema_version = 1
    updated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    write_guard = [ordered]@{
        enabled = $true
        allowed_write_roots = @($Root)
        block_c_drive_write = $true
        block_windows_folder_write = $true
        block_program_files_write = $true
        block_user_profile_write = $false
        notes = "HS_IP_PS pipeline output must remain inside $Root"
    }

    source_control = [ordered]@{
        local_git_only_by_default = $true
        remote_allowed = $false
        exclude_private_keys = $true
        exclude_logs = $true
        exclude_audit = $true
        exclude_work_folders = $true
    }

    keys = [ordered]@{
        private_key_folder = "$Root\keys\private"
        public_key_folder = "$Root\keys\public"
        shard_folder = "$Root\keys\shards"
        backup_required = $true
        backup_encryption_required = $true
        private_keys_never_distributed = $true
    }

    distribution = [ordered]@{
        include_source = $false
        include_mqh_files = $false
        include_private_keys = $false
        include_public_keys = $false
        include_build_scripts = $false
        include_obfuscation_maps = $false
        include_logs = $false
        include_audit = $false
        include_checksum_manifest = $true
        include_customer_docs = $true
    }

    runtime = [ordered]@{
        fail_closed_on_invalid_license = $true
        allow_new_orders_without_license = $false
        reveal_detailed_errors_to_customer = $false
        safe_mode_message = "HS_IP_PS: LICENSE INVALID"
    }
}

$securityJson = $securityPolicy | ConvertTo-Json -Depth 12
$securityPath = Join-Path $Root "config\security_policy.json"
Set-Content -Path $securityPath -Value $securityJson -Encoding UTF8
Write-Host "Created: $securityPath"

# ------------------------------------------------------------
# 6. Create README
# ------------------------------------------------------------

$readme = @'
HS_IP_PS
HIGH SECURITY IP PROTECTION SYSTEM

This workspace is private.

Do not distribute:
- keys
- logs
- audit
- scripts
- source_original
- source_work
- include_work
- backup

Customer distribution must come only from:
customer_packages

All pipeline writes must remain inside the project root.
'@

$readmePath = Join-Path $Root "README.md"
Set-Content -Path $readmePath -Value $readme -Encoding UTF8
Write-Host "Created: $readmePath"

# ------------------------------------------------------------
# 7. Create .gitignore
# ------------------------------------------------------------

$gitignore = @'
# HS_IP_PS local Git exclusions

keys/private/
keys/shards/
logs/
audit/
backup/
source_work/
include_work/
build/
dist/
customer_packages/
licenses/

*.log
*.tmp
*.bak
*.old
'@

$gitignorePath = Join-Path $Root ".gitignore"
Set-Content -Path $gitignorePath -Value $gitignore -Encoding UTF8
Write-Host "Created: $gitignorePath"

# ------------------------------------------------------------
# 8. Apply NTFS permissions if elevated
# ------------------------------------------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-Host "Applying NTFS permissions..." -ForegroundColor Cyan

    $currentUser = (whoami).Trim()

    icacls $Root /inheritance:r | Out-Null
    icacls $Root /grant:r "Administrators:(OI)(CI)F" | Out-Null
    icacls $Root /grant:r "SYSTEM:(OI)(CI)F" | Out-Null
    icacls $Root /grant:r "${currentUser}:(OI)(CI)F" | Out-Null

    $privateKeys = Join-Path $Root "keys\private"
    icacls $privateKeys /inheritance:r | Out-Null
    icacls $privateKeys /grant:r "Administrators:(OI)(CI)F" | Out-Null
    icacls $privateKeys /grant:r "SYSTEM:(OI)(CI)F" | Out-Null
    icacls $privateKeys /grant:r "${currentUser}:(OI)(CI)F" | Out-Null

    Write-Host "NTFS permissions applied." -ForegroundColor Green
} else {
    Write-Warning "This script is not elevated. NTFS permissions were not changed."
    Write-Warning "Run PowerShell as Administrator and rerun this script to apply permissions."
}

# ------------------------------------------------------------
# 9. Initialize local Git repository (isolated: --local config only)
# ------------------------------------------------------------

$gitCommand = Get-Command git -ErrorAction SilentlyContinue

if ($null -ne $gitCommand -or $gitExe -ne "") {
    $gitBin = if ($null -ne $gitCommand) { "git" } else { $gitExe }

    Push-Location $Root

    if (-not (Test-Path ".git")) {
        & $gitBin init -b main
        Write-Host "Initialized local Git repository." -ForegroundColor Green
    } else {
        Write-Host "Git repository already exists." -ForegroundColor DarkGray
    }

    # Isolation: repo-scoped (local) config only. No --global, no remote.
    & $gitBin config --local user.name "HS_IP_PS Developer" | Out-Null
    & $gitBin config --local user.email "developer@local.hsips" | Out-Null
    & $gitBin config --local core.autocrlf true | Out-Null
    & $gitBin config --local core.safecrlf true | Out-Null

    & $gitBin add . | Out-Null
    & $gitBin commit -m "HS_IP_PS bootstrap structure" --allow-empty | Out-Null

    Pop-Location
} else {
    Write-Warning "Git was not found. Local Git initialization skipped."
}

# ------------------------------------------------------------
# 10. Verify bundle artifacts
# ------------------------------------------------------------

if (-not (Test-Path (Join-Path $Root "scripts\HSIPS-Guard.ps1"))) {
    Write-Warning "scripts\HSIPS-Guard.ps1 is missing. Copy the scripts from the HS_IP_PS bundle."
}

Write-Host ""
Write-Host "HS_IP_PS bootstrap completed." -ForegroundColor Green
Write-Host "Root: $Root" -ForegroundColor Green
