# infra/ci-oidc

Credential-free AWS access for GitHub Actions. **$0/month**, and meant to stay
applied.

```bash
cp terraform.tfvars.example terraform.tfvars   # set github_repo
terraform init && terraform apply              # ~10 seconds, 2 resources
```

Unlike `infra/eks`, there is no teardown step. IAM roles, policies and OIDC
providers are free, so this stack has no reason to be destroyed at the end of a
session and every reason to keep existing.

## Why this is separate from infra/eks

An AWS account may hold **exactly one** OIDC provider per issuer URL. Keeping
this inside the cluster stack would mean a second stack needing GitHub OIDC
fails with `EntityAlreadyExists`, and the trust relationship would be destroyed
every time the cluster came down.

The lifetimes are different: the cluster exists for a session, this exists for
years. Resources with different lifetimes belong in different stacks.

## What it creates

| | Cost |
|---|---|
| GitHub OIDC provider (account-level) | $0 |
| `ci-cd-lab-ci` role, assumable only by one repository | $0 |

**No policies are attached.** `sts:GetCallerIdentity` requires no permission, so
the role proves authentication works while granting nothing. Project 6 attaches
Terraform permissions when there is something to manage; `infra/eks` attaches
its own cluster-scoped policy to this role by name.

## The security boundary

One line, in the trust policy:

```hcl
"token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
```

Omit it and any repository on GitHub can assume this role. Widen it to
`repo:owner/*` and so can every repository you own, including one you fork
years from now.

### The sub claim has two spellings

GitHub is moving from `repo:owner/name:context` to an **immutable** form with
numeric IDs embedded:

```
repo:slavkurochkin@67211311/ci-cd-lab@1367903510:pull_request
```

The IDs survive a rename or an ownership transfer. A policy pinned to names
alone can be defeated by renaming a repository out from under it, which is why
the format changed.

The trust policy lists both, and a `StringLike` list matches if any entry does.
**This is the failure mode to remember:** a policy with only the old spelling
passes `terraform validate`, plans correctly, and is rejected only when a real
token arrives. The error is `Not authorized to perform
sts:AssumeRoleWithWebIdentity`, which names no cause. The actual claim is in
CloudTrail under `userIdentity.principalId`:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 1
```

### Branch scope

The trailing `:*` allows any branch, tag and pull request. That is fine while
the role grants nothing, and you want it working from feature branches
throughout Track B. **Narrow it to `:ref:refs/heads/main` before attaching any
policy that can change infrastructure.**

## Proving it works

`.github/workflows/aws-identity.yml` assumes this role and calls
`aws sts get-caller-identity`. Two things to notice in the run:

- `gh secret list` is empty. No access key exists anywhere.
- The workflow needs `permissions: id-token: write`. That is the permission to
  *request a token about itself*, not permission to write to the repository.

## If you lose the state file

`infra/eks` tolerates a lost state file because `make eks-down` finds and
deletes resources without Terraform's help. This stack has no such fallback:
Terraform will try to create an OIDC provider that already exists and fail.

Recovery is `terraform import`, not a sweep:

```bash
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
terraform import aws_iam_role.ci ci-cd-lab-ci
```

That asymmetry is the concrete argument for remote state, which is Project 8.
