#!/usr/bin/env python3
"""The four DORA metrics for this repository, from GitHub and Git. Project 16.

    python3 scripts/dora.py              # Markdown report
    python3 scripts/dora.py --json       # the numbers

Production has two delivery paths here, and both count:

  terraform   Capstone B's Lambda prod: GitHub Deployments to the `infra-prod`
              environment, made by the Terraform workflow's apply-prod job.
  gitops      Capstone C's cluster prod: commits on main that change
              deploy/envs/prod (a promotion, a config change, a revert).

Methodology, stated because every choice moves a number:

  deployment          terraform: a deployment whose last status is `success`.
                      Deployments that end in `error` after `waiting` were
                      superseded or cancelled before approval; nothing reached
                      prod, so they are not deployments (5 of 7 here).
                      gitops: the merge of a commit changing deploy/envs/prod.
                      Argo CD applies it minutes later; the cluster is gone
                      between sessions, so merge time is the time used.
  lead time           from the first commit of the pull request that made the
                      change to its prod deploy. For a digest promotion the
                      change is the pull request behind the commit the image
                      was built from; for any other prod change, its own pull
                      request. Without a pull request, the commit time.
  change failure      terraform: a deployment whose last status is `failure`.
                      gitops: a prod change that a later `Revert "..."` commit
                      undid.
  time to restore     from a failed change to the deployment that undid it.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from functools import cache

REPO = "slavkurochkin/ci-cd-lab"
PROD_FILE = "deploy/envs/prod/kustomization.yaml"


@dataclass(frozen=True)
class Deploy:
    path: str  # "terraform" or "gitops"
    ref: str  # deployment id or commit sha
    at: datetime
    change_at: datetime  # when the change landed on main
    failed: bool
    restored_at: datetime | None = None  # when a failed change was undone
    label: str = ""


def ts(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(UTC)


def hours(delta: timedelta) -> float:
    return round(delta.total_seconds() / 3600, 2)


# --- metrics (pure; tested in scripts/test_dora.py) ---------------------------


def metrics(deploys: list[Deploy], days: float) -> dict[str, object]:
    """The four DORA metrics over a window of `days`."""
    if not deploys:
        return {"deployments": 0}
    lead = [hours(d.at - d.change_at) for d in deploys]
    failures = [d for d in deploys if d.failed]
    restores = [hours(d.restored_at - d.at) for d in failures if d.restored_at]
    return {
        "deployments": len(deploys),
        "deploys_per_week": round(len(deploys) / days * 7, 1),
        "lead_time_hours_median": round(statistics.median(lead), 2),
        "lead_time_hours_max": max(lead),
        "change_failure_rate": round(len(failures) / len(deploys), 3),
        "failed_changes": len(failures),
        "time_to_restore_hours_median": round(statistics.median(restores), 2) if restores else None,
        "unrestored_failures": len(failures) - len(restores),
    }


def reverted_by(subjects: dict[str, str]) -> dict[str, str]:
    """Map a reverted commit's subject to the sha of the commit reverting it.

    `git revert` titles a commit `Revert "<original subject>"`; squash merges
    then append ` (#N)`.
    """
    out = {}
    for sha, subject in subjects.items():
        m = re.match(r'^Revert "(.*)"(?: \(#\d+\))?$', subject)
        if m:
            out[m.group(1)] = sha
    return out


# --- data -------------------------------------------------------------------------


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def gh(path: str) -> list | dict:
    return json.loads(run("gh", "api", "--paginate", path))


def commit_time(sha: str) -> datetime:
    return ts(run("git", "show", "-s", "--format=%cI", sha).strip())


@cache
def change_started(sha: str) -> datetime:
    """When the change in `sha` was first committed: its pull request's first
    commit. A squash merge's subject ends in (#N)."""
    subject = run("git", "show", "-s", "--format=%s", sha).strip()
    m = re.search(r"\(#(\d+)\)$", subject)
    if not m:
        return commit_time(sha)
    commits = gh(f"repos/{REPO}/pulls/{m.group(1)}/commits?per_page=100")
    return min(ts(c["commit"]["author"]["date"]) for c in commits) if commits else commit_time(sha)


