#!/usr/bin/env bash
# =============================================================================
# run-workday-daily.sh  --  DAILY Workday company discovery agent
#
# Every day it:
#   1. Loads the running memory of every Workday company it has EVER found.
#   2. Picks a rotating slice of search terms (different each day) and mines
#      public *.myworkdayjobs.com careers subdomains via Firecrawl search.
#   3. Keeps only NET-NEW companies (dedupes against memory, the master CSV,
#      and optionally Clay tables / a Notion company database).
#   4. Appends the net-new ones to the memory + one dated master CSV.
#   5. If CLAY_WEBHOOK_URL is set, POSTs each company not sent before into
#      the Clay table, where it gets qualified and routed on to outreach.
#      No webhook set = it just writes the CSV for you to review.
#
# "Shell scrapes, Claude thinks": this shell discovers + dedupes; the
# qualification prompt is agent/workday-company-finder.md.
#
# COST: Firecrawl search is metered. This script only spends when
# CONFIRM_SPEND=1 (the scheduled workflow sets it). It is capped at
# MAX_QUERIES searches per day. A dry run (default) prints the plan and
# spends nothing.
#
# Usage:
#   bash agent/run-workday-daily.sh                    # dry run: today's plan
#   CONFIRM_SPEND=1 bash agent/run-workday-daily.sh    # real run (spends, capped)
#   CLAY_WEBHOOK_URL=https://... CONFIRM_SPEND=1 bash agent/run-workday-daily.sh
#
# Kill switch: create state/STOP_WORKDAY to pause it (commit it to pause the
# cloud schedule too).
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- config ----------------------------------------------------------------
LIMIT="${LIMIT:-20}"                          # results per search
MAX_QUERIES="${MAX_QUERIES:-8}"               # searches per day (hard cost cap)
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
STATE_DIR="${STATE_DIR:-$REPO_ROOT/state}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/output}"
MEMORY="$STATE_DIR/workday-known-slugs.txt"
MASTER_LIST="${MASTER_LIST:-}"                # optional: file of companies you already have (seeds memory)
CLAY_WEBHOOK_URL="${CLAY_WEBHOOK_URL:-}"      # Clay table webhook URL
CLAY_WEBHOOK_AUTH="${CLAY_WEBHOOK_AUTH:-}"    # optional x-clay-webhook-auth value
# Optional: Clay tables to check so we never re-add a company already in Clay.
# Needs the `clay` CLI logged in. Format: "tableId:companyColumnId tableId:companyColumnId"
CLAY_DEDUP_TABLES="${CLAY_DEDUP_TABLES:-}"
# Optional: Notion company database to dedupe against (needs NOTION_API_TOKEN too).
COMPANY_DB_ID="${COMPANY_DB_ID:-}"
mkdir -p "$STATE_DIR" "$OUT_DIR"

# ---- kill switch -----------------------------------------------------------
if [ -f "$STATE_DIR/STOP_WORKDAY" ]; then
  echo "STOP_WORKDAY present -> paused, exiting."; exit 0
fi

# ---- Firecrawl key (prefer env var, e.g. from CI secret; else .env) ---------
FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"
if [ -z "$FIRECRAWL_API_KEY" ] && [ -f "$ENV_FILE" ]; then
  FIRECRAWL_API_KEY="$(grep -E '^FIRECRAWL_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" || true)"
fi

# ---- the query pool (rotates daily) ----------------------------------------
POOL=(
 "global payroll" "international payroll" "payroll manager" "payroll analyst"
 "HRIS analyst" "HRIS manager" "shared services payroll" "compensation analyst"
 "senior director human resources" "people operations" "total rewards"
 "EMEA payroll" "APAC payroll" "LATAM payroll" "EMEA HR" "APAC HR"
 "manufacturing operations" "pharmaceutical" "biotech" "financial services"
 "insurance" "logistics supply chain" "consumer goods" "retail stores"
 "automotive" "energy utilities" "oil and gas" "semiconductor" "aerospace"
 "medical devices" "telecommunications" "software engineer" "data center"
 "mining" "chemicals" "food and beverage" "hospitality" "construction"
 "banking" "asset management"
)

