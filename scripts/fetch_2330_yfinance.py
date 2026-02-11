from __future__ import annotations

import argparse
from pathlib import Path
from typing import List

import pandas as pd

try:
    import yfinance as yf
except Exception as e:
    raise SystemExit(
        "Missing dependency: yfinance. Install with: pip install yfinance"
    ) from e


REQUIRED_OUT_COLS = ["date", "open", "high", "low", "close", "volume"]


def _flatten_columns(df: pd.DataFrame) -> pd.DataFrame:
    if isinstance(df.columns, pd.MultiIndex):
        df = df.copy()
        df.columns = [str(c[0]) for c in df.columns]
    return df


def _normalize_ohlcv(df: pd.DataFrame) -> pd.DataFrame:
    if df is None or df.empty:
        raise ValueError("Downloaded dataframe is empty")

    df = _flatten_columns(df)

    if isinstance(df.index, pd.DatetimeIndex):
        df = df.reset_index()

    df = df.copy()
    df.columns = [str(c).strip().lower() for c in df.columns]

    if "date" not in df.columns:
        raise ValueError(f"Cannot find date column. Columns={df.columns.tolist()}")

    col_map = {}
    for want, candidates in [
        ("open", ["open"]),
        ("high", ["high"]),
        ("low", ["low"]),
        ("close", ["close", "adj close", "adj_close", "adjclose"]),
        ("volume", ["volume"]),
    ]:
        found = None
        for cand in candidates:
            if cand in df.columns:
                found = cand
                break
        if not found:
            raise ValueError(f"Missing required column '{want}'. Columns={df.columns.tolist()}")
        col_map[want] = found

    out = pd.DataFrame(
        {
            "date": pd.to_datetime(df["date"], errors="coerce"),
            "open": pd.to_numeric(df[col_map["open"]], errors="coerce"),
            "high": pd.to_numeric(df[col_map["high"]], errors="coerce"),
            "low": pd.to_numeric(df[col_map["low"]], errors="coerce"),
            "close": pd.to_numeric(df[col_map["close"]], errors="coerce"),
            "volume": pd.to_numeric(df[col_map["volume"]], errors="coerce"),
        }
    )

    out = out.dropna(subset=["date", "open", "high", "low", "close"])
    out["volume"] = out["volume"].fillna(0).astype("int64")
    out = out.sort_values("date")
    out["date"] = out["date"].dt.strftime("%Y-%m-%d")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="2330.TW")
    ap.add_argument("--period", default="2y")
    ap.add_argument("--interval", default="1d")
    ap.add_argument("--out", default="data/2330.csv")
    args = ap.parse_args()

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    df = yf.download(
        tickers=args.symbol,
        period=args.period,
        interval=args.interval,
        auto_adjust=False,
        progress=False,
        group_by="column",
    )

    norm = _normalize_ohlcv(df)
    norm = norm[REQUIRED_OUT_COLS]
    norm.to_csv(out_path, index=False, encoding="utf-8")

    print(f"OK wrote: {out_path} rows={len(norm)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
