from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pandas as pd


@dataclass
class Snapshot:
    asof_date: str
    symbol: str
    holding: int
    shares: int
    entry_price: float
    stop_level: float
    trail_level: float
    last_close_inferred: Optional[float]
    stop_buffer_pct: Optional[float]
    trail_buffer_pct: Optional[float]
    exit_reason_today_last: str
    cash: float
    equity: float


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Weekly report generator (no tabulate dependency)")
    ap.add_argument("--symbol", required=True)
    ap.add_argument("--equity_csv", required=True)
    ap.add_argument("--trades_csv", required=True)
    ap.add_argument("--out_report", required=True)
    ap.add_argument("--out_allocation", required=True)
    ap.add_argument("--trades_tail", type=int, default=10)
    ap.add_argument("--data_csv", default="", help="Optional original data csv (data/{symbol}.csv) for last_close fallback")
    return ap.parse_args()


def _to_float(x) -> float:
    try:
        return float(x)
    except Exception:
        return float("nan")


def _fmt_pct(x: Optional[float]) -> str:
    if x is None or pd.isna(x):
        return "N/A"
    return f"{x*100.0:.2f}%"


def _fmt_num(x: Optional[float], d: int = 4) -> str:
    if x is None or pd.isna(x):
        return "N/A"
    return f"{float(x):.{d}f}"


def _path_posix(p: Path) -> str:
    # Stable path for markdown display, no backslash issues
    try:
        return p.as_posix()
    except Exception:
        return str(p).replace("\\", "/")


def _md_table(df: pd.DataFrame) -> list[str]:
    if df is None or df.empty:
        return ["(none)"]

    cols = df.columns.tolist()
    lines = []
    lines.append("| " + " | ".join(cols) + " |")
    lines.append("| " + " | ".join(["-" * len(str(c)) for c in cols]) + " |")
    for _, r in df.iterrows():
        vals = []
        for c in cols:
            vals.append(str(r.get(c, "")))
        lines.append("| " + " | ".join(vals) + " |")
    return lines


def infer_last_close(equity_df: pd.DataFrame, data_csv: Optional[Path], symbol: str) -> Optional[float]:
    # 1) Try implied close from last equity row if holding: close = (equity - cash) / shares
    if equity_df is not None and not equity_df.empty:
        last = equity_df.iloc[-1]
        shares = int(_to_float(last.get("shares", 0)))
        if shares > 0:
            cash = _to_float(last.get("cash", float("nan")))
            equity = _to_float(last.get("equity", float("nan")))
            if pd.notna(cash) and pd.notna(equity):
                close = (equity - cash) / float(shares)
                if pd.notna(close) and close > 0:
                    return float(close)

    # 2) data csv explicit fallback
    candidates = []
    if data_csv:
        candidates.append(data_csv)
    candidates.append(Path("data") / f"{symbol}.csv")

    for p in candidates:
        if not p or not p.exists():
            continue
        try:
            ddf = pd.read_csv(p)
            if "close" in ddf.columns and len(ddf) > 0:
                v = _to_float(ddf["close"].iloc[-1])
                if pd.notna(v) and v > 0:
                    return float(v)
        except Exception:
            pass

    return None


def compute_snapshot(symbol: str, equity_csv: Path, trades_csv: Path, data_csv: Optional[Path], trades_tail: int) -> tuple[Snapshot, pd.DataFrame]:
    eq = pd.read_csv(equity_csv)
    if eq.empty:
        raise SystemExit(f"Empty equity csv: {equity_csv}")

    last = eq.iloc[-1]
    asof = str(last.get("date", ""))

    holding = int(_to_float(last.get("position", 0)))
    shares = int(_to_float(last.get("shares", 0)))
    entry_price = _to_float(last.get("entry_price", float("nan")))
    stop_level = _to_float(last.get("stop_level", float("nan")))
    trail_level = _to_float(last.get("trail_level", float("nan")))
    cash = _to_float(last.get("cash", float("nan")))
    equity = _to_float(last.get("equity", float("nan")))
    exit_reason_today_last = str(last.get("exit_reason_today", ""))

    last_close = infer_last_close(eq, data_csv, symbol)

    stop_buf = None
    trail_buf = None
    if last_close is not None and pd.notna(last_close) and float(last_close) > 0:
        if pd.notna(stop_level) and float(stop_level) > 0:
            stop_buf = (float(last_close) / float(stop_level)) - 1.0
        if pd.notna(trail_level) and float(trail_level) > 0:
            trail_buf = (float(last_close) / float(trail_level)) - 1.0

    trades_tail_df = pd.DataFrame()
    if Path(trades_csv).exists():
        tdf = pd.read_csv(trades_csv)
        if not tdf.empty:
            if "return_pct" in tdf.columns:
                tdf["return_pct"] = tdf["return_pct"].apply(lambda x: f"{_to_float(x)*100.0:.2f}%")
            keep = [c for c in ["entry_date", "exit_date", "return_pct", "exit_reason"] if c in tdf.columns]
            trades_tail_df = tdf[keep].tail(int(trades_tail)).reset_index(drop=True)

    snap = Snapshot(
        asof_date=asof,
        symbol=symbol,
        holding=holding,
        shares=shares,
        entry_price=float(entry_price) if pd.notna(entry_price) else float("nan"),
        stop_level=float(stop_level) if pd.notna(stop_level) else float("nan"),
        trail_level=float(trail_level) if pd.notna(trail_level) else float("nan"),
        last_close_inferred=float(last_close) if last_close is not None else None,
        stop_buffer_pct=stop_buf,
        trail_buffer_pct=trail_buf,
        exit_reason_today_last=exit_reason_today_last,
        cash=float(cash) if pd.notna(cash) else float("nan"),
        equity=float(equity) if pd.notna(equity) else float("nan"),
    )
    return snap, trades_tail_df


