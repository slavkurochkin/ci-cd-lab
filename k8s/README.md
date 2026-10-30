# k8s

Both services on a local minikube cluster. Project 10.

**You declare what should be true, and controllers keep making it true.** Delete a pod and a controller replaces it. Scale by hand and the next apply puts the declared count back. Most surprises in this project come from expecting a command to *do* something, when it only changes what is declared.

```bash
minikube start --cpus 2 --memory 4096

# Build into minikube's own image store, so pods run this checkout and nothing
# is pulled from a registry.
(cd app/api    && minikube image build -t "ci-cd-lab/api:local"    -f Dockerfile .)
(cd app/worker && minikube image build -t "ci-cd-lab/worker:local" -f Dockerfile .)

kubectl apply --server-side -k k8s/overlays/dev
kubectl -n lab-dev rollout status deploy/api
```

Since Project 11 the manifests live in `base/` with `overlays/dev` and `overlays/prod`, and need the platform from `platform/install.sh` (Vault, External Secrets, Reloader, metrics-server). The demos below were run on Project 10's flat manifests in a namespace called `lab`; [`docs/CONFIG-AND-PACKAGING.md`](../docs/CONFIG-AND-PACKAGING.md) is Project 11, [`docs/ROLLOUTS-AND-FORENSICS.md`](../docs/ROLLOUTS-AND-FORENSICS.md) Project 12.

`minikube stop` when you are done. It costs nothing in AWS, but it is a VM on your laptop.

| Path | What |
|---|---|
| `base/api.yaml` | Deployment and a ClusterIP Service on port 80 |
| `base/worker.yaml` | a **Job**, not a Deployment; see below |
| `base/dynamodb.yaml`, `base/secrets.yaml` | Project 11: DynamoDB Local, and the api's secrets from Vault |
| `overlays/dev`, `overlays/prod` | Project 11: namespace, replicas, resources, config |
| `chart/api` | Project 11: the same api as a Helm chart |
| `platform/install.sh` | Project 11: what the manifests assume is installed |
| `base/pdb.yaml`, `rollout/` | Project 12: the disruption budget; traffic and a step-by-step watcher for rollouts |
| `broken/` | Project 12: five broken deployments, and how each was diagnosed |

Everything below was run on minikube v1.38.1, Kubernetes v1.35.1, October 2026.

---

## Self-healing: you do not restart pods

**A Deployment does not keep pods alive. It keeps a ReplicaSet at a count, and the ReplicaSet creates pods until the count is right.** Deleting a pod is not undone by the pod; it is noticed by a controller.

One of the two api pods was deleted. The second ready pod was back in **2 seconds**, and the events show who acted:

```
api-6fc6dfb55c-fg5gp   Killing
api-6fc6dfb55c         SuccessfulCreate      ← the ReplicaSet, not the Deployment, not you
api-6fc6dfb55c-9hd9h   Scheduled → Pulled → Created → Started
```

This is also why you almost never create a Pod or a ReplicaSet directly. A bare Pod has no controller, so deleting it is final. A bare ReplicaSet has no rollout history, so changing its image does nothing to the pods it already has.

