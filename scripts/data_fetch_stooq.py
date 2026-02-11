from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

import requests


# ----------------------------
# Helpers
# ----------------------------
TZ_TAIPEI = dt.timezone(dt.timedelta(hours=8))


def normalize_symbol(sym: str) -> str:
    s = (sym or "").strip().upper()
    if s.endswith(".TW"):
        s = s[:-3]
    if s.endswith(".TWO"):
        s = s[:-4]
    if s.isdigit():
        s = s.zfill(4)
    return s


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def months_ago_first_day(months: int) -> dt.date:
    today = dt.date.today()
    y = today.year
    m = today.month - months
    while m <= 0:
        y -= 1
        m += 12
    return dt.date(y, m, 1)


def is_html(text: str) -> bool:
    t = (text or "").lstrip().lower()
    return t.startswith("<!doctype html") or t.startswith("<html") or "<title>" in t[:400]


def looks_like_csv_header(line: str) -> bool:
    line = (line or "").strip().lower()
    return line.startswith("date,open,high,low,close,volume")


def safe_float(x: str) -> float:
    x = (x or "").strip()
    if x == "" or x.lower() in {"nan", "none", "null"}:
        return 0.0
    return float(x)


def parse_roc_date(s: str) -> dt.date:
    s = (s or "").strip()
    m = re.match(r"^(\d{2,3})/(\d{1,2})/(\d{1,2})$", s)
    if not m:
        raise ValueError(f"bad roc date: {s}")
    roc_y = int(m.group(1))
    month = int(m.group(2))
    day = int(m.group(3))
    ad_y = roc_y + 1911
    return dt.date(ad_y, month, day)


def write_ohlcv_csv(out_path: Path, rows: list[tuple[str, float, float, float, float, float]]) -> None:
    ensure_parent(out_path)
    with out_path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date", "open", "high", "low", "close", "volume"])
        for d, o, h, l, c, v in rows:
            w.writerow([d, f"{o:.4f}", f"{h:.4f}", f"{l:.4f}", f"{c:.4f}", f"{v:.4f}"])


def read_existing_last_date(path: Path) -> Optional[dt.date]:
    if not path.exists():
        return None
    try:
        with path.open("r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        if len(lines) < 2:
            return None
        last = lines[-1].split(",")[0].strip()
        return dt.date.fromisoformat(last)
    except Exception:
        return None


def count_rows(path: Path) -> int:
    if not path.exists():
        return 0
    with path.open("r", encoding="utf-8") as f:
        return max(0, sum(1 for _ in f) - 1)


@dataclass
class FetchResult:
    ok: bool
    provider: str
    rows: list[tuple[str, float, float, float, float, float]]
    reason: str = ""


# ----------------------------
# Providers
# ----------------------------
def fetch_stooq(symbol: str, timeout: int) -> FetchResult:
    sym = normalize_symbol(symbol).lower()
    url = f"https://stooq.com/q/d/l/?s={sym}.tw&i=d"

    print(f"[Fetch:stooq] GET {url}")
    try:
        r = requests.get(
            url,
            timeout=timeout,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
                "Accept": "text/csv,*/*",
            },
        )
    except Exception as e:
        return FetchResult(False, "stooq", [], f"request_failed:{type(e).__name__}")

    text = (r.text or "").strip()
    if not text:
        return FetchResult(False, "stooq", [], "empty_response")
    first = text.splitlines()[0].strip()
    if first.lower().startswith("no data"):
        print(f"[Fetch:stooq] unexpected first line: {first}")
        return FetchResult(False, "stooq", [], "no_data")

    lines = text.splitlines()
    if not lines or not looks_like_csv_header(lines[0]):
        return FetchResult(False, "stooq", [], "unexpected_csv_format")

    rows: list[tuple[str, float, float, float, float, float]] = []
    for line in lines[1:]:
        if not line.strip():
            continue
        parts = line.split(",")
        if len(parts) < 6:
            continue
        d = parts[0].strip()
        try:
            dt.date.fromisoformat(d)
        except Exception:
            continue
        try:
            o = safe_float(parts[1])
            h = safe_float(parts[2])
            l = safe_float(parts[3])
            c = safe_float(parts[4])
            v = safe_float(parts[5])
        except Exception:
            continue
        rows.append((d, o, h, l, c, v))

    if not rows:
        return FetchResult(False, "stooq", [], "parsed_zero_rows")
    return FetchResult(True, "stooq", rows, "")


def _twse_request_json(url: str, timeout: int) -> Tuple[Optional[dict], str]:
    try:
        r = requests.get(
            url,
            timeout=timeout,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
                "Accept": "application/json,text/plain,*/*",
                "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.8",
                "Referer": "https://www.twse.com.tw/",
            },
        )
    except Exception as e:
        return None, f"request_failed:{type(e).__name__}"

    raw = r.content
    try:
        txt = raw.decode("utf-8", errors="replace")
    except Exception:
        txt = str(raw[:200])

    if is_html(txt):
        return None, "html_blocked"

    lb = txt.find("{")
    rb = txt.rfind("}")
    if lb == -1 or rb == -1 or rb <= lb:
        return None, "non_json_response"

    try:
        return json.loads(txt[lb : rb + 1]), ""
    except Exception:
        return None, "json_decode_failed"


