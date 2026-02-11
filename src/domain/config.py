from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AppConfig:
    # ===== 資金 / 風控 =====
    total_capital: int = 100_000
    reserve_cash_ratio: float = 0.20
    max_positions: int = 1

    # ===== 檔案位置（相對 project root）=====
    data_dir: Path = Path("data")
    prices_csv: Path = Path("data") / "prices.csv"
    portfolio_json: Path = Path("data") / "portfolio.json"
    trades_csv: Path = Path("data") / "trades.csv"
    decisions_csv: Path = Path("data") / "decisions.csv"

    # ===== 策略參數（最小可用）=====
    ma_short: int = 5
    ma_long: int = 20

    # ===== 交易模式 =====
    paper_trade: bool = True

    # ===== 交易單位 / 成交成本 =====
    # MVP 預設用 1（零股/美股/加密友善）；台股整張用 --tw-lot 切到 1000
    lot_size: int = 1
    # 手續費率（簡化）：0.001 = 0.1%
    fee_rate: float = 0.001
    # 滑價（basis points）：5 = 0.05%
    slippage_bps: float = 5.0

    @property
    def reserve_cash(self) -> int:
        return int(self.total_capital * self.reserve_cash_ratio)

    @property
    def usable_capital(self) -> int:
        return max(0, int(self.total_capital - self.reserve_cash))

    @classmethod
    def load_default(cls) -> "AppConfig":
        return cls()
