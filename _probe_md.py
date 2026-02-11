from pathlib import Path
from src.market_data import load_market_data

paths = sorted(Path("data").glob("*.csv"))
print("Found CSVs:", [str(p) for p in paths])

for p in paths:
    try:
        md = load_market_data(str(p))
        dates = getattr(md, "dates", None)
        closes = getattr(md, "closes", None)
        print(f"\n== {p} ==")
        print("  dates type:", type(dates).__name__, "len:", (len(dates) if dates is not None else None))
        print("  closes type:", type(closes).__name__, "len:", (len(closes) if closes is not None else None))
        if dates:
            print("  first dates:", dates[:5])
        if closes:
            print("  first closes:", closes[:5])
    except Exception as e:
        print(f"\n== {p} ==")
        print("  ERROR:", repr(e))
