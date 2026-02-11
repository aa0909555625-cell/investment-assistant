from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Literal

import pandas as pd

StopMode = Literal["close", "low"]
TrailingMode = Literal["close", "low"]
ExitMode = Literal["both", "trend", "signal"]
TrendExit = Literal["sma_fast", "sma_slow"]


@dataclass
class Position:
    entry_date: str
    entry_price: float
    shares: int
    entry_cash_used: float
    max_fav_ref: float
    stop_level: float
    trail_level: float


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out_trades", required=True)
    ap.add_argument("--out_equity", required=True)

    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--cooldown_bars", type=int, default=0)

    ap.add_argument("--slippage_bps", type=float, default=0.0)

    ap.add_argument("--stop_loss", type=float, default=0.0)
    ap.add_argument("--stop_loss_mode", choices=["close", "low"], default="close")

    ap.add_argument("--trailing_stop", type=float, default=0.0)
    ap.add_argument("--trailing_mode", choices=["close", "low"], default="close")

    ap.add_argument("--take_profit", type=float, default=0.0)

    ap.add_argument("--exit_mode", choices=["both", "trend", "signal"], default="both")
    ap.add_argument("--trend_exit", choices=["sma_fast", "sma_slow"], default="sma_fast")

    ap.add_argument("--buy_fee", type=float, default=0.001425)
    ap.add_argument("--sell_fee", type=float, default=0.001425)
    ap.add_argument("--sell_tax", type=float, default=0.003)

    # Debug
    ap.add_argument("--debug_signal_scan", action="store_true", help="Print signal candidate counts")
    return ap.parse_args()


def _to_float(x) -> float:
    try:
        return float(x)
    except Exception:
        return float("nan")


def _to_bool(v) -> bool:
    """
    Robust bool coercion:
    - True/False, 1/0
    - "true"/"false", "1"/"0", "yes"/"no"
    - empty/NaN -> False
    """
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    try:
        if pd.isna(v):
            return False
    except Exception:
        pass
    if isinstance(v, (int, float)):
        return float(v) != 0.0
    s = str(v).strip().lower()
    if s in ("", "nan", "none", "null"):
        return False
    if s in ("true", "t", "yes", "y", "1"):
        return True
    if s in ("false", "f", "no", "n", "0"):
        return False
    # fallback: non-empty string treated as True
    return True


def _truthy_count(series: pd.Series) -> int:
    try:
        return int(series.map(_to_bool).sum())
    except Exception:
        # best effort fallback
        c = 0
        for x in series.tolist():
            if _to_bool(x):
                c += 1
        return c


def _pick_best_signal_col(df: pd.DataFrame, canonical: str, candidates: list[str], debug: bool = False) -> str:
    """
    Pick the best signal column among candidates based on truthy count.
    Priority:
      1) existing candidate with highest truthy count
      2) if all candidates exist but all 0 -> prefer canonical if exists, else first existing
      3) if none exist -> create canonical all-False
    """
    existing = [c for c in candidates if c in df.columns]

    stats: list[tuple[str, int]] = []
    for c in existing:
        stats.append((c, _truthy_count(df[c])))

    if debug:
        if stats:
            print(f"[SignalScan] {canonical} candidates truthy counts:")
            for name, cnt in sorted(stats, key=lambda x: (-x[1], x[0])):
                print(f"  - {name}: {cnt}")
        else:
            print(f"[SignalScan] {canonical} candidates: none found in columns")

    if not existing:
        df[canonical] = False
        return canonical

    # choose max truthy
    best_name, best_cnt = sorted(stats, key=lambda x: (-x[1], x[0]))[0]

    # if all zero, keep canonical if it exists, otherwise keep best_name (first by tie-break)
    if best_cnt == 0:
        if canonical in df.columns:
            return canonical
        return best_name

    return best_name


