from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
from typing import List, Dict, Any


def _norm_key(s: str) -> str:
    """
    Normalize CSV header keys:
    - strip BOM (\ufeff)
    - trim whitespace
    - lowercase
    """
    if s is None:
        return ""
    return s.replace("\ufeff", "").strip().lower()


@dataclass(frozen=True)
class MarketData:
    """
    Minimal market data container used by Phase ③~⑦.

    Expected columns in CSV (case-insensitive, BOM-safe):
      - date
      - close

    Other columns are ignored.
    """
    dates: List[str]
    closes: List[float]
    _date_to_index: Dict[str, int]

    @classmethod
    def from_csv(cls, csv_path: str | Path) -> "MarketData":
        path = Path(csv_path)
        if not path.exists():
            raise FileNotFoundError(f"CSV not found: {path}")

        dates: List[str] = []
        closes: List[float] = []

        # utf-8-sig automatically strips BOM for the first header token in many cases,
        # but we still normalize keys to be safe.
        with path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                raise ValueError("CSV has no header row")

            # Build a mapping from normalized key -> original key
            field_map: Dict[str, str] = {}
            for raw in reader.fieldnames:
                nk = _norm_key(raw)
                if nk and nk not in field_map:
                    field_map[nk] = raw

            if "date" not in field_map or "close" not in field_map:
                got = [str(x) for x in (reader.fieldnames or [])]
                raise ValueError(
                    "CSV must contain 'date' and 'close' columns. got: " + str(got)
                )

            k_date = field_map["date"]
            k_close = field_map["close"]

            for row in reader:
                d = (row.get(k_date) or "").strip()
                c = (row.get(k_close) or "").strip()
                if not d or not c:
                    continue
                try:
                    close = float(c)
                except ValueError:
                    continue
                dates.append(d)
                closes.append(close)

        if not dates:
            raise ValueError("No valid rows parsed from CSV (need date/close).")

        date_to_index = {d: i for i, d in enumerate(dates)}
        return cls(dates=dates, closes=closes, _date_to_index=date_to_index)

    def closes_upto(self, date: str) -> List[float]:
        """
        Returns closes from beginning up to and including 'date'.
        """
        if date not in self._date_to_index:
            raise KeyError(f"Date not found in MarketData: {date}")
        idx = self._date_to_index[date]
        return self.closes[: idx + 1]

    def last_price_on(self, date: str) -> float:
        """
        Returns close price on 'date'.
        """
        if date not in self._date_to_index:
            raise KeyError(f"Date not found in MarketData: {date}")
        return float(self.closes[self._date_to_index[date]])

# -----------------------------------------------------------------------------
# Backward-compatible shim
# -----------------------------------------------------------------------------
def load_market_data(csv_path):
    """
    Backward-compatible helper for older scripts.
    Prefer: MarketData.from_csv(csv_path)
    """
    return MarketData.from_csv(csv_path)