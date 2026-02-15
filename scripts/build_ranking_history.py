# -*- coding: utf-8 -*-
"""
build_ranking_history.py
Build per-day ranking (TopN) from all_stocks_daily.csv so backtests can use
the correct "prev_date ranking" instead of reusing one static ranking file.

Output: data/ranking_history.csv
Columns: date,rank,code,name,sector,total_score,source
"""

from __future__ import annotations
import os
import argparse
from typing import Optional, Dict

import pandas as pd


def _read_csv(path: str) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(path)

    dtype: Dict[str, object] = {
        "date": str,
        "code": str,
        "name": str,
        "sector": str,
        "source": str,
    }

    try:
        return pd.read_csv(path, dtype=dtype, low_memory=False)
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype=dtype, low_memory=False)


def _to_float_series(s: pd.Series) -> pd.Series:
    return pd.to_numeric(s, errors="coerce")


def build_history(
    in_csv: str,
    out_csv: str,
    top: int,
    threshold: float,
) -> pd.DataFrame:
    df = _read_csv(in_csv)

    if "total_score" not in df.columns:
        raise ValueError("Missing column: total_score")

    df["date"] = df["date"].astype(str)
    df["code"] = df["code"].astype(str).str.strip()
    df["total_score"] = _to_float_series(df["total_score"])

    # Keep optional cols if present
    for c in ["name", "sector", "source"]:
        if c not in df.columns:
            df[c] = ""

    # group by date
    dates = sorted(df["date"].dropna().unique().tolist())

    rows = []
    for d in dates:
        day = df[df["date"] == d].copy()
        day = day.dropna(subset=["total_score"])
        day = day[day["total_score"] >= float(threshold)]

        if len(day) == 0:
            continue

        day = day.sort_values(["total_score", "code"], ascending=[False, True]).head(int(top))
        day = day.reset_index(drop=True)
        day["rank"] = day.index + 1

        out = day[["date", "rank", "code", "name", "sector", "total_score", "source"]].copy()
        rows.append(out)

    out_df = pd.concat(rows, ignore_index=True) if rows else pd.DataFrame(
        columns=["date", "rank", "code", "name", "sector", "total_score", "source"]
    )

    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)
    out_df.to_csv(out_csv, index=False, encoding="utf-8")

    return out_df


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in_csv", default="data/all_stocks_daily.csv")
    ap.add_argument("--out_csv", default="data/ranking_history.csv")
    ap.add_argument("--top", type=int, default=200)
    ap.add_argument("--threshold", type=float, default=70.0)
    args = ap.parse_args(argv)

    out_df = build_history(args.in_csv, args.out_csv, args.top, args.threshold)
    print(f"OK: wrote -> {os.path.abspath(args.out_csv)} (rows={len(out_df)})")

    if len(out_df) > 0:
        tail = out_df.tail(8)
        print("tail:")
        print(tail.to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())