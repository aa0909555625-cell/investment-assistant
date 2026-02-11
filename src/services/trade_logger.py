from __future__ import annotations

import csv
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from typing import Optional


class TradeLogger:
    """
    Append fills to a CSV file with a fixed schema.
    Ensures header exists and column order is stable.
    """

    FIELDNAMES = [
        "ts",
        "action",
        "symbol",
        "fill_price",
        "quantity",
        "fee",
        "cash_delta",
        "cash_after",
        "position_qty",
        "position_avg_cost",
        "note",
    ]

    def __init__(self, path: Path):
        self.path = path

    def append_fill(
        self,
        *,
        action: str,
        symbol: str,
        fill_price: float,
        quantity: int,
        fee: float,
        cash_delta: float,
        cash_after: float,
        position_qty: int,
        position_avg_cost: float,
        note: str,
        ts: Optional[datetime] = None,
    ) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

        write_header = (not self.path.exists()) or (self.path.stat().st_size == 0)

        row = {
            "ts": (ts or datetime.now()).isoformat(timespec="seconds"),
            "action": str(action),
            "symbol": str(symbol),
            "fill_price": f"{float(fill_price):.6f}",
            "quantity": int(quantity),
            "fee": f"{float(fee):.6f}",
            "cash_delta": f"{float(cash_delta):.6f}",
            "cash_after": f"{float(cash_after):.6f}",
            "position_qty": int(position_qty),
            "position_avg_cost": f"{float(position_avg_cost):.6f}",
            "note": str(note),
        }

        with self.path.open("a", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=self.FIELDNAMES)
            if write_header:
                w.writeheader()
            w.writerow(row)
