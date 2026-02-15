#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
market_pack_v1.py (robust)
- Reads all_stocks_daily.csv (or any CSV with a date column)
- Detects latest date robustly (handles BOM/whitespace/case)
- Writes:
    market_snapshot_YYYY-MM-DD.json
    sector_heat_YYYY-MM-DD.json
Args (kept compatible with run_dashboard.ps1):
  --in <csv>
  --outdir <dir>
  --sector_map <csv> (optional, not required)
"""

import argparse, csv, json, os, re, sys
from datetime import datetime
from collections import defaultdict

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

def norm(s):
  if s is None:
    return ""
  return str(s).strip()

def parse_date(s):
  s = norm(s)
  if not s:
    return None
  # strip quotes
  if len(s) >= 2 and ((s[0] == s[-1] == '"') or (s[0] == s[-1] == "'")):
    s = s[1:-1].strip()
  if DATE_RE.match(s):
    try:
      return datetime.strptime(s, "%Y-%m-%d").date()
    except Exception:
      return None
  # try ISO prefix (e.g., 2026-02-11 00:00:00)
  m = re.match(r"^(\d{4}-\d{2}-\d{2})", s)
  if m:
    try:
      return datetime.strptime(m.group(1), "%Y-%m-%d").date()
    except Exception:
      return None
  return None

def find_date_key(fieldnames):
  if not fieldnames:
    return None
  # handle BOM on first column
  fns = [fn.lstrip("\ufeff").strip() for fn in fieldnames]
  # exact match
  for cand in ("date", "Date", "datetime", "Datetime", "dt", "DT"):
    for i, fn in enumerate(fns):
      if fn == cand:
        return fieldnames[i]
  # case-insensitive contains 'date'
  for i, fn in enumerate(fns):
    if "date" == fn.lower():
      return fieldnames[i]
  for i, fn in enumerate(fns):
    if "date" in fn.lower():
      return fieldnames[i]
  # fallback: first column
  return fieldnames[0]

def safe_float(v, default=0.0):
  try:
    if v is None: return default
    s = norm(v)
    if s == "": return default
    return float(s)
  except Exception:
    return default

def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--in", dest="inp", required=True)
  ap.add_argument("--outdir", required=True)
  ap.add_argument("--sector_map", default="")
  args = ap.parse_args()

  inp = args.inp
  outdir = args.outdir

  if not os.path.exists(inp):
    print(f"Input not found: {inp}", file=sys.stderr)
    return 2

  os.makedirs(outdir, exist_ok=True)

  # read CSV
  rows = []
  with open(inp, "r", encoding="utf-8-sig", newline="") as f:
    r = csv.DictReader(f)
    if not r.fieldnames:
      print("No header found in input CSV.", file=sys.stderr)
      return 3
    date_key = find_date_key(r.fieldnames)
    for row in r:
      rows.append(row)

  if not rows:
    print("No rows in input CSV.", file=sys.stderr)
    return 4

  # find latest date
  dates = []
  for row in rows:
    d = parse_date(row.get(date_key, ""))
    if d:
      dates.append(d)

  if not dates:
    # show debug clues
    sample = rows[0].get(date_key, "")
    print("No date found in input CSV.", file=sys.stderr)
    print(f"[DEBUG] date_key={date_key!r} sample_value={sample!r}", file=sys.stderr)
    print(f"[DEBUG] header={list(rows[0].keys())}", file=sys.stderr)
    return 5

  latest = max(dates)
  latest_s = latest.strftime("%Y-%m-%d")

  # filter rows for latest date (allow raw string match too)
  latest_rows = []
  for row in rows:
    d = parse_date(row.get(date_key, ""))
    if d and d == latest:
      latest_rows.append(row)

  if not latest_rows:
    print("Date parsed but zero rows matched latest date (unexpected).", file=sys.stderr)
    return 6

  # compute sector heat (avg total_score by sector)
  by_sector_sum = defaultdict(float)
  by_sector_cnt = defaultdict(int)

  # score key guess
  score_keys = ["total_score", "score", "TotalScore", "totalScore"]
  sector_keys = ["sector", "Sector", "industry", "Industry", "類股", "產業"]

  def pick_key(row, keys, default=""):
    for k in keys:
      if k in row and norm(row.get(k)) != "":
        return k
    return default

  score_key = pick_key(latest_rows[0], score_keys, "total_score")
  sector_key = pick_key(latest_rows[0], sector_keys, "sector")

  # snapshot stats
  n = 0
  n_ge_70 = 0
  n_ge_50 = 0
  score_sum = 0.0

  for row in latest_rows:
    n += 1
    sc = safe_float(row.get(score_key), 0.0)
    score_sum += sc
    if sc >= 70: n_ge_70 += 1
    if sc >= 50: n_ge_50 += 1

    sec = norm(row.get(sector_key, "unknown")) or "unknown"
    by_sector_sum[sec] += sc
    by_sector_cnt[sec] += 1

  avg_score = score_sum / n if n else 0.0
  sector_items = []
  for sec, cnt in by_sector_cnt.items():
    sector_items.append({
      "sector": sec,
      "n": cnt,
      "avg_score": (by_sector_sum[sec] / cnt) if cnt else 0.0
    })
  sector_items.sort(key=lambda x: x["avg_score"], reverse=True)

  market_snapshot = {
    "date": latest_s,
    "n": n,
    "avg_score": round(avg_score, 4),
    "n_score_ge_70": n_ge_70,
    "n_score_ge_50": n_ge_50,
    "breadth_ge_70": round(n_ge_70 / n, 6) if n else 0.0,
    "breadth_ge_50": round(n_ge_50 / n, 6) if n else 0.0,
    "score_key": score_key,
    "sector_key": sector_key,
    "version": "market_pack_v1_robust"
  }

  out_snapshot = os.path.join(outdir, f"market_snapshot_{latest_s}.json")
  out_sector   = os.path.join(outdir, f"sector_heat_{latest_s}.json")

  with open(out_snapshot, "w", encoding="utf-8") as f:
    json.dump(market_snapshot, f, ensure_ascii=False, indent=2)
  with open(out_sector, "w", encoding="utf-8") as f:
    json.dump({"date": latest_s, "items": sector_items, "version": "sector_heat_v1_robust"}, f, ensure_ascii=False, indent=2)

  print(out_sector)
  print(out_snapshot)
  print(f"OK: market_pack wrote snapshot+sector_heat for date={latest_s}")

  return 0

if __name__ == "__main__":
  sys.exit(main())