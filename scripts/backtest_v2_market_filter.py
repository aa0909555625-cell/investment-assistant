# -*- coding: utf-8 -*-
"""
Backtest v2 with Market Filter (TAIEX via Stooq).

Inputs (default conventions):
- Symbol OHLC: data/<symbol>.csv  (Date,Open,High,Low,Close,Volume) OR (date,open,high,low,close,volume)
- Signals:     data/phase5_signals_<symbol>.csv with at least columns: date, buy_signal, sell_signal
- Market:      data/market_taiex_stooq.csv from scripts/data_fetch_taiex_stooq.py

Logic:
- Only allow ENTRY if buy_signal==1 AND MarketOK==True on that date
- Exit if sell_signal==1 (or end of data)
- Single position, long-only (v2 baseline)
- MarketOK rule default: close > SMA200; optional trend confirm SMA50>SMA200

Outputs:
- data/backtest_v2_trades_<symbol>.csv
- data/backtest_v2_equity_<symbol>.csv
"""
from __future__ import annotations
import argparse
import os
from dataclasses import dataclass
from typing import Optional, Tuple

import pandas as pd


def _read_any_csv(path: str) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    df = pd.read_csv(path)
    if df.empty:
        raise RuntimeError(f"Empty CSV: {path}")
    # normalize headers to lower for detection
    lower = {c.lower(): c for c in df.columns}
    return df, lower


def _load_ohlc(symbol: str, path: str) -> pd.DataFrame:
    df, lower = _read_any_csv(path)
    # Accept Date or date
    date_col = lower.get("date")
    if not date_col:
        raise RuntimeError(f"OHLC missing Date column: {path} cols={list(df.columns)}")

    # Stooq uses Open/High/Low/Close (capitalized)
    def pick(name: str) -> str:
        c = lower.get(name)
        if not c:
            raise RuntimeError(f"OHLC missing {name}: {path} cols={list(df.columns)}")
        return c

    o = pick("open"); h = pick("high"); l = pick("low"); c = pick("close")
    v = lower.get("volume", None)

    out = pd.DataFrame({
        "date": pd.to_datetime(df[date_col]).dt.date.astype(str),
        "open": pd.to_numeric(df[o], errors="coerce"),
        "high": pd.to_numeric(df[h], errors="coerce"),
        "low": pd.to_numeric(df[l], errors="coerce"),
        "close": pd.to_numeric(df[c], errors="coerce"),
    })
    out["volume"] = pd.to_numeric(df[v], errors="coerce") if v else 0
    out = out.dropna(subset=["close"]).sort_values("date").reset_index(drop=True)
    return out


def _load_signals(symbol: str, path: str) -> pd.DataFrame:
    df, lower = _read_any_csv(path)
    date_col = lower.get("date")
    if not date_col:
        raise RuntimeError(f"Signals missing date: {path} cols={list(df.columns)}")

    buy_col = lower.get("buy_signal")
    sell_col = lower.get("sell_signal")
    if not buy_col or not sell_col:
        raise RuntimeError(f"Signals need buy_signal & sell_signal: {path} cols={list(df.columns)}")

    out = pd.DataFrame({
        "date": pd.to_datetime(df[date_col]).dt.date.astype(str),
        "buy_signal": pd.to_numeric(df[buy_col], errors="coerce").fillna(0).astype(int),
        "sell_signal": pd.to_numeric(df[sell_col], errors="coerce").fillna(0).astype(int),
    }).sort_values("date").reset_index(drop=True)
    return out


def _load_market(path: str, sma_fast: int = 50, sma_slow: int = 200, require_trend_confirm: bool = False) -> pd.DataFrame:
    df, lower = _read_any_csv(path)
    date_col = lower.get("date")
    close_col = lower.get("close")
    if not date_col or not close_col:
        raise RuntimeError(f"Market CSV must have date,close: {path} cols={list(df.columns)}")

    out = pd.DataFrame({
        "date": pd.to_datetime(df[date_col]).dt.date.astype(str),
        "m_close": pd.to_numeric(df[close_col], errors="coerce"),
    }).dropna(subset=["m_close"]).sort_values("date").reset_index(drop=True)

    out["sma_fast"] = out["m_close"].rolling(sma_fast, min_periods=sma_fast).mean()
    out["sma_slow"] = out["m_close"].rolling(sma_slow, min_periods=sma_slow).mean()

    ok = out["m_close"] > out["sma_slow"]
    if require_trend_confirm:
        ok = ok & (out["sma_fast"] > out["sma_slow"])
    out["market_ok"] = ok.fillna(False)
    return out[["date", "m_close", "sma_fast", "sma_slow", "market_ok"]]


@dataclass
class Trade:
    entry_date: str
    entry_price: float
    exit_date: str
    exit_price: float
    pnl: float
    pnl_pct: float
    reason: str


