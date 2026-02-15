import argparse, json, os
from datetime import datetime

def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--regime", default="")
    ap.add_argument("--inplace", action="store_true")
    args = ap.parse_args()

    date = args.date.strip()
    snapshot_path = args.snapshot or os.path.join("reports", f"market_snapshot_{date}.json")
    regime_path = args.regime or os.path.join("reports", f"regime_{date}.json")

    if not os.path.exists(snapshot_path):
        raise SystemExit(f"Missing snapshot: {snapshot_path}")
    if not os.path.exists(regime_path):
        raise SystemExit(f"Missing regime: {regime_path}")

    snap = read_json(snapshot_path)
    reg = read_json(regime_path)

    # backup
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    bak = snapshot_path + f".bak_{ts}"
    with open(snapshot_path, "rb") as rf:
        raw = rf.read()
    with open(bak, "wb") as wf:
        wf.write(raw)

    # merge: keep full regime block
    snap["regime"] = reg

    # promote common fields to top-level (dashboard/other scripts can read easily)
    promote = [
        "market_regime",
        "volatility_state",
        "trend_strength",
        "volatility_proxy",
        "confidence_score",
        "suggested_exposure",
        "no_trade_flag",
        "no_trade_reason",
        "note",
        "version",
    ]
    for k in promote:
        if k in reg:
            snap[k] = reg[k]

    write_json(snapshot_path, snap)
    print(snapshot_path)
    print(bak)

if __name__ == "__main__":
    main()