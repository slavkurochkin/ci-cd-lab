# Five broken deployments

Each file breaks one thing. Apply one, look at it with kubectl, and write down the cause before reading its section. Project 12.

```bash
kubectl apply -f k8s/broken/00-namespace.yaml -f k8s/broken/01-release.yaml
kubectl -n lab-broken get pods
kubectl -n lab-broken describe pod <name>      # Events, at the bottom
kubectl -n lab-broken logs <name>
kubectl delete namespace lab-broken            # when done
```

**`kubectl describe` before `kubectl logs`.** Three of the five never started a container, so there were no logs to read. The fourth logged the answer. The fifth looked healthy in both, and only the events said what happened.

| # | File | STATUS | Where the answer was | `kubectl logs` said |
|---|---|---|---|---|
| 1 | `01-release.yaml` | `ImagePullBackOff` | event: `pull access denied` | nothing to read |
| 2 | `02-entrypoint.yaml` | `CrashLoopBackOff` | **logs**: `Attribute "application" not found` | the answer |
| 3 | `03-sizing.yaml` | `Pending` | event: `Insufficient memory` | nothing to read |
| 4 | `04-config.yaml` | `CreateContainerConfigError` | event: `configmap "api-config" not found` | `waiting to start` |
| 5 | `05-scratch.yaml` | `Completed`, `Running` with 1 restart | events: `Evicted`; `lastState`: `OOMKilled` | normal server start-up |

Run on minikube v1.38.1, Kubernetes v1.35.1, October 2026.

---

## 1. ImagePullBackOff: a tag that was never pushed

```
Failed to pull image "ci-cd-lab/api:1.4.0": Error response from daemon: pull access denied for
ci-cd-lab/api, repository does not exist or may require 'docker login'
Error: ErrImagePull
Back-off pulling image "ci-cd-lab/api:1.4.0"
```

The node has `ci-cd-lab/api:local`, not `1.4.0`, so `IfNotPresent` asked Docker Hub, which has no such repository. The message is the same for a missing tag, a missing repository and missing credentials: registries answer "denied" rather than say which names exist. Check the tag exists before suspecting credentials.

**Fix:** the tag that exists. The image is a build output, so the deploy should be handed the digest the build produced (Capstone B did that for Lambda), not a tag typed by hand.

---

## 2. CrashLoopBackOff: the one where logs help

The events said only `Back-off restarting failed container`. The container did start, so it had logs:

```
ERROR:    Error loading ASGI app. Attribute "application" not found in module "api.main".
```

`lastState.terminated.exitCode` was 3, uvicorn's code for "could not load the app". The command named `api.main:application`; the object is `app`.

**Fix:** remove the `command` override and use the image's own `CMD`. An override has to repeat everything the image already knows.

`kubectl logs --previous` failed here (`unable to retrieve container logs`) while plain `logs` showed the error: between restarts the last terminated container is the current one. Try both.

---

## 3. Pending: a unit typo

```
0/1 nodes are available: 1 Insufficient memory. ... Preemption is not helpful for scheduling.
```

The request says `64Gi`; every other pod in this repo asks for `64Mi`. No node has 64 GiB, so the scheduler never places the pod, no container exists, and there is nothing in `logs`. A `Pending` pod is a scheduling question, and the scheduler's answer is only in the events.

**Fix:** `64Mi`. Other `Pending` causes leave the same kind of event: a `nodeSelector` no node matches, a taint without a toleration, a PersistentVolumeClaim with no volume.

---

## 4. CreateContainerConfigError: a name Kustomize would have rewritten

```
Error: configmap "api-config" not found
```

The ConfigMap exists, as `api-config-7fdmd2d8bg`. That is the hashed name from Project 11's `configMapGenerator`, and Kustomize rewrites every reference to it inside the build. This Deployment was written by hand, outside the build, so it still says `api-config`. The image pulled and the pod was scheduled; the kubelet stopped while assembling the container's environment, before starting it.

**Fix:** the real name, or better, put the Deployment in the kustomization so the reference is rewritten with it. A missing Secret, or a missing key in one, gives the same status.

---

## 5. Evicted, and it looked like success

The symptom was a pod that kept being replaced. Neither `STATUS` nor `logs` said why:

```
NAME                       READY   STATUS      RESTARTS
scratch-58d55bd489-7bt8b   0/1     Completed   0
scratch-58d55bd489-rgr4q   0/1     Completed   1
scratch-58d55bd489-hvcnt   1/1     Running     1
```

The events did:

```
Warning  Evicted   pod/scratch-58d55bd489-7bt8b   Pod ephemeral local storage usage exceeds the total limit of containers 50Mi.
Normal   Killing   pod/scratch-58d55bd489-7bt8b   Stopping container api
```

**Two faults, stacked.** The container writes a 100 MB cache to `/tmp` (an `emptyDir`) before starting the server.

1. On first start, `lastState` was `OOMKilled`, exit 137. `dd` writes through the page cache, and dirty pages count against the container's 128Mi memory limit until they reach disk.
2. On the restart the write got through, the server started, and about 60 seconds later the kubelet evicted the pod for using more than its 50Mi `ephemeral-storage` limit.

**An evicted pod showed `Completed`**, because the eviction sends SIGTERM and uvicorn shut down cleanly, with exit 0. The pod's phase is `Succeeded`. Nothing in `get pods` says "Evicted". Events are deleted after an hour, so an eviction found the next morning has left no reason behind.

**Fix:** both limits, one at a time, to prove both faults were real. Raising `ephemeral-storage` to 200Mi alone left `RESTARTS 1` and `lastState: OOMKilled` on the new pod; `kubectl rollout status` still said `successfully rolled out`, because the pod was ready after its restart. Raising the memory limit to 256Mi as well gave 0 restarts and no eviction over the next two minutes. The old `Completed` pods stayed listed until deleted.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Storage eviction** | writes to `emptyDir` or the container layer above `ephemeral-storage` | the kubelet evicts the pod | `Completed` or `Error` in `get pods`; the reason only in events, for an hour |
| **OOM kill** | memory, page cache included, above the limit | the kernel kills the process | `RESTARTS` goes up; `lastState: OOMKilled`, exit 137 |
| **Node-pressure eviction** | the node itself runs short of memory or disk | the kubelet evicts pods, BestEffort first | `Evicted` on pods that were within their limits |
