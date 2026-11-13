@echo off
setlocal
cd /d "%~dp0"

rem Start the IPTV web player + local ysp-live source in the BACKGROUND, no windows.
rem Usage: start.bat [/check] [/q] [/nolocal]
rem   /check   : show which node/python would be used, start nothing
rem   /q       : accepted for compatibility (output is already quiet)
rem   /nolocal : do not start the local ysp-live source
rem Env: NODE_EXE, PY_EXE, PORT (8088), YSP_PORT (20345), HOST, M3U_SRC
rem Logs: logs\node.log, logs\start-status.txt (local source output discarded)
rem Bundled portable runtimes: runtime\node\node.exe + runtime\python\python.exe (nothing to install)
rem Local source auto-restarts every 3h by its own supervisor.
rem   YSP_RESTART_HOURS=6 changes the interval, 0 disables it;
rem   YSP_RESTART_AT=02:00 adds a daily restart (earliest deadline wins).
rem   Restart events are logged to logs\restart.log.
rem NOTE: a .bat always flashes a console window when double-clicked.
rem       For a completely silent start, double-click start.vbs instead.

set "CHECK="
set "QUIET="
if /i "%~1"=="/check" set "CHECK=1"
if /i "%~2"=="/check" set "CHECK=1"
if /i "%~3"=="/check" set "CHECK=1"
if /i "%~1"=="/q" set "QUIET=1"
if /i "%~2"=="/q" set "QUIET=1"
if /i "%~3"=="/q" set "QUIET=1"
if /i "%~1"=="/nolocal" set "IPTV_NOLOCAL=1"
if /i "%~2"=="/nolocal" set "IPTV_NOLOCAL=1"
if /i "%~3"=="/nolocal" set "IPTV_NOLOCAL=1"

if defined CHECK (
    cscript //nologo "%~dp0start.vbs" /check
    echo.
    pause
    exit /b 0
)

cscript //nologo "%~dp0start.vbs"
if errorlevel 2 (
    echo [ERROR] Node.js not found. Download (LTS, Windows x64 .msi):
    echo         https://nodejs.org/zh-cn/download
    echo         Full details and portable version: logs\node.log
    exit /b 2
)
if errorlevel 1 (
    echo [ERROR] hidden start failed. See logs\start-status.txt
    exit /b 1
)
echo Started in background - no windows. Logs in %~dp0logs
echo Stop with stop.bat
exit /b 0
