# -*- coding: utf-8 -*-
"""
Portfolio Backtest v3 (Cross-sectional, dynamic holdings, risk switch, costs)

Assumptions:
- data/all_stocks_daily.csv contains multiple dates and per-stock daily return proxy in 'change_percent' (close-to-close %)
- data/market_snapshot_taiex.csv exists with columns: date, risk_mode, trend_ok, market_ok
  (If only json exists, we will still run but risk_mode will default to RISK_OFF when missing.)

Outputs:
- reports/portfolio_backtest_v3.csv
- reports/portfolio_backtest_v3_summary.json

Costs model (conservative default):
- fee_rate: 0.001425 (0.1425%)
- tax_rate: 0.003 (0.3%)
- slippage_bps: 5 (0.05%) per side
Applied on turnover (buy+sell), approximated daily rebalancing to target weights.
"""
from __future__ import annotations
import argparse
import json
import os
import math
import pandas as pd

def _read_csv(path: str) -> pd.DataFrame:
    try:
        return pd.read_csv(path, dtype={"code": str})
    except UnicodeDecodeError:
        return pd.read_csv(path, encoding="utf-8-sig", dtype={"code": str})

def _safe_numeric(s):
    return pd.to_numeric(s, errors="coerce")

def decide_holdings_count(risk_mode: str, breadth_ratio: float) -> int:
    rm = (risk_mode or "").upper()
    br = float(breadth_ratio or 0.0)
    if rm == "RISK_ON":
        if br > 0.20: return 25
        if br > 0.10: return 20
        if br > 0.05: return 15
        return 10
    if br > 0.10: return 10
    if br > 0.05: return 7
    if br > 0.02: return 5
    return 0

def model_params(risk_mode: str) -> dict:
    rm = (risk_mode or "").upper()
    if rm == "RISK_ON":
        return {"capital_use_ratio": 0.90, "single_name_cap_ratio": 0.08}
    return {"capital_use_ratio": 0.45, "single_name_cap_ratio": 0.05}

def compute_breadth_ratio(day: pd.DataFrame, threshold: float) -> float:
    # breadth on that day
    scores = _safe_numeric(day["total_score"]).dropna()
    if len(scores) == 0:
        return 0.0
    above = float((scores >= threshold).sum())
    total = float(len(scores))
    return above / total if total > 0 else 0.0

def pick_portfolio(day: pd.DataFrame, risk_mode: str, breadth_ratio: float, capital_use_ratio: float, cap_ratio: float) -> pd.DataFrame:
    # sort by score desc
    d = day.copy()
    d["total_score"] = _safe_numeric(d["total_score"])
    d = d.dropna(subset=["total_score"])
    d = d.sort_values(["total_score","code"], ascending=[False, True]).reset_index(drop=True)
    d["rank"] = range(1, len(d)+1)

    hold_n = decide_holdings_count(risk_mode, breadth_ratio)
    if hold_n <= 0:
        return pd.DataFrame(columns=["code","weight","rank","total_score"])

    sel = d.head(hold_n).copy()
    # equal weight with cap on weight
    n = len(sel)
    if n <= 0:
        return pd.DataFrame(columns=["code","weight","rank","total_score"])

    base_w = capital_use_ratio / n
    cap_w = cap_ratio
    sel["weight"] = base_w
    sel["weight"] = sel["weight"].clip(upper=cap_w)

    # redistribute to reach capital_use_ratio, but only within caps
    max_iter = 10
    for _ in range(max_iter):
        s = float(sel["weight"].sum())
        leftover = capital_use_ratio - s
        if abs(leftover) <= 1e-9:
            break
        room = (cap_w - sel["weight"]).clip(lower=0.0)
        room_sum = float(room.sum())
        if room_sum <= 1e-12:
            break
        add = leftover * (room / room_sum)
        sel["weight"] = sel["weight"] + add

    # if still short (due to caps), keep remaining as cash
    # normalize tiny drift only if exceed use ratio
    s = float(sel["weight"].sum())
    if s > capital_use_ratio and s > 1e-12:
        sel["weight"] = sel["weight"] * (capital_use_ratio / s)

    return sel[["code","weight","rank","total_score"]].copy()

def costs_from_turnover(turnover: float, fee_rate: float, tax_rate: float, slippage_bps: float) -> float:
    # turnover = sum(abs(w_t - w_{t-1})) ; approximates buy+sell notion already
    slip = (slippage_bps / 10000.0)
    # fee+tax apply on traded notional; slippage too
    return turnover * (fee_rate + tax_rate + slip)

def max_drawdown(equity: pd.Series) -> float:
    peak = equity.cummax()
    dd = (equity / peak) - 1.0
    return float(dd.min()) if len(dd) else 0.0

