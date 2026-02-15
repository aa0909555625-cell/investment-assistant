# -*- coding: utf-8 -*-
"""
Fetch TAIEX (TWSE Cap-Weighted Index) daily OHLC using TWSE official endpoint:
https://www.twse.com.tw/indicesReport/MI_5MINS_HIST?response=json&date=YYYYMM01

TWSE date format may be:
- Gregorian: YYYY/MM/DD
- ROC year: 115/02/11 (ROC 115 = 2026)

Output CSV columns:
date,open,high,low,close,volume
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

def _to_float(s: str) -> float:
    if s is None:
        return float("nan")
    s = str(s).strip().replace(",", "")
    if s == "" or s.lower() == "nan":
        return float("nan")
    try:
        return float(s)
    except:
        return float("nan")

def _parse_twse_date(s: str) -> str:
    """
    Accept:
      - 2026/02/11
      - 115/02/11  (ROC year)
    Return:
      - 2026-02-11
    """
    s = str(s).strip().replace(" ", "")
    parts = s.split("/")
    if len(parts) != 3:
        return s

    y, m, d = parts
    try:
        yi = int(y)
        mi = int(m)
        di = int(d)
    except:
        return s

    # ROC year handling: 115 => 2026
    # heuristic: if year <= 1911, treat as ROC.
    if yi <= 1911:
        yi += 1911

    return f"{yi:04d}-{mi:02d}-{di:02d}"

def fetch_mi_5mins_hist_month(yyyymm: str, timeout: int = 20) -> list[dict]:
    url = f"https://www.twse.com.tw/indicesReport/MI_5MINS_HIST?response=json&date={yyyymm}01"
    req = Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
            "Accept": "application/json,text/plain,*/*",
            "Referer": "https://www.twse.com.tw/",
        },
        method="GET",
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except (HTTPError, URLError) as e:
        raise RuntimeError(f"TWSE fetch failed for {yyyymm}: {repr(e)}")

    try:
        js = json.loads(raw)
    except Exception as e:
        raise RuntimeError(f"TWSE json parse failed for {yyyymm}: {repr(e)}")

    data = js.get("data")
    if not data or not isinstance(data, list):
        stat = js.get("stat")
        raise RuntimeError(f"TWSE MI_5MINS_HIST no data for {yyyymm}: stat={stat!r}")

    out = []
    # row: [date, open, high, low, close]
    for row in data:
        if not row or len(row) < 5:
            continue
        out.append({
            "date": _parse_twse_date(row[0]),
            "open": _to_float(row[1]),
            "high": _to_float(row[2]),
            "low":  _to_float(row[3]),
            "close": _to_float(row[4]),
            "volume": 0,
        })
    return out

def month_iter(end: dt.date, months: int) -> list[str]:
    # return yyyymm list (ascending)
    y = end.year
    m = end.month
    res = []
    for _ in range(months):
        res.append(f"{y:04d}{m:02d}")
        m -= 1
        if m <= 0:
            y -= 1
            m = 12
    return list(reversed(res))

def write_csv(path: str, rows: list[dict]) -> tuple[int, str]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rows = sorted(rows, key=lambda r: r["date"])

    # de-dup by date (keep last)
    dedup = {}
    for r in rows:
        dedup[r["date"]] = r
    rows = [dedup[k] for k in sorted(dedup.keys())]

    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["date","open","high","low","close","volume"])
        w.writeheader()
        w.writerows(rows)

    last_date = rows[-1]["date"] if rows else "N/A"
    return (len(rows), last_date)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/market_taiex_stooq.csv", help="output csv path")
    ap.add_argument("--months", type=int, default=24, help="how many months to fetch")
    ap.add_argument("--timeout", type=int, default=20, help="http timeout seconds")
    ap.add_argument("--sleep", type=float, default=0.6, help="sleep between month requests")
    args = ap.parse_args()

    today = dt.date.today()
    yyyymm_list = month_iter(today, max(1, args.months))

    all_rows: list[dict] = []
    last_err = None
    for yyyymm in yyyymm_list:
        try:
            rows = fetch_mi_5mins_hist_month(yyyymm, timeout=args.timeout)
            all_rows.extend(rows)
            last_err = None
        except Exception as e:
            last_err = e
        time.sleep(max(0.0, args.sleep))

    if not all_rows:
        raise SystemExit(f"FATAL: no TAIEX rows fetched. last_err={repr(last_err)}")

    n, last_date = write_csv(args.out, all_rows)
    print(f"OK: wrote {os.path.abspath(args.out)} rows={n} last_date={last_date}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())