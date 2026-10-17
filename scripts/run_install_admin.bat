@echo off
chcp 65001 >nul
rem Resolve project root from this script's own location,
rem so the project can be renamed or moved without breaking paths.
set "SCRIPT_DIR=%~dp0"
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

rem Self-elevate: registering a SYSTEM scheduled task needs administrator.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install_task.ps1" > "%ROOT%\logs\install_stdout.txt" 2>&1
if errorlevel 1 (
    echo Install failed, see "%ROOT%\logs\install_stdout.txt"
    type "%ROOT%\logs\install_stdout.txt"
    pause
    exit /b 1
)
echo Install OK. See "%ROOT%\logs\install_task.log"
pause
