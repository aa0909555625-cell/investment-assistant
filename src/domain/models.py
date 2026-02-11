from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Optional


@dataclass(frozen=True)
class PriceBar:
    symbol: str
    d: date
    close: float


@dataclass(frozen=True)
class Decision:
    action: str  # BUY / SELL / HOLD
    symbol: Optional[str]
    price: Optional[float]
    quantity: int
    reason: str

    @staticmethod
    def buy(symbol: str, quantity: int = 1, reason: str = "ma_cross_buy") -> "Decision":
        return Decision("BUY", symbol, None, quantity, reason)

    @staticmethod
    def sell(symbol: str, quantity: int = 1, reason: str = "ma_cross_sell") -> "Decision":
        return Decision("SELL", symbol, None, quantity, reason)

    @staticmethod
    def hold(reason: str = "hold") -> "Decision":
        return Decision("HOLD", None, None, 0, reason)
