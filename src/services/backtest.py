from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from src.adapters.market_data import MarketDataResult
from src.domain.config import AppConfig
from src.domain.models import Decision
from src.domain.portfolio import Portfolio
from src.services.broker import PaperBroker, Fill


@dataclass(frozen=True)
class BacktestMetrics:
    start_cash: float
    end_value: float
    total_return: float
    max_drawdown: float
    trades: int
    buys: int
    sells: int
    win_rate: float
    avg_win: float
    avg_loss: float


@dataclass(frozen=True)
class EquityPoint:
    d: date
    total_value: float
    cash: float
    position_value: float
    drawdown: float


@dataclass(frozen=True)
class BacktestReport:
    metrics: BacktestMetrics
    equity: List[EquityPoint]
    fills: List[Fill]


def _iso_now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _append_csv_row(path: Path, header: List[str], row: List[str]) -> None:
    _ensure_parent(path)
    exists = path.exists()
    with path.open("a", encoding="utf-8", newline="") as f:
        if not exists:
            f.write(",".join(header) + "\n")
        f.write(",".join(row) + "\n")


def _portfolio_value(portfolio: Portfolio, prices: Dict[str, float]) -> Tuple[float, float]:
    pos_value = 0.0
    for sym, pos in portfolio.positions.items():
        if pos.quantity == 0:
            continue
        px = float(prices.get(sym, 0.0))
        pos_value += float(pos.quantity) * px
    total = float(portfolio.cash) + float(pos_value)
    return total, pos_value


def run_backtest(
    md: MarketDataResult,
    engine,
    cfg: AppConfig,
    start_cash: float,
    log_equity_path: Optional[Path],
    log_metrics_path: Optional[Path],
    log_trades_path: Optional[Path],
    log_rejected: bool = False,
) -> BacktestReport:
    broker = PaperBroker(cfg)

    # in-memory portfolio only (backtest should not reuse live portfolio.json)
    portfolio = Portfolio(cash=float(start_cash))

    dates = md.dates()
    symbols = md.symbols()

    equity: List[EquityPoint] = []
    fills: List[Fill] = []

    peak = float(start_cash)
    max_dd = 0.0

    realized_pnls: List[float] = []
    buys = 0
    sells = 0

    for d in dates:
        # 1) decisions + execution for this date
        for sym in symbols:
            closes = md.closes_upto(sym, d)
            decision: Decision = engine.decide(sym, closes)

            # backtest always executes (paper) here; logging controlled separately
            portfolio, fill = broker.execute(portfolio, decision)
            if fill:
                is_fill = (fill.quantity > 0)
                if is_fill:
                    fills.append(fill)
                    if fill.action == "BUY":
                        buys += 1
                    elif fill.action == "SELL":
                        sells += 1
                        realized_pnls.append(float(fill.realized_pnl))

                if log_trades_path is not None:
                    # Only write fills unless log_rejected=True
                    if is_fill or log_rejected:
                        header = [
                            "ts",
                            "event",
                            "action",
                            "symbol",
                            "fill_price",
                            "quantity",
                            "fee",
                            "cash_delta",
                            "cash_after",
                            "position_qty",
                            "position_avg_cost",
                            "realized_pnl",
                            "note",
                        ]
                        event = "FILL" if is_fill else "REJECT"
                        pos = portfolio.get_position(fill.symbol)
                        row = [
                            _iso_now(),
                            event,
                            fill.action,
                            fill.symbol,
                            f"{float(fill.price):.6f}",
                            str(int(fill.quantity)),
                            f"{float(fill.fee):.6f}",
                            f"{float(fill.cash_delta):.6f}",
                            f"{float(portfolio.cash):.6f}",
                            str(int(pos.quantity)),
                            f"{float(pos.avg_cost):.6f}",
                            f"{float(fill.realized_pnl):.6f}",
                            (fill.note or "").replace(",", " "),
                        ]
                        _append_csv_row(log_trades_path, header, row)

        # 2) equity snapshot (valuation uses last known price up to date)
        prices = md.latest_prices_on(d)
        total, pos_value = _portfolio_value(portfolio, prices)

        if total > peak:
            peak = total
        dd = 0.0 if peak <= 0 else (total / peak - 1.0)
        if dd < max_dd:
            max_dd = dd

        equity.append(
            EquityPoint(
                d=d,
                total_value=float(total),
                cash=float(portfolio.cash),
                position_value=float(pos_value),
                drawdown=float(dd),
            )
        )

    end_value = equity[-1].total_value if equity else float(start_cash)
    total_return = 0.0 if start_cash == 0 else (end_value / float(start_cash) - 1.0)

    # win-rate
    wins = [p for p in realized_pnls if p > 0]
    losses = [p for p in realized_pnls if p < 0]
    trades = len(realized_pnls)
    win_rate = (len(wins) / trades) if trades > 0 else 0.0
    avg_win = (sum(wins) / len(wins)) if wins else 0.0
    avg_loss = (sum(losses) / len(losses)) if losses else 0.0

    metrics = BacktestMetrics(
        start_cash=float(start_cash),
        end_value=float(end_value),
        total_return=float(total_return),
        max_drawdown=float(max_dd),
        trades=int(trades),
        buys=int(buys),
        sells=int(sells),
        win_rate=float(win_rate),
        avg_win=float(avg_win),
        avg_loss=float(avg_loss),
    )

    # write equity / metrics
    if log_equity_path is not None:
        _ensure_parent(log_equity_path)
        with log_equity_path.open("w", encoding="utf-8", newline="") as f:
            f.write("date,total_value,cash,position_value,drawdown\n")
            for p in equity:
                f.write(
                    f"{p.d.isoformat()},{p.total_value:.6f},{p.cash:.6f},{p.position_value:.6f},{p.drawdown:.6f}\n"
                )

    if log_metrics_path is not None:
        _ensure_parent(log_metrics_path)
        payload = {
            "start_cash": metrics.start_cash,
            "end_value": metrics.end_value,
            "total_return": metrics.total_return,
            "max_drawdown": metrics.max_drawdown,
            "trades": metrics.trades,
            "buys": metrics.buys,
            "sells": metrics.sells,
            "win_rate": metrics.win_rate,
            "avg_win": metrics.avg_win,
            "avg_loss": metrics.avg_loss,
        }
        log_metrics_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    return BacktestReport(metrics=metrics, equity=equity, fills=fills)
