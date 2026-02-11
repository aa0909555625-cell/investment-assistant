from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from src.domain.config import AppConfig
from src.domain.models import Decision


def _sma(values: List[float], window: int) -> Optional[float]:
    if window <= 0:
        return None
    if len(values) < window:
        return None
    return sum(values[-window:]) / float(window)


@dataclass
class InvestmentEngine:
    config: AppConfig

    def decide(self, symbol: str, closes: List[float]) -> Decision:
        if not symbol:
            return Decision("HOLD", None, None, 0, "No symbol provided")

        if not closes:
            return Decision("HOLD", symbol, None, 0, "No price data")

        price = float(closes[-1])

        need = max(self.config.ma_short, self.config.ma_long)
        if len(closes) < need:
            return Decision(
                "HOLD",
                symbol,
                price,
                0,
                f"Not enough price history (need {need}, got {len(closes)})",
            )

        short_ma = _sma(closes, self.config.ma_short)
        long_ma = _sma(closes, self.config.ma_long)
        if short_ma is None or long_ma is None:
            return Decision("HOLD", symbol, price, 0, "MA unavailable")

        # previous-day MA for cross detection (need one more bar)
        prev_closes = closes[:-1]
        prev_short = _sma(prev_closes, self.config.ma_short)
        prev_long = _sma(prev_closes, self.config.ma_long)
        if prev_short is None or prev_long is None:
            return Decision("HOLD", symbol, price, 0, "Not enough history for cross detection")

        crossed_up = (prev_short <= prev_long) and (short_ma > long_ma)
        crossed_down = (prev_short >= prev_long) and (short_ma < long_ma)

        if crossed_up:
            qty = self._position_size(price)
            return Decision(
                "BUY",
                symbol,
                price,
                qty,
                f"MA cross up: SMA{self.config.ma_short} {short_ma:.2f} > SMA{self.config.ma_long} {long_ma:.2f}",
            )

        if crossed_down:
            # sizing for SELL is handled by broker (min(qty, position_qty)),
            # but we still propose a qty target here for logging/intent.
            qty = self._position_size(price)
            return Decision(
                "SELL",
                symbol,
                price,
                qty,
                f"MA cross down: SMA{self.config.ma_short} {short_ma:.2f} < SMA{self.config.ma_long} {long_ma:.2f}",
            )

        return Decision(
            "HOLD",
            symbol,
            price,
            0,
            f"No MA cross (SMA{self.config.ma_short}={short_ma:.2f}, SMA{self.config.ma_long}={long_ma:.2f})",
        )

    def _position_size(self, price: float) -> int:
        if price <= 0:
            return 0

        budget = float(self.config.usable_capital)
        raw_qty = int(budget // float(price))

        lot = int(self.config.lot_size)
        if lot > 1:
            raw_qty = (raw_qty // lot) * lot

        return max(0, raw_qty)
