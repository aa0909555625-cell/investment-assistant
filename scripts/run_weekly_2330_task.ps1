$ErrorActionPreference = 'Stop'
Set-Location 'D:\projects\investment-assistant'

if (-not (Test-Path 'D:\projects\investment-assistant\logs')) { New-Item -ItemType Directory -Force -Path 'D:\projects\investment-assistant\logs' | Out-Null }

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$log = Join-Path 'D:\projects\investment-assistant\logs' "weekly_multi_$ts.log"

"== RUN weekly pipeline: $ts ==" | Out-File -FilePath $log -Encoding utf8 -Append

& 'D:\projects\investment-assistant\.venv\Scripts\python.exe' '.\scripts\weekly_pipeline.py' --symbols 2330,0050 --fetch_mode always --quiet 2>&1 | Tee-Object -FilePath $log -Append

"== DONE ==" | Out-File -FilePath $log -Encoding utf8 -Append
