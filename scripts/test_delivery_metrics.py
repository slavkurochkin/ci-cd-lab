"""Tests for the DORA and error-budget arithmetic. Run: cd scripts && uv run --with pytest pytest test_delivery_metrics.py"""

from datetime import UTC, datetime, timedelta

from dora import Deploy, metrics, reverted_by

T0 = datetime(2026, 10, 1, tzinfo=UTC)


def deploy(hour: float, change_hour: float, failed=False, restored_hour=None) -> Deploy:
    at = T0 + timedelta(hours=hour)
    return Deploy(
        path="gitops",
        ref=str(hour),
        at=at,
        change_at=T0 + timedelta(hours=change_hour),
        failed=failed,
        restored_at=T0 + timedelta(hours=restored_hour) if restored_hour is not None else None,
    )


def test_no_deploys():
    assert metrics([], 7) == {"deployments": 0}


def test_frequency_lead_time_failure_rate_restore():
    m = metrics(
        [
            deploy(10, 8),  # lead 2h
            deploy(20, 19, failed=True, restored_hour=20.5),  # lead 1h, restore 0.5h
            deploy(30, 26),  # lead 4h
            deploy(40, 39, failed=True),  # never restored
        ],
        days=14,
    )
    assert m["deployments"] == 4
    assert m["deploys_per_week"] == 2.0
    assert m["lead_time_hours_median"] == 1.5
    assert m["lead_time_hours_max"] == 4.0
    assert m["change_failure_rate"] == 0.5
    assert m["failed_changes"] == 2
    assert m["time_to_restore_hours_median"] == 0.5
    assert m["unrestored_failures"] == 1


def test_no_failures_means_no_restore_time():
    m = metrics([deploy(1, 0)], days=7)
    assert m["change_failure_rate"] == 0
    assert m["time_to_restore_hours_median"] is None


def test_reverts_are_matched_by_subject_including_squash_suffix():
    subjects = {
        "a1": 'Revert "prod: rename the orders table (#80)" (#82)',
        "b2": "prod: rename the orders table (#80)",
        "c3": 'Revert "plain subject"',
        "d4": "Promote 48fc0a4 to prod (#78)",
    }
    assert reverted_by(subjects) == {
        "prod: rename the orders table (#80)": "a1",
        "plain subject": "c3",
    }


# --- error_budget.budget ------------------------------------------------------

from error_budget import budget


def test_budget_within():
    b = budget(requests=1000, errors=5, slo=99)
    assert b["budget_requests"] == 10
    assert b["budget_spent_percent"] == 50
    assert b["availability_percent"] == 99.5


def test_budget_spent():
    b = budget(requests=200, errors=12, slo=99)
    assert b["budget_spent_percent"] == 600
    assert b["availability_percent"] == 94.0


def test_budget_with_no_requests():
    assert budget(requests=0, errors=0, slo=99)["budget_spent_percent"] == 0
