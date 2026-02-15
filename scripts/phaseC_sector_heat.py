import argparse, json, os, sys
from datetime import datetime
import pandas as pd

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True, help="YYYY-MM-DD")
    ap.add_argument("--csv", default=os.path.join("data","all_stocks_daily.csv"))
    ap.add_argument("--out", default="")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--min_count", type=int, default=10)
    args = ap.parse_args()

    date = args.date.strip()
    if not date:
        raise SystemExit("date required")

    csv_path = args.csv
    if not os.path.exists(csv_path):
        raise SystemExit(f"CSV not found: {csv_path}")

    df = pd.read_csv(csv_path, low_memory=False)
    # expected columns: date, code, name, sector, change_percent, total_score
    need = {"date","sector","change_percent","total_score"}
    miss = [c for c in need if c not in df.columns]
    if miss:
        raise SystemExit(f"CSV missing columns: {miss}")

    d = df[df["date"].astype(str) == date].copy()
    if d.empty:
        raise SystemExit(f"No rows for date={date} in {csv_path}")

    # sanitize
    d["sector"] = d["sector"].fillna("Unknown").astype(str).str.strip()
    d.loc[d["sector"]=="", "sector"] = "Unknown"
    d["change_percent"] = pd.to_numeric(d["change_percent"], errors="coerce")
    d["total_score"] = pd.to_numeric(d["total_score"], errors="coerce")
    d = d.dropna(subset=["change_percent","total_score"])

    # breadth
    adv = int((d["change_percent"] > 0).sum())
    dec = int((d["change_percent"] < 0).sum())
    flat = int((d["change_percent"] == 0).sum())
    total = int(len(d))
    adv_ratio = round(adv / total, 4) if total else 0.0
    dec_ratio = round(dec / total, 4) if total else 0.0

    # score distribution (for "強弱股比例")
    strong = int((d["total_score"] >= 80).sum())
    mid_bull = int(((d["total_score"] >= 60) & (d["total_score"] <= 79)).sum())
    mid_range = int(((d["total_score"] >= 40) & (d["total_score"] <= 59)).sum())
    weak = int((d["total_score"] < 40).sum())

    # concentration: top/bottom by total_score
    d_sorted = d.sort_values("total_score", ascending=False)
    top_n = max(10, min(200, int(total * 0.05)))  # 5% capped
    bot_n = top_n
    top_mean = float(d_sorted.head(top_n)["change_percent"].mean()) if total else 0.0
    bot_mean = float(d_sorted.tail(bot_n)["change_percent"].mean()) if total else 0.0

    # sector heat
    g = (d.groupby("sector", dropna=False)
           .agg(
               count=("sector","size"),
               avg_change=("change_percent","mean"),
               avg_score=("total_score","mean")
           )
           .reset_index())

    g = g[g["count"] >= args.min_count].copy()
    if g.empty:
        # fallback: no min_count filter
        g = (d.groupby("sector", dropna=False)
               .agg(count=("sector","size"),
                    avg_change=("change_percent","mean"),
                    avg_score=("total_score","mean"))
               .reset_index())

    # ranking: score first, then change
    g["avg_change"] = g["avg_change"].astype(float)
    g["avg_score"] = g["avg_score"].astype(float)

    hot = g.sort_values(["avg_score","avg_change","count"], ascending=[False,False,False]).head(args.top)
    weakz = g.sort_values(["avg_score","avg_change","count"], ascending=[True,True,False]).head(args.top)

    def pack(df_):
        out = []
        for _, r in df_.iterrows():
            out.append({
                "sector": str(r["sector"]),
                "count": int(r["count"]),
                "avg_change_percent": round(float(r["avg_change"]), 3),
                "avg_total_score": round(float(r["avg_score"]), 2),
            })
        return out

    payload = {
        "date": date,
        "source_csv": os.path.normpath(csv_path),
        "generated_at": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
        "breadth": {
            "total": total,
            "adv": adv, "dec": dec, "flat": flat,
            "adv_ratio": adv_ratio, "dec_ratio": dec_ratio
        },
        "score_buckets": {
            "strong_80_plus": strong,
            "bull_60_79": mid_bull,
            "range_40_59": mid_range,
            "weak_under_40": weak
        },
        "concentration": {
            "top_n": top_n,
            "bottom_n": bot_n,
            "top_mean_change_percent": round(top_mean, 3),
            "bottom_mean_change_percent": round(bot_mean, 3)
        },
        "sectors": {
            "hot_top": pack(hot),
            "weak_top": pack(weakz)
        }
    }

    out_path = args.out.strip()
    if not out_path:
        out_path = os.path.join("reports", f"sector_heat_{date}.json")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print(out_path)

if __name__ == "__main__":
    main()