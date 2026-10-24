@echo off
chcp 65001 >nul
setlocal
rem Resolve project root from this script's own location,
rem so the project can be renamed or moved without breaking paths.
set "SCRIPT_DIR=%~dp0"
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"
set "STDOUT_FILE=%ROOT%\logs\install_stdout.txt"

rem Pre-check: without config.ini the task installs fine but fails every minute.
if not exist "%SCRIPT_DIR%config.ini" (
    echo [WARN] config.ini not found: "%SCRIPT_DIR%config.ini"
    echo        The task will install but fail every minute until you create it:
    echo          copy config.example.ini config.ini   ^(then fill in the real password^)
    echo.
)

rem Self-elevate: registering a SYSTEM scheduled task needs administrator.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges - a UAC prompt will appear.
    echo Click "Yes", then CONTINUE IN THE NEW WINDOW; this window will close.
    powershell.exe -NoProfile -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Elevation refused - nothing was installed.' }"
    exit /b
)

echo [1/2] Registering scheduled task CampusAutoLogin ...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install_task.ps1" > "%STDOUT_FILE%" 2>&1
set "RC=%errorlevel%"

rem Show the full output (Chinese messages come from install_task.ps1; shown here so
rem you do not have to open the log file to see the conclusion).
type "%STDOUT_FILE%"
echo.
echo [2/2] Finished. Exit code = %RC%  ^(0=success, 2=needs manual check, 1=failed^)
echo.

if "%RC%"=="0" echo [RESULT] Success - task installed, enabled, runs every minute.
if "%RC%"=="2" echo [RESULT] Registered but NOT verified - read the conclusion above.
if not "%RC%"=="0" if not "%RC%"=="2" echo [RESULT] Failed - nothing was installed. See "%STDOUT_FILE%"
echo.
echo Next: wait 1-2 minutes, then check the run log
echo   Get-Content "%ROOT%\logs\auto_login.log" -Tail 20
echo Logs: "%ROOT%\logs\install_task.log"
pause
exit /b %RC%
