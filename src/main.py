from pathlib import Path
import argparse
import json

from src.market_data import MarketData
from src.domain.portfolio import Portfolio
from src.services.broker import Broker
from src.services.equity import EquityCurve
from src.services.metrics import compute_metrics

from src.strategy.ma_cross import MACrossStrategy
from src.strategy.rsi import RSIStrategy


def build_strategy(args):
    if args.strategy == "ma":
        return MACrossStrategy(
            ma_short=args.ma_short,
            ma_long=args.ma_long,
        )

    if args.strategy == "rsi":
        return RSIStrategy(
            period=args.rsi_period,
            overbought=args.rsi_overbought,
            oversold=args.rsi_oversold,
        )

    raise ValueError(f"Unknown strategy: {args.strategy}")


def run_backtest(args):
    md = MarketData.from_csv(args.csv)

    portfolio = Portfolio.load(
        Path("data/portfolio.json"),
        default_cash=100000,
    )

    broker = Broker(portfolio)
    equity = EquityCurve(start_cash=portfolio.cash)
    strategy = build_strategy(args)

    for d in md.dates:
        closes = md.closes_upto(d)
        decision = strategy.decide(args.symbol, closes)
        price = md.last_price_on(d)

        if decision:
            broker.handle_decision(decision, d, price)

        equity.mark(
            d,
            portfolio.cash,
            portfolio.position_value(args.symbol, price),
        )

    equity.write_csv("data/equity.csv")
    broker.write_trades("data/trades.csv")

    metrics = compute_metrics(equity.records, broker.trades)
    Path("data").mkdir(exist_ok=True)

    with open("data/metrics.json", "w", encoding="utf-8") as f:
        json.dump(metrics.__dict__, f, indent=2)

    return metrics


def main():
    p = argparse.ArgumentParser("investment-assistant")

    p.add_argument("--csv", default="data/2330.csv")
    p.add_argument("--symbol", default="2330.TW")

    p.add_argument("--strategy", choices=["ma", "rsi"], default="ma")

    # MA params
    p.add_argument("--ma-short", type=int, default=1)
    p.add_argument("--ma-long", type=int, default=3)

    # RSI params
    p.add_argument("--rsi-period", type=int, default=14)
    p.add_argument("--rsi-overbought", type=float, default=70)
    p.add_argument("--rsi-oversold", type=float, default=30)

    p.add_argument("--backtest", action="store_true")

    args = p.parse_args()

    if args.backtest:
        m = run_backtest(args)
        print(m)


if __name__ == "__main__":
    raise SystemExit(main())
