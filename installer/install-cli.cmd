@echo off
rem Double-clickable wrapper for the EmLoad CLI installer.
rem Accepts the same switches as install-cli.ps1, e.g.
rem   install-cli.cmd -SkipPySide6
rem   install-cli.cmd -Uninstall
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-cli.ps1" %*
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
    echo.
    echo EmLoad CLI setup finished with exit code %code%.
    pause
)
exit /b %code%
