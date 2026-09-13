"""Lab 03 verifier -- Abstraction, Service Containers & the Local Loop.

Three files under test, plus act configuration:
  .github/actions/setup-service/action.yml   the composite action
  .github/workflows/reusable-service-ci.yml  the reusable workflow
  .github/workflows/lab-03-ci.yml            the caller
  .actrc                                     the local loop
"""

import json
import re

import pytest
import yaml

from labcheck import (
    gh_available,
    latest_runs,
    load_workflow,
    repo_root,
    require_file,
    tool_available,
)
from labcheck.shell import run

ACTION = ".github/actions/setup-service/action.yml"
REUSABLE = ".github/workflows/reusable-service-ci.yml"
CALLER = ".github/workflows/lab-03-ci.yml"
ACTRC = ".actrc"

SERVICES = ("api", "worker")


@pytest.fixture(scope="module")
def action():
    path = require_file(ACTION)
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        pytest.fail(f"{ACTION} did not parse to a mapping")
    return data


@pytest.fixture(scope="module")
def reusable():
    return load_workflow(REUSABLE)


@pytest.fixture(scope="module")
def caller():
    return load_workflow(CALLER)


def action_steps(action):
    return (action.get("runs") or {}).get("steps") or []


# ---------------------------------------------------------------------------
# TODO(lab-03-a) -- the composite action
# ---------------------------------------------------------------------------


def test_action_is_composite(action):
    assert (action.get("runs") or {}).get("using") == "composite", (
        f"{ACTION} is not a composite action (`runs.using` must be `composite`)."
    )


def test_action_declares_inputs(action):
    inputs = action.get("inputs") or {}
    assert {"service", "version"} <= set(inputs), (
        "TODO(lab-03-a1): the action must declare `service` and `version` inputs.\n"
        f"  found: {sorted(inputs)}"
    )


def test_action_service_input_is_required(action):
    service = (action.get("inputs") or {}).get("service") or {}
    assert service.get("required") is True, (
        "TODO(lab-03-a1): `service` must be `required: true`. Without it the action\n"
        "  silently sets up nothing when a caller forgets to pass it."
    )


def test_action_inputs_have_no_type(action):
    """Composite action inputs are always strings -- `type:` is a workflow_call concept."""
    typed = [
        name for name, spec in (action.get("inputs") or {}).items() if isinstance(spec, dict) and "type" in spec
    ]
    assert not typed, (
        f"TODO(lab-03-a1): composite action inputs cannot be typed: {typed}\n"
        "  Only `workflow_call` inputs take a `type:`. This is why the reusable workflow\n"
        "  has to pass its matrix as a JSON string."
    )


@pytest.mark.parametrize(
    ("service", "setup_action"),
    [("api", "astral-sh/setup-uv"), ("worker", "actions/setup-node")],
)
def test_action_sets_up_each_service(action, service, setup_action):
    steps = [s for s in action_steps(action) if str(s.get("uses", "")).startswith(setup_action)]
    assert steps, (
        f"TODO(lab-03-a2): the action never calls {setup_action}, so the {service}\n"
        "  service has no toolchain."
    )
    condition = str(steps[0].get("if", ""))
    assert f"'{service}'" in condition or f'"{service}"' in condition, (
        f"TODO(lab-03-a2): the {setup_action} step is not gated on the service input.\n"
        f"  Without an `if:`, setting up the worker also installs Python.\n"
        f"  current if: {condition!r}"
    )


def test_action_passes_version_through(action):
    body = yaml.safe_dump(action)
    assert "inputs.version" in body, (
        "TODO(lab-03-a2): nothing reads the `version` input, so every caller gets the\n"
        "  same runtime and the matrix in the reusable workflow tests one thing N times."
    )


def test_every_run_step_declares_a_shell(action):
    """The single most common composite-action error."""
    missing = [
        s.get("name") or s.get("run", "")[:40]
        for s in action_steps(action)
        if "run" in s and "shell" not in s
    ]
    assert not missing, (
        "TODO(lab-03-a3): these `run:` steps have no `shell:`, which is required in a\n"
        f"  composite action (workflows default it for you; actions do not): {missing}"
    )


