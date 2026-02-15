# -*- coding: utf-8 -*-
"""
allocation_pack_v1.py (Step 7-12)
Adds:
- Bucket allocation: ETF / LARGE / SMALL with configurable ratios
- Score-weighted allocation within bucket + max/min weight caps
- Exposure range + tranche plan
- Per-item reason + bucket fields
"""
import argparse
import csv
import json
import os
import re
from typing import Dict, Any, List, Tuple, Optional


def read_json(path: str) -> Optional[Dict[str, Any]]:
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def safe_float(v, default=0.0) -> float:
    try:
        if v is None:
            return default
        if isinstance(v, (int, float)):
            return float(v)
        s = str(v).strip().replace("%", "")
        if s == "" or s.lower() == "nan":
            return default
        return float(s)
    except Exception:
        return default


def safe_int(v, default=0) -> int:
    try:
        if v is None:
            return default
        if isinstance(v, int):
            return v
        s = str(v).strip()
        if s == "" or s.lower() == "nan":
            return default
        return int(float(s))
    except Exception:
        return default


def find_latest_ranking(data_dir: str) -> Tuple[str, str]:
    pat = re.compile(r"^ranking_(\d{4}-\d{2}-\d{2})\.csv$", re.I)
    best = None
    for name in os.listdir(data_dir):
        m = pat.match(name)
        if m:
            d = m.group(1)
            if best is None or d > best[0]:
                best = (d, os.path.join(data_dir, name))
    if best:
        return best
    raise RuntimeError("No ranking_YYYY-MM-DD.csv found in data/. Run weekly_pipeline.py first.")


def read_csv(path: str) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)
    return rows


