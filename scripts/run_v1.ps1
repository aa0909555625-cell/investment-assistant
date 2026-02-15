param(
  [Parameter(Mandatory=$true)][string]$Date,
  [double]$Capital = 300000,
  [int]$MaxPicks = 20,
  [double]$RiskPerTrade = 0.01,
  [switch]$Open
)

$ErrorActionPreference = "Stop"

Write-Host "=== RUN v1 PIPELINE ===" -ForegroundColor Cyan
Write-Host "Date=$Date Capital=$Capital MaxPicks=$MaxPicks RiskPerTrade=$RiskPerTrade" -ForegroundColor DarkGray

# 1) rehab (existing 7.5)
& ".\scripts\rehab_data_schema.ps1" -Date $Date | Out-Host

# 2) decision table (gates + action + reason)
& ".\scripts\enrich_decision_table.ps1" -Date $Date | Out-Host

# 3) order tickets (CSV + MD)
& ".\scripts\build_order_tickets.ps1" -Date $Date -Capital $Capital -RiskPerTrade $RiskPerTrade -MaxPicks $MaxPicks | Out-Host

# 4) daily report (MD) - generate before dashboard, so dashboard param mismatch won't block it
& ".\scripts\build_daily_report.ps1" -Date $Date | Out-Host

# 5) dashboard (best-effort; handle scripts that don't accept -Date)
try {
  & ".\scripts\build_dashboard_html.ps1" -Date $Date -Capital $Capital -Top 4000 | Out-Host
} catch {
  Write-Host "[WARN] build_dashboard_html.ps1 doesn't accept -Date. Retrying without -Date..." -ForegroundColor Yellow
  & ".\scripts\build_dashboard_html.ps1" -Capital $Capital -Top 4000 | Out-Host
}

# 6) health check
if (Test-Path ".\scripts\run_health_check.ps1") { & ".\scripts\run_health_check.ps1" | Out-Host }

# open outputs
if ($Open) {
  $dash = Get-ChildItem ".\reports" -Filter "tw_dashboard_*html" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($dash) { Start-Process $dash.FullName }

  $rep = ".\reports\daily_report_$($Date.Replace('-','')).md"
  if (Test-Path $rep) { Start-Process (Resolve-Path $rep).Path }

  $tmd = ".\reports\order_tickets_$($Date.Replace('-','')).md"
  if (Test-Path $tmd) { Start-Process (Resolve-Path $tmd).Path }
}

Write-Host "DONE v1." -ForegroundColor Green