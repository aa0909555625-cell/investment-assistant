from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    csv_path: Path
    symbol: str
    ma_short: int = 5
    ma_long: int = 20
    lot_size: int = 1
    fee_rate: float = 0.001
    slippage_bps: float = 5.0
    start_cash: float = 100000.0
