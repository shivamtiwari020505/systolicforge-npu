@echo off
setlocal
if "%~1"=="" (
    echo Usage: fpga\vivado\run_vivado.cmd full^|basys3^|all
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_vivado.ps1" -Flow "%~1"
exit /b %errorlevel%
