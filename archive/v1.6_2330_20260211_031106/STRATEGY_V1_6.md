# Baseline v1.6 (2330) - Weekly Runbook + Output Isolation

## What changed vs v1.5
- weekly_runbook.py no longer MOVEs report_2330.md (copy only)
- weekly_runbook.py isolates outputs to prevent overwriting:
  - v1.1: data/phase6_trades_2330_v11.csv, data/phase6_equity_2330_v11.csv
  - v1.5: data/phase6_trades_2330_v15.csv, data/phase6_equity_2330_v15.csv

## Regime rule (monthly)
- strong_trend = (Close > SMA200 AND SMA50 > SMA200)
- base allocation:
  - strong_trend True: v1.1=60% / v1.5=40%
  - else: v1.1=80% / v1.5=20%
- overheat downgrade:
  - dist_to_sma50_pct >= 10% => v1.1=80% / v1.5=20%

## Latest snapshot
- Month: 2026-02
- Date:  2026-02-10
- Close: 1880.0
- SMA50: 1624.6
- SMA200:1298.575
- StrongTrend: True
- DistToSMA50(%): 15.72
- Overheated: True
- AllocationFinal: v1.1=80% / v1.5=20% (downgrade: overheated)

## Repro command
.\.venv\Scripts\python.exe .\scripts\weekly_runbook.py --symbol 2330 --in data/2330.csv --out reports/weekly_runbook_2330.md
