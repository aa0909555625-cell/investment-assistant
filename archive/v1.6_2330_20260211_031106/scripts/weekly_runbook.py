from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import shutil
import pandas as pd


def extract_core_6(report_path: Path) -> list[str]:
    want_prefix = [
        "- End Equity:",
        "- Total Return:",
        "- Max Drawdown:",
        "- Sharpe",
        "- Trade Count:",
        "- Win Rate:",
    ]
    if not report_path.exists():
        return [f"(missing report: {report_path})"]

    lines = report_path.read_text(encoding="utf-8").splitlines()
    out: list[str] = []
    for p in want_prefix:
        hit = next((l.strip() for l in lines if l.strip().startswith(p)), None)
        if hit:
            out.append(hit)
    return out


def run(cmd: list[str]) -> None:
    subprocess.check_call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="2330")
    ap.add_argument("--in", dest="inp", default="data/2330.csv")
    ap.add_argument("--out", default="reports/weekly_runbook_2330.md")
    args = ap.parse_args()

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Input not found: {inp}")

    regime_path = Path("reports/monthly_regime_2330.csv")
    if not regime_path.exists():
        raise SystemExit("Missing reports/monthly_regime_2330.csv (run scripts/monthly_regime.py first)")

    reg = pd.read_csv(regime_path).iloc[-1].to_dict()
    py = str(Path(".venv/Scripts/python.exe"))

    # Output isolation paths
    v11_report = Path("reports/_tmp_v11.md")
    v15_report = Path("reports/_tmp_v15.md")

    v11_trades = Path("data/phase6_trades_2330_v11.csv")
    v11_equity = Path("data/phase6_equity_2330_v11.csv")

    v15_trades = Path("data/phase6_trades_2330_v15.csv")
    v15_equity = Path("data/phase6_equity_2330_v15.csv")

    # --------------------
    # v1.1 (baseline) run
    # --------------------
    run([py, "scripts/run_pipeline.py",
         "--symbol", args.symbol,
         "--in", str(inp),
         "--rsi_period", "14",
         "--buy_rsi", "50",
         "--sell_rsi", "60",
         "--cooldown_bars", "2"
    ])

    # Preserve report_2330.md into v11 report snapshot
    src_report = Path("reports/report_2330.md")
    if not src_report.exists():
        raise SystemExit("Expected reports/report_2330.md not found after run_pipeline.py")
    shutil.copyfile(src_report, v11_report)

    # Also snapshot the default outputs into v11 isolated files (if present)
    src_trades = Path("data/phase6_trades_2330.csv")
    src_equity = Path("data/phase6_equity_2330.csv")
    if src_trades.exists():
        shutil.copyfile(src_trades, v11_trades)
    if src_equity.exists():
        shutil.copyfile(src_equity, v11_equity)

    # --------------------
    # v1.5 run (trend-only + stop/trailing)
    # --------------------
    run([py, "scripts/phase5_signals_rsi.py",
         "--in", str(inp),
         "--out", "data/phase5_signals_2330.csv",
         "--rsi_period", "14",
         "--buy_rsi", "50",
         "--sell_rsi", "60"
    ])

    run([py, "scripts/phase6_backtest_singlepos.py",
         "--in", "data/phase5_signals_2330.csv",
         "--out_trades", str(v15_trades),
         "--out_equity", str(v15_equity),
         "--initial_cash", "1000000",
         "--cooldown_bars", "2",
         "--slippage_bps", "5",
         "--stop_loss", "0.04",
         "--stop_loss_mode", "low",
         "--trailing_stop", "0.10",
         "--trailing_mode", "low",
         "--exit_mode", "trend",
         "--trend_exit", "sma_fast",
    ])

    run([py, "scripts/phase7_report.py",
         "--equity", str(v15_equity),
         "--trades", str(v15_trades),
         "--out", str(v15_report),
    ])

    # Collect core stats
    v11_core = extract_core_6(v11_report)
    v15_core = extract_core_6(v15_report)

    # Recent trades table from v1.5
    trades_df = pd.read_csv(v15_trades) if v15_trades.exists() else pd.DataFrame()
    last_trades = trades_df.tail(5).to_dict(orient="records") if not trades_df.empty else []

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    md: list[str] = []
    md.append(f"# Weekly Runbook ({args.symbol})")
    md.append("")
    md.append("## Latest Monthly Regime Snapshot")
    md.append(f"- Month: {reg.get('month')}")
    md.append(f"- Date:  {reg.get('date')}")
    md.append(f"- Close: {reg.get('close')}")
    md.append(f"- SMA50: {reg.get('sma50')}")
    md.append(f"- SMA200:{reg.get('sma200')}")
    md.append(f"- StrongTrend: {reg.get('strong_trend')}")
    md.append(f"- DistToSMA50(%): {reg.get('dist_to_sma50_pct')}")
    md.append(f"- Overheated: {reg.get('overheated')}")
    md.append(f"- AllocationFinal: {reg.get('allocation_final')}")
    md.append("")
    md.append("## Strategy Metrics (Core 6 lines)")
    md.append("")
    md.append("### v1.1 (baseline / exit_mode=both)")
    md.extend(v11_core)
    md.append("")
    md.append("### v1.5 (trend-only / stop_loss_low 4% / trailing_low 10%)")
    md.extend(v15_core)
    md.append("")
    md.append("## Recent Trades (v1.5 last 5)")
    if last_trades:
        md.append("| entry_date | exit_date | entry_price | exit_price | return_pct | exit_reason |")
        md.append("|---|---|---:|---:|---:|---|")
        for t in last_trades:
            rp = float(t.get("return_pct", 0.0)) * 100.0
            md.append(f"| {t.get('entry_date')} | {t.get('exit_date')} | {t.get('entry_price')} | {t.get('exit_price')} | {rp:.2f}% | {t.get('exit_reason')} |")
    else:
        md.append("- (no trades)")
    md.append("")
    md.append("## Output Files (isolated)")
    md.append(f"- v1.1 trades: {v11_trades}")
    md.append(f"- v1.1 equity: {v11_equity}")
    md.append(f"- v1.5 trades: {v15_trades}")
    md.append(f"- v1.5 equity: {v15_equity}")
    md.append("")
    md.append("## Action (this week)")
    md.append(f"- Follow AllocationFinal: **{reg.get('allocation_final')}**")

    out_path.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"OK wrote: {out_path}")
    print(f"OK isolated: {v11_trades}, {v11_equity}, {v15_trades}, {v15_equity}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
