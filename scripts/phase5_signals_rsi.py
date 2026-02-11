from __future__ import annotations

import argparse
from pathlib import Path
import pandas as pd


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)

    ap.add_argument("--rsi_period", type=int, default=14)
    ap.add_argument("--buy_rsi", type=float, default=50.0)
    ap.add_argument("--sell_rsi", type=float, default=60.0)

    ap.add_argument("--sma_fast", type=int, default=50)
    ap.add_argument("--sma_slow", type=int, default=200)

    # trend gating: fast / slow / both
    ap.add_argument("--trend", choices=["fast", "slow", "both"], default="both")

    return ap.parse_args()


def rsi(series: pd.Series, period: int) -> pd.Series:
    # Wilder's RSI
    delta = series.diff()
    gain = delta.clip(lower=0.0)
    loss = (-delta).clip(lower=0.0)

    # Wilder smoothing = EMA alpha=1/period with adjust=False
    avg_gain = gain.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    avg_loss = loss.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()

    rs = avg_gain / avg_loss.replace(0.0, pd.NA)
    out = 100.0 - (100.0 / (1.0 + rs))
    return out


def main() -> int:
    args = parse_args()

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Input not found: {inp}")

    df = pd.read_csv(inp)

    need_cols = {"date", "open", "high", "low", "close"}
    if not need_cols.issubset(set(df.columns)):
        raise SystemExit(f"Missing OHLC columns. Need={sorted(need_cols)} got={df.columns.tolist()}")

    # normalize types
    df["close"] = pd.to_numeric(df["close"], errors="coerce")

    sma_fast_n = int(args.sma_fast)
    sma_slow_n = int(args.sma_slow)

    df["sma_fast"] = df["close"].rolling(sma_fast_n, min_periods=sma_fast_n).mean()
    df["sma_slow"] = df["close"].rolling(sma_slow_n, min_periods=sma_slow_n).mean()

    df["rsi"] = rsi(df["close"], int(args.rsi_period))

    # === Trend gate ===
    # gate_trend_ok: used to allow entries only when in up-trend
    trend_mode = args.trend
    if trend_mode == "fast":
        df["gate_trend_ok"] = (df["close"] >= df["sma_fast"])
    elif trend_mode == "slow":
        df["gate_trend_ok"] = (df["close"] >= df["sma_slow"])
    else:
        df["gate_trend_ok"] = (df["close"] >= df["sma_fast"]) & (df["close"] >= df["sma_slow"])

    # trend_break: used by Phase6 exit_mode=trend
    # default: break if close < sma_fast (you pass trend_exit=sma_fast in Phase6)
    df["trend_break"] = (df["close"] < df["sma_fast"])

    # === RSI crossing signals (row-level booleans) ===
    buy_thr = float(args.buy_rsi)
    sell_thr = float(args.sell_rsi)

    r = df["rsi"]
    r_prev = r.shift(1)

    # buy when RSI crosses up over buy_thr AND trend gate ok
    df["buy_signal"] = (df["gate_trend_ok"] == True) & (r_prev < buy_thr) & (r >= buy_thr)

    # sell when RSI crosses down below sell_thr (classic exit) OR crosses up over sell_thr (profit-taking)
    # We'll implement "cross down below sell_thr" (more standard) to avoid overly frequent sells:
    df["sell_signal"] = (r_prev > sell_thr) & (r <= sell_thr)

    # Fill NaNs to False for signal columns
    for c in ["gate_trend_ok", "trend_break", "buy_signal", "sell_signal"]:
        df[c] = df[c].fillna(False).astype(bool)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False, encoding="utf-8")

    gate_true = int(df["gate_trend_ok"].sum())
    buy_cnt = int(df["buy_signal"].sum())
    sell_cnt = int(df["sell_signal"].sum())

    print(
        f"OK Phase5 wrote: {out} rows={len(df)} gateTrueBars={gate_true} "
        f"buySignals={buy_cnt} sellSignals={sell_cnt} "
        f"RSI(p={int(args.rsi_period)}) buy={buy_thr} sell={sell_thr} "
        f"trend={trend_mode} SMA({sma_fast_n},{sma_slow_n})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
