import argparse
import os
from io import StringIO
import requests
import pandas as pd

def normalize_symbol(sym: str) -> str:
    s = (sym or "").strip()
    # common aliases -> stooq index symbols
    alias = {
        "^twii": "^twse",   # TAIEX
        "twii": "^twse",
        "^taiex": "^twse",
        "taiex": "^twse",
        "^twse": "^twse",
    }
    key = s.lower()
    if key in alias:
        return alias[key]
    # if user passed TWSE without caret, fix it
    if key == "twse":
        return "^twse"
    return s

def fetch_stooq_csv(symbol: str, timeout=25) -> str:
    # Stooq daily CSV endpoint
    # Example: https://stooq.com/q/d/l/?s=^twse&i=d
    url = f"https://stooq.com/q/d/l/?s={symbol}&i=d"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0",
        "Accept": "text/csv,text/plain,*/*",
    }
    r = requests.get(url, headers=headers, timeout=timeout)
    r.raise_for_status()
    text = r.text or ""
    return text

def parse_daily_csv(text: str) -> pd.DataFrame:
    # Heuristic: ensure it's a CSV with Date header
    head = text.strip()[:200].replace("\r"," ").replace("\n"," ")
    if "Date" not in text[:200] and "date" not in text[:200]:
        raise RuntimeError(f"Response is not a CSV with Date header. First 200 chars: {head}")

    df = pd.read_csv(StringIO(text))
    # normalize columns
    df.columns = [c.strip().lower() for c in df.columns]

    # Stooq usually: Date,Open,High,Low,Close,Volume
    if "date" not in df.columns:
        raise RuntimeError(f"CSV parsed but missing 'date' column. Columns={list(df.columns)}")

    df["date"] = pd.to_datetime(df["date"], errors="coerce").dt.strftime("%Y-%m-%d")
    df = df.dropna(subset=["date"])

    # Ensure standard output columns
    keep = ["date", "open", "high", "low", "close", "volume"]
    for c in keep:
        if c not in df.columns:
            df[c] = None
    df = df[keep].dropna(subset=["close"])
    return df

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", required=True, help="stooq symbol, e.g. ^TWSE (TAIEX)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--min_rows", type=int, default=300)
    ap.add_argument("--timeout", type=int, default=25)
    args = ap.parse_args()

    symbol = normalize_symbol(args.symbol)
    text = fetch_stooq_csv(symbol, timeout=args.timeout)
    df = parse_daily_csv(text)

    if len(df) < args.min_rows:
        raise SystemExit(f"Too few rows: {len(df)} (<{args.min_rows}) for symbol={symbol}")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    df.to_csv(args.out, index=False, encoding="utf-8")
    print(args.out)

if __name__ == "__main__":
    main()