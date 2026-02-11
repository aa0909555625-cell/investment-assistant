from __future__ import annotations

import itertools
import subprocess
import sys
from pathlib import Path

import pandas as pd


def run(cmd: list[str]) -> None:
    subprocess.check_call(cmd)


def parse_report(md_path: Path) -> dict:
    txt = md_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    out = {"total_return": None, "max_drawdown": None, "sharpe": None, "trade_count": None, "win_rate": None}
    for line in txt:
        line = line.strip()
        if line.startswith("- Total Return:"):
            out["total_return"] = float(line.split(":")[1].replace("%", "").strip())
        elif line.startswith("- Max Drawdown:"):
            out["max_drawdown"] = float(line.split(":")[1].replace("%", "").strip())
        elif line.startswith("- Sharpe"):
            out["sharpe"] = float(line.split(":")[1].strip())
        elif line.startswith("- Trade Count:"):
            out["trade_count"] = int(line.split(":")[1].strip())
        elif line.startswith("- Win Rate:"):
            out["win_rate"] = float(line.split(":")[1].replace("%", "").strip())
    return out


def main() -> int:
    # Strategy intent:
    # - RSI is timing, trend gate defines regime
    # - Aim for enough trades to evaluate (>= 10)

    symbol = "2330"
    inp = Path("data/2330.csv")
    if not inp.exists():
        raise SystemExit("Missing data/2330.csv")

    # More sensible grid for trend-gated RSI on 2330:
    rsi_periods = [14, 20]
    buy_levels = [35, 40, 45, 50]
    sell_levels = [55, 60, 65]
    cooldowns = [0, 2, 3, 5]
    trend_modes = ["both", "sma_cross", "close_above_slow"]  # exclude none by default

    # SMA choices (keep stable)
    sma_fast = 50
    sma_slow = 200

    trade_threshold = 10

    py = sys.executable
    results = []

    out_dir = Path("reports/scan_tmp")
    out_dir.mkdir(parents=True, exist_ok=True)

    phase5_out = Path(f"data/phase5_signals_{symbol}.csv")
    phase6_trades = Path(f"data/phase6_trades_{symbol}.csv")
    phase6_equity = Path(f"data/phase6_equity_{symbol}.csv")

    combos = list(itertools.product(rsi_periods, buy_levels, sell_levels, cooldowns, trend_modes))
    total = 0

    for period, buy, sell, cooldown, trend_mode in combos:
        if buy >= sell:
            continue

        total += 1
        report_out = out_dir / f"report_{symbol}_p{period}_b{buy}_s{sell}_c{cooldown}_t{trend_mode}.md"

        run([
            py, "scripts/phase5_signals_rsi.py",
            "--in", str(inp),
            "--out", str(phase5_out),
            "--rsi_period", str(period),
            "--buy_rsi", str(float(buy)),
            "--sell_rsi", str(float(sell)),
            "--sma_fast", str(sma_fast),
            "--sma_slow", str(sma_slow),
            "--trend_mode", trend_mode,
        ])

        run([
            py, "scripts/phase6_backtest_singlepos.py",
            "--in", str(phase5_out),
            "--out_trades", str(phase6_trades),
            "--out_equity", str(phase6_equity),
            "--initial_cash", "1000000",
            "--cooldown_bars", str(cooldown),
            "--slippage_bps", "0",
            "--stop_loss", "0",
            "--take_profit", "0",
        ])

        run([
            py, "scripts/phase7_report.py",
            "--equity", str(phase6_equity),
            "--trades", str(phase6_trades),
            "--out", str(report_out),
        ])

        m = parse_report(report_out)
        results.append({
            "rsi_period": period,
            "buy_rsi": buy,
            "sell_rsi": sell,
            "cooldown_bars": cooldown,
            "trend_mode": trend_mode,
            "sma_fast": sma_fast,
            "sma_slow": sma_slow,
            "trade_count": m["trade_count"],
            "win_rate_pct": m["win_rate"],
            "total_return_pct": m["total_return"],
            "max_drawdown_pct": m["max_drawdown"],
            "sharpe": m["sharpe"],
            "report": str(report_out).replace("\\", "/"),
        })

    df = pd.DataFrame(results)

    # Enforce minimum trades for evaluation
    df_ok = df[df["trade_count"].fillna(0) >= trade_threshold].copy()

    # If nothing passes threshold, still export full df but flag
    out_full = Path("reports/rsi_scan_full.csv")
    df.to_csv(out_full, index=False, encoding="utf-8")

    out_rank = Path("reports/rsi_scan_rank.csv")
    if df_ok.empty:
        df2 = df.copy()
        df2["score"] = 0.0
        df2.to_csv(out_rank, index=False, encoding="utf-8")
        print(f"OK wrote: {out_rank} rows={len(df2)} (WARNING: no strategy met trade_threshold >= {trade_threshold})")
        return 0

    # Score: reward return & sharpe, penalize drawdown; slight penalty if too many trades (overtrading)
    df_ok["score"] = (
        df_ok["total_return_pct"].fillna(0) * 1.0
        - df_ok["max_drawdown_pct"].fillna(0) * 0.8
        + df_ok["sharpe"].fillna(0) * 10.0
        - (df_ok["trade_count"].fillna(0) * 0.05)
    )

    df_ok = df_ok.sort_values(["score"], ascending=False).reset_index(drop=True)
    df_ok.to_csv(out_rank, index=False, encoding="utf-8")

    print(f"OK wrote: {out_rank} rows={len(df_ok)} (trade_threshold >= {trade_threshold})")
    print("Top 10:")
    print(df_ok.head(10)[[
        "rsi_period","buy_rsi","sell_rsi","cooldown_bars","trend_mode",
        "trade_count","win_rate_pct","total_return_pct","max_drawdown_pct","sharpe","score"
    ]].to_string(index=False))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
