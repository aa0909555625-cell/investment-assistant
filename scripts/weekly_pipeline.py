from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import List, Literal


FetchMode = Literal["missing", "always", "never"]


def run(cmd: List[str], quiet: bool) -> None:
    if not quiet:
        print(">> " + " ".join(cmd))
    subprocess.run(cmd, check=True)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Weekly pipeline: (fetch) -> Phase5 -> Phase6 -> Weekly report (multi-symbol)")
    ap.add_argument("--py", default=r".\.venv\Scripts\python.exe")
    ap.add_argument("--symbols", default="2330", help="Comma separated symbols, e.g. 2330,0050,2317 or 2330.TW")
    ap.add_argument("--data_dir", default="data")
    ap.add_argument("--reports_dir", default="reports")

    ap.add_argument("--fetch_mode", choices=["missing", "always", "never"], default="missing")
    ap.add_argument("--min_rows", type=int, default=200)

    # Phase5 params
    ap.add_argument("--rsi_period", type=int, default=14)
    ap.add_argument("--buy_rsi", type=float, default=50.0)
    ap.add_argument("--sell_rsi", type=float, default=60.0)

    # Phase6 params
    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--cooldown_bars", type=int, default=2)
    ap.add_argument("--slippage_bps", type=float, default=5.0)
    ap.add_argument("--stop_loss", type=float, default=0.04)
    ap.add_argument("--stop_loss_mode", default="low")
    ap.add_argument("--trailing_stop", type=float, default=0.10)
    ap.add_argument("--trailing_mode", default="low")
    ap.add_argument("--exit_mode", default="trend")
    ap.add_argument("--trend_exit", default="sma_fast")

    # Output
    ap.add_argument("--trades_tail", type=int, default=10)
    ap.add_argument("--quiet", action="store_true", help="Do not print command lines")
    ap.add_argument("--snapshot_reports", action="store_true", default=True, help="Write dated copies of reports/allocation")
    return ap.parse_args()


