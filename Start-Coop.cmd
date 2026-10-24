@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Coop.ps1" -ProjectRoot "%~dp0"
if errorlevel 1 goto :failure
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Coop.ps1"
set "result=%ERRORLEVEL%"
echo.
pause
exit /b %result%
:failure
echo The update check could not start. The launcher was not opened.
pause
exit /b 1
