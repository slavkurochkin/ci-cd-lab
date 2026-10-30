# Rollouts, failure and forensics

What a rolling update does pod by pod, how it drops requests and how to stop it, what a failed rollout looks like, and five broken deployments diagnosed from evidence. Project 12, on minikube, $0.

| Path | What |
|---|---|
| [`k8s/base/api.yaml`](../k8s/base/api.yaml) | rollout strategy, history limit, progress deadline, `preStop` |
| [`k8s/base/pdb.yaml`](../k8s/base/pdb.yaml) | PodDisruptionBudget: one api pod down at a time |
| [`k8s/base/dynamodb.yaml`](../k8s/base/dynamodb.yaml) | `Recreate`, for the one thing that must run as a single copy |
| [`k8s/rollout/`](../k8s/rollout) | `loadgen.py` (traffic from inside the cluster) and `watch.sh` (replica counts at each step) |
| [`k8s/broken/`](../k8s/broken) | five broken deployments and how each was diagnosed |
| [`app/worker/src/work.ts`](../app/worker/src/work.ts) | the worker stops between items on SIGTERM |

```bash
kubectl apply --server-side -k k8s/overlays/prod
kubectl -n lab-prod apply -k k8s/rollout            # 60s of traffic
k8s/rollout/watch.sh lab-prod api &                 # one line per change
kubectl -n lab-prod rollout restart deploy/api
kubectl -n lab-prod logs job/loadgen
```

Run on minikube v1.38.1, Kubernetes v1.35.1, October 2026. Traffic: 4 clients in a pod in the same namespace, a new connection per request, about 4,100 requests a second against 3 api pods.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| Zero failed requests during a rolling update under load | **0 of 250,380** and **0 of 248,769**, two runs with `preStop`. Without it: 156 of 240,826 failed, in three bursts. |
| Each of the five broken deployments correctly diagnosed before being fixed | All five, from events, logs and `lastState`; each fix applied alone and confirmed. One had two faults. See [`k8s/broken/README.md`](../k8s/broken/README.md). |
| You can state the exact number of available pods at each step of a rollout | Measured for 3 and 4 replicas, for both strategies used here (below). |

---

## A rolling update drops requests until you add a preStop wait

**Give the api a `preStop` sleep of a few seconds.** Removing a pod starts two things at the same time: the kubelet stops the container, and the endpoints controller and kube-proxy take the pod out of the Service. Neither waits for the other. uvicorn closes its listening socket within milliseconds of SIGTERM, and kube-proxy on the node is still sending new connections there.

Baseline, the manifests as Project 11 left them, `kubectl rollout restart` 10 seconds into 60 seconds of traffic:

```
t= 13s ok=1613 failed={'ConnectionRefusedError': 56}
t= 16s ok=1944 failed={'RemoteDisconnected': 1, 'ConnectionRefusedError': 49}
t= 19s ok=2181 failed={'ConnectionResetError': 1, 'ConnectionRefusedError': 49}
{"requests": 240826, "failed": 156, ...}
```

One burst per old pod, each at the second that pod was told to stop. The Deployment reported 3 available pods the whole time: by its own numbers nothing was wrong.

With `lifecycle.preStop.sleep.seconds: 5`, the same test twice:

```
{"requests": 250380, "failed": 0, "outcomes": {"ok": 250380}}
{"requests": 248769, "failed": 0, "outcomes": {"ok": 248769}}
```

During those 5 seconds the pod still serves, and the routing change lands. Then SIGTERM, and uvicorn finishes what it has. The cost was time: each old pod stayed 5 seconds longer, and the rollout took 25 seconds instead of 20.

`sleep` is a built-in lifecycle action, so it needs no shell in the image. The older `exec: ["sh", "-c", "sleep 5"]` fails silently on a distroless image. The sleep counts against `terminationGracePeriodSeconds` (30 here), so the grace period must cover the sleep plus the longest request.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **No preStop** | the app stops listening on SIGTERM | kube-proxy still routes to it for a moment | a few `connection refused` per pod per deploy; "flaky deploys" |
| **Grace period too short** | `terminationGracePeriodSeconds` below preStop plus request time | SIGKILL mid-request | `connection reset`; exit 137 in `lastState` |
| **SIGTERM ignored** | PID 1 with no handler (see the worker below) | nothing stops until SIGKILL | every pod takes the full grace period to go away |

> Further reading: [Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)

---

## The arithmetic of a rollout

**`maxSurge` is how many extra pods may exist, `maxUnavailable` how many of the desired count may be missing.** Surge rounds up and unavailable rounds down, so the defaults, 25% and 25%, mean different things at different sizes:

| Replicas | 25% surge (rounded up) | 25% unavailable (rounded down) | Lowest available |
|---|---|---|---|
| 2 | 1 | 0 | 2 |
| 3 | 1 | 0 | 3 |
| 4 | 1 | 1 | **3** |

