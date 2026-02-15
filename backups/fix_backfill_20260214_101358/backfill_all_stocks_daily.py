# -*- coding: utf-8 -*-
"""
Backfill all_stocks_daily.csv by reusing existing build_all_stocks_daily_from_universe.py.

Strategy:
- Inspect builder help text (-h) to detect which date argument it supports.
- For each day in [start, end], call builder; after each run, copy data/all_stocks_daily.csv to data/backfill_tmp/all_stocks_daily_<date>.csv
- Merge all backfilled daily files into data/all_stocks_daily.csv (multi-date).

This avoids rewriting your stable builder.

Usage:
python scripts/backfill_all_stocks_daily.py --start 2025-08-01 --end 2026-02-11 --py .venv/Scripts/python.exe
"""
from __future__ import annotations
import argparse
import os
import re
import shutil
import subprocess
from datetime import datetime, timedelta
import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILDER = os.path.join(ROOT, "scripts", "build_all_stocks_daily_from_universe.py")
OUT_MAIN = os.path.join(ROOT, "data", "all_stocks_daily.csv")
TMP_DIR = os.path.join(ROOT, "data", "backfill_tmp")

def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
    return p.returncode, out

def detect_date_arg(py: str) -> str:
    code, out = run([py, BUILDER, "-h"])
    if code != 0:
        raise RuntimeError("Builder -h failed:\n" + out)

    # try common patterns
    candidates = [
        "--date", "--Date",
        "--target-date", "--target_date",
        "--ymd", "--Ymd",
        "--yyyymmdd", "--YYYYMMDD",
        "--day", "--Day",
    ]
    # match tokens like: "  --date DATE"
    for c in candidates:
        if re.search(r"\s" + re.escape(c) + r"(\s|,)", out):
            return c

    # fallback: search for any option containing "date"
    m = re.search(r"(\-\-[A-Za-z0-9\-_]*date[A-Za-z0-9\-_]*)", out)
    if m:
        return m.group(1)

    raise RuntimeError("Cannot detect date argument from builder -h.\nPlease open builder help output.")

def daterange(start: str, end: str):
    s = datetime.strptime(start, "%Y-%m-%d").date()
    e = datetime.strptime(end, "%Y-%m-%d").date()
    d = s
    while d <= e:
        # only weekdays; builder itself should still validate trading days
        if d.weekday() < 5:
            yield d
        d += timedelta(days=1)

def read_csv_safe(path: str) -> pd.DataFrame:
    try:
        return pd.read_csv(path, dtype={"code": str})
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype={"code": str})

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True, help="YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD")
    ap.add_argument("--py", default="", help="python executable path")
    ap.add_argument("--max_days", type=int, default=9999, help="safety limit")
    ap.add_argument("--dry_run", action="store_true")
    args = ap.parse_args()

    py = args.py.strip() or "python"
    if not os.path.exists(BUILDER):
        raise FileNotFoundError("Missing builder: " + BUILDER)

    os.makedirs(TMP_DIR, exist_ok=True)

    date_arg = detect_date_arg(py)
    print(f"[INFO] detected builder date arg: {date_arg}")

    done = 0
    for d in daterange(args.start, args.end):
        if done >= args.max_days:
            print("[WARN] hit max_days, stop.")
            break

        date_str = d.strftime("%Y-%m-%d")
        tmp_out = os.path.join(TMP_DIR, f"all_stocks_daily_{date_str}.csv")

        if os.path.exists(tmp_out):
            print(f"[SKIP] exists -> {os.path.relpath(tmp_out, ROOT)}")
            done += 1
            continue

        cmd = [py, BUILDER, date_arg, date_str]
        print("[RUN] " + " ".join(cmd))

        if args.dry_run:
            done += 1
            continue

        code, out = run(cmd)
        if code != 0:
            print("[FAIL] builder returned non-zero for date=" + date_str)
            print(out[:2000])
            # do not stop whole backfill; continue
            done += 1
            continue

        if not os.path.exists(OUT_MAIN):
            print("[FAIL] builder did not produce data/all_stocks_daily.csv for date=" + date_str)
            print(out[:2000])
            done += 1
            continue

        # Copy the produced file as this date snapshot
        shutil.copyfile(OUT_MAIN, tmp_out)
        print(f"[OK] saved -> {os.path.relpath(tmp_out, ROOT)}")
        done += 1

    # Merge phase
    files = sorted([os.path.join(TMP_DIR, f) for f in os.listdir(TMP_DIR) if f.lower().endswith(".csv")])
    if not files:
        raise RuntimeError("No backfill daily files were produced in data/backfill_tmp")

    frames = []
    for f in files:
        df = read_csv_safe(f)
        if "date" not in df.columns:
            # If builder doesn't include date, infer from filename
            base = os.path.basename(f)
            m = re.search(r"(\d{4}\-\d{2}\-\d{2})", base)
            if m:
                df["date"] = m.group(1)
        frames.append(df)

    all_df = pd.concat(frames, ignore_index=True)

    # normalize date string
    all_df["date"] = all_df["date"].astype(str)

    # drop duplicates by (date, code) keep last
    if "code" in all_df.columns:
        all_df = all_df.sort_values(["date","code"]).drop_duplicates(["date","code"], keep="last")

    # write multi-date
    os.makedirs(os.path.dirname(OUT_MAIN) or ".", exist_ok=True)
    all_df.to_csv(OUT_MAIN, index=False, encoding="utf-8-sig")
    print(f"[DONE] merged -> data/all_stocks_daily.csv (dates={all_df['date'].nunique()}, rows={len(all_df)})")

if __name__ == "__main__":
    main()