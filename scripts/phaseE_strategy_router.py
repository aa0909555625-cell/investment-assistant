import argparse, json, os
from datetime import datetime

def read_json(path: str):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def write_json(path: str, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def clamp(x, lo, hi):
    try:
        x = float(x)
    except Exception:
        x = lo
    return max(lo, min(hi, x))

def pick_strategy(regime: str, vol: str):
    regime = (regime or "").strip()
    vol = (vol or "").strip()
    if regime == "Trend":
        return ("trend_momentum_v1", "Trend regime: follow momentum; manage stops.")
    if regime == "Range":
        return ("range_mean_revert_v1", "Range regime: mean reversion; smaller targets; tighter risk.")
    if regime == "HighVolatility":
        return ("risk_off_v1", "HighVol regime: reduce exposure; prefer no-trade windows.")
    return ("unknown_v1", "Unknown regime: be conservative; validate data.")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--capital", type=float, default=300000.0)
    ap.add_argument("--max_positions", type=int, default=5)
    ap.add_argument("--min_exposure", type=float, default=0.0)
    ap.add_argument("--max_exposure", type=float, default=1.0)
    args = ap.parse_args()

    date = args.date.strip()
    snapshot_path = args.snapshot or os.path.join("reports", f"market_snapshot_{date}.json")
    out_path = args.out or os.path.join("reports", f"decision_{date}.json")

    if not os.path.exists(snapshot_path):
        raise SystemExit(f"Missing snapshot: {snapshot_path}")

    snap = read_json(snapshot_path)

    # snapshot-first promoted fields
    regime = snap.get("market_regime") or (snap.get("regime", {}) or {}).get("market_regime") or "NA"
    vol_state = snap.get("volatility_state") or (snap.get("regime", {}) or {}).get("volatility_state") or "NA"
    suggested_exposure = snap.get("suggested_exposure")
    if suggested_exposure is None:
        suggested_exposure = (snap.get("regime", {}) or {}).get("suggested_exposure", 0.3)

    no_trade_flag = snap.get("no_trade_flag")
    if no_trade_flag is None:
        no_trade_flag = (snap.get("regime", {}) or {}).get("no_trade_flag", False)

    no_trade_reason = snap.get("no_trade_reason")
    if no_trade_reason is None:
        no_trade_reason = (snap.get("regime", {}) or {}).get("no_trade_reason", "")

    note = snap.get("note") or (snap.get("regime", {}) or {}).get("note", "")

    # choose strategy
    strategy_id, strategy_note = pick_strategy(str(regime), str(vol_state))

    # exposure policy
    exp = clamp(suggested_exposure, args.min_exposure, args.max_exposure)
    if bool(no_trade_flag):
        exp = 0.0

    capital = float(args.capital)
    max_positions = max(1, int(args.max_positions))

    max_position_value = round(capital * exp, 2)
    per_trade_budget = round(max_position_value / max_positions, 2)

    decision = {
        "date": date,
        "inputs": {
            "capital": capital,
            "max_positions": max_positions,
            "regime": str(regime),
            "volatility_state": str(vol_state),
            "suggested_exposure_raw": suggested_exposure,
            "no_trade_flag": bool(no_trade_flag),
            "no_trade_reason": str(no_trade_reason or ""),
        },
        "decision": {
            "strategy_id": strategy_id,
            "exposure": exp,
            "max_position_value": max_position_value,
            "per_trade_budget": per_trade_budget,
            "allow_trade": (not bool(no_trade_flag)),
            "gate": "NO_TRADE" if bool(no_trade_flag) else "OK",
        },
        "notes": {
            "strategy_note": strategy_note,
            "regime_note": str(note or ""),
        },
        "generated_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "version": "decision_v1"
    }

    write_json(out_path, decision)
    print(out_path)

if __name__ == "__main__":
    main()