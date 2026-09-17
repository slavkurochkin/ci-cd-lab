# Lab 04 — Trust: Permissions, OIDC & Supply Chain

> **Roadmap:** Project 4 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Get to zero long-lived cloud credentials in this repository, and understand every place a pipeline can be attacked.

---

## Before you start

**This lab's files already exist in solved form on `main`.** Project 4 was worked from the roadmap before the lab was written, so installing the starters replaces working configuration.

Work on a branch:

```bash
git switch -c lab-04
make reset LAB=04          # overwrite the solved files with the starters
```

To abandon the attempt and get your working setup back:

```bash
git checkout main -- .github/workflows/aws-identity.yml \
                     .github/workflows/security.yml \
                     .github/zizmor.yml .github/dependabot.yml
```

`infra/ci-oidc/` is **not** part of the starter. It is complete, commented for reading, and already applied to your AWS account — resetting it while the real provider exists would create drift Terraform cannot see. Read it; do not rewrite it.

---

## Concepts

### The credential you never issued cannot leak

The normal way for a pipeline to reach a cloud account is an access key pasted into secret storage. That key has three properties you cannot fix:

- It **never expires**. It works until someone remembers to delete it.
- It **works from anywhere**. AWS cannot tell your runner from a stolen backup.
- You **find out late**. A leaked key is discovered by its effects.

Rotating it, scoping it, and storing it carefully reduce the damage. None of them remove the key.

**OIDC removes the key.** The pipeline proves who it is and receives a credential that expires in an hour. `docs/OIDC.md` explains the mechanism in full — read it before Task C, not after.

> Further reading: [GitHub Docs — About security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)

---

### Permissions: the default is not the same as a decision

Every job gets a `GITHUB_TOKEN`. What it can do is decided by the repository default unless the workflow says otherwise.

A safe default is not the same as a safe workflow. The default is a setting in a web UI that anyone with admin can change, and changing it silently re-permissions every job in the repository. A `permissions:` block travels with the file, is reviewed with the file, and cannot be widened by a setting.

**`id-token: write` is the one people get wrong**, because the name reads like repository write access. It is not. It grants the right to *ask GitHub for a signed statement about this workflow run*. Without it the OIDC token request fails before AWS is ever contacted.

---

### A tag is a pointer, not a version

`uses: some/action@v4` names a **tag**, and the person who owns that repository can move it whenever they like. If their account is compromised, `v4` can be repointed at malicious code, and your next run executes it with your token.

A commit SHA cannot be changed after the fact. That is the whole argument.

| | What it is | Can it change under you |
|---|---|---|
| `@v4` | a moveable pointer | yes, silently |
| `@11d5960a…` | a specific commit | no |

Pinning creates a second problem: a pin you never update stops receiving fixes. **A pin without an update mechanism is a slow leak of a different kind**, which is what Task D is about.

> Further reading: [GitHub Docs — Using third-party actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)

---

### Two ways an update mechanism goes wrong

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Too eager** | no cooldown | a version is proposed the day it appears, which is also the day a compromised maintainer would publish one | a routine-looking pull request, green, indistinguishable from any other |
| **Too bundled** | every update type in one group | one pull request carries fifteen major version jumps across five actions | tests fail and name none of the five possible causes |

The fix for the first is a waiting period. The fix for the second is to bundle only what carries no promised breakage, and let majors arrive alone.

---

### The scanner is the thing that enforces the rule

Writing "we pin actions to SHAs" in a contributing guide is a wish. A check that fails the build is a rule.

`zizmor` audits workflows the way a linter audits code, and it treats an unpinned action as an **error**. Putting it in CI therefore does two jobs at once: it catches the class of mistake you have not thought of, and it enforces Task C's pinning without a separate script.

**Suppress by rule, never by severity.** `--min-severity=medium` silences one finding you disagree with and every future low finding you have not seen yet. Naming the rule in a config file, with a comment, keeps the disagreement visible and reviewable.

