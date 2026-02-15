$ErrorActionPreference = 'Stop'

# weekend skip
$dow = [int](Get-Date).DayOfWeek
if ($dow -eq 0 -or $dow -eq 6) { exit 0 }

$project = 'D:\projects\investment-assistant\server'
$php     = 'C:\xampp\php\php.exe'
$artisan = Join-Path $project 'artisan'

$logDir = Join-Path $project 'storage\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir ("market_run_daily_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

# overwrite log every run, force UTF-8 codepage in cmd session
cmd.exe /c "chcp 65001>nul & "$php" "$artisan" market:run-daily > "$log" 2>&1"