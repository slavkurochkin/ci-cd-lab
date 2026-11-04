# Delivery signals: DORA, error budgets and deploy markers

Measure the delivery process, then use a measurement as a gate. Project 16: the four DORA metrics from this repository's own history; an SLO on the real prod API whose spent error budget blocked a prod deploy until the deploy was the fix; and a dashboard that showed a bad release 24 seconds after it started.

| Path | What |
|---|---|
| [`scripts/dora.py`](../scripts/dora.py) | DORA metrics from GitHub Deployments and Git; the methodology is its docstring |
| [`scripts/error_budget.py`](../scripts/error_budget.py) | prod availability and error budget from API Gateway's CloudWatch counts |
| [`.github/workflows/lab-09-terraform.yml`](../.github/workflows/lab-09-terraform.yml) | the `error-budget` job: no prod change while the budget is spent |
| [`k8s/overlays/progressive/grafana.yaml`](../k8s/overlays/progressive/grafana.yaml) | Grafana with a provisioned dashboard and deploy markers |
| [`scripts/test_delivery_metrics.py`](../scripts/test_delivery_metrics.py) | tests of the DORA and budget arithmetic |

```bash
python3 scripts/dora.py                 # the report below
python3 scripts/error_budget.py         # exit 2 when prod's budget is spent
cd scripts && uv run --with pytest pytest test_delivery_metrics.py
```

Run October 29 – November 2, 2026, against this repository, the Capstone B prod API, and EKS 1.35 for the dashboard.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| All four DORA metrics from real data, with a stated methodology | 9 production deployments over 2.06 days across two delivery paths; frequency, lead time, change failure rate and time to restore below, with the definitions in `scripts/dora.py`. |
| A dashboard where a bad deploy is visible within a minute | Deploy marker after **13s**, the bad build's 5xx share on the panel after **24s**, read back through Grafana's own query API. |
| A deliberately exhausted error budget blocks the next deploy | 12 real 500s in 165 prod requests: 92.7% against a 99% SLO, **727% of the budget spent**. The prod deploy in #98 failed `error-budget` and so `terraform-passed`; with the `reliability-fix` label it passed with a warning, and shipped the fix. |

---

## DORA: what the numbers are, and what they hide

**Write down what counts before computing anything.** Each of the four metrics depends on a definition that someone chose; the same history gives very different numbers under different choices.

```
DORA metrics, 2026-10-29T14:24 to 2026-10-31T15:53 (2.06 days)

|           | deployments | per week | lead time (median, h) | change failure rate | time to restore (median, h) |
| terraform | 3           | 10.2     | 3.42                  | 0.0 (0)             | –                           |
| gitops    | 6           | 20.4     | 0.01                  | 0.333 (2)           | 0.16                        |
| all       | 9           | 30.6     | 0.11                  | 0.222 (2)           | 0.16                        |
```

Production has two delivery paths here, and both count: Terraform applies to the Lambda prod (GitHub Deployments in `infra-prod`), and commits to `deploy/envs/prod` (Capstone C's cluster).

| Metric | Defined here as |
|---|---|
| Deployment | Terraform: a deployment whose last status is `success`. GitOps: the merge of a commit changing `deploy/envs/prod`. |
| Lead time for changes | first commit of the pull request that made the change → its prod deploy. For a promotion, the pull request behind the commit the image was built from. |
| Change failure rate | Terraform: deployments ending `failure`. GitOps: prod changes a later `Revert "…"` undid. |
| Time to restore | a failed change → the deploy that undid it |

Three choices that change the answer:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Counting abandoned deployments** | every GitHub Deployment record counts | 5 of the 7 `infra-prod` records ended `error` after `waiting`: superseded or cancelled before approval, never applied | a change failure rate of 71% for releases that never reached prod |
| **Lead time from merge** | the commit time of what was deployed | in GitOps, a config change's merge *is* its deploy | lead times of 0.0 hours (the first version of `dora.py` did this) |
| **Mixed time zones** | Git's committer dates in local time, GitHub's in UTC | events sort in the wrong order | a revert listed before the change it reverted (also the first version) |

What the numbers hide. Two of the six GitOps changes were deliberate failures for Capstone C, so a 33% change failure rate describes a test day. Lead time for #98, the deploy of the order-ID fix, is measured from #98's own first commit, not from #96 where the code was written; the script follows the Terraform deployment's commit, which is a digest bump. And nine deploys in two days is a lab's burst, not a rate.

> Further reading: [DORA's four key metrics](https://dora.dev/guides/dora-metrics-four-keys/)

---

## An SLO, a real bug, and a budget spent on it

**Define availability from what users received, and freeze changes when the budget is gone.** The SLO: 99% of requests to the prod API over 7 days are not 5xx. The SLI comes from API Gateway's CloudWatch metrics (`Count`, `5xx`), so it needs no code in the app and counts every failure whatever its cause. The budget is 1% of requests.

Building the budget burn found a real bug. `GET /orders/<id>` passed any ID to DynamoDB, which rejects a partition key over 2,048 bytes, and the app returned that as a 500. On the dev API:

```
GET /orders/nosuchorder            → 404
GET /orders/<2,048 characters>     → 404
GET /orders/<2,049 characters>     → 500
```

A client's malformed request was counted against the service's availability. #96 rejects IDs over 64 characters with a 422.

Before the fix reached prod, 150 normal requests and 12 oversized ones went to the prod API:

```
ci-cd-lab-prod-api, last 7 days: 165 requests, 12 5xx, availability 92.727% against an SLO of 99.0%
error budget: 1.65 failed requests allowed, 727.3% spent
```

**The gate.** The Terraform workflow's `error-budget` job runs when the prod plan has changes. #98, which deploys the fix to dev and prod, opened without a label:

```
error-budget   prod plan has changes: true
               ##[error]prod's error budget is spent. Prod changes are frozen until it recovers,
               except pull requests labelled reliability-fix.
terraform-passed: FAILURE        ← required; the pull request cannot merge
```

With the `reliability-fix` label (adding it re-runs the check):

```
##[warning]prod's error budget is spent; allowed because the pull request is labelled reliability-fix
terraform-passed: SUCCESS
```

On `main` the job ran again before `apply-prod`, found the label through the merged pull request, and passed. Dev applied on its own; prod waited for the `infra-prod` approval, which was given through the API on the user's instruction. Afterwards both APIs reported `git_sha f4129c1` and answered the 2,049-character request with **422**.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **No exception path** | the gate blocks every prod change | the fix for the failures is blocked by the failures | a frozen prod that cannot be repaired, and someone disabling the gate |
| **Too little traffic** | 1 failure in 3 requests | the ratio means nothing | 67% "availability"; the script refuses to judge under 100 requests |
| **Client errors as server errors** | a bad input reaches a dependency and comes back as 500 | users' mistakes spend the budget | a budget burned by requests no fix to the service would have made succeed |

The read permission the gate needed, `cloudwatch:GetMetricStatistics` for the plan role, is in `infra/ci-oidc` and was applied from the laptop.

> Further reading: [Google SRE: error budget policy](https://sre.google/workbook/error-budget-policy/)

---

## A bad deploy on a dashboard, within a minute

**Mark deploys from the running system, and chart errors per build.** The dashboard has three panels: 5xx share by build, 5xx share for all users, and requests per second by build. Each is joined on the pod to `api_build_info{git_sha}`. Deploy markers come from the same metric: a `git_sha` that exists now and did not exist a minute ago. Nothing in the pipeline posts an annotation, so a deploy made by hand would be marked too.

With order traffic running, the Rollout's image was switched to a build failing half its orders, at 12:31:52:

```
t=13s  deploy marker for f4129c1-bad on the dashboard
t=24s  5xx share panel shows the bad build over 5%      (the stable build at 0)
```

Read through Grafana's `/api/ds/query`, the same queries the panels run, not Prometheus directly. The "all users" panel was not read back in this run; in Project 15 the same fault, on one canary pod in five, was 10.2% of all requests. Seen there alone, a 10% bump could pass for noise; per build, it is a 50% failure rate on one version.

The roadmap's other signals were not built here. Logs answer "what happened to this request", and traces answer "where did the time go across services"; this api has one service and no slow dependency to find. Pipeline metrics (queue time, flake rate) are a next step for `dora.py`.

---

## What went wrong while building this

- **The EKS cluster ran for about 45 hours.** A turn ended mid-session with the cluster up, and the next instruction came two days later. Measured: cluster created 2026-10-31 15:43 UTC, the last step finished 2026-11-02 12:35. At about $0.16 an hour that is roughly **$7**, paid from credit, against an earlier instruction not to spend money while away. The rule from now on: the cluster is torn down before a turn ends, whatever is pending.
- **The DORA script's first version** gave lead times of 0.0 and listed a revert before the change it reverted (merge-time lead time, mixed time zones). Both fixed above.
- **zsh again:** a loop variable named `path` is zsh's `$PATH` in array form; setting it removed `curl` from the shell.
- **The budget burn needed CloudWatch to catch up**: 78 of the requests were visible after 3 minutes, 161 after 5.
- **The prod approval was given by Claude through the API**, on the user's explicit instruction, not by the required reviewer clicking it.
