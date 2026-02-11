from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


def sma(s: pd.Series, n: int) -> pd.Series:
    return s.rolling(n, min_periods=n).mean()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", default="data/2330.csv")
    ap.add_argument("--out", default="reports/monthly_regime_2330.csv")
    ap.add_argument("--overheat_pct", type=float, default=0.10, help="If close is >= (1+overheat_pct)*SMA50, downgrade allocation")
    args = ap.parse_args()

    inp = Path(args.inp)
    if not inp.exists():
        raise SystemExit(f"Input not found: {inp}")

    df = pd.read_csv(inp)
    df["date"] = pd.to_datetime(df["date"])
    df = df.sort_values("date")

    close = df["close"].astype(float)
    df["sma50"] = sma(close, 50)
    df["sma200"] = sma(close, 200)

    # month-end rows
    df["month"] = df["date"].dt.to_period("M").astype(str)
    month_end = df.groupby("month", as_index=False).tail(1).copy()

    # regime: strong trend
    month_end["strong_trend"] = (month_end["close"] > month_end["sma200"]) & (month_end["sma50"] > month_end["sma200"])

    # overheat: distance to SMA50
    month_end["dist_to_sma50_pct"] = (month_end["close"] / month_end["sma50"]) - 1.0
    month_end["overheated"] = month_end["dist_to_sma50_pct"] >= float(args.overheat_pct)

    def alloc_base(strong: bool) -> str:
        return "v1.1=60% / v1.5=40%" if strong else "v1.1=80% / v1.5=20%"

    def alloc_final(strong: bool, overheated: bool) -> str:
        # If overheated, downgrade to defensive split even in strong trend
        if overheated:
            return "v1.1=80% / v1.5=20% (downgrade: overheated)"
        return alloc_base(strong)

    month_end["allocation_base"] = month_end["strong_trend"].map(alloc_base)
    month_end["allocation_final"] = month_end.apply(lambda r: alloc_final(bool(r["strong_trend"]), bool(r["overheated"])), axis=1)

    out = month_end[
        ["month", "date", "close", "sma50", "sma200", "strong_trend", "dist_to_sma50_pct", "overheated", "allocation_base", "allocation_final"]
    ].copy()

    # pretty round
    out["sma50"] = out["sma50"].round(3)
    out["sma200"] = out["sma200"].round(3)
    out["dist_to_sma50_pct"] = (out["dist_to_sma50_pct"] * 100).round(2)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(out_path, index=False, encoding="utf-8")

    print(f"OK wrote: {out_path} rows={len(out)}")
    print("Latest 6 months:")
    print(out.tail(6).to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
