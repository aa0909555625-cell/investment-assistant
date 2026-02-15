import argparse, json, os
from datetime import datetime

def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--sector", default="")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    date = args.date.strip()
    snapshot_path = args.snapshot or os.path.join("reports", f"market_snapshot_{date}.json")
    sector_path   = args.sector   or os.path.join("reports", f"sector_heat_{date}.json")
    out_path      = args.out      or os.path.join("reports", f"regime_{date}.json")

    snap = read_json(snapshot_path)
    sec = read_json(sector_path) if os.path.exists(sector_path) else {}

    idx = snap.get("indices", {}) or {}
    taiex = idx.get("taiex", {}) or {}
    tpex  = idx.get("tpex", {}) or {}

    taiex_pct = float(taiex.get("change_percent", 0.0) or 0.0)
    tpex_pct  = float(tpex.get("change_percent", 0.0) or 0.0)

    metrics = snap.get("metrics", {}) or {}
    heat_spread = float(metrics.get("heat_spread", 0.0) or 0.0)
    index_div = metrics.get("index_divergence", None)
    index_div = float(index_div) if index_div is not None else abs(taiex_pct - tpex_pct)

    breadth = (sec.get("breadth", {}) or {})
    adv_ratio = float(breadth.get("adv_ratio", 0.0) or 0.0)

    # ---- v0 features ----
    abs_move = abs(taiex_pct)
    trend_strength = clamp((abs_move / 2.0) * 0.6 + clamp(adv_ratio) * 0.4)  # ~0..1
    vol_proxy = clamp((heat_spread / 20.0) * 0.7 + (index_div / 2.0) * 0.3)  # ~0..1

    # ---- regime rules (v0) ----
    is_trend = (abs_move >= 1.0 and adv_ratio >= 0.55)
    is_highvol = (heat_spread >= 12.0 or index_div >= 1.5)

    if is_highvol and not is_trend:
        regime = "HighVolatility"
    elif is_trend:
        regime = "Trend"
    else:
        regime = "Range"

    # confidence: stronger signals => higher confidence
    conf = 0.35
    conf += 0.35 * trend_strength
    conf += 0.30 * (1.0 - abs(vol_proxy - 0.5) * 2.0)  # stable mid vol => higher confidence
    conf = clamp(conf)

    # suggested exposure by regime
    if regime == "Trend":
        exposure = 0.70
        note = "Trend: follow momentum; keep stops; avoid chasing illiquid names."
    elif regime == "Range":
        exposure = 0.40
        note = "Range: mean-revert / selective; reduce hold time; avoid overtrading."
    else:
        exposure = 0.20
        note = "HighVol: reduce exposure; prioritize risk; consider no-trade windows."

    # volatility state label
    if vol_proxy >= 0.70:
        vol_state = "High"
    elif vol_proxy >= 0.40:
        vol_state = "Medium"
    else:
        vol_state = "Low"

    out = {
        "date": date,
        "market_regime": regime,
        "volatility_state": vol_state,
        "trend_strength": round(trend_strength, 4),
        "volatility_proxy": round(vol_proxy, 4),
        "confidence_score": round(conf, 4),
        "signals": {
            "taiex_change_percent": round(taiex_pct, 4),
            "tpex_change_percent": round(tpex_pct, 4),
            "adv_ratio": round(adv_ratio, 4),
            "heat_spread": round(heat_spread, 4),
            "index_divergence": round(index_div, 4)
        },
        "suggested_exposure": round(exposure, 4),
        "note": note,
        "generated_at": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
        "version": "regime_v0"
    }

    write_json(out_path, out)
    print(out_path)

if __name__ == "__main__":
    main()