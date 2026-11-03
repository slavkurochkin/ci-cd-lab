#!/usr/bin/env python3
"""Runner minutes by workflow, and time-to-feedback on pull requests. Project 18.

    python3 scripts/pipeline_report.py              # last 30 days
    python3 scripts/pipeline_report.py --days 7

Data: the Actions API (`gh api`), one call per run for its jobs.

Definitions, chosen before computing anything:

runner minutes    sum over jobs of (completed_at - started_at), per workflow.
                  Queue time is not runner time. Re-run attempts count: a
                  retry spends real minutes even when it turns a run green.
time-to-feedback  for each commit pushed to a pull request: from the first
                  workflow run created for that commit to the last one
                  completing. This is what the author waits for before they
                  know whether the change is good. Runs that waited for a
                  maintainer to approve them (`action_required`) are counted
                  apart: that is a person's wait, not the pipeline's.
queue wait        from a run being created to its first job starting,
                  worst run per commit. Later jobs wait on earlier ones by
                  design (`needs`), which is not queueing.

What you'll learn: where CI time goes, and which number to cut.
Run: about a minute for 30 days of this repository, $0.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta


def ts(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def percentile(xs: list[float], p: float) -> float:
    """Nearest-rank percentile: the smallest value with at least p% at or below it."""
    if not xs:
        raise ValueError("no values")
    ordered = sorted(xs)
    rank = max(1, -(-len(ordered) * p // 100))  # ceil(n * p / 100), at least 1
    return ordered[int(rank) - 1]


@dataclass
class Job:
    name: str
    started: datetime
    completed: datetime

    @property
    def minutes(self) -> float:
        return (self.completed - self.started).total_seconds() / 60


@dataclass
class Run:
    id: int
    workflow: str
    event: str
    head_sha: str
    attempt: int
    conclusion: str | None
    created: datetime
    updated: datetime
    jobs: list[Job]


def gh(path: str) -> object:
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def repo() -> str:
    out = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                         check=True, capture_output=True, text=True)
    return out.stdout.strip()


def fetch(name: str, since: datetime) -> list[Run]:
    raw: list[dict] = []
    page = 1
    while True:
        data = gh(f"repos/{name}/actions/runs?per_page=100&page={page}&created=>={since:%Y-%m-%d}")
        assert isinstance(data, dict)
        batch = data["workflow_runs"]
        raw += batch
        if len(batch) < 100:
            break
        page += 1

    def jobs(r: dict) -> list[Job]:
        data = gh(f"repos/{name}/actions/runs/{r['id']}/attempts/{r['run_attempt']}/jobs?per_page=100")
        assert isinstance(data, dict)
        out = []
        for j in data["jobs"]:
            s, c = ts(j.get("started_at")), ts(j.get("completed_at"))
            if s and c and c >= s and j.get("conclusion") != "skipped":
                out.append(Job(j["name"], s, c))
        return out

    with ThreadPoolExecutor(max_workers=8) as pool:
        all_jobs = list(pool.map(jobs, raw))
    def workflow(r: dict) -> str:
        # Dependabot's runs have a unique name each; its path is stable.
        return "Dependabot updates" if r["path"].startswith("dynamic/dependabot") else r["name"]

    return [
        Run(r["id"], workflow(r), r["event"], r["head_sha"], r["run_attempt"], r["conclusion"],
            ts(r["created_at"]), ts(r["updated_at"]), j)  # type: ignore[arg-type]
        for r, j in zip(raw, all_jobs, strict=True)
    ]


def minutes_by_workflow(runs: list[Run]) -> dict[str, tuple[float, int, float]]:
    """workflow -> (minutes, runs, minutes spent in re-run attempts)."""
    out: dict[str, list[float]] = defaultdict(lambda: [0.0, 0, 0.0])
    for r in runs:
        m = sum(j.minutes for j in r.jobs)
        row = out[r.workflow]
        row[0] += m
        row[1] += 1
        if r.attempt > 1:
            row[2] += m
    return {k: (v[0], int(v[1]), v[2]) for k, v in out.items()}


def feedback(runs: list[Run]) -> tuple[list[float], list[float], int]:
    """Per pull-request commit: time-to-feedback and queue-wait minutes, and commits held for approval."""
    by_sha: dict[str, list[Run]] = defaultdict(list)
    for r in runs:
        if r.event == "pull_request" and r.attempt == 1:
            by_sha[r.head_sha].append(r)
    ttf, queue, held = [], [], 0
    for rs in by_sha.values():
        if any(r.conclusion == "action_required" for r in rs):
            held += 1
            continue
        ran = [r for r in rs if r.jobs]
        if not ran:
            continue
        start = min(r.created for r in ran)
        end = max(j.completed for r in ran for j in r.jobs)
        ttf.append((end - start).total_seconds() / 60)
        queue.append(max((min(j.started for j in r.jobs) - r.created).total_seconds() / 60 for r in ran))
    return ttf, queue, held


def slowest_jobs(runs: list[Run], top: int = 8) -> list[tuple[str, float, float, int]]:
    """(workflow / job, p50 minutes, p95 minutes, count) for pull-request jobs, slowest p95 first."""
    durations: dict[str, list[float]] = defaultdict(list)
    for r in runs:
        if r.event == "pull_request":
            for j in r.jobs:
                durations[f"{r.workflow} / {j.name}"].append(j.minutes)
    rows = [(k, percentile(v, 50), percentile(v, 95), len(v)) for k, v in durations.items() if len(v) >= 3]
    return sorted(rows, key=lambda r: -r[2])[:top]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()
    since = datetime.now(UTC) - timedelta(days=args.days)
    name = repo()
    runs = fetch(name, since)
    print(f"{name}: {len(runs)} workflow runs since {since:%Y-%m-%d}\n")

    rows = minutes_by_workflow(runs)
    total = sum(m for m, _, _ in rows.values())
    print("| workflow | runs | runner minutes | share | in re-runs |")
    print("|---|---|---|---|---|")
    for wf, (m, n, re) in sorted(rows.items(), key=lambda kv: -kv[1][0]):
        print(f"| {wf} | {n} | {m:.0f} | {m / total:.0%} | {re:.0f} |")
    print(f"| **total** | {len(runs)} | **{total:.0f}** | | {sum(r for _, _, r in rows.values()):.0f} |\n")

    ttf, queue, held = feedback(runs)
    if ttf:
        print(f"time-to-feedback over {len(ttf)} pull-request commits "
              f"({held} more waited for a maintainer's approval and are not counted):")
        print(f"  p50 {percentile(ttf, 50):.1f} min   p95 {percentile(ttf, 95):.1f} min   max {max(ttf):.1f} min")
        print(f"  worst queue wait per commit: p50 {percentile(queue, 50):.1f} min   p95 {percentile(queue, 95):.1f} min\n")
    print("slowest pull-request jobs (p95):")
    for k, p50, p95, n in slowest_jobs(runs):
        print(f"  {p95:5.1f} min p95  {p50:5.1f} p50  n={n:<4} {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
