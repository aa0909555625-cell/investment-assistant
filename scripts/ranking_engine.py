# -*- coding: utf-8 -*-
"""
ranking_engine.py
- Read daily universe CSV (e.g. data/all_stocks_daily.csv)
- Select latest date (or specified date) and rank by total_score
- Output top N ranking CSV

Fix: eliminate pandas DtypeWarning (mixed types) by enforcing dtype + low_memory=False.
"""

from __future__ import annotations

import os
import sys
import argparse
from typing import Optional

import pandas as pd

REQUIRED = ["date", "code", "total_score"]


def _read_csv(path: str) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(f"Missing: {path}")

    # Force stable dtypes to avoid mixed-type warnings on big CSVs
    dtype = {
        "date": str,
        "code": str,
        "source": str,
    }

    # best effort encoding handling
    try:
        return pd.read_csv(path, dtype=dtype, low_memory=False)
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype=dtype, low_memory=False)


def _ensure_cols(df: pd.DataFrame, cols: list[str]) -> None:
    missing = [c for c in cols if c not in df.columns]
    if missing:
        raise ValueError(f"Missing columns: {missing}. Have={list(df.columns)}")


def _to_float_series(s: pd.Series) -> pd.Series:
    # robust numeric parse (keeps NaN for bad cells)
    return pd.to_numeric(s, errors="coerce")


def build_ranking(
    in_csv: str,
    top: int = 200,
    date: str = "",
) -> pd.DataFrame:
    df = _read_csv(in_csv)
    _ensure_cols(df, REQUIRED)

    # normalize
    df["date"] = df["date"].astype(str)
    df["code"] = df["code"].astype(str).str.strip()
    df["total_score"] = _to_float_series(df["total_score"])

    if date:
        d = str(date)
    else:
        # pick latest available date
        # (string sort works with YYYY-MM-DD)
        d = df["date"].dropna().astype(str).max()

    day = df[df["date"].astype(str) == d].copy()
    if len(day) == 0:
        raise ValueError(f"No rows for date={d} in {in_csv}")

    # sort by total_score desc, then code asc for stability
    day = day.dropna(subset=["total_score"])
    day = day.sort_values(["total_score", "code"], ascending=[False, True])

    # ensure output columns at least include REQUIRED + optional columns if exist
    out = day.head(int(top)).copy()

    return out


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in_csv", required=True, help="Input universe CSV, e.g. data/all_stocks_daily.csv")
    ap.add_argument("--out_csv", default="", help="Output ranking CSV (default: data/ranking_<date>.csv)")
    ap.add_argument("--top", type=int, default=200, help="Top N rows")
    ap.add_argument("--date", default="", help="Target date YYYY-MM-DD (default: latest in in_csv)")
    args = ap.parse_args(argv)

    out_df = build_ranking(args.in_csv, top=args.top, date=args.date)

    # default output path
    out_date = out_df["date"].astype(str).iloc[0]
    out_csv = args.out_csv.strip() or os.path.join("data", f"ranking_{out_date}.csv")

    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)

    # Write UTF-8 (no BOM) by default; PowerShell side already uses Write-Utf8NoBom usually,
    # but here keep python side standard.
    out_df.to_csv(out_csv, index=False, encoding="utf-8")

    print(f"OK: wrote -> {os.path.abspath(out_csv)} (rows={len(out_df)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())