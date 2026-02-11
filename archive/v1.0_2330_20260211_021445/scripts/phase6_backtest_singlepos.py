from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import pandas as pd


@dataclass
class Fees:
    buy_fee_rate: float = 0.001425
    sell_fee_rate: float = 0.001425
    sell_tax_rate: float = 0.003
    slippage_bps: float = 0.0


TRADE_COLUMNS = [
    "entry_date",
    "exit_date",
    "entry_price",
    "exit_price",
    "shares",
    "gross_pnl",
    "net_cashflow_exit",
    "return_pct",
    "exit_reason",
]


def apply_slippage(price: float, bps: float, side: str) -> float:
    if bps <= 0:
        return price
    rate = bps / 10000.0
    if side == "buy":
        return price * (1 + rate)
    return price * (1 - rate)


def load_signals(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [str(c).strip().lower() for c in df.columns]

    need = {"date", "close", "sig_buy", "sig_sell"}
    missing = need - set(df.columns)
    if missing:
        raise ValueError(f"Missing columns: {sorted(missing)} in {path}")

    df["date"] = pd.to_datetime(df["date"], errors="coerce")
    df = df.dropna(subset=["date", "close"]).copy()
    df = df.sort_values("date").reset_index(drop=True)

    df["sig_buy"] = df["sig_buy"].astype(bool)
    df["sig_sell"] = df["sig_sell"].astype(bool)

    # optional columns from Phase5
    for c in ["sma_fast", "sma_slow", "trend_gate", "rsi"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    if "trend_gate" in df.columns:
        df["trend_gate"] = df["trend_gate"].astype(bool)

    return df


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", default="data/phase5_signals_2330.csv")
    ap.add_argument("--out_trades", default="data/phase6_trades_2330.csv")
    ap.add_argument("--out_equity", default="data/phase6_equity_2330.csv")

    ap.add_argument("--initial_cash", type=float, default=1_000_000.0)
    ap.add_argument("--cooldown_bars", type=int, default=3)

    ap.add_argument("--buy_fee_rate", type=float, default=0.001425)
    ap.add_argument("--sell_fee_rate", type=float, default=0.001425)
    ap.add_argument("--sell_tax_rate", type=float, default=0.003)
    ap.add_argument("--slippage_bps", type=float, default=0.0)

    ap.add_argument("--stop_loss", type=float, default=0.0)
    ap.add_argument("--take_profit", type=float, default=0.0)

    # NEW: exit mode
    # rsi  = use sig_sell only (old)
    # trend= exit when close < sma_fast (or sma_slow if chosen)
    # both = either rsi sell signal OR trend break
    ap.add_argument("--exit_mode", choices=["rsi", "trend", "both"], default="both")
    ap.add_argument("--trend_exit", choices=["sma_fast", "sma_slow"], default="sma_fast")

    args = ap.parse_args()

    inp = Path(args.inp)
    out_trades = Path(args.out_trades)
    out_equity = Path(args.out_equity)
    out_trades.parent.mkdir(parents=True, exist_ok=True)
    out_equity.parent.mkdir(parents=True, exist_ok=True)

    df = load_signals(inp)

    fees = Fees(
        buy_fee_rate=args.buy_fee_rate,
        sell_fee_rate=args.sell_fee_rate,
        sell_tax_rate=args.sell_tax_rate,
        slippage_bps=args.slippage_bps,
    )

    cash = float(args.initial_cash)
    shares = 0
    entry_price = None
    entry_date = None
    last_exit_index = -10**9

    trades: list[dict] = []
    equity_rows: list[dict] = []

    for i, row in df.iterrows():
        date = row["date"]
        close = float(row["close"])
        buy_sig = bool(row["sig_buy"])
        sell_sig = bool(row["sig_sell"])

        # Trend exit condition (if SMA column exists)
        trend_exit = False
        trend_line = None
        if args.trend_exit in df.columns:
            trend_line = row.get(args.trend_exit)
            if pd.notna(trend_line):
                trend_exit = close < float(trend_line)

        # Risk exits
        do_exit = False
        exit_reason = ""
        if shares > 0 and entry_price is not None:
            ret = (close - entry_price) / entry_price
            if args.stop_loss > 0 and ret <= -abs(args.stop_loss):
                do_exit = True
                exit_reason = "stop_loss"
            elif args.take_profit > 0 and ret >= abs(args.take_profit):
                do_exit = True
                exit_reason = "take_profit"

        # Combine exit modes
        exit_by_rsi = sell_sig
        exit_by_trend = trend_exit

        want_exit = False
        if args.exit_mode == "rsi":
            want_exit = exit_by_rsi or do_exit
        elif args.exit_mode == "trend":
            want_exit = exit_by_trend or do_exit
        else:  # both
            want_exit = exit_by_rsi or exit_by_trend or do_exit

        if shares > 0 and want_exit:
            px = apply_slippage(close, fees.slippage_bps, "sell")
            gross = shares * px
            fee = gross * fees.sell_fee_rate
            tax = gross * fees.sell_tax_rate
            net = gross - fee - tax
            cash += net

            trade_ret = (px - entry_price) / entry_price if entry_price else 0.0

            if exit_reason:
                reason = exit_reason
            elif exit_by_trend and exit_by_rsi:
                reason = "trend+signal"
            elif exit_by_trend:
                reason = "trend_break"
            elif exit_by_rsi:
                reason = "signal"
            else:
                reason = "exit"

            trades.append(
                {
                    "entry_date": entry_date.strftime("%Y-%m-%d") if entry_date is not None else "",
                    "exit_date": date.strftime("%Y-%m-%d"),
                    "entry_price": float(entry_price) if entry_price is not None else 0.0,
                    "exit_price": float(px),
                    "shares": int(shares),
                    "gross_pnl": float((px - entry_price) * shares) if entry_price else 0.0,
                    "net_cashflow_exit": float(net),
                    "return_pct": float(trade_ret),
                    "exit_reason": reason,
                }
            )

            shares = 0
            entry_price = None
            entry_date = None
            last_exit_index = i

        # entry (single position, no pyramiding)
        can_enter = (shares == 0) and buy_sig and ((i - last_exit_index) >= args.cooldown_bars)
        if can_enter:
            px = apply_slippage(close, fees.slippage_bps, "buy")
            denom = px * (1 + fees.buy_fee_rate)
            buy_shares = int(cash // denom)
            if buy_shares > 0:
                cost_gross = buy_shares * px
                fee = cost_gross * fees.buy_fee_rate
                total = cost_gross + fee
                cash -= total
                shares = buy_shares
                entry_price = px
                entry_date = date

        position_value = shares * close
        equity = cash + position_value
        equity_rows.append(
            {
                "date": date.strftime("%Y-%m-%d"),
                "close": close,
                "cash": cash,
                "shares": int(shares),
                "position_value": position_value,
                "equity": equity,
            }
        )

    eq = pd.DataFrame(equity_rows)
    eq.to_csv(out_equity, index=False, encoding="utf-8")

    if trades:
        tr = pd.DataFrame(trades)[TRADE_COLUMNS]
    else:
        tr = pd.DataFrame(columns=TRADE_COLUMNS)
    tr.to_csv(out_trades, index=False, encoding="utf-8")

    print(f"OK Phase6 wrote: {out_equity} rows={len(eq)}")
    print(
        f"OK Phase6 wrote: {out_trades} trades={len(tr)} cooldown_bars={args.cooldown_bars} "
        f"single_position=True exit_mode={args.exit_mode} trend_exit={args.trend_exit}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