def fetch_twse(symbol: str, months: int, timeout: int, throttle_sec: float = 0.25, retries: int = 2) -> FetchResult:
    sym = normalize_symbol(symbol)
    start = months_ago_first_day(months)
    today = dt.date.today()

    ym_list: list[tuple[int, int]] = []
    y, m = start.year, start.month
    while (y, m) <= (today.year, today.month):
        ym_list.append((y, m))
        m += 1
        if m == 13:
            y += 1
            m = 1

    rows: list[tuple[str, float, float, float, float, float]] = []
    any_ok = False

    for (y, m) in ym_list:
        date_yyyymm01 = f"{y}{m:02d}01"
        urls = [
            f"https://www.twse.com.tw/exchangeReport/STOCK_DAY?response=json&date={date_yyyymm01}&stockNo={sym}",
            f"https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?response=json&date={date_yyyymm01}&stockNo={sym}",
        ]

        month_ok = False
        last_err = ""

        for u in urls:
            for attempt in range(retries + 1):
                j, err = _twse_request_json(u, timeout=timeout)
                if j is not None:
                    stat = str(j.get("stat", "")).strip()
                    data = j.get("data", None)

                    if stat and ("OK" not in stat.upper()):
                        last_err = f"stat:{stat}"
                        break
                    if not data or not isinstance(data, list):
                        last_err = "no_data_array"
                        break

                    parsed_this_month = 0
                    for item in data:
                        if not isinstance(item, list) or len(item) < 9:
                            continue
                        try:
                            d = parse_roc_date(str(item[0]).strip()).isoformat()
                            o = float(str(item[3]).replace(",", ""))
                            h = float(str(item[4]).replace(",", ""))
                            l = float(str(item[5]).replace(",", ""))
                            c = float(str(item[6]).replace(",", ""))
                            v = float(str(item[1]).replace(",", ""))
                        except Exception:
                            continue
                        rows.append((d, o, h, l, c, v))
                        parsed_this_month += 1

                    if parsed_this_month > 0:
                        any_ok = True
                        month_ok = True
                        break

                    last_err = "parsed_zero_rows"
                    break

                last_err = err
                time.sleep(0.4 * (attempt + 1))

            if month_ok:
                break

        if not month_ok:
            print(f"[Fetch:twse] error {y}{m:02d}: {last_err}")

        time.sleep(throttle_sec)

    if rows:
        rows = list({r[0]: r for r in rows}.values())
        rows.sort(key=lambda x: x[0])

    if not any_ok or not rows:
        return FetchResult(False, "twse", [], "twse_no_data")

    return FetchResult(True, "twse", rows, "")


def _yahoo_chart_json(ticker: str, start: int, end: int, timeout: int) -> Tuple[Optional[dict], str]:
    url = (
        f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}"
        f"?period1={start}&period2={end}&interval=1d&events=history"
    )
    print(f"[Fetch:yahoo] GET {url}")

    try:
        r = requests.get(
            url,
            timeout=timeout,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
                "Accept": "application/json,text/plain,*/*",
            },
        )
    except Exception as e:
        return None, f"request_failed:{type(e).__name__}"

    txt = (r.text or "").strip()
    if not txt:
        return None, "empty_response"
    if is_html(txt):
        return None, "html_blocked"

    lb = txt.find("{")
    rb = txt.rfind("}")
    if lb == -1 or rb == -1 or rb <= lb:
        return None, "non_json_response"

    try:
        return json.loads(txt[lb : rb + 1]), ""
    except Exception:
        return None, "json_decode_failed"


