from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

from src.domain.portfolio import Portfolio
from src.services.broker import Fill


@dataclass(frozen=True)
class TradeLogRow:
    ts: str
    action: str
    symbol: str
    fill_price: float
    quantity: int
    fee: float
    cash_delta: float
    cash_after: float
    position_qty: int
    position_avg_cost: float
    note: str


class TradeLogger:
    def __init__(self, path: Path):
        self.path = path

    def append(self, fill: Fill, portfolio: Portfolio) -> None:
        # Derive position snapshot after fill
        pos = portfolio.positions.get(fill.symbol)
        pos_qty = int(pos.quantity) if pos else 0
        pos_avg = float(pos.avg_cost) if pos else 0.0

        row = TradeLogRow(
            ts=datetime.now().isoformat(timespec="seconds"),
            action=fill.action,
            symbol=fill.symbol,
            fill_price=float(fill.price),
            quantity=int(fill.quantity),
            fee=float(fill.fee),
            cash_delta=float(fill.cash_delta),
            cash_after=float(portfolio.cash),
            position_qty=pos_qty,
            position_avg_cost=pos_avg,
            note=str(fill.note),
        )

        self._write_row(row)

    def _write_row(self, row: TradeLogRow) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        is_new = not self.path.exists()

        with self.path.open("a", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            if is_new:
                writer.writerow(
                    [
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
                )

            writer.writerow(
                [
                    row.ts,
                    row.action,
                    row.symbol,
                    f"{row.fill_price:.6f}",
                    row.quantity,
                    f"{row.fee:.6f}",
                    f"{row.cash_delta:.6f}",
                    f"{row.cash_after:.6f}",
                    row.position_qty,
                    f"{row.position_avg_cost:.6f}",
                    row.note,
                ]
            )
