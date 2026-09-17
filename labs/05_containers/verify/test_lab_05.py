"""Lab 05 verifier -- Building & Publishing Containers.

Every failure names the TODO it corresponds to.
"""

import re

import pytest

from labcheck import gh_available, latest_runs, load_workflow
from labcheck.paths import repo_root
from labcheck.workflow import unpinned_third_party_actions

WORKFLOW = ".github/workflows/publish.yml"
SERVICES = ("api", "worker")


@pytest.fixture(scope="module")
def workflow():
    return load_workflow(WORKFLOW)


@pytest.fixture(scope="module")
def image_job(workflow):
    if "image" not in workflow.jobs:
        pytest.fail("the `image` job is missing -- run `make lab LAB=05`.")
    return workflow.job("image")


def _steps_text(workflow):
    parts = []
    for step in workflow.steps("image"):
        parts.append(step.uses or "")
        parts.append(step.run or "")
        parts.append(str(step.raw.get("with") or ""))
    return "\n".join(parts)


def _dockerfile(service: str) -> str:
    return (repo_root() / f"app/{service}/Dockerfile").read_text()


# ---------------------------------------------------------------------------
# TODO(lab-05-a) -- tags, cache, push
# ---------------------------------------------------------------------------


def test_tags_are_computed(workflow):
    assert "metadata-action" in _steps_text(workflow), (
        "TODO(lab-05-a): nothing computes tags. docker/metadata-action turns the event\n"
        "  into a tag list so the workflow does not hand-roll them."
    )


def test_images_are_tagged_by_commit(workflow):
    text = _steps_text(workflow)
    assert "type=sha" in text, (
        "TODO(lab-05-a): no commit-SHA tag. That is the tag you would deploy -- it is\n"
        "  the only one that cannot come to mean something else later."
    )


def test_latest_is_not_published(workflow):
    text = _steps_text(workflow)
    assert not re.search(r"type=raw,value=latest|tags:.*\blatest\b", text), (
        "TODO(lab-05-a): a `latest` tag is being published. A mutable tag cannot tell\n"
        "  you what is running -- ask it twice and it may answer differently."
    )


def test_layer_cache_is_configured(workflow):
    text = _steps_text(workflow)
    assert "cache-from" in text, (
        "TODO(lab-05-a): no cache backend. Both Dockerfiles put dependencies before\n"
        "  source so a source-only change reuses the dependency layer -- but without a\n"
        "  cache that ordering buys nothing between runs."
    )


def test_push_is_skipped_on_pull_requests(workflow):
    push = next(
        (s for s in workflow.steps("image")
         if "build-push-action" in (s.uses or "") and str(s.raw.get("with", {})).find("push") >= 0),
        None,
    )
    assert push is not None, (
        "TODO(lab-05-a): nothing pushes the image."
    )
    condition = str(push.raw.get("if", ""))
    assert "pull_request" in condition, (
        "TODO(lab-05-a): the push step has no `if:`, so a pull request publishes an\n"
        "  image. A pull request should build and scan; only main should publish."
    )


def test_sbom_is_attached(workflow):
    assert "sbom" in _steps_text(workflow), (
        "TODO(lab-05-a): no SBOM. During an incident the question is 'which of our\n"
        "  images contain this package', and without one the answer is a guess."
    )


# ---------------------------------------------------------------------------
# TODO(lab-05-b) -- permissions and registry login
# ---------------------------------------------------------------------------


def test_job_can_write_packages(image_job):
    perms = image_job.get("permissions") or {}
    assert perms.get("packages") == "write", (
        "TODO(lab-05-b): the job cannot push to GHCR without `packages: write`.\n"
        f"  found: {perms}"
    )


def test_job_can_sign(image_job):
    perms = image_job.get("permissions") or {}
    missing = [p for p in ("id-token", "attestations") if perms.get(p) != "write"]
    assert not missing, (
        "TODO(lab-05-b): attestation signing needs `id-token: write` and\n"
        f"  `attestations: write`. missing: {missing}"
    )


