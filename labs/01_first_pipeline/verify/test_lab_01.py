"""Lab 01 verifier -- Pipelines & the Build Contract.

Every failure here names the TODO it corresponds to, so a red test tells you
which part of the workflow to open.
"""

import re

import pytest

from labcheck import gh_available, latest_runs, load_workflow, tool_available
from labcheck.shell import run

WORKFLOW = ".github/workflows/lab-01-ci.yml"

# Steps that mask a non-zero exit. These are the reason a green check can lie.
SWALLOWS_FAILURE = re.compile(r"\|\|\s*(true|:)\s*$|\|\|\s*(true|:)\s*\n", re.MULTILINE)


@pytest.fixture(scope="module")
def workflow():
    return load_workflow(WORKFLOW)


# ---------------------------------------------------------------------------
# TODO(lab-01-a) -- triggers
# ---------------------------------------------------------------------------


def test_runs_on_pull_requests(workflow):
    triggers = workflow.triggers
    assert "pull_request" in triggers, (
        "TODO(lab-01-a): the workflow does not run on pull requests, so it gates nothing.\n"
        f"  current triggers: {sorted(str(k) for k in triggers)}"
    )


def test_pull_request_trigger_targets_main(workflow):
    config = workflow.triggers.get("pull_request") or {}
    branches = config.get("branches", []) if isinstance(config, dict) else []
    assert "main" in branches, (
        "TODO(lab-01-a): scope the pull_request trigger to PRs targeting `main`.\n"
        "  expected:  pull_request:\n               branches: [main]"
    )


def test_runs_on_push_to_main(workflow):
    config = workflow.triggers.get("push") or {}
    branches = config.get("branches", []) if isinstance(config, dict) else []
    assert "main" in branches, (
        "TODO(lab-01-a): also run on pushes to `main`.\n"
        "  Without it, nothing verifies the merge commit itself -- and a merge of two\n"
        "  individually-green PRs can still be broken."
    )


def test_manual_trigger_kept(workflow):
    assert "workflow_dispatch" in workflow.triggers, (
        "TODO(lab-01-a): keep workflow_dispatch. Being able to run a pipeline by hand\n"
        "  is how you test it without opening a pull request."
    )


# ---------------------------------------------------------------------------
# TODO(lab-01-b) -- the check must be able to fail
# ---------------------------------------------------------------------------


def test_no_step_swallows_its_exit_code(workflow):
    offenders = [
        str(step)
        for step in workflow.steps()
        if step.run and SWALLOWS_FAILURE.search(step.run)
    ]
    assert not offenders, (
        "TODO(lab-01-b): these steps discard their exit code with `|| true`, so the job\n"
        "  goes green whatever happens:\n    " + "\n    ".join(offenders)
    )


def test_no_job_or_step_continues_on_error(workflow):
    offenders = [
        str(step) for step in workflow.steps() if step.raw.get("continue-on-error") is True
    ]
    offenders += [
        f"job:{job_id}" for job_id, job in workflow.jobs.items() if job.get("continue-on-error")
    ]
    assert not offenders, (
        "TODO(lab-01-b): `continue-on-error: true` is the other way to make a check\n"
        "  incapable of failing:\n    " + "\n    ".join(offenders)
    )


# ---------------------------------------------------------------------------
# TODO(lab-01-c) and (lab-01-d) -- the build contract, for both services
# ---------------------------------------------------------------------------


def test_both_services_have_a_job(workflow):
    assert set(workflow.jobs) >= {"api", "worker"}, (
        "TODO(lab-01-d): this repository has two services and both need a job.\n"
        f"  found: {sorted(workflow.jobs)}"
    )


def test_worker_job_is_independent_of_api(workflow):
    assert workflow.needs("worker") == [], (
        "TODO(lab-01-d): the worker job declares `needs: api`. The services are\n"
        "  independent, so making them sequential only means you wait longer to learn\n"
        "  that both are broken."
    )


@pytest.mark.parametrize(
    ("job_id", "tool", "hint"),
    [
        ("api", "ruff check", "uv run ruff check ."),
        ("api", "ruff format", "uv run ruff format --check ."),
        ("api", "pytest", "uv run pytest"),
        ("worker", "npm run lint", "npm run lint"),
        ("worker", "npm run format:check", "npm run format:check"),
        ("worker", "npm test", "npm test"),
    ],
)
def test_build_contract_step_present(workflow, job_id, tool, hint):
    if job_id not in workflow.jobs:
        pytest.skip(f"the {job_id} job does not exist yet -- see TODO(lab-01-d)")

    commands = "\n".join(step.run for step in workflow.steps(job_id) if step.run)
    assert tool in commands, (
        f"TODO(lab-01-c)/(lab-01-d): the {job_id} job never runs `{tool}`.\n"
        f"  The build contract is format, lint, and test. Add: {hint}"
    )


def test_api_lint_runs_before_tests(workflow):
    """Cheap checks first: a lint failure should not wait behind a slow suite."""
    commands = [step.run or "" for step in workflow.steps("api")]
    lint_at = next((i for i, c in enumerate(commands) if "ruff check" in c), None)
    test_at = next((i for i, c in enumerate(commands) if "pytest" in c), None)
    if lint_at is None or test_at is None:
        pytest.skip("lint or test step missing -- covered by another test")
    assert lint_at < test_at, (
        "Put the lint step before the test step. Fast checks first means faster\n"
        "  feedback on the most common class of mistake."
    )


# ---------------------------------------------------------------------------
# TODO(lab-01-e) -- timeouts
# ---------------------------------------------------------------------------


def test_every_job_has_a_timeout(workflow):
    missing = [job_id for job_id, job in workflow.jobs.items() if "timeout-minutes" not in job]
    assert not missing, (
        "TODO(lab-01-e): these jobs have no `timeout-minutes` and inherit the 6 hour\n"
        f"  default: {missing}\n"
        "  A hung job with no timeout burns runner minutes until someone notices."
    )


def test_timeouts_are_realistic(workflow):
    generous = {
        job_id: job["timeout-minutes"]
        for job_id, job in workflow.jobs.items()
        if isinstance(job.get("timeout-minutes"), int) and job["timeout-minutes"] > 30
    }
    assert not generous, (
        "TODO(lab-01-e): these timeouts are too generous for a suite that runs in\n"
        f"  seconds: {generous}\n"
        "  A timeout only protects you if it fires before you would have noticed anyway."
    )


# ---------------------------------------------------------------------------
# Tool and live checks
# ---------------------------------------------------------------------------


def test_actionlint_is_clean(workflow):
    if not tool_available("actionlint"):
        pytest.skip("actionlint not installed (brew install actionlint)")
    result = run(["actionlint", WORKFLOW])
    assert result.ok, f"actionlint found problems in {WORKFLOW}:\n{result.output}"


@pytest.mark.live_github
def test_workflow_has_actually_run():
    """Static structure is not proof. Only a real run is."""
    if not gh_available():
        pytest.skip("gh CLI not installed or not authenticated")

    runs = latest_runs("lab-01-ci.yml")
    if not runs:
        pytest.skip(
            "this workflow has never run -- push the branch and open a pull request, "
            "then re-run this verifier"
        )

    successes = [r for r in runs if r.get("conclusion") == "success"]
    assert successes, (
        "the workflow has run but never succeeded. Most recent runs:\n"
        + "\n".join(f"  {r.get('conclusion')}  {r.get('displayTitle')}  {r.get('url')}" for r in runs[:5])
    )