# pick today's slice: MAX_QUERIES terms starting at an offset from day-of-year
DOY=$(( 10#$(date +%j) ))
N=${#POOL[@]}
START=$(( (DOY * MAX_QUERIES) % N ))
QUERIES=()
for ((i=0; i<MAX_QUERIES; i++)); do
  QUERIES+=("${POOL[$(( (START + i) % N ))]}")
done

STAMP="$(date +%Y%m%d)"
TODAY_DATE="$(date +%Y-%m-%d)"
RAW="$OUT_DIR/workday-daily-raw-$STAMP.jsonl"
# ONE accumulating master file: every new company, dated, with a status column.
MASTER="$OUT_DIR/workday-companies-MASTER.csv"

echo "=============================================================="
echo " Workday Daily Agent  ($TODAY_DATE)"
echo "=============================================================="
echo " today's searches ($MAX_QUERIES): ${QUERIES[*]}"
echo " memory file: $MEMORY  ($( [ -f "$MEMORY" ] && wc -l < "$MEMORY" || echo 0 ) known)"
echo " webhook: $( [ -n "$CLAY_WEBHOOK_URL" ] && echo "SET (writes to Clay)" || echo "not set (CSV only)" )"
echo " est. cost: ~$MAX_QUERIES Firecrawl search credits"
echo "--------------------------------------------------------------"

if [ "${CONFIRM_SPEND:-0}" != "1" ]; then
  echo " DRY RUN (CONFIRM_SPEND not set). Nothing spent. Today it WOULD search:"
  for q in "${QUERIES[@]}"; do echo "   site:myworkdayjobs.com $q"; done
  echo ""
  echo " Real run:  CONFIRM_SPEND=1 bash agent/run-workday-daily.sh"
  exit 0
fi
if [ -z "$FIRECRAWL_API_KEY" ]; then
  echo "ERROR: FIRECRAWL_API_KEY not set (env var or $ENV_FILE)" >&2; exit 1
fi

# ---- seed memory on first run from the optional master list -----------------
if [ ! -f "$MEMORY" ]; then
  : > "$MEMORY"
  if [ -n "$MASTER_LIST" ] && [ -f "$MASTER_LIST" ]; then
    { grep -oiE '[a-z0-9-]+\.wd[0-9]+\.myworkdayjobs\.com' "$MASTER_LIST" || true; } \
      | sed -E 's#([a-z0-9-]+)\.wd[0-9]+.*#\1#I' | tr 'A-Z' 'a-z' | sort -u > "$MEMORY"
  fi
  echo " seeded memory with $(wc -l < "$MEMORY") known slugs"
fi

# ---- run the searches ------------------------------------------------------
: > "$RAW"
for q in "${QUERIES[@]}"; do
  curl -s -X POST "https://api.firecrawl.dev/v1/search" \
    -H "Authorization: Bearer $FIRECRAWL_API_KEY" -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"query":"site:myworkdayjobs.com "+sys.argv[1],"limit":int(sys.argv[2])}))' "$q" "$LIMIT")" \
    >> "$RAW"; echo "" >> "$RAW"; sleep 1
done

# ---- optional: read Clay tables so we skip anything already in Clay ---------
CLAY_KNOWN="$STATE_DIR/known-elsewhere-$STAMP.txt"
: > "$CLAY_KNOWN"
if ! command -v clay >/dev/null 2>&1 || [ -z "${CLAY_DEDUP_TABLES// /}" ]; then
  echo " no clay CLI / CLAY_DEDUP_TABLES -> skipping Clay table dedupe"
else
echo " checking Clay tables to avoid duplicates..."
# shellcheck disable=SC2086
python3 - "$CLAY_KNOWN" $CLAY_DEDUP_TABLES <<'PY'
import sys, re, json, subprocess
out_path=sys.argv[1]; specs=sys.argv[2:]
def norm(s): return re.sub(r'[^a-z0-9]','',s.lower())
host_re=re.compile(r'([a-z0-9-]+)\.wd\d+\.myworkdayjobs\.com', re.I)
keys=set()
def run(a):
    r=subprocess.run(["clay"]+a,capture_output=True,text=True)
    try: return json.loads(r.stdout) if r.stdout.strip() else {}
    except Exception: return {}
