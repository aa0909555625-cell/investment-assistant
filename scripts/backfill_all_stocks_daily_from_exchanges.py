# -*- coding: utf-8 -*-
"""
Backfill all_stocks_daily.csv from official exchange endpoints (TWSE + TPEx).

Goal:
- Produce >=2 trading dates in data/all_stocks_daily.csv so portfolio backtest v3 has bars > 0.
- Keep schema EXACTLY as current data/all_stocks_daily.csv header.
- Append only missing dates unless --force.

Sources:
- TWSE: https://www.twse.com.tw/exchangeReport/STOCK_DAY_ALL?response=json&date=YYYYMMDD
- TPEx: https://www.tpex.org.tw/web/stock/aftertrading/otc_quotes_no1430/stk_wn1430_result.php?l=zh-tw&se=EW&o=data&d=ROC/MM/DD

Notes:
- total_score here is a conservative, deterministic score computed from change_percent only.
  (You can later replace it with your full scoring model.)
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import re
import sys
import time
from typing import Dict, List, Tuple, Optional

import requests


def die(msg: str, code: int = 1) -> None:
    print(f"[FATAL] {msg}", file=sys.stderr)
    raise SystemExit(code)


def ymd(s: str) -> dt.date:
    return dt.datetime.strptime(s, "%Y-%m-%d").date()


def daterange(start: dt.date, end: dt.date) -> List[dt.date]:
    out = []
    cur = start
    while cur <= end:
        # skip weekends
        if cur.weekday() < 5:
            out.append(cur)
        cur += dt.timedelta(days=1)
    return out


def read_header(path: str) -> List[str]:
    if not os.path.exists(path):
        die(f"Missing required file: {path} (expected existing schema).")
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        first = f.readline().strip("\r\n")
    if not first:
        die(f"Empty header in: {path}")
    return next(csv.reader([first]))


def existing_dates(path: str) -> set:
    ds = set()
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        r = csv.DictReader(f)
        if "date" not in (r.fieldnames or []):
            die("data/all_stocks_daily.csv must contain 'date' column.")
        for row in r:
            d = (row.get("date") or "").strip()
            if d:
                ds.add(d)
    return ds


def safe_float(x: str) -> Optional[float]:
    if x is None:
        return None
    s = str(x).strip()
    if s == "" or s in ("--", "---", "null", "None"):
        return None
    s = s.replace(",", "")
    try:
        return float(s)
    except Exception:
        return None


def clamp(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else hi if v > hi else v


def score_from_change_percent(cp: Optional[float]) -> float:
    """
    Deterministic conservative score:
      base 50, add cp*2, clamp 0..100.
    """
    if cp is None or (isinstance(cp, float) and (math.isnan(cp) or math.isinf(cp))):
        return 0.0
    return float(round(clamp(50.0 + cp * 2.0, 0.0, 100.0), 2))


# ----------------- TWSE -----------------

def fetch_twse_stock_day_all(d: dt.date, timeout: int = 25) -> List[Dict[str, str]]:
    url = "https://www.twse.com.tw/exchangeReport/STOCK_DAY_ALL"
    params = {"response": "json", "date": d.strftime("%Y%m%d")}
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/json,text/plain,*/*",
        "Referer": "https://www.twse.com.tw/",
    }
    resp = requests.get(url, params=params, headers=headers, timeout=timeout)
    resp.raise_for_status()

    j = resp.json()
    # Typical keys: "fields", "data", "stat", "date", ...
    data = j.get("data")
    fields = j.get("fields")
    if not isinstance(data, list) or not isinstance(fields, list) or len(fields) == 0:
        # sometimes holiday -> no data
        return []

    # map by field names when possible; otherwise by index
    # Expected fields include: "證券代號","證券名稱","成交股數","成交金額","開盤價","最高價","最低價","收盤價","漲跌(+/-)","漲跌價差","成交筆數"
    idx = {str(name): i for i, name in enumerate(fields)}

    out = []
    for row in data:
        if not isinstance(row, list) or len(row) < 2:
            continue
        code = str(row[idx.get("證券代號", 0)]).strip()
        name = str(row[idx.get("證券名稱", 1)]).strip()

        close = safe_float(row[idx.get("收盤價", 7)]) if "收盤價" in idx else None
        open_ = safe_float(row[idx.get("開盤價", 4)]) if "開盤價" in idx else None
        high = safe_float(row[idx.get("最高價", 5)]) if "最高價" in idx else None
        low = safe_float(row[idx.get("最低價", 6)]) if "最低價" in idx else None
        vol = safe_float(row[idx.get("成交股數", 2)]) if "成交股數" in idx else None
        val = safe_float(row[idx.get("成交金額", 3)]) if "成交金額" in idx else None

        # change value parsing
        # some payload uses two columns: "漲跌(+/-)" and "漲跌價差"
        sign = None
        if "漲跌(+/-)" in idx:
            sgn = str(row[idx["漲跌(+/-)"]]).strip()
            if "+" in sgn:
                sign = +1
            elif "-" in sgn:
                sign = -1
        chg = None
        if "漲跌價差" in idx:
            chg = safe_float(row[idx["漲跌價差"]])
        if chg is not None and sign is not None:
            chg = chg * float(sign)

        cp = None
        if close is not None and chg is not None:
            prev = close - chg
            if prev and prev != 0:
                cp = (chg / prev) * 100.0

        out.append({
            "code": code,
            "name": name,
            "market": "TWSE",
            "close": close,
            "open": open_,
            "high": high,
            "low": low,
            "volume": vol,
            "turnover": val,
            "change_percent": cp,
        })
    return out


# ----------------- TPEX -----------------

def to_roc_date(d: dt.date) -> str:
    roc_year = d.year - 1911
    return f"{roc_year:03d}/{d.month:02d}/{d.day:02d}"


def parse_tpex_o_data(text: str) -> Tuple[List[str], List[List[str]]]:
    """
    TPEx o=data response is CSV-like (often with header row).
    We'll parse it as CSV and return (header, rows).
    """
    text = text.strip("\ufeff").strip()
    # Some responses might be JSON; handle quickly
    if text.startswith("{") or text.startswith("["):
        try:
            j = json.loads(text)
            # try known shapes
            if isinstance(j, dict):
                if "aaData" in j and isinstance(j["aaData"], list):
                    # header may not exist -> return empty header
                    return [], j["aaData"]
            # fallback: treat as no rows
            return [], []
        except Exception:
            return [], []

    # CSV-like
    lines = [ln for ln in text.splitlines() if ln.strip() != ""]
    if not lines:
        return [], []

    reader = csv.reader(lines)
    all_rows = list(reader)
    if not all_rows:
        return [], []

    header = all_rows[0]
    rows = all_rows[1:] if len(all_rows) > 1 else []
    return header, rows


def fetch_tpex_daily_close(d: dt.date, timeout: int = 25) -> List[Dict[str, str]]:
    url = "https://www.tpex.org.tw/web/stock/aftertrading/otc_quotes_no1430/stk_wn1430_result.php"
    params = {"l": "zh-tw", "se": "EW", "o": "data", "d": to_roc_date(d)}
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "text/plain,text/csv,application/json,*/*",
        "Referer": "https://www.tpex.org.tw/",
    }
    resp = requests.get(url, params=params, headers=headers, timeout=timeout)
    resp.raise_for_status()

    header, rows = parse_tpex_o_data(resp.text)
    if not rows:
        return []

    # When header exists in Chinese:
    # 代號, 名稱, 收盤, 漲跌, 開盤, 最高, 最低, 成交股數, 成交金額(元), 成交筆數, ...
    # We'll index by common header names; if header missing, fallback to known positions.
    idx = {h.strip(): i for i, h in enumerate(header)} if header else {}

    def cell(r: List[str], key: str, pos: int) -> str:
        if idx and key in idx and idx[key] < len(r):
            return r[idx[key]]
        return r[pos] if pos < len(r) else ""

    out = []
    for r in rows:
        if not isinstance(r, list) or len(r) < 3:
            continue
        code = str(cell(r, "代號", 0)).strip()
        name = str(cell(r, "名稱", 1)).strip()

        close = safe_float(cell(r, "收盤", 2))
        # "漲跌" might be "+0.19" or "-0.10"
        chg = safe_float(cell(r, "漲跌", 3))
        open_ = safe_float(cell(r, "開盤", 4))
        high = safe_float(cell(r, "最高", 5))
        low = safe_float(cell(r, "最低", 6))
        vol = safe_float(cell(r, "成交股數", 7))
        val = safe_float(cell(r, "成交金額(元)", 8))

        cp = None
        if close is not None and chg is not None:
            prev = close - chg
            if prev and prev != 0:
                cp = (chg / prev) * 100.0

        out.append({
            "code": code,
            "name": name,
            "market": "TPEX",
            "close": close,
            "open": open_,
            "high": high,
            "low": low,
            "volume": vol,
            "turnover": val,
            "change_percent": cp,
        })
    return out


def build_rows_for_schema(schema: List[str], date_str: str, items: List[Dict[str, object]]) -> List[Dict[str, str]]:
    """
    Create rows that exactly match schema columns.
    Unknown columns -> empty string.
    """
    rows = []
    for it in items:
        row = {k: "" for k in schema}
        if "date" in row:
            row["date"] = date_str
        # common columns
        for k_src, k_dst in [
            ("code", "code"),
            ("name", "name"),
            ("market", "market"),
            ("sector", "sector"),
            ("close", "close"),
            ("open", "open"),
            ("high", "high"),
            ("low", "low"),
            ("volume", "volume"),
            ("turnover", "turnover"),
            ("change_percent", "change_percent"),
        ]:
            if k_dst in row and k_src in it and it[k_src] is not None:
                row[k_dst] = str(it[k_src])

        # derive change_percent if missing but have close/open (fallback)
        if ("change_percent" in row) and (row["change_percent"] == "" or row["change_percent"] is None):
            c = safe_float(row.get("close", ""))
            o = safe_float(row.get("open", ""))
            if c is not None and o is not None and o != 0:
                row["change_percent"] = str(round(((c - o) / o) * 100.0, 6))

        # total_score (required by portfolio backtest v3)
        if "total_score" in row:
            cp = safe_float(row.get("change_percent", ""))
            row["total_score"] = str(score_from_change_percent(cp))

        # If your schema expects something like "total_score" but named differently, we keep it as-is.
        rows.append(row)
    return rows


def append_rows(path: str, schema: List[str], rows: List[Dict[str, str]]) -> None:
    if not rows:
        return
    exists = os.path.exists(path)
    with open(path, "a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=schema)
        if not exists:
            w.writeheader()
        for r in rows:
            w.writerow(r)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True, help="YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD")
    ap.add_argument("--in_csv", default=r"data/all_stocks_daily.csv")
    ap.add_argument("--timeout", type=int, default=25)
    ap.add_argument("--sleep", type=float, default=0.6)
    ap.add_argument("--force", action="store_true", help="Backfill even if date exists already (appends anyway).")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    schema = read_header(args.in_csv)
    print(f"[INFO] schema cols={len(schema)}")

    start = ymd(args.start)
    end = ymd(args.end)
    if end < start:
        die("end < start")

    have = existing_dates(args.in_csv)
    produced_any = False

    for d in daterange(start, end):
        date_str = d.strftime("%Y-%m-%d")
        if (not args.force) and (date_str in have):
            print(f"[SKIP] {date_str} already exists")
            continue

        print(f"[DATE] {date_str}")

        twse = []
        tpex = []
        try:
            twse = fetch_twse_stock_day_all(d, timeout=args.timeout)
        except Exception as e:
            print(f"[WARN] TWSE fetch failed date={date_str}: {e}")
            if args.debug:
                raise

        try:
            tpex = fetch_tpex_daily_close(d, timeout=args.timeout)
        except Exception as e:
            print(f"[WARN] TPEX fetch failed date={date_str}: {e}")
            if args.debug:
                raise

        merged = []

        # Put both markets together; schema may have 'market' column, otherwise ignored.
        for it in twse:
            merged.append(it)
        for it in tpex:
            merged.append(it)

        if not merged:
            print(f"[WARN] No rows for {date_str} (holiday or endpoint returned empty)")
            time.sleep(max(0.0, args.sleep))
            continue

        rows = build_rows_for_schema(schema, date_str, merged)
        append_rows(args.in_csv, schema, rows)

        produced_any = True
        print(f"[OK] appended rows={len(rows)} -> {args.in_csv}")
        time.sleep(max(0.0, args.sleep))

    if not produced_any:
        raise RuntimeError("No backfill data produced for the given range. Try a wider range (or enable --debug).")


if __name__ == "__main__":
    main()