def test_registry_login_happens(workflow):
    login = next((s for s in workflow.steps("image") if "login-action" in (s.uses or "")), None)
    assert login is not None, (
        "TODO(lab-05-b): no login step. buildx falls back to an anonymous token and GHCR\n"
        "  answers 403 -- after the build and the scan have already run. The permission\n"
        "  above grants the right; it does not present a credential."
    )


def test_login_precedes_push(workflow):
    steps = workflow.steps("image")
    login = next((i for i, s in enumerate(steps) if "login-action" in (s.uses or "")), None)
    push = next(
        (i for i, s in enumerate(steps)
         if "build-push-action" in (s.uses or "") and "push" in str(s.raw.get("with") or "")),
        None,
    )
    if login is None or push is None:
        pytest.skip("login or push step missing -- see TODO(lab-05-a)/(lab-05-b)")
    assert login < push, (
        "TODO(lab-05-b): the login step comes after the push step."
    )


# ---------------------------------------------------------------------------
# TODO(lab-05-c) -- the scan is a gate, not a report
# ---------------------------------------------------------------------------


def test_image_is_scanned(workflow):
    assert "trivy" in _steps_text(workflow).lower(), (
        "TODO(lab-05-c): nothing scans the image."
    )


def test_scan_fails_the_build(workflow):
    scan = next((s for s in workflow.steps("image") if "trivy" in (s.uses or "").lower()), None)
    if scan is None:
        pytest.skip("no scan step yet -- see TODO(lab-05-c)")
    with_block = scan.raw.get("with") or {}
    assert str(with_block.get("exit-code", "0")) == "1", (
        "TODO(lab-05-c): the scan reports but does not fail the job. A scan that cannot\n"
        "  fail is the `|| true` of Lab 01 wearing a more sophisticated hat."
    )
    severity = str(with_block.get("severity", ""))
    assert "HIGH" in severity and "CRITICAL" in severity, (
        f"TODO(lab-05-c): severity is {severity or 'unset'}; the gate should cover HIGH\n"
        "  and CRITICAL."
    )


def test_unfixable_findings_are_ignored(workflow):
    scan = next((s for s in workflow.steps("image") if "trivy" in (s.uses or "").lower()), None)
    if scan is None:
        pytest.skip("no scan step yet -- see TODO(lab-05-c)")
    with_block = scan.raw.get("with") or {}
    assert str(with_block.get("ignore-unfixed", "")).lower() == "true", (
        "TODO(lab-05-c): `ignore-unfixed` is not set. A vulnerability with no available\n"
        "  fix cannot be acted on, and failing on it teaches people to add blanket\n"
        "  ignore files -- which is worse than not scanning."
    )


def test_scan_precedes_push(workflow):
    steps = workflow.steps("image")
    scan = next((i for i, s in enumerate(steps) if "trivy" in (s.uses or "").lower()), None)
    push = next(
        (i for i, s in enumerate(steps)
         if "build-push-action" in (s.uses or "") and "push" in str(s.raw.get("with") or "")),
        None,
    )
    if scan is None or push is None:
        pytest.skip("scan or push step missing")
    assert scan < push, (
        "TODO(lab-05-c): the scan runs after the push. That is a report, not a gate --\n"
        "  by the time it fails, the image is already in the registry."
    )


# ---------------------------------------------------------------------------
# TODO(lab-05-d) -- what the gate found
# ---------------------------------------------------------------------------


def test_api_image_applies_security_updates():
    text = _dockerfile("api")
    assert "apt-get upgrade" in text, (
        "TODO(lab-05-d): app/api/Dockerfile never applies the distribution's security\n"
        "  updates, so the image carries whatever the base image shipped with. A base\n"
        "  image tag is a snapshot of someone else's patching cadence."
    )


def test_worker_image_does_not_ship_a_package_manager():
    text = _dockerfile("worker")
    removes_npm = "rm -rf /usr/local/lib/node_modules/npm" in text or "npm uninstall -g npm" in text
    assert removes_npm, (
        "TODO(lab-05-d): app/worker/Dockerfile ships npm in the runtime image. npm's own\n"
        "  dependency tree (pacote, brace-expansion, ip-address) counts as vulnerabilities\n"
        "  even though the entrypoint is `node` and nothing runs npm again."
    )


