"""Lab 06 verifier -- Terraform Fundamentals.

Reads HCL as text rather than parsing it. A real HCL parser would be stricter
and would also reject a correct answer written in an unexpected style; these
tests check that the right resources and arguments are present, and leave the
shape to you.
"""

import json
import re
import subprocess

import pytest

from labcheck.paths import repo_root

SANDBOX = "infra/sandbox"
ACCOUNT = "infra/account"


def _read(relative: str) -> str:
    path = repo_root() / relative
    if not path.is_file():
        pytest.fail(f"{relative} is missing -- run `make lab LAB=06`.")
    return path.read_text()


@pytest.fixture(scope="module")
def sandbox():
    return _read(f"{SANDBOX}/main.tf") + "\n" + _read(f"{SANDBOX}/outputs.tf")


@pytest.fixture(scope="module")
def account():
    return _read(f"{ACCOUNT}/main.tf")


def _terraform(directory: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["terraform", f"-chdir={repo_root() / directory}", *args],
        capture_output=True, text=True,
    )


def _strip_comments(text: str) -> str:
    """HCL comments, removed.

    These tests read HCL as text, so a rule like "there is no depends_on here"
    is otherwise defeated by the comment explaining why there is no depends_on.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)(#|//).*$", "", line) for line in text.splitlines())


def _has_resource(text: str, kind: str, name: str | None = None) -> bool:
    name_pattern = re.escape(name) if name else '[^"]+'
    pattern = r'resource\s+"' + re.escape(kind) + r'"\s+"' + name_pattern + r'"'
    return re.search(pattern, text) is not None


# ---------------------------------------------------------------------------
# TODO(lab-06-a) -- variables, locals, for expressions
# ---------------------------------------------------------------------------


def test_environment_variable_is_constrained(sandbox):
    assert 'variable "environment"' in sandbox, (
        "TODO(lab-06-a1): no `environment` variable."
    )
    block = sandbox[sandbox.index('variable "environment"'):]
    block = block[: block.index("\n}\n") + 3] if "\n}\n" in block else block
    assert "validation" in block, (
        "TODO(lab-06-a1): `environment` accepts any string. A variable with no\n"
        "  constraint is one someone eventually sets to \"prd\" at 6pm."
    )


def test_service_names_is_a_typed_list(sandbox):
    assert 'variable "service_names"' in sandbox, (
        "TODO(lab-06-a2): no `service_names` variable."
    )
    assert re.search(r"type\s*=\s*list\(string\)", sandbox), (
        "TODO(lab-06-a2): `service_names` has no `type = list(string)`. Without a type\n"
        "  constraint Terraform accepts a string and fails somewhere less obvious."
    )


def test_locals_use_a_for_expression(sandbox):
    assert "locals" in sandbox, "TODO(lab-06-a3): no `locals` block."
    assert re.search(r"\{\s*for\s+", sandbox), (
        "TODO(lab-06-a3): `service_ports` is not built with a `for` expression.\n"
        "  Writing the map out by hand works until someone adds a service."
    )


# ---------------------------------------------------------------------------
# TODO(lab-06-b) -- the resource graph, and replacement
# ---------------------------------------------------------------------------


def test_pet_keys_on_the_environment(sandbox):
    assert _has_resource(sandbox, "random_pet", "name"), (
        "TODO(lab-06-b): no `random_pet` resource named `name`."
    )
    assert "keepers" in sandbox, (
        "TODO(lab-06-b): `random_pet` has no `keepers`. Without it nothing ever forces\n"
        "  a replacement, and the plan verb this lab exists to show never appears."
    )
    assert re.search(r"keepers\s*=\s*\{[^}]*var\.environment", sandbox, re.S), (
        "TODO(lab-06-b): `keepers` does not reference var.environment, so changing the\n"
        "  environment will not force a replacement."
    )


def test_password_depends_on_the_pet_by_reference(sandbox):
    assert _has_resource(sandbox, "random_password", "token"), (
        "TODO(lab-06-b): no `random_password` resource named `token`."
    )
    assert "random_pet.name" in sandbox, (
        "TODO(lab-06-b): nothing references random_pet.name, so Terraform has no\n"
        "  ordering to derive."
    )


def test_no_explicit_depends_on_in_the_sandbox(sandbox):
    assert "depends_on" not in _strip_comments(sandbox), (
        "TODO(lab-06-b): there is a `depends_on` here, and there should not be.\n"
        "  Every ordering in this module is derivable from a reference. An explicit\n"
        "  depends_on usually means a reference is missing."
    )


# ---------------------------------------------------------------------------
# TODO(lab-06-c) -- what state holds
# ---------------------------------------------------------------------------


def test_a_private_key_is_generated(sandbox):
    assert _has_resource(sandbox, "tls_private_key"), (
        "TODO(lab-06-c): no `tls_private_key`. It is here so you can find its private\n"
        "  key sitting in terraform.tfstate in plain text."
    )


def test_the_token_output_is_marked_sensitive(sandbox):
    assert 'output "token"' in sandbox, "TODO(lab-06-c): no `token` output."
    block = sandbox[sandbox.index('output "token"'):]
    block = block[: block.index("\n}") + 2] if "\n}" in block else block
    assert "sensitive" in block, (
        "TODO(lab-06-c): the `token` output is not marked sensitive, so the generated\n"
        "  password prints to the console on every apply."
    )


# ---------------------------------------------------------------------------
# TODO(lab-06-d) -- an S3 bucket is five resources
# ---------------------------------------------------------------------------


def test_bucket_exists(account):
    assert _has_resource(account, "aws_s3_bucket"), (
        "TODO(lab-06-d1): no `aws_s3_bucket`."
    )


def test_bucket_name_is_globally_unique(account):
    assert "aws_caller_identity" in account, (
        "TODO(lab-06-d1): the bucket name does not include the account ID. S3 names are\n"
        "  globally unique across every AWS account, so a fixed name fails with\n"
        "  BucketAlreadyExists for a bucket you cannot see and do not own."
    )


@pytest.mark.parametrize(
    "kind",
    [
        "aws_s3_bucket_versioning",
        "aws_s3_bucket_server_side_encryption_configuration",
        "aws_s3_bucket_public_access_block",
        "aws_s3_bucket_lifecycle_configuration",
    ],
)
def test_bucket_is_configured(account, kind):
    assert _has_resource(account, kind), (
        f"TODO(lab-06-d2): no `{kind}`.\n"
        "  A bucket is not one object with settings -- it is a bucket plus four\n"
        "  independent configurations, each of which can simply be absent."
    )


def test_all_four_public_access_flags_are_set(account):
    missing = [
        flag
        for flag in (
            "block_public_acls",
            "block_public_policy",
            "ignore_public_acls",
            "restrict_public_buckets",
        )
        if not re.search(rf"{flag}\s*=\s*true", account)
    ]
    assert not missing, (
        f"TODO(lab-06-d2): these public-access flags are not set to true: {missing}\n"
        "  Each blocks a different route -- new ACLs, existing ACLs, new policies,\n"
        "  existing policies. Setting two of four leaves whichever was already open\n"
        "  still open."
    )


def test_versioning_has_an_expiry(account):
    assert "noncurrent_version_expiration" in account, (
        "TODO(lab-06-d2): versioning is enabled with no expiry for old versions, so\n"
        "  every overwrite is kept forever and the bill grows with the number of edits\n"
        "  rather than the amount of data."
    )


# ---------------------------------------------------------------------------
# TODO(lab-06-e) -- the budget, and drift
# ---------------------------------------------------------------------------


def test_budget_is_declared(account):
    assert _has_resource(account, "aws_budgets_budget"), (
        "TODO(lab-06-e): no `aws_budgets_budget`."
    )


def test_budget_warns_before_the_money_is_spent(account):
    assert "FORECASTED" in account, (
        "TODO(lab-06-e): the budget has no FORECASTED notification. One that reports\n"
        "  only actual spend is a receipt, not a warning."
    )
    assert "ACTUAL" in account, (
        "TODO(lab-06-e): the budget has no ACTUAL notification. A forecast can be wrong\n"
        "  in both directions."
    )


def test_budget_is_in_state_not_just_in_the_account():
    """The drift test. Declaring the resource is not the same as managing it."""
    result = _terraform(ACCOUNT, "state", "list")
    if result.returncode != 0:
        pytest.skip("terraform state is not initialised in infra/account")
    assert "aws_budgets_budget" in result.stdout, (
        "TODO(lab-06-e): the budget is declared but not in state, so Terraform thinks it\n"
        "  must create one that already exists -- an apply that fails.\n"
        "  Close the gap:\n"
        "    terraform -chdir=infra/account import aws_budgets_budget.monthly \\\n"
        "      \"<account-id>:ci-cd-lab-monthly\""
    )


# ---------------------------------------------------------------------------
# Both modules
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("directory", [SANDBOX, ACCOUNT])
def test_formatting_is_canonical(directory):
    result = _terraform(directory, "fmt", "-check", "-recursive")
    assert result.returncode == 0, (
        f"`terraform fmt` would change files in {directory}:\n{result.stdout}"
        "  Run `terraform -chdir=" + directory + " fmt`."
    )


@pytest.mark.parametrize("directory", [SANDBOX, ACCOUNT])
def test_configuration_is_valid(directory):
    result = _terraform(directory, "validate", "-json")
    if result.returncode != 0 and "Missing required provider" in result.stdout:
        pytest.skip(f"{directory} is not initialised -- run terraform init")
    payload = json.loads(result.stdout or "{}")
    assert payload.get("valid"), (
        f"`terraform validate` failed in {directory}:\n"
        + "\n".join(d.get("summary", "") for d in payload.get("diagnostics", []))
    )
