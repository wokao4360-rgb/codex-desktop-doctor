@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\CodexDesktopDoctor.ps1" %*
exit /b %ERRORLEVEL%
