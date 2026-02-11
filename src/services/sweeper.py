from __future__ import annotations

import csv
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable, List, Tuple

from src.adapters.market_data import MarketDataResult
from src.core.engine import InvestmentEngine
from src.domain.config import AppConfig
from src.services.backtest import BacktestReport, run_backtest


@dataclass(frozen=True)
class SweepRow:
    ma_short: int
    ma_long: int
    start_cash: float
    end_value: float
    total_return: float
    max_drawdown: float
    trades: int
    buys: int
    sells: int
    win_rate: float


def _default_short_grid() -> List[int]:
    return [2, 3, 4, 5]


def _default_long_grid() -> List[int]:
    return [3, 5, 8, 10, 20]


def generate_ma_grid(shorts: Iterable[int], longs: Iterable[int]) -> List[Tuple[int, int]]:
    out: List[Tuple[int, int]] = []
    for s in shorts:
        for l in longs:
            if s < l:
                out.append((int(s), int(l)))
    # stable ordering
    out.sort(key=lambda x: (x[0], x[1]))
    return out


def run_ma_sweep(
    md: MarketDataResult,
    base_cfg: AppConfig,
    output_csv: Path,
    shorts: List[int] | None = None,
    longs: List[int] | None = None,
) -> List[SweepRow]:
    shorts = shorts or _default_short_grid()
    longs = longs or _default_long_grid()

    grid = generate_ma_grid(shorts, longs)

    rows: List[SweepRow] = []

    for ma_s, ma_l in grid:
        cfg = replace(base_cfg, ma_short=int(ma_s), ma_long=int(ma_l))
        engine = InvestmentEngine(cfg)

        # IMPORTANT: sweep uses in-memory portfolio, never touches your live paper portfolio.json
        report: BacktestReport = run_backtest(
            md=md,
            engine=engine,
            cfg=cfg,
            start_cash=float(cfg.total_capital),
            log_equity_path=None,
            log_metrics_path=None,
            log_trades_path=None,
            log_rejected=False,
        )

        rows.append(
            SweepRow(
                ma_short=ma_s,
                ma_long=ma_l,
                start_cash=report.metrics.start_cash,
                end_value=report.metrics.end_value,
                total_return=report.metrics.total_return,
                max_drawdown=report.metrics.max_drawdown,
                trades=report.metrics.trades,
                buys=report.metrics.buys,
                sells=report.metrics.sells,
                win_rate=report.metrics.win_rate,
            )
        )

    # write CSV
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    with output_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "ma_short",
                "ma_long",
                "start_cash",
                "end_value",
                "total_return",
                "max_drawdown",
                "trades",
                "buys",
                "sells",
                "win_rate",
            ]
        )
        for r in rows:
            w.writerow(
                [
                    r.ma_short,
                    r.ma_long,
                    f"{r.start_cash:.6f}",
                    f"{r.end_value:.6f}",
                    f"{r.total_return:.6f}",
                    f"{r.max_drawdown:.6f}",
                    r.trades,
                    r.buys,
                    r.sells,
                    f"{r.win_rate:.6f}",
                ]
            )

    return rows