def test_action_installs_via_the_uniform_target(action):
    """One step, both services -- because every service exposes `make install`."""
    runs = "\n".join(str(s.get("run", "")) for s in action_steps(action))
    assert "make install" in runs, (
        "TODO(lab-03-a3): the action should install dependencies with `make install`.\n"
        "  Every service exposes the same targets, which is what lets one step cover both."
    )


# ---------------------------------------------------------------------------
# TODO(lab-03-b) -- the reusable workflow's interface
# ---------------------------------------------------------------------------


def test_reusable_workflow_is_callable(reusable):
    assert "workflow_call" in reusable.triggers, (
        "TODO(lab-03-b): the workflow is not callable. Its `on:` block must contain\n"
        f"  `workflow_call`.\n  current triggers: {sorted(str(k) for k in reusable.triggers)}"
    )


def test_reusable_workflow_declares_inputs(reusable):
    inputs = (reusable.triggers.get("workflow_call") or {}).get("inputs") or {}
    assert {"service", "versions", "run-integration-tests"} <= set(inputs), (
        "TODO(lab-03-b): the workflow must declare `service`, `versions` and\n"
        f"  `run-integration-tests` inputs.\n  found: {sorted(inputs)}"
    )


@pytest.mark.parametrize(
    ("name", "expected_type"),
    [("service", "string"), ("versions", "string"), ("run-integration-tests", "boolean")],
)
def test_workflow_call_inputs_are_typed(reusable, name, expected_type):
    inputs = (reusable.triggers.get("workflow_call") or {}).get("inputs") or {}
    spec = inputs.get(name) or {}
    assert spec.get("type") == expected_type, (
        f"TODO(lab-03-b): input `{name}` must declare `type: {expected_type}`.\n"
        "  `type` is mandatory on workflow_call inputs -- the workflow will not parse\n"
        f"  without it.\n  found: {spec.get('type')!r}"
    )


def test_workflow_service_input_is_required(reusable):
    inputs = (reusable.triggers.get("workflow_call") or {}).get("inputs") or {}
    assert (inputs.get("service") or {}).get("required") is True, (
        "TODO(lab-03-b): `service` must be required. Everything else has a sane default."
    )


def test_reusable_workflow_declares_an_output(reusable):
    outputs = (reusable.triggers.get("workflow_call") or {}).get("outputs") or {}
    assert "coverage-artifact" in outputs, (
        "TODO(lab-03-b): declare a `coverage-artifact` output. A reusable workflow that\n"
        "  returns nothing is a script; one with outputs is an interface."
    )


def test_workflow_output_is_wired_to_a_job(reusable):
    outputs = (reusable.triggers.get("workflow_call") or {}).get("outputs") or {}
    value = str((outputs.get("coverage-artifact") or {}).get("value", ""))
    assert "jobs." in value and "outputs." in value, (
        "TODO(lab-03-b): the output's `value:` must read a job output, e.g.\n"
        "  ${{ jobs.test.outputs.coverage-artifact }}\n"
        f"  found: {value!r}"
    )


def test_job_output_does_not_depend_on_the_matrix(reusable):
    """A per-leg job output is last-writer-wins with no defined ordering."""
    value = str((reusable.job("test").get("outputs") or {}).get("coverage-artifact", ""))
    assert value, "TODO(lab-03-b): the `test` job declares no `coverage-artifact` output."
    assert "matrix." not in value, (
        "TODO(lab-03-b): this job output varies per matrix leg, so every leg writes it and\n"
        "  the last writer wins -- with no defined ordering between legs.\n"
        f"  found: {value!r}"
    )


# ---------------------------------------------------------------------------
# TODO(lab-03-c) -- matrix from an input
# ---------------------------------------------------------------------------


