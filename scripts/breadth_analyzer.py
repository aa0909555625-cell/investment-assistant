# -*- coding: utf-8 -*-
"""
Breadth Analyzer (History-capable)

Inputs:
- data/all_stocks_daily.csv (must include date, code, total_score, change_percent)

Outputs:
- data/breadth_history.csv (date-level breadth series)
- data/breadth_{DATE}.csv / .json (latest snapshot convenience)

Breadth definition (v0.9):
- breadth_ratio = (# stocks with total_score >= score_threshold) / (# valid stocks)
- adv_ratio     = (# stocks with change_percent > 0) / (# valid stocks)
"""

from __future__ import annotations
import argparse
import json
import os
from typing import Optional, Tuple

import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

def _read_csv(path: str) -> pd.DataFrame:
    # avoid DtypeWarning: set low_memory=False + explicit dtype for code/date/source
    return pd.read_csv(
        path,
        dtype={"code": str, "date": str, "source": str},
        low_memory=False,
        encoding="utf-8-sig",
    )

def _clip_range(df: pd.DataFrame, start: Optional[str], end: Optional[str]) -> pd.DataFrame:
    if start:
        df = df[df["date"] >= str(start)]
    if end:
        df = df[df["date"] <= str(end)]
    return df

def build_breadth_history(in_csv: str, score_threshold: float, start: Optional[str], end: Optional[str]) -> pd.DataFrame:
    df = _read_csv(in_csv)
    need = {"date","code","total_score","change_percent"}
    if not need.issubset(set(df.columns)):
        raise ValueError(f"{in_csv} must contain columns: {sorted(list(need))}")

    df["date"] = df["date"].astype(str)
    df = _clip_range(df, start, end)

    df["total_score"] = pd.to_numeric(df["total_score"], errors="coerce")
    df["change_percent"] = pd.to_numeric(df["change_percent"], errors="coerce")

    # valid rows
    v = df.dropna(subset=["total_score"]).copy()

    # group by date
    g = v.groupby("date", sort=True)
    out = pd.DataFrame({
        "date": g.size().index.astype(str),
        "n": g.size().values.astype(int),
        "n_score_ge": g.apply(lambda x: int((x["total_score"] >= score_threshold).sum())).values.astype(int),
        "n_adv": g.apply(lambda x: int((pd.to_numeric(x["change_percent"], errors="coerce") > 0).sum())).values.astype(int),
    })

    out["breadth_ratio"] = (out["n_score_ge"] / out["n"]).astype(float)
    out["adv_ratio"] = (out["n_adv"] / out["n"]).astype(float)

    out = out.sort_values("date").reset_index(drop=True)
    return out

def write_latest_snapshot(hist: pd.DataFrame, out_csv: str, out_json: str):
    if hist.empty:
        return
    last = hist.iloc[-1].to_dict()
    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    pd.DataFrame([last]).to_csv(out_csv, index=False, encoding="utf-8-sig")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(last, f, ensure_ascii=False, indent=2)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in_csv", default=r"data/all_stocks_daily.csv")
    ap.add_argument("--out_history", default=r"data/breadth_history.csv")
    ap.add_argument("--out_csv", default="", help="optional: data/breadth_YYYY-MM-DD.csv")
    ap.add_argument("--out_json", default="", help="optional: data/breadth_YYYY-MM-DD.json")
    ap.add_argument("--score_threshold", type=float, default=70.0)
    ap.add_argument("--start", default="")
    ap.add_argument("--end", default="")
    args = ap.parse_args()

    start = args.start.strip() or None
    end = args.end.strip() or None

    hist = build_breadth_history(args.in_csv, args.score_threshold, start, end)

    os.makedirs(os.path.dirname(os.path.join(ROOT, args.out_history)), exist_ok=True)
    hist.to_csv(os.path.join(ROOT, args.out_history), index=False, encoding="utf-8-sig")

    # optional latest snapshot
    if args.out_csv and args.out_json:
        write_latest_snapshot(hist, os.path.join(ROOT, args.out_csv), os.path.join(ROOT, args.out_json))

    print(f"OK: wrote -> {os.path.join(ROOT, args.out_history)} rows={len(hist)}")
    if not hist.empty:
        print("tail:")
        print(hist.tail(5).to_string(index=False))

if __name__ == "__main__":
    main()