from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, List


@dataclass
class BacktestMetrics:
    start_value: float
    end_value: float
    return_pct: float
    max_drawdown: float
    trades: int


def _get_total_value(r: Any) -> float:
    # 支援 dataclass/object: r.total_value
    if hasattr(r, "total_value"):
        return float(getattr(r, "total_value"))
    # 支援 dict: r["total_value"]
    if isinstance(r, dict) and "total_value" in r:
        return float(r["total_value"])
    raise TypeError(f"Unsupported equity record type: {type(r)}")


def compute_metrics(equity_records: Iterable[Any], trades: List[Any]) -> BacktestMetrics:
    values = [_get_total_value(r) for r in equity_records]
    if not values:
        return BacktestMetrics(
            start_value=0.0,
            end_value=0.0,
            return_pct=0.0,
            max_drawdown=0.0,
            trades=len(trades),
        )

    start_value = float(values[0])
    end_value = float(values[-1])
    return_pct = (end_value / start_value - 1.0) if start_value != 0 else 0.0

    peak = values[0]
    max_dd = 0.0
    for v in values:
        if v > peak:
            peak = v
        dd = (peak - v) / peak if peak != 0 else 0.0
        if dd > max_dd:
            max_dd = dd

    return BacktestMetrics(
        start_value=start_value,
        end_value=end_value,
        return_pct=return_pct,
        max_drawdown=max_dd,
        trades=len(trades),
    )
