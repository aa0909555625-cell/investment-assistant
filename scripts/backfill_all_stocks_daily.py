# -*- coding: utf-8 -*-
"""
Backfill all_stocks_daily.csv by reusing existing build_all_stocks_daily_from_universe.py.

This version supports builders that:
A) accept a --date-like flag
B) accept date as positional argument
C) accept NO date at all (always builds latest)  -> backfill will not be possible (we will detect and stop)

Process:
- Determine call mode by probing one test date.
- For each day in [start, end], call builder; after each run, copy data/all_stocks_daily.csv to data/backfill_tmp/all_stocks_daily_<date>.csv
- Merge all backfilled daily files into data/all_stocks_daily.csv (multi-date).

Usage:
python scripts/backfill_all_stocks_daily.py --start 2025-11-15 --end 2026-02-11 --py .venv/Scripts/python.exe
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

def read_csv_safe(path: str) -> pd.DataFrame:
    try:
        return pd.read_csv(path, dtype={"code": str})
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype={"code": str})

def try_build(py: str, cmd: list[str], expect_date: str) -> bool:
    """
    Run builder command, then check if OUT_MAIN exists and contains expect_date in 'date' column.
    """
    code, out = run(cmd)
    if code != 0:
        return False
    if not os.path.exists(OUT_MAIN):
        return False
    try:
        df = read_csv_safe(OUT_MAIN)
        if "date" not in df.columns:
            # still accept, we'll infer later, but for detection we need date presence
            return False
        dates = set(df["date"].astype(str).unique().tolist())
        return (str(expect_date) in dates)
    except Exception:
        return False

def detect_call_mode(py: str, test_date: str) -> tuple[str, str]:
    """
    Returns:
      ("flag", "--date") or ("positional","") or ("nodate","")
    """
    # 1) parse -h output and try common flags
    code, help_out = run([py, BUILDER, "-h"])
    # some scripts exit 0/1 with help; both ok for parsing
    candidates = ["--date","--target-date","--ymd","--day","--trade-date","--tradedate","--asof","--as_of"]
    found_flags = []
    for c in candidates:
        if re.search(r"\s" + re.escape(c) + r"(\s|,)", help_out):
            found_flags.append(c)

    # try found flags first
    for f in found_flags:
        cmd = [py, BUILDER, f, test_date]
        if try_build(py, cmd, test_date):
            return ("flag", f)

    # 2) try common flags even if not shown (some scripts hide args)
    for f in candidates:
        cmd = [py, BUILDER, f, test_date]
        if try_build(py, cmd, test_date):
            return ("flag", f)

    # 3) try positional date
    cmd = [py, BUILDER, test_date]
    if try_build(py, cmd, test_date):
        return ("positional", "")

    # 4) no-date builder (always latest) detection:
    # run without date, see if output exists but DOES NOT match test_date
    code2, out2 = run([py, BUILDER])
    if code2 == 0 and os.path.exists(OUT_MAIN):
        try:
            df = read_csv_safe(OUT_MAIN)
            if "date" in df.columns:
                dates = set(df["date"].astype(str).unique().tolist())
                if test_date not in dates:
                    return ("nodate", "")
        except Exception:
            pass

    raise RuntimeError(
        "Cannot determine builder call mode.\n"
        "Tried: --date flags, positional date, and no-date mode.\n"
        "Tip: run builder manually once with a past date to see how it accepts date."
    )

def daterange_weekdays(start: str, end: str):
    s = datetime.strptime(start, "%Y-%m-%d").date()
    e = datetime.strptime(end, "%Y-%m-%d").date()
    d = s
    while d <= e:
        if d.weekday() < 5:
            yield d
        d += timedelta(days=1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--py", default="")
    ap.add_argument("--max_days", type=int, default=9999)
    ap.add_argument("--dry_run", action="store_true")
    args = ap.parse_args()

    py = args.py.strip() or "python"
    if not os.path.exists(BUILDER):
        raise FileNotFoundError("Missing builder: " + BUILDER)

    os.makedirs(TMP_DIR, exist_ok=True)

    # use end date as probe (most likely to exist)
    mode, flag = detect_call_mode(py, args.end)
    print(f"[INFO] builder mode={mode} flag={flag}")

    if mode == "nodate":
        raise RuntimeError(
            "Builder appears to NOT accept a date argument (always builds latest).\n"
            "Backfill cannot proceed until builder supports date (flag or positional)."
        )

    done = 0
    for d in daterange_weekdays(args.start, args.end):
        if done >= args.max_days:
            print("[WARN] hit max_days, stop.")
            break

        date_str = d.strftime("%Y-%m-%d")
        tmp_out = os.path.join(TMP_DIR, f"all_stocks_daily_{date_str}.csv")
        if os.path.exists(tmp_out):
            print(f"[SKIP] exists -> {os.path.relpath(tmp_out, ROOT)}")
            done += 1
            continue

        if mode == "flag":
            cmd = [py, BUILDER, flag, date_str]
        else:
            cmd = [py, BUILDER, date_str]

        print("[RUN] " + " ".join(cmd))
        if args.dry_run:
            done += 1
            continue

        code, out = run(cmd)
        if code != 0:
            print(f"[FAIL] date={date_str} exit={code}")
            print(out[:2000])
            done += 1
            continue

        if not os.path.exists(OUT_MAIN):
            print(f"[FAIL] builder did not produce data/all_stocks_daily.csv for date={date_str}")
            print(out[:2000])
            done += 1
            continue

        shutil.copyfile(OUT_MAIN, tmp_out)
        print(f"[OK] saved -> {os.path.relpath(tmp_out, ROOT)}")
        done += 1

    files = sorted([os.path.join(TMP_DIR, f) for f in os.listdir(TMP_DIR) if f.lower().endswith(".csv")])
    if not files:
        raise RuntimeError("No backfill daily files were produced in data/backfill_tmp")

    frames = []
    for f in files:
        df = read_csv_safe(f)
        if "date" not in df.columns:
            base = os.path.basename(f)
            m = re.search(r"(\d{4}\-\d{2}\-\d{2})", base)
            if m:
                df["date"] = m.group(1)
        frames.append(df)

    all_df = pd.concat(frames, ignore_index=True)
    all_df["date"] = all_df["date"].astype(str)

    if "code" in all_df.columns:
        all_df = all_df.sort_values(["date","code"]).drop_duplicates(["date","code"], keep="last")

    os.makedirs(os.path.dirname(OUT_MAIN) or ".", exist_ok=True)
    all_df.to_csv(OUT_MAIN, index=False, encoding="utf-8-sig")
    print(f"[DONE] merged -> data/all_stocks_daily.csv (dates={all_df['date'].nunique()}, rows={len(all_df)})")

if __name__ == "__main__":
    main()