for spec in specs:
    parts=spec.split(":"); tid=parts[0]; comp_col=parts[1] if len(parts)>1 else None
    cursor=None
    for _ in range(30):
        a=["tables","rows","list",tid,"--limit","100"]+(["--cursor",cursor] if cursor else [])
        d=run(a); rows=d.get("data",[]); cursor=d.get("cursor")
        for r in rows:
            cells=r.get("cells",{})
            # company name -> normalized key
            if comp_col and comp_col in cells:
                c=cells[comp_col]
                v=c.get("value") if isinstance(c,dict) and c.get("status")=="success" else None
                if v: keys.add(norm(str(v)))
            # any workday slug anywhere in the row
            for cell in cells.values():
                v=cell.get("value") if isinstance(cell,dict) else None
                if isinstance(v,str):
                    m=host_re.search(v)
                    if m: keys.add(m.group(1).lower())
        if not cursor: break
with open(out_path,"w") as f:
    for k in sorted(keys):
        if k: f.write(k+"\n")
print(f"   loaded {len(keys)} companies already in Clay")
PY
fi

# ---- optional: check a Notion company database so we skip what's there ------
if [ -n "${NOTION_API_TOKEN:-}" ] && [ -n "$COMPANY_DB_ID" ]; then
  echo " checking the Notion company database to avoid re-adding..."
  python3 - "$CLAY_KNOWN" "$COMPANY_DB_ID" <<'PY'
import sys, re, json, urllib.request, os
out_path, dbid = sys.argv[1], sys.argv[2]
TOKEN=os.environ["NOTION_API_TOKEN"]
H={"Authorization":f"Bearer {TOKEN}","Notion-Version":"2022-06-28","Content-Type":"application/json"}
def norm(s): return re.sub(r'[^a-z0-9]','',(s or '').lower())
rows=[]; cur=None
while True:
    b={"page_size":100}
    if cur: b["start_cursor"]=cur
    try:
        req=urllib.request.Request(f"https://api.notion.com/v1/databases/{dbid}/query",data=json.dumps(b).encode(),headers=H,method="POST")
        d=json.load(urllib.request.urlopen(req))
    except Exception as e:
        print("  Notion read failed:",e); break
    rows.extend(d.get("results",[]))
    if d.get("has_more"): cur=d.get("next_cursor")
    else: break
keys=set()
for p in rows:
    for k,v in p["properties"].items():
        if v.get("type")=="title": keys.add(norm("".join(x.get("plain_text","") for x in v["title"])))
        if v.get("type")=="url" and v.get("url"):
            dm=re.sub(r'^https?://|^www\.','',v["url"].lower()).split('/')[0].split('.')[0]
            if dm: keys.add(dm)
with open(out_path,"a") as f:
    for k in keys:
        if k: f.write(k+"\n")
print(f"  loaded {len(keys)} companies from the Notion company database")
PY
fi

# ---- parse, dedupe vs memory + known lists, append to master, update memory --
python3 - "$RAW" "$MEMORY" "$MASTER" "$CLAY_KNOWN" "$TODAY_DATE" <<'PY'
import json, re, sys, os, csv
raw, mem_path, master, known_path, today = sys.argv[1:6]
def norm(s): return re.sub(r'[^a-z0-9]','',s.lower())
known=set(l.strip().lower() for l in open(mem_path) if l.strip())
try: known |= set(l.strip() for l in open(known_path) if l.strip())
except Exception: pass
# also skip anything already sitting in the master file (by slug)
if os.path.exists(master):
    for r in csv.DictReader(open(master)):
        s=(r.get('Workday Slug') or '').strip().lower()
        if s: known.add(s); known.add(norm(s))
