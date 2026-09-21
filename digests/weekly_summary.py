#!/usr/bin/env python3
"""
Weekly Slack summary for the Workday Company Finder agent.
Reads the agent's master CSV (output/workday-companies-MASTER.csv) and posts:
how many new this week, total found, and whether the search looks tapped out.

Runs weekly in the cloud (see .github/workflows/workday-weekly.yml).

Env:
  SLACK_WEBHOOK_URL  - Slack incoming webhook (required)
  MASTER_PATH        - master CSV path (default: output/workday-companies-MASTER.csv)
"""
import os, csv, json, urllib.request, datetime

WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
MASTER = os.environ.get("MASTER_PATH", "output/workday-companies-MASTER.csv")


def post_slack(text):
    req = urllib.request.Request(
        WEBHOOK, data=json.dumps({"text": text, "unfurl_links": False}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as r:
        resp = r.read().decode()
    if resp.strip() != "ok":
        raise SystemExit(f"Slack webhook error: {resp[:200]}")


def main():
    today = datetime.date.today()
    rows = list(csv.DictReader(open(MASTER))) if os.path.exists(MASTER) else []
    total = len(rows)

    def d(s):
        try:
            return datetime.date.fromisoformat(s.strip())
        except Exception:
            return None

    new7 = sum(1 for r in rows if (dt := d(r.get("Date Found", ""))) and (today - dt).days < 7)
    not_added = sum(1 for r in rows if (r.get("Status", "") or "").strip().lower() == "not added")

    if new7 == 0:
        health = ":warning: No new companies this week. The search may be tapped out - worth adding fresh search terms."
    else:
        health = f":white_check_mark: {new7} new Workday companies found this week."

    msg = (
        ":bar_chart: *Workday Company Finder - weekly update*\n"
        f"• *New this week:* {new7}\n"
        f"• *Total found (all time):* {total}\n"
        f"• *Still to add to Clay ('Not added'):* {not_added}\n"
        f"{health}"
    )
    post_slack(msg)
    print("posted:\n" + msg)


if __name__ == "__main__":
    main()
