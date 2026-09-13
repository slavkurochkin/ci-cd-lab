"""Lab 02 verifier -- Speed & Cost.

Speed claims are not testable statically, so these tests assert on the
*mechanisms* that produce the speedup, plus the correctness traps that each
one introduces.
"""

import pytest

from labcheck import gh_available, latest_runs, load_workflow, tool_available
from labcheck.shell import run

WORKFLOW = ".github/workflows/lab-02-ci.yml"


@pytest.fixture(scope="module")
def workflow():
    return load_workflow(WORKFLOW)


def commands(workflow, job_id):
    return "\n".join(step.run for step in workflow.steps(job_id) if step.run)


def step_with(workflow, job_id, action_prefix):
    for step in workflow.steps(job_id):
        if step.uses and step.uses.startswith(action_prefix):
            return step
    return None


# ---------------------------------------------------------------------------
# TODO(lab-02-a) -- concurrency
# ---------------------------------------------------------------------------


def test_concurrency_group_declared(workflow):
    assert "concurrency" in workflow.data, (
        "TODO(lab-02-a): no top-level `concurrency:` block. Every superseded push\n"
        "  runs to completion and bills you for a result nobody will read."
    )


def test_concurrency_cancels_in_progress(workflow):
    block = workflow.data.get("concurrency") or {}
    assert isinstance(block, dict) and block.get("cancel-in-progress") is True, (
        "TODO(lab-02-a): set `cancel-in-progress: true`. Without it the group only\n"
        "  queues superseded runs -- you still pay for all of them, just later."
    )


def test_concurrency_group_is_per_branch(workflow):
    group = str((workflow.data.get("concurrency") or {}).get("group", ""))
    assert "github.ref" in group or "github.head_ref" in group, (
        "TODO(lab-02-a): the concurrency group does not vary by branch, so a push to\n"
        f"  one branch cancels an unrelated branch's run.\n  group: {group!r}"
    )


def test_main_runs_are_not_cancelled(workflow):
    """Cancelling a push to main destroys the record of what was released."""
    group = str((workflow.data.get("concurrency") or {}).get("group", ""))
    assert "run_id" in group or "run_number" in group, (
        "TODO(lab-02-a): runs on `main` share a group key with each other, so a quick\n"
        "  second merge cancels the first one's run -- and that run was the only record\n"
        "  that the released commit passed.\n"
        "  Make the key unique on main, e.g.:\n"
        "    github.ref == 'refs/heads/main' && github.run_id || github.ref"
    )


# ---------------------------------------------------------------------------
# TODO(lab-02-b) -- caching
# ---------------------------------------------------------------------------


def test_uv_cache_enabled(workflow):
    step = step_with(workflow, "api", "astral-sh/setup-uv")
    if step is None:
        pytest.fail("TODO(lab-02-b): the api job no longer sets up uv")
    assert step.raw.get("with", {}).get("enable-cache") in (True, "true"), (
        "TODO(lab-02-b): setup-uv is not caching. Add `enable-cache: true` under `with:`."
    )


def test_uv_cache_keyed_on_the_lock_file(workflow):
    step = step_with(workflow, "api", "astral-sh/setup-uv")
    glob = str((step.raw.get("with") or {}).get("cache-dependency-glob", "")) if step else ""
    assert "uv.lock" in glob, (
        "TODO(lab-02-b): key the uv cache on app/api/uv.lock via `cache-dependency-glob`.\n"
        "  A cache keyed on something that changes every commit never hits; one keyed on\n"
        "  something that never changes serves you stale dependencies forever."
    )


def test_npm_cache_enabled(workflow):
    step = step_with(workflow, "worker", "actions/setup-node")
    if step is None:
        pytest.fail("TODO(lab-02-b): the worker job no longer sets up Node")
    assert (step.raw.get("with") or {}).get("cache") == "npm", (
        "TODO(lab-02-b): setup-node is not caching. Add `cache: npm` under `with:`."
    )


