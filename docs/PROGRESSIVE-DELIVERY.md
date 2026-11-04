# Progressive delivery

Deploy and release as separate events. A new version goes to one pod in five; it is released further only while its own error rate stays low, and aborted without anyone watching when it does not. A feature ships switched off and is turned on without a deploy. Project 15, on EKS, about $0.20 of credit.

| Path | What |
|---|---|
| [`k8s/overlays/progressive/rollout.yaml`](../k8s/overlays/progressive/rollout.yaml) | the api as an Argo `Rollout`: 5 replicas, canary 20 → 40 → 60 → 80%, 60s pauses |
| [`k8s/overlays/progressive/analysis.yaml`](../k8s/overlays/progressive/analysis.yaml) | the `AnalysisTemplate`: the canary pods' own 5xx share, every 20s |
| [`k8s/overlays/progressive/prometheus.yaml`](../k8s/overlays/progressive/prometheus.yaml) | a namespace-only Prometheus, scraping every 5s |
| [`k8s/overlays/progressive/flags.yaml`](../k8s/overlays/progressive/flags.yaml) | the feature flags, as a mounted ConfigMap |
| [`app/api/src/api/flags.py`](../app/api/src/api/flags.py) | flags read per request; `/metrics`; the `x-build` header |
| [`k8s/platform/progressive.sh`](../k8s/platform/progressive.sh) | Argo Rollouts v1.10.1 |

```bash
./k8s/platform/progressive.sh
kubectl apply --server-side -k k8s/overlays/progressive   # minikube; on EKS, pin the image (below)
```

Run on EKS 1.35, 2 × `t3.small`, Argo Rollouts v1.10.1, Prometheus v3.15.1, October 2026. EKS rather than minikube: the laptop's Docker VM had 1.9 GB free, and Project 11 showed what happens when minikube runs it out.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| A bad version reaches at most the configured canary percentage of traffic | **19.4% and 19.9%** of requests in the 40 seconds the bad version existed, two runs, against a 20% step. 4.6% of each 3-minute test. |
| The abort happens without human intervention | Both runs aborted **49s** after the image changed: analysis readings `NaN`, `0.51`, `0.50`; `failed (2) > failureLimit (1)`; all five pods back on the stable version. |
| A feature can be enabled and disabled with no deploy | `quotes` turned off, on, off by editing a ConfigMap: all five pods followed in **75s, 90s, 65s**. Same five pods (UIDs), no restarts, Rollout revision 8 before and after. |

---

## Deploy is not release

**Put a new version in front of a slice of real traffic, measure it, and let the measurement decide.** A Deployment's rolling update (Project 12) replaces every pod as soon as each new one is ready. Readiness says the process answers `/readyz`, not that it serves orders correctly. A Rollout stops at each weight, and a background analysis decides whether to go on.

With no service mesh, the weight is the pod share: the Service spreads requests evenly over ready pods, so 1 canary pod in 5 gets about 20%. The measured 19.4% and 19.9% match. Finer steps (1%, 5%) need a mesh or an ingress that splits traffic by weight; with replicas alone, 5 pods means steps of 20.

**Blue/green** is the other strategy Argo Rollouts offers: a full second set of pods, a switch of the Service, and an instant switch back. It costs double the pods for the duration, and every user moves at once. It was not built here.

