# -*- coding: utf-8 -*-
"""
Dynamic Portfolio Engine (Risk Switch + Breadth + Capital Allocation)

Inputs:
- data/ranking_<date>.csv
- data/breadth_<date>.json
- data/market_snapshot_taiex.json  (existing)
Output:
- data/portfolio_plan_<date>.csv
"""
from __future__ import annotations
import argparse
import json
import os
from dataclasses import dataclass
import pandas as pd

def _read_csv(path: str) -> pd.DataFrame:
    try:
        return pd.read_csv(path, dtype={"code": str})
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype={"code": str})

def _read_json(path: str) -> dict:
    if not os.path.exists(path):
        raise FileNotFoundError(f"Missing: {path}")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def decide_holdings_count(risk_mode: str, breadth_ratio: float) -> int:
    rm = (risk_mode or "").upper()
    br = float(breadth_ratio or 0.0)

    if rm == "RISK_ON":
        if br > 0.20: return 25
        if br > 0.10: return 20
        if br > 0.05: return 15
        return 10
    # RISK_OFF
    if br > 0.10: return 10
    if br > 0.05: return 7
    if br > 0.02: return 5
    return 0  # extreme weak -> all cash

def model_params(risk_mode: str) -> dict:
    rm = (risk_mode or "").upper()
    if rm == "RISK_ON":
        return {
            "capital_use_ratio": 0.90,
            "single_name_cap_ratio": 0.08,
            "cash_reserve_ratio": 0.10
        }
    return {
        "capital_use_ratio": 0.45,
        "single_name_cap_ratio": 0.05,
        "cash_reserve_ratio": 0.55
    }

def allocate_equal_with_caps(selected: pd.DataFrame, capital: float, use_ratio: float, cap_ratio: float) -> pd.DataFrame:
    if selected.empty:
        return selected

    usable = float(capital) * float(use_ratio)
    n = len(selected)
    base = usable / n if n > 0 else 0.0
    cap_amt = float(capital) * float(cap_ratio)

    # start equal
    selected = selected.copy()
    selected["amount_raw"] = base
    # cap
    selected["amount"] = selected["amount_raw"].clip(upper=cap_amt)

    # redistribute leftover (simple iterative, deterministic)
    max_iter = 10
    for _ in range(max_iter):
        used = float(selected["amount"].sum())
        leftover = usable - used
        if leftover <= 1e-6:
            break
        room = (cap_amt - selected["amount"]).clip(lower=0.0)
        room_sum = float(room.sum())
        if room_sum <= 1e-6:
            break
        add = leftover * (room / room_sum)
        selected["amount"] = selected["amount"] + add

    # final normalize if tiny drift
    used = float(selected["amount"].sum())
    if used > 1e-6:
        scale = usable / used
        selected["amount"] = selected["amount"] * scale

    return selected

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--capital", type=float, default=300000.0)
    ap.add_argument("--ranking_csv", default="")
    ap.add_argument("--breadth_json", default="")
    ap.add_argument("--market_json", default=r"data/market_snapshot_taiex.json")
    ap.add_argument("--out_csv", default="")
    args = ap.parse_args()

    date = str(args.date)
    ranking_csv = args.ranking_csv.strip() or f"data/ranking_{date}.csv"
    breadth_json = args.breadth_json.strip() or f"data/breadth_{date}.json"
    out_csv = args.out_csv.strip() or f"data/portfolio_plan_{date}.csv"

    rk = _read_csv(ranking_csv)
    bd = _read_json(breadth_json)
    mk = _read_json(args.market_json)

    risk_mode = str(mk.get("risk_mode", "RISK_OFF")).upper()
    market_ok = bool(mk.get("market_ok", False))
    trend_ok  = bool(mk.get("trend_ok", False))

    # hard safety: if market_ok is false => force RISK_OFF
    if not market_ok or not trend_ok:
        risk_mode = "RISK_OFF"

    breadth_ratio = float(bd.get("breadth_ratio", 0.0))
    hold_n = decide_holdings_count(risk_mode, breadth_ratio)
    params = model_params(risk_mode)

    capital = float(args.capital)
    cash_reserve = capital * float(params["cash_reserve_ratio"])
    use_ratio = float(params["capital_use_ratio"])
    cap_ratio = float(params["single_name_cap_ratio"])

    if hold_n <= 0:
        # all cash
        plan = pd.DataFrame([{
            "date": date,
            "risk_mode": risk_mode,
            "market_ok": market_ok,
            "trend_ok": trend_ok,
            "breadth_ratio": breadth_ratio,
            "holdings": 0,
            "capital": capital,
            "used_capital": 0.0,
            "cash_reserve": capital,
            "code": "",
            "rank": "",
            "total_score": "",
            "weight": 0.0,
            "amount": 0.0
        }])
    else:
        sel = rk.head(hold_n).copy()
        # ensure numeric
        if "rank" not in sel.columns:
            sel["rank"] = range(1, len(sel) + 1)
        sel["total_score"] = pd.to_numeric(sel.get("total_score", 0), errors="coerce").fillna(0.0)

        sel = allocate_equal_with_caps(sel, capital, use_ratio, cap_ratio)
        used = float(sel["amount"].sum())
        cash = max(0.0, capital - used)

        sel["weight"] = sel["amount"] / capital if capital > 0 else 0.0

        # project-level columns
        sel.insert(0, "date", date)
        sel.insert(1, "risk_mode", risk_mode)
        sel.insert(2, "market_ok", market_ok)
        sel.insert(3, "trend_ok", trend_ok)
        sel.insert(4, "breadth_ratio", breadth_ratio)
        sel.insert(5, "holdings", hold_n)
        sel.insert(6, "capital", capital)
        sel.insert(7, "used_capital", used)
        sel.insert(8, "cash_reserve", cash)

        # keep clean columns
        keep_first = ["date","risk_mode","market_ok","trend_ok","breadth_ratio","holdings","capital","used_capital","cash_reserve","code","rank","name","sector","total_score","weight","amount"]
        keep = [c for c in keep_first if c in sel.columns] + [c for c in sel.columns if c not in keep_first]
        plan = sel[keep].copy()

    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)
    plan.to_csv(out_csv, index=False, encoding="utf-8-sig")
    print(f"OK: wrote -> {out_csv} (rows={len(plan)})")

if __name__ == "__main__":
    main()