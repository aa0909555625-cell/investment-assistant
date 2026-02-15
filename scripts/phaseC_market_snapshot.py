import argparse, json, os
from datetime import datetime
import pandas as pd

def safe_float(x, default=0.0):
    try:
        if x is None: return default
        return float(x)
    except Exception:
        return default

def safe_str(x, default=""):
    try:
        if x is None: return default
        s = str(x)
        return s.strip()
    except Exception:
        return default

def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def load_indices(indices_path):
    if not os.path.exists(indices_path):
        return None
    with open(indices_path, "r", encoding="utf-8") as f:
        return json.load(f)

def compute_sector_heat(day_df, top_n=5):
    d = day_df.copy()
    d["sector"] = d["sector"].fillna("Unknown").astype(str).str.strip()
    d.loc[d["sector"]=="", "sector"] = "Unknown"
    d["change_percent"] = pd.to_numeric(d["change_percent"], errors="coerce")
    d["total_score"] = pd.to_numeric(d["total_score"], errors="coerce")
    d = d.dropna(subset=["change_percent", "total_score"])

    d["dir"] = d["change_percent"].apply(lambda v: "up" if v > 0 else ("down" if v < 0 else "flat"))

    g = (d.groupby("sector", dropna=False)
           .agg(
               count=("sector","size"),
               avg_total_score=("total_score","mean"),
               avg_change_percent=("change_percent","mean"),
               up=("dir", lambda s: int((s=="up").sum())),
               down=("dir", lambda s: int((s=="down").sum())),
               flat=("dir", lambda s: int((s=="flat").sum()))
           )
           .reset_index())

    # Heat score (simple, stable): score-weighted + change boost
    g["heat_score"] = g["avg_total_score"] * 1.0 + (g["avg_change_percent"] * 5.0)

    g = g.sort_values(["heat_score","avg_total_score","avg_change_percent","count"], ascending=[False,False,False,False])

    top = g.head(top_n).copy()
    weak = g.tail(top_n).sort_values(["heat_score","avg_total_score","avg_change_percent","count"], ascending=[True,True,True,False]).copy()

    def pack(df_):
        out = []
        for _, r in df_.iterrows():
            out.append({
                "sector": safe_str(r["sector"]),
                "count": int(r["count"]),
                "avg_total_score": round(float(r["avg_total_score"]), 2),
                "avg_change_percent": round(float(r["avg_change_percent"]), 3),
                "up": int(r["up"]),
                "down": int(r["down"]),
                "flat": int(r["flat"]),
                "heat_score": round(float(r["heat_score"]), 2),
            })
        return out

    return pack(top), pack(weak), g

def compute_metrics(day_df, indices_obj, sector_full_df):
    # heat_concentration_top3: top3 sectors by count / total
    total = len(day_df)
    conc = 0.0
    if total > 0 and sector_full_df is not None and not sector_full_df.empty:
        top3 = sector_full_df.sort_values("count", ascending=False).head(3)["count"].sum()
        conc = float(top3) / float(total)

    # heat_spread: (top heat_score - median heat_score)
    spread = 0.0
    if sector_full_df is not None and not sector_full_df.empty:
        top_h = float(sector_full_df["heat_score"].max())
        med_h = float(sector_full_df["heat_score"].median())
        spread = top_h - med_h

    # index_divergence: abs(taiex% - tpex%)
    div = None
    if isinstance(indices_obj, dict):
        taiex = indices_obj.get("taiex") or {}
        tpex = indices_obj.get("tpex") or {}
        div = abs(safe_float(taiex.get("change_percent"), 0.0) - safe_float(tpex.get("change_percent"), 0.0))

    return {
        "heat_concentration_top3": round(conc, 4),
        "heat_spread": round(spread, 4),
        "index_divergence": round(div, 4) if div is not None else None
    }

def compute_tape_summary(day_df, hot_sectors, weak_sectors):
    d = day_df.copy()
    d["change_percent"] = pd.to_numeric(d["change_percent"], errors="coerce")
    d = d.dropna(subset=["change_percent"])
    total = int(len(d))
    adv = int((d["change_percent"] > 0).sum())
    dec = int((d["change_percent"] < 0).sum())
    adv_ratio = (adv / total) if total else 0.0

    # Band + suggested position (Chinese, stable)
    if adv_ratio >= 0.70:
        band = "強勢突破"
        suggested_position = 0.75
        strategy = "偏多趨勢盤：可順勢提高曝險，優先挑強勢類股/強勢股，嚴守停損與回檔風險。"
    elif adv_ratio >= 0.55:
        band = "偏多區"
        suggested_position = 0.55
        strategy = "偏多盤：可分批布局，避免追高；以趨勢濾網搭配回檔承接較穩。"
    elif adv_ratio >= 0.40:
        band = "震盪區"
        suggested_position = 0.35
        strategy = "震盪盤：降低曝險、縮短持有期；以區間策略與風險控管優先。"
    else:
        band = "弱勢區"
        suggested_position = 0.20
        strategy = "偏空/弱勢盤：以風控優先，降低交易頻率，避免硬做；等待型態轉強再出手。"

    # zones (top3 names)
    hz = [z.get("sector","") for z in hot_sectors[:3]]
    wz = [z.get("sector","") for z in weak_sectors[:3]]

    return {
        "hot_zones": hz,
        "weak_zones": wz,
        "band": band,
        "strategy": strategy,
        "suggested_position": round(float(suggested_position), 4)
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default="", help="YYYY-MM-DD")
    ap.add_argument("--outdir", default="reports")
    ap.add_argument("--csv", default=os.path.join("data","all_stocks_daily.csv"))
    ap.add_argument("--top_sectors", type=int, default=5)
    # compat / ignored
    ap.add_argument("--capital", default=None)
    ap.add_argument("--top", default=None)
    args = ap.parse_args()

    date = args.date.strip() or datetime.now().strftime("%Y-%m-%d")
    outdir = args.outdir

    if not os.path.exists(args.csv):
        raise SystemExit(f"CSV not found: {args.csv}")

    # CSV: tolerate BOM + mixed types
    df = pd.read_csv(args.csv, encoding="utf-8-sig", low_memory=False)
    need = {"date","code","name","sector","change_percent","total_score"}
    missing = [c for c in need if c not in df.columns]
    if missing:
        raise SystemExit(f"CSV missing columns: {missing}")

    day = df[df["date"].astype(str) == date].copy()
    if day.empty:
        raise SystemExit(f"No rows for date={date} in {args.csv}")

    # Indices: prefer existing indices file if present
    indices_path = os.path.join(outdir, f"indices_{date}.json")
    indices_obj = load_indices(indices_path)

    # If not present, still emit placeholder indices block (keeps schema stable)
    if indices_obj is None:
        indices_obj = {}

    hot, weak, sector_full = compute_sector_heat(day, top_n=args.top_sectors)
    metrics = compute_metrics(day, indices_obj, sector_full)
    tape = compute_tape_summary(day, hot, weak)

    payload = {
        "date": date,
        "indices": indices_obj,
        "metrics": metrics,
        "tape_summary": tape,
        "sector_heat": {
            "top": hot,
            "weak": weak
        },
        "source": "phaseC_market_snapshot",
        "generated_at": datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
    }

    snap_path = os.path.join(outdir, f"market_snapshot_{date}.json")
    write_json(snap_path, payload)

    # also (re)write indices file as UTF-8 if exists (normalize encoding)
    # (only when it has content)
    if isinstance(indices_obj, dict) and len(indices_obj) > 0:
        write_json(indices_path, indices_obj)

    print(snap_path)

if __name__ == "__main__":
    main()