from typing import List, Optional
from src.domain.models import Decision
from src.strategy.base import Strategy


class RSIStrategy(Strategy):
    """
    RSI Strategy (Single-Position Mode)

    Rules:
    - Only BUY when there is NO existing position
    - Only SELL when there IS an existing position
    - Hold at most 1 unit at any time
    """

    def __init__(self, period: int = 14, overbought: float = 70, oversold: float = 30):
        if period <= 1:
            raise ValueError("RSI period must be > 1")
        self.period = period
        self.overbought = overbought
        self.oversold = oversold

    def decide(
        self,
        symbol: str,
        closes: List[float],
        position: int = 0,  # 👈 現有持倉數量（由 backtester 傳入）
    ) -> Optional[Decision]:
        """
        Decide trading action based on RSI and current position.

        :param symbol: trading symbol
        :param closes: historical close prices
        :param position: current position size (0 or 1)
        """
        # Need enough data to compute RSI
        if len(closes) < self.period + 1:
            return None

        gains = []
        losses = []

        for i in range(-self.period, 0):
            diff = closes[i] - closes[i - 1]
            if diff >= 0:
                gains.append(diff)
                losses.append(0)
            else:
                gains.append(0)
                losses.append(-diff)

        avg_gain = sum(gains) / self.period
        avg_loss = sum(losses) / self.period

        if avg_loss == 0:
            rsi = 100.0
        else:
            rs = avg_gain / avg_loss
            rsi = 100.0 - (100.0 / (1.0 + rs))

        # === Trading Rules (Single Position) ===

        # BUY only if no position
        if position == 0 and rsi <= self.oversold:
            return Decision(
                action="BUY",
                symbol=symbol,
                price=None,
                quantity=1,
                reason="rsi_oversold",
            )

        # SELL only if holding position
        if position > 0 and rsi >= self.overbought:
            return Decision(
                action="SELL",
                symbol=symbol,
                price=None,
                quantity=position,  # 全部賣出
                reason="rsi_overbought",
            )

        return None
