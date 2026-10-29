# infra/state

The S3 bucket that holds every long-lived stack's Terraform state, including its own. Project 7.

**State is the only thing Terraform cannot recreate. Keep it in one versioned, locked, private bucket, not in a file on one laptop.** Before this project, the state for the OIDC role, the ECR repositories and the budget existed in one place: `terraform.tfstate` files in a gitignored folder on one machine.

```bash
cp ../backend.hcl.example ../backend.hcl      # set the account ID
terraform init -backend-config=../backend.hcl
terraform plan                                # No changes.
```

---

## What lives here

| Key in `ci-cd-lab-tfstate-<account-id>` | Root | What losing it would cost |
|---|---|---|
| `state/terraform.tfstate` | `infra/state` | this bucket's own settings, recoverable by import |
| `account/terraform.tfstate` | `infra/account` | the artifacts bucket and the budget, import again |
| `ci-oidc/terraform.tfstate` | `infra/ci-oidc` | `EntityAlreadyExists` on the next apply |
| `ecr/terraform.tfstate` | `infra/ecr` | `RepositoryAlreadyExistsException` on the next apply |
| `envs/dev/…`, `envs/prod/…` | `infra/envs/*` | see [`../envs/README.md`](../envs/README.md) |

`infra/eks` stays local. Nothing in it outlives a session, and `make eks-down` finds what is left without reading state. `infra/sandbox` stays local because it creates nothing in AWS.

Every backend block has the same four settings and no bucket name:

```hcl
backend "s3" {
  key          = "account/terraform.tfstate"
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true
}
```

The bucket name contains the account ID, and a backend block cannot read a variable or a data source. So the name lives in `infra/backend.hcl` (gitignored) and arrives through `terraform init -backend-config=../backend.hcl`. This is called **partial configuration**.

> Further reading: [S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)

---

## Bootstrapping: a bucket that stores its own state

**Create the bucket outside Terraform, adopt it with `import` blocks, and only then point the backend at it.** Terraform needs a backend before it can create anything, and the backend here is the thing being created.

The order, as it was run:

1. `aws s3api create-bucket --bucket ci-cd-lab-tfstate-<account-id>`
2. Write `main.tf` with `import` blocks, and leave the `backend` block out of `versions.tf`.
3. `terraform apply` with local state.
4. Add the `backend "s3"` block, then `terraform init -migrate-state -backend-config=../backend.hcl`.
5. `terraform plan` → `No changes.` The bucket now holds the state that describes it.

**A bare bucket is no longer bare.** The plan expected to import one resource and create four. It said:

```
module.state_bucket.aws_s3_bucket.this will be updated in-place   (imported)
module.state_bucket.aws_s3_bucket_public_access_block.this will be imported
module.state_bucket.aws_s3_bucket_server_side_encryption_configuration.this will be imported
module.state_bucket.aws_s3_bucket_lifecycle_configuration.this will be created
module.state_bucket.aws_s3_bucket_versioning.this will be created
Plan: 3 to import, 2 to add, 1 to change, 0 to destroy.
```

Since 2023, AWS turns on SSE-S3 encryption and all four public-access blocks for every new bucket. Versioning and lifecycle rules are still off. `get-bucket-versioning` on the new bucket returned nothing at all. The one change was tags: the CLI bucket had none, and `default_tags` adds three.

The `import` blocks stay in `main.tf`. After the first apply they do nothing, and they record where these resources came from. Project 6 used the CLI command `terraform import`, which changes state immediately and leaves no trace in the code. An `import` block shows up in `plan` first and goes through review like any other change.

**After migration, Terraform empties the old local file but does not delete it.** `terraform.tfstate` was 0 bytes and `terraform.tfstate.backup` held the last full copy. Both were deleted once `plan` against S3 was clean.

**Do not `terraform destroy` this root.** It would try to delete the bucket holding every other stack's state. `force_destroy` is `false`, so S3 refuses to delete a bucket that still has objects in it. That refusal is the last guard, and it should not be the only one.