host_re=re.compile(r'([a-z0-9-]+)\.wd(\d+)\.myworkdayjobs\.com', re.I)
found={}
for line in open(raw):
    line=line.strip()
    if not line: continue
    try: obj=json.loads(line)
    except Exception: continue
    for it in (obj.get('data') or []):
        m=host_re.search(it.get('url') or '')
        if not m: continue
        slug=m.group(1).lower()
        found.setdefault(slug,(f"{slug}.wd{m.group(2)}.myworkdayjobs.com",))
netnew={s:v for s,v in found.items() if s not in known and norm(s) not in known}
new_file = not os.path.exists(master)
newrun = os.path.join(os.path.dirname(mem_path), "new-this-run.csv")
hdr=["Date Found","Company","Workday Slug","Workday Careers URL","Status"]
with open(master,'a',newline='') as f, open(newrun,'w',newline='') as g:
    w=csv.writer(f); wg=csv.writer(g)
    if new_file: w.writerow(hdr)
    wg.writerow(hdr)
    for s in sorted(netnew):
        host=netnew[s][0]
        name=s.replace('-',' ').title()   # rough placeholder; Claude resolves the real name
        row=[today, name, s, f"https://{host}", "Not added"]
        w.writerow(row); wg.writerow(row)
with open(mem_path,'a') as f:
    for s in sorted(netnew): f.write(s+"\n")
print(f" surfaced {len(found)} | net-new {len(netnew)} (appended to master with date + 'Not added')")
for s in sorted(netnew): print(f"   + {s}")
PY

# ---- push every company not known + not sent before into Clay (webhook) -----
# The ledger (state/sent-to-clay.txt) means each company is sent exactly once,
# so no wasted Clay credits. state/clay-send-log.csv feeds the daily digest.
SENT_LEDGER="$STATE_DIR/sent-to-clay.txt"
if [ -n "$CLAY_WEBHOOK_URL" ] && [ -f "$MASTER" ]; then
  posted=$(python3 - "$MASTER" "$CLAY_WEBHOOK_URL" "$CLAY_WEBHOOK_AUTH" "$CLAY_KNOWN" "$SENT_LEDGER" <<'PY'
import csv, sys, json, re, os, urllib.request, datetime
master, url, auth, known_path, ledger = sys.argv[1:6]
def norm(s): return re.sub(r'[^a-z0-9]','',(s or '').lower())
known=set(l.strip().lower() for l in open(known_path) if l.strip()) if os.path.exists(known_path) else set()
sent=set(l.strip().lower() for l in open(ledger) if l.strip()) if os.path.exists(ledger) else set()
n=0; newly=[]
for r in csv.DictReader(open(master)):
    slug=(r.get('Workday Slug') or '').strip().lower()
    name=r.get('Company') or ''
    if not slug or slug in sent: continue
    if norm(name) in known or slug in known: continue
    body=json.dumps({"companyName":name,"workdaySlug":slug,
                     "careersUrl":r.get('Workday Careers URL',''),"source":"workday-daily"}).encode()
    h={"Content-Type":"application/json"}
    if auth: h["x-clay-webhook-auth"]=auth
    try:
        urllib.request.urlopen(urllib.request.Request(url,data=body,headers=h),timeout=15)
        n+=1; newly.append(slug)
    except Exception: pass
if newly:
    today=datetime.date.today().isoformat()
    with open(ledger,"a") as f:
        for s in newly: f.write(s+"\n")
    sendlog=os.path.join(os.path.dirname(ledger),"clay-send-log.csv")
    hdr=not os.path.exists(sendlog)
    with open(sendlog,"a",newline="") as f:
        w=csv.writer(f)
        if hdr: w.writerow(["date","slug"])
        for s in newly: w.writerow([today,s])
print(n)
PY
)
  echo " posted $posted companies (not known, not sent before) into Clay via webhook."
fi

rm -f "$CLAY_KNOWN"
echo "--------------------------------------------------------------"
echo " master file: $MASTER"
echo " memory now: $(wc -l < "$MEMORY") known companies"
