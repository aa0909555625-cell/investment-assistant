@echo off
setlocal enabledelayedexpansion

REM === project ===
cd /d "D:\projects\investment-assistant\server"

REM === weekend skip (Sat=6 Sun=0) via PowerShell tiny one-liner ===
for /f %%d in ('powershell -NoProfile -Command "(Get-Date).DayOfWeek.value__"') do set DOW=%%d
if "%DOW%"=="0" exit /b 0
if "%DOW%"=="6" exit /b 0

REM === log dir ===
if not exist "D:\projects\investment-assistant\server\storage\logs" mkdir "D:\projects\investment-assistant\server\storage\logs"

REM === YYYYMMDD (locale-independent) ===
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyyMMdd\")"') do set DS=%%i

REM === run ===
"C:\xampp\php\php.exe" "D:\projects\investment-assistant\server\artisan" market:run-daily > "D:\projects\investment-assistant\server\storage\logs\market_run_daily_!DS!.log" 2>&1

endlocal
