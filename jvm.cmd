@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0jvm.ps1" %*
exit /b %ERRORLEVEL%
