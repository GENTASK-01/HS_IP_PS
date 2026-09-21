# ==========================================================
# HS_IP_PS Guard Helper
# Single source of truth for the project root and write-path
# enforcement. Every pipeline script dot-sources this file.
# ==========================================================

# Resolve the project root once: prefer the HSIPS_HOME machine
# environment variable; otherwise derive it from this script's own
# location (scripts/ is always directly under the root), so the whole
# system is fully relocatable with no hardcoded drive letter.
$global:HSIPS_ROOT = [Environment]::GetEnvironmentVariable("HSIPS_HOME", "Machine")

if ([string]::IsNullOrWhiteSpace($global:HSIPS_ROOT)) {
    $global:HSIPS_ROOT = Split-Path $PSScriptRoot -Parent
}

function Assert-HSIPSWritePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $allowedRoot = [System.IO.Path]::GetFullPath($global:HSIPS_ROOT)

    if (-not $fullPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "HS_IP_PS WRITE GUARD BLOCKED OPERATION: $fullPath is outside $allowedRoot"
    }
}

function Assert-HSIPSProjectRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-HSIPSWritePath -Path $Path
}

function Get-HSIPSConfig {
    $configPath = Join-Path $global:HSIPS_ROOT "config\hsips.json"

    if (-not (Test-Path $configPath)) {
        throw "HS_IP_PS configuration not found: $configPath"
    }

    return (Get-Content -Path $configPath -Raw | ConvertFrom-Json)
}
