# -*- coding: utf-8 -*-
"""
backtest_portfolio_v3.py

Portfolio backtest (daily) using:
- all_stocks_daily.csv (universe + change_percent + total_score + OHLCV)
- market_snapshot_taiex.csv (market_ok, trend_ok; best-effort)
- breadth_history.csv (breadth field e.g. adv_ratio)
- ranking_history.csv (date-wise ranked candidates)

Key fixes:
- RISK_ON selection uses ranking_history by prev_date_used (with backfill when prev_date missing)
- Always try to fill holdings_on using:
  1) total_score >= threshold (ranking_history)
  2) total_score < threshold (ranking_history)
  3) fallback liquidity fill from all_stocks_daily (volume desc)
- If RISK_ON but no picks possible => turnover=0 cost=0 status=NO_PICKS (no phantom costs)
- CLI compatibility: accepts --in_csv (deprecated) to avoid breaking callers.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import pandas as pd


def _read_csv(path: str, dtype: Optional[dict] = None) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    return pd.read_csv(path, dtype=dtype or {}, low_memory=False)


def _to_float(x, default: float = math.nan) -> float:
    try:
        if x is None or (isinstance(x, float) and math.isnan(x)):
            return default
        s = str(x).strip()
        if s == "" or s.lower() == "nan":
            return default
        return float(s)
    except Exception:
        return default


def _safe_str(x) -> str:
    return "" if x is None else str(x)


def _ensure_dir(p: str) -> None:
    d = os.path.dirname(p)
    if d and not os.path.exists(d):
        os.makedirs(d, exist_ok=True)


def _write_csv(path: str, rows: List[dict]) -> None:
    _ensure_dir(path)
    if not rows:
        pd.DataFrame([]).to_csv(path, index=False, encoding="utf-8")
        return
    pd.DataFrame(rows).to_csv(path, index=False, encoding="utf-8")


def _write_json(path: str, obj: dict) -> None:
    _ensure_dir(path)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)


def _build_index_by_date(df: pd.DataFrame) -> Dict[str, pd.DataFrame]:
    if "date" not in df.columns:
        return {}
    out: Dict[str, pd.DataFrame] = {}
    for d, g in df.groupby("date"):
        out[str(d)] = g
    return out


def _sorted_dates(dates: List[str]) -> List[str]:
    # dates are YYYY-MM-DD; string sort works
    return sorted({str(d) for d in dates})


def _prev_trading_date(target_prev: str, available_dates: List[str]) -> Optional[str]:
    """Find the nearest date <= target_prev in available_dates."""
    if not available_dates:
        return None
    ds = _sorted_dates(available_dates)
    # binary-ish scan backwards (small N is fine)
    for d in reversed(ds):
        if d <= target_prev:
            return d
    return None


@dataclass
class PickResult:
    codes: List[str]
    source: str
    status: str
    prev_date_used: str


def _select_codes_for_prev_date(
    prev_date: str,
    target_holdings: int,
    threshold: float,
    ranking_by_date: Dict[str, pd.DataFrame],
    all_by_date: Dict[str, pd.DataFrame],
) -> PickResult:
    """
    Select up to target_holdings based on prev_date.
    If prev_date missing in all_by_date, backfill prev_date_used to nearest available <= prev_date.
    Then pick from ranking_history first; if insufficient, fill by all_stocks_daily volume.
    """
    if target_holdings <= 0:
        return PickResult(codes=[], source="RISK_OFF", status="RISK_OFF", prev_date_used=prev_date)

    all_dates = list(all_by_date.keys())
    prev_date_used = prev_date if prev_date in all_by_date else (_prev_trading_date(prev_date, all_dates) or prev_date)

    # 1) ranking_history pool
    picked: List[str] = []
    src = "RANKING_HISTORY"
    status = "OK"

    rh = ranking_by_date.get(prev_date_used)
    if rh is not None and len(rh) > 0:
        # normalize
        rh = rh.copy()
        if "code" in rh.columns:
            rh["code"] = rh["code"].astype(str)
        if "total_score" in rh.columns:
            rh["total_score_f"] = rh["total_score"].apply(lambda v: _to_float(v, math.nan))
        else:
            rh["total_score_f"] = math.nan

        ge = rh[rh["total_score_f"].notna() & (rh["total_score_f"] >= float(threshold))].copy()
        lt = rh[rh["total_score_f"].notna() & (rh["total_score_f"] < float(threshold))].copy()

        ge = ge.sort_values(["total_score_f", "code"], ascending=[False, True])
        lt = lt.sort_values(["total_score_f", "code"], ascending=[False, True])

        for df_pool, tag in [(ge, "OK"), (lt, "FILLED_BELOW_THRESHOLD")]:
            if len(picked) >= target_holdings:
                break
            for c in df_pool["code"].tolist():
                if c and c not in picked:
                    picked.append(c)
                    if len(picked) >= target_holdings:
                        break
            if tag != "OK" and len(picked) > 0:
                status = tag

    # 2) if still not enough, liquidity fill from all_stocks_daily (prev_date_used)
    if len(picked) < target_holdings:
        uni = all_by_date.get(prev_date_used)
        if uni is not None and len(uni) > 0:
            u = uni.copy()
            u["code"] = u["code"].astype(str)
            # volume sort desc, then total_score desc, then code asc
            if "volume" in u.columns:
                u["volume_f"] = u["volume"].apply(lambda v: _to_float(v, 0.0))
            else:
                u["volume_f"] = 0.0
            if "total_score" in u.columns:
                u["total_score_f"] = u["total_score"].apply(lambda v: _to_float(v, -1e18))
            else:
                u["total_score_f"] = -1e18

            u = u[~u["code"].isin(picked)].copy()
            u = u.sort_values(["volume_f", "total_score_f", "code"], ascending=[False, False, True])

            need = target_holdings - len(picked)
            more = [c for c in u["code"].tolist() if c][:need]
            if more:
                picked.extend(more)
                src = "ALL_STOCKS_DAILY_LIQUIDITY_FILL"
                if status == "OK":
                    status = "FILLED_LIQUIDITY"

    if len(picked) == 0:
        return PickResult(codes=[], source="ALL_STOCKS_DAILY", status="NO_PICKS", prev_date_used=prev_date_used)

    return PickResult(codes=picked[:target_holdings], source=src, status=status, prev_date_used=prev_date_used)


def _compute_turnover(prev_w: Dict[str, float], cur_w: Dict[str, float]) -> float:
    if not prev_w and not cur_w:
        return 0.0
    if not prev_w and cur_w:
        return 1.0
    if prev_w and not cur_w:
        return 1.0
    overlap = 0.0
    for c, w in cur_w.items():
        if c in prev_w:
            overlap += min(w, prev_w[c])
    # simple one-way turnover approximation: buy/sell fraction
    return max(0.0, min(1.0, 1.0 - overlap))


def _get_ret(all_by_date: Dict[str, pd.DataFrame], date: str, code: str) -> Optional[float]:
    df = all_by_date.get(date)
    if df is None or len(df) == 0:
        return None
    m = df[df["code"].astype(str) == str(code)]
    if len(m) == 0:
        return None
    v = m.iloc[0].get("change_percent", None)
    r = _to_float(v, math.nan)
    if math.isnan(r):
        return None
    return r / 100.0


def _lookup_meta(all_by_date: Dict[str, pd.DataFrame], date: str, code: str) -> Tuple[str, str, str, float]:
    """name, sector, source, total_score (best effort from all_stocks_daily on prev_date_used)."""
    df = all_by_date.get(date)
    if df is None or len(df) == 0:
        return ("", "", "", math.nan)
    m = df[df["code"].astype(str) == str(code)]
    if len(m) == 0:
        return ("", "", "", math.nan)
    row = m.iloc[0]
    name = _safe_str(row.get("name", ""))
    sector = _safe_str(row.get("sector", ""))
    src = _safe_str(row.get("source", ""))
    ts = _to_float(row.get("total_score", None), math.nan)
    return (name, sector, src, ts)


def _get_market_flags(market_by_date: Dict[str, pd.DataFrame], date: str) -> Tuple[bool, bool]:
    df = market_by_date.get(date)
    if df is None or len(df) == 0:
        return (True, True)
    row = df.iloc[0]
    # best-effort: accept columns market_ok / trend_ok, else default True
    mk = row.get("market_ok", True)
    tk = row.get("trend_ok", True)
    def _to_bool(v, default=True):
        if isinstance(v, bool):
            return v
        s = str(v).strip().lower()
        if s in ("1", "true", "t", "yes", "y"):
            return True
        if s in ("0", "false", "f", "no", "n"):
            return False
        return default
    return (_to_bool(mk, True), _to_bool(tk, True))


def _get_breadth_metric(breadth_by_date: Dict[str, pd.DataFrame], date: str, field: str) -> float:
    df = breadth_by_date.get(date)
    if df is None or len(df) == 0:
        return math.nan
    row = df.iloc[0]
    return _to_float(row.get(field, None), math.nan)


def main() -> int:
    ap = argparse.ArgumentParser()
    # compatibility / inputs
    ap.add_argument("--ranking_history_csv", default="data/ranking_history.csv")
    ap.add_argument("--in_csv", default=None, help="(compat) deprecated; ignored if ranking_history_csv exists")
    ap.add_argument("--market_csv", default="data/market_snapshot_taiex.csv")
    ap.add_argument("--breadth_history_csv", default="data/breadth_history.csv")
    # strategy params
    ap.add_argument("--breadth_field", default="adv_ratio")
    ap.add_argument("--breadth_min", type=float, default=0.50)
    ap.add_argument("--threshold", type=float, default=70.0)
    ap.add_argument("--holdings_on", type=int, default=15)
    ap.add_argument("--cost_bps", type=float, default=25.0)
    ap.add_argument("--init_capital", type=float, default=1_000_000.0)
    ap.add_argument("--debug_date", default=None)

    args = ap.parse_args()

    # ---- load universe ----
    all_path = r"data/all_stocks_daily.csv"
    all_df = _read_csv(all_path, dtype={"code": str, "source": str})
    all_df["date"] = all_df["date"].astype(str)
    all_df["code"] = all_df["code"].astype(str)
    all_by_date = _build_index_by_date(all_df)

    # ---- load market ----
    market_df = pd.DataFrame()
    if os.path.exists(args.market_csv):
        market_df = _read_csv(args.market_csv, dtype={"source": str})
        if "date" in market_df.columns:
            market_df["date"] = market_df["date"].astype(str)
    market_by_date = _build_index_by_date(market_df) if len(market_df) > 0 else {}

    # ---- load breadth ----
    breadth_df = pd.DataFrame()
    if os.path.exists(args.breadth_history_csv):
        breadth_df = _read_csv(args.breadth_history_csv, dtype={"source": str})
        if "date" in breadth_df.columns:
            breadth_df["date"] = breadth_df["date"].astype(str)
    breadth_by_date = _build_index_by_date(breadth_df) if len(breadth_df) > 0 else {}

    # ---- load ranking history (primary) ----
    ranking_df = pd.DataFrame()
    ranking_source = "RANKING_HISTORY"
    if os.path.exists(args.ranking_history_csv):
        ranking_df = _read_csv(args.ranking_history_csv, dtype={"code": str, "source": str})
        if "date" in ranking_df.columns:
            ranking_df["date"] = ranking_df["date"].astype(str)
        ranking_df["code"] = ranking_df["code"].astype(str)
    else:
        # compat fallback: if caller provided in_csv, try it as ranking history (single-date ranking is still usable for that date only)
        if args.in_csv and os.path.exists(args.in_csv):
            ranking_source = "RANKING_CSV_COMPAT"
            ranking_df = _read_csv(args.in_csv, dtype={"code": str, "source": str})
            if "date" in ranking_df.columns:
                ranking_df["date"] = ranking_df["date"].astype(str)
            else:
                # no date column: cannot build history; keep empty
                ranking_df = pd.DataFrame()

    ranking_by_date = _build_index_by_date(ranking_df) if len(ranking_df) > 0 else {}

    # ---- backtest date range ----
    # Prefer market dates if present; else use all_stocks_daily dates.
    if len(market_df) > 0 and "date" in market_df.columns:
        dates = _sorted_dates(market_df["date"].tolist())
    else:
        dates = _sorted_dates(list(all_by_date.keys()))

    if not dates:
        raise SystemExit("No dates found to backtest.")

    # ---- run ----
    init_cap = float(args.init_capital)
    equity = init_cap
    peak = init_cap
    prev_weights: Dict[str, float] = {}

    backtest_rows: List[dict] = []
    attrib_rows: List[dict] = []
    holdings_rows: List[dict] = []
    plan_rows: List[dict] = []

    for i, d in enumerate(dates):
        prev_date = dates[i - 1] if i > 0 else d

        market_ok, trend_ok = _get_market_flags(market_by_date, d)
        breadth_metric = _get_breadth_metric(breadth_by_date, d, args.breadth_field)

        risk_on = bool(market_ok) and bool(trend_ok) and (not math.isnan(breadth_metric)) and (breadth_metric >= float(args.breadth_min))
        risk_mode = "RISK_ON" if risk_on else "RISK_OFF"

        target_holdings = int(args.holdings_on) if risk_on else 0

        pick = _select_codes_for_prev_date(
            prev_date=prev_date,
            target_holdings=target_holdings,
            threshold=float(args.threshold),
            ranking_by_date=ranking_by_date,
            all_by_date=all_by_date,
        )

        # weights
        cur_weights: Dict[str, float] = {}
        if pick.codes:
            w = 1.0 / float(len(pick.codes))
            for c in pick.codes:
                cur_weights[str(c)] = w

        # compute returns
        returns_count = 0
        gross = 0.0

        # If NO_PICKS on RISK_ON => do NOT charge turnover/cost, do NOT pretend turnover.
        if risk_on and len(cur_weights) == 0 and pick.status == "NO_PICKS":
            turnover = 0.0
            cost_frac = 0.0
            net = 0.0
        else:
            turnover = _compute_turnover(prev_weights, cur_weights)
            cost_frac = turnover * (float(args.cost_bps) / 10000.0)

            # realized gross (missing returns treated as 0 to avoid bias / keep deterministic)
            for c, w in cur_weights.items():
                r = _get_ret(all_by_date, d, c)
                if r is not None:
                    returns_count += 1
                    gross += w * r
                else:
                    gross += 0.0

            net = gross - cost_frac

        # equity update
        equity = equity * (1.0 + net)
        peak = max(peak, equity)
        drawdown = 0.0 if peak <= 0 else (peak - equity) / peak

        # exports: holdings detail
        for c, w in cur_weights.items():
            r = _get_ret(all_by_date, d, c)
            contrib = 0.0 if r is None else (w * r)
            holdings_rows.append({
                "date": d,
                "prev_date": prev_date,
                "prev_date_used": pick.prev_date_used,
                "code": c,
                "weight": w,
                "ret": "" if r is None else r,
                "contrib": contrib,
                "risk_mode": risk_mode,
                "selection_source": pick.source,
                "status": pick.status,
            })

        picked_count = len(cur_weights)
        # attribution per day
        attrib_rows.append({
            "date": d,
            "prev_date": prev_date,
            "prev_date_used": pick.prev_date_used,
            "risk_mode": risk_mode,
            "market_ok": bool(market_ok),
            "trend_ok": bool(trend_ok),
            "breadth_field": args.breadth_field,
            "breadth_metric": "" if math.isnan(breadth_metric) else breadth_metric,
            "breadth_min": float(args.breadth_min),
            "threshold": float(args.threshold),
            "holdings": picked_count,
            "picked_count": picked_count,
            "returns_count": returns_count,
            "turnover": turnover,
            "gross_return": gross,
            "cost_frac": cost_frac,
            "net_return": net,
            "equity": equity,
            "drawdown": drawdown,
            "selection_source": pick.source,
            "status": pick.status,
        })

        # plan daily rows (one row per pick; if none, output 1 blank row w/ status)
        if picked_count == 0:
            plan_rows.append({
                "date": d,
                "prev_date": prev_date,
                "prev_date_used": pick.prev_date_used,
                "risk_mode": risk_mode,
                "market_ok": bool(market_ok),
                "trend_ok": bool(trend_ok),
                "breadth_field": args.breadth_field,
                "breadth_metric": "" if math.isnan(breadth_metric) else breadth_metric,
                "breadth_min": float(args.breadth_min),
                "threshold": float(args.threshold),
                "rank": "",
                "code": "",
                "name": "",
                "sector": "",
                "total_score": "",
                "weight": "",
                "picked_count": picked_count,
                "returns_count": returns_count,
                "status": pick.status,
                "selection_source": pick.source,
            })
        else:
            # rank + total_score: best-effort from ranking_history on prev_date_used, else from all_stocks_daily
            rh = ranking_by_date.get(pick.prev_date_used)
            rank_map: Dict[str, int] = {}
            score_map: Dict[str, float] = {}

            if rh is not None and len(rh) > 0 and "code" in rh.columns:
                tmp = rh.copy()
                tmp["code"] = tmp["code"].astype(str)
                if "rank" in tmp.columns:
                    for _, rr in tmp.iterrows():
                        c = str(rr.get("code", ""))
                        if c:
                            try:
                                rank_map[c] = int(float(rr.get("rank")))
                            except Exception:
                                pass
                if "total_score" in tmp.columns:
                    for _, rr in tmp.iterrows():
                        c = str(rr.get("code", ""))
                        if c:
                            score_map[c] = _to_float(rr.get("total_score", None), math.nan)

            for c, w in cur_weights.items():
                name, sector, src, ts = _lookup_meta(all_by_date, pick.prev_date_used, c)
                ts2 = score_map.get(c, ts)
                plan_rows.append({
                    "date": d,
                    "prev_date": prev_date,
                    "prev_date_used": pick.prev_date_used,
                    "risk_mode": risk_mode,
                    "market_ok": bool(market_ok),
                    "trend_ok": bool(trend_ok),
                    "breadth_field": args.breadth_field,
                    "breadth_metric": "" if math.isnan(breadth_metric) else breadth_metric,
                    "breadth_min": float(args.breadth_min),
                    "threshold": float(args.threshold),
                    "rank": rank_map.get(c, ""),
                    "code": c,
                    "name": name,
                    "sector": sector,
                    "total_score": "" if math.isnan(ts2) else ts2,
                    "weight": w,
                    "picked_count": picked_count,
                    "returns_count": returns_count,
                    "status": pick.status,
                    "selection_source": pick.source,
                })

        # backtest summary row
        backtest_rows.append({
            "date": d,
            "prev_date": prev_date,
            "risk_mode": risk_mode,
            "market_ok": bool(market_ok),
            "trend_ok": bool(trend_ok),
            "breadth_metric": "" if math.isnan(breadth_metric) else breadth_metric,
            "holdings": picked_count,
            "turnover": turnover,
            "gross_return": gross,
            "cost_frac": cost_frac,
            "net_return": net,
            "equity": equity,
            "drawdown": drawdown,
        })

        # debug print
        if args.debug_date and str(args.debug_date) == str(d):
            print("===== DEBUG_DATE =====")
            print(f"date={d} prev_date={prev_date} prev_date_used={pick.prev_date_used} risk_mode={risk_mode}")
            print(f"market_ok={market_ok} trend_ok={trend_ok} breadth_field={args.breadth_field} breadth_metric={breadth_metric} breadth_min={args.breadth_min}")
            print(f"threshold={args.threshold} target_holdings={target_holdings} selection_source={pick.source} status={pick.status}")
            print(f"picked_codes({len(pick.codes)}): {','.join(pick.codes)}")
            if pick.codes:
                # show returns breakdown
                pairs = []
                for c in pick.codes:
                    r = _get_ret(all_by_date, d, c)
                    pairs.append((c, -999 if r is None else r))
                # sort by ret desc
                pairs2 = sorted(pairs, key=lambda t: t[1], reverse=True)
                print("top_pos:")
                for c, r in pairs2[:10]:
                    print(f"  {c}  {'' if r == -999 else r}")
                print("top_neg:")
                for c, r in list(reversed(pairs2[-10:])):
                    print(f"  {c}  {'' if r == -999 else r}")
            print(f"returns_count={returns_count} gross_return={gross} cost_frac={cost_frac} net_return={net} turnover={turnover}")
            print("===== DEBUG_END =====")

        prev_weights = cur_weights

    # ---- metrics ----
    total_return = (equity / init_cap - 1.0) if init_cap > 0 else 0.0
    # daily bars count
    bars = max(1, len(backtest_rows))
    # naive annualization (252 trading days)
    ann = (1.0 + total_return) ** (252.0 / float(bars)) - 1.0 if bars > 0 else 0.0

    # max drawdown
    mdd = 0.0
    for r in backtest_rows:
        dd = _to_float(r.get("drawdown", 0.0), 0.0)
        mdd = max(mdd, dd)

    # sharpe (using net_return)
    rets = []
    for r in backtest_rows:
        rets.append(_to_float(r.get("net_return", 0.0), 0.0))
    mu = sum(rets) / float(len(rets)) if rets else 0.0
    var = sum((x - mu) ** 2 for x in rets) / float(len(rets)) if rets else 0.0
    sd = math.sqrt(var) if var > 0 else 0.0
    sharpe = (mu / sd * math.sqrt(252.0)) if sd > 0 else 0.0

    summary = {
        "init_capital": init_cap,
        "final_equity": equity,
        "total_return": total_return,
        "annualized_return": ann,
        "max_drawdown": mdd,
        "sharpe": sharpe,
        "bars": len(backtest_rows),
        "breadth_field": args.breadth_field,
        "breadth_min": float(args.breadth_min),
        "cost_bps": float(args.cost_bps),
        "holdings_on": int(args.holdings_on),
        "threshold": float(args.threshold),
        "ranking_source": ranking_source,
    }

    # ---- write outputs ----
    _write_csv("reports/portfolio_backtest_v3.csv", backtest_rows)
    _write_csv("reports/portfolio_attribution_v3.csv", attrib_rows)
    _write_csv("reports/portfolio_holdings_v3.csv", holdings_rows)
    _write_csv("reports/portfolio_plan_v3_daily.csv", plan_rows)
    _write_json("reports/portfolio_backtest_v3_summary.json", summary)

    print("OK: wrote -> reports/portfolio_backtest_v3.csv")
    print("OK: wrote -> reports/portfolio_holdings_v3.csv")
    print("OK: wrote -> reports/portfolio_attribution_v3.csv")
    print("OK: wrote -> reports/portfolio_plan_v3_daily.csv")
    print("OK: wrote -> reports/portfolio_backtest_v3_summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())