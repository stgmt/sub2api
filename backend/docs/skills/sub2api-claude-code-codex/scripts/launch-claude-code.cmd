@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%launch-claude-code.ps1" %*
exit /b %ERRORLEVEL%
