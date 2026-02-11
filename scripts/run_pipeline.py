from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str]) -> None:
    print("==> " + " ".join(cmd))
    subprocess.check_call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser(description="Investment Assistant pipeline runner (Phase 5/6/7)")
    ap.add_argument("--symbol", default="2330")
    ap.add_argument("--in", dest="inp", default="data/2330.csv")

    # Phase5 params
    ap.add_argument("--rsi_period", type=int, default=14)
    ap.add_argument("--buy_rsi", type=float, default=50.0)
    ap.add_argument("--sell_rsi", type=float, default=60.0)

    # Phase6 params
    ap.add_argument("--cooldown_bars", type=int, default=2)
    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--slippage_bps", type=float, default=0.0)
    ap.add_argument("--stop_loss", type=float, default=0.0)
    ap.add_argument("--stop_loss_mode", choices=["close", "low"], default="close")
    ap.add_argument("--trailing_stop", type=float, default=0.0)
    ap.add_argument("--trailing_mode", choices=["close", "low"], default="close")  # NEW
    ap.add_argument("--take_profit", type=float, default=0.0)

    args = ap.parse_args()

    root = Path(".")
    scripts = root / "scripts"
    data = root / "data"
    reports = root / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    data.mkdir(parents=True, exist_ok=True)

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Input not found: {inp}")

    # outputs
    p5_out = data / f"phase5_signals_{args.symbol}.csv"
    p6_trades = data / f"phase6_trades_{args.symbol}.csv"
    p6_equity = data / f"phase6_equity_{args.symbol}.csv"
    p7_out = reports / f"report_{args.symbol}.md"

    py = str(Path(sys.executable))

    # Phase 5
    run([
        py, str(scripts / "phase5_signals_rsi.py"),
        "--in", str(inp),
        "--out", str(p5_out),
        "--rsi_period", str(args.rsi_period),
        "--buy_rsi", str(args.buy_rsi),
        "--sell_rsi", str(args.sell_rsi),
    ])

    # Phase 6
    run([
        py, str(scripts / "phase6_backtest_singlepos.py"),
        "--in", str(p5_out),
        "--out_trades", str(p6_trades),
        "--out_equity", str(p6_equity),
        "--initial_cash", str(args.initial_cash),
        "--cooldown_bars", str(args.cooldown_bars),
        "--slippage_bps", str(args.slippage_bps),
        "--stop_loss", str(args.stop_loss),
        "--stop_loss_mode", str(args.stop_loss_mode),
        "--trailing_stop", str(args.trailing_stop),
        "--trailing_mode", str(args.trailing_mode),   # NEW passthrough
        "--take_profit", str(args.take_profit),
    ])

    # Phase 7
    run([
        py, str(scripts / "phase7_report.py"),
        "--equity", str(p6_equity),
        "--trades", str(p6_trades),
        "--out", str(p7_out),
    ])

    print(f"OK pipeline done. Report: {p7_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
