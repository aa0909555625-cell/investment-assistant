from __future__ import annotations

import csv
import json
import math
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------
# Helpers
# ---------------------------

def _read_csv_rows(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def _read_json(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _safe_float(x: Any, default: float = 0.0) -> float:
    try:
        return float(x)
    except Exception:
        return default


# ---------------------------
# Domain DTO
# ---------------------------

@dataclass
class TradeFill:
    ts: datetime
    action: str
    symbol: str
    price: float
    qty: int
    fee: float
    realized_pnl: float
    note: str
    event: str  # FILL / REJECT


# ---------------------------
# Core analytics
# ---------------------------

def load_trades(trades_csv: Path) -> List[TradeFill]:
    rows = _read_csv_rows(trades_csv)
    out: List[TradeFill] = []

    for r in rows:
        try:
            ts = datetime.fromisoformat(r.get("ts", ""))
        except Exception:
            continue

        out.append(
            TradeFill(
                ts=ts,
                event=(r.get("event", "") or "").upper(),
                action=(r.get("action", "") or "").upper(),
                symbol=r.get("symbol", "") or "",
                price=_safe_float(r.get("fill_price")),
                qty=int(_safe_float(r.get("quantity"))),
                fee=_safe_float(r.get("fee")),
                realized_pnl=_safe_float(r.get("realized_pnl")),
                note=r.get("note", "") or "",
            )
        )

    out.sort(key=lambda x: x.ts)
    return out


def summarize_equity(equity_csv: Path) -> Dict[str, Any]:
    rows = _read_csv_rows(equity_csv)
    values = [_safe_float(r.get("total_value")) for r in rows if r.get("total_value")]

    if len(values) < 2:
        return {"days": len(values), "mean_daily_return": 0.0, "vol": 0.0, "sharpe": None}

    rets = [(values[i] / values[i - 1] - 1.0) for i in range(1, len(values)) if values[i - 1] > 0]

    mu = sum(rets) / len(rets)
    var = sum((x - mu) ** 2 for x in rets) / max(len(rets) - 1, 1)
    vol = math.sqrt(var)

    sharpe = None
    if vol > 0 and len(rets) >= 20:
        sharpe = (mu / vol) * math.sqrt(252)

    return {
        "days": len(values),
        "mean_daily_return": mu,
        "daily_volatility": vol,
        "sharpe_annualized": sharpe,
    }


# ---------------------------
# Public API (LEGACY)
# ---------------------------

def write_report(
    out_path: Path,
    metrics_json: Path,
    equity_csv: Path,
    trades_csv: Path,
) -> None:
    m = _read_json(metrics_json)
    eq = summarize_equity(equity_csv)
    fills = load_trades(trades_csv)

    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines: List[str] = []
    lines.append("=== Investment Assistant Report ===")
    lines.append(f"Generated: {datetime.now().replace(microsecond=0).isoformat()}")
    lines.append("")
    lines.append("[Backtest Summary]")
    lines.append(f"  start_cash   : {m.get('start_cash', 0):.2f}")
    lines.append(f"  end_value    : {m.get('end_value', 0):.2f}")
    lines.append(f"  total_return : {m.get('total_return', 0) * 100:.4f}%")
    lines.append(f"  max_drawdown : {m.get('max_drawdown', 0) * 100:.4f}%")
    lines.append("")
    lines.append("[Equity Stats]")
    lines.append(f"  days               : {eq.get('days')}")
    lines.append(f"  mean_daily_return  : {eq.get('mean_daily_return', 0) * 100:.6f}%")
    lines.append(f"  daily_volatility   : {eq.get('daily_volatility', 0) * 100:.6f}%")
    lines.append(f"  sharpe(annualized) : {eq.get('sharpe_annualized')}")
    lines.append("")
    lines.append("[Notes]")
    lines.append("  - sharpe is NA when sample size is too small.")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")


def write_report_json(
    out_path: Path,
    metrics_json: Path,
    equity_csv: Path,
    trades_csv: Path,
) -> None:
    payload = {
        "generated": datetime.now().replace(microsecond=0).isoformat(),
        "metrics": _read_json(metrics_json),
        "equity": summarize_equity(equity_csv),
        "trades_count": len(load_trades(trades_csv)),
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
