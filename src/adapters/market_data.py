from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import csv


@dataclass
class MarketDataResult:
    dates: list[str]
    closes: list[float]

    def closes_upto(self, symbol: str, date: str) -> list[float]:
        out = []
        for d, c in zip(self.dates, self.closes):
            if d <= date:
                out.append(c)
            else:
                break
        return out

    def last_price_on(self, symbol: str, date: str) -> float:
        last = None
        for d, c in zip(self.dates, self.closes):
            if d <= date:
                last = c
            else:
                break
        return float(last) if last is not None else 0.0


def load_prices_from_csv(csv_path: str | Path) -> MarketDataResult:
    dates, closes = [], []
    path = Path(csv_path)

    if not path.exists():
        return MarketDataResult([], [])

    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if "date" in r and "close" in r:
                dates.append(r["date"])
                closes.append(float(r["close"]))

    pairs = sorted(zip(dates, closes), key=lambda x: x[0])
    return MarketDataResult(
        dates=[p[0] for p in pairs],
        closes=[p[1] for p in pairs],
    )
