from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple, Union


@dataclass
class EquityRecord:
    date: str
    cash: float
    position_value: float
    total_value: float


class EquityCurve:
    def __init__(self, *, start_cash: float = None, initial_cash: float = None):
        if start_cash is None and initial_cash is None:
            raise TypeError("EquityCurve requires start_cash / initial_cash")

        self.start_cash = start_cash if start_cash is not None else initial_cash
        self.records: List[EquityRecord] = []

    def mark(self, date, cash: float, position_value: float):
        total = cash + position_value
        self.records.append(
            EquityRecord(
                date=str(date),
                cash=float(cash),
                position_value=float(position_value),
                total_value=float(total),
            )
        )

    def write_csv(self, path: Union[str, Path]):
        path = Path(path)  # ✅ 關鍵修正：統一轉成 Path
        path.parent.mkdir(parents=True, exist_ok=True)

        with path.open("w", encoding="utf-8") as f:
            f.write("date,cash,position_value,total_value\n")
            for r in self.records:
                f.write(
                    f"{r.date},{r.cash},{r.position_value},{r.total_value}\n"
                )