> Further reading: [Import blocks](https://developer.hashicorp.com/terraform/language/import)

---

## Locking

**Every root sets `use_lockfile = true`.** Two applies against the same state at the same time is how a state file ends up describing neither of them.

The test: one `terraform apply -var budget_limit=51` was left waiting at its `yes` prompt, which holds the lock. A second apply in another shell got:

```
Error: Error acquiring the state lock

Error message: operation error S3: PutObject, https response error
StatusCode: 412 ... api error PreconditionFailed: At least one of the
pre-conditions you specified did not hold
Lock Info:
  Path:      ci-cd-lab-tfstate-<account-id>/account/terraform.tfstate
  Operation: OperationTypeApply
  Who:       <user>@<hostname>
```

While the first apply waited, the bucket held a 252-byte `account/terraform.tfstate.tflock` next to the state. The lock is an S3 conditional write: `PutObject` with `If-None-Match`, which fails with `412` if the object already exists. No DynamoDB table is involved. The S3 backend's `dynamodb_table` setting is deprecated in favour of this.

The first attempt at this test proved nothing. With no pending changes, the first apply printed `No changes` and exited without a prompt, so it released the lock before the second one started, and both "succeeded". A lock test needs the first run to be stuck *holding* the lock.

---

## Drift

**`plan` finds drift. `plan -refresh-only` tells you it is drift.** In a normal plan, a change made outside Terraform looks the same as a change you made in the code.

The budget was changed from $50 to $75 with `aws budgets update-budget`, which is what a console edit amounts to. A normal `terraform plan`:

```
# aws_budgets_budget.monthly will be updated in-place
  ~ limit_amount      = "75.0" -> "50"
Plan: 0 to add, 1 to change, 0 to destroy.
```

Nothing in that output says someone changed it. `terraform plan -refresh-only` does:

```
Note: Objects have changed outside of Terraform
  # aws_budgets_budget.monthly has changed
  ~ limit_amount      = "50.0" -> "75.0"
```

Those are the two ways to resolve drift:

| | Command | Result |
|---|---|---|
| **Revert it** | `terraform apply` | AWS goes back to the code. Used here: the budget returned to `50.0` in place, same ID. |
| **Accept it** | change the code to match, then `apply -refresh-only` | the code and state catch up with AWS |

`apply -refresh-only` on its own only rewrites state. The next normal plan would revert the change anyway, because the code still says 50.

> Further reading: [Manage resource drift](https://developer.hashicorp.com/terraform/tutorials/state/resource-drift)

---

## `moved`: refactoring without destroying

**When a resource's address changes, write a `moved` block. Terraform tracks resources by address, not by what they are.**

The five bucket resources in `infra/account` moved into `../modules/s3-bucket`. Without `moved` blocks:

```
# aws_s3_bucket.artifacts will be destroyed
  (because aws_s3_bucket.artifacts is not in configuration)
...
# module.artifacts.aws_s3_bucket.this will be created
...
Plan: 5 to add, 0 to change, 5 to destroy.
```

The artifacts bucket was empty, so that apply would have **succeeded**: it would have deleted the bucket and created a new one with the same name, and nothing would have failed. With objects in the bucket it goes wrong partway (this part was not run). The four settings depend on the bucket, so Terraform deletes them first. The bucket delete then fails with `BucketNotEmpty`, after the public-access block is already gone.

With the five blocks in [`../account/moved.tf`](../account/moved.tf):

```
# aws_s3_bucket.artifacts has moved to module.artifacts.aws_s3_bucket.this
...
Plan: 0 to add, 0 to change, 0 to destroy.
```

Note that this says `0 to add, 0 to change, 0 to destroy`, not `No changes.` The moves are pending, and they have to be applied to be written to state. After that apply, the next plan said `No changes.`

`terraform state mv` does the same thing from the command line. It changes state immediately, with no plan and no review, and it has to be run again in every copy of the state. A `moved` block is in the code, shows up in the plan, and is applied wherever the code is applied.

> Further reading: [Refactoring modules](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)

---

## `terraform state` surgery

**`state rm` makes Terraform forget a resource. It does not delete anything.** That makes it more dangerous than it looks, because the next plan wants to create something that already exists.

```
$ terraform state rm aws_budgets_budget.monthly
Successfully removed 1 resource instance(s).

$ terraform plan
# aws_budgets_budget.monthly will be created
Plan: 1 to add, 0 to change, 0 to destroy.

$ terraform apply
Error: creating Budget (ci-cd-lab-monthly): ... DuplicateRecordException:
A budget or resource with the same name but a different internalId already exists.
```

The budget collides because AWS enforces unique budget names. For a resource with a generated name, such as one using `name_prefix`, the apply would **succeed**, and you would have two.

The budget was adopted again with an `import` block: `Plan: 1 to import`, then `No changes.`

| Command | Changes AWS? | Blast radius |
|---|---|---|
| `state list` / `state show` | no | none, read-only |
| `state mv` | no | wrong address → the next plan destroys and recreates |
| `state rm` | no | the resource becomes invisible: survives `destroy`, collides on the next create |
| `-target` | yes | applies part of the graph; the rest is left in whatever state it is in |

`-target` is for getting out of a broken apply, not for daily use. A plan built with it is not the whole plan, and Terraform prints a warning saying so.

**Every one of these writes a new version of the state object, and versioning keeps the old ones.** One session of this project left 25 versions of `account/terraform.tfstate`. To undo a bad `state rm`, restore the previous version of the object. The 90-day lifecycle rule on this bucket sets how far back you can go.

---

## State holds secrets in plain text

`encrypt = true` encrypts the object at rest in S3. It does not encrypt the contents for the people who can read the object. Anyone with `s3:GetObject` on this bucket can read every value in every state file, including any marked `sensitive`. Project 6 showed this with the `tls_private_key` in `infra/sandbox`. So access to this bucket is access to every secret any stack has handled. Project 9 gives CI a role that can read it, and that role's policy is where this matters.

---

## Failure modes

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **State on a laptop** | no backend block | the only copy of state is one gitignored file | nothing, until the laptop is gone and the next apply fails with `AlreadyExists` |
| **No lock** | `use_lockfile` unset | two applies write state at the same time; the last write wins | both applies succeed; state describes neither |
| **Rename without `moved`** | resource moved into a module | Terraform sees a delete and a create | `5 to add, 5 to destroy` on a change that "only moved code" |
| **Drift read as a code change** | a console edit, then a normal `plan` | the reviewer thinks the diff is a code change | an update nobody wrote, with no "changed outside" note |
| **`state rm` as cleanup** | removing a resource "Terraform should not manage" | Terraform forgets it but AWS keeps it | a create that fails with `DuplicateRecordException`, or succeeds and makes a second one |
| **Lock test with no changes** | testing locking with a no-op apply | the first apply exits before the second starts | both succeed; locking looks broken, or looks tested when it was not |

---

## What went wrong while building this

- **The first lock test passed for the wrong reason.** See *Locking*: a no-op apply never holds the lock long enough to collide with anything.
- **A one-line override file is invalid HCL.** `terraform { backend "local" {} }` fails with `Argument definition required`, because a single-line block cannot contain a nested block. The override in `labs/04_trust/README.md` uses three lines.
- **Adding a backend block broke Lab 04.** A learner at Lab 04 applies `infra/ci-oidc` long before this bucket exists, and `terraform init` would ask for a bucket name. Lab 04 and the other stack READMEs now say to use a gitignored `backend_override.tf` with a local backend until Project 7.
- **The roadmap's evaluation said the refactor "produces `No changes.`".** The first plan with `moved` blocks says `0 to add, 0 to change, 0 to destroy`. `No changes.` only appears after the moves are applied.
