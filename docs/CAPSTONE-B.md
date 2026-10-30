# Capstone B — Reproducible Cloud Foundation

The api service on AWS Lambda, in environments that exist only because Terraform says so, created and destroyed by pull requests, at $0 billed.

## The result in one table

| Deliverable | Result |
|---|---|
| One PR stands up an environment from nothing | **#53**: six files under `infra/envs/staging/`, four of them identical to dev's. Plan: 15 to add. Applied on merge with no approval; `POST /orders` then `GET /orders/{id}` worked against staging's own table. |
| One PR destroys it | **#58**: one line, `enabled = false`. Plan: 15 to destroy. Applied on merge. Afterwards no staging function, API, table, role, log group or bucket existed, and `make aws-sweep` printed `Account is clean.` |
| A cost report showing $0.00 | October 2026 to date: **$0.0162** of usage (ECR $0.0144, S3 $0.0019), offset by Free-plan credits; **$0.00 billed**. Cost Explorer lags about a day, so the Lambda, API Gateway and DynamoDB usage from the same day is not in this figure. |
| Dev and prod run the api | Dev: live since the first apply's re-run. **Prod: planned (10 to add, nothing deleted) and waiting for a person to approve the `infra-prod` deployment.** |
| An architecture diagram and a runbook for "the apply failed halfway" | [Architecture](#architecture), and a [runbook](#runbook-the-apply-failed-halfway) written from the dev apply that did fail halfway. |

Contents: [Architecture](#architecture) · [The five integration challenges](#the-five-integration-challenges) · [Releases and immutable tags](#releases-and-immutable-tags) · [Runbook](#runbook-the-apply-failed-halfway) · [Failure modes](#failure-modes) · [What went wrong](#what-went-wrong-while-building-this) · [What is still open](#what-is-still-open)

---

## Architecture

```
                      laptop, rarely                         pull request → main, always
                      ──────────────                         ───────────────────────────
infra/state    S3 state bucket (versioned, locked) ◄──────── every stack's state
infra/ci-oidc  OIDC provider · tf-plan · tf-apply-nonprod
               tf-apply-prod · lambda boundary · public-pull
infra/ecr      ci-cd-lab/api, ci-cd-lab/worker ◄───────────── release images (v0.2.3)
infra/account  budget · artifacts bucket                              │ by digest
                                                                      ▼
                         infra/envs/<env>/  (dev, prod; staging came and went)
                         ┌────────────────────────────────────────────────────┐
  internet ──► API Gateway HTTP API ──► Lambda ci-cd-lab-<env>-api ──► DynamoDB│
               (throttle 5 rps, burst 10)  (image @ sha256:b3af845…)  <env>-orders
                         │                    │ role: <env>-api-lambda         │
                         │                    │ + permissions boundary         │
                         │                    └──► CloudWatch Logs (7 days)    │
                         │  S3 ci-cd-lab-<env>-<account>  (data bucket)        │
                         └────────────────────────────────────────────────────┘
```

**Two kinds of stack, applied two ways.** What changes rarely and writes IAM broadly (`state`, `ci-oidc`, `ecr`, `account`) is applied from a laptop. What changes often (`infra/envs/*`) is applied only by CI: a pull request plans it, a merge applies nonprod, and prod waits for a person.

Every environment root is the same three files plus `versions.tf`, which differs only in the backend key. What makes dev dev is `terraform.tfvars`:

```hcl
environment          = "dev"
api_image_digest     = "sha256:b3af8458ebb6c9748be00d87cff0e4bfcb0fbaba45d54ff2ce514adf5232c553"
data_noncurrent_days = 7
```

---

## The five integration challenges

### 1. The registry before the image, and the image before the environment

**Each layer exists before the one that needs it, and none of them creates the layer above.** The ECR repositories live in `infra/ecr` and outlive every environment. A release pushes an image into them. An environment names that image by digest. Applying an environment never builds an image, and building an image never touches an environment.

One manual step is left: copying a new release's digest into `terraform.tfvars`. That edit is the deploy, and it gets planned, policy-checked and, for prod, approved. Automating it as a pull request the release opens hits a GitHub rule: a pull request created with `GITHUB_TOKEN` does not trigger workflows, so its required checks would never report. Doing it properly needs a GitHub App token, which this curriculum does not set up.

### 2. An apply role that creates IAM roles without escalating itself

**The apply role may create a role only with a permissions boundary attached, and can never remove or rewrite that boundary.** A role's effective permissions are its own policy intersected with its boundary, so whatever inline policy CI writes, the role it creates can only write function logs and read and write an orders table.

Checked with `iam:SimulateCustomPolicy` against the planned policies before anything was applied:

| Role | Request | Decision |
|---|---|---|
| nonprod | `CreateRole` staging role, with the boundary | allowed |
| nonprod | the same, with no boundary / with `AdministratorAccess` as boundary | implicitDeny |
| nonprod | `CreateRole` named `ci-cd-lab-ci` | implicitDeny |
| nonprod | `CreateRole` with prod's role name | explicitDeny |
| nonprod | `DeleteRolePermissionsBoundary` | explicitDeny |
| nonprod | `PassRole` to Lambda / to EC2 | allowed / implicitDeny |
| nonprod | prod's function, prod's state file, the state bucket, the artifacts bucket | explicitDeny |
| prod | anything named for dev | implicitDeny |

Then for real: dev's first apply created `ci-cd-lab-dev-api-lambda` with the boundary attached, from CI, under the nonprod role.

Roles are per tier, not per environment: `nonprod` matches `ci-cd-lab-*` by name and has prod, the state bucket and the artifacts bucket denied explicitly. That is what lets a new environment be one pull request with no IAM change.

> Further reading: [Permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)

### 3. The image digest and the state must not drift apart

**The digest lives in Git, and the nightly drift check compares it with what Lambda runs.** Moving dev's function to another image from the CLI (0.2.2 instead of 0.2.3) opened issue #54 on the next drift run, started by hand rather than waiting for 06:17 UTC. The issue names both digests:

```
  ~ image_uri = "…/ci-cd-lab/api@sha256:b3af8458…" -> "…/ci-cd-lab/api@sha256:be0703bf…"
```

Putting it back closed #54 on the following run, with no one editing the issue.

**The digest is the platform manifest, not the image index.** Every image the pipeline pushes is an OCI index holding an `amd64` manifest and a provenance attestation. Lambda rejects an index. Pointing it at the `amd64` manifest inside the index (`b3af845…`, while the index is `6201382…`) worked first time, and the attestation stays attached to the index. The common fix, turning attestations off, would have undone Capstone A.

The digest choice exposed one more coupling: ECR's lifecycle rule kept the 10 most recent tagged images, so a deployed image would expire after ten more merges. A new first rule keeps the 20 most recent releases (`*.*.*`) before the keep-10 rule can count them.

### 4. A state backend for the thing that creates the state backend

Solved in Project 7 (`infra/state`): the bucket was created with the CLI, adopted with `import` blocks, and then given its own state. Every stack here, and every environment, keeps state in it under its own key with S3 native locking.

### 5. Free tier is per account

**Two environments cost nothing because nothing bills while idle.** Lambda, HTTP API and DynamoDB on demand bill per request; logs keep 7 days; the data buckets are empty. The cost guard is the API's throttle: 5 requests a second, burst 10. Past that, API Gateway answers 429 and Lambda never runs, so an anonymous caller cannot run up a bill. Reserved concurrency would have been the other guard. It was not used, because AWS refuses any reservation that leaves fewer than 10 unreserved, and this account's limit is 10 (`get-account-settings`: 10 concurrent, 10 unreserved).

This account is on AWS's Free plan with credits (USD 179.77 left, expiring March 2027). "Billed $0.00" therefore says less than it seems, which is why the table at the top reports usage before credits as well.

---

## Releases and immutable tags

**A release pushes exactly one tag per image: its version.** It took four releases to get there, because Capstone A's release added three tags that exist to move, and the repositories refuse to move a tag.

| Release | Failed on | Why | Fix |
|---|---|---|---|
| v0.2.0 | worker `sha-7601b80…` | `main` had already pushed that tag for the same commit | #48: no `sha-` tag on a release build |
| v0.2.1 | `0.2` | a floating minor tag; v0.2.0 had created it | #49: no `major.minor` tag |
| v0.2.2 | `latest` | `metadata-action` adds it to every release by default; v0.2.1 had created it | #50: `flavor: latest=false` |
| v0.2.3 | — | released | |

Each failure pushed some tags first and then stopped, and an immutable tag cannot be re-cut. So each one burned its version number. v0.1.0 never hit any of this because it was the only release before ECR existed.

**The release rebuilds; it should promote.** Worker's `sha-7601b80…` from `main` is `sha256:0d98f0d5…`; worker `0.2.0`, built from the same commit by the release 70 minutes later, is `sha256:931bd3b5…`. Same source, two images. The image that ships is not the one `main` tested. Promoting would mean re-tagging `main`'s image. The obstacle here is Lab 02's path filter: `main` only builds a service that changed, so at a release commit there is often no image of that commit to promote.

Two more release problems were found on the way:

- **ECR Public rate limits.** The api image copies the Lambda Web Adapter from `public.ecr.aws`, where anonymous pulls get 1 per second and 500 GB a month. GitHub's runners share IPs, and builds failed with `toomanyrequests: Data limit exceeded` four times. Publishing builds now log in with the CI role. Pull request builds assume `ci-cd-lab-public-pull`, a role that can only get an ECR Public login token. That is safe to give a pull request, because the token pulls only public images. Fork pull requests get no OIDC token and stay anonymous.
- **A HIGH CVE on `main`'s lock file.** The first api build failed the Trivy gate on `urllib3` 2.7.0 (CVE-2026-97687, CVE-2026-97689). Nothing in the change caused it: the advisories were new, and `main` would have failed the same way on its next build.

> Further reading: [ECR Public quotas](https://docs.aws.amazon.com/AmazonECR/latest/public/public-service-quotas.html), [Lambda container images](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)

---

## Runbook: the apply failed halfway

**Read what state recorded before changing anything, fix the cause, and run the same pipeline again. Do not delete what was created, and do not apply from a laptop.** A failed apply keeps what it finished in state, so the next plan contains only what is left.

This is what happened on dev's first apply, and the order it was handled in.

**1. Find out what exists.** The apply log lists each `Creation complete` and each `Error`. Dev's first apply:

```
aws_cloudwatch_log_group.api      Creation complete
aws_apigatewayv2_api.http         Creation complete
aws_iam_role.lambda               Creation complete
aws_dynamodb_table.orders         Creation complete after 14s
aws_iam_role_policy.lambda        Creation complete
aws_lambda_function.api           Error: AccessDeniedException: Lambda does not have permission to access the ECR image
aws_apigatewayv2_stage.default    Error: not authorized to perform: apigateway:TagResource
```

`terraform state list` (or the next plan) confirms it: the five completed resources are in state. Nothing was orphaned.

**2. Check the lock.** A cancelled or crashed apply can leave `envs/<env>/terraform.tfstate.tflock` behind. Read its `Who` and `Created`, confirm that run is finished, then `terraform force-unlock <ID>`. Dev's failure released its lock normally.

**3. Fix the cause, not the symptom.** Both errors were missing permissions, and both were fixed where they belong:

- Lambda pulls an image as the Lambda service, not as the caller, so the repository policy on `ci-cd-lab/api` now allows `lambda.amazonaws.com` for functions named `ci-cd-lab-*`.
- `apigateway:TagResource` is its own action, not one of the HTTP verbs; both apply roles got it, and nonprod's prod deny covers it.

**4. Run the same pipeline again.** Re-running the Terraform workflow on `main` planned only what was missing and applied it. The completed resources were not touched.

**5. Confirm.** The next plan was `No changes.`, and the API answered.

What not to do, and why:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Delete what was created** | "start clean" by removing the role or table by hand | state still lists them | the next plan wants to re-create resources it thinks exist, or refresh fails on missing ones |
| **Apply from a laptop** | your credentials can do it, CI's could not | the fix is never tested in the path that failed | the next CI apply fails the same way |
| **`state rm` the failed resources** | clearing the error | Terraform forgets resources that may exist | `AlreadyExists` on the next create |
| **`-target` the rest** | apply only what failed | everything that depends on it is planned against a partial graph | a plan that is not the whole plan, and a warning saying so |

---

## Failure modes

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Index digest given to Lambda** | the digest `docker push` printed, or the tag's digest | Lambda rejects an OCI image index | `CreateFunction` fails with an image manifest error |
| **Deployed image expired** | a keep-N rule counting every tagged image | ten merges later the running image is deleted | nothing, until the function has to pull again |
| **Repository policy missing** | the apply role can read the image | Lambda pulls as the Lambda service | `Lambda does not have permission to access the ECR image` |
| **A moving tag in an immutable registry** | `latest`, `0.2`, or a tag pushed twice | the push of that tag is refused after earlier tags succeeded | a failed release and a burned version number |
| **Pending prod approval blocks everything** | one concurrency group for every run on `main` | each later run waits behind the approval | dev and staging stop applying until someone approves prod |
| **Account ID in public comments** | plan comments and drift issues quote whole plans | ARNs and bucket names contain it | the ID the repository keeps out of every file, in a public comment |

---

## What went wrong while building this

- **Every release before v0.2.3 failed**, each on a different moving tag. See [Releases and immutable tags](#releases-and-immutable-tags).
- **The first CI plan of the api failed** on `ecr:DescribeImages`. The `aws_ecr_repository` data source lists images though the module only needed the URL. The URL is now built from the account ID and region, which needs no permission.
- **The module's tests passed on a provider version the environments do not use.** `aws_region.region` exists only in provider 6.x. A module has no lock file, so its tests ran on 6.x; the environments pin 5.100 and failed. `.name` works on both.
- **Dev's first apply failed halfway.** See the runbook.
- **The IAM simulator rejected policies over 2,000 characters**, and two zsh modifiers (`$A:r`, `$F:c`) mangled ARNs in the test script before any IAM was checked. The policies were split into statement groups; the simulator evaluates the list together, so the decisions are the same.
- **A prod approval nobody had given held up three ready pull requests.** Fixed by #57; two older runs waiting on prod were then cancelled, so the one prod approval left is for the newest plan.
- **The pipeline published the AWS account ID** in plan comments since Project 9 and in drift issue #54. #56 redacts both; job logs are public too and are not redacted.
- **`make aws-sweep` called dev's resources findings** once dev was meant to exist. It now knows which environments are live.

---

## What is still open

- **API Gateway resources cannot be scoped by name.** The nonprod role is denied any write to an API tagged `Environment=prod`, but a stage or route does not carry its API's tag, so nonprod could still modify a prod API's routes in principle.
- **GitHub created `infra-staging` with no protection rules** the first time a job named it. Anyone who can push a workflow to a branch could use it to assume the nonprod role. Nonprod cannot reach prod, but the environment should be restricted to `main`.
- **The digest bump is a hand edit** (challenge 1).
- **`/version` reports `0.1.0`** in every environment: releases never update the app's own version. The `git_sha` it reports, `b59ff7d`, is the v0.2.3 commit, so the stamped SHA is the reliable identity.
- **`infra/envs/staging/` still exists** with `enabled = false`, an empty state file (618 bytes), and the `infra-staging` GitHub environment. Removing them is a cleanup pull request.
- **`GET /orders/{id}` returns `72` where `POST /orders` returned `72.0`.** DynamoDB's `Decimal` comes back as an integer when it is whole.
