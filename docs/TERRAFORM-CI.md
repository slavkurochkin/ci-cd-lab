# Terraform in CI

How `infra/envs/dev` and `infra/envs/prod` are planned, checked and applied by the pipeline. Project 9.

**For these two environments, the pipeline is the only thing that applies.** A pull request gets a plan, a policy check and a comment. A merge applies dev, then waits for a person to approve prod. Nobody's laptop holds a credential that can write to them.

| File | What it is |
|---|---|
| [`.github/workflows/lab-09-terraform.yml`](../.github/workflows/lab-09-terraform.yml) | check, plan, comment, apply |
| [`.github/workflows/terraform-drift.yml`](../.github/workflows/terraform-drift.yml) | nightly plan; opens an issue when it is not empty |
| [`infra/ci-oidc/terraform-roles.tf`](../infra/ci-oidc/terraform-roles.tf) | the three roles the workflows assume |
| [`policy/terraform/`](../policy/terraform) | four policy rules and their tests |

---

## The flow

```
pull request                                   merge to main
────────────                                   ─────────────
changes                                        changes
  ├─ static   fmt, validate, tflint,             ├─ static
  │           checkov, module + policy tests     ├─ plan (dev, prod)  → saved plan files
  ├─ plan (dev)   plan role → conftest           ├─ gate   which plans are not empty
  ├─ plan (prod)  plan role → conftest           ├─ apply (dev)    infra-dev environment
  ├─ comment  one comment, edited per push       └─ apply (prod)   infra-prod: waits for approval
  └─ terraform-passed   ← required to merge
```

`terraform-passed` is the required check, for the reason you met in Lab 02: a job skipped by a path filter reports nothing, and a required check that reports nothing blocks the pull request forever. It passes when every job passed or was skipped, and fails otherwise.

---

## Three roles, so each job can do one thing

**A job that plans cannot apply, and a job that applies dev cannot touch prod.** Each role's trust policy decides which jobs can assume it, and its permissions decide what those jobs can do.

| Role | Who can assume it (OIDC `sub`) | What it can do |
|---|---|---|
| `ci-cd-lab-tf-plan` | `pull_request`, `ref:refs/heads/main` | read `envs/*` state, take the lock, read bucket settings. No write to any resource |
| `ci-cd-lab-tf-apply-dev` | `environment:infra-dev` | write `envs/dev` state; create and configure `ci-cd-lab-dev-*` |
| `ci-cd-lab-tf-apply-prod` | `environment:infra-prod` | the same, for prod |

A job only gets an `environment:infra-prod` subject by declaring `environment: infra-prod`. GitHub issues the token only after that environment's rules pass: the run is on `main`, and a reviewer approved it. A pull request cannot produce that subject, so it cannot reach the prod role, whatever the workflow file says.

The plan role trusts `pull_request`, which the CI role from Project 4 refuses. That is safe only because of what the plan role cannot do. Note what it cannot read either: state outside `envs/`. State files hold every attribute in plain text, and a dev plan has no reason to read `ci-oidc`'s.

Only `infra/envs/*` is applied by CI. `ci-oidc` and `ecr` write IAM, and a role that can write IAM can grant itself anything. Capstone B is where that gets solved; until then those stacks are applied from a laptop.

> Further reading: [OIDC in AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)

---

## The applied plan is the reviewed plan

**`apply` consumes the plan file saved by the `plan` job in the same run. It never plans again.**

On `main`, `plan` uploads `tfplan` as an artifact, the job summary shows it, and the apply job downloads that file and runs `terraform apply tfplan`. What the approver reads in the summary is what gets applied. If state changed between the two, because someone else applied in the meantime, Terraform refuses with `Saved plan is stale` instead of applying something nobody read.

The plan on the pull request is not the plan that gets applied. It was made against the PR branch, before merge, and `main` may have moved since. It answers "what will this change do", and the plan on `main` answers "what will happen now".

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Apply re-plans** | `terraform apply -auto-approve` in the apply job | applies whatever the world looks like at apply time | an apply that differs from the plan someone approved, and nothing says so |
| **Approval fatigue** | every merge stops at the prod gate, including empty plans | people learn that approving changes nothing | the approval button clicked in two seconds, the one time it mattered too |
| **Plan file kept forever** | default artifact retention | the plan holds every attribute it touches, readable by anyone with read access to a public repository | nothing, until someone downloads it |

The `gate` job handles the second row. It reads whether each plan changes anything, and an apply job runs only for an environment that has changes. A merge that leaves prod's plan empty never asks for an approval. Plan files are kept for one day.

---

## A plan comment for people who do not read Terraform

**Deletes go first, in full, and only the raw plan is ever cut short.** A long plan cannot push a delete out of view.

`.github/scripts/plan-summary.py` turns `terraform show` into one table per environment: each resource and what happens to it, in words ("replace: deleted, then created again", "rename only"). The raw plan is folded below it, and cut at 25,000 characters per environment because GitHub refuses comments over 65,536. There is one comment per pull request, edited on each push, so it does not bury the conversation.

