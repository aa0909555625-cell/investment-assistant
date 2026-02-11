from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str]) -> None:
    print("==>", " ".join(cmd))
    subprocess.check_call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="2330")
    ap.add_argument("--in", dest="inp", default="data/2330.csv")
    ap.add_argument("--rsi_period", type=int, default=14)
    ap.add_argument("--buy_rsi", type=float, default=30.0)
    ap.add_argument("--sell_rsi", type=float, default=70.0)
    ap.add_argument("--cooldown_bars", type=int, default=3)
    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--slippage_bps", type=float, default=0.0)
    ap.add_argument("--stop_loss", type=float, default=0.0)
    ap.add_argument("--take_profit", type=float, default=0.0)
    args = ap.parse_args()

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Missing input csv: {inp}")

    phase5_out = Path(f"data/phase5_signals_{args.symbol}.csv")
    phase6_trades = Path(f"data/phase6_trades_{args.symbol}.csv")
    phase6_equity = Path(f"data/phase6_equity_{args.symbol}.csv")
    report_out = Path(f"reports/report_{args.symbol}.md")

    py = sys.executable

    run([
        py, "scripts/phase5_signals_rsi.py",
        "--in", str(inp),
        "--out", str(phase5_out),
        "--rsi_period", str(args.rsi_period),
        "--buy_rsi", str(args.buy_rsi),
        "--sell_rsi", str(args.sell_rsi),
    ])

    run([
        py, "scripts/phase6_backtest_singlepos.py",
        "--in", str(phase5_out),
        "--out_trades", str(phase6_trades),
        "--out_equity", str(phase6_equity),
        "--initial_cash", str(args.initial_cash),
        "--cooldown_bars", str(args.cooldown_bars),
        "--slippage_bps", str(args.slippage_bps),
        "--stop_loss", str(args.stop_loss),
        "--take_profit", str(args.take_profit),
    ])

    run([
        py, "scripts/phase7_report.py",
        "--equity", str(phase6_equity),
        "--trades", str(phase6_trades),
        "--out", str(report_out),
    ])

    print(f"OK pipeline done. Report: {report_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
