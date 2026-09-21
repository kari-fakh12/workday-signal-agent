#!/usr/bin/env python3
"""
Daily Slack digest for the Workday -> Clay pipeline: how many companies the
agent sent to Clay today, and how many qualified companies landed in the
master list (a Notion database) today.

Runs daily in the cloud (see .github/workflows/workday-clay-daily.yml), after
the agent's own daily run.

Env:
  NOTION_API_TOKEN   - Notion integration token (required)
  SLACK_WEBHOOK_URL  - Slack incoming webhook (required)
  MNC_DB_ID          - Notion database id of the qualified master list (required)
  CLAY_SEND_LOG      - path to the send log (default: state/clay-send-log.csv)
"""
import os, csv, json, urllib.request, datetime

NOTION = os.environ["NOTION_API_TOKEN"]
WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
MNC_DB = os.environ["MNC_DB_ID"]
SEND_LOG = os.environ.get("CLAY_SEND_LOG", "state/clay-send-log.csv")
MNC_URL = "https://www.notion.so/" + MNC_DB.replace("-", "")
NH = {"Authorization": f"Bearer {NOTION}", "Notion-Version": "2022-06-28",
      "Content-Type": "application/json"}


def notion_all(dbid):
    rows, cur = [], None
    while True:
        b = {"page_size": 100}
        if cur:
            b["start_cursor"] = cur
        req = urllib.request.Request(
            f"https://api.notion.com/v1/databases/{dbid}/query",
            data=json.dumps(b).encode(), headers=NH, method="POST")
        d = json.load(urllib.request.urlopen(req))
        rows.extend(d.get("results", []))
        if d.get("has_more"):
            cur = d.get("next_cursor")
        else:
            return rows


def created_date(p):
    return p["created_time"][:10]  # YYYY-MM-DD (UTC)


def post_slack(text):
    req = urllib.request.Request(
        WEBHOOK, data=json.dumps({"text": text, "unfurl_links": False}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as r:
        resp = r.read().decode()
    if resp.strip() != "ok":
        raise SystemExit(f"Slack webhook error: {resp[:200]}")


def main():
    today = datetime.date.today().isoformat()

    # --- sent to Clay (from the dated send log) ---
    sent_today = sent_total = 0
    if os.path.exists(SEND_LOG):
        for r in csv.DictReader(open(SEND_LOG)):
            sent_total += 1
            if (r.get("date") or "").strip() == today:
                sent_today += 1

    # --- qualified added to the master list today ---
    mnc = notion_all(MNC_DB)
    mnc_total = len(mnc)
    mnc_today = sum(1 for p in mnc if created_date(p) == today)

    if sent_today == 0 and mnc_today == 0:
        health = ":coffee: Quiet day - no new companies sent and none newly qualified."
    else:
        health = ":white_check_mark: Pipeline active."

    msg = (
        ":robot_face: *Workday -> Clay pipeline - daily update*\n"
        f"• *Sent to Clay today:* {sent_today}   (all-time: {sent_total})\n"
        f"• *Qualified added to master list today:* {mnc_today}   (list total: {mnc_total})\n"
        f"{health}\n"
        f"Master list: {MNC_URL}"
    )
    post_slack(msg)
    print("posted:\n" + msg)


if __name__ == "__main__":
    main()