def test_matrix_is_built_from_the_input(reusable):
    matrix = ((reusable.job("test").get("strategy") or {}).get("matrix") or {})
    values = str(matrix.get("version", ""))
    assert "fromJSON" in values and "inputs.versions" in values, (
        "TODO(lab-03-c): the matrix must come from the caller's input. A matrix cannot be\n"
        "  passed directly -- inputs are only strings, booleans or numbers -- so the caller\n"
        "  passes JSON and you unpack it with fromJSON(inputs.versions).\n"
        f"  found: {values!r}"
    )


def test_matrix_does_not_fail_fast(reusable):
    strategy = reusable.job("test").get("strategy") or {}
    assert strategy.get("fail-fast") is False, (
        "TODO(lab-03-c): set `fail-fast: false`, as in Lab 02."
    )


def test_matrix_legs_are_distinguishable(reusable):
    name = str(reusable.job("test").get("name", ""))
    assert "matrix.version" in name, (
        "TODO(lab-03-c): put the matrix value in the job `name:` or the caller's checks\n"
        "  list shows several identical rows."
    )


def test_reusable_workflow_calls_the_composite_action(reusable):
    refs = [s.uses for s in reusable.steps() if s.uses]
    assert any("./.github/actions/setup-service" in str(r) for r in refs), (
        "TODO(lab-03-a2): the reusable workflow never calls the composite action.\n"
        "  A local action is referenced by path from the repository root, and the repo\n"
        f"  must be checked out first.\n  uses: refs found: {refs}"
    )


def test_reusable_workflow_is_service_agnostic(reusable):
    """It must not know what language a service is written in."""
    body = yaml.safe_dump(reusable.data)
    leaked = [t for t in ("uv run", "npm run", "npm ci", "pytest", "vitest", "ruff") if t in body]
    assert not leaked, (
        "TODO(lab-03-b): the reusable workflow references language-specific commands:\n"
        f"    {leaked}\n"
        "  It should call `make lint` / `make test` and let each service's Makefile decide\n"
        "  what those mean. A workflow that knows about Python cannot build the worker."
    )


# ---------------------------------------------------------------------------
# TODO(lab-03-d) -- the caller
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("job_id", SERVICES)
def test_caller_delegates_to_the_reusable_workflow(caller, job_id):
    job = caller.job(job_id)
    assert job, f"TODO(lab-03-d1): the caller has no `{job_id}` job."
    assert str(job.get("uses", "")).endswith("reusable-service-ci.yml"), (
        f"TODO(lab-03-d1): the `{job_id}` job does not call the reusable workflow.\n"
        f"  expected: uses: ./.github/workflows/reusable-service-ci.yml\n"
        f"  found:    {job.get('uses')!r}"
    )


@pytest.mark.parametrize("job_id", SERVICES)
def test_calling_job_has_no_steps_or_runner(caller, job_id):
    job = caller.job(job_id)
    illegal = [k for k in ("steps", "runs-on", "timeout-minutes") if k in job]
    assert not illegal, (
        f"TODO(lab-03-d1): the `{job_id}` job calls a reusable workflow and also declares\n"
        f"  {illegal}. That is not allowed -- the called workflow owns all of it, and the\n"
        "  workflow will not parse."
    )


@pytest.mark.parametrize("job_id", SERVICES)
def test_calling_job_keeps_its_gating(caller, job_id):
    assert "changes" in caller.needs(job_id), (
        f"TODO(lab-03-d1): the `{job_id}` job lost its `needs: changes`. Calling a reusable\n"
        "  workflow does not change how a job is scheduled."
    )
    assert f"needs.changes.outputs.{job_id}" in str(caller.job(job_id).get("if", "")), (
        f"TODO(lab-03-d1): the `{job_id}` job lost its path-filter `if:`."
    )


def test_api_is_matrixed_and_runs_integration_tests(caller):
    with_block = caller.job("api").get("with") or {}
    assert with_block.get("service") == "api", "TODO(lab-03-d1): api job must pass service: api"

    try:
        versions = json.loads(str(with_block.get("versions", "[]")))
    except json.JSONDecodeError:
        pytest.fail(
            f"TODO(lab-03-d1): `versions` is not valid JSON: {with_block.get('versions')!r}\n"
            "  It is passed as a string and parsed with fromJSON in the reusable workflow."
        )
    assert len(versions) >= 3, f"TODO(lab-03-d1): api should test three Python versions, got {versions}"
    assert with_block.get("run-integration-tests") is True, (
        "TODO(lab-03-d1): the api job must pass `run-integration-tests: true` -- it is the\n"
        "  only service with an external dependency."
    )


