# -*- coding: utf-8 -*-
"""
cost_model_min.py
Inject minimal transaction-cost assumptions into decision_YYYY-MM-DD.json
(Taiwan common defaults; tunable knobs)

- commission_rate_per_side default 0.1425% (0.001425)
- sell transaction tax:
    stock: 0.3% (0.003)
    etf: 0.1% (0.001)
    daytrade_stock: 0.15% (0.0015)
- slippage_bps_per_side: simple knob (bps)
"""
import argparse, json, os
from datetime import datetime

def now_str():
  return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def main():
  ap = argparse.ArgumentParser(description="Inject minimal cost assumptions into decision json.")
  ap.add_argument("--decision", required=True, help="decision_YYYY-MM-DD.json path")
  ap.add_argument("--mode", default="stock", choices=["stock","etf","daytrade_stock"])
  ap.add_argument("--commission_rate", type=float, default=0.001425)
  ap.add_argument("--min_commission_twd", type=float, default=20.0)
  ap.add_argument("--sell_tax_stock", type=float, default=0.003)
  ap.add_argument("--sell_tax_etf", type=float, default=0.001)
  ap.add_argument("--sell_tax_daytrade_stock", type=float, default=0.0015)
  ap.add_argument("--slippage_bps", type=float, default=5.0)
  args = ap.parse_args()

  p = args.decision
  if not os.path.exists(p):
    raise SystemExit(f"decision file not found: {p}")

  with open(p, "r", encoding="utf-8") as f:
    obj = json.load(f)

  if args.mode == "stock":
    sell_tax = args.sell_tax_stock
  elif args.mode == "etf":
    sell_tax = args.sell_tax_etf
  else:
    sell_tax = args.sell_tax_daytrade_stock

  obj.setdefault("meta", {})
  obj["meta"]["cost_model_version"] = "min_v1"
  obj["meta"]["cost_model_updated_at"] = now_str()

  obj["cost_assumptions"] = {
    "product_mode": args.mode,
    "commission_rate_per_side": float(args.commission_rate),
    "min_commission_twd_per_trade": float(args.min_commission_twd),
    "sell_transaction_tax_rate": float(sell_tax),
    "sell_tax_rates": {
      "stock": float(args.sell_tax_stock),
      "etf": float(args.sell_tax_etf),
      "daytrade_stock": float(args.sell_tax_daytrade_stock),
    },
    "slippage_bps_per_side": float(args.slippage_bps),
    "notes": [
      "Defaults are conservative; tune commission_rate if your broker discount is known.",
      "Transaction tax is sell-side; choose mode=stock/etf/daytrade_stock.",
      "Slippage is a simple bps knob; not orderbook-based."
    ],
  }

  tmp = p + ".tmp"
  with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
  os.replace(tmp, p)
  print(p)

if __name__ == "__main__":
  main()