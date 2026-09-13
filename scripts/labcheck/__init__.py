"""Shared helpers for lab verifiers.

Every lab's ``verify/test_*.py`` imports from here so the assertions stay
consistent and the error messages stay actionable. A verifier that fails
should tell you which file to open and what is missing -- never just
``assert False``.
"""

from labcheck.gh import gh_available, latest_runs, repo_slug
from labcheck.paths import repo_root, require_file
from labcheck.shell import CommandResult, run, tool_available
from labcheck.workflow import (
    Workflow,
    load_workflow,
    unpinned_third_party_actions,
)

__all__ = [
    "CommandResult",
    "Workflow",
    "gh_available",
    "latest_runs",
    "load_workflow",
    "repo_root",
    "repo_slug",
    "require_file",
    "run",
    "tool_available",
    "unpinned_third_party_actions",
]