def fetch_yahoo(symbol: str, months: int, timeout: int) -> FetchResult:
    sym = normalize_symbol(symbol)
    ticker = f"{sym}.TW"

    end = int(time.time())
    start_date = dt.date.today() - dt.timedelta(days=int(months * 31))
    start = int(time.mktime(start_date.timetuple()))

    j, err = _yahoo_chart_json(ticker, start=start, end=end, timeout=timeout)
    if j is None:
        return FetchResult(False, "yahoo", [], err)

    try:
        chart = j.get("chart", {})
        if chart.get("error"):
            return FetchResult(False, "yahoo", [], f"chart_error:{chart['error']}")
        result = (chart.get("result") or [None])[0]
        if not result:
            return FetchResult(False, "yahoo", [], "no_result")

        timestamps = result.get("timestamp") or []
        indicators = ((result.get("indicators") or {}).get("quote") or [None])[0] or {}
        opens = indicators.get("open") or []
        highs = indicators.get("high") or []
        lows = indicators.get("low") or []
        closes = indicators.get("close") or []
        volumes = indicators.get("volume") or []
    except Exception:
        return FetchResult(False, "yahoo", [], "parse_failed")

    n = min(len(timestamps), len(opens), len(highs), len(lows), len(closes), len(volumes))
    if n <= 0:
        return FetchResult(False, "yahoo", [], "parsed_zero_rows")

    rows: list[tuple[str, float, float, float, float, float]] = []
    for i in range(n):
        ts = timestamps[i]
        if ts is None:
            continue
        d = dt.datetime.fromtimestamp(int(ts), tz=dt.timezone.utc).date().isoformat()

        o = 0.0 if opens[i] is None else float(opens[i])
        h = 0.0 if highs[i] is None else float(highs[i])
        l = 0.0 if lows[i] is None else float(lows[i])
        c = 0.0 if closes[i] is None else float(closes[i])
        v = 0.0 if volumes[i] is None else float(volumes[i])

        if c == 0.0 and o == 0.0 and h == 0.0 and l == 0.0:
            continue

        rows.append((d, o, h, l, c, v))

    if not rows:
        return FetchResult(False, "yahoo", [], "parsed_zero_rows")

    # sort + de-dup
    rows = list({r[0]: r for r in rows}.values())
    rows.sort(key=lambda x: x[0])

    # v4.8: clean placeholder tail bars even if it's "yesterday" (recent window)
    # placeholder pattern: volume=0 AND OHLC all equal
    # remove if within last 7 days (to avoid killing ancient weird data)
    now_taipei = dt.datetime.now(tz=TZ_TAIPEI)
    today_taipei = now_taipei.date()
    recent_cutoff = today_taipei - dt.timedelta(days=7)

    removed = 0
    while len(rows) >= 2:
        d, o, h, l, c, v = rows[-1]
        try:
            bd = dt.date.fromisoformat(d)
        except Exception:
            break
        if bd < recent_cutoff:
            break
        if v == 0.0 and o == h == l == c:
            rows.pop()
            removed += 1
            continue
        break

    if removed > 0:
        print(f"[Fetch:yahoo] cleaned tail placeholder bars={removed}; new_last={rows[-1][0]}")

    return FetchResult(True, "yahoo", rows, "")


# ----------------------------
# CLI
# ----------------------------
def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Fetch TW OHLCV data (providers chain)")
    ap.add_argument("--symbol", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--months", type=int, default=36)
    ap.add_argument("--timeout", type=int, default=15)

    ap.add_argument("--providers", default="stooq,yahoo,twse", help="Comma list: stooq,yahoo,twse")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--min_rows", type=int, default=200)

    return ap.parse_args()


def main() -> int:
    args = parse_args()
    sym = normalize_symbol(args.symbol)
    out = Path(args.out)
    months = int(args.months)
    timeout = int(args.timeout)
    min_rows = int(args.min_rows)
    force = bool(args.force)

    existing_last = read_existing_last_date(out)
    existing_rows = count_rows(out)

    providers = [p.strip().lower() for p in str(args.providers).split(",") if p.strip()]
    if not providers:
        providers = ["stooq", "yahoo", "twse"]

    last_fail = ""
    res: Optional[FetchResult] = None

    for p in providers:
        if p == "stooq":
            res = fetch_stooq(sym, timeout=timeout)
            if res.ok:
                break
            print(f"[Fetch:stooq] failed: {res.reason}")
            last_fail = f"stooq:{res.reason}"

        elif p == "yahoo":
            res = fetch_yahoo(sym, months=months, timeout=timeout)
            if res.ok:
                break
            print(f"[Fetch:yahoo] failed: {res.reason}")
            last_fail = f"yahoo:{res.reason}"

        elif p == "twse":
            print(f"[Fetch:twse] fallback for {sym}, months={months}")
            res = fetch_twse(sym, months=months, timeout=timeout)
            if res.ok:
                break
            print(f"[Fetch:twse] failed: {res.reason}")
            last_fail = f"twse:{res.reason}"

        else:
            print(f"[WARN] unknown provider ignored: {p}")

    if res is None or not res.ok:
        print(f"[ERROR] fetch failed for {sym}: {last_fail or 'no_provider_succeeded'}")
        return 1

    rows = res.rows
    if not rows:
        print(f"[ERROR] fetched empty rows for {sym} via={res.provider}")
        return 1

    last_date = dt.date.fromisoformat(rows[-1][0])
    fetched_n = len(rows)

    # acceptance rules
    if (not force) and fetched_n < min_rows:
        print(f"[WARN] fetch rejected for {sym} (too_few_rows:{fetched_n} < {min_rows}); keeping existing file: {out}")
        return 1

    # prevent stale/partial overwrite unless force
    if (not force) and existing_last is not None:
        if last_date < existing_last:
            print(f"[WARN] fetch rejected for {sym} (stale_last:{last_date} < existing_last:{existing_last}); keeping existing file: {out}")
            return 1
        if fetched_n < existing_rows:
            print(f"[WARN] fetch rejected for {sym} (partial_rows:{fetched_n} < existing_rows:{existing_rows}); keeping existing file: {out}")
            return 1

    write_ohlcv_csv(out, rows)
    print(f"OK fetched {sym} -> {out} rows={fetched_n} via={res.provider}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
