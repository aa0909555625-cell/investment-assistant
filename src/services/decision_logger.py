from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional


@dataclass
class DecisionLogger:
    path: Path

    def _ensure_header(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists() and self.path.stat().st_size > 0:
            return
        with self.path.open("w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["ts", "action", "symbol", "price", "quantity", "reason"])

    def append(
        self,
        action: str,
        symbol: Optional[str],
        price: Optional[float],
        quantity: int,
        reason: str,
        ts: Optional[datetime] = None,
    ) -> None:
        self._ensure_header()
        if ts is None:
            ts = datetime.now()
        with self.path.open("a", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(
                [
                    ts.isoformat(timespec="seconds"),
                    str(action),
                    "" if symbol is None else str(symbol),
                    "" if price is None else f"{float(price):.6f}",
                    int(quantity),
                    str(reason),
                ]
            )