Measured with `watch.sh`, one line per change (it polls every 0.5s, so a step faster than that can be missed):

**3 replicas, `maxSurge: 1`, `maxUnavailable: 0`** (the base now)

```
t=  0s  total=3 updated=3 ready=3 available=3 terminating=0
t= 10s  total=4 updated=1 ready=3 available=3 terminating=0   one new pod, starting
t= 13s  total=4 updated=2 ready=3 available=3 terminating=1   first new pod ready → one old pod out, next new pod in
t= 16s  total=4 updated=3 ready=3 available=3 terminating=2
t= 19s  total=3 updated=3 ready=3 available=3 terminating=2
t= 25s  total=3 updated=3 ready=3 available=3 terminating=0   last preStop sleep over
```

**4 replicas, defaults (25%/25%)**

```
t=  0s  total=4 updated=4 ready=4 available=4
t=  2s  total=5 updated=2 ready=3 available=3 terminating=1   one extra and one fewer, at once
t=  5s  total=5 updated=4 ready=3 available=3 terminating=3
t=  8s  total=4 updated=4 ready=4 available=4
```

**4 replicas, `maxSurge: 1`, `maxUnavailable: 0`**

```
t=  0s  total=4 updated=4 ready=4 available=4
t=  3s  total=5 updated=1 ready=4 available=4
t=  5s  total=5 updated=2 ready=4 available=4 terminating=1
t=  9s  total=5 updated=3 ready=4 available=4 terminating=2
t= 12s  total=5 updated=4 ready=4 available=4 terminating=2
t= 15s  total=4 updated=4 ready=4 available=4 terminating=2
```

The defaults finished in 8 seconds with 3 of 4 available; `1`/`0` took 15 and never dropped below 4. The base writes `1`/`0` out, even though at 2 or 3 replicas they equal the defaults: someone scaling prod to 4 should not quietly get a different rollout.

`total` does not count terminating pods. During the `preStop` sleep a pod is terminating and still serving, so the node briefly runs more api processes than `total` says.

> Further reading: [Rolling update deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment)

---

## Recreate: for things that must be one copy

**Use `Recreate` when two copies running at once is wrong.** DynamoDB Local is in memory: during a rolling update the Service would send writes to both the old and the new copy, and whatever went to the old one vanishes with it. `Recreate` stops the old pod before starting the new one, and pays with a short outage. The same applies to a pod holding a `ReadWriteOnce` volume, or a job runner that must not run twice.

Switching an existing Deployment to `Recreate` with server-side apply failed:

```
The Deployment "dynamodb" is invalid: spec.strategy.rollingUpdate: Forbidden:
may not be specified when strategy `type` is 'Recreate'
```

The API server had filled in `rollingUpdate` defaults when the Deployment was created. No manager owns defaulted fields, so the apply does not remove them. It took one JSON patch per namespace, removing `rollingUpdate` and setting the type, after which the apply was clean. A new namespace does not hit this.

---

## A failed rollout, caught and undone

**Set `progressDeadlineSeconds`, and gate on `kubectl rollout status`.** The api was pointed at `ci-cd-lab/api:v2`, a tag that does not exist, under the same traffic:

```
Waiting for deployment "api" rollout to finish: 1 out of 3 new replicas have been updated...
error: deployment "api" exceeded its progress deadline
rollout status exit=1 after 61s

Progressing=False ProgressDeadlineExceeded: ReplicaSet "api-55877c4865" has timed out progressing.
Available=True  MinimumReplicasAvailable: Deployment has minimum availability.

api-55877c4865-kzl4d   0/1   ErrImageNeverPull
api-5998ff8b68-...     1/1   Running            (×3)
```

With `maxUnavailable: 0` the rollout stopped at its first new pod, and the three old pods kept serving: **0 of 249,140 requests failed**. Note `Available=True` alongside `Progressing=False`. A check that reads only availability calls this deploy healthy. The exit code of `rollout status` is the signal Project 13's pipeline will gate on.

`kubectl rollout undo` brought the old template back at once. The old ReplicaSet still had its 3 pods; undo deleted the stuck one.

**Undo needs the old ReplicaSet.** With `revisionHistoryLimit: 0`, after one rollout:

```
$ kubectl -n lab-dev rollout undo deploy/api
error: no rollout history found for deployment "api"
```

The base keeps 5. `CHANGE-CAUSE` in `rollout history` was `<none>` for every revision: nothing records which commit made which revision yet. Project 13 annotates it.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **No timeout on `rollout status`** | `kubectl apply` and move on, or no `progressDeadlineSeconds` | a stuck rollout reports nothing | a green pipeline, and one pod in `ErrImagePull` next to the old ones |
| **History limit 0** | set to save objects | old ReplicaSets deleted | `no rollout history found` at the moment you need undo |
| **maxUnavailable above 0 with a bad image** | defaults at 4+ replicas | old pods removed before new ones prove themselves | capacity down by one for as long as the bad rollout sits there |

