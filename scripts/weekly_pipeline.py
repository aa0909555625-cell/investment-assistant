# -*- coding: utf-8 -*-
"""
weekly_pipeline.py (v3 HISTORY runner-safe, FIX CWD)

Fix:
- Subprocess cwd MUST be project root, not scripts/.
  Otherwise child scripts that use relative paths like "data/..." will break.

Pipeline:
1) build_ranking_history.py -> data/ranking_history.csv
2) ranking_engine.py        -> data/ranking_YYYY-MM-DD.csv (latest snapshot)
3) ensure breadth_history.csv
4) backtest_portfolio_v3.py (uses ranking_history if available)
"""

from __future__ import annotations

import os
import sys
import argparse
import subprocess
from typing import Optional
import pandas as pd


def _read_csv(path: str, dtype: Optional[dict] = None) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    try:
        return pd.read_csv(path, dtype=dtype or {}, low_memory=False)
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype=dtype or {}, low_memory=False)


def _write_csv(df: pd.DataFrame, path: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    df.to_csv(path, index=False, encoding="utf-8")
    print(f"OK: wrote -> {os.path.abspath(path)} (rows={len(df)})")


def _latest_date_from_all(all_csv: str) -> str:
    df = _read_csv(all_csv, dtype={"date": str})
    df["date"] = df["date"].astype(str)
    return sorted(df["date"].dropna().unique().tolist())[-1]


def _ensure_breadth_history(all_csv: str, out_csv: str, threshold: float) -> None:
    if os.path.exists(out_csv):
        return

    df = _read_csv(all_csv, dtype={"date": str, "code": str, "source": str})
    df["date"] = df["date"].astype(str)
    df["total_score"] = pd.to_numeric(df.get("total_score", pd.Series([], dtype="float64")), errors="coerce")
    df["change_percent"] = pd.to_numeric(df.get("change_percent", pd.Series([], dtype="float64")), errors="coerce")

    rows = []
    for d, g in df.groupby("date"):
        n = int(len(g))
        n_score_ge = int((g["total_score"] >= float(threshold)).sum()) if "total_score" in g.columns else 0
        n_adv = int((g["change_percent"] > 0).sum()) if "change_percent" in g.columns else 0
        breadth_ratio = (n_score_ge / n) if n > 0 else 0.0
        adv_ratio = (n_adv / n) if n > 0 else 0.0
        rows.append({
            "date": str(d),
            "n": n,
            "n_score_ge": n_score_ge,
            "n_adv": n_adv,
            "breadth_ratio": breadth_ratio,
            "adv_ratio": adv_ratio,
        })

    out = pd.DataFrame(rows).sort_values("date")
    _write_csv(out, out_csv)


def _run_py(script_path: str, args: list[str], cwd: str) -> int:
    """
    Run a python script using current interpreter (sys.executable),
    with cwd pinned to project root.
    """
    if not os.path.exists(script_path):
        print(f"WARN: missing script: {script_path}")
        return 127

    cmd = [sys.executable, script_path] + args
    try:
        p = subprocess.run(cmd, cwd=cwd)
        if p.returncode != 0:
            print(f"WARN: script failed rc={p.returncode}: {os.path.basename(script_path)}")
        return int(p.returncode)
    except Exception as e:
        print(f"WARN: failed to run {script_path}: {e}")
        return 127


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--capital", type=float, default=300000)
    ap.add_argument("--top", type=int, default=200)
    ap.add_argument("--threshold", type=float, default=70.0)
    ap.add_argument("--init_capital", type=float, default=1_000_000.0)
    ap.add_argument("--breadth_field", default="adv_ratio")
    ap.add_argument("--breadth_min", type=float, default=0.50)
    args = ap.parse_args(argv)

    # project root
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    data_dir = os.path.join(root, "data")
    reports_dir = os.path.join(root, "reports")
    scripts_dir = os.path.join(root, "scripts")

    os.makedirs(data_dir, exist_ok=True)
    os.makedirs(reports_dir, exist_ok=True)

    all_csv = os.path.join(data_dir, "all_stocks_daily.csv")
    if not os.path.exists(all_csv):
        raise FileNotFoundError(f"Missing: {all_csv}")

    latest = _latest_date_from_all(all_csv)

    # 1) ranking_history
    build_hist = os.path.join(scripts_dir, "build_ranking_history.py")
    ranking_hist_csv = os.path.join(data_dir, "ranking_history.csv")
    _run_py(build_hist, [
        "--in_csv", all_csv,
        "--out_csv", ranking_hist_csv,
        "--top", str(args.top),
        "--threshold", str(args.threshold),
    ], cwd=root)

    # 2) latest ranking snapshot (compat/UI)
    rank_engine = os.path.join(scripts_dir, "ranking_engine.py")
    _run_py(rank_engine, [
        "--in_csv", all_csv,
        "--top", str(args.top),
    ], cwd=root)

    ranking_out = os.path.join(data_dir, f"ranking_{latest}.csv")
    if not os.path.exists(ranking_out):
        # find newest ranking_*.csv under data/
        cands = [os.path.join(data_dir, f) for f in os.listdir(data_dir) if f.startswith("ranking_") and f.endswith(".csv")]
        cands = sorted(cands, key=lambda p: os.path.getmtime(p)) if cands else []
        if cands:
            ranking_out = cands[-1]
        else:
            print("WARN: no ranking_*.csv found; backtest will fallback.")

    # 3) breadth_history
    breadth_csv = os.path.join(data_dir, "breadth_history.csv")
    _ensure_breadth_history(all_csv, breadth_csv, args.threshold)

    bh = _read_csv(breadth_csv, dtype={"date": str})
    print("tail:")
    print(bh.tail(5).to_string(index=False))

    # 4) backtest v3
    backtest = os.path.join(scripts_dir, "backtest_portfolio_v3.py")
    bt_args = [
        "--in_csv", ranking_out,
        "--breadth_history_csv", breadth_csv,
        "--breadth_field", str(args.breadth_field),
        "--breadth_min", str(args.breadth_min),
        "--threshold", str(args.threshold),
        "--holdings_on", "15",
        "--cost_bps", "25",
        "--init_capital", str(args.init_capital),
    ]
    if os.path.exists(ranking_hist_csv):
        bt_args += ["--ranking_history_csv", ranking_hist_csv]

    _run_py(backtest, bt_args, cwd=root)

    print(f"v3: {os.path.join(reports_dir, 'portfolio_backtest_v3.csv')}")
    print("=== PIPELINE DONE ===")
    print(f"date={latest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())