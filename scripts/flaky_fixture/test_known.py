"""A suite with known flaky tests, so the detector can be checked. Project 18.

Three tests here are flaky on purpose, one per common cause. Every other test
is stable. scripts/flaky.py must report exactly the three, and nothing else.
"""

import random
import time

import pytest

_cache: dict[str, int] = {}


# 1. Order dependence: passes only when test_fill_cache ran first.
def test_fill_cache() -> None:
    _cache["user"] = 1
    assert _cache["user"] == 1


def test_reads_cache_left_by_another_test() -> None:  # FLAKY: order
    assert _cache.get("user") == 1


# 2. Randomness without a fixed seed: fails about one run in five.
def test_random_sample_is_unique() -> None:  # FLAKY: unseeded randomness
    picks = [random.randint(1, 5) for _ in range(2)]
    assert picks[0] != picks[1]


# 3. A deadline close to the work: passes on a fast machine, fails on a slow one.
def test_finishes_within_deadline() -> None:  # FLAKY: timing
    start = time.perf_counter()
    time.sleep(random.uniform(0.004, 0.012))
    assert time.perf_counter() - start < 0.010


@pytest.mark.parametrize("n", range(12))
def test_stable_arithmetic(n: int) -> None:
    assert n * 2 == n + n


def test_stable_seeded_randomness() -> None:
    rng = random.Random(42)
    assert [rng.randint(1, 30) for _ in range(3)] == [21, 4, 1]