def test_worker_is_matrixed_over_node_versions(caller):
    with_block = caller.job("worker").get("with") or {}
    assert with_block.get("service") == "worker"
    versions = json.loads(str(with_block.get("versions", "[]")))
    assert len(versions) >= 2, (
        f"TODO(lab-03-d1): the worker should test more than one Node version, got {versions}"
    )


def test_caller_consumes_the_reusable_workflow_output(caller):
    body = yaml.safe_dump(caller.data)
    assert re.search(r"needs\.(api|worker)\.outputs\.coverage-artifact", body), (
        "TODO(lab-03-b): nothing reads the reusable workflow's output, so the interface is\n"
        "  unproven. Read it in ci-passed via needs.api.outputs.coverage-artifact."
    )


def test_shared_pipeline_files_retrigger_both_services(caller):
    filters = ""
    for step in caller.steps("changes"):
        if step.uses and "paths-filter" in step.uses:
            filters = str((step.raw.get("with") or {}).get("filters", ""))
    assert filters, "TODO(lab-03-d2): the changes job has no paths-filter step."

    parsed = yaml.safe_load(filters) or {}

    def flatten(value):
        if isinstance(value, list):
            return [x for v in value for x in flatten(v)]
        return [value]

    for service in SERVICES:
        patterns = flatten(parsed.get(service, []))
        for shared in (CALLER, REUSABLE, ACTION):
            assert shared in patterns, (
                f"TODO(lab-03-d2): the `{service}` filter does not match `{shared}`.\n"
                "  All three pipeline files affect both services -- a PR editing one of them\n"
                "  would skip every job and ship the change untested.\n"
                f"  current patterns: {patterns}"
            )


# ---------------------------------------------------------------------------
# TODO(lab-03-e) -- service containers
# ---------------------------------------------------------------------------


def test_integration_job_exists(reusable):
    assert "integration" in reusable.jobs, (
        "TODO(lab-03-e): the reusable workflow has no `integration` job."
    )


def test_integration_job_is_opt_in(reusable):
    condition = str(reusable.job("integration").get("if", ""))
    assert "run-integration-tests" in condition, (
        "TODO(lab-03-e): the integration job must be gated on `inputs.run-integration-tests`,\n"
        "  or the worker pays for a DynamoDB it has no use for."
    )


def test_service_container_declared(reusable):
    services = reusable.job("integration").get("services") or {}
    assert services, (
        "TODO(lab-03-e): the integration job declares no `services:` block, so there is no\n"
        "  DynamoDB for the tests to talk to."
    )
    images = [str((spec or {}).get("image", "")) for spec in services.values()]
    assert any("dynamodb-local" in image for image in images), (
        f"TODO(lab-03-e): no dynamodb-local service container found. images: {images}"
    )


def test_service_container_image_is_pinned(reusable):
    """`latest` on a service container makes the test suite's dependency drift silently."""
    services = reusable.job("integration").get("services") or {}
    unpinned = [
        str((spec or {}).get("image", ""))
        for spec in services.values()
        if ":" not in str((spec or {}).get("image", "")) or str((spec or {}).get("image", "")).endswith(":latest")
    ]
    assert not unpinned, (
        f"TODO(lab-03-e): pin the service container image to a version: {unpinned}\n"
        "  An unpinned dependency turns an upstream release into a failing build on a\n"
        "  commit that changed nothing."
    )


def test_service_container_port_is_mapped(reusable):
    services = reusable.job("integration").get("services") or {}
    ports = [p for spec in services.values() for p in ((spec or {}).get("ports") or [])]
    assert any("8000" in str(p) for p in ports), (
        "TODO(lab-03-e): map the container's port 8000 to the host. Without `ports:` the\n"
        "  container is on the Docker network but unreachable from a job running directly\n"
        f"  on the runner.\n  found: {ports}"
    )


