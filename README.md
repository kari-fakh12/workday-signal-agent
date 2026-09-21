# workday-signal-agent

A small agent I built for a client, a global payroll-data platform, that finds big companies running Workday and sends them into outbound.

## The problem

The client is a global payroll data platform. It sells to large multinationals with messy payroll across many countries. A company running Workday is a good sign it's that kind of company. The hard part was finding those companies without paying for a tech-install database.

## The trick

Every Workday customer gets a public careers site at `<slug>.wdN.myworkdayjobs.com`. So a `site:myworkdayjobs.com <term>` search returns subdomains, and each subdomain is a company that runs Workday for sure. Change the search term every day and you keep finding new ones.

## How it works

1. Search. The shell runs a rotating set of `site:myworkdayjobs.com` searches through Firecrawl and pulls out the subdomains.
2. Dedupe. It drops anything already in memory (every company ever found), the master CSV, and optionally Clay tables or a Notion database.
3. Qualify. In Clay, or by handing the CSV to Claude with the prompt, the slug becomes the real company name and gets checked against the ICP: 10k+ employees, 10+ countries, not a vendor, EOR, staffing firm or university. No sourced number means "needs check", never a guess. The prompt is in `agent/workday-company-finder.md`.
4. Clay. Net-new companies go into a Clay table through a webhook. A ledger makes sure each one is only sent once.
5. HeyReach. From Clay, qualified companies go to HeyReach for outreach.

On top of that, a daily Slack digest says how many were sent to Clay and how many qualified ones landed in the master list, and a weekly summary says how many were found that week and flags when the search terms look used up.

```
 GitHub Actions (08:00 UTC daily)
          |
          v
 Firecrawl search  site:myworkdayjobs.com <term>
          |
          v
 pull <slug>.wdN subdomains --> dedupe vs memory / master CSV
          |
          v
 Claude: real name + ICP check (10k+ staff, 10+ countries)
          |
          v
 Clay webhook --> HeyReach outreach
          |
          v
 commit results back to repo
          |
          +--> Slack daily digest (10:00 UTC)
          +--> Slack weekly summary (Mondays)
```

## Safety

- Dry run by default. Without `CONFIRM_SPEND=1` (or `--confirm` for the one-off script) it prints the searches it would run and the cost, and calls nothing.
- Spend cap. `MAX_QUERIES` limits searches per day (default 8).
- Kill switch. Put a file at `state/STOP_WORKDAY` and it stops. Commit it to stop the cloud run too.
- Runs in the cloud on GitHub Actions, so it keeps going with my laptop off.
- Each company is sent to Clay once, so no wasted Clay credits.

## Run it

```bash
cp .env.example .env               # add your keys

bash agent/run-workday-daily.sh                   # dry run, shows today's searches
CONFIRM_SPEND=1 bash agent/run-workday-daily.sh   # real run
bash agent/run-workday-finder.sh --confirm        # one-off bigger sweep
```

Then give the CSV in `output/` to Claude with `agent/workday-company-finder.md` as the system prompt, or let the Clay webhook handle it.

For the cloud version, add the env vars below as repo secrets. The three workflows in `.github/workflows/` handle the rest.

## Env vars

| Name | Needed for | Notes |
|---|---|---|
| `FIRECRAWL_API_KEY` | search | required for a real run |
| `CONFIRM_SPEND` | search | `1` to actually spend, default off |
| `MAX_QUERIES` | search | searches per day, default 8 |
| `LIMIT` | search | results per search, default 20 |
| `MASTER_LIST` | dedupe | optional file of companies you already have |
| `CLAY_WEBHOOK_URL` | Clay | optional, no webhook means CSV only |
| `CLAY_WEBHOOK_AUTH` | Clay | optional webhook auth value |
| `CLAY_DEDUP_TABLES` | dedupe | optional, `tableId:columnId` pairs, needs the clay CLI |
| `NOTION_API_TOKEN` | dedupe, digest | Notion integration token |
| `COMPANY_DB_ID` | dedupe | optional Notion company database |
| `MNC_DB_ID` | daily digest | Notion database of qualified companies |
| `SLACK_WEBHOOK_URL` | digests | Slack incoming webhook |

## Result

242 qualified companies found for the client.

## Layout

```
agent/        system prompt + the two runners
digests/      daily Slack digest + weekly summary
.github/      the three scheduled workflows
state/        memory, send ledger, kill switch (not committed here)
output/       master CSV + raw search results (not committed here)
```

MIT license.
