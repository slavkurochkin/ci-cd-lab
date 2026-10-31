#!/usr/bin/env python3
"""Prod's error budget, from the API's own request counts. Project 16.

    python3 scripts/error_budget.py                  # report; exit 2 if spent
    python3 scripts/error_budget.py --slo 99.5 --days 7

The SLO: at least --slo percent of requests to the prod API over the last
--days days are not server errors (5xx). The SLI comes from API Gateway's
CloudWatch metrics (Count and 5xx), so it counts what users received,
whatever the cause, and needs no code in the app.

The error budget is the share of requests allowed to fail: 1% of them at a
99% SLO. "Spent" means more than that failed.

Exit codes: 0 budget left, 2 budget spent, 1 could not tell. Below
--min-requests in the window the number means nothing (one failure out of
three requests is 33%), so the script says so and exits 0.

Reads with the AWS CLI, so it needs nothing installed beyond what a GitHub
runner has: cloudwatch:GetMetricStatistics and apigateway:GET.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import UTC, datetime, timedelta


def aws(*args: str) -> dict:
    out = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def api_id(name: str, region: str) -> str:
    for api in aws("apigatewayv2", "get-apis", "--region", region)["Items"]:
        if api["Name"] == name:
            return api["ApiId"]
    raise SystemExit(f"no API named {name}")


def total(metric: str, api: str, days: int, region: str) -> float:
    end = datetime.now(UTC)
    start = end - timedelta(days=days)
    # Hourly sums, added up here. One period covering the whole window would
    # be refused for windows over a day with the default resolution.
    points = aws(
        "cloudwatch", "get-metric-statistics", "--region", region,
        "--namespace", "AWS/ApiGateway", "--metric-name", metric,
        "--dimensions", f"Name=ApiId,Value={api}", "Name=Stage,Value=$default",
        "--start-time", start.isoformat(), "--end-time", end.isoformat(),
        "--period", "3600", "--statistics", "Sum",
    )["Datapoints"]
    return sum(p["Sum"] for p in points)


def budget(requests: float, errors: float, slo: float) -> dict[str, float]:
    """The arithmetic, separate from the reads so it can be tested."""
    allowed = requests * (1 - slo / 100)
    return {
        "requests": requests,
        "errors": errors,
        "availability_percent": round(100 * (1 - errors / requests), 3) if requests else 100.0,
        "budget_requests": round(allowed, 2),
        "budget_spent_percent": round(100 * errors / allowed, 1) if allowed else (0.0 if not errors else float("inf")),
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--api-name", default="ci-cd-lab-prod-api")
    p.add_argument("--slo", type=float, default=99.0, help="percent of requests that must not be 5xx")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--min-requests", type=int, default=100)
    p.add_argument("--region", default="us-east-1")
    a = p.parse_args()

    api = api_id(a.api_name, a.region)
    b = budget(total("Count", api, a.days, a.region), total("5xx", api, a.days, a.region), a.slo)
    print(
        f"{a.api_name}, last {a.days} days: {b['requests']:.0f} requests, {b['errors']:.0f} 5xx, "
        f"availability {b['availability_percent']}% against an SLO of {a.slo}%"
    )
    if b["requests"] < a.min_requests:
        print(f"fewer than {a.min_requests} requests: too few to judge the budget; not blocking")
        return 0
    print(f"error budget: {b['budget_requests']} failed requests allowed, {b['budget_spent_percent']}% spent")
    return 2 if b["budget_spent_percent"] > 100 else 0


if __name__ == "__main__":
    raise SystemExit(main())
