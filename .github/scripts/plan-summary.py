#!/usr/bin/env python3
"""Turn `terraform show` output and conftest output into a short Markdown summary.

    plan-summary.py <env> <plan.txt> <policy.txt>

Written for a reader who does not know Terraform. The order is: the verdict,
anything that deletes, everything else that changes, the policy result, then
the full plan folded away. Only the full plan is ever truncated, so a long
plan cannot push a delete out of view.
"""

import re
import sys

# GitHub rejects comments over 65,536 characters, and this summary shares a
# comment with the other environment's.
FULL_PLAN_LIMIT = 25_000

ACTIONS = [
    # (text Terraform prints, label, dangerous)
    ("must be replaced", "replace: **deleted, then created again**", True),
    ("will be destroyed", "**delete**", True),
    ("will be updated in-place", "change in place", False),
    ("will be created", "create", False),
    ("will be read during apply", "read", False),
    ("has moved to", "rename only (no change in AWS)", False),
    ("will be imported", "adopt an existing resource", False),
]

ADDRESS = re.compile(r"^\s*# (\S+) (.+)$")


def classify(plan: str) -> list[tuple[str, str, bool]]:
    found = []
    for line in plan.splitlines():
        m = ADDRESS.match(line)
        if not m:
            continue
        address, rest = m.groups()
        for text, label, dangerous in ACTIONS:
            if rest.startswith(text):
                found.append((address, label, dangerous))
                break
    return found


def verdict(plan: str) -> str:
    for line in plan.splitlines():
        if line.startswith("Plan:") or line.startswith("No changes."):
            return line.strip()
    return "No plan summary line found. Read the full plan."


def policy_failures(policy: str) -> tuple[bool, list[str]]:
    failures = []
    for line in policy.splitlines():
        if line.startswith("FAIL"):
            # FAIL - <file> - <namespace> - <message>
            failures.append(line.split(" - ", 3)[-1])
    passed = not failures and "0 failures" in policy
    return passed, failures


def main() -> None:
    env, plan_path, policy_path = sys.argv[1:4]
    plan = open(plan_path, encoding="utf-8").read()
    policy = open(policy_path, encoding="utf-8").read()

    changes = classify(plan)
    dangerous = [c for c in changes if c[2]]
    passed, failures = policy_failures(policy)

    out = [f"### `{env}`: {verdict(plan)}", ""]

    if dangerous:
        out.append(f"> [!WARNING]\n> This plan deletes {len(dangerous)} resource(s). Check each one is meant to go.")
        out.append("")

    if changes:
        out.append("| Resource | What happens |")
        out.append("|---|---|")
        for address, label, _ in sorted(changes, key=lambda c: not c[2]):
            out.append(f"| `{address}` | {label} |")
        out.append("")

    if passed:
        out.append("**Policy:** passed.")
    elif failures:
        out.append(f"**Policy: {len(failures)} violation(s).** This blocks the merge.")
        out.extend(f"- {f}" for f in failures)
    else:
        out.append("**Policy:** did not run cleanly. See the job log.")
    out.append("")

    body = plan
    note = ""
    if len(body) > FULL_PLAN_LIMIT:
        hidden = len(body) - FULL_PLAN_LIMIT
        body = body[:FULL_PLAN_LIMIT]
        note = f"\n\n_Truncated: {hidden:,} characters hidden. The table above lists every resource in the plan._"
    out.append("<details><summary>Full plan</summary>\n")
    out.append("```\n" + body.rstrip() + "\n```" + note)
    out.append("\n</details>")

    print("\n".join(out))


if __name__ == "__main__":
    main()
