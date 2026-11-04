# Preview environments and break-glass

A preview per pull request, a namespace each, behind one load balancer; and a way to deploy when CI is down that leaves a record. Project 18, part 3.

| Path | What |
|---|---|
| [`deploy/apps/previews.yaml`](../deploy/apps/previews.yaml) | ApplicationSet: one Application per open pull request labelled `preview` |
| [`deploy/preview/`](../deploy/preview) | what a preview runs: the api, its own DynamoDB Local, a ResourceQuota and a LimitRange |
| [`deploy/apps/traefik.yaml`](../deploy/apps/traefik.yaml) | the one ingress controller and its one NLB |
| [`.github/workflows/preview.yml`](../.github/workflows/preview.yml) | builds `api:pr-<n>-<sha>`, deletes it when the pull request closes |
| [`.github/workflows/preview-reaper.yml`](../.github/workflows/preview-reaper.yml) | removes the label from previews older than 72 hours |
| [`scripts/preview-capacity.sh`](../scripts/preview-capacity.sh) | fills the cluster with previews until a pod goes `Pending` |
| [`scripts/break-glass.sh`](../scripts/break-glass.sh), [`break-glass-audit.yml`](../.github/workflows/break-glass-audit.yml) | a deploy without CI or review, and its audit issue |

Run November 4, 2026, 02:15–02:55 UTC, on EKS 1.35 with three `t3.small` nodes; break-glass drilled on November 3 without a cluster.

---

## Evaluation (part 3)