def test_job_waits_for_the_dependency(reusable):
    """The image ships no health tool, so --health-cmd cannot work and waiting is your job."""
    body = "\n".join(s.run for s in reusable.steps("integration") if s.run)
    services = reusable.job("integration").get("services") or {}
    has_health_cmd = any("--health-cmd" in str((spec or {}).get("options", "")) for spec in services.values())
    waits = "localhost:8000" in body and ("sleep" in body or "until" in body or "seq" in body)
    assert has_health_cmd or waits, (
        "TODO(lab-03-e): nothing waits for DynamoDB to be reachable, so the tests race the\n"
        "  container's startup and fail intermittently.\n"
        "  amazon/dynamodb-local ships no curl or wget, so `--health-cmd` has nothing to run\n"
        "  inside the container -- add a wait loop against http://localhost:8000 instead."
    )


def test_integration_step_points_the_app_at_the_container(reusable):
    envs = {}
    for step in reusable.steps("integration"):
        envs.update(step.raw.get("env") or {})
    assert "DYNAMODB_ENDPOINT" in envs, (
        "TODO(lab-03-e): set DYNAMODB_ENDPOINT on the test step. That one variable is what\n"
        "  lets identical application code talk to a service container in CI and a real\n"
        "  table in AWS."
    )
    assert "8000" in str(envs["DYNAMODB_ENDPOINT"])


def test_integration_job_uses_the_uniform_target(reusable):
    body = "\n".join(s.run for s in reusable.steps("integration") if s.run)
    assert "make test-integration" in body, (
        "TODO(lab-03-e): run the suite with `make test-integration`, like every other\n"
        "  service-level command in this pipeline."
    )


# ---------------------------------------------------------------------------
# TODO(lab-03-f) -- the local loop
# ---------------------------------------------------------------------------


def test_actrc_maps_the_runner_image():
    text = require_file(ACTRC).read_text()
    assert re.search(r"^-P\s+ubuntu-latest=\S+", text, re.MULTILINE), (
        "TODO(lab-03-f): .actrc does not map `ubuntu-latest` to a runner image. act's\n"
        "  default image is a near-empty stub and almost nothing will run on it."
    )


def test_actrc_sets_container_architecture():
    text = require_file(ACTRC).read_text()
    assert "--container-architecture" in text, (
        "TODO(lab-03-f): set `--container-architecture linux/amd64`. On Apple Silicon the\n"
        "  default picks arm64 images, which many actions do not publish."
    )


def test_actrc_configures_an_artifact_server():
    text = require_file(ACTRC).read_text()
    assert "--artifact-server-path" in text, (
        "TODO(lab-03-f): set `--artifact-server-path`, or any step using upload-artifact\n"
        "  fails outright rather than being skipped."
    )


def test_make_ci_local_target_exists():
    makefile = (repo_root() / "Makefile").read_text()
    assert re.search(r"^ci-local:", makefile, re.MULTILINE), (
        "TODO(lab-03-f): the Makefile has no `ci-local` target."
    )


# ---------------------------------------------------------------------------
# Tool and live checks
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", [CALLER, REUSABLE])
def test_actionlint_is_clean(path):
    if not tool_available("actionlint"):
        pytest.skip("actionlint not installed (brew install actionlint)")
    result = run(["actionlint", path])
    assert result.ok, f"actionlint found problems in {path}:\n{result.output}"


@pytest.mark.live_github
def test_workflow_has_actually_run():
    if not gh_available():
        pytest.skip("gh CLI not installed or not authenticated")

    runs = latest_runs("lab-03-ci.yml")
    if not runs:
        pytest.skip("this workflow has never run -- push the branch and open a pull request")

    successes = [r for r in runs if r.get("conclusion") == "success"]
    assert successes, (
        "the workflow has run but never succeeded. Most recent runs:\n"
        + "\n".join(f"  {r.get('conclusion')}  {r.get('displayTitle')}  {r.get('url')}" for r in runs[:5])
    )
