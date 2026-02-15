import csv
import re
import sys
import time
import random
from pathlib import Path
from html.parser import HTMLParser
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
OUT_ALL = ROOT / "data" / "universe_all.csv"
OUT_STOCK = ROOT / "data" / "universe_stock.csv"

URLS = [
    ("TWSE", "https://isin.twse.com.tw/isin/C_public.jsp?strMode=2"),
    ("TPEx", "https://isin.twse.com.tw/isin/C_public.jsp?strMode=4"),
    ("ESB",  "https://isin.twse.com.tw/isin/C_public.jsp?strMode=5"),
]

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) InvestmentAssistant/1.0"

def fetch_html(url: str, timeout: int = 30) -> str:
    req = Request(url, headers={"User-Agent": UA})
    with urlopen(req, timeout=timeout) as resp:
        data = resp.read()
    for enc in ("utf-8", "big5", "cp950"):
        try:
            return data.decode(enc, errors="strict")
        except Exception:
            pass
    return data.decode("utf-8", errors="replace")

class IsinTableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = False
        self.table_depth = 0
        self.in_tr = False
        self.in_td = False
        self.cell_buf = []
        self.cur_row = []
        self.rows = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "table":
            if not self.in_table:
                self.in_table = True
                self.table_depth = 1
            else:
                self.table_depth += 1
        if not self.in_table:
            return
        if tag == "tr":
            self.in_tr = True
            self.cur_row = []
        elif tag == "td" and self.in_tr:
            self.in_td = True
            self.cell_buf = []

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "table" and self.in_table:
            self.table_depth -= 1
            if self.table_depth <= 0:
                self.in_table = False
        if not self.in_table:
            return
        if tag == "td" and self.in_td:
            self.in_td = False
            cell = "".join(self.cell_buf).strip()
            cell = re.sub(r"\s+", " ", cell)
            self.cur_row.append(cell)
        elif tag == "tr" and self.in_tr:
            self.in_tr = False
            if self.cur_row:
                self.rows.append(self.cur_row)

    def handle_data(self, data):
        if self.in_table and self.in_td:
            self.cell_buf.append(data)

def norm_code_name(s: str):
    s = (s or "").strip()
    s = re.sub(r"\s+", " ", s)
    m = re.match(r"^(\d{4,6}[A-Z]?)\s+(.*)$", s)
    if not m:
        return "", ""
    return m.group(1).strip(), m.group(2).strip()

def classify_instrument(code: str) -> str:
    if re.fullmatch(r"\d{4}", code):
        if code.startswith("91"):
            return "TDR"
        return "STOCK_COMMON"
    if re.fullmatch(r"00\d{3,4}[A-Z]?", code):
        return "ETF_OR_FUND"
    if re.fullmatch(r"02\d{3,4}[A-Z]?", code):
        return "ETN"
    if re.fullmatch(r"01\d{3,4}[A-Z]?", code):
        return "REIT_OR_FUND"
    return "OTHER"

def parse_isin_page(html: str):
    p = IsinTableParser()
    p.feed(html)
    rows = p.rows

    out = []
    cur_section = ""
    for r in rows:
        if len(r) == 1:
            sec = re.sub(r"<.*?>", "", r[0]).strip()
            if sec:
                cur_section = sec
            continue

        if len(r) < 2:
            continue

        code, name = norm_code_name(r[0])
        if not code or not name:
            continue

        isin = r[1].strip() if len(r) > 1 else ""
        list_date = r[2].strip() if len(r) > 2 else ""
        market_raw = r[3].strip() if len(r) > 3 else ""
        industry = r[4].strip() if len(r) > 4 else ""
        cfi = r[5].strip() if len(r) > 5 else ""
        remark = r[6].strip() if len(r) > 6 else ""

        out.append({
            "code": code,
            "name": name,
            "isin": isin,
            "list_date": list_date,
            "market_raw": market_raw,
            "industry": industry,
            "cfi": cfi,
            "remark": remark,
            "section": cur_section,
            "kind": classify_instrument(code),
        })
    return out

def write_csv(path: Path, rows, fieldnames):
    # project dicts to only the desired fields (avoids extrasaction issues)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

def main():
    all_rows = []
    for market, url in URLS:
        time.sleep(0.5 + random.random() * 0.6)
        html = fetch_html(url)
        parsed = parse_isin_page(html)
        for x in parsed:
            x["market"] = market
        all_rows.extend(parsed)
        print(f"[OK] fetched {market}: rows={len(parsed)}")

    # de-dup by code: prefer TWSE > TPEx > ESB
    priority = {"TWSE": 0, "TPEx": 1, "ESB": 2}
    best = {}
    for x in all_rows:
        c = x["code"]
        if c not in best or priority.get(x["market"], 9) < priority.get(best[c]["market"], 9):
            best[c] = x

    dedup = list(best.values())
    dedup.sort(key=lambda z: (priority.get(z["market"], 9), z["code"]))

    # write all
    fields_all = ["code","name","market","market_raw","industry","isin","list_date","cfi","remark","section","kind"]
    write_csv(OUT_ALL, dedup, fields_all)

    # write stocks only (common stocks: 4-digit, exclude 91xx TDR)
    stocks = [x for x in dedup if x.get("kind") == "STOCK_COMMON"]
    fields_stock = ["code","name","market","industry","isin","list_date"]
    write_csv(OUT_STOCK, stocks, fields_stock)

    print(f"OK: wrote {OUT_ALL} rows={len(dedup)}")
    print(f"OK: wrote {OUT_STOCK} rows={len(stocks)}")
    print("SAMPLE stock:")
    for x in stocks[:10]:
        print(f"{x['market']:4} {x['code']} {x['name']} {x.get('industry','')}")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("FATAL:", repr(e), file=sys.stderr)
        raise