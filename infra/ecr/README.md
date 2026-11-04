# infra/ecr

Container registry for the images the pipeline builds. **About $0.015/month per
retained version pair**, and the first 500MB of private storage is free for
twelve months.

```bash
terraform init -backend-config=../backend.hcl && terraform apply     # ~10 seconds, 5 resources
gh variable set AWS_ECR_REGISTRY --body "$(terraform output -raw registry)"
```

State lives in the S3 bucket from `infra/state` (Project 7), and `infra/backend.hcl` names it. If you are working through the curriculum before Project 7, there is no bucket yet: create a gitignored `backend_override.tf` here containing `terraform {` / `backend "local" {}` / `}` on three lines, and delete it when Project 7 moves the state.

Apply `infra/ci-oidc` first. This stack looks that role up by name to attach
push permissions to it.

## Adding a service

Since Project 8, one line in `terraform.tfvars`:

```hcl
services = {
  api    = {}
  worker = {}
  auth   = { retained_images = 3 }   # the new line; the override is optional
}
```

The repository, its lifecycle policy and CI push access all follow from that line. `ci.tf` builds the push policy from `module.repository`, so it covers a new repository without being edited. `tests/ecr.tftest.hcl` checks exactly that, offline:

```bash
terraform test     # 3 passed, 0 failed
```

The settings themselves live in the module. Its [README](../modules/ecr-repository/README.md) explains them, and why `services` is a map rather than a list.

## How this stack finds the CI role

`infra/ci-oidc` creates the role and `infra/ecr` grants it push access, so one stack needs something from another. There are two ways to get it, and this stack uses the first:

| | How | Needs | Breaks when |
|---|---|---|---|
| **Data source** (used) | `data "aws_iam_role" "ci" { name = var.ci_role_name }` | `iam:GetRole` | the role is renamed or deleted, at plan, with a clear error |
| `terraform_remote_state` | read `infra/ci-oidc`'s outputs from its state file | `s3:GetObject` on that whole state file | the other stack renames an output |

`terraform_remote_state` reads the entire state file, not only the outputs. Anyone who can plan this stack would also be able to read every value in `ci-oidc`'s state. A data source asks AWS about one resource. This is also why the precondition in `ci.tf` works: it reads the role's live trust policy, not what the other stack last recorded.

## Why this exists when GHCR already works

**Track C pulls from it.** EKS pulling from GHCR needs an image pull secret — a
stored credential, which is exactly what Project 4 spent its time removing. ECR
plus IAM needs no secret.

The pipeline pushes to both. GHCR is public and free and is where attestation
verification is cheapest; ECR is what the cluster will use.

## What it creates

| | |
|---|---|
| Two repositories | `ci-cd-lab/api`, `ci-cd-lab/worker`, one [`ecr-repository`](../modules/ecr-repository) module per entry in `services` |
| Lifecycle policy | expire untagged after 1 day, keep the 10 most recent tagged |
| Scan on push | ECR's own continuous scan, alongside the Trivy gate in CI |
| An inline policy on the CI role | push to these two repositories and nothing else |

### `IMMUTABLE` tags

Pushing `0.1.0` twice **fails** rather than silently changing what `0.1.0`
means. The whole curriculum argues that a digest is the only identifier that
cannot lie to you; this makes the registry enforce it.

The cost is that a failed release cannot be re-cut under the same version. That
is the correct trade — a version that meant two different things is worse than
a version number you skipped.

### Two scans, two questions

Trivy runs at build time and answers *"should this ship"*. ECR's scan runs
continuously against a feed that keeps moving, and answers *"is something we
shipped last month now known to be vulnerable"*. A gate cannot ask the second
question.

## This is where the CI role got its first permission

Until this stack, `ci-cd-lab-ci` could prove its own identity and do nothing
else. That is why its trust policy could safely accept any branch or pull
request.

Adding push access changed that, and `infra/ci-oidc` was narrowed in the same
change:

```
repo:OWNER/NAME:ref:refs/heads/main
repo:OWNER/NAME:ref:refs/tags/v*
```

Without it, anyone who could open a pull request against this repository could
push an image to it — a `pull_request` subject names the repository the pull
request *targets*, not whoever wrote the code.

The policy here is scoped by ARN to these two repositories, and grants no
delete. **CI publishes; it does not curate.** Retention is the lifecycle
policy's job, and changing that is a Terraform change someone reviews.

## Cost control

The retention count is the entire cost control:

```hcl
retained_images = 10
```

Every merge pushes two images. Without a cap that grows forever, slowly enough
that nobody notices for a year. Raising this number is choosing a bill.

```bash
aws ecr describe-images --repository-name ci-cd-lab/api --query 'length(imageDetails)'
```

## Teardown

There isn't one, and that is the point. Unlike `infra/eks`, these are meant to
persist — `make aws-sweep` does not flag them, because it lists what should not
be running.

If you do want them gone, note that `force_delete` is deliberately not set:
emptying a registry should be something you do on purpose.

```bash
aws ecr batch-delete-image --repository-name ci-cd-lab/api \
  --image-ids "$(aws ecr list-images --repository-name ci-cd-lab/api --query 'imageIds' --output json)"
terraform destroy
```
