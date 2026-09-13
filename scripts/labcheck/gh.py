"""Reading real workflow runs from GitHub.

Static checks prove a workflow is well-formed. Only a real run proves it works,
so the Actions labs assert against ``gh run list`` as their final gate.
"""

import json
from typing import Any

from labcheck.shell import run, tool_available


def gh_available() -> bool:
    """True when the gh CLI is installed and authenticated."""
    if not tool_available("gh"):
        return False
    return run(["gh", "auth", "status"], timeout=30).ok


def repo_slug() -> str | None:
    """``owner/name`` for the current directory's repo, or None if there is no remote."""
    result = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    return result.stdout.strip() or None if result.ok else None


def latest_runs(workflow_file: str, limit: int = 10) -> list[dict[str, Any]]:
    """Recent runs of one workflow, newest first. Empty when it has never run."""
    result = run(
        [
            "gh", "run", "list",
            "--workflow", workflow_file,
            "--limit", str(limit),
            "--json", "conclusion,status,headBranch,event,displayTitle,url,createdAt",
        ]
    )
    if not result.ok:
        return []
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return []