def run_backtest(
    ohlc: pd.DataFrame,
    signals: pd.DataFrame,
    market: pd.DataFrame,
    capital: float = 300000.0,
    single_position: bool = True,
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    # merge all on date
    df = ohlc.merge(signals, on="date", how="left").merge(market[["date", "market_ok"]], on="date", how="left")
    df["buy_signal"] = df["buy_signal"].fillna(0).astype(int)
    df["sell_signal"] = df["sell_signal"].fillna(0).astype(int)
    df["market_ok"] = df["market_ok"].fillna(False).astype(bool)

    in_pos = False
    entry_price = 0.0
    entry_date = ""
    shares = 0.0
    cash = float(capital)

    trades: list[Trade] = []
    equity_rows = []

    for i, r in df.iterrows():
        date = r["date"]
        close = float(r["close"])

        # ENTRY: only if market_ok and buy_signal and not in position
        if (not in_pos) and (r["buy_signal"] == 1) and (r["market_ok"] is True):
            # all-in baseline
            shares = cash / close if close > 0 else 0.0
            entry_price = close
            entry_date = date
            cash = cash - shares * close
            in_pos = True

        # EXIT: sell_signal -> exit
        if in_pos and (r["sell_signal"] == 1):
            exit_price = close
            exit_date = date
            proceeds = shares * exit_price
            cash = cash + proceeds
            pnl = (exit_price - entry_price) * shares
            pnl_pct = (exit_price / entry_price - 1.0) if entry_price > 0 else 0.0
            trades.append(Trade(entry_date, entry_price, exit_date, exit_price, pnl, pnl_pct, "signal"))
            shares = 0.0
            in_pos = False

        equity = cash + (shares * close if in_pos else 0.0)
        equity_rows.append({
            "date": date,
            "equity": equity,
            "cash": cash,
            "position": 1 if in_pos else 0,
            "shares": shares,
            "close": close,
            "market_ok": bool(r["market_ok"]),
            "buy_signal": int(r["buy_signal"]),
            "sell_signal": int(r["sell_signal"]),
        })

    # force exit at end
    if in_pos:
        last = df.iloc[-1]
        exit_price = float(last["close"])
        exit_date = str(last["date"])
        proceeds = shares * exit_price
        cash = cash + proceeds
        pnl = (exit_price - entry_price) * shares
        pnl_pct = (exit_price / entry_price - 1.0) if entry_price > 0 else 0.0
        trades.append(Trade(entry_date, entry_price, exit_date, exit_price, pnl, pnl_pct, "eod"))
        in_pos = False
        shares = 0.0

    trades_df = pd.DataFrame([t.__dict__ for t in trades])
    equity_df = pd.DataFrame(equity_rows)
    return trades_df, equity_df


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", required=True, help="e.g. 2330 or 0050")
    ap.add_argument("--capital", type=float, default=300000.0)
    ap.add_argument("--ohlc", default="", help="default data/<symbol>.csv")
    ap.add_argument("--signals", default="", help="default data/phase5_signals_<symbol>.csv")
    ap.add_argument("--market", default="data/market_taiex_stooq.csv")
    ap.add_argument("--require_trend_confirm", action="store_true", help="also require SMA50>SMA200")
    ap.add_argument("--out_trades", default="", help="default data/backtest_v2_trades_<symbol>.csv")
    ap.add_argument("--out_equity", default="", help="default data/backtest_v2_equity_<symbol>.csv")
    args = ap.parse_args()

    sym = args.symbol.strip()
    ohlc_path = args.ohlc.strip() or f"data/{sym}.csv"
    sig_path = args.signals.strip() or f"data/phase5_signals_{sym}.csv"
    mkt_path = args.market.strip()

    out_trades = args.out_trades.strip() or f"data/backtest_v2_trades_{sym}.csv"
    out_equity = args.out_equity.strip() or f"data/backtest_v2_equity_{sym}.csv"
    os.makedirs(os.path.dirname(os.path.abspath(out_trades)), exist_ok=True)

    ohlc = _load_ohlc(sym, ohlc_path)
    sig = _load_signals(sym, sig_path)
    mkt = _load_market(mkt_path, require_trend_confirm=args.require_trend_confirm)

    trades, equity = run_backtest(ohlc, sig, mkt, capital=args.capital)

    trades.to_csv(out_trades, index=False, encoding="utf-8")
    equity.to_csv(out_equity, index=False, encoding="utf-8")

    # quick summary
    if len(equity) > 0:
        start_eq = float(equity["equity"].iloc[0])
        end_eq = float(equity["equity"].iloc[-1])
        ret = (end_eq / start_eq - 1.0) if start_eq > 0 else 0.0
    else:
        end_eq = args.capital
        ret = 0.0

    print(f"OK: {sym} backtest_v2 done")
    print(f"  trades={len(trades)} end_equity={end_eq:.2f} return={ret*100:.2f}%")
    print(f"  wrote: {out_trades}")
    print(f"  wrote: {out_equity}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())