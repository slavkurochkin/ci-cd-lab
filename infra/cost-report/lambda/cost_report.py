"""Weekly AWS cost digest and budget alerts, posted to Slack. Project 18.

One function, two triggers:

  EventBridge Scheduler, Mondays   the digest: last 7 days against the 7
                                   before, by the `Lab` tag and by service,
                                   ranked, plus CI runner minutes.
  SNS, from AWS Budgets            an alert, forwarded as it arrives.

Costs are UnblendedCost with credits and refunds excluded: the usage you
would pay for. With promotional credits the net is $0 every week, and a
report of zeros teaches nothing about what is spending.

Cost Explorer bills $0.01 per request. The digest makes two (one per
grouping, each covering both weeks as daily rows), so it costs $0.02 a week.
A per-minute poll would cost $432 a month; the metering is the design.

Runner minutes come from GitHub, which this function cannot ask without a
stored token. The weekly Pipeline health workflow writes them to S3, and the
digest reads that file. If the file is older than eight days the digest says
so: GitHub disables scheduled workflows in a repository with no activity for
60 days, and a report that silently drops a section looks like a quiet week.
"""

from __future__ import annotations

import json
import os
import urllib.request
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from typing import Any

UNTAGGED = "untagged"
STALE_AFTER = timedelta(days=8)


def week_bounds(today: date) -> tuple[date, date, date]:
    """(start of the week before, start of last week, today): two 7-day windows ending today."""
    return today - timedelta(days=14), today - timedelta(days=7), today


def split_weeks(results: list[dict[str, Any]], boundary: date) -> tuple[dict[str, float], dict[str, float]]:
    """Daily Cost Explorer rows -> ({key: cost} before boundary, {key: cost} from it)."""
    before: dict[str, float] = defaultdict(float)
    after: dict[str, float] = defaultdict(float)
    for day in results:
        start = date.fromisoformat(day["TimePeriod"]["Start"])
        bucket = after if start >= boundary else before
        for group in day.get("Groups", []):
            key = group["Keys"][0]
            # A tag group key is "Lab$<value>"; "Lab$" alone is untagged.
            if "$" in key:
                key = key.split("$", 1)[1] or UNTAGGED
            bucket[key] += float(group["Metrics"]["UnblendedCost"]["Amount"])
    return dict(before), dict(after)


def ranked(previous: dict[str, float], current: dict[str, float], top: int = 8) -> list[tuple[str, float, float]]:
    """(key, this week, change) by this week's cost, keys under half a cent dropped."""
    keys = {k for k in set(previous) | set(current) if max(previous.get(k, 0), current.get(k, 0)) >= 0.005}
    rows = [(k, current.get(k, 0.0), current.get(k, 0.0) - previous.get(k, 0.0)) for k in keys]
    return sorted(rows, key=lambda r: (-r[1], r[0]))[:top]


def money(x: float) -> str:
    return f"${x:,.2f}"


def delta(x: float) -> str:
    if abs(x) < 0.005:
        return "±$0.00"
    return ("+" if x > 0 else "−") + money(abs(x))


def label(key: str, by_tag: bool) -> str:
    if not by_tag:
        return key
    return "*untagged*" if key == UNTAGGED else f"Lab {key}"


def section(title: str, previous: dict[str, float], current: dict[str, float], by_tag: bool) -> list[str]:
    lines = [f"*{title}*"]
    for i, (key, cost, change) in enumerate(ranked(previous, current), 1):
        lines.append(f"{i}. {label(key, by_tag)}: {money(cost)} ({delta(change)})")
    if len(lines) == 1:
        lines.append("nothing over half a cent")
    return lines


def runner_section(data: dict[str, Any] | None, now: datetime) -> list[str]:
    lines = ["*CI runner minutes, last 7 days*"]
    if data is None:
        return lines + ["no data: the Pipeline health workflow has not written any"]
    generated = datetime.fromisoformat(data["generated_at"])
    if now - generated > STALE_AFTER:
        return lines + [f"stale: last written {generated:%Y-%m-%d}. Is the scheduled workflow disabled?"]
    workflows = sorted(data["workflows"].items(), key=lambda kv: -kv[1])
    for i, (name, minutes) in enumerate(workflows[:6], 1):
        lines.append(f"{i}. {name}: {minutes:.0f} min")
    lines.append(f"total {data['total_minutes']:.0f} min over {data['runs']} runs")
    return lines


def digest(by_tag: list[dict[str, Any]], by_service: list[dict[str, Any]], runner: dict[str, Any] | None,
           today: date, now: datetime) -> str:
    _, boundary, end = week_bounds(today)
    tag_prev, tag_cur = split_weeks(by_tag, boundary)
    svc_prev, svc_cur = split_weeks(by_service, boundary)
    total, total_prev = sum(tag_cur.values()), sum(tag_prev.values())
    untagged = tag_cur.get(UNTAGGED, 0.0)
    share = f"{untagged / total:.0%}" if total >= 0.005 else "0%"
    lines = [
        f"*AWS spend {boundary:%b %d} – {end - timedelta(days=1):%b %d}*: {money(total)} "
        f"({delta(total - total_prev)} on the week before), before credits",
        f"untagged: {money(untagged)} ({share})",
        "",
        *section("By Lab tag", tag_prev, tag_cur, by_tag=True),
        "",
        *section("By service", svc_prev, svc_cur, by_tag=False),
        "",
        *runner_section(runner, now),
    ]
    return "\n".join(lines)


def alert_text(message: str, subject: str | None) -> str:
    return f":rotating_light: *{subject or 'AWS Budgets alert'}*\n```{message.strip()[:2500]}```"


# --- AWS and Slack; everything above is pure and tested offline ------------------------


def cost_explorer_rows(ce: Any, start: date, end: date, group_by: dict[str, str]) -> list[dict[str, Any]]:
    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[group_by],
        Filter={"Not": {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Credit", "Refund"]}}},
    )
    return list(response["ResultsByTime"])


def read_runner_minutes(s3: Any, bucket: str, key: str) -> dict[str, Any] | None:
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except s3.exceptions.NoSuchKey:
        return None
    return dict(json.loads(body))


def post(webhook: str, text: str) -> None:
    request = urllib.request.Request(
        webhook, data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310 (fixed https URL from SSM)
        if response.status != 200:
            raise RuntimeError(f"Slack answered {response.status}")


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    import boto3  # in the Lambda runtime; imported here so tests need no AWS SDK

    webhook = boto3.client("ssm").get_parameter(Name=os.environ["WEBHOOK_PARAMETER"], WithDecryption=True)[
        "Parameter"
    ]["Value"]

    records = event.get("Records", [])
    if records and records[0].get("EventSource") == "aws:sns":
        for record in records:
            sns = record["Sns"]
            post(webhook, alert_text(sns["Message"], sns.get("Subject")))
        return {"posted": "alert", "count": len(records)}

    now = datetime.now(UTC)
    first, _, end = week_bounds(now.date())
    ce = boto3.client("ce", region_name="us-east-1")
    by_tag = cost_explorer_rows(ce, first, end, {"Type": "TAG", "Key": "Lab"})
    by_service = cost_explorer_rows(ce, first, end, {"Type": "DIMENSION", "Key": "SERVICE"})
    runner = read_runner_minutes(boto3.client("s3"), os.environ["RUNNER_BUCKET"], os.environ["RUNNER_KEY"])
    text = digest(by_tag, by_service, runner, now.date(), now)
    print(text)
    if not event.get("dry_run"):
        post(webhook, text)
    return {"posted": "digest" if not event.get("dry_run") else "dry-run", "chars": len(text)}
