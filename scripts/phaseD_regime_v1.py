import argparse, json, os
from datetime import datetime
import numpy as np
import pandas as pd

def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, float(x)))

def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def ema(series, span):
    return series.ewm(span=span, adjust=False).mean()

def atr14_pct(df):
    # ATR(14) / Close
    high = df["high"].astype(float)
    low = df["low"].astype(float)
    close = df["close"].astype(float)
    prev_close = close.shift(1)

    tr = pd.concat([
        (high - low).abs(),
        (high - prev_close).abs(),
        (low - prev_close).abs()
    ], axis=1).max(axis=1)

    atr = tr.rolling(14).mean()
    atr_pct = atr / close
    return atr, atr_pct

def adx14(df):
    # Classic Wilder ADX(14)
    high = df["high"].astype(float)
    low = df["low"].astype(float)
    close = df["close"].astype(float)

    up_move = high.diff()
    down_move = (-low.diff())

    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)

    prev_close = close.shift(1)
    tr = pd.concat([
        (high - low).abs(),
        (high - prev_close).abs(),
        (low - prev_close).abs()
    ], axis=1).max(axis=1)

    # Wilder smoothing via EMA with alpha=1/14 -> equivalent to ewm(alpha=1/14)
    atr = tr.ewm(alpha=1/14, adjust=False).mean()
    plus_di = 100 * (pd.Series(plus_dm, index=df.index).ewm(alpha=1/14, adjust=False).mean() / atr)
    minus_di = 100 * (pd.Series(minus_dm, index=df.index).ewm(alpha=1/14, adjust=False).mean() / atr)

    dx = 100 * ((plus_di - minus_di).abs() / (plus_di + minus_di))
    adx = dx.ewm(alpha=1/14, adjust=False).mean()
    return adx, plus_di, minus_di

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", required=True)
    ap.add_argument("--taiex_csv", default=os.path.join("data","taiex_daily.csv"))
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--sector", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--ma_slope_window", type=int, default=10)
    args = ap.parse_args()

    date = args.date.strip()
    snapshot_path = args.snapshot or os.path.join("reports", f"market_snapshot_{date}.json")
    sector_path = args.sector or os.path.join("reports", f"sector_heat_{date}.json")
    out_path = args.out or os.path.join("reports", f"regime_{date}.json")

    if not os.path.exists(args.taiex_csv):
        raise SystemExit(f"Missing taiex csv: {args.taiex_csv}")
    if not os.path.exists(snapshot_path):
        raise SystemExit(f"Missing snapshot: {snapshot_path}")

    snap = read_json(snapshot_path)
    sec = read_json(sector_path) if os.path.exists(sector_path) else {}

    # ----- load index OHLC -----
    df = pd.read_csv(args.taiex_csv, encoding="utf-8")
    df.columns = [c.strip().lower() for c in df.columns]
    need = ["date","open","high","low","close"]
    for c in need:
        if c not in df.columns:
            raise SystemExit(f"taiex csv missing column: {c}")

    df["date"] = pd.to_datetime(df["date"], errors="coerce").dt.strftime("%Y-%m-%d")
    df = df.dropna(subset=["date"]).sort_values("date").reset_index(drop=True)

    row = df[df["date"] == date]
    if row.empty:
        raise SystemExit(f"Date not found in taiex csv: {date}")

    # compute indicators on full history then take last row
    close = df["close"].astype(float)
    ma50 = close.rolling(50).mean()
    ma200 = close.rolling(200).mean()

    slope_w = max(3, int(args.ma_slope_window))
    ma50_slope = (ma50 - ma50.shift(slope_w)) / slope_w  # points per day
    ma50_slope_pct = ma50_slope / ma50  # slope as pct of ma50

    atr, atr_pct = atr14_pct(df)
    adx, plus_di, minus_di = adx14(df)

    # today's values (last matching row; safe)
    i = row.index[-1]
    o = float(df.loc[i, "open"])
    h = float(df.loc[i, "high"])
    l = float(df.loc[i, "low"])
    c = float(df.loc[i, "close"])
    prev_c = float(df.loc[i-1, "close"]) if i-1 >= 0 else c

    gap_pct = (o - prev_c) / prev_c if prev_c != 0 else 0.0

    ma50_v = float(ma50.loc[i]) if not np.isnan(ma50.loc[i]) else None
    ma200_v = float(ma200.loc[i]) if not np.isnan(ma200.loc[i]) else None
    slope_pct_v = float(ma50_slope_pct.loc[i]) if not np.isnan(ma50_slope_pct.loc[i]) else 0.0
    atr_pct_v = float(atr_pct.loc[i]) if not np.isnan(atr_pct.loc[i]) else 0.0
    adx_v = float(adx.loc[i]) if not np.isnan(adx.loc[i]) else 0.0

    # ----- tape/breadth features -----
    idx = (snap.get("indices", {}) or {}).get("taiex", {}) or {}
    taiex_chg_pct = float(idx.get("change_percent", 0.0) or 0.0)

    metrics = snap.get("metrics", {}) or {}
    heat_spread = float(metrics.get("heat_spread", 0.0) or 0.0)
    index_div = metrics.get("index_divergence", None)
    if index_div is None:
        # if missing, approximate with 0
        index_div = 0.0
    else:
        index_div = float(index_div)

    breadth = (sec.get("breadth", {}) or {})
    adv_ratio = float(breadth.get("adv_ratio", 0.0) or 0.0)

    # ----- volatility state (v1) -----
    # combine ATR% + heat_spread + divergence
    vol_proxy = clamp((atr_pct_v / 0.03) * 0.55 + (heat_spread / 20.0) * 0.35 + (index_div / 2.0) * 0.10)
    if vol_proxy >= 0.70:
        vol_state = "High"
    elif vol_proxy >= 0.40:
        vol_state = "Medium"
    else:
        vol_state = "Low"

    # ----- trend strength (v1) -----
    above_ma200 = 0.0
    if ma200_v is not None and ma200_v != 0:
        above_ma200 = clamp((c - ma200_v) / ma200_v * 5.0, 0.0, 1.0)  # 0..1 (scaled)
    slope_score = clamp((slope_pct_v / 0.0015), 0.0, 1.0)  # ~0.15%/day => 1
    adx_score = clamp((adx_v - 12.0) / 18.0, 0.0, 1.0)    # 12..30 => 0..1
    breadth_score = clamp((adv_ratio - 0.45) / 0.25, 0.0, 1.0)

    trend_strength = clamp(0.35*adx_score + 0.25*slope_score + 0.25*above_ma200 + 0.15*breadth_score)

    # ----- regime classification (v1) -----
    is_trend = (ma50_v is not None and ma200_v is not None
                and (ma50_v > ma200_v)
                and (slope_pct_v > 0)
                and (adx_v >= 20.0))

    is_highvol = (atr_pct_v >= 0.025) or (abs(gap_pct) >= 0.015) or (vol_state == "High")
    if is_highvol and not is_trend:
        regime = "HighVolatility"
    elif is_trend:
        regime = "Trend"
    else:
        regime = "Range"

    # ----- confidence -----
    # alignment + stability
    align = 0.0
    align += 0.35 * trend_strength
    align += 0.25 * (1.0 - abs(vol_proxy - 0.5) * 2.0)  # mid vol => higher
    align += 0.20 * clamp(abs(taiex_chg_pct) / 2.0, 0.0, 1.0)
    align += 0.20 * clamp(1.0 - (abs(gap_pct) / 0.03), 0.0, 1.0)
    confidence = clamp(align)

    # ----- no-trade rules (v1) -----
    no_trade = False
    reasons = []
    if abs(gap_pct) >= 0.015:
        no_trade = True
        reasons.append(f"GapTooLarge({gap_pct*100:.2f}%)")
    if atr_pct_v >= 0.03:
        no_trade = True
        reasons.append(f"ATRTooHigh({atr_pct_v*100:.2f}%)")
    if (index_div >= 1.8) and (adv_ratio >= 0.45 and adv_ratio <= 0.55):
        no_trade = True
        reasons.append(f"Divergence+Indecision(div={index_div:.2f}, adv={adv_ratio:.2f})")
    if (regime == "HighVolatility") and (confidence < 0.55):
        no_trade = True
        reasons.append(f"HighVolLowConf({confidence:.2f})")

    # ----- suggested exposure (v1) -----
    if no_trade:
        exposure = 0.0
    else:
        if regime == "Trend":
            exposure = 0.70
        elif regime == "Range":
            exposure = 0.40
        else:
            exposure = 0.20

        # downshift by vol_state
        if vol_state == "High":
            exposure *= 0.7
        elif vol_state == "Medium":
            exposure *= 0.9

    # ----- note (dashboard-friendly) -----
    if no_trade:
        note = "NO-TRADE: " + "; ".join(reasons)
    else:
        if regime == "Trend":
            note = "Trend: MA alignment + ADX supports trend. Follow momentum; manage stops."
        elif regime == "Range":
            note = "Range: ADX low / slope weak. Prefer mean-revert; reduce hold time."
        else:
            note = "HighVol: volatility elevated. Reduce exposure; wait for stabilization."

    out = {
        "date": date,
        "market_regime": regime,
        "volatility_state": vol_state,
        "trend_strength": round(float(trend_strength), 4),
        "volatility_proxy": round(float(vol_proxy), 4),
        "confidence_score": round(float(confidence), 4),
        "suggested_exposure": round(float(exposure), 4),
        "no_trade_flag": bool(no_trade),
        "no_trade_reason": "; ".join(reasons),
        "signals": {
            "taiex_change_percent": round(float(taiex_chg_pct), 4),
            "adv_ratio": round(float(adv_ratio), 4),
            "heat_spread": round(float(heat_spread), 4),
            "index_divergence": round(float(index_div), 4),
            "gap_percent": round(float(gap_pct), 6),
        },
        "indicators": {
            "close": round(float(c), 2),
            "ma50": round(float(ma50_v), 2) if ma50_v is not None else None,
            "ma200": round(float(ma200_v), 2) if ma200_v is not None else None,
            "ma50_slope_pct": round(float(slope_pct_v), 8),
            "atr14_pct": round(float(atr_pct_v), 6),
            "adx14": round(float(adx_v), 4),
        },
        "note": note,
        "generated_at": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
        "version": "regime_v1"
    }

    write_json(out_path, out)
    print(out_path)

if __name__ == "__main__":
    main()