def render_report(symbol: str, snap: Snapshot, trades_tail_df: pd.DataFrame, equity_csv: Path, trades_csv: Path) -> str:
    lines: list[str] = []
    lines.append(f"# Weekly Report - {symbol}")
    lines.append("")
    lines.append(f"- As of: **{snap.asof_date}**")
    lines.append(f"- Equity: **{snap.equity:,.2f}**" if pd.notna(snap.equity) else "- Equity: **N/A**")
    lines.append(f"- Cash: **{snap.cash:,.2f}**" if pd.notna(snap.cash) else "- Cash: **N/A**")
    lines.append(f"- Holding: **{snap.holding}**")
    lines.append(f"- Last close (inferred): **{_fmt_num(snap.last_close_inferred, 4)}**")
    lines.append(f"- Shares: **{snap.shares}**")
    lines.append(f"- Entry price: **{_fmt_num(snap.entry_price, 4)}**")
    lines.append(f"- Stop level: **{_fmt_num(snap.stop_level, 4)}**")
    lines.append(f"- Trail level: **{_fmt_num(snap.trail_level, 4)}**")
    lines.append(f"- Stop buffer: **{_fmt_pct(snap.stop_buffer_pct)}** (last_close vs stop_level)")
    lines.append(f"- Trail buffer: **{_fmt_pct(snap.trail_buffer_pct)}** (last_close vs trail_level)")
    lines.append("")
    lines.append("## Action (This Week)")
    if snap.holding == 1:
        lines.append("- Position is OPEN. Monitor stop / trailing line.")
        lines.append("- If price breaches stop/trail condition per Phase6 rules, system will exit on that bar.")
    else:
        lines.append("- No position. Wait for next buy signal (Phase5) and re-entry per Phase6 rules.")
    lines.append("")
    lines.append("## Recent Trades (tail)")
    lines.append("")
    lines.extend(_md_table(trades_tail_df))
    lines.append("")
    lines.append("## Artifacts")
    lines.append(f"- equity_csv: `{_path_posix(equity_csv)}`")
    lines.append(f"- trades_csv: `{_path_posix(trades_csv)}`")
    lines.append("")
    return "\n".join(lines)


def write_allocation(out_allocation: Path, snap: Snapshot) -> None:
    payload = {
        "asof_date": snap.asof_date,
        "symbol": snap.symbol,
        "holding": int(snap.holding),
        "shares": int(snap.shares),
        "entry_price": None if pd.isna(snap.entry_price) else float(snap.entry_price),
        "stop_level": None if pd.isna(snap.stop_level) else float(snap.stop_level),
        "trail_level": None if pd.isna(snap.trail_level) else float(snap.trail_level),
        "last_close_inferred": None if snap.last_close_inferred is None else float(snap.last_close_inferred),
        "stop_buffer_pct": None if snap.stop_buffer_pct is None else float(snap.stop_buffer_pct),
        "trail_buffer_pct": None if snap.trail_buffer_pct is None else float(snap.trail_buffer_pct),
        "exit_reason_today_last": snap.exit_reason_today_last,
        "cash": float(snap.cash) if pd.notna(snap.cash) else None,
        "equity": float(snap.equity) if pd.notna(snap.equity) else None,
    }
    out_allocation.parent.mkdir(parents=True, exist_ok=True)
    out_allocation.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    symbol = str(args.symbol)

    equity_csv = Path(args.equity_csv)
    trades_csv = Path(args.trades_csv)
    out_report = Path(args.out_report)
    out_allocation = Path(args.out_allocation)
    data_csv = Path(args.data_csv) if str(args.data_csv).strip() else None

    snap, trades_tail_df = compute_snapshot(symbol, equity_csv, trades_csv, data_csv, int(args.trades_tail))
    report_text = render_report(symbol, snap, trades_tail_df, equity_csv, trades_csv)

    out_report.parent.mkdir(parents=True, exist_ok=True)
    out_report.write_text(report_text, encoding="utf-8")

    write_allocation(out_allocation, snap)

    print(f"OK weekly_runbook wrote report: {out_report}")
    print(f"OK weekly_runbook wrote allocation_final: {out_allocation}")
    print(
        f"Snapshot: asof={snap.asof_date} holding={snap.holding} shares={snap.shares} "
        f"stop={_fmt_num(snap.stop_level)} trail={_fmt_num(snap.trail_level)} last_close={_fmt_num(snap.last_close_inferred)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