What the public-bucket PR (#43) got:

```
### `dev`: Plan: 2 to add, 1 to change, 0 to destroy.

| Resource                                   | What happens    |
| aws_s3_bucket.shared                       | create          |
| aws_s3_bucket_public_access_block.shared   | create          |
| module.data_bucket.aws_s3_bucket.this      | change in place |

Policy: 3 violation(s). This blocks the merge.
- aws_s3_bucket_public_access_block.shared: block_public_acls must be true. ...
- aws_s3_bucket_public_access_block.shared: block_public_policy must be true. ...
- aws_s3_bucket_public_access_block.shared: restrict_public_buckets must be true. ...
```

---

## Policy as code

**A rule nobody has to remember to check.** Four rules in Rego, run by `conftest` against `terraform show -json` of each plan:

| Rule | Denies | File |
|---|---|---|
| No public S3 | a public access block with any flag off; a `public-*` ACL; more buckets than access blocks | `s3_public.rego` |
| Required tags | a taggable resource missing `Project`, `ManagedBy` or `Environment` in `tags_all` | `tags.rego` |
| No wildcard IAM | `*` or a write wildcard such as `s3:Put*`; a write action on resource `*` | `iam.rego` |
| No prod bucket deletes | a plan that deletes or replaces an `aws_s3_bucket` in prod | `prod.rego` |

They read the plan, not the code, so they see values the code does not show: tags that come from `default_tags`, a module's resources fully expanded, and the actions Terraform will take. A rule on the code cannot tell a replace from an update.

`conftest verify` runs 15 unit tests: each rule rejects at least one bad plan and accepts a good one.

Two things went wrong while writing them, and both are worth knowing:

- **Without `--namespace terraform`, conftest checks nothing and passes.** It looks for rules in package `main` by default. These are in `terraform`, so the first run against `infra/ci-oidc` printed `0 tests, 0 passed, 0 warnings, 0 failures` and exited 0. With the namespace, the same plan had 7 failures.
- **The rules found the roles written for this project.** The first apply roles granted `s3:Put*`, and the IAM rule rejected it. `Put*` includes `PutBucketPolicy` and `PutBucketAcl`, which are the two ways to make a bucket public. The roles now name the five `Put` actions the module uses, so they cannot make a bucket public even if every check here were bypassed.

`checkov` runs too, on the code rather than the plan. It ships hundreds of generic checks, and five of them flag choices this curriculum made on purpose: no KMS, no access logging, no cross-region replication, no S3 event notifications, and no KMS on ECR. Each is skipped with a reason, on the resource itself:

```hcl
#checkov:skip=CKV_AWS_145:SSE-S3, not KMS. A KMS key is $1/month plus per-request charges, for an audit trail these buckets do not need.
```

A skip with a reason next to the resource is a decision someone can review. A `--skip-check` flag in a workflow is not.

> Further reading: [conftest](https://www.conftest.dev/), [Checkov suppressions](https://www.checkov.io/2.Basics/Suppressing%20and%20Skipping%20Policies.html)

---

## Drift detection

**Report drift; do not fix it automatically.** Drift means AWS and `main` disagree, and either side may be the one that is right.

`terraform-drift.yml` plans both environments at 06:17 UTC with the plan role. `-detailed-exitcode` returns 2 when the plan is not empty. For each environment it then opens an issue titled `Drift detected in infra/envs/<env>`, or comments on the one already open, and closes it when a later night is clean. There is one issue per environment, not one per night, so the issue stays readable.

---

## Failure modes

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Exit code 2 read as failure** | `terraform plan -detailed-exitcode` in a `run:` step | GitHub runs steps with `bash -e`; exit 2 ("there are changes") ends the step before the script reads it | a plan with changes fails red; an empty plan passes, so it works until the first real change |
| **Lock never released** | the plan role can write and delete `.tflock` but not read it | releasing the lock reads it back first; `AccessDenied` | the job fails, and every later plan or apply waits on a lock nobody holds |
| **Policy runs no rules** | `conftest test` without `--namespace` | conftest looks in package `main` and finds nothing | `0 tests, 0 passed, 0 failures`, green |
| **Required check never reports** | the Terraform job itself required, behind a path filter | a PR not touching `infra/` never runs it | `Expected — Waiting for status to be reported`, forever |
| **Fork PR** | a pull request from a fork | GitHub issues no OIDC token to fork PRs, so the plan cannot assume a role | `plan` fails at credentials. Correct: a change nobody can plan should not merge |

---

## What went wrong while building this

- **Every plan left both environments locked.** The first CI run planned dev and prod, failed to release either lock (`AccessDenied` on `s3:GetObject` for the `.tflock`), and left them locked. They were released with `terraform force-unlock <ID>` after confirming from each lock's `Who` and `Created` that it belonged to the finished run. The plan role now has `GetObject` on the lock object.
- **The first green run hid a broken plan step.** It had no changes, so `plan` exited 0. The first PR with a change failed both plans: exit code 2 ended the step under GitHub's default `bash -e`. The drift workflow had the same line, and there it would have broken the one case it exists for. Both now turn off `-e` until the exit code is read.
- **`checkov` passed locally and failed in CI.** Both were version 3.3.10. The Homebrew install ran 8 checks with no failures on `infra/envs`; `uvx checkov==3.3.10`, which is what CI runs, ran 18 with 4 failures. The cause was not tracked down. Run the scanner locally the way CI runs it.
- **The tag rule does not fit every stack.** `Environment` is required, and IAM in `ci-oidc` has no environment. CI runs the rules on `infra/envs/*` only, where it fits.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| A PR adding a public S3 bucket is blocked by policy, not by a reviewer noticing | PR #43: `plan (dev)` failed on 3 policy violations, `static` failed on `checkov`, `terraform-passed` failed, merge state `BLOCKED`. No bucket was created. Closed unmerged. |
| The plan comment is readable by someone who does not know Terraform | the table above |
| Manually changing a resource in the console produces an issue by morning | see below, after merge |
