@echo off
setlocal

set "HSIPS_ROOT=%~dp0.."
pushd "%HSIPS_ROOT%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HSIPS_ROOT%\scripts\HSIPS-Main.ps1" %*

popd
endlocal
