"""Lab 04 verifier -- Trust: Permissions, OIDC & Supply Chain.

Every failure names the TODO it corresponds to, so a red test tells you which
file to open.
"""

import re

import pytest
import yaml

from labcheck import gh_available, latest_runs, load_workflow
from labcheck.paths import repo_root
from labcheck.workflow import unpinned_third_party_actions

IDENTITY = ".github/workflows/aws-identity.yml"
SECURITY = ".github/workflows/security.yml"
DEPENDABOT = ".github/dependabot.yml"
ZIZMOR = ".github/zizmor.yml"

COMPOSITE_ACTION_DIR = ".github/actions/setup-service"


def _yaml(relative: str):
    path = repo_root() / relative
    if not path.is_file():
        pytest.fail(f"{relative} is missing -- run `make lab LAB=04` to install the starters.")
    return yaml.safe_load(path.read_text())


@pytest.fixture(scope="module")
def identity():
    return load_workflow(IDENTITY)


@pytest.fixture(scope="module")
def security():
    return load_workflow(SECURITY)


@pytest.fixture(scope="module")
def dependabot():
    return _yaml(DEPENDABOT)


# ---------------------------------------------------------------------------
# TODO(lab-04-a) -- least privilege
# ---------------------------------------------------------------------------


def test_workflow_declares_permissions(identity):
    assert identity.data.get("permissions") is not None, (
        "TODO(lab-04-a): the workflow declares no `permissions:`, so every job inherits\n"
        "  the repository default. A default is a setting someone can change; a\n"
        "  declaration travels with the file."
    )


def test_workflow_permissions_are_least_privilege(identity):
    perms = identity.data.get("permissions") or {}
    assert isinstance(perms, dict), (
        "TODO(lab-04-a): use a mapping, not `permissions: write-all` or `read-all`.\n"
        "  Name what the workflow needs."
    )
    for scope, level in perms.items():
        assert level != "write" or scope == "id-token", (
            f"TODO(lab-04-a): workflow-level `{scope}: write` is broader than this\n"
            "  workflow needs. Nothing here writes to the repository."
        )


# ---------------------------------------------------------------------------
# TODO(lab-04-b) -- the OIDC token permission
# ---------------------------------------------------------------------------


def test_job_requests_an_id_token(identity):
    perms = identity.job("whoami").get("permissions") or {}
    assert perms.get("id-token") == "write", (
        "TODO(lab-04-b): the `whoami` job cannot request an OIDC token without\n"
        "  `id-token: write`. The name is misleading -- it does not grant write access\n"
        "  to the repository, only the right to ask GitHub for a token about this run.\n"
        f"  found: {perms or 'no job-level permissions'}"
    )


# ---------------------------------------------------------------------------
# TODO(lab-04-c) -- assume the role, and prove it
# ---------------------------------------------------------------------------


def test_assumes_a_role(identity):
    step = next(
        (s for s in identity.steps("whoami") if s.uses and "configure-aws-credentials" in s.uses),
        None,
    )
    assert step is not None, (
        "TODO(lab-04-c): nothing in the job calls aws-actions/configure-aws-credentials,\n"
        "  so no role is assumed."
    )
    with_block = step.raw.get("with") or {}
    assert with_block.get("role-to-assume"), (
        "TODO(lab-04-c): the step sets no `role-to-assume`."
    )
    assert "aws-region" in with_block, (
        "TODO(lab-04-c): `aws-region` is required even though IAM is global."
    )


def test_role_arn_is_not_a_secret(identity):
    step = next(
        (s for s in identity.steps("whoami") if s.uses and "configure-aws-credentials" in s.uses),
        None,
    )
    if step is None:
        pytest.skip("no configure-aws-credentials step yet -- see TODO(lab-04-c)")
    role = str((step.raw.get("with") or {}).get("role-to-assume", ""))
    assert "secrets." not in role, (
        "TODO(lab-04-c): the role ARN is being read from `secrets.`. An ARN is an\n"
        "  identifier, not a credential -- storing it as a secret implies the security\n"
        "  comes from its name rather than from the role's trust policy. Use a\n"
        "  repository variable (`vars.`) instead."
    )


def test_identity_is_checked(identity):
    body = "\n".join(s.run for s in identity.steps("whoami") if s.run)
    assert "get-caller-identity" in body, (
        "TODO(lab-04-c): nothing calls `aws sts get-caller-identity`, so the job never\n"
        "  proves the credentials work."
    )
    assert "assumed-role" in body, (
        "TODO(lab-04-c): the job never checks that the identity is a *session*.\n"
        "  A long-lived IAM user answers get-caller-identity just as happily. The\n"
        "  difference between arn:aws:iam::...:user/... and\n"
        "  arn:aws:sts::...:assumed-role/... is the whole point of this lab."
    )


# ---------------------------------------------------------------------------
# TODO(lab-04-d) -- keeping pins current
# ---------------------------------------------------------------------------