def normalize_ranking(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out = []
    for r in rows:
        code = (r.get("code") or r.get("symbol") or "").strip()
        if not code:
            continue
        name = (r.get("name") or "").strip() or code
        sector = (r.get("sector") or r.get("industry") or "").strip() or "UNKNOWN"
        score = safe_float(r.get("total_score", r.get("score", "")), default=0.0)
        rank = safe_int(r.get("rank", ""), default=0)
        date = (r.get("date") or "").strip()
        out.append({
            "date": date,
            "code": code,
            "name": name,
            "sector": sector,
            "rank": rank if rank > 0 else None,
            "score": score,
            "source": (r.get("source") or "").strip()
        })
    # sort by score desc, then rank asc
    out.sort(key=lambda x: (-safe_float(x.get("score"), 0.0), safe_int(x.get("rank") or 999999, 999999), x.get("code")))
    return out


def is_etf(code: str) -> bool:
    # TW ETF often begins with 00 (0050/006208/00757...)
    c = (code or "").strip()
    return len(c) == 4 and c.startswith("00")


def bucket_of(item: Dict[str, Any], large_rank_threshold: int) -> str:
    if is_etf(item.get("code", "")):
        return "ETF"
    r = item.get("rank")
    if r is not None and safe_int(r, 999999) <= large_rank_threshold:
        return "LARGE"
    return "SMALL"


def risk_to_exposure_range(risk_mode: str) -> Tuple[Tuple[float, float], float, str]:
    rm = (risk_mode or "").strip().lower()
    # (min,max), target, note
    if rm in ("risk_off", "off", "stop", "avoid"):
        return (0.0, 0.0), 0.0, "RISK_OFF: keep cash."
    if rm in ("cautious", "warning", "defensive"):
        return (0.15, 0.35), 0.30, "CAUTIOUS: reduce exposure, staged entries."
    if rm in ("normal", "neutral", "ok"):
        return (0.40, 0.70), 0.70, "NORMAL: staged entries, keep some cash."
    if rm in ("aggressive", "risk_on", "on"):
        return (0.70, 0.90), 0.85, "RISK_ON: higher exposure allowed (still staged)."
    return (0.30, 0.60), 0.60, "DEFAULT: moderate exposure."


def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def allocate_weights_score(items: List[Dict[str, Any]], max_w: float, min_w: float) -> List[float]:
    # score-weighted; if all scores are equal/zero -> equal weights
    scores = [max(0.0, safe_float(i.get("score"), 0.0)) for i in items]
    ssum = sum(scores)
    n = max(1, len(items))
    if ssum <= 0:
        w = [1.0 / n] * n
    else:
        w = [s / ssum for s in scores]

    # apply caps (simple iterative projection)
    # 1) cap max
    w = [min(max_w, wi) for wi in w]
    # 2) enforce min then renormalize with remaining mass
    # If min_w too high vs n, just equal weights
    if min_w * n > 0.999:
        return [1.0 / n] * n

    # bring up to min
    w = [max(min_w, wi) for wi in w]
    # renormalize
    total = sum(w)
    if total <= 0:
        return [1.0 / n] * n
    w = [wi / total for wi in w]

    # after renormalize, ensure max again (rare); one more pass
    w = [min(max_w, wi) for wi in w]
    total = sum(w)
    if total <= 0:
        return [1.0 / n] * n
    w = [wi / total for wi in w]
    return w


def split_by_bucket(items: List[Dict[str, Any]], large_rank_threshold: int) -> Dict[str, List[Dict[str, Any]]]:
    b = {"ETF": [], "LARGE": [], "SMALL": []}
    for it in items:
        b[bucket_of(it, large_rank_threshold)].append(it)
    return b


def redistribute_bucket_ratios(buckets: Dict[str, List[Dict[str, Any]]], ratios: Dict[str, float]) -> Dict[str, float]:
    # if a bucket is empty, redistribute its ratio proportionally to non-empty buckets
    active = [k for k,v in buckets.items() if len(v) > 0 and ratios.get(k,0) > 0]
    if not active:
        # fallback: everything 0
        return {k: 0.0 for k in ratios.keys()}
    missing = [k for k,v in buckets.items() if len(v) == 0 and ratios.get(k,0) > 0]
    total_missing = sum(ratios[k] for k in missing)
    base_total = sum(ratios[k] for k in active)
    out = dict(ratios)
    for k in missing:
        out[k] = 0.0
    if base_total <= 0:
        # equal distribute to active
        each = (1.0 / len(active))
        return { "ETF": (each if "ETF" in active else 0.0),
                 "LARGE": (each if "LARGE" in active else 0.0),
                 "SMALL": (each if "SMALL" in active else 0.0) }
    for k in active:
        out[k] = out[k] + total_missing * (out[k] / base_total)
    # normalize
    s = sum(out.values())
    if s > 0:
        out = {k: out[k]/s for k in out.keys()}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--capital", required=True, type=int)
    ap.add_argument("--outdir", default="reports")
    ap.add_argument("--root", default=".")
    ap.add_argument("--reports_dir", default="reports")
    ap.add_argument("--top", type=int, default=8)
    ap.add_argument("--min_items", type=int, default=1)

    # Step 7-12 knobs
    ap.add_argument("--large_rank_threshold", type=int, default=200)
    ap.add_argument("--bucket_etf", type=float, default=0.30)
    ap.add_argument("--bucket_large", type=float, default=0.40)
    ap.add_argument("--bucket_small", type=float, default=0.30)
    ap.add_argument("--max_weight", type=float, default=0.15)
    ap.add_argument("--min_weight", type=float, default=0.05)
    ap.add_argument("--cash_floor_pct", type=float, default=0.10)

    # tranche plan (3 steps)
    ap.add_argument("--tranches", default="0.30,0.40,0.30")  # must sum to 1.0 (for investable portion)
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    data_dir = os.path.join(root, "data")
    reports_dir = os.path.join(root, args.reports_dir)
    outdir = os.path.join(root, args.outdir)
    os.makedirs(outdir, exist_ok=True)

    # ranking source
    ranking_path = os.path.join(data_dir, f"ranking_{args.date}.csv")
    source_used = ""
    if os.path.exists(ranking_path):
        date_used = args.date
        source_used = f"ranking:{os.path.relpath(ranking_path, root)}"
    else:
        date_used, ranking_path = find_latest_ranking(data_dir)
        source_used = f"ranking:{os.path.relpath(ranking_path, root)}"

    rows = read_csv(ranking_path)
    norm = normalize_ranking(rows)

    # pick top candidates
    need = max(args.top, args.min_items)
    candidates = norm[:need] if len(norm) >= need else norm[:]
    if len(candidates) < args.min_items:
        raise RuntimeError("Not enough candidates from ranking to satisfy min_items.")

    # market risk_mode -> exposure range + target
    market = read_json(os.path.join(reports_dir, "market_overview.json")) or {}
    decision = (market.get("decision") or {}) if isinstance(market, dict) else {}
    risk_mode = str(decision.get("risk_mode", "normal"))
    (exp_min, exp_max), exp_target, exp_note = risk_to_exposure_range(risk_mode)

    # enforce cash floor
    exp_target = clamp(exp_target, 0.0, 1.0 - float(args.cash_floor_pct))
    exp_min = clamp(exp_min, 0.0, 1.0 - float(args.cash_floor_pct))
    exp_max = clamp(exp_max, 0.0, 1.0 - float(args.cash_floor_pct))
    if exp_min > exp_max:
        exp_min, exp_max = exp_max, exp_min

    capital = int(args.capital)
    investable = int(round(capital * exp_target))
    cash_reserved = capital - investable

    # bucket split
    buckets = split_by_bucket(candidates, args.large_rank_threshold)
    ratios = {"ETF": float(args.bucket_etf), "LARGE": float(args.bucket_large), "SMALL": float(args.bucket_small)}
    ratios = redistribute_bucket_ratios(buckets, ratios)

    # weights within buckets
    max_w = float(args.max_weight)
    min_w = float(args.min_weight)

    # allocate investable by bucket
    bucket_budget = {k: int(round(investable * ratios.get(k, 0.0))) for k in ratios.keys()}
    # rounding fix
    diff = investable - sum(bucket_budget.values())
    if diff != 0:
        # add diff to the largest ratio bucket among active ones
        active = [k for k in ["LARGE","SMALL","ETF"] if len(buckets[k]) > 0]
        if active:
            best = max(active, key=lambda k: ratios.get(k,0.0))
            bucket_budget[best] += diff

    out_items: List[Dict[str, Any]] = []
    idx = 1
    for bk in ["ETF","LARGE","SMALL"]:
        items = buckets[bk]
        if not items:
            continue
        w_in = allocate_weights_score(items, max_w=max_w, min_w=min_w)
        b_budget = bucket_budget.get(bk, 0)
        amounts = [int(round(b_budget * wi)) for wi in w_in]
        d2 = b_budget - sum(amounts)
        if d2 != 0:
            amounts[0] += d2

        for i, it in enumerate(items):
            reason = f"bucket={bk}, score_rank={i+1}/{len(items)}"
            out_items.append({
                "idx": idx,
                "code": it.get("code"),
                "name": it.get("name"),
                "sector": it.get("sector"),
                "bucket": bk,
                "rank": it.get("rank"),
                "score": it.get("score"),
                "side": "BUY",
                "weight": w_in[i],
                "amount": amounts[i],
                "reason": reason,
                "warning": "",
                "source": "ranking"
            })
            idx += 1

    # tranche plan parse
    tr_raw = [safe_float(x, 0.0) for x in (args.tranches.split(",") if args.tranches else [])]
    if len(tr_raw) == 0:
        tr_raw = [1.0]
    s = sum(tr_raw)
    if s <= 0:
        tr_raw = [1.0]
        s = 1.0
    tr = [x/s for x in tr_raw]  # normalize
    tranche_amounts = [int(round(investable * x)) for x in tr]
    d3 = investable - sum(tranche_amounts)
    if d3 != 0:
        tranche_amounts[0] += d3

    payload = {
        "date": date_used,
        "requested_date": args.date,
        "capital": capital,
        "risk_mode": risk_mode,
        "exposure_range": {"min": exp_min, "max": exp_max},
        "exposure_target": exp_target,
        "investable": investable,
        "cash_reserved": cash_reserved,
        "cash_floor_pct": float(args.cash_floor_pct),
        "bucket_ratios": ratios,
        "items_count": len(out_items),
        "total_allocated": sum([x["amount"] for x in out_items]),
        "source_used": source_used,
        "notes": {
            "exposure_note": exp_note,
            "max_weight": max_w,
            "min_weight": min_w,
            "large_rank_threshold": int(args.large_rank_threshold)
        },
        "tranches": [{"step": i+1, "pct": tr[i], "amount": tranche_amounts[i]} for i in range(len(tr))],
        "items": out_items
    }

    date_for_files = args.date
    csv_path = os.path.join(outdir, f"allocation_{date_for_files}.csv")
    json_path = os.path.join(outdir, f"allocation_{date_for_files}.json")

    csv_fields = ["date","idx","code","name","sector","bucket","rank","score","side","weight","amount","reason","warning","source"]
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=csv_fields)
        w.writeheader()
        for it in out_items:
            w.writerow({
                "date": date_used,
                "idx": it["idx"],
                "code": it["code"],
                "name": it["name"],
                "sector": it["sector"],
                "bucket": it["bucket"],
                "rank": "" if it["rank"] is None else it["rank"],
                "score": "" if it["score"] is None else it["score"],
                "side": it["side"],
                "weight": it["weight"],
                "amount": it["amount"],
                "reason": it["reason"],
                "warning": it["warning"],
                "source": it["source"],
            })

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print(f"[OK] wrote -> {os.path.relpath(csv_path, root)}")
    print(f"[OK] wrote -> {os.path.relpath(json_path, root)}")
    print(f"[INFO] date={date_used} items={len(out_items)} investable={investable} cash_reserved={cash_reserved} risk_mode={risk_mode} exposure_target={exp_target:.2f} range=({exp_min:.2f}-{exp_max:.2f}) source_used={source_used}")


if __name__ == "__main__":
    main()