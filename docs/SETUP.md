# Setup

What you need, and when. Nothing here is required before the track that uses it — install as you go rather than up front.

```bash
make doctor
```

That prints the status of every tool, tagged with the track that first needs it, and a single `brew install` line for whatever is missing.

---

## Now — Track A (Projects 1–5)

**Tools:** `git`, `make`, `uv`, `node`, `gh`, and `actionlint`.

```bash
brew install uv node gh actionlint
gh auth login   # needs the 'workflow' scope to push .github/workflows changes
```

Confirm the sample app builds and passes locally, so a red pipeline later means a pipeline problem:

```bash
make test
make lint
```

### The GitHub repository

Track A needs a real repository, because a workflow that has never run is not verified.

```bash
git init
git add -A
git commit -m "CI/CD lab: curriculum, sample app, tooling"
gh repo create ci-cd-lab --public --source=. --push
```

**Make it public.** Public repositories get unlimited GitHub-hosted runner minutes; private ones get 2,000/month on the free plan. The security consequences of a public repository — fork pull requests, `pull_request_target`, secret exposure — are not a side effect to work around. They are Project 4's subject matter, and having them be real makes that project worth doing.

Protect `main` once your first workflow has run at least once (the check names only become selectable after they have reported):

```bash
gh api -X PUT repos/{owner}/{repo}/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["api", "worker"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

Docker Desktop is needed from Project 5 onward. Install it before then and leave it closed until you need it.

---

## Later — Track B (Projects 6–9)

**Tools:** `terraform`, `awscli`, `tflint`, `checkov`.

```bash
brew install hashicorp/tap/terraform terraform-linters/tap/tflint awscli checkov
```

### An AWS account

Use a **separate account** from anything you care about. A fresh account gives you the 12-month free tier, and more importantly it bounds the damage: `make aws-sweep` deleting the wrong thing in a dedicated lab account is an inconvenience.

Read [COST.md](COST.md) before your first `terraform apply`. It lists what this curriculum uses, what it deliberately never creates, and why.

```bash
aws configure          # or aws configure sso
aws sts get-caller-identity
```

Pin your account and region so the guardrails have something to check. Put these in your shell profile:

```bash
export AWS_LAB_ACCOUNT_ID=123456789012
export AWS_LAB_REGION=us-east-1
export AWS_REGION=$AWS_LAB_REGION
```

One region for everything. Two regions means two places to sweep, and the second one is where a forgotten resource bills you for a year.

In the Billing console, turn on **free tier usage alerts** — they fire at 85% of a free tier limit, which is the earliest warning available. Project 6's first real resource is a budget alarm; `scripts/aws-guard.sh` refuses to apply without one, and refuses again once month-to-date spend has reached it.

Set the budget to **$50/month**. Track B stays inside the free tier, but Track C runs a real cluster from Project 13, and $50 is high enough that an alert means something is wrong rather than something is busy.

Before any apply:

```bash
./scripts/aws-guard.sh terraform apply
```

After every destroy:

```bash
make aws-sweep
```

---

## Later still — Track C (Projects 10–14)

**Tools:** `kubectl`, `minikube`, `helm`, `argocd`, `doppler`, plus `terraform` and `awscli` from Track B.

```bash
brew install kubernetes-cli minikube helm argocd dopplerhq/cli/doppler
minikube start --cpus 2 --memory 4096
kubectl get nodes
```

**Projects 10–12 run locally on minikube and cost nothing.** That is where you break things on purpose, so a mistake should cost a `kubectl delete` rather than a fifteen-minute cluster rebuild.

`minikube stop` when you are not using it; it is a VM on your laptop and it is not free in battery.

### Projects 13–14 run on EKS

From Project 13 the cluster is real, because the lessons there — a runner that genuinely cannot reach it, pod identity, a load balancer that outlives its Service — have no local equivalent.

```bash
export AWS_LAB_REGION=us-east-1
export AWS_LAB_ACCOUNT_ID=<your lab account>

make eks-up      # ~15 min, starts billing at ~$0.21/hr
# ... work the lab ...
make eks-down    # destroys everything, then sweeps for orphans
```

`make eks-down` is the last command of every session. It is safe to run twice, and it deliberately does not trust `terraform destroy` — see [COST.md](COST.md) for what it does and why the order matters.

A four-hour session costs about **$0.84**. A cluster you forget about costs **$4.50/day**. Put both exports in your shell profile so the guard always knows which account it is allowed to touch.

---

## Track D (Projects 15–18)

**Tools:** `trivy`, `cosign`, plus Prometheus and Grafana installed into minikube by the labs themselves.

```bash
brew install trivy cosign
```

---

## Troubleshooting

**`make lab LAB=01` says a file exists and differs**
It is refusing to overwrite your work. `make reset LAB=01` discards your edits and restores the starter.

**`make verify` fails with `no lab matches '1'`**
The lab has not been built yet. `make status` lists what exists.

**Verifier tests are skipped rather than run**
Live tests skip when their prerequisite is missing: `gh` not authenticated, no cluster running, `actionlint` not installed. A skip is not a pass — a lab is finished when its live tests actually run.

**`gh` refuses to push a workflow file**
Your token lacks the `workflow` scope. `gh auth refresh -s workflow`.

**A required check is stuck pending forever**
A path filter skipped the job, and a skipped job never reports. Lab 02, Task F.
