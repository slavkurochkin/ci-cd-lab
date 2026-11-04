"""A slow, stable suite for measuring sharding. Project 18.

48 tests of 0.25s each: 12s of work in series, and nothing else. Real suites
are rarely this even, which is the point of measuring both.
"""

import time

import pytest


@pytest.mark.parametrize("n", range(48))
def test_slow(n: int) -> None:
    time.sleep(0.25)
    assert n >= 0
