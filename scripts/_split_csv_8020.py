import sys
from pathlib import Path
import pandas as pd

def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: python _split_csv_8020.py <src> <train> <test>")
        return 2

    src = Path(sys.argv[1])
    train = Path(sys.argv[2])
    test = Path(sys.argv[3])

    if not src.exists():
        print(f"Missing src: {src}")
        return 2

    df = pd.read_csv(src)
    if df is None or df.empty:
        print("CSV empty")
        return 2

    n = len(df)
    if n < 30:
        print(f"CSV too small: rows={n} (need >= 30 for meaningful WF)")
        return 2

    # keep input order; if you want to enforce date sort, uncomment:
    # if "date" in df.columns:
    #     df["date"] = pd.to_datetime(df["date"], errors="coerce")
    #     df = df.sort_values("date").dropna(subset=["date"])

    cut = int(n * 0.8)
    df.iloc[:cut].to_csv(train, index=False, encoding="utf-8")
    df.iloc[cut:].to_csv(test, index=False, encoding="utf-8")

    print(f"OK split rows: total={n} train={cut} test={n-cut}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
