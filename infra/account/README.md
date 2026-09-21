# infra/account

Account-level resources that are effectively free and meant to persist: an S3
bucket and the budget.

```bash
cp terraform.tfvars.example terraform.tfvars   # set budget_email
terraform init && terraform apply
```

## The bucket is five resources, not one

```
aws_s3_bucket
aws_s3_bucket_versioning
aws_s3_bucket_server_side_encryption_configuration
aws_s3_bucket_public_access_block
aws_s3_bucket_lifecycle_configuration
```

A bucket is not one object with settings. It is a bucket plus four independent
configurations, **each of which can simply be absent** — and a bucket with none
of them is a valid bucket that is versionless, unencrypted, and potentially
public.

That is why "we have an S3 bucket" says nothing about whether it is safe, and
why Project 9 runs a policy scanner over exactly this.

**All four public-access settings, deliberately.** Each blocks a different
route:

| | Blocks |
|---|---|
| `block_public_acls` | new ACLs granting public access |
| `ignore_public_acls` | ACLs that already exist |
| `block_public_policy` | new bucket policies granting public access |
| `restrict_public_buckets` | policies that already exist |

Setting two of the four is the usual near-miss, and it leaves whichever route
was already open still open.

**Versioning has a second half.** It makes an overwrite recoverable, and it
means deleted objects keep costing storage until something removes them. The
lifecycle rule expiring noncurrent versions after 30 days is not optional
tidiness — without it the bill grows with the number of *edits*.

## The budget is a lesson about drift

This budget existed before this module did. It was created with the AWS CLI
while setting the account up, and Terraform did not know about it.

That gap has a name. A resource that exists in the account but not in state is
**invisible to `plan`, survives `destroy`, and collides with any apply that
tries to create it.** The first plan here said:

```
# aws_budgets_budget.monthly will be created      ← it already exists
Plan: 6 to add, 0 to change, 0 to destroy.
```

`terraform import` closes it:

```bash
terraform import aws_budgets_budget.monthly "<account-id>:ci-cd-lab-monthly"
```

After which the same plan said something different and true:

```
# aws_budgets_budget.monthly will be updated in-place
Plan: 5 to add, 1 to change, 0 to destroy.
```

The update was real: the CLI-created budget had one notification, and this
module declares two. **Import does not make the difference go away — it makes
the difference visible.** That is the whole point, and it is Project 7's
subject.

## Two notifications, on purpose

| Type | Threshold | Answers |
|---|---|---|
| `FORECASTED` | 80% | "you are on track to exceed this" |
| `ACTUAL` | 100% | "you have exceeded this" |

A budget that only reports actual spend is a receipt. A forecast can be wrong
in both directions, which is why both exist.

**A budget is a tripwire, not a cap.** AWS does not stop anything when one is
exceeded; it sends an email. Treating it as a limit is the mistake that turns a
forgotten cluster into a surprise.

## Teardown

There isn't one. These persist, and `make aws-sweep` lists them under
*"Persistent by design"* rather than as findings — a sweep that is red when
everything is correct is a sweep nobody reads.