> Further reading: [Failed deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment)

---

## PodDisruptionBudget

**A PDB limits voluntary removals: node drains, upgrades, anything through the eviction API.** The base allows one api pod down at a time. Two evictions, back to back, against prod's three pods:

```
evict api-...-l6nk4   {"status":"Success","code":201}
evict api-...-r6ccg   Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
```

`ALLOWED DISRUPTIONS` went from 1 to 0 and back to 1 once the replacement was ready, a few seconds later; the same eviction then succeeded. `kubectl drain` makes these calls and retries a 429 until it gets through, so a drain moves prod one pod at a time.

**`maxUnavailable: 1`, not `minAvailable: 1`.** Dev runs one replica. `minAvailable: 1` would mean dev's pod can never be evicted, and a node drain would wait forever. A PDB does nothing about crashes, OOM kills or a lost node; those are not voluntary.

> Further reading: [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)

---

## Five broken deployments

Diagnosed one by one in [`k8s/broken/README.md`](../k8s/broken/README.md). Three never started a container, so `kubectl logs` had nothing. The answer was in the events every time but once, and that once was the only case where logs helped. One fault hid behind `STATUS Completed`: an evicted pod whose server shut down cleanly.

---

## kubectl debug, for an image with no shell

**When an image has no shell, attach an ephemeral container instead of rebuilding the image.** metrics-server is distroless:

```
$ kubectl -n kube-system exec metrics-server-... -- sh -c 'echo hi'
command terminated with exit code 127
$ kubectl -n kube-system exec metrics-server-... -- ls /
command terminated with exit code 127
```

An ephemeral busybox container, targeting the metrics-server container so it shares its process namespace:

```
$ kubectl -n kube-system debug metrics-server-... --image=busybox:1.37 --target=metrics-server -- sh -c 'ps; ls /proc/1/root/'
PID   USER     COMMAND
    1 1000     /metrics-server --cert-dir=/tmp --secure-port=4443 ... --kubelet-insecure-tls
   35 root     sh -c ps; ...
bin boot dev etc home lib metrics-server proc root run sbin sys tmp usr var
```

PID 1 is the server, with its full command line; `/proc/1/root` is its filesystem. The pod was not restarted. An ephemeral container cannot be removed: it stays in the pod spec until the pod is replaced. Here a `rollout restart` of metrics-server cleared it.

`kubectl debug --copy-to` is the other mode: a copy of the pod with changes, such as a different command. It is the tool for a crash-looping container that exits too fast to attach to.

> Further reading: [Debug running pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container)

---

## The worker: SIGTERM and PID 1

**A process that runs as PID 1 must handle SIGTERM itself.** Linux gives PID 1 no default action for SIGTERM, so a Node process with no handler ignores it. Deleting a pod running `node` as PID 1 took **32 seconds**: the full 30-second grace period, then SIGKILL, mid-work.

The worker now works through `WORK_ITEMS` items and, on SIGTERM, finishes the one in hand and stops. Deleted 5 seconds into a 60-item batch:

```
SIGTERM: finishing the current item, then stopping
{"itemsDone":6,"itemsTotal":60,"interrupted":true}
delete took 1.0s
```

It exits 143, not 0. A Job counts exit 0 as complete, and the 54 items never processed would be forgotten; a non-zero exit makes the Job retry. uvicorn already handles SIGTERM, which is why the api needed only the `preStop` wait.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **PID 1 ignores SIGTERM** | Node or a shell script as the entrypoint, no handler | the kubelet waits out the grace period | every deploy and drain takes 30s per pod; work cut off by SIGKILL |
| **Clean exit on interruption** | `exit 0` after stopping early | the Job is marked complete | items silently never processed |

---

## What went wrong while building this

- **zsh, twice more.** Arrays are 1-indexed, so `${P[0]}` was empty and the first eviction targeted no pod (`MethodNotAllowed`). And `$N` holding `-n lab-broken` is not split into two words, so kubectl got the namespace `" lab-broken"`. Plain words in commands, or bash.
- **`namespace.yaml` sorted after `01-…yaml`**, so `kubectl apply -f k8s/broken/` created the deployments before their namespace and all five failed with `namespaces "lab-broken" not found`. Renamed `00-namespace.yaml`.
- **Case 5's symptom line was wrong.** It promised a pile of `Evicted` pods. They showed `Completed`; corrected after the run.
- **`maxSurge: "1"` in a JSON patch was refused**: a quoted number must be a percentage. The run that followed repeated the 25% case, and was discarded.
- **Switching DynamoDB to `Recreate`** was refused until a manual patch removed the defaulted `rollingUpdate` (above).
- **Memory, this time, was fine.** Before starting minikube, `docker stats` showed the laptop's other containers at about 1.2 GiB, not Project 11's 4.6 GiB, and the VM had 4.9 GiB available. The 6 GiB profile ran dev, prod, the platform and the broken namespace without trouble.