def terraform_deploys() -> list[Deploy]:
    out = []
    for d in gh(f"repos/{REPO}/deployments?environment=infra-prod&per_page=100"):
        statuses = gh(f"repos/{REPO}/deployments/{d['id']}/statuses?per_page=100")
        if not statuses:
            continue
        last = statuses[0]  # newest first
        if last["state"] not in ("success", "failure"):
            continue  # error/inactive after waiting: never reached prod
        out.append(
            Deploy(
                path="terraform",
                ref=str(d["id"]),
                at=ts(last["created_at"]),
                change_at=change_started(d["sha"]),
                failed=last["state"] == "failure",
                label=d["sha"][:7],
            )
        )
    return out


def gitops_deploys() -> list[Deploy]:
    log = run("git", "log", "--format=%H%x09%cI%x09%s", "origin/main", "--", PROD_FILE)
    rows = [line.split("\t", 2) for line in log.splitlines()]
    subjects = {sha: subject for sha, _, subject in rows}
    reverts = reverted_by(subjects)
    times = {sha: ts(at) for sha, at, _ in rows}
    out = []
    for sha, _at, subject in rows:
        m = re.match(r"^Promote ([0-9a-f]{7,40}) to prod", subject)
        change_at = change_started(m.group(1) if m else sha)
        undo = reverts.get(subject)
        out.append(
            Deploy(
                path="gitops",
                ref=sha,
                at=times[sha],
                change_at=change_at,
                failed=undo is not None,
                restored_at=times[undo] if undo else None,
                label=subject[:60],
            )
        )
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    run("git", "fetch", "-q", "origin", "main")

    deploys = terraform_deploys() + gitops_deploys()
    first = min(d.at for d in deploys)
    last = max(d.at for d in deploys)
    days = max((last - first).total_seconds() / 86400, 1.0)
    result = {
        "window": {"from": first.isoformat(), "to": last.isoformat(), "days": round(days, 2)},
        "all": metrics(deploys, days),
        "terraform": metrics([d for d in deploys if d.path == "terraform"], days),
        "gitops": metrics([d for d in deploys if d.path == "gitops"], days),
        "deployments": [
            {
                "path": d.path,
                "at": d.at.isoformat(),
                "lead_time_hours": hours(d.at - d.change_at),
                "failed": d.failed,
                "restore_hours": hours(d.restored_at - d.at) if d.restored_at else None,
                "what": d.label,
            }
            for d in sorted(deploys, key=lambda d: d.at)
        ],
    }
    if args.json:
        print(json.dumps(result, indent=2))
        return
    w = result["window"]
    print(f"DORA metrics, {w['from'][:16]} to {w['to'][:16]} ({w['days']} days)\n")
    print("| | deployments | per week | lead time (median, h) | change failure rate | time to restore (median, h) |")
    print("|---|---|---|---|---|---|")
    for key in ("terraform", "gitops", "all"):
        m = result[key]
        print(
            f"| {key} | {m['deployments']} | {m.get('deploys_per_week')} | "
            f"{m.get('lead_time_hours_median')} | {m.get('change_failure_rate')} "
            f"({m.get('failed_changes')}) | {m.get('time_to_restore_hours_median')} |"
        )
    print("\n| when (UTC) | path | lead time (h) | failed | restored after (h) | what |")
    print("|---|---|---|---|---|---|")
    for d in result["deployments"]:
        print(
            f"| {d['at'][:16]} | {d['path']} | {d['lead_time_hours']} | "
            f"{'yes' if d['failed'] else ''} | {d['restore_hours'] or ''} | {d['what']} |"
        )


if __name__ == "__main__":
    main()
