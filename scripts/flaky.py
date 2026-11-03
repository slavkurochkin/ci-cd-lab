#!/usr/bin/env python3
"""Find flaky tests by running a suite many times in random order. Project 18.

A test is flaky when the same code gives it both outcomes. One red run says
nothing about which tests are flaky; twenty runs in shuffled order do. Each
run writes JUnit XML, and a test that passed in some runs and failed in
others is reported with its failure rate.

    python3 scripts/flaky.py --runs 20 --cwd app/api -- \\
        uv run --with pytest-randomly pytest -q -p randomly --junitxml={junit}

    python3 scripts/flaky.py --runs 20 --cwd app/worker -- \\
        npx vitest run --sequence.shuffle --reporter=junit --outputFile={junit}

`{junit}` is replaced with a fresh path for each run. With --quarantine FILE
the flaky test ids are written there (one per line); a suite's conftest can
then mark them as non-blocking. Each run gets FLAKY_DETECT=1, which a
quarantine must honour by switching itself off: a quarantined test still
has to be measured. Exit 1 when any test is flaky.

What you'll learn: which tests are flaky, measured, instead of by reputation.
Run: about runs x suite time, $0.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def outcomes(junit: Path) -> dict[str, str]:
    """Test id -> 'pass' | 'fail' | 'skip' from one JUnit XML file."""
    result: dict[str, str] = {}
    for case in ET.parse(junit).getroot().iter("testcase"):
        classname = case.get("classname", "")
        name = case.get("name", "")
        test_id = f"{classname}::{name}" if classname else name
        if case.find("failure") is not None or case.find("error") is not None:
            result[test_id] = "fail"
        elif case.find("skipped") is not None:
            result[test_id] = "skip"
        else:
            result[test_id] = "pass"
    return result


def classify(runs: list[dict[str, str]]) -> dict[str, tuple[int, int]]:
    """Test id -> (failures, runs it ran in), for tests that both passed and failed."""
    seen: dict[str, list[str]] = defaultdict(list)
    for run in runs:
        for test_id, outcome in run.items():
            if outcome != "skip":
                seen[test_id].append(outcome)
    return {
        t: (o.count("fail"), len(o))
        for t, o in seen.items()
        if "pass" in o and "fail" in o
    }


def always_failing(runs: list[dict[str, str]]) -> list[str]:
    seen: dict[str, set[str]] = defaultdict(set)
    for run in runs:
        for test_id, outcome in run.items():
            seen[test_id].add(outcome)
    return sorted(t for t, o in seen.items() if o == {"fail"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--cwd", default=".")
    parser.add_argument("--quarantine", type=Path, help="write flaky test ids here")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="-- then the test command, with {junit}")
    args = parser.parse_args()
    command = [c for c in args.command if c != "--"]
    if not any("{junit}" in c for c in command):
        parser.error("the command must contain {junit}")

    runs: list[dict[str, str]] = []
    red = 0
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(args.runs):
            junit = Path(tmp) / f"run-{i}.xml"
            cmd = [c.replace("{junit}", str(junit)) for c in command]
            env = {**os.environ, "FLAKY_DETECT": "1"}
            code = subprocess.run(cmd, cwd=args.cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            red += code != 0
            if not junit.exists():
                print(f"run {i}: no JUnit file (exit {code}); is the command right?", file=sys.stderr)
                return 2
            runs.append(outcomes(junit))
    elapsed = time.monotonic() - started

    flaky = classify(runs)
    broken = always_failing(runs)
    tests = len(set().union(*runs))
    print(f"{args.runs} runs of {tests} tests in {elapsed:.0f}s; {red} of {args.runs} runs were red")
    if broken:
        print(f"\nfailing in every run (broken, not flaky): {len(broken)}")
        for t in broken:
            print(f"  {t}")
    print(f"\nflaky: {len(flaky)}")
    for t, (fails, n) in sorted(flaky.items(), key=lambda kv: -kv[1][0] / kv[1][1]):
        print(f"  {fails:>3}/{n:<3} {fails / n:5.0%}  {t}")

    if args.quarantine is not None:
        args.quarantine.write_text("".join(f"{t}\n" for t in sorted(flaky)))
        print(f"\nwrote {len(flaky)} id(s) to {args.quarantine}")
    return 1 if flaky else 0


if __name__ == "__main__":
    sys.exit(main())