| Roadmap check | Result |
|---|---|
| No orphaned preview environment survives a closed pull request | Closing #119: Application and namespace gone after **103s**, image deleted 6s after the close. #120, left open, was reaped: label removed, comment posted, image deleted, namespace gone **115s** after the reaper ran. No `pr-*` namespace was left at the end. |
| Five simultaneous previews cost the same as one | Four ran at once (the cluster's ceiling, below), all through one NLB. A preview adds an Ingress rule and two pods, no billed resource. |
| `aws elbv2 describe-load-balancers` returns exactly one entry | **1** before the first preview, with four running, and after the last was deleted; `aws elb` (Classic): **0**. |
| You can state the preview ceiling as a number, and the resource that imposes it | **4 previews.** The fifth's pod: `0/3 nodes are available: 1 Insufficient memory, 3 Too many pods`. Pods per node, with CPU at 27–34%. |
| A break-glass path that works when CI is down and files an audit issue | Drill: signature verified, commit pushed, issue filed in **6.4s** with no workflow involved. A hand-made push without the script got its own issue from the audit workflow. |

---

## A namespace per pull request

**Isolate a preview in a namespace with a quota, and trigger its life and death from the pull request's state, not from events.** Argo CD's ApplicationSet asks GitHub every two minutes for open pull requests labelled `preview` and keeps one Application per match. A pull request that closes, or loses the label, stops matching, and its Application is deleted. The Application's finalizer then deletes everything it created, including the `pr-<n>` Namespace, because the Namespace is one of its manifests and not made by `CreateNamespace=true`, which Argo CD never deletes.

Two previews, each answering only for its own pull request:

```
pr-119: {"git_sha":"d2c343ac…","environment":"preview"}     #119 head d2c343a
pr-120: {"git_sha":"632aaf83…","environment":"preview"}     #120 head 632aaf8
order created in pr-119: 200 from pr-119, 404 from pr-120
order created in pr-120: 404 from pr-119, 200 from pr-120
quota in use, pr-119: pods 2/4, requests.cpu 100m/300m, requests.memory 352Mi/768Mi
```

The manifests come from `main`; only the image comes from the pull request. If previews rendered the pull request's own `deploy/preview`, a pull request could delete its own ResourceQuota. The cost is that a change to the Kubernetes manifests is not previewed. Neither is anything cluster-scoped (CRDs, webhooks, the admission policies) or anything in AWS (the real table, Pod Identity): those changes need dev.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Namespace made by CreateNamespace** | the namespace is not one of the Application's resources | deleting the Application leaves it | empty `pr-*` namespaces piling up, each holding its quota and secrets |
| **Preview of its own manifests** | the ApplicationSet renders the pull request's branch | the pull request controls its own quota | one preview's load test starving every other preview |
| **Teardown on `closed` only** | the workflow deletes on `pull_request: closed` | a pull request left open never closes | a preview running for three weeks; the reaper exists for this |
| **A token-triggered label change** | the reaper removes the label with `GITHUB_TOKEN` | events caused by `GITHUB_TOKEN` start no workflows | `preview.yml`'s `unlabeled` job never runs, so the reaper deletes the images itself |

Unauthenticated, GitHub allows the ApplicationSet 60 requests an hour; polling every 120 seconds uses 30.

> Further reading: [Argo CD: Pull Request generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/)

---

## One load balancer

**Route every preview through one ingress controller; give no preview a load balancer.** Traefik runs once, behind one NLB, and each preview adds an Ingress rule for `pr-<n>.preview`. An unknown host gets Traefik's `404 page not found`; a known one reaches its api. The quota sets `services.loadbalancers: 0`, so a preview that asked for its own would be refused.

ingress-nginx, the usual choice, was retired in March 2026. The Service carries `service.beta.kubernetes.io/aws-load-balancer-type: nlb`: without it the in-tree cloud provider makes a Classic ELB, which `aws elbv2 describe-load-balancers` does not list, and a check of "exactly one" would pass with a load balancer it cannot see.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **A LoadBalancer per preview** | each preview's Service is `type: LoadBalancer` | an NLB per open pull request, ~$0.023/hour each | the bill rising with open pull requests, not with work |
| **Counting the wrong API** | a Classic ELB, checked with `aws elbv2` | Classic load balancers are a different API | "0 load balancers" with one billing |

> Further reading: [Traefik: Kubernetes Ingress](https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/ingress/)

---

## The ceiling is pods per node

**Find the limit you are near by filling the cluster, then read the scheduler's reason.** `scripts/preview-capacity.sh` added previews one at a time:

```
3 × t3.small: 1930m CPU, 1.4Gi memory, 11 pods allocatable each
pods running before: 29 (25 platform, 4 for two previews)
pr-901: ready (1)
pr-902: ready (2)
pr-903: 0/3 nodes are available: 1 Insufficient memory, 3 Too many pods.
nodes: CPU 28%, 27%, 34% requested; memory 98%, 56%, 56%
```

Four previews: two from pull requests and two from the script. The platform (Argo CD, Kyverno, External Secrets, Traefik, kube-system and the three api environments) holds 25 of the 33 pod slots, and a preview needs two. The arithmetic the ROADMAP predicted holds: the VPC's two `/24` subnets have 502 addresses, and the nodes allow 33 pods. IP exhaustion is far away; pods per node, then memory, are what run out. CPU, the resource people usually watch, was a third used.

---

## Break-glass

**Skip the pipeline, not admission, and file the record before anything else can go wrong.** `scripts/break-glass.sh <env> <digest> "<reason>"`:

1. checks the digest with `cosign verify` against this repository's CI identity; Kyverno checks it again at admission, so break-glass cannot run an image CI did not build;
2. commits the digest to `deploy/envs/<env>` and pushes to `main` (an admin bypass of branch protection, which GitHub logs);
3. files an issue labelled `break-glass` with who, when, from, to, the commit and the reason, and a checklist for the review afterwards.

`break-glass-audit.yml` checks every push to `main` that touches `deploy/envs`: a commit with no pull request and no existing issue gets one.

The drill (`--drill` pushes to `break-glass-drill` instead of `main`):

```
== 1. signed by this repository's CI?   yes
== 2. commit                            pushed 7f1ee69 to break-glass-drill
== 3. audit issue                       #117                      6.4s in all
audit workflow on that push:            7f1ee69: already has an audit issue
a hand edit pushed without the script:  43a3a17: issue filed (#118)
```

The script files its issue through the API, not through Actions, so the record does not wait for the pipeline that broke. Both drill issues were closed and the branch deleted.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Break-glass around admission** | `kubectl set image` on the cluster | the cluster drifts from Git, and the image need not be signed | Argo CD reverting the fix within minutes, or worse, not |
| **No record** | a direct push and nothing else | nobody reviews it afterwards | a prod change found months later in `git log` |

> Further reading: [GitHub: about protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

---

## What went wrong while building this

- **Kyverno's Application showed OutOfSync** (as in Project 17), so `make platform-up`'s wait loop never finished and was stopped by hand once every other Application was healthy.
- **The capacity script first used `${array[@]}` on an empty array**, which macOS's bash 3.2 rejects under `set -u`; it uses `${array[@]+"${array[@]}"}`.
- **A preview deleted by tag could take another tag with it** if both pointed at one image version. The cleanup deletes only versions whose tags all belong to the pull request.
- **Not all of the cluster is tagged yet.** The new launch template tags the nodes, their root volumes and primary network interfaces (`Lab=13`). The pod network interfaces the VPC CNI adds, the control plane's and the NLB's are created by AWS and Kubernetes and carry no `Lab` tag.
- **Teardown left a load balancer behind, made by Argo CD.** `make eks-down` deleted Traefik's Service; Argo CD, still running, recreated it six seconds later, and Kubernetes made a new NLB just before the cluster went. Nothing was left to delete it, its network interfaces held the subnets, and the internet gateway sat in "destroying" for over ten minutes until the NLB was deleted by hand. `eks-down.sh` now scales Argo CD's controllers to zero before it deletes any Service. The script's own check had passed: it looked once, right after the delete, before the new NLB existed.
- **`make aws-sweep` flagged the cost report's Lambda** as an environment nobody owns. It is listed as persistent now.
- **Cluster time**: `make platform-up` at 02:14:52 UTC, `make aws-sweep` printed `Account is clean.` at 02:54:51. About 40 minutes, roughly $0.15 of credit; the stray NLB ran about 12 minutes of it.
