from __future__ import annotations

import argparse
from pathlib import Path
import pandas as pd


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)

    avg_gain = gain.ewm(alpha=1 / period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False).mean()

    rs = avg_gain / avg_loss.replace(0, pd.NA)
    out = 100 - (100 / (1 + rs))
    return out.astype("float64")


def load_ohlcv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [str(c).strip().lower() for c in df.columns]
    need = {"date", "open", "high", "low", "close", "volume"}
    missing = need - set(df.columns)
    if missing:
        raise ValueError(f"Missing columns: {sorted(missing)} in {path}")

    df["date"] = pd.to_datetime(df["date"], errors="coerce")
    df = df.dropna(subset=["date", "close"]).copy()
    df = df.sort_values("date").reset_index(drop=True)
    return df


def main() -> int:
    ap = argparse.ArgumentParser()

    ap.add_argument("--in", dest="inp", default="data/2330.csv")
    ap.add_argument("--out", dest="outp", default="data/phase5_signals_2330.csv")

    # RSI timing
    ap.add_argument("--rsi_period", type=int, default=20)
    ap.add_argument("--buy_rsi", type=float, default=40.0)
    ap.add_argument("--sell_rsi", type=float, default=60.0)

    # Trend gate (default: SMA50 > SMA200 AND close > SMA200)
    ap.add_argument("--sma_fast", type=int, default=50)
    ap.add_argument("--sma_slow", type=int, default=200)
    ap.add_argument("--trend_mode", choices=["none", "sma_cross", "close_above_slow", "both"], default="both")

    args = ap.parse_args()

    inp = Path(args.inp)
    outp = Path(args.outp)
    outp.parent.mkdir(parents=True, exist_ok=True)

    df = load_ohlcv(inp)

    # indicators
    df["sma_fast"] = df["close"].rolling(args.sma_fast, min_periods=args.sma_fast).mean()
    df["sma_slow"] = df["close"].rolling(args.sma_slow, min_periods=args.sma_slow).mean()
    df["rsi"] = rsi(df["close"], period=args.rsi_period)
    df["rsi_prev"] = df["rsi"].shift(1)

    # trend gate
    if args.trend_mode == "none":
        gate = pd.Series(True, index=df.index)
    elif args.trend_mode == "sma_cross":
        gate = (df["sma_fast"] > df["sma_slow"])
    elif args.trend_mode == "close_above_slow":
        gate = (df["close"] > df["sma_slow"])
    else:  # both
        gate = (df["sma_fast"] > df["sma_slow"]) & (df["close"] > df["sma_slow"])

    # NOTE:
    # BUY: RSI crosses up above buy_rsi AND trend gate is true
    # SELL: RSI crosses down below sell_rsi (no trend gate; allow exit anytime)
    df["sig_buy"] = gate & (df["rsi_prev"] < args.buy_rsi) & (df["rsi"] >= args.buy_rsi)
    df["sig_sell"] = (df["rsi_prev"] > args.sell_rsi) & (df["rsi"] <= args.sell_rsi)

    df["trend_gate"] = gate.fillna(False)

    # stringify date
    df["date"] = df["date"].dt.strftime("%Y-%m-%d")

    cols = [
        "date", "open", "high", "low", "close", "volume",
        "sma_fast", "sma_slow", "trend_gate",
        "rsi", "sig_buy", "sig_sell",
    ]
    df[cols].to_csv(outp, index=False, encoding="utf-8")

    buy_n = int(df["sig_buy"].sum())
    sell_n = int(df["sig_sell"].sum())
    gate_n = int(df["trend_gate"].sum())

    print(
        f"OK Phase5 wrote: {outp} rows={len(df)} "
        f"gateTrueBars={gate_n} buySignals={buy_n} sellSignals={sell_n} "
        f"RSI(p={args.rsi_period}) buy={args.buy_rsi} sell={args.sell_rsi} "
        f"trend={args.trend_mode} SMA({args.sma_fast},{args.sma_slow})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
