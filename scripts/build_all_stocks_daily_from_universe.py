# -*- coding: utf-8 -*-
"""
Build data/all_stocks_daily.csv from data/universe_stock.csv using TWSE/TPEx sources.

FIXES:
1) Output "date" is trading date (prefer market_snapshot_taiex.json date).
2) TPEx is OPTIONAL: if TPEx endpoint/format changes, still output TWSE rows.
3) Save raw snapshots for TWSE/TPEx to data/cache for debugging.
4) IMPORTANT: universe_stock.csv may be UTF-8 BOM (PowerShell) -> use utf-8-sig + header fallback.
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

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(DATA, "cache")
CACHE_TWSE = os.path.join(CACHE, "twse")
CACHE_TPEX = os.path.join(CACHE, "tpex")

UNIVERSE_STOCK = os.path.join(DATA, "universe_stock.csv")
OUT_OK = os.path.join(DATA, "all_stocks_daily.csv")
OUT_FAIL = os.path.join(DATA, "all_stocks_daily_fail.csv")
MARKET_SNAPSHOT = os.path.join(DATA, "market_snapshot_taiex.json")

def ensure_dir(p: str) -> None:
    os.makedirs(p, exist_ok=True)

def safe_float(s, default=0.0):
    try:
        if s is None:
            return default
        t = str(s).strip().replace(",", "")
        if t == "":
            return default
        t = t.replace("<p style ='color:red'>+</p>", "").replace("<p style ='color:green'>-</p>", "")
        t = t.replace("+", "").replace("%", "")
        return float(t)
    except:
        return default

def safe_str(s) -> str:
    return "" if s is None else str(s).strip()

def last_business_day(d: dt.date) -> dt.date:
    while d.weekday() >= 5:
        d = d - dt.timedelta(days=1)
    return d

def read_market_snapshot_date(path: str) -> str | None:
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            js = json.load(f)
        ds = js.get("date")
        if ds and isinstance(ds, str) and len(ds) == 10:
            return ds
        return None
    except:
        return None

def pick_trading_date() -> str:
    ds = read_market_snapshot_date(MARKET_SNAPSHOT)
    if ds:
        return ds
    d = last_business_day(dt.date.today())
    return d.strftime("%Y-%m-%d")

def _pick_key(row: dict, wanted: str) -> str | None:
    """header fallback: handle BOM / weird headers by suffix match"""
    if wanted in row:
        return wanted
    lw = wanted.lower()
    for k in row.keys():
        if k is None:
            continue
        ks = str(k).strip()
        if ks.lower().endswith(lw):
            return k
    return None

def load_universe_stock(path: str) -> list[dict]:
    if not os.path.exists(path):
        raise RuntimeError(f"Missing file: {path}")

    rows = []
    # utf-8-sig removes BOM from header (PowerShell often writes BOM CSV)
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            k_code = _pick_key(row, "code")
            k_name = _pick_key(row, "name")
            k_sector = _pick_key(row, "sector")
            k_market = _pick_key(row, "market")

            code = safe_str(row.get(k_code) if k_code else "")
            if not code:
                continue

            rows.append({
                "code": code,
                "name": safe_str(row.get(k_name) if k_name else ""),
                "sector": safe_str(row.get(k_sector) if k_sector else ""),
                "market": safe_str(row.get(k_market) if k_market else ""),  # TWSE / TPEX / blank
            })
    return rows

def http_get_json(url: str, timeout: int = 20, referer: str = "") -> dict:
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
        "Accept": "application/json,text/plain,*/*",
    }
    if referer:
        headers["Referer"] = referer

    req = Request(url, headers=headers, method="GET")
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except (HTTPError, URLError) as e:
        raise RuntimeError(f"HTTP failed: {repr(e)}")

    try:
        return json.loads(raw)
    except Exception as e:
        raise RuntimeError(f"JSON parse failed: {repr(e)}; head={raw[:120]!r}")

def fetch_twse_stock_day_all(date_yyyymmdd: str, timeout: int = 20) -> dict:
    url = f"https://www.twse.com.tw/exchangeReport/STOCK_DAY_ALL?response=json&date={date_yyyymmdd}"
    return http_get_json(url, timeout=timeout, referer="https://www.twse.com.tw/")

def fetch_tpex_stock_day_all(date_yyyymmdd: str, timeout: int = 20) -> dict:
    y = int(date_yyyymmdd[0:4]); m = int(date_yyyymmdd[4:6]); d = int(date_yyyymmdd[6:8])
    roc_y = y - 1911
    roc = f"{roc_y}/{m:02d}/{d:02d}"
    url = f"https://www.tpex.org.tw/web/stock/aftertrading/daily_close_quotes/stk_quote_result.php?l=zh-tw&d={roc}"
    return http_get_json(url, timeout=timeout, referer="https://www.tpex.org.tw/")

def parse_twse_map(js: dict) -> dict[str, dict]:
    data = js.get("data")
    if not data or not isinstance(data, list):
        raise RuntimeError("TWSE json missing data")
    out = {}
    for row in data:
        if not row or len(row) < 8:
            continue
        code = safe_str(row[0])
        if not code:
            continue
        out[code] = {
            "open": safe_float(row[4], 0.0),
            "high": safe_float(row[5], 0.0),
            "low":  safe_float(row[6], 0.0),
            "close": safe_float(row[7], 0.0),
            "volume": safe_float(row[2], 0.0),
        }
    return out

def _parse_tpex_rows_to_map(rows: list) -> dict[str, dict]:
    out = {}
    for row in rows:
        if not row or len(row) < 6:
            continue
        code = safe_str(row[0])
        if not code:
            continue
        close = safe_float(row[2], 0.0) if len(row) > 2 else 0.0
        open_ = safe_float(row[4], 0.0) if len(row) > 4 else 0.0
        high  = safe_float(row[5], 0.0) if len(row) > 5 else 0.0
        low   = safe_float(row[6], 0.0) if len(row) > 6 else 0.0
        vol   = safe_float(row[8], 0.0) if len(row) > 8 else 0.0
        out[code] = {"open": open_, "high": high, "low": low, "close": close, "volume": vol}
    return out

def parse_tpex_map(js: dict) -> dict[str, dict]:
    if isinstance(js, dict):
        if isinstance(js.get("aaData"), list):
            return _parse_tpex_rows_to_map(js["aaData"])
        if isinstance(js.get("data"), list):
            return _parse_tpex_rows_to_map(js["data"])
        if isinstance(js.get("tables"), list) and js["tables"]:
            t0 = js["tables"][0]
            if isinstance(t0, dict) and isinstance(t0.get("data"), list):
                return _parse_tpex_rows_to_map(t0["data"])
        keys = list(js.keys())
        raise RuntimeError(f"TPEx json missing rows (aaData/data/tables). keys={keys}")
    raise RuntimeError("TPEx json is not a dict")

def compute_change_percent(open_: float, close: float) -> float:
    if open_ <= 0:
        return 0.0
    return (close - open_) / open_ * 100.0

def score_placeholder(change_percent: float) -> float:
    cp = max(-10.0, min(10.0, change_percent))
    return 65.0 + (cp * 2.0)

def write_csv(path: str, rows: list[dict], fields: list[str]) -> None:
    ensure_dir(os.path.dirname(path))
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

def dump_json(path: str, js: dict) -> None:
    ensure_dir(os.path.dirname(path))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(js, f, ensure_ascii=False, indent=2)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--sleep", type=float, default=0.4)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    trading_date = pick_trading_date()
    yyyymmdd = trading_date.replace("-", "")

    ensure_dir(CACHE_TWSE)
    ensure_dir(CACHE_TPEX)

    # TWSE
    twse_raw_path = os.path.join(CACHE_TWSE, f"_twse_stock_day_all_{yyyymmdd}.json")
    if (not args.force) and os.path.exists(twse_raw_path):
        with open(twse_raw_path, "r", encoding="utf-8") as f:
            twse_js = json.load(f)
    else:
        twse_js = fetch_twse_stock_day_all(yyyymmdd, timeout=args.timeout)
        dump_json(twse_raw_path, twse_js)
    twse_map = parse_twse_map(twse_js)

    # TPEx optional
    tpex_map = {}
    tpex_err = None
    tpex_raw_path = os.path.join(CACHE_TPEX, f"_tpex_stock_day_all_{yyyymmdd}.json")
    try:
        time.sleep(max(0.0, args.sleep))
        if (not args.force) and os.path.exists(tpex_raw_path):
            with open(tpex_raw_path, "r", encoding="utf-8") as f:
                tpex_js = json.load(f)
        else:
            tpex_js = fetch_tpex_stock_day_all(yyyymmdd, timeout=args.timeout)
            dump_json(tpex_raw_path, tpex_js)
        tpex_map = parse_tpex_map(tpex_js)
    except Exception as e:
        tpex_err = repr(e)
        try:
            dbg_path = os.path.join(CACHE_TPEX, f"_tpex_parse_fail_{yyyymmdd}.txt")
            ensure_dir(os.path.dirname(dbg_path))
            with open(dbg_path, "w", encoding="utf-8") as f:
                f.write("TPEx parse failed:\n")
                f.write(tpex_err + "\n")
                if os.path.exists(tpex_raw_path):
                    f.write(f"\nraw_saved={tpex_raw_path}\n")
        except:
            pass

    uni = load_universe_stock(UNIVERSE_STOCK)
    if args.limit and args.limit > 0:
        uni = uni[: args.limit]

    ok_rows = []
    fail_rows = []

    for it in uni:
        code = it["code"]
        name = it["name"]
        sector = it["sector"]
        market = (it.get("market") or "").upper()

        try:
            src = None
            rec = None

            if market == "TPEX":
                if not tpex_map:
                    raise KeyError(f"tpex_unavailable:{tpex_err}")
                rec = tpex_map.get(code)
                if rec is None:
                    raise KeyError("tpex_missing")
                src = "tpex"
            else:
                rec = twse_map.get(code)
                if rec is None:
                    if tpex_map:
                        rec2 = tpex_map.get(code)
                        if rec2 is None:
                            raise KeyError("twse_missing")
                        rec = rec2
                        src = "tpex"
                    else:
                        raise KeyError("twse_missing")
                else:
                    src = "twse"

            o = float(rec["open"]); h = float(rec["high"]); l = float(rec["low"]); c = float(rec["close"])
            v = float(rec.get("volume", 0.0))

            cp = compute_change_percent(o, c)
            score = score_placeholder(cp)

            ok_rows.append({
                "date": trading_date,
                "code": code,
                "name": name,
                "sector": sector,
                "change_percent": cp,
                "total_score": score,
                "source": src,
                "open": o, "high": h, "low": l, "close": c, "volume": v,
            })
        except Exception as e:
            fail_rows.append({
                "code": code,
                "name": name,
                "sector": sector,
                "error": repr(e),
            })

    fields_ok = ["date","code","name","sector","change_percent","total_score","source","open","high","low","close","volume"]
    fields_fail = ["code","name","sector","error"]

    write_csv(OUT_OK, ok_rows, fields_ok)
    write_csv(OUT_FAIL, fail_rows, fields_fail)

    print(f"OK: wrote {OUT_OK} rows={len(ok_rows)} date={trading_date}")
    print(f"OK: wrote {OUT_FAIL} rows={len(fail_rows)}")

    if tpex_err:
        print(f"[WARN] TPEx optional disabled this run: {tpex_err}")
        print(f"[WARN] See: {os.path.join(CACHE_TPEX, f'_tpex_parse_fail_{yyyymmdd}.txt')}")

    # quick universe sanity
    print(f"[INFO] universe_stock loaded rows={len(uni)} (first_code={(uni[0]['code'] if len(uni)>0 else 'N/A')})")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())