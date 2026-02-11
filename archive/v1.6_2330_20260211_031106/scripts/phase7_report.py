from __future__ import annotations

import argparse
from pathlib import Path
import pandas as pd


def max_drawdown(equity: pd.Series) -> float:
    peak = equity.cummax()
    dd = (equity / peak) - 1.0
    return float(dd.min()) if len(dd) else 0.0


def losing_streaks(returns: pd.Series) -> int:
    streak = 0
    max_streak = 0
    for r in returns.fillna(0.0).tolist():
        if r < 0:
            streak += 1
            max_streak = max(max_streak, streak)
        else:
            streak = 0
    return int(max_streak)


def safe_read_trades(path: Path) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    try:
        df = pd.read_csv(path)
        # empty file with headers ok; empty file without headers throws (we also fixed Phase6)
        return df
    except pd.errors.EmptyDataError:
        return pd.DataFrame()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--equity", default="data/phase6_equity_2330.csv")
    ap.add_argument("--trades", default="data/phase6_trades_2330.csv")
    ap.add_argument("--out", default="reports/report_2330.md")
    args = ap.parse_args()

    equity_path = Path(args.equity)
    trades_path = Path(args.trades)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    eq = pd.read_csv(equity_path)
    tr = safe_read_trades(trades_path)

    eq["equity"] = pd.to_numeric(eq["equity"], errors="coerce")
    eq = eq.dropna(subset=["equity"]).copy()
    if eq.empty:
        raise SystemExit("Equity file has no valid rows")

    start_equity = float(eq["equity"].iloc[0])
    end_equity = float(eq["equity"].iloc[-1])
    total_return = (end_equity / start_equity) - 1.0 if start_equity > 0 else 0.0

    eq["ret"] = eq["equity"].pct_change().fillna(0.0)
    vol = float(eq["ret"].std()) if len(eq) > 1 else 0.0
    sharpe = float((eq["ret"].mean() / vol) * (252 ** 0.5)) if vol > 0 else 0.0

    mdd = max_drawdown(eq["equity"])

    trade_count = int(len(tr)) if tr is not None and not tr.empty else 0
    if trade_count > 0 and "return_pct" in tr.columns:
        win_rate = float((pd.to_numeric(tr["return_pct"], errors="coerce") > 0).mean())
        avg_trade = float(pd.to_numeric(tr["return_pct"], errors="coerce").mean())
        max_lose_streak = losing_streaks(pd.to_numeric(tr["return_pct"], errors="coerce"))
    else:
        win_rate = 0.0
        avg_trade = 0.0
        max_lose_streak = 0

    if trade_count > 0 and {"entry_date", "exit_date"}.issubset(set(tr.columns)):
        tr2 = tr.copy()
        tr2["entry_date"] = pd.to_datetime(tr2["entry_date"], errors="coerce")
        tr2["exit_date"] = pd.to_datetime(tr2["exit_date"], errors="coerce")
        hold = (tr2["exit_date"] - tr2["entry_date"]).dt.days
        avg_hold = float(hold.dropna().mean()) if hold.notna().any() else 0.0
    else:
        avg_hold = 0.0

    md = []
    md.append("# 2330 RSI Single-Position Backtest Report")
    md.append("")
    md.append(f"- Period: {eq['date'].iloc[0]} → {eq['date'].iloc[-1]}")
    md.append(f"- Start Equity: {start_equity:,.0f}")
    md.append(f"- End Equity: {end_equity:,.0f}")
    md.append(f"- Total Return: {total_return*100:.2f}%")
    md.append(f"- Max Drawdown: {mdd*100:.2f}%")
    md.append(f"- Sharpe (rough): {sharpe:.2f}")
    md.append("")
    md.append("## Trades")
    md.append(f"- Trade Count: {trade_count}")
    md.append(f"- Win Rate: {win_rate*100:.2f}%")
    md.append(f"- Avg Trade Return: {avg_trade*100:.2f}%")
    md.append(f"- Avg Holding Days: {avg_hold:.2f}")
    md.append(f"- Max Losing Streak (trades): {max_lose_streak}")
    md.append("")

    if trade_count > 0:
        md.append("### Recent Trades (last 10)")
        md.append("")
        view = tr.tail(10).copy()
        cols = [c for c in ["entry_date", "exit_date", "entry_price", "exit_price", "shares", "return_pct", "exit_reason"] if c in view.columns]
        if "return_pct" in view.columns:
            view["return_pct"] = pd.to_numeric(view["return_pct"], errors="coerce").fillna(0.0).map(lambda x: f"{x*100:.2f}%")

        md.append("| " + " | ".join(cols) + " |")
        md.append("|" + "|".join(["---"] * len(cols)) + "|")
        for _, r in view.iterrows():
            md.append("| " + " | ".join([str(r[c]) for c in cols]) + " |")
        md.append("")
    else:
        md.append("> No trades generated under this parameter set.")
        md.append("")

    out_path.write_text("\n".join(md), encoding="utf-8")
    print(f"OK Phase7 wrote: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