def sharpe(daily_ret: pd.Series, rf: float = 0.0) -> float:
    if len(daily_ret) < 2:
        return 0.0
    x = daily_ret - rf
    mu = float(x.mean())
    sd = float(x.std(ddof=1))
    if sd <= 1e-12:
        return 0.0
    return mu / sd * math.sqrt(252.0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in_csv", default=r"data/all_stocks_daily.csv")
    ap.add_argument("--market_csv", default=r"data/market_snapshot_taiex.csv")
    ap.add_argument("--out_csv", default=r"reports/portfolio_backtest_v3.csv")
    ap.add_argument("--threshold", type=float, default=70.0)
    ap.add_argument("--start", default="", help="YYYY-MM-DD")
    ap.add_argument("--end", default="", help="YYYY-MM-DD")
    ap.add_argument("--fee_rate", type=float, default=0.001425)
    ap.add_argument("--tax_rate", type=float, default=0.003)
    ap.add_argument("--slippage_bps", type=float, default=5.0)
    ap.add_argument("--init_capital", type=float, default=1000000.0)
    args = ap.parse_args()

    df = _read_csv(args.in_csv)

    need = {"date","code","total_score","change_percent"}
    if not need.issubset(set(df.columns)):
        raise ValueError(f"data/all_stocks_daily.csv must contain: {sorted(list(need))}")

    df["date"] = df["date"].astype(str)
    df["change_percent"] = _safe_numeric(df["change_percent"]).fillna(0.0) / 100.0
    df["total_score"] = _safe_numeric(df["total_score"])

    # market snapshot (optional)
    mkt = None
    if os.path.exists(args.market_csv):
        mkt = _read_csv(args.market_csv)
        if "date" in mkt.columns:
            mkt["date"] = mkt["date"].astype(str)

    dates = sorted(df["date"].unique().tolist())
    if args.start:
        dates = [d for d in dates if d >= args.start]
    if args.end:
        dates = [d for d in dates if d <= args.end]
    if len(dates) < 2:
        raise ValueError("Need at least 2 trading dates for portfolio backtest v3.")

    equity = float(args.init_capital)
    prev_w = {}  # code -> weight
    rows = []

    for i in range(len(dates) - 1):
        d0 = dates[i]
        d1 = dates[i + 1]

        day0 = df[df["date"] == d0].copy()
        day1 = df[df["date"] == d1].copy()

        # decide risk mode
        risk_mode = "RISK_OFF"
        market_ok = False
        trend_ok = False
        if mkt is not None and "risk_mode" in mkt.columns:
            r = mkt[mkt["date"] == d0]
            if not r.empty:
                risk_mode = str(r.iloc[0].get("risk_mode","RISK_OFF")).upper()
                market_ok = bool(r.iloc[0].get("market_ok", False))
                trend_ok  = bool(r.iloc[0].get("trend_ok", False))
        # safety
        if not market_ok or not trend_ok:
            risk_mode = "RISK_OFF"

        br = compute_breadth_ratio(day0.dropna(subset=["total_score"]), args.threshold)
        params = model_params(risk_mode)
        port = pick_portfolio(
            day0,
            risk_mode=risk_mode,
            breadth_ratio=br,
            capital_use_ratio=float(params["capital_use_ratio"]),
            cap_ratio=float(params["single_name_cap_ratio"])
        )

        # target weights
        tgt = {str(r.code): float(r.weight) for r in port.itertuples(index=False)} if not port.empty else {}

        # turnover
        codes = set(prev_w.keys()) | set(tgt.keys())
        turnover = sum(abs(tgt.get(c,0.0) - prev_w.get(c,0.0)) for c in codes)

        # costs (as fraction of equity)
        cost_frac = costs_from_turnover(turnover, args.fee_rate, args.tax_rate, args.slippage_bps)

        # realized next-day return on target weights (using day1 change_percent)
        ret_map = dict(zip(day1["code"].astype(str), day1["change_percent"].astype(float)))
        gross_ret = sum(tgt.get(c,0.0) * ret_map.get(c, 0.0) for c in tgt.keys())
        net_ret = gross_ret - cost_frac

        equity = equity * (1.0 + net_ret)

        rows.append({
            "date": d1,
            "prev_date": d0,
            "risk_mode": risk_mode,
            "market_ok": market_ok,
            "trend_ok": trend_ok,
            "breadth_ratio": br,
            "holdings": int(len(tgt)),
            "turnover": float(turnover),
            "gross_return": float(gross_ret),
            "cost_frac": float(cost_frac),
            "net_return": float(net_ret),
            "equity": float(equity)
        })

        prev_w = tgt

    out_csv = args.out_csv
    os.makedirs(os.path.dirname(out_csv) or ".", exist_ok=True)
    out = pd.DataFrame(rows)
    out.to_csv(out_csv, index=False, encoding="utf-8-sig")
    print(f"OK: wrote -> {out_csv} rows={len(out)}")

    # summary
    daily = out["net_return"]
    dd = max_drawdown(out["equity"])
    sh = sharpe(daily)
    ann = (out["equity"].iloc[-1] / float(args.init_capital)) ** (252.0 / max(1, len(out))) - 1.0

    summary = {
        "init_capital": float(args.init_capital),
        "final_equity": float(out["equity"].iloc[-1]),
        "total_return": float(out["equity"].iloc[-1] / float(args.init_capital) - 1.0),
        "annualized_return": float(ann),
        "max_drawdown": float(dd),
        "sharpe": float(sh),
        "bars": int(len(out))
    }
    sum_path = r"reports/portfolio_backtest_v3_summary.json"
    with open(sum_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(f"OK: wrote -> {sum_path}")

if __name__ == "__main__":
    main()