def main() -> int:
    args = parse_args()

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Input not found: {inp}")

    df = pd.read_csv(inp)

    need_cols = {"date", "open", "high", "low", "close"}
    if not need_cols.issubset(set(df.columns)):
        raise SystemExit(f"Missing OHLC columns in input. Need={sorted(need_cols)} got={df.columns.tolist()}")

    debug_scan = bool(getattr(args, "debug_signal_scan", False))

    # === Signal column auto-alignment (Phase5 may output different names) ===
    buy_col = _pick_best_signal_col(
        df,
        canonical="buy_signal",
        candidates=["buy_signal", "buy", "signal_buy", "entry_signal", "enter", "long_entry", "entry", "buySignal"],
        debug=debug_scan,
    )
    sell_col = _pick_best_signal_col(
        df,
        canonical="sell_signal",
        candidates=["sell_signal", "sell", "signal_sell", "exit_signal", "exit", "long_exit", "sellSignal"],
        debug=debug_scan,
    )
    trend_col = _pick_best_signal_col(
        df,
        canonical="trend_break",
        candidates=["trend_break", "trend_exit", "trend_fail", "trend_down", "gate_trend_break", "trendBreak"],
        debug=debug_scan,
    )

    cash = float(args.initial_cash)
    pos: Optional[Position] = None
    cooldown = 0

    trades: list[dict] = []
    equity_rows: list[dict] = []

    stop_loss = float(args.stop_loss)
    trailing_stop = float(args.trailing_stop)
    stop_mode: StopMode = args.stop_loss_mode
    trail_mode: TrailingMode = args.trailing_mode

    buy_fee = float(args.buy_fee)
    sell_fee = float(args.sell_fee)
    sell_tax = float(args.sell_tax)

    slippage = float(args.slippage_bps) / 10000.0
    take_profit = float(args.take_profit)

    exit_mode: ExitMode = args.exit_mode
    trend_exit: TrendExit = args.trend_exit  # reserved, kept for interface compatibility

    def mark_price_for_stop(irow: pd.Series) -> float:
        return _to_float(irow["low"] if stop_mode == "low" else irow["close"])

    def mark_price_for_trail(irow: pd.Series) -> float:
        return _to_float(irow["low"] if trail_mode == "low" else irow["close"])

    def update_risk_lines(irow: pd.Series) -> None:
        nonlocal pos
        if not pos:
            return

        if stop_loss > 0:
            pos.stop_level = pos.entry_price * (1.0 - stop_loss)
        else:
            pos.stop_level = 0.0

        if trailing_stop > 0:
            ref = mark_price_for_trail(irow)
            if pd.notna(ref):
                pos.max_fav_ref = max(pos.max_fav_ref, float(ref))
            pos.trail_level = pos.max_fav_ref * (1.0 - trailing_stop)
        else:
            pos.trail_level = 0.0

    def should_exit(irow: pd.Series) -> tuple[bool, str]:
        nonlocal pos
        if not pos:
            return False, ""

        if stop_loss > 0 and pos.stop_level > 0:
            m = mark_price_for_stop(irow)
            if pd.notna(m) and float(m) <= pos.stop_level:
                return True, f"stop_loss_{stop_mode}"

        if trailing_stop > 0 and pos.trail_level > 0:
            m = mark_price_for_trail(irow)
            if pd.notna(m) and float(m) <= pos.trail_level:
                return True, f"trailing_stop_{trail_mode}"

        if take_profit > 0:
            cp = _to_float(irow["close"])
            if pd.notna(cp) and cp >= pos.entry_price * (1.0 + take_profit):
                return True, "take_profit"

        if exit_mode in ("both", "trend") and _to_bool(irow.get(trend_col, False)):
            return True, "trend_break"

        if exit_mode in ("both", "signal") and _to_bool(irow.get(sell_col, False)):
            return True, "signal"

        return False, ""

    def do_buy(irow: pd.Series) -> None:
        nonlocal cash, pos, cooldown
        px = _to_float(irow["close"])
        if pd.isna(px) or px <= 0:
            return
        px_exec = px * (1.0 + slippage)

        shares = int(cash / (px_exec * (1.0 + buy_fee)))
        if shares <= 0:
            return

        cost = shares * px_exec * (1.0 + buy_fee)
        cash -= cost

        entry_date = str(irow["date"])
        trail_ref = mark_price_for_trail(irow)
        if pd.isna(trail_ref) or trail_ref <= 0:
            trail_ref = px_exec

        pos = Position(
            entry_date=entry_date,
            entry_price=float(px_exec),
            shares=shares,
            entry_cash_used=float(cost),
            max_fav_ref=float(trail_ref),
            stop_level=0.0,
            trail_level=0.0,
        )
        update_risk_lines(irow)
        cooldown = 0

    def do_sell(irow: pd.Series, reason: str) -> None:
        nonlocal cash, pos, cooldown
        if not pos:
            return
        px = _to_float(irow["close"])
        if pd.isna(px) or px <= 0:
            return
        px_exec = px * (1.0 - slippage)

        gross = pos.shares * px_exec
        fees = gross * (sell_fee + sell_tax)
        net = gross - fees
        cash += net

        ret = (px_exec / pos.entry_price) - 1.0

        trades.append(
            {
                "entry_date": pos.entry_date,
                "exit_date": str(irow["date"]),
                "entry_price": round(pos.entry_price, 6),
                "exit_price": round(px_exec, 6),
                "shares": int(pos.shares),
                "gross_pnl": round((px_exec - pos.entry_price) * pos.shares, 6),
                "net_cashflow_exit": round(cash, 6),
                "return_pct": ret,
                "exit_reason": reason,
            }
        )

        pos = None
        cooldown = int(args.cooldown_bars)

    for _, r in df.iterrows():
        date = str(r["date"])
        close = _to_float(r["close"])

        exit_reason_today = ""

        if cooldown > 0 and pos is None:
            cooldown -= 1

        if pos is not None:
            update_risk_lines(r)
            do_exit, reason = should_exit(r)
            if do_exit:
                exit_reason_today = reason
                do_sell(r, reason)

        if pos is None and cooldown == 0:
            if _to_bool(r.get(buy_col, False)):
                do_buy(r)

        equity = cash
        position_flag = 0
        entry_price = 0.0
        stop_level = 0.0
        trail_level = 0.0
        shares = 0

        if pos is not None and pd.notna(close):
            equity = cash + pos.shares * float(close)
            position_flag = 1
            shares = int(pos.shares)
            entry_price = float(pos.entry_price)
            stop_level = float(pos.stop_level)
            trail_level = float(pos.trail_level)

        equity_rows.append(
            {
                "date": date,
                "equity": round(float(equity), 6),
                "cash": round(float(cash), 6),
                "position": position_flag,
                "shares": shares,
                "entry_price": round(entry_price, 6),
                "stop_level": round(stop_level, 6),
                "trail_level": round(trail_level, 6),
                "exit_reason_today": exit_reason_today,
            }
        )

    out_trades = Path(args.out_trades)
    out_equity = Path(args.out_equity)
    out_trades.parent.mkdir(parents=True, exist_ok=True)
    out_equity.parent.mkdir(parents=True, exist_ok=True)

    pd.DataFrame(trades).to_csv(out_trades, index=False, encoding="utf-8")
    pd.DataFrame(equity_rows).to_csv(out_equity, index=False, encoding="utf-8")

    print(f"OK Phase6 wrote: {out_equity} rows={len(equity_rows)}")
    print(
        f"OK Phase6 wrote: {out_trades} trades={len(trades)} cooldown_bars={args.cooldown_bars} "
        f"single_position=True exit_mode={exit_mode} trend_exit={trend_exit} "
        f"stop_loss={stop_loss} stop_loss_mode={stop_mode} trailing_stop={trailing_stop} trailing_mode={trail_mode} "
        f"slippage_bps={args.slippage_bps} (signal_cols: buy={buy_col}, sell={sell_col}, trend={trend_col})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