def test_npm_cache_points_at_the_service_lock_file(workflow):
    """The default lookup is the repository root, which has no lock file here."""
    step = step_with(workflow, "worker", "actions/setup-node")
    path = str((step.raw.get("with") or {}).get("cache-dependency-path", "")) if step else ""
    assert "app/worker" in path, (
        "TODO(lab-02-b): set `cache-dependency-path: app/worker/package-lock.json`.\n"
        "  Without it setup-node looks in the repository root, finds no lock file, and\n"
        "  caches nothing -- while the step still shows green."
    )


# ---------------------------------------------------------------------------
# TODO(lab-02-c) -- matrix
# ---------------------------------------------------------------------------


def test_api_job_uses_a_matrix(workflow):
    strategy = workflow.job("api").get("strategy") or {}
    versions = (strategy.get("matrix") or {}).get("python-version")
    assert versions, (
        "TODO(lab-02-c): the api job has no `strategy.matrix.python-version`."
    )
    assert len(versions) >= 3, (
        f"TODO(lab-02-c): test at least three Python versions, found {versions}."
    )


def test_matrix_does_not_fail_fast(workflow):
    strategy = workflow.job("api").get("strategy") or {}
    assert strategy.get("fail-fast") is False, (
        "TODO(lab-02-c): set `fail-fast: false`. The default cancels the remaining legs\n"
        "  on the first failure, which hides whether the break is version-specific -- the\n"
        "  only question a version matrix exists to answer."
    )


def test_matrix_version_is_actually_used(workflow):
    """A matrix that no step references runs N identical jobs at N times the cost."""
    step = step_with(workflow, "api", "astral-sh/setup-uv")
    used = str((step.raw.get("with") or {}).get("python-version", "")) if step else ""
    assert "matrix.python-version" in used, (
        "TODO(lab-02-c): nothing passes `matrix.python-version` to setup-uv, so all\n"
        "  three legs test the same interpreter -- three times the cost, one version's\n"
        "  worth of information."
    )


def test_matrix_legs_are_distinguishable(workflow):
    name = str(workflow.job("api").get("name", ""))
    assert "matrix.python-version" in name, (
        "TODO(lab-02-c): include the matrix value in the job `name:`, otherwise the\n"
        "  checks list shows three identical entries and you cannot tell which failed."
    )


# ---------------------------------------------------------------------------
# TODO(lab-02-d) -- path filters
# ---------------------------------------------------------------------------


def test_changes_job_exists(workflow):
    assert "changes" in workflow.jobs, (
        "TODO(lab-02-d): add a `changes` job that detects which services a PR touched."
    )


def test_changes_job_exposes_outputs(workflow):
    outputs = workflow.job("changes").get("outputs") or {}
    assert {"api", "worker"} <= set(outputs), (
        "TODO(lab-02-d): the changes job must expose `api` and `worker` outputs.\n"
        f"  found: {sorted(outputs)}"
    )


@pytest.mark.parametrize("job_id", ["api", "worker"])
def test_service_jobs_are_gated_on_changes(workflow, job_id):
    job = workflow.job(job_id)
    condition = str(job.get("if", ""))
    assert "changes" in workflow.needs(job_id), (
        f"TODO(lab-02-d): the {job_id} job does not declare `needs: changes`, so it\n"
        "  cannot read the filter outputs."
    )
    assert f"needs.changes.outputs.{job_id}" in condition, (
        f"TODO(lab-02-d): the {job_id} job has no `if:` gating it on the filter output.\n"
        f"  current if: {condition!r}"
    )


def test_workflow_changes_retrigger_everything(workflow):
    """Editing the pipeline must rebuild both services, or you never test the change."""
    filters = ""
    for step in workflow.steps("changes"):
        if step.uses and "paths-filter" in step.uses:
            filters = str((step.raw.get("with") or {}).get("filters", ""))
    assert filters.count("lab-02-ci.yml") >= 2, (
        "TODO(lab-02-d): both filters must also match this workflow file. Otherwise a PR\n"
        "  that only edits the pipeline skips every job, and the change ships untested."
    )


# ---------------------------------------------------------------------------
# TODO(lab-02-e) -- artifacts
# ---------------------------------------------------------------------------


def test_coverage_is_produced(workflow):
    assert "--cov" in commands(workflow, "api"), (
        "TODO(lab-02-e): the api job never generates a coverage report."
    )


