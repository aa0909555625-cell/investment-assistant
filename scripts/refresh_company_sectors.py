# -*- coding: utf-8 -*-
import argparse, csv, os, re, sys, time
from datetime import datetime
from urllib.request import Request, urlopen

ISIN_LISTED = "https://isin.twse.com.tw/isin/C_public.jsp?strMode=2"
ISIN_OTC    = "https://isin.twse.com.tw/isin/C_public.jsp?strMode=4"

def fetch_big5(url: str, timeout: int = 20) -> str:
    req = Request(url, headers={
        "User-Agent": "Mozilla/5.0",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    with urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    # TWSE ISIN pages are typically Big5
    return raw.decode("big5", errors="ignore")

def strip_tags(s: str) -> str:
    s = re.sub(r"(?is)<script.*?>.*?</script>", "", s)
    s = re.sub(r"(?is)<style.*?>.*?</style>", "", s)
    s = re.sub(r"(?is)<br\s*/?>", "\n", s)
    s = re.sub(r"(?is)</(tr|p|div)>", "\n", s)
    s = re.sub(r"(?is)<.*?>", "", s)
    s = s.replace("\u3000", " ").replace("&nbsp;", " ")
    return re.sub(r"[ \t]+", " ", s).strip()

def parse_isin_rows(html: str):
    """
    Robust-ish: parse table rows by splitting <tr> ... </tr>, then <td>.
    We only need:
      - code (first token before whitespace)
      - name
      - industry (產業別) column if present
    """
    rows = []
    for tr in re.findall(r"(?is)<tr[^>]*>(.*?)</tr>", html):
        tds = re.findall(r"(?is)<td[^>]*>(.*?)</td>", tr)
        if not tds or len(tds) < 3:
            continue
        first = strip_tags(tds[0])
        if not first:
            continue
        # code may be like "2330　台積電" or "0050　元大台灣50"
        parts = re.split(r"\s+", first)
        code = parts[0].strip()
        if not re.match(r"^\d{4,6}[A-Z]?$", code):
            continue

        name = strip_tags(tds[0])
        name = re.sub(r"^\s*"+re.escape(code)+r"\s*", "", name).strip()

        # try industry column heuristics: look for any td that contains "業" / "ETF" keywords
        # official table often: [有價證券代號及名稱, 國際證券辨識號碼(ISIN Code), 上市日, 市場別, 產業別, CFICode, 備註]
        industry = ""
        if len(tds) >= 6:
            industry = strip_tags(tds[4])
        elif len(tds) >= 5:
            industry = strip_tags(tds[-2])
        else:
            industry = ""

        # normalize
        industry = normalize_sector(code, industry, name)

        rows.append((code, industry, name))
    return rows

def normalize_sector(code: str, sector: str, name: str) -> str:
    sector = (sector or "").strip()
    name = (name or "").strip()

    # ETF rule (TW ETFs commonly start with 00xxxx)
    if code.isdigit() and code.startswith("00"):
        return "ETF"

    # clean known junk patterns
    if re.match(r"^[A-Z0-9]{6}$", sector):
        sector = ""
    if re.match(r"^\d{4,6}\s", sector):
        sector = ""
    if sector in ("CEOGEU","CEOGDU","CEOGAU","CEOGDE","CEOGEA"):
        sector = ""
    if sector in ("", "Unknown", "unknown"):
        # last resort: keep Unknown
        return "Unknown"

    return sector

def write_csv(path: str, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["code","sector","name"])
        w.writerows(rows)

def load_sector_map(path: str):
    mp = {}
    with open(path, "r", encoding="utf-8", newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            code = (row.get("code") or "").strip()
            sector = (row.get("sector") or "").strip()
            name = (row.get("name") or "").strip()
            if not code:
                continue
            mp[code] = (sector if sector else "Unknown", name)
    return mp

def is_bad_existing_sector(s: str) -> bool:
    s = (s or "").strip()
    if s == "" or re.match(r"^(?i)unknown$", s):
        return True
    # legacy / junk tokens
    if s in ("CEOGEU","CEOGDU","CEOGAU","CEOGDE","CEOGEA"):
        return True
    if re.match(r"^[A-Z0-9]{6}$", s):
        return True
    if re.match(r"^\d{4,6}\s", s):
        return True
    # contains a lot of replacement chars / garbled
    if "" in s:
        return True
    return False

def update_all_stocks_daily(all_csv: str, sector_map_csv: str):
    mp = load_sector_map(sector_map_csv)
    if not os.path.exists(all_csv):
        print(f"[WARN] all_stocks_daily.csv not found: {all_csv}")
        return 0, 0

    with open(all_csv, "r", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
        fieldnames = rows[0].keys() if rows else []

    changed = 0
    unk = 0
    for row in rows:
        code = (row.get("code") or "").strip()
        cur = (row.get("sector") or "").strip()
        if not code:
            continue

        # always normalize existing ETFs by code prefix
        if code.isdigit() and code.startswith("00"):
            new_sector = "ETF"
            if cur != new_sector:
                row["sector"] = new_sector
                changed += 1
            continue

        if code in mp:
            new_sector = mp[code][0]
            # overwrite if existing is bad OR map provides something non-Unknown
            if is_bad_existing_sector(cur) and new_sector and new_sector.lower() != "unknown":
                row["sector"] = new_sector
                changed += 1
            elif is_bad_existing_sector(cur) and (not new_sector or new_sector.lower() == "unknown"):
                # keep as Unknown
                row["sector"] = "Unknown"
            # if existing is good, do not overwrite
        else:
            if is_bad_existing_sector(cur):
                row["sector"] = "Unknown"

    # recount unknown/blank
    for row in rows:
        s = (row.get("sector") or "").strip()
        if s == "" or s.lower() == "unknown":
            unk += 1

    with open(all_csv, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    return changed, unk

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output csv path (company_sectors.csv)")
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--update_all_stocks", action="store_true")
    ap.add_argument("--all_stocks_csv", default=os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "all_stocks_daily.csv"))
    args = ap.parse_args()

    out = args.out
    timeout = args.timeout

    listed_html = fetch_big5(ISIN_LISTED, timeout=timeout)
    otc_html    = fetch_big5(ISIN_OTC, timeout=timeout)

    # debug saves (same as you already do)
    dbg_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data")
    os.makedirs(dbg_dir, exist_ok=True)
    dbg_listed = os.path.join(dbg_dir, "debug_isin_listed.html")
    dbg_otc    = os.path.join(dbg_dir, "debug_isin_otc.html")
    with open(dbg_listed, "w", encoding="utf-8", newline="") as f:
        f.write(listed_html)
    with open(dbg_otc, "w", encoding="utf-8", newline="") as f:
        f.write(otc_html)

    listed_rows = parse_isin_rows(listed_html)
    otc_rows    = parse_isin_rows(otc_html)

    print(f"INFO: parsed listed rows={len(listed_rows)} (debug saved: {dbg_listed})")
    print(f"INFO: parsed otc rows={len(otc_rows)} (debug saved: {dbg_otc})")

    rows = listed_rows + otc_rows

    if len(rows) < 500:
        print("OK: wrote sector map -> %s (rows=%d)" % (out, len(rows)))
        print("[FATAL] sector map rows too small (<500). Parser likely failed.")
        return 2

    write_csv(out, rows)
    print("OK: wrote sector map -> %s (rows=%d)" % (out, len(rows)))

    if args.update_all_stocks:
        chg, unk = update_all_stocks_daily(args.all_stocks_csv, out)
        print(f"OK: updated all_stocks_daily.csv changed={chg}")
        print(f"INFO: Unknown/blank sector count now = {unk}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())