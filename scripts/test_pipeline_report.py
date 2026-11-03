"""Tests of the arithmetic in pipeline_report.py. Offline. Project 18."""

from datetime import UTC, datetime, timedelta

import pytest
from pipeline_report import Job, Run, feedback, minutes_by_workflow, percentile

T0 = datetime(2026, 11, 3, 12, 0, tzinfo=UTC)


def at(minutes: float) -> datetime:
    return T0 + timedelta(minutes=minutes)


def run(workflow: str, sha: str, jobs: list[tuple[float, float]], *, attempt: int = 1,
        event: str = "pull_request", created: float = 0, conclusion: str = "success") -> Run:
    return Run(1, workflow, event, sha, attempt, conclusion, at(created), at(created),
               [Job(f"j{i}", at(s), at(e)) for i, (s, e) in enumerate(jobs)])


def test_percentile_nearest_rank() -> None:
    xs = [float(x) for x in range(1, 21)]  # 1..20
    assert percentile(xs, 50) == 10
    assert percentile(xs, 95) == 19
    assert percentile(xs, 100) == 20
    assert percentile([7.0], 95) == 7


def test_percentile_needs_values() -> None:
    with pytest.raises(ValueError):
        percentile([], 50)


def test_minutes_count_reruns_apart() -> None:
    runs = [run("CI", "a", [(0, 2), (0, 3)]), run("CI", "a", [(10, 11)], attempt=2)]
    assert minutes_by_workflow(runs) == {"CI": (6.0, 2, 1.0)}


def test_feedback_spans_all_runs_of_a_commit() -> None:
    # Two workflows for one commit: created at 0 and 1, last job ends at 5.
    runs = [run("A", "x", [(0.5, 2)]), run("B", "x", [(3, 5)], created=1)]
    ttf, queue, held = feedback(runs)
    assert ttf == [5.0]
    assert queue == [2.0]  # B waited from 1 to 3 for its first job
    assert held == 0


def test_feedback_ignores_needs_chains_in_queue() -> None:
    # The second job starts after the first; that is not queue time.
    ttf, queue, _ = feedback([run("A", "x", [(0.2, 1), (1, 4)])])
    assert ttf == [4.0]
    assert queue == [pytest.approx(0.2)]


def test_feedback_skips_held_commits_and_pushes() -> None:
    runs = [
        run("A", "held", [], conclusion="action_required"),
        run("A", "main", [(0, 9)], event="push"),
        run("A", "retry", [(0, 1)], attempt=2),
    ]
    ttf, _, held = feedback(runs)
    assert ttf == []
    assert held == 1