def test_dependabot_covers_the_composite_action(dependabot):
    update = dependabot["updates"][0]
    dirs = update.get("directories") or ([update["directory"]] if update.get("directory") else [])
    covered = any(COMPOSITE_ACTION_DIR in str(d) for d in dirs)
    assert covered, (
        "TODO(lab-04-d1): `directory: /` covers .github/workflows and a root action.yml,\n"
        f"  and nothing else. {COMPOSITE_ACTION_DIR}/action.yml holds pinned actions that\n"
        "  would never be proposed for update -- silently, with no error.\n"
        f"  found: {dirs}"
    )


def test_dependabot_has_a_cooldown(dependabot):
    cooldown = dependabot["updates"][0].get("cooldown") or {}
    days = cooldown.get("default-days")
    assert days is not None, (
        "TODO(lab-04-d2): no cooldown. A new version is proposed the day it appears,\n"
        "  which is also the day a compromised maintainer would publish one."
    )
    assert int(days) >= 7, (
        f"TODO(lab-04-d2): default-days={days} is shorter than the week a yanked\n"
        "  release usually takes to be noticed."
    )


def test_major_updates_are_not_grouped(dependabot):
    groups = dependabot["updates"][0].get("groups") or {}
    assert groups, (
        "TODO(lab-04-d3): no groups. Five actions produce five pull requests a week,\n"
        "  which is how people learn to merge them without reading them."
    )
    for name, group in groups.items():
        types = group.get("update-types")
        assert types is not None, (
            f"TODO(lab-04-d3): group `{name}` has no `update-types`, so it bundles major\n"
            "  versions too. A major is a promise that something breaks; bundled, a red\n"
            "  run names none of the things that might have caused it."
        )
        assert "major" not in types, (
            f"TODO(lab-04-d3): group `{name}` includes major updates.\n"
            f"  found: {types}"
        )


# ---------------------------------------------------------------------------
# TODO(lab-04-e) -- checking the pipeline itself
# ---------------------------------------------------------------------------


def test_security_workflow_runs_on_changes_and_on_a_schedule(security):
    triggers = {str(k) for k in security.triggers}
    assert "pull_request" in triggers, (
        "TODO(lab-04-e1): Security does not run on pull requests, so a workflow change\n"
        "  is never checked before it lands."
    )
    assert "schedule" in triggers, (
        "TODO(lab-04-e1): no schedule. Actions get published and tags get moved, so a\n"
        "  clean scan today says nothing about next month. This is the trigger that\n"
        "  catches a supplier changing under you."
    )


def test_security_workflow_runs_zizmor(security):
    body = "\n".join(s.run for s in security.steps("zizmor") if s.run)
    uses = " ".join(s.uses or "" for s in security.steps("zizmor"))
    assert "zizmor" in body or "zizmor" in uses, (
        "TODO(lab-04-e1): the job never runs zizmor."
    )
    if "zizmor" in body:
        assert re.search(r"zizmor@[\w.]+", body), (
            "TODO(lab-04-e1): zizmor is run without a pinned version. `uvx zizmor` takes\n"
            "  whatever is newest, so this job's behaviour changes without a commit."
        )


def test_zizmor_config_suppresses_by_rule_not_by_severity(security):
    config = _yaml(ZIZMOR) or {}
    rules = config.get("rules") or {}
    assert rules, (
        "TODO(lab-04-e2): .github/zizmor.yml suppresses nothing. Run\n"
        "  `zizmor --offline .github/` and decide, for each finding, whether to fix it\n"
        "  or record why it does not apply."
    )
    assert "self-repository" in rules, (
        "TODO(lab-04-e2): `self-repository` is the one rule this repository disagrees\n"
        "  with, because act cannot parse the syntax it prefers. Suppress that rule by\n"
        f"  name.\n  found rules: {sorted(rules)}"
    )


# ---------------------------------------------------------------------------
# Across the repository
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", [IDENTITY, SECURITY])
def test_third_party_actions_are_pinned(path):
    workflow = load_workflow(path)
    unpinned = unpinned_third_party_actions(workflow)
    assert not unpinned, (
        f"TODO(lab-04-c): {path} uses third-party actions by tag, not by commit:\n"
        + "\n".join(f"    {ref}" for ref in unpinned)
        + "\n  A tag is a pointer its owner can move. A moved tag runs their code with\n"
        "  your token on the next run."
    )


def test_the_identity_workflow_has_actually_run():
    """Everything above reads files. This asks whether it ever worked."""
    if not gh_available():
        pytest.skip("gh is not installed or not authenticated")
    runs = latest_runs("aws-identity.yml", limit=10)
    if not runs:
        pytest.skip(
            "this workflow has never run -- push the branch and dispatch it, then re-run"
        )
    assert any(r.get("conclusion") == "success" for r in runs), (
        "TODO(lab-04-c): the workflow has run but never succeeded. A trust policy that\n"
        "  looks correct and is rejected by STS is the usual cause -- the error names no\n"
        "  reason, so read the actual claim from CloudTrail. See docs/OIDC.md."
    )
