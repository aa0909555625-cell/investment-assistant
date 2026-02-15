# -*- coding: utf-8 -*-
"""
sector_map_build.py (BOM-safe)
- Prefer data/universe_all.csv or data/universe_stock.csv
- Treat industry as sector
- BOM-safe header normalization: handles "\ufeffcode"
- Output: data/sector_map.csv with columns: code,sector
"""
from __future__ import annotations

import argparse
import csv
import os
from typing import Dict, List, Tuple

PREFERRED_FILES = [
    os.path.join("data", "universe_all.csv"),
    os.path.join("data", "universe_stock.csv"),
]

CODE_KEYS = ["code", "symbol", "ticker"]
SECTOR_KEYS = ["sector", "industry", "category", "group", "industry_name", "sector_name"]

BAD_SECTORS = {"", "unknown", "na", "n/a", "null", "none", "-"}

def norm(s: str) -> str:
    return (s or "").strip()

def norm_key(k: str) -> str:
    # strip whitespace + BOM
    return norm(k).lstrip("\ufeff").lower()

def read_csv(path: str) -> Tuple[List[str], List[Dict[str, str]]]:
    with open(path, "r", encoding="utf-8") as f:
        r = csv.DictReader(f)
        rows = list(r)
        header_raw = list(r.fieldnames or [])
        header_norm = [norm_key(h) for h in header_raw]
        # also normalize each row key (BOM-safe)
        norm_rows: List[Dict[str, str]] = []
        for row in rows:
            rr: Dict[str, str] = {}
            for k, v in row.items():
                rr[norm_key(k)] = v
            norm_rows.append(rr)
        return header_norm, norm_rows

def pick_key(keys: List[str], header_lower: List[str]) -> str:
    for k in keys:
        if k in header_lower:
            return k
    return ""

def good_sector(s: str) -> bool:
    v = norm(s)
    if v == "":
        return False
    if v.lower() in {x.lower() for x in BAD_SECTORS}:
        return False
    # reject "unknown"/"UNKNOWN"
    if v.lower() == "unknown":
        return False
    return True

def build_map_from_file(path: str) -> Tuple[Dict[str, str], str]:
    header, rows = read_csv(path)
    ck = pick_key(CODE_KEYS, header)
    sk = pick_key(SECTOR_KEYS, header)
    if not ck or not sk:
        return {}, f"missing keys (code={ck}, sector={sk}) header={header[:8]}..."

    m: Dict[str, str] = {}
    good = 0
    total = 0

    for rr in rows:
        code = norm(rr.get(ck, ""))
        if not code:
            continue
        sector = norm(rr.get(sk, ""))
        total += 1
        if not good_sector(sector):
            continue
        good += 1
        if code not in m:
            m[code] = sector

    ratio = (good / total) if total > 0 else 0.0
    # gate: need meaningful mapping
    if good < 300 and ratio < 0.30:
        return {}, f"quality too low (good={good}, total={total}, ratio={ratio:.2f})"

    return m, f"OK (good={good}, total={total}, ratio={ratio:.2f}, keys=code:{ck} sector:{sk})"

def write_map(out_path: str, m: Dict[str, str], source: str, msg: str) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["code", "sector"])
        w.writeheader()
        for code, sec in m.items():
            w.writerow({"code": code, "sector": sec})
    print(f"[OK] sector_map built -> {out_path}")
    print(f"     source: {source}")
    print(f"     {msg}")
    print(f"     rows: {len(m)}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/sector_map.csv")
    ap.add_argument("--data_dir", default="data")
    args = ap.parse_args()

    # 1) preferred files first
    for p in PREFERRED_FILES:
        if os.path.exists(p):
            m, msg = build_map_from_file(p)
            if m:
                write_map(args.out, m, p, msg)
                return
            else:
                print(f"[WARN] preferred source rejected: {p} :: {msg}")

    # 2) fallback scan (avoid derived files)
    best_map: Dict[str, str] = {}
    best_path = ""
    for root, _, files in os.walk(args.data_dir):
        for fn in files:
            if not fn.lower().endswith(".csv"):
                continue
            path = os.path.join(root, fn)
            low = path.lower()
            if any(x in low for x in ["ranking", "decisions", "all_stocks_daily", "portfolio_plan", "sector_map"]):
                continue
            try:
                m, msg = build_map_from_file(path)
                if m and len(m) > len(best_map):
                    best_map = m
                    best_path = path
            except Exception:
                continue

    if not best_map:
        raise RuntimeError("No suitable sector mapping source found. Ensure universe_all.csv or universe_stock.csv has industry/sector column (BOM-safe).")

    write_map(args.out, best_map, best_path, "fallback chosen")

if __name__ == "__main__":
    main()