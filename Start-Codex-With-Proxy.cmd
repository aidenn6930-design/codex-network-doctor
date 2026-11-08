@echo off
powershell.exe -NoProfile -File "%~dp0src\Start-CodexWithProxy.ps1" %*
if errorlevel 1 (
    echo.
    echo Codex did not start. Review the message above, then press any key to close this window.
    pause >nul
)
