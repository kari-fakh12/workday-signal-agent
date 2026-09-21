#!/usr/bin/env bash
# =============================================================================
# run-workday-finder.sh  --  one-off Workday company discovery
#
# Discovers companies that run Workday by mining their public careers portals
# on *.myworkdayjobs.com. Every Workday customer gets a careers site at
#   <slug>.wd<N>.myworkdayjobs.com
# so a search sweep for `site:myworkdayjobs.com <term>` surfaces the
# subdomains, and each subdomain slug IS a confirmed Workday company.
#
# The slug/host/careers-URL are FACTUAL (they come straight from the search
# API). The clean company name + ICP qualification are left to Claude
# (agent/workday-company-finder.md). This shell never invents a company name.
#
# COST: uses Firecrawl /v1/search (metered). One search call per query term.
#       By default this is a DRY RUN: it prints the query plan and the
#       estimated spend and does NOT call the API. Add --confirm to spend.
#
# Usage:
#   bash agent/run-workday-finder.sh                 # dry run: show plan + cost
#   bash agent/run-workday-finder.sh --confirm       # actually search
#   LIMIT=30 bash agent/run-workday-finder.sh --confirm
#   MASTER_LIST=/path/to/known.csv bash agent/run-workday-finder.sh --confirm
#   QUERIES_FILE=/path/to/queries.txt bash agent/run-workday-finder.sh --confirm
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- config ----------------------------------------------------------------
LIMIT="${LIMIT:-20}"                    # results per query
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
MASTER_LIST="${MASTER_LIST:-}"          # optional file of companies you already have
OUT_DIR="${OUT_DIR:-$REPO_ROOT/output}"
CONFIRM=0
[ "${1:-}" = "--confirm" ] && CONFIRM=1

# ---- Firecrawl key (env var first, else .env) ------------------------------
FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"
if [ -z "$FIRECRAWL_API_KEY" ] && [ -f "$ENV_FILE" ]; then
  FIRECRAWL_API_KEY="$(grep -E '^FIRECRAWL_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" || true)"
fi

# ---- query seeds -----------------------------------------------------------
# Each becomes:  site:myworkdayjobs.com <term>
# Terms are chosen to surface LARGE, multi-country employers:
# global payroll roles + big industries + regions.
if [ -n "${QUERIES_FILE:-}" ] && [ -f "${QUERIES_FILE:-}" ]; then
  mapfile -t QUERIES < "$QUERIES_FILE"
else
  QUERIES=(
    "global payroll"
    "international payroll"
    "payroll manager"
    "HRIS analyst"
    "senior director human resources"
    "shared services payroll"
    "EMEA payroll"
    "APAC payroll"
    "manufacturing operations"
    "pharmaceutical"
    "financial services"
    "logistics supply chain"
    "consumer goods"
    "automotive"
    "energy utilities"
    "retail stores"
  )
fi

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW_JSON="$OUT_DIR/workday-search-$STAMP.jsonl"
OUT_CSV="$OUT_DIR/workday-netnew-$STAMP.csv"

# ---- cost estimate ---------------------------------------------------------
NQ="${#QUERIES[@]}"
echo "=============================================================="
echo " Workday Company Finder"
echo "=============================================================="
echo " queries:            $NQ"
echo " results per query:  $LIMIT   (search-only, no page scraping)"
echo " known-list source:  ${MASTER_LIST:-none}"
echo " est. Firecrawl cost: ~1 search credit x $NQ queries = ~$NQ search credits"
echo " output CSV:         $OUT_CSV"
echo "--------------------------------------------------------------"

if [ "$CONFIRM" -ne 1 ]; then
  echo " DRY RUN. No API called, nothing spent."
  echo " Queries that WOULD run:"
  for q in "${QUERIES[@]}"; do echo "   site:myworkdayjobs.com $q"; done
  echo ""
  echo " To actually search, re-run with --confirm:"
  echo "   bash agent/run-workday-finder.sh --confirm"
  exit 0
fi

if [ -z "$FIRECRAWL_API_KEY" ]; then
  echo "ERROR: FIRECRAWL_API_KEY not set (env var or $ENV_FILE)" >&2
  exit 1
fi

# ---- build the KNOWN set (slugs we already have) ---------------------------
KNOWN_SLUGS="$(mktemp)"
{
  # any myworkdayjobs URL anywhere in the optional master list (csv, html, txt)
  if [ -n "$MASTER_LIST" ] && [ -f "$MASTER_LIST" ]; then
    grep -oiE '[a-z0-9-]+\.wd[0-9]+\.myworkdayjobs\.com' "$MASTER_LIST" \
      | sed -E 's#([a-z0-9-]+)\.wd[0-9]+\.myworkdayjobs\.com#\1#I' || true
  fi
} | tr 'A-Z' 'a-z' | sort -u > "$KNOWN_SLUGS"
echo " known Workday slugs loaded: $(wc -l < "$KNOWN_SLUGS")"

# ---- run the searches ------------------------------------------------------
: > "$RAW_JSON"
for q in "${QUERIES[@]}"; do
  echo "  searching: site:myworkdayjobs.com $q"
  curl -s -X POST "https://api.firecrawl.dev/v1/search" \
    -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"query":"site:myworkdayjobs.com "+sys.argv[1],"limit":int(sys.argv[2])}))' "$q" "$LIMIT")" \
    >> "$RAW_JSON"
  echo "" >> "$RAW_JSON"
  sleep 1
done

# ---- parse, dedupe, write CSV ---------------------------------------------
python3 - "$RAW_JSON" "$KNOWN_SLUGS" "$OUT_CSV" <<'PY'
import json, re, sys
raw, known_path, out_csv = sys.argv[1], sys.argv[2], sys.argv[3]

known = set()
with open(known_path) as f:
    for line in f:
        s = line.strip().lower()
        if s: known.add(s)

host_re = re.compile(r'([a-z0-9-]+)\.wd(\d+)\.myworkdayjobs\.com', re.I)
found = {}   # slug -> (host, careers_url, page_title)

with open(raw) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        data = obj.get('data') or obj.get('results') or []
        # firecrawl v1 search -> {"success":true,"data":[{"url":...},...]}
        for item in (data if isinstance(data, list) else []):
            url = item.get('url') or ''
            m = host_re.search(url)
            if not m: continue
            slug = m.group(1).lower()
            host = f"{slug}.wd{m.group(2)}.myworkdayjobs.com"
            if slug not in found:
                found[slug] = (host, f"https://{host}", (item.get('title') or '')[:80])

netnew = {s:v for s,v in found.items() if s not in known}

with open(out_csv, 'w') as f:
    f.write("slug,host,careers_url,page_title,status\n")
    for slug in sorted(found):
        host, url, title = found[slug]
        status = "NEW" if slug not in known else "known"
        title = title.replace(',', ' ').replace('"', "'")
        f.write(f"{slug},{host},{url},{title},{status}\n")

print(f"\n  total distinct Workday companies surfaced: {len(found)}")
print(f"  already on our list (known):              {len(found)-len(netnew)}")
print(f"  NET-NEW (not on our list):                {len(netnew)}")
print(f"\n  NET-NEW slugs:")
for s in sorted(netnew):
    print(f"    {s:24s} {netnew[s][1]}")
PY

echo "--------------------------------------------------------------"
echo " CSV written: $OUT_CSV"
echo " raw search responses: $RAW_JSON"
echo ""
echo " Next: hand $OUT_CSV to Claude (agent/workday-company-finder.md) to"
echo " resolve proper company names and qualify against the ICP."
rm -f "$KNOWN_SLUGS"