def read_allocation(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def md_row(cols: list[str]) -> str:
    return "| " + " | ".join(cols) + " |"


def normalize_symbol(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    digits = "".join(re.findall(r"\d+", s))
    if not digits:
        return ""
    if len(digits) < 4:
        return digits.zfill(4)
    return digits


def parse_symbols(s: str) -> list[str]:
    parts = [p.strip() for p in str(s).split(",") if p.strip()]
    out: list[str] = []
    for p in parts:
        sym = normalize_symbol(p)
        if sym and sym not in out:
            out.append(sym)
    return out


def maybe_fetch(py: str, sym: str, inp: Path, fetch_mode: FetchMode, min_rows: int, quiet: bool) -> tuple[bool, str]:
    if fetch_mode == "never":
        return inp.exists(), ("OK existing" if inp.exists() else "missing")

    if fetch_mode == "missing" and inp.exists():
        return True, "OK existing"

    try:
        run(
            [
                py,
                r".\scripts\data_fetch_stooq.py",
                "--symbol",
                sym,
                "--out",
                str(inp),
                "--force",
                "--min_rows",
                str(int(min_rows)),
            ],
            quiet=quiet,
        )
        return inp.exists(), ("OK fetched" if inp.exists() else "fetch_no_file")
    except subprocess.CalledProcessError as e:
        if inp.exists():
            print(f"[WARN] fetch failed for {sym} (exit={e.returncode}); using existing file: {inp}")
            return True, "fetch_failed_use_existing"
        return False, f"fetch_failed (exit={e.returncode})"


def safe_copy(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def main() -> int:
    args = parse_args()
    quiet = bool(args.quiet)

    py = args.py
    data_dir = Path(args.data_dir)
    rep_dir = Path(args.reports_dir)
    rep_dir.mkdir(parents=True, exist_ok=True)

    symbols = parse_symbols(args.symbols)
    if not symbols:
        raise SystemExit("No valid symbols provided")

    fetch_mode: FetchMode = args.fetch_mode
    stamp = datetime.now().strftime("%Y%m%d")

    summary_rows: list[list[str]] = []

    produced_reports: list[Path] = []
    produced_allocs: list[Path] = []

    for sym in symbols:
        inp = data_dir / f"{sym}.csv"
        signals = data_dir / f"phase5_signals_{sym}.csv"
        trades = data_dir / f"phase6_trades_{sym}_v15.csv"
        equity = data_dir / f"phase6_equity_{sym}_v15.csv"
        report = rep_dir / f"weekly_{sym}.md"
        alloc = rep_dir / f"allocation_final_{sym}.json"

        ok, msg = maybe_fetch(py, sym, inp, fetch_mode, int(args.min_rows), quiet)
        if not ok:
            print(f"[SKIP] {sym} data not ready: {inp} ({msg})")
            summary_rows.append([sym, "", "SKIP", "", "", "", "", "", "", ""])
            continue

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
            ],
            quiet=quiet,
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
            ],
            quiet=quiet,
        )

        # Weekly (pass data_csv for last_close fallback)
        run(
            [
                py,
                r".\scripts\weekly_runbook.py",
                "--symbol",
                sym,
                "--equity_csv",
                str(equity),
                "--trades_csv",
                str(trades),
                "--out_report",
                str(report),
                "--out_allocation",
                str(alloc),
                "--trades_tail",
                str(int(args.trades_tail)),
                "--data_csv",
                str(inp),
            ],
            quiet=quiet,
        )

        produced_reports.append(report)
        produced_allocs.append(alloc)

        a = read_allocation(alloc)
        holding = int(a.get("holding", 0))
        asof = str(a.get("asof_date", ""))
        last_close = a.get("last_close_inferred", None)
        stop = a.get("stop_level", None)
        trail = a.get("trail_level", None)
        stop_buf = a.get("stop_buffer_pct", None)
        trail_buf = a.get("trail_buffer_pct", None)

        def fmt_num(x) -> str:
            if x is None:
                return ""
            try:
                xf = float(x)
                if xf != xf or xf <= 0:
                    return ""
                return f"{xf:.2f}"
            except Exception:
                return ""

        def fmt_pct(x) -> str:
            if x is None:
                return ""
            try:
                xf = float(x)
                if xf != xf:
                    return ""
                return f"{xf*100.0:.2f}%"
            except Exception:
                return ""

        summary_rows.append(
            [
                sym,
                asof,
                "1" if holding else "0",
                fmt_num(last_close),
                fmt_num(stop),
                fmt_num(trail),
                fmt_pct(stop_buf),
                fmt_pct(trail_buf),
                str(report.as_posix()),
                str(alloc.as_posix()),
            ]
        )

    # Summary report
    summary_path = rep_dir / "weekly_summary.md"
    hdr = ["symbol", "asof", "holding", "last_close", "stop", "trail", "stop_buf", "trail_buf", "report", "allocation"]

    lines: list[str] = ["# Weekly Summary", ""]
    if not summary_rows:
        lines.append("- (no outputs; check symbols and data fetch)")
    else:
        lines.append(md_row(hdr))
        lines.append(md_row(["-" * len(h) for h in hdr]))
        for r in summary_rows:
            if len(r) < len(hdr):
                r = r + [""] * (len(hdr) - len(r))
            lines.append(md_row(r[: len(hdr)]))

    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"OK weekly_pipeline wrote summary: {summary_path}")

    # Snapshot copies (dated)
    if bool(args.snapshot_reports):
        dated_summary = rep_dir / f"weekly_summary_{stamp}.md"
        safe_copy(summary_path, dated_summary)

        for rp in produced_reports:
            safe_copy(rp, rp.with_name(rp.stem + f"_{stamp}" + rp.suffix))
        for ap in produced_allocs:
            safe_copy(ap, ap.with_name(ap.stem + f"_{stamp}" + ap.suffix))

        print(f"OK weekly_pipeline snapshotted reports with date stamp={stamp}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