> Further reading: [zizmor — audit documentation](https://docs.zizmor.sh/audits/)

---

### What OIDC does not do

It proves **who** you are. It says nothing about **what you may do**.

A role can be assumable and still permitted to do nothing at all — which is exactly how `infra/ci-oidc` is configured, because it exists to demonstrate the login. Permissions are a separate document attached to the role.

Keep the two questions apart, because the same split reappears in every system you will meet:

- **Authentication:** are you who you say you are?
- **Authorization:** are you allowed to do this?

---

## Setup

```bash
git switch -c lab-04
make reset LAB=04
```

The AWS side is already applied. Get the role ARN and make it available to the workflow:

```bash
cd infra/ci-oidc && terraform output -raw role_arn
gh variable set AWS_CI_ROLE_ARN --body "$(terraform -chdir=infra/ci-oidc output -raw role_arn)"
```

A **variable**, not a secret. An ARN is an identifier; treating it as a secret implies the security comes from its name rather than from the role's trust policy.

If `infra/ci-oidc` has never been applied:

```bash
cd infra/ci-oidc
cp terraform.tfvars.example terraform.tfvars   # set github_repo and the two numeric IDs
terraform init && terraform apply
```

It costs **$0** and is meant to stay applied.

---

## Tasks

### Task A — Declare what the workflow may do (`TODO(lab-04-a)`)

Covers: least privilege, and why a default is not a decision.

Add a top-level `permissions:` block to `.github/workflows/aws-identity.yml` granting the least this workflow needs.

**What to observe:**
- Check the repository default first: `gh api repos/{owner}/{repo}/actions/permissions/workflow`. Note that yours is already safe, and that this task is still worth doing.

**Questions to reflect on:**
- Who can change that default, and would anyone notice?

---

### Task B — Ask for a token (`TODO(lab-04-b)`)

Covers: `id-token: write`, and why its name misleads.

Add a job-level `permissions:` block to the `whoami` job.

**What to observe:**
- Try it without this first. The failure happens before AWS is contacted, which is a different error from a trust policy mismatch and worth being able to tell apart.

---

### Task C — Assume the role and prove it (`TODO(lab-04-c)`)

Covers: OIDC end to end, SHA pinning, and the difference between a user and a session.

Call `aws-actions/configure-aws-credentials`, pinned to a commit SHA, reading the ARN from `vars.AWS_CI_ROLE_ARN`. Then call `aws sts get-caller-identity` and **fail the job unless the ARN is an assumed-role session.**

**What to observe:**
- `gh secret list` is empty, and stays empty. Nothing was stored.
- The ARN in the log starts `arn:aws:sts::` and contains `assumed-role/`. A long-lived IAM user would answer the same call just as happily — checking for the session is the difference between proving it and assuming it.

**If it fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`:** that error names no cause. The actual claim GitHub sent is in CloudTrail under `userIdentity.principalId`. `docs/OIDC.md` has the lookup command and explains the two spellings of the `sub` claim.

**Questions to reflect on:**
- The role ARN is in the workflow file in plain text. Why is that safe, and what would have to be true for it not to be?

---

### Task D — Keep the pins current (`TODO(lab-04-d1/d2/d3)`)

Covers: the cost of pinning, cooldowns, and grouping.

In `.github/dependabot.yml`:

1. Cover every directory that holds pinned actions, not just `/`.
2. Add a cooldown.
3. Group the update types that carry no promised breakage, and leave majors ungrouped.

**What to observe:**
- Find the composite action's pins: `grep -r 'uses:.*@' .github/actions/`. With `directory: /`, Dependabot never sees them, and nothing reports that.

**Questions to reflect on:**
- A cooldown delays security fixes as well as attacks. What length would you defend, and to whom?

---

### Task E — Check the pipeline itself (`TODO(lab-04-e1/e2)`)

Covers: workflow static analysis, and suppressing findings honestly.

1. In `.github/workflows/security.yml`: run `zizmor` on pull requests, pushes, and a schedule, failing on any finding. Install it from PyPI at a pinned version.
2. In `.github/zizmor.yml`: suppress the one rule this repository disagrees with, and write down why.

**What to observe:**
- Run `zizmor --offline .github/` before you configure anything. Read all of it.
- After it is green, unpin one action back to a tag and run it again. The job fails. **That is the pin rule becoming enforceable rather than aspirational.**

**Questions to reflect on:**
- Which is more honest when you disagree with a finding: a config entry naming the rule, or raising the severity threshold? What does each one hide?

---

### Task F — The deployment gate (no TODO; this is repository configuration)

Covers: environments, and what they do to the OIDC subject.

Create a `production` environment with a required reviewer and deployments restricted to protected branches:

```bash
gh api -X PUT repos/{owner}/{repo}/environments/production --input - <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": YOUR_USER_ID }],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
```

Then add `environment: production` to a job and dispatch it.

**What to observe:**
- The job sits in *Waiting*. It has not started.
- Once approved, the OIDC `sub` claim gains `:environment:production`.

That suffix is the part that matters. A role requiring it **can only be assumed from a job a human approved** — not by opening a pull request, not by pushing to a branch. It is what turns an environment from paperwork into a mechanism, and it is what Project 6's Terraform role will need.

---

## Verify

```bash
make verify LAB=04
```

| Test | What it proves |
|---|---|
| `test_workflow_declares_permissions`, `..._least_privilege` | Task A |
| `test_job_requests_an_id_token` | Task B |
| `test_assumes_a_role`, `..._role_arn_is_not_a_secret` | Task C: the role is assumed, and its ARN is not treated as a secret |
| `test_identity_is_checked` | Task C: the job proves it got a *session* |
| `test_dependabot_covers_the_composite_action` | Task D1 |
| `test_dependabot_has_a_cooldown` | Task D2 |
| `test_major_updates_are_not_grouped` | Task D3 |
| `test_security_workflow_runs_on_changes_and_on_a_schedule` | Task E1 |
| `test_security_workflow_runs_zizmor` | Task E1, pinned |
| `test_zizmor_config_suppresses_by_rule_not_by_severity` | Task E2 |
| `test_third_party_actions_are_pinned` | Task C, across both workflows |
| `test_the_identity_workflow_has_actually_run` | it worked, not just parsed |

That last one is the only test that cannot be satisfied by editing a file, and it is the one that matters. Everything above it reads YAML. A trust policy can be valid, plan correctly, match every published example, and be rejected the first time a real token arrives.

---

## Key lesson

The credential you never issued is the one that cannot leak. OIDC is not a convenience feature; it removes an entire category of incident.

And the second lesson, which this lab teaches by accident: **passing every check you can run offline proves nothing about the parts you cannot.** Three of the four things that went wrong while this project was first built were valid configuration that failed on first contact with a real request.
