from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Union


@dataclass
class Trade:
    date: str
    action: str
    symbol: str
    price: float
    quantity: int
    reason: str
    fee: float
    cash_after: float


class Broker:
    def __init__(
        self,
        portfolio,
        fee_rate: float = 0.001,
        slippage_bps: float = 0.0,
    ):
        self.portfolio = portfolio
        self.fee_rate = fee_rate
        self.slippage_bps = slippage_bps
        self.trades: List[Trade] = []

    def _apply_slippage(self, price: float, action: str) -> float:
        slip = price * (self.slippage_bps / 10000.0)
        return price + slip if action == "BUY" else price - slip

    def handle_decision(self, decision, date, price):
        action = decision.action
        symbol = decision.symbol
        qty = decision.quantity

        # ✅ 關鍵防線：無持倉不允許 SELL
        current_position = self.portfolio.positions.get(symbol, 0)
        if action == "SELL" and current_position < qty:
            return  # 忽略非法賣出（不中斷回測）

        px = self._apply_slippage(float(price), action)
        fee = px * qty * self.fee_rate

        if action == "BUY":
            self.portfolio.buy(symbol, qty, px, fee)
        elif action == "SELL":
            self.portfolio.sell(symbol, qty, px, fee)
        else:
            return

        self.trades.append(
            Trade(
                date=str(date),
                action=action,
                symbol=symbol,
                price=round(px, 6),
                quantity=qty,
                reason=decision.reason,
                fee=round(fee, 6),
                cash_after=round(self.portfolio.cash, 6),
            )
        )

    def write_trades(self, path: Union[str, Path]):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)

        with path.open("w", encoding="utf-8") as f:
            f.write(
                "date,action,symbol,price,quantity,reason,fee,cash_after\n"
            )
            for t in self.trades:
                f.write(
                    f"{t.date},{t.action},{t.symbol},"
                    f"{t.price},{t.quantity},{t.reason},"
                    f"{t.fee},{t.cash_after}\n"
                )