> Further reading: [Controllers](https://kubernetes.io/docs/concepts/architecture/controller/)

---

## Services find pods by label, and a typo is not an error

**A Service is not connected to a Deployment. It sends traffic to every ready pod whose labels match its selector, and a selector that matches nothing is a valid selector.**

The Service's selector was patched from `api` to `apl`:

```
$ kubectl -n lab get service api
NAME   TYPE        CLUSTER-IP      PORT(S)
api    ClusterIP   10.103.55.237   80/TCP          ← looks fine

$ kubectl -n lab get endpoints api
NAME   ENDPOINTS
api    <none>                                      ← the only sign

$ curl http://api/version                          (from a pod in lab)
curl exit 7                                        ← connection refused
```

The pods stayed `1/1 Running`. No warning event was emitted. The only `Warning` events in the namespace were two `Readiness probe failed` from the pods' first seconds, before uvicorn was listening, which have nothing to do with the selector.

`kubectl get endpoints` (or `get endpointslices`) is where a broken selector shows. A Service with an IP and no endpoints answers every connection with a refusal, because there is nothing behind the IP to forward to.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Selector typo** | `apl` for `api` in the Service | matches no pods | Service has a ClusterIP, `ENDPOINTS <none>`, callers get connection refused |
| **Pod label typo** | the template's label changed, Service unchanged | the same, from the other side | the same, and the Deployment is perfectly healthy |
| **Pods not ready** | readiness probe failing | ready pods are the only endpoints | `ENDPOINTS <none>` while pods are `Running`, with `Readiness probe failed` events |

The third row looks the same as the first two in `get endpoints`. The difference is in the events: a failing probe leaves a warning, and a wrong label leaves nothing.

> Further reading: [Labels and selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)

---

## DNS: the namespace is part of the name

**`api` only resolves inside the `lab` namespace. From anywhere else it is `api.lab.svc.cluster.local`.** The short name works because of the pod's DNS search path:

```
search lab.svc.cluster.local svc.cluster.local cluster.local
```

From a pod in `lab`, `curl http://api/version` answered. From a pod in `default`, the same command failed with curl exit 6, *could not resolve host*, and `http://api.lab.svc.cluster.local/version` answered.

A namespace scopes names. It is not a security boundary: the pod in `default` reached the api once it used the full name. Stopping that takes a NetworkPolicy, and minikube's default network plugin does not enforce one.

The answer was `{"git_sha":"3eecdd5","environment":"minikube"}`. `3eecdd5` is this checkout's commit, so the pods run the image built here.

> Further reading: [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

---

## A Deployment for something that exits

**A Deployment keeps a process running. A process that is meant to finish belongs in a Job.**

The worker prints its build identity and exits 0. Run as a Deployment:

```
t= 10s  0/1  CrashLoopBackOff  restarts=1
t= 20s  0/1  Completed         restarts=2
t= 40s  0/1  CrashLoopBackOff  restarts=2
t= 50s  0/1  Completed         restarts=3
...
lastState: Completed  exit=0
```

`CrashLoopBackOff` does not mean the container crashed. It means it keeps stopping, and the kubelet waits longer before each restart. Exiting with 0 counts. As a Job (`worker.yaml`), the same image ran once: `Complete 1/1` in 4 seconds.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Short-lived process in a Deployment** | a batch task, a migration, a one-off script | restartPolicy is always `Always` | `CrashLoopBackOff` with `exit=0`, and logs that look successful |
| **Long-running process in a Job** | a server run as a Job | the Job never completes | a Job stuck at `0/1` forever |

---

## Images: what is on the node is not what gets used

**Use an explicit tag and say the pull policy. `:latest` silently changes the pull policy to `Always`.**

The api image was tagged `ci-cd-lab/api:latest` inside minikube, where it existed, and run without a pull policy:

```
pullPolicy=Always  status=ImagePullBackOff
Failed to pull image "ci-cd-lab/api:latest": ... pull access denied for ci-cd-lab/api,
repository does not exist ...
```

The image was on the node, but `Always` means *ask the registry first*, and Docker Hub has no such repository. The manifests use `:local` with `imagePullPolicy: Never`: run what `minikube image build` produced, or fail with `ErrImageNeverPull` and say so.

`minikube image build` puts the image in the cluster's container runtime, not in the Docker on your laptop. `docker images` on the laptop does not list it, and `minikube image ls` does.

---

## The first deploy failed: a user name is not a user ID

**`runAsNonRoot` needs a numeric user.** With `runAsNonRoot: true` and the image's `USER app`, both api pods stayed in `CreateContainerConfigError`:

```
container has runAsNonRoot and image has non-numeric user (app), cannot verify user is non-root
```

The kubelet does not look inside the image's `/etc/passwd` to turn `app` into a number. The manifests now set `runAsUser: 1001` for the api (the UID the Dockerfile creates) and `1000` for the worker (`node`). The alternative is `USER 1001` in the Dockerfile itself, which would fix it for every consumer of the image; that is a change for the image, not for this project.

---

## apply, create, and who owns a field

**`create` fails if the object exists; `apply` describes the end state and can be run any number of times.** Running `kubectl create -f api.yaml` against the running cluster: `AlreadyExists` for both objects. `kubectl apply --server-side` with the same file: `serverside-applied`, no change.

Server-side apply also records **which client owns each field**, and refuses to silently take a field from another owner. Both times this project changed something by hand, the next apply said so:

```
# after `kubectl patch` changed the selector
error: Apply failed with 1 conflict: conflict with "kubectl-patch" using v1: .spec.selector

# after `kubectl scale --replicas=3`
error: Apply failed with 1 conflict: conflict with "kubectl" with subresource "scale" using apps/v1: .spec.replicas
```

`--force-conflicts` takes the field back; both times, the manifest was meant to win. Client-side `kubectl apply` would have overwritten both without a word. In production the second case is usually an autoscaler owning `replicas`, and the fix is to leave `replicas` out of the manifest so there is nothing to fight over.

> Further reading: [Server-side apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)

---

## Evaluation

| Roadmap check | Result |
|---|---|
| Deleting a pod results in a new one without you doing anything | back to 2 ready replicas in 2 seconds; the ReplicaSet logged `SuccessfulCreate` |
| You can reach the API through a Service by name from inside the cluster | `curl http://api/version` from a pod in `lab`; `api.lab.svc.cluster.local` from `default` |
| You can explain, from `kubectl get endpoints`, why a broken selector produces no error | `ENDPOINTS <none>`; a selector matching nothing is valid, so there is nothing to report |

---

## What went wrong while building this

- **`runAsNonRoot` refused both images**, because they name their user instead of numbering it. See above.
- **zsh again.** `ci-cd-lab/$s:local` built images called `apiocal` and `workerocal`: `$s:l` is zsh's lowercase modifier. The same thing mangled ARNs in Capstone B (`$A:r`, `$F:c`). Braces, `${s}`, every time.
- **`minikube image build app/api` could not find the Dockerfile** from a relative context path. Building from inside the app directory with `-f Dockerfile .` works.
- **The roadmap says Deployments for both services.** The worker exits, so a Deployment for it is a `CrashLoopBackOff`; it runs as a Job.
