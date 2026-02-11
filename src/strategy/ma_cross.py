from typing import List, Optional
from src.domain.models import Decision
from src.strategy.base import Strategy


class MACrossStrategy(Strategy):
    def __init__(self, ma_short: int, ma_long: int):
        if ma_short <= 0 or ma_long <= 0 or ma_short >= ma_long:
            raise ValueError("Invalid MA parameters")
        self.ma_short = ma_short
        self.ma_long = ma_long

    def decide(
        self,
        symbol: str,
        closes: List[float],
    ) -> Optional[Decision]:
        if len(closes) < self.ma_long + 1:
            return None

        short_prev = sum(closes[-self.ma_short - 1 : -1]) / self.ma_short
        long_prev = sum(closes[-self.ma_long - 1 : -1]) / self.ma_long

        short_now = sum(closes[-self.ma_short :]) / self.ma_short
        long_now = sum(closes[-self.ma_long :]) / self.ma_long

        if short_prev <= long_prev and short_now > long_now:
            return Decision("BUY", symbol, None, 1, "golden_cross")

        if short_prev >= long_prev and short_now < long_now:
            return Decision("SELL", symbol, None, 1, "death_cross")

        return None
