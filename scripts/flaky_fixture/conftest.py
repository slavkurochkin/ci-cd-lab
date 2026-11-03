"""Quarantine: tests listed in quarantine.txt still run but cannot fail the build.

scripts/flaky.py --quarantine writes the list. Each quarantined test is marked
xfail(strict=False): a failure shows as `x`, a pass as `X`, and neither turns
the run red. That keeps the signal (the test still runs, and the report still
counts it) without letting a known flake decide whether a change merges.

scripts/flaky.py sets FLAKY_DETECT=1, which switches quarantine off. Without
that, the detector saw quarantined tests as skipped and reported nothing
flaky: quarantine hid the tests from the one check that could notice they
were still flaky, or fixed.

Quarantine is a holding pen, not a fix. Every entry needs an owner and an
issue, and a test that stays here for weeks is a test nobody is going to fix.
"""

import os
from pathlib import Path

import pytest

QUARANTINE = Path(__file__).with_name("quarantine.txt")


def _dotted(nodeid: str) -> str:
    path, _, name = nodeid.partition("::")
    return path.removesuffix(".py").replace("/", ".") + "::" + name


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    if os.environ.get("FLAKY_DETECT") == "1" or not QUARANTINE.exists():
        return
    ids = [line.strip() for line in QUARANTINE.read_text().splitlines() if line.strip()]
    for item in items:
        dotted = _dotted(item.nodeid)
        if any(q == dotted or q.endswith("." + dotted) for q in ids):
            item.add_marker(pytest.mark.xfail(reason="quarantined: flaky", strict=False))