@pytest.mark.parametrize("service", SERVICES)
def test_images_run_as_a_non_root_user(service):
    text = _dockerfile(service)
    assert re.search(r"^USER\s+(?!root)\S+", text, re.MULTILINE), (
        f"TODO(lab-05-d): app/{service}/Dockerfile does not drop to a non-root user."
    )


# ---------------------------------------------------------------------------
# TODO(lab-05-e) -- provenance, and a check worth requiring
# ---------------------------------------------------------------------------


def test_provenance_is_attested(workflow):
    assert "attest-build-provenance" in _steps_text(workflow), (
        "TODO(lab-05-e1): nothing attests the build. Without it the registry holds an\n"
        "  image nobody can tie back to a commit."
    )


def test_attestation_uses_the_pushed_digest(workflow):
    step = next(
        (s for s in workflow.steps("image") if "attest-build-provenance" in (s.uses or "")),
        None,
    )
    if step is None:
        pytest.skip("no attestation step yet -- see TODO(lab-05-e1)")
    subject = str((step.raw.get("with") or {}).get("subject-digest", ""))
    assert "digest" in subject, (
        "TODO(lab-05-e1): the attestation does not name the pushed digest. A digest is\n"
        "  the only identifier that cannot come to mean something else."
    )


def test_job_names_do_not_collide(workflow):
    name = str(workflow.job("image").get("name", ""))
    assert name not in ("${{ matrix.service }}", "api", "worker"), (
        "TODO(lab-05-e2): this job reports as `api` and `worker`, the same names three\n"
        "  other workflows in this repository use. Branch protection matches required\n"
        "  checks by name alone, so requiring `api` would be satisfied by whichever\n"
        "  workflow reported last. That is not a gate."
    )


def test_there_is_an_aggregate_to_require(workflow):
    aggregate = [j for j in workflow.jobs if j != "image"]
    assert aggregate, (
        "TODO(lab-05-e2): no aggregate job. The scan gate blocks a publish; it does not\n"
        "  block a merge. A failing job that no required check depends on leaves the\n"
        "  pull request mergeable, so a vulnerable dependency can still land on main."
    )
    job_id = aggregate[0]
    job = workflow.job(job_id)
    assert "image" in workflow.needs(job_id), (
        f"TODO(lab-05-e2): `{job_id}` does not depend on the image job."
    )
    assert "always()" in str(job.get("if", "")), (
        f"TODO(lab-05-e2): `{job_id}` needs `if: always()`, or it is skipped exactly when\n"
        "  a dependency was skipped -- which is the case it exists to report on."
    )
    body = "\n".join(s.run or "" for s in workflow.steps(job_id))
    assert "needs.image.result" in body or "needs.image.result" in str(job), (
        f"TODO(lab-05-e2): `{job_id}` never reads `needs.image.result`, so it reports\n"
        "  success even when the image job failed. `if: always()` without a result check\n"
        "  is a green tick that means nothing."
    )


# ---------------------------------------------------------------------------
# Across the workflow
# ---------------------------------------------------------------------------


def test_third_party_actions_are_pinned():
    unpinned = unpinned_third_party_actions(load_workflow(WORKFLOW))
    assert not unpinned, (
        "Lab 04 established that a tag is a pointer its owner can move:\n"
        + "\n".join(f"    {ref}" for ref in unpinned)
    )


def test_the_workflow_has_actually_published():
    """Everything above reads YAML. This asks whether an image exists."""
    if not gh_available():
        pytest.skip("gh is not installed or not authenticated")
    runs = latest_runs("publish.yml", limit=10)
    if not runs:
        pytest.skip("this workflow has never run -- push the branch, then re-run")
    assert any(r.get("conclusion") == "success" for r in runs), (
        "TODO(lab-05-b): the workflow has run but never succeeded. A missing registry\n"
        "  login fails at the push, after the build and scan have already passed -- and\n"
        "  a pull request will not show it, because pull requests skip the push."
    )