def test_coverage_is_uploaded(workflow):
    step = step_with(workflow, "api", "actions/upload-artifact")
    assert step is not None, (
        "TODO(lab-02-e): nothing uploads the coverage report, so it dies with the runner."
    )


def test_artifact_name_is_unique_per_matrix_leg(workflow):
    step = step_with(workflow, "api", "actions/upload-artifact")
    name = str((step.raw.get("with") or {}).get("name", "")) if step else ""
    assert "matrix.python-version" in name, (
        "TODO(lab-02-e): the artifact name is the same in every matrix leg. Uploading\n"
        "  the same name from three jobs is an error on upload-artifact@v4 -- include\n"
        f"  the matrix value.\n  name: {name!r}"
    )


def test_artifact_retention_is_short(workflow):
    step = step_with(workflow, "api", "actions/upload-artifact")
    retention = (step.raw.get("with") or {}).get("retention-days") if step else None
    assert retention is not None, (
        "TODO(lab-02-e): set `retention-days`. The default is 90 days of storage for a\n"
        "  file you look at for ten minutes."
    )
    assert int(retention) <= 30, (
        f"TODO(lab-02-e): retention-days={retention} is longer than this file is useful for."
    )


# ---------------------------------------------------------------------------
# TODO(lab-02-f) -- the aggregate required check
# ---------------------------------------------------------------------------


def test_aggregate_job_exists(workflow):
    assert "ci-passed" in workflow.jobs, (
        "TODO(lab-02-f): add a `ci-passed` job. With path filters in place, marking the\n"
        "  individual jobs as required blocks any PR that skips one of them."
    )


def test_aggregate_job_depends_on_both_services(workflow):
    assert {"api", "worker"} <= set(workflow.needs("ci-passed")), (
        "TODO(lab-02-f): ci-passed must declare `needs: [api, worker]`.\n"
        f"  found: {workflow.needs('ci-passed')}"
    )


def test_aggregate_job_runs_even_when_dependencies_are_skipped(workflow):
    condition = str(workflow.job("ci-passed").get("if", ""))
    assert "always()" in condition, (
        "TODO(lab-02-f): without `if: always()` the aggregate job is itself skipped when\n"
        "  a dependency is skipped -- which is the exact situation it exists to handle."
    )


def test_aggregate_job_inspects_dependency_results(workflow):
    """`if: always()` alone makes the job pass unconditionally -- the worst outcome."""
    body = commands(workflow, "ci-passed") + str(workflow.job("ci-passed"))
    assert "needs.api.result" in body and "needs.worker.result" in body, (
        "TODO(lab-02-f): ci-passed runs but never reads `needs.<job>.result`, so it\n"
        "  reports success even when both services failed. `if: always()` without a\n"
        "  result check is a green tick that means nothing."
    )


def test_aggregate_job_distinguishes_skipped_from_failed(workflow):
    body = commands(workflow, "ci-passed")
    assert "skipped" in body, (
        "TODO(lab-02-f): ci-passed must treat `skipped` as acceptable and `failure` and\n"
        "  `cancelled` as not. Nothing in the job mentions `skipped`."
    )


# ---------------------------------------------------------------------------
# Tool and live checks
# ---------------------------------------------------------------------------


def test_actionlint_is_clean():
    if not tool_available("actionlint"):
        pytest.skip("actionlint not installed (brew install actionlint)")
    result = run(["actionlint", WORKFLOW])
    assert result.ok, f"actionlint found problems in {WORKFLOW}:\n{result.output}"


@pytest.mark.live_github
def test_workflow_has_actually_run():
    if not gh_available():
        pytest.skip("gh CLI not installed or not authenticated")

    runs = latest_runs("lab-02-ci.yml")
    if not runs:
        pytest.skip("this workflow has never run -- push the branch and open a pull request")

    successes = [r for r in runs if r.get("conclusion") == "success"]
    assert successes, (
        "the workflow has run but never succeeded. Most recent runs:\n"
        + "\n".join(f"  {r.get('conclusion')}  {r.get('displayTitle')}  {r.get('url')}" for r in runs[:5])
    )
