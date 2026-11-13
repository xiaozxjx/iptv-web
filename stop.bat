@echo off
cd /d "%~dp0"
setlocal enabledelayedexpansion

rem Stop the IPTV web player (8088) AND the local ysp-live source (20345) by TCP port.
rem Usage: stop.bat [port] [/q]
rem   port : stop only this one TCP port (default: stop both services)
rem   /q   : quiet, skip the final pause (can be the only argument)
rem Env: PORT (default 8088), YSP_PORT (default 20345)
rem Log: logs\stop.log - every line is prefixed with [YYYY-MM-DD HH:MM:SS]

rem ISO date for the log stamp; fall back to the local date string.
set "TODAY="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd')"`) do set "TODAY=%%i"
if not defined TODAY (
    set "TODAY=%date%"
    set "TODAY=!TODAY:/=-!"
    set "TODAY=!TODAY:~0,10!"
)

set "P=8088"
if defined PORT set "P=%PORT%"
set "YP=20345"
if defined YSP_PORT set "YP=%YSP_PORT%"
set "QUIET="
set "ARG1="
if /i "%~1"=="/q" set "QUIET=1"
if /i "%~2"=="/q" set "QUIET=1"
if /i "%~1"=="/q" (set "ARG1=") else (set "ARG1=%~1")

call :log "===== stop ====="
if defined ARG1 (
    rem Stopping the source port: kill its supervisor too, otherwise it respawns.
    if "%ARG1%"=="%YP%" call :killsrc
    call :killport %ARG1%
) else (
    rem Kill the supervisor FIRST - it owns no TCP port and would respawn the
    rem worker about 10 seconds after we stop port 20345.
    call :killsrc
    call :killport %P%
    call :killport %YP%
)

if defined QUIET goto :eof
echo.
pause
goto :eof

:killsrc
rem ysp-live.py now runs as supervisor + worker; neither is reliably found by port alone.
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -like '*ysp-live.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
call :log "Stopped ysp-live.py supervisor and worker processes."
goto :eof

:killport
set "Q=%~1"
call :log "Target port: %Q%"
set "FOUND="
for /f "tokens=5" %%a in ('netstat -ano -p TCP ^| findstr /r /c:":%Q% .*LISTENING"') do (
    set "FOUND=1"
    call :log "Stopping PID %%a ..."
    taskkill /PID %%a /F >nul 2>&1
    if errorlevel 1 (
        call :log "  Failed to stop PID %%a - try running as Administrator"
    ) else (
        call :log "  Stopped PID %%a"
    )
)

if not defined FOUND (
    call :log "No service listening on port %Q% - nothing to stop."
) else (
    ping -n 2 127.0.0.1 >nul
    netstat -ano -p TCP | findstr /r /c:":%Q% .*LISTENING" >nul
    if errorlevel 1 (
        call :log "Port %Q% is now free."
    ) else (
        call :log "WARNING: port %Q% is still in use."
    )
)
goto :eof

:log
set "T=!time!"
set "T=!T: =0!"
echo [!TODAY! !T:~0,8!] %~1
goto :eof
