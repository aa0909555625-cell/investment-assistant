from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def run(cmd: list[str]) -> None:
    print(">> " + " ".join(cmd))
    subprocess.run(cmd, check=True)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Weekly pipeline: Phase5 -> Phase6 -> Weekly report")
    ap.add_argument("--py", default=r".\.venv\Scripts\python.exe")
    ap.add_argument("--symbol", default="2330")
    ap.add_argument("--in_csv", default=r"data\2330.csv")

    ap.add_argument("--rsi_period", type=int, default=14)
    ap.add_argument("--buy_rsi", type=float, default=50.0)
    ap.add_argument("--sell_rsi", type=float, default=60.0)

    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--cooldown_bars", type=int, default=2)
    ap.add_argument("--slippage_bps", type=float, default=5.0)
    ap.add_argument("--stop_loss", type=float, default=0.04)
    ap.add_argument("--stop_loss_mode", default="low")
    ap.add_argument("--trailing_stop", type=float, default=0.10)
    ap.add_argument("--trailing_mode", default="low")
    ap.add_argument("--exit_mode", default="trend")
    ap.add_argument("--trend_exit", default="sma_fast")

    ap.add_argument("--out_dir", default="reports")
    return ap.parse_args()


def main() -> int:
    args = parse_args()

    root = Path(".")
    py = args.py

    symbol = str(args.symbol)
    inp = Path(args.in_csv)

    signals = Path("data") / f"phase5_signals_{symbol}.csv"
    trades = Path("data") / f"phase6_trades_{symbol}_v15.csv"
    equity = Path("data") / f"phase6_equity_{symbol}_v15.csv"

    out_dir = Path(args.out_dir)
    report = out_dir / f"weekly_{symbol}.md"
    alloc = out_dir / f"allocation_final_{symbol}.json"

    # Phase5
    run(
        [
            py,
            r".\scripts\phase5_signals_rsi.py",
            "--in",
            str(inp),
            "--out",
            str(signals),
            "--rsi_period",
            str(int(args.rsi_period)),
            "--buy_rsi",
            str(float(args.buy_rsi)),
            "--sell_rsi",
            str(float(args.sell_rsi)),
            "--trend",
            "both",
            "--sma_fast",
            "50",
            "--sma_slow",
            "200",
        ]
    )

    # Phase6
    run(
        [
            py,
            r".\scripts\phase6_backtest_singlepos.py",
            "--in",
            str(signals),
            "--out_trades",
            str(trades),
            "--out_equity",
            str(equity),
            "--initial_cash",
            str(float(args.initial_cash)),
            "--cooldown_bars",
            str(int(args.cooldown_bars)),
            "--slippage_bps",
            str(float(args.slippage_bps)),
            "--stop_loss",
            str(float(args.stop_loss)),
            "--stop_loss_mode",
            str(args.stop_loss_mode),
            "--trailing_stop",
            str(float(args.trailing_stop)),
            "--trailing_mode",
            str(args.trailing_mode),
            "--exit_mode",
            str(args.exit_mode),
            "--trend_exit",
            str(args.trend_exit),
        ]
    )

    # Weekly
    run(
        [
            py,
            r".\scripts\weekly_runbook.py",
            "--symbol",
            symbol,
            "--equity_csv",
            str(equity),
            "--trades_csv",
            str(trades),
            "--out_report",
            str(report),
            "--out_allocation",
            str(alloc),
            "--trades_tail",
            "10",
        ]
    )

    print(f"OK weekly_pipeline done. report={report} allocation={alloc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
