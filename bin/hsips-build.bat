@echo off
setlocal

if "%~1"=="" (
    echo Usage: hsips-build.bat PRODUCT_CODE
    echo Example: hsips-build.bat NEBULA_SCALPER
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\Invoke-HSIPSBuild.ps1" -ProductCode "%~1"

endlocal
