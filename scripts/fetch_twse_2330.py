import sys
from datetime import datetime
from dateutil.relativedelta import relativedelta
import pandas as pd
import requests

stock_no = sys.argv[1]
months_back = int(sys.argv[2])

def ym_list(months_back: int):
    end = datetime.today().replace(day=1)
    start = end - relativedelta(months=months_back)
    cur = start
    out = []
    while cur <= end:
        out.append(cur.strftime("%Y%m01"))
        cur = cur + relativedelta(months=1)
    return out

def fetch_month(yyyymm01: str):
    # TWSE 月成交資訊（JSON）
    url = f"https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date={yyyymm01}&stockNo={stock_no}&response=json"
    r = requests.get(url, timeout=30, headers={"User-Agent":"Mozilla/5.0"})
    r.raise_for_status()
    j = r.json()
    if j.get("stat") != "OK":
        return pd.DataFrame()
    fields = j["fields"]
    data = j["data"]
    df = pd.DataFrame(data, columns=fields)

    # 欄位通常含：日期, 成交股數, 成交金額, 開盤價, 最高價, 最低價, 收盤價, 漲跌價差, 成交筆數
    # 日期是民國：113/01/02 → 2024-01-02
    def roc_to_ad(s: str) -> str:
        y, m, d = s.split("/")
        y = int(y) + 1911
        return f"{y:04d}-{int(m):02d}-{int(d):02d}"

    df["date"] = df["日期"].map(roc_to_ad)

    def to_float(x):
        x = str(x).replace(",", "").strip()
        return float(x) if x not in ("--","") else None

    def to_int(x):
        x = str(x).replace(",", "").strip()
        return int(float(x)) if x not in ("--","") else None

    df["open"]   = df["開盤價"].map(to_float)
    df["high"]   = df["最高價"].map(to_float)
    df["low"]    = df["最低價"].map(to_float)
    df["close"]  = df["收盤價"].map(to_float)
    df["volume"] = df["成交股數"].map(to_int)

    out = df[["date","open","high","low","close","volume"]].dropna(subset=["date","close"])
    return out

dfs = []
for ym in ym_list(months_back):
    dfm = fetch_month(ym)
    if not dfm.empty:
        dfs.append(dfm)

if not dfs:
    raise SystemExit("No data fetched from TWSE.")

df = pd.concat(dfs, ignore_index=True).drop_duplicates(subset=["date"]).sort_values("date")

# 輸出到 data/2330.csv（UTF-8 no BOM）
out_path = "data/2330.csv"
df.to_csv(out_path, index=False, encoding="utf-8")

print(f"OK: wrote {out_path} rows={len(df)} date_range={df['date'].min()}..{df['date'].max()}")
print(df.head(5).to_string(index=False))
