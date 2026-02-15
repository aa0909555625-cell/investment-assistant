# -*- coding: utf-8 -*-
"""
Backfill market snapshot for TAIEX.

Goal:
- Produce multi-date data/market_snapshot_taiex.csv so portfolio backtest v3 can switch risk mode over time.

Strategy:
1) Try TWSE MI_5MINS_HIST (json first, then html).
2) If TWSE yields no rows (common due to endpoint changes / blocking), fallback to existing:
   - data/market_taiex_stooq.csv (your project already has it and it's stable)

Outputs:
- data/market_taiex_hist.csv          (normalized close series with chg_pct)
- data/market_snapshot_taiex.csv      (date, close, chg_pct, sma_fast, sma_slow, trend_ok, market_ok, risk_mode, source)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from io import StringIO
from typing import List, Optional, Tuple

import pandas as pd
import requests

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_HIST = os.path.join(ROOT, "data", "market_taiex_hist.csv")
OUT_SNAP = os.path.join(ROOT, "data", "market_snapshot_taiex.csv")
FALLBACK_STOOQ = os.path.join(ROOT, "data", "market_taiex_stooq.csv")

URL = "https://www.twse.com.tw/indicesReport/MI_5MINS_HIST"

S = requests.Session()
S.headers.update({
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.8",
    "Referer": "https://www.twse.com.tw/",
})

def ymd(s: str) -> dt.date:
    return dt.datetime.strptime(s, "%Y-%m-%d").date()

def month_iter(start: dt.date, end: dt.date):
    cur = dt.date(start.year, start.month, 1)
    last = dt.date(end.year, end.month, 1)
    while cur <= last:
        yield cur.year, cur.month
        if cur.month == 12:
            cur = dt.date(cur.year + 1, 1, 1)
        else:
            cur = dt.date(cur.year, cur.month + 1, 1)

def roc_to_ad(roc: str) -> str:
    roc = str(roc).strip()
    m = re.match(r"^\s*(\d{2,3})/(\d{2})/(\d{2})\s*$", roc)
    if not m:
        return ""
    y = int(m.group(1)) + 1911
    return f"{y:04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"

def to_float(x) -> float:
    s = str(x).replace(",", "").strip()
    if s in ("", "--", "---", "nan", "None"):
        return float("nan")
    try:
        return float(s)
    except Exception:
        return float("nan")

def _try_parse_json(text: str):
    t = text.strip()
    if not t.startswith("{"):
        return None
    try:
        return json.loads(t)
    except Exception:
        return None

def fetch_month_table_twse(year: int, month: int, timeout: int) -> pd.DataFrame:
    date_param = f"{year:04d}{month:02d}01"

    # 1) JSON first (more stable than HTML)
    r = S.get(URL, params={"response": "json", "date": date_param}, timeout=timeout)
    if r.status_code == 200:
        js = _try_parse_json(r.text)
        if isinstance(js, dict) and "data" in js and "fields" in js:
            fields = [str(x).strip() for x in js.get("fields", [])]
            data = js.get("data", [])
            if isinstance(data, list) and len(data) > 0:
                df = pd.DataFrame(data, columns=fields)
                # expect columns like 日期/開盤指數/最高指數/最低指數/收盤指數
                if ("日期" in df.columns) and ("收盤指數" in df.columns):
                    return df

    # 2) HTML fallback
    r = S.get(URL, params={"response": "html", "date": date_param}, timeout=timeout)
    r.raise_for_status()
    try:
        tables = pd.read_html(StringIO(r.text))
    except Exception:
        return pd.DataFrame()

    if not tables:
        return pd.DataFrame()

    # find the table containing 日期 + 收盤指數
    for t in tables:
        cols = [str(c).strip() for c in t.columns.tolist()]
        if ("日期" in cols) and ("收盤指數" in cols):
            df = t.copy()
            df.columns = cols
            return df

    # last resort: first table
    df = tables[0].copy()
    df.columns = [str(c).strip() for c in df.columns.tolist()]
    return df

def build_hist_from_twse(start: dt.date, end: dt.date, timeout: int) -> pd.DataFrame:
    frames: List[pd.DataFrame] = []
    for y, m in month_iter(start, end):
        dfm = fetch_month_table_twse(y, m, timeout=timeout)
        if dfm.empty:
            continue
        # must contain 日期 + 收盤指數 at least
        if ("日期" not in dfm.columns) or ("收盤指數" not in dfm.columns):
            continue
        dfm["date"] = dfm["日期"].map(roc_to_ad)
        dfm = dfm[dfm["date"] != ""].copy()
        # not all tables include OHLC perfectly; use close at least
        if "收盤指數" in dfm.columns:
            dfm["close"] = dfm["收盤指數"].map(to_float)
        else:
            continue
        dfm = dfm[["date","close"]].copy()
        frames.append(dfm)

    if not frames:
        return pd.DataFrame()

    hist = pd.concat(frames, ignore_index=True)
    hist["date"] = hist["date"].astype(str)
    hist = hist.dropna(subset=["close"])
    hist = hist.drop_duplicates(["date"], keep="last")
    hist = hist.sort_values("date").reset_index(drop=True)

    s = start.strftime("%Y-%m-%d")
    e = end.strftime("%Y-%m-%d")
    hist = hist[(hist["date"] >= s) & (hist["date"] <= e)].copy()

    hist["prev_close"] = hist["close"].shift(1)
    hist["chg_pct"] = ((hist["close"] - hist["prev_close"]) / hist["prev_close"]) * 100.0
    hist["chg_pct"] = hist["chg_pct"].replace([float("inf"), float("-inf")], float("nan")).fillna(0.0)
    hist.drop(columns=["prev_close"], inplace=True)

    hist["source"] = "twse"
    return hist

def build_hist_from_stooq_csv(start: dt.date, end: dt.date) -> pd.DataFrame:
    if not os.path.exists(FALLBACK_STOOQ):
        return pd.DataFrame()

    df = pd.read_csv(FALLBACK_STOOQ, encoding="utf-8-sig")
    # support possible schemas
    # expected columns: date, close OR Close
    cols = {c.lower(): c for c in df.columns}
    if "date" not in cols:
        return pd.DataFrame()

    date_col = cols["date"]
    close_col = cols.get("close") or cols.get("adj_close") or cols.get("close_price") or cols.get("c") or cols.get("close_") or cols.get("closing")
    if close_col is None:
        # sometimes stooq data is "Close" with capital
        close_col = cols.get("close".lower())
    if close_col is None:
        # try exact
        if "close" in df.columns:
            close_col = "close"
        elif "Close" in df.columns:
            close_col = "Close"
        else:
            return pd.DataFrame()

    out = pd.DataFrame({
        "date": df[date_col].astype(str),
        "close": pd.to_numeric(df[close_col], errors="coerce"),
    }).dropna(subset=["close"]).copy()

    out = out.sort_values("date").drop_duplicates(["date"], keep="last").reset_index(drop=True)
    s = start.strftime("%Y-%m-%d")
    e = end.strftime("%Y-%m-%d")
    out = out[(out["date"] >= s) & (out["date"] <= e)].copy()

    out["prev_close"] = out["close"].shift(1)
    out["chg_pct"] = ((out["close"] - out["prev_close"]) / out["prev_close"]) * 100.0
    out["chg_pct"] = out["chg_pct"].replace([float("inf"), float("-inf")], float("nan")).fillna(0.0)
    out.drop(columns=["prev_close"], inplace=True)

    out["source"] = "stooq_csv"
    return out

def build_snapshot(hist: pd.DataFrame, fast: int, slow: int) -> pd.DataFrame:
    df = hist.copy()
    df["sma_fast"] = df["close"].rolling(fast, min_periods=fast).mean()
    df["sma_slow"] = df["close"].rolling(slow, min_periods=slow).mean()

    df["trend_ok"] = (df["close"] > df["sma_fast"]) & (df["close"] > df["sma_slow"])
    df["trend_ok"] = df["trend_ok"].fillna(False)

    # v0.9 baseline: market_ok == trend_ok (later we'll AND breadth_ratio)
    df["market_ok"] = df["trend_ok"]
    df["risk_mode"] = df["market_ok"].map(lambda x: "RISK_ON" if bool(x) else "RISK_OFF")

    out = df[["date","close","chg_pct","sma_fast","sma_slow","trend_ok","market_ok","risk_mode","source"]].copy()
    out["date"] = out["date"].astype(str)
    out["trend_ok"] = out["trend_ok"].astype(bool)
    out["market_ok"] = out["market_ok"].astype(bool)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True, help="YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD")
    ap.add_argument("--fast", type=int, default=20)
    ap.add_argument("--slow", type=int, default=60)
    ap.add_argument("--timeout", type=int, default=25)
    args = ap.parse_args()

    start = ymd(args.start)
    end = ymd(args.end)
    if end < start:
        raise SystemExit("end < start")

    # 1) try TWSE
    hist = build_hist_from_twse(start, end, timeout=args.timeout)

    # 2) fallback to stooq csv if TWSE is empty
    if hist.empty:
        hist = build_hist_from_stooq_csv(start, end)

    if hist.empty:
        raise SystemExit("No TAIEX hist rows produced (TWSE empty, and fallback stooq csv not available/empty).")

    os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
    hist.to_csv(OUT_HIST, index=False, encoding="utf-8-sig")

    snap = build_snapshot(hist, fast=args.fast, slow=args.slow)
    snap.to_csv(OUT_SNAP, index=False, encoding="utf-8-sig")

    print(f"OK: wrote -> {OUT_HIST} rows={len(hist)} source={hist['source'].iloc[-1]}")
    print(f"OK: wrote -> {OUT_SNAP} rows={len(snap)} fast={args.fast} slow={args.slow}")
    print("snapshot tail:")
    print(snap.tail(5).to_string(index=False))

if __name__ == "__main__":
    main()