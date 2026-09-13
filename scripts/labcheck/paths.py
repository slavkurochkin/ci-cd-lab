"""Locating files relative to the repository root, with useful failures."""

from functools import lru_cache
from pathlib import Path

import pytest


@lru_cache(maxsize=1)
def repo_root() -> Path:
    """The directory containing ROADMAP.md, walking up from this file."""
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "ROADMAP.md").is_file():
            return candidate
    raise RuntimeError("could not locate the repository root (no ROADMAP.md found above this file)")


def require_file(relative: str) -> Path:
    """Return the path, or fail the test with the path you were supposed to create."""
    path = repo_root() / relative
    if not path.is_file():
        pytest.fail(f"missing file: {relative}\n  expected at: {path}")
    return path
