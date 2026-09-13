# Cost

Tracks A and B cost **$0**. Track C costs **roughly $10–25/month** from Project 13,
because it runs on a real EKS cluster that you create at the start of a session
and destroy at the end of it.

That split is a design decision, and this document is where it is justified.

Read this before Project 6. Everything before that is free with no caveats.

---

## The rule

> If a resource bills by the hour whether or not you use it, it does not outlive the session that created it.

The earlier version of this rule was *"the curriculum does not create it"*, which
kept the bill at exactly zero and cost something real in exchange: Projects 13
and 14 had to teach deployment against a cluster that CI could reach trivially
and that had no cloud identity, no cloud load balancer, and no cloud networking.
The hardest and most valuable problems in delivery are the ones that only exist
when the cluster is somewhere else.

So one resource is now a deliberate exception, and the discipline moved from
*never create it* to *never leave it running*.

## The exception

| Resource | Rate | Why it is now in scope |
|---|---|---|
| **EKS control plane** | $0.10/hr | The reachability problem in Project 13 is only real if the cluster is genuinely unreachable from a runner. |
| **2 × `t3.medium` nodes** | $0.083/hr | Real nodes mean real scheduling, real evictions, and an actual `Pending` pod with an actual reason. |
| **NLB** (from a `Service`) | $0.023/hr | Created by Kubernetes, not Terraform. Learning that it outlives its Service is half of Project 13's teardown lesson. |

**About $0.21/hour, so about $4.50/day if you forget.**

A four-hour session costs **$0.84**. Twelve sessions a month costs **$10**.
A cluster left up for three weeks costs **$92** — that, and nothing else, is the
failure mode this document exists to prevent. The hourly rate is not the risk.
Forgetting is the risk.

## What this curriculum still never provisions

| Resource | Roughly | Why it is excluded |
|---|---|---|
| **NAT Gateway** | $32/mo + data | The classic surprise bill. The lab cluster uses public subnets with no private egress, so it needs no NAT. |
| **RDS instance** | $15/mo+ | Bills hourly. DynamoDB's always-free tier covers everything here. |
| **Fargate profiles** | varies | Managed node groups make the node visible, which is the point in Track C. |
| **Idle Elastic IPs** | $3.60/mo | Bills specifically *because* it is idle. |
| **A second cluster** | doubles everything | One cluster, one region, one place to sweep. Namespaces separate `dev` and `staging`, not clusters. |

If a lab asks you to create one of these, it is a bug in the lab.

## What the curriculum uses for free

| Service | Free tier | Expires? |
|---|---|---|
| **IAM** — users, roles, policies, OIDC providers, Pod Identity associations | Unlimited | Never |
| **DynamoDB** | 25 GB storage, 25 WCU + 25 RCU | **Never** |
| **Lambda** | 1M requests + 400,000 GB-seconds / month | **Never** |
| **CloudWatch Logs** | 5 GB ingest, 5 GB storage / month | **Never** |
| **AWS Budgets** | 2 budgets | **Never** |
| **SNS** | 1M publishes / month | **Never** |
| **S3** | 5 GB, 20k GET, 2k PUT / month | 12 months |
| **ECR** | 500 MB private storage / month | 12 months |
| **API Gateway** (HTTP API) | 1M requests / month | 12 months |
| **SSM Parameter Store** (standard) | Unlimited standard parameters | Never |

The four with a 12-month clock are the ones to watch if you work through this
slowly. If your account is older than a year, S3 and ECR start billing — at these
volumes, cents per month, but not zero.

**GitHub Actions**: unlimited runner minutes on a **public** repository. GHCR is
free for public packages.

**Projects 10–12** run on minikube and cost nothing. Kubernetes fundamentals,
Kustomize and Helm overlays, and the five broken deployments are all faster to
learn locally, where a mistake costs a `kubectl delete` instead of a rebuild.
Project 13 is where the cluster has to become real.

---

## Guardrails

### 1. A budget, created first

Project 6's first real AWS resource is an AWS Budget. Set it to **$50/month** with
alerts at 50%, 80% and 100%. That is well above the ~$25 a heavy month costs and
far below anything that would matter, so an alert means something is wrong rather
than something is busy.

### 2. `scripts/aws-guard.sh`

Wraps any apply. It refuses to proceed unless credentials resolve, the account
matches `AWS_LAB_ACCOUNT_ID`, the region matches the pinned `AWS_LAB_REGION`, a
budget exists, and month-to-date spend is still under it. It also warns when a
cluster is already running, because the expensive mistake is creating a second one.

### 3. `make eks-down` — the last command of every session

```bash
make eks-up      # ~15 minutes, starts billing
# ... work the lab ...
make eks-down    # destroys everything, then sweeps
```

`scripts/eks-down.sh` does not trust Terraform, and runs in the order AWS requires:

1. **Delete `LoadBalancer` Services first.** Kubernetes created those ELBs, so
   Terraform has never heard of them. Their ENIs sit in your subnets, and the VPC
   will not delete while they are there — this is why a naive `terraform destroy`
   hangs for twenty minutes and then fails.
2. `terraform destroy` for everything Terraform does own.
3. Delete any cluster and node group that survived step 2, directly through the API.
4. Sweep, and print what is still billing.

It is safe to run twice. Run it twice.

### 4. `make aws-sweep`

Lists every billable resource in the pinned region, split into **Metered**
(fine while you work, must be zero when you stop) and **Should never exist**.
An empty Metered section is the end of a session.

```bash
make aws-sweep
```

### 5. Teardown is part of the lab

Every AWS lab ends with a destroy and a sweep. Capstone C's deliverable is a
working delivery platform *and* an empty account.

---

## Checking your bill

```bash
make eks-cost      # this month, by service
```

Cost Explorer lags by up to 24 hours. Budget alerts are the fast signal; this is
the audit. Also turn on **free tier usage alerts** in Billing preferences.

## If something does cost money

1. `make aws-sweep` to find what exists.
2. `make eks-down` — it handles the ordering that `terraform destroy` gets wrong.
3. Sweep again. Destroy can partially fail and still exit 0 on a later run.
4. Anything left was created outside Terraform. Delete it in the console and work
   out how it got there; that is the actual lesson.

The two that reliably survive a clean destroy are **EBS volumes** left behind by a
PersistentVolume with `reclaimPolicy: Retain`, and **load balancers** created by a
Service that was deleted after the cluster. Both are in the sweep for that reason.

An AWS account you cannot confidently empty is one you will be afraid to
experiment in, which defeats the point of having a lab account.
