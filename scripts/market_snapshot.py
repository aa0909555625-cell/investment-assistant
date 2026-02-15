#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
market_snapshot.py (robust)
- Always produce TAIEX snapshot (required).
- TPEx OTC series is optional: if endpoint changed/blocked, we degrade gracefully.
Outputs:
  data/market_snapshot_taiex.csv
  data/market_snapshot_taiex.json

JSON schema (new, flat):
{
  "date": "YYYY-MM-DD",
  "close": 12345.6,
  "chg_pct": 1.23,
  "sma_fast": 12000.0,
  "sma_slow": 11000.0,
  "trend_ok": true,
  "market_ok": true,
  "risk_mode": "RISK_ON|RISK_OFF",
  "source": "stooq",
  "otc": { "date": "...", "close": ..., "chg_pct": ..., "ok": true/false, "error": "..." }
}
"""

from __future__ import annotations
import argparse
import json
import os
from dataclasses import dataclass
from typing import Optional, Dict, Any

import pandas as pd


def ensure_parent(path: str) -> None:
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.exists(d):
        os.makedirs(d, exist_ok=True)


def read_taiex_from_csv(csv_path: str) -> pd.DataFrame:
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Missing market csv: {csv_path}")
    df = pd.read_csv(csv_path)
    # expected columns from our stooq fetch: date, open, high, low, close, volume (may vary)
    if "date" not in df.columns:
        # some fetchers use Date
        if "Date" in df.columns:
            df = df.rename(columns={"Date": "date"})
        else:
            raise RuntimeError(f"market csv missing date column: cols={list(df.columns)}")
    if "close" not in df.columns:
        # sometimes Close
        if "Close" in df.columns:
            df = df.rename(columns={"Close": "close"})
        else:
            raise RuntimeError(f"market csv missing close column: cols={list(df.columns)}")

    df["date"] = df["date"].astype(str)
    df["close"] = pd.to_numeric(df["close"], errors="coerce")
    df = df.dropna(subset=["close"]).copy()
    df = df.sort_values("date").reset_index(drop=True)
    if len(df) < 260:
        # we need SMA200 at least
        raise RuntimeError(f"market csv too short for SMA200: rows={len(df)}")
    return df


def sma(series: pd.Series, window: int) -> pd.Series:
    return series.rolling(window=window, min_periods=window).mean()


def pct_change(last: float, prev: float) -> float:
    if prev == 0 or prev is None:
        return 0.0
    return (last / prev - 1.0) * 100.0


def build_taiex_snapshot(df: pd.DataFrame) -> Dict[str, Any]:
    df = df.copy()
    df["sma50"] = sma(df["close"], 50)
    df["sma200"] = sma(df["close"], 200)

    last = df.iloc[-1]
    prev = df.iloc[-2]

    close = float(last["close"])
    sma50 = float(last["sma50"])
    sma200 = float(last["sma200"])
    chg_pct = float(pct_change(close, float(prev["close"])))

    trend_ok = bool(close >= sma200)
    market_ok = bool((close >= sma50) and trend_ok)
    risk_mode = "RISK_ON" if market_ok else "RISK_OFF"

    return {
        "date": str(last["date"]),
        "close": close,
        "chg_pct": chg_pct,
        "sma_fast": sma50,
        "sma_slow": sma200,
        "trend_ok": trend_ok,
        "market_ok": market_ok,
        "risk_mode": risk_mode,
        "source": "stooq",
    }


def try_read_tpex_otc_series(timeout: int = 20) -> Dict[str, Any]:
    """
    Optional. We do NOT fail the whole snapshot if this breaks.
    Since TPEx endpoints often change / block, we just return ok=false with error.
    """
    # Intentionally minimal: we keep compatibility without hard dependency on TPEx.
    return {"ok": False, "error": "TPEx OTC fetch disabled (optional).", "date": None, "close": None, "chg_pct": None}


def write_csv(out_csv: str, snap: Dict[str, Any]) -> None:
    ensure_parent(out_csv)
    row = {
        "date": snap.get("date"),
        "close": snap.get("close"),
        "chg_pct": snap.get("chg_pct"),
        "sma_fast": snap.get("sma_fast"),
        "sma_slow": snap.get("sma_slow"),
        "trend_ok": snap.get("trend_ok"),
        "market_ok": snap.get("market_ok"),
        "risk_mode": snap.get("risk_mode"),
        "source": snap.get("source"),
        "otc_ok": (snap.get("otc") or {}).get("ok"),
        "otc_close": (snap.get("otc") or {}).get("close"),
        "otc_chg_pct": (snap.get("otc") or {}).get("chg_pct"),
        "otc_error": (snap.get("otc") or {}).get("error"),
    }
    pd.DataFrame([row]).to_csv(out_csv, index=False, encoding="utf-8")


def write_json(out_json: str, snap: Dict[str, Any]) -> None:
    ensure_parent(out_json)
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(snap, f, ensure_ascii=False, indent=2)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--market_csv", default=r"data\market_taiex_stooq.csv", help="TAIEX series csv (stooq)")
    ap.add_argument("--out_csv", default=r"data\market_snapshot_taiex.csv")
    ap.add_argument("--out_json", default=r"data\market_snapshot_taiex.json")
    ap.add_argument("--timeout", type=int, default=20)
    args = ap.parse_args()

    taiex_df = read_taiex_from_csv(args.market_csv)
    snap = build_taiex_snapshot(taiex_df)

    otc = try_read_tpex_otc_series(timeout=args.timeout)
    snap["otc"] = otc

    write_csv(args.out_csv, snap)
    write_json(args.out_json, snap)

    print(f"OK: wrote {os.path.abspath(args.out_csv)} rows=1")
    print(f"OK: wrote {os.path.abspath(args.out_json)} date={snap['date']} risk_mode={snap['risk_mode']}")


if __name__ == "__main__":
    main()