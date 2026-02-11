from __future__ import annotations

from pathlib import Path

from src.market_data import load_market_data


def pick_csv() -> Path | None:
    """
    Pick the best available CSV for 2330 market data.

    Priority:
      1) ./data/2330.csv
      2) ./data/prices_2330.csv
    """
    root = Path(__file__).resolve().parent
    candidates = [
        root / "data" / "2330.csv",
        root / "data" / "prices_2330.csv",
    ]
    for p in candidates:
        if p.exists() and p.is_file():
            return p
    return None


def main() -> int:
    csv_path = pick_csv()
    if not csv_path:
        print("[WARN] CSV not found: data/2330.csv or data/prices_2330.csv. Skipping market data check.")
        print("       Hint: put your CSV under ./data/ (2330.csv preferred).")
        return 2

    try:
        md = load_market_data(str(csv_path))
    except Exception as e:
        print(f"[ERROR] Failed to load MarketData from: {csv_path}")
        print(f"        {type(e).__name__}: {e}")
        return 1

    print("[OK] MarketData loaded")
    print("csv:", str(csv_path))
    print("dates len:", len(md.dates))
    print("closes len:", len(md.closes))
    print("first 5 dates:", md.dates[:5])
    print("first 5 closes:", md.closes[:5])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())