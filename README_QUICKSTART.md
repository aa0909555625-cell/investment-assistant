# Investment Assistant — Quick Start

## Daily usage (most common)
1) Run doctor:
   powershell -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Cash 300000

## What doctor does
- env_check
- health_check
- retention_cleanup (keep 30 days)
- run main .\run.ps1 (if exists)
- generate Top10 report (if script exists)

## Tips
- If ExecutionPolicy blocks scripts:
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

- To open latest report:
  Get-ChildItem .\reports\*.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | % { notepad .FullName }
