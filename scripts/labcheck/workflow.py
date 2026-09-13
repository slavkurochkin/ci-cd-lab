"""Parsing and asserting on GitHub Actions workflow files.

The one trap worth knowing: PyYAML reads an unquoted ``on:`` key as the
boolean ``True`` (YAML 1.1 legacy). Every tool that parses workflows has to
handle it, and ``Workflow.triggers`` does it here so no verifier has to.
"""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# A pinned action reference looks like owner/repo@<40 hex chars>.
SHA_PIN = re.compile(r"^[^@]+@[0-9a-f]{40}$")

# Actions published by GitHub itself. Still worth pinning, but not the point of Lab 04.
FIRST_PARTY_PREFIXES = ("actions/", "github/")


@dataclass(frozen=True)
class Step:
    job_id: str
    index: int
    raw: dict[str, Any]

    @property
    def uses(self) -> str | None:
        return self.raw.get("uses")

    @property
    def run(self) -> str | None:
        return self.raw.get("run")

    @property
    def name(self) -> str:
        return self.raw.get("name") or self.uses or (self.run or "").splitlines()[0][:60]

    def __str__(self) -> str:
        return f"{self.job_id}[{self.index}] {self.name}"


class Workflow:
    """A parsed workflow file with the accessors verifiers actually need."""

    def __init__(self, path: Path, data: dict[str, Any]) -> None:
        self.path = path
        self.data = data

    @property
    def name(self) -> str:
        return self.data.get("name", self.path.stem)

    @property
    def triggers(self) -> dict[str, Any]:
        """The ``on:`` block, working around PyYAML reading ``on`` as True."""
        for key in ("on", True):
            if key in self.data:
                value = self.data[key]
                if isinstance(value, str):
                    return {value: None}
                if isinstance(value, list):
                    return dict.fromkeys(value)
                if isinstance(value, dict):
                    return value
        return {}

    @property
    def jobs(self) -> dict[str, dict[str, Any]]:
        return self.data.get("jobs", {}) or {}

    def job(self, job_id: str) -> dict[str, Any]:
        return self.jobs.get(job_id, {}) or {}

    def steps(self, job_id: str | None = None) -> list[Step]:
        """Every step in the workflow, or in one job."""
        job_ids = [job_id] if job_id else list(self.jobs)
        collected: list[Step] = []
        for jid in job_ids:
            for index, raw in enumerate(self.job(jid).get("steps", []) or []):
                if isinstance(raw, dict):
                    collected.append(Step(jid, index, raw))
        return collected

    def needs(self, job_id: str) -> list[str]:
        value = self.job(job_id).get("needs")
        if value is None:
            return []
        return [value] if isinstance(value, str) else list(value)

    def action_refs(self) -> list[str]:
        return [step.uses for step in self.steps() if step.uses]

    def __repr__(self) -> str:
        return f"Workflow({self.path.name!r}, jobs={list(self.jobs)})"


def load_workflow(relative: str) -> Workflow:
    """Load ``.github/workflows/<name>`` and fail helpfully if it is missing or invalid."""
    import pytest

    from labcheck.paths import repo_root

    path = repo_root() / relative
    if not path.is_file():
        pytest.fail(f"missing workflow: {relative}\n  expected at: {path}")

    try:
        data = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        pytest.fail(f"{relative} is not valid YAML:\n{exc}")

    if not isinstance(data, dict):
        pytest.fail(f"{relative} did not parse to a mapping -- is the file empty?")

    return Workflow(path, data)


def unpinned_third_party_actions(workflow: Workflow) -> list[str]:
    """Third-party ``uses:`` references not pinned to a full commit SHA.

    Local actions (``./path``) and reusable workflows in this repo are excluded,
    because there is no supply chain to pin.
    """
    unpinned = []
    for ref in workflow.action_refs():
        if ref.startswith((".", "/")):
            continue
        if ref.startswith(FIRST_PARTY_PREFIXES):
            continue
        if not SHA_PIN.match(ref):
            unpinned.append(ref)
    return unpinned