> Further reading: [Argo Rollouts canary](https://argo-rollouts.readthedocs.io/en/stable/features/canary/)

---

## What decides: the canary's own error rate

**Measure the canary against a threshold, on its own pods only.** The analysis query divides the canary's 5xx rate by its total rate, selected by the `rollouts_pod_template_hash` label that Argo Rollouts puts on each ReplicaSet's pods and Prometheus keeps.

The bad version failed half its `POST /orders`. Averaged over all five pods, that is 10%: in the 40 seconds it ran, **10.2% of all requests failed** (908 of 8,936). Measured on its own pods, it was 51%. A whole-service average would have needed a threshold under 10% to catch it, and would have missed a canary failing a quarter of its requests behind four healthy pods.

```
2026-10-31T12:58:07Z  Successful  NaN      ← canary pod up, no requests in the window yet
2026-10-31T12:58:27Z  Failed      0.5116
2026-10-31T12:58:47Z  Failed      0.5041
Metric "error-rate" assessed Failed due to failed (2) > failureLimit (1)
RolloutAborted … Background analysis phase error/failed
```

The good version, by contrast: 14 measurements, the first `NaN` and the rest `0`, through every step to `Healthy` in 435s; **0 of 66,641** requests failed, 30,167 served by the old version and 36,474 by the new.

**"No data" is not "no harm", and it is not "harm" either.** The first good canary was aborted. In its first seconds Prometheus had no series for the canary's hash, and `sum(rate(...))` returns an **empty** result, not `NaN` and not 0. Argo Rollouts treats an empty result as an error, and five errors in a row abort:

```
Metric "error-rate" assessed Error due to consecutiveErrors (5) > consecutiveErrorLimit (4):
could not evaluate successCondition "isNaN(result[0]) || result[0] < 0.05": metric result is nil or empty
```

The query now wraps both sides in `scalar()` and the errors in `or vector(0)`: no requests yet gives `NaN` (passes), requests without errors give `0`.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Empty result** | `sum(rate(x{hash="new"}))` before the first scrape of the new pods | the provider returns nothing | a good release `Degraded`, `RolloutAborted`, "metric result is nil or empty" |
| **Whole-service rate** | the query has no pod-template-hash filter | the canary's failures are diluted by the stable pods | a canary failing 50% reads as 10%, under a 15% threshold, and is promoted |
| **No traffic in the window** | a quiet service, or a canary that receives nothing | every measurement is `NaN` and passes | a release promoted on no evidence; check the measurement count, not just the phase |

> Further reading: [Analysis with Prometheus](https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/)

---

## Feature flags: release without a deploy

**Ship the code switched off, and switch it on in config.** `POST /orders/quote` is deployed in every pod and answers 404 until the `quotes` flag is true. The api reads `/etc/flags/flags.json` on each request (it re-reads only when the file's modification time changes), and the file is a mounted ConfigMap.

| Change to `api-flags` | All 5 pods answer the new way after |
|---|---|
| `quotes`: true → false | 75s |
| false → true | 90s |
| true → false | 65s |

The pods, their restart counts and the Rollout revision did not change. The delay is the kubelet refreshing mounted ConfigMaps (a sync period plus a cache), so turning a feature off is about a minute, not instant. A flag service with push updates would be faster, and is another moving part.

Three choices in the setup decide whether this works:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Flags as env vars** | `envFrom: configMapRef` | env vars are read once, at start | the ConfigMap changes; the pods behave as before |
| **Generated ConfigMap name** | flags in a `configMapGenerator` | a new value means a new name, a new pod template, a new rollout | flipping a flag starts a canary |
| **Mounted with `subPath`** | `subPath: flags.json` | subPath mounts are never updated | the file in the pod keeps the old value forever |

A flag also doubles the paths through the code: every flag is two versions to test, and `n` flags are `2ⁿ` combinations. A flag that has been on everywhere for a month is code to delete, not a switch to keep.

---

## What went wrong while building this

- **A good release was aborted** on an empty query result (above). The fix is in the query, not in a higher error limit.
- **Kustomize did not rewrite the ConfigMap name inside the Rollout.** It knows a Deployment's fields, not a custom resource's; the pods would have asked for plain `api-config`. `rollout-transform.yaml` names the paths. Copying the `images` entries from Argo Rollouts' own version of that file then failed with `conflicting fieldspecs` once another kustomization wrapped this one: Kustomize's built-in image paths already match any kind with `spec/template/spec/containers`.
- **The load generator merged two builds.** It cut the `x-build` value to 7 characters, so `30b05a0-v2` counted as `30b05a0`. It now keeps the suffix.
- **The laptop could not take it.** The Docker VM had 1.9 GB free; the run moved to EKS instead of risking Project 11's out-of-memory crash.
- **Two of my wait loops never ended.** One compared `uniq -c` output, whose padding varies, with a fixed string; one watcher's output stopped changing mid-rollout. Both were stopped by hand; the second hides the intermediate canary steps of the good run, which the traffic split above confirms instead.
- **The test images were pushed from the laptop**, built `FROM` the published stable image with only `COPY` and `ENV`, so no ARM-to-x86 emulation was needed. They were deleted from ECR after the session.
