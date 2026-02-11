@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\health_check.ps1" -MaxAgeMinutes 15 -VerboseMode
echo ExitCode=%ERRORLEVEL%
pause
