from __future__ import annotations

import json
from pathlib import Path
from dataclasses import dataclass, field
from typing import Dict


@dataclass
class Portfolio:
    cash: float
    positions: Dict[str, int] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path, default_cash: float) -> Portfolio:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            return cls(
                cash=float(data.get("cash", default_cash)),
                positions=data.get("positions", {}),
            )

        # 第一次執行
        return cls(cash=default_cash)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "cash": self.cash,
                    "positions": self.positions,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    def buy(self, symbol: str, qty: int, price: float, fee: float) -> None:
        cost = price * qty + fee
        if self.cash < cost:
            raise ValueError("Insufficient cash")

        self.cash -= cost
        self.positions[symbol] = self.positions.get(symbol, 0) + qty

    def sell(self, symbol: str, qty: int, price: float, fee: float) -> None:
        if self.positions.get(symbol, 0) < qty:
            raise ValueError("Insufficient position")

        self.positions[symbol] -= qty
        self.cash += price * qty - fee

    def position_value(self, symbol: str, price: float) -> float:
        return self.positions.get(symbol, 0) * price
