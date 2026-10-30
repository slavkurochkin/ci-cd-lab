# Configuration and packaging

Config out of the image, secrets out of Git, resources from measurement, and the same app packaged twice: Kustomize for the environments, Helm for the chart. Project 11, on minikube, $0.

| Path | What |
|---|---|
| [`k8s/base/`](../k8s/base) | api, worker, DynamoDB Local, the api's secrets; config from a generated ConfigMap |
| [`k8s/overlays/dev`](../k8s/overlays/dev), [`prod`](../k8s/overlays/prod) | namespace, replicas, resources, `ENVIRONMENT` |
| [`k8s/chart/api/`](../k8s/chart/api) | the api as a Helm chart with a values schema |
| [`k8s/platform/install.sh`](../k8s/platform/install.sh) | metrics-server, Vault (dev mode), External Secrets Operator 2.12.0, Reloader 2.2.18 |

```bash
./k8s/platform/install.sh
kubectl apply --server-side -k k8s/overlays/dev
```

Run on minikube v1.38.1, Kubernetes v1.35.1, October 2026.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| `kustomize build overlays/prod` differs from dev in replicas, resources and config only | Diffing the two builds, with the namespace name normalised: `ENVIRONMENT`, the ConfigMap name that hashes it, `replicas: 1 → 3`, and the resources. Nothing else. |
| A pod with a failing readiness probe never receives traffic | **0 requests.** A fourth pod with prod's labels and a readiness probe on a missing path, under 60s of traffic (`k8s/rollout/loadgen.py`, Project 12): the three ready pods logged 86,216 + 86,376 + 85,905 `GET /version` = all 258,497 requests; the unready pod logged none, and 17 `GET /not-here` from the kubelet's probe, so it was running and listening the whole time. The EndpointSlice listed it with `ready=false`. First attempted during Project 11, when the node ran out of memory before the count ran. |
| `helm template` output is valid and `helm lint` passes | `helm lint`: 0 failed. `helm template ... \| kubeconform -strict`: Deployment, Service, ConfigMap valid against Kubernetes 1.35; the ExternalSecret skipped (no schema for the custom resource). |

---

## Config: out of the image, and changes that roll

**Config goes in a ConfigMap whose name changes when its content does.** The base's `configMapGenerator` named it `api-config-98bbkdfmf6` and rewrote all three references (init container, api, worker) to match. Dev's is `api-config-7fdmd2d8bg`, prod's `api-config-k47mc9gh4m`: same keys, different `ENVIRONMENT`, different name.

A new name means a new pod template, so the Deployment rolls. A hand-named ConfigMap that is edited in place changes underneath running pods, and environment variables only read it at start, so nothing changes until some unrelated restart.

The Helm chart does the same with a `checksum/config` annotation: a hash of the rendered ConfigMap on the pod template.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **ConfigMap edited in place** | a fixed name, `kubectl edit` or a re-apply | env vars are read once at start | the ConfigMap shows the new value; the pods behave as before |
| **Config baked into the image** | `ENV` in the Dockerfile | one image per environment | a rebuild to change a URL, and dev and prod no longer run the same image |

> Further reading: [configMapGenerator](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/)

---

## Secrets: out of Git, and the bootstrap problem

**A Kubernetes Secret is base64, which is an encoding, not encryption.** Anyone who can read the Secret can read the value. What keeps it out of Git is not writing it there: the api's DynamoDB credentials live in Vault, and the External Secrets Operator copies them into a Secret every 15 seconds.

**The credential that fetches the credentials is the cluster's own identity.** External Secrets presents the `api-secrets-reader` ServiceAccount's token to Vault, with audience `vault`. Vault checks it with the Kubernetes API and maps that account, in `lab-dev` or `lab-prod`, to a policy that reads one path. Nothing was planted: no token in the repository, none in the cluster. It is the same answer OIDC gave CI in Project 4.

Vault here is a stand-in, in dev mode, in memory, at $0. Doppler or AWS Secrets Manager replace it by changing the `SecretStore`; the `ExternalSecret` and the Deployment do not change.

**Measured: a change in Vault reached running pods in 9 seconds.**

```
vault kv put secret/lab/api ...        t=0
Kubernetes Secret updated by ESO       t=4s
new api pod Available                  t=9s     (Reloader: "Changes detected in 'api-secrets' ...; updated 'api'")
```

Reloader does it by writing a hash of the Secret into an env var on the pod template (`STAKATER_API_SECRETS_SECRET`), which is an ordinary rollout. Argo CD (Project 14) will see that env var as a difference from Git.

**When the store goes away, running pods keep working.** Vault was killed mid-session (below). External Secrets reported it at once (`SecretStore: InvalidProviderConfig`, `ExternalSecret: SecretSyncedError`), but the Kubernetes Secret kept its last value and the api kept serving. What stops is rotation, and any new namespace that needs the secret for the first time.

That first rotation was not planned. The first value in Vault, `AWS_ACCESS_KEY_ID=lab-api`, made every DynamoDB call fail with `UnrecognizedClientException`: DynamoDB Local 2.x accepts any credentials, but only an access key ID of letters and digits. The fix was changing it in Vault, which is the rotation measured above.

One app change made the secret matter. `store.py` set `local` credentials whenever `DYNAMODB_ENDPOINT` was set, using `kwargs.setdefault`, which only looks at `kwargs`. Credentials in the environment were ignored. It now reads them from the environment and falls back to `local`.

> Further reading: [External Secrets: Vault provider](https://external-secrets.io/latest/provider/hashicorp-vault/), [Secrets are base64](https://kubernetes.io/docs/concepts/configuration/secret/)

---

## Resources: measure first, and measure the right number

**Set requests and the memory limit from measurement, and leave the CPU limit off.**

One api pod under about 357 requests a second (26,744 in 75 seconds from four clients):

| | CPU | Memory (`kubectl top`) |
|---|---|---|
| idle | 2m | 62Mi |
| under load | 460m | 72Mi |

**`kubectl top` overstates the memory floor.** The api then ran happily under a **48Mi** limit, below the 62Mi it "used". Inside the container, cgroup `memory.stat` said why: `anon 34Mi`, the rest page cache. The kernel reclaims cache before it kills anything, so the number a limit has to clear is the anonymous memory, not the working set.

With a **24Mi** limit, below the 34Mi floor:

```
t=10s  0/1  OOMKilled          restarts=0
t=20s  0/1  CrashLoopBackOff   restarts=1
...
lastState: OOMKilled  exit=137
```

And no outage: the previous pod kept running and stayed the Service's only endpoint. A rolling update does not remove a working pod until its replacement is ready, so a bad limit gets stuck instead of taking the service down.

Setting a request above its limit is refused before any pod exists: `requests: Invalid value: "96Mi": must be less than or equal to memory limit of 48Mi`.

What the overlays use:

| | CPU request | Memory request | Memory limit | Why |
|---|---|---|---|---|
| dev | 25m | 64Mi | 160Mi | test traffic; the request covers the 34Mi floor |
| prod | 250m | 96Mi | 192Mi | 460m served ~357 req/s on one pod; three replicas at 250m carry that with one lost |

**No CPU limit.** A CPU limit throttles a busy container even when the node has idle CPU. A memory limit stays, because without one a single pod can use the node's memory, which is what happened next.

---

## QoS classes, learned the hard way

**A pod with no requests is BestEffort, and BestEffort is killed first when a node runs out.** The Vault Helm chart sets no requests. When the node ran out of memory, the kernel's log said:

```
Out of memory: Killed process 112867 (vault) ... oom_score_adj:1000
```

`oom_score_adj: 1000` is BestEffort: first in line. The api pods are Burstable (requests below limits) and the control plane is Guaranteed-like (`-997`), so Vault went first. Because Vault was in dev mode, its secrets went with it, and `install.sh` had to be run again.

| QoS class | When | Killed |
|---|---|---|
| Guaranteed | requests equal limits, for every container | last |
| Burstable | some requests, not equal to limits | in between, by how far over its request it is |
| BestEffort | no requests or limits at all | first |

---

## Probes

**Liveness asks "is the process wedged", readiness asks "should this pod get traffic now", and startup protects slow starts from liveness.** They fail differently: liveness restarts the container, readiness removes it from the Service and restarts nothing.

| Probe | Path | Period × failures | Why these numbers |
|---|---|---|---|
| startup | `/healthz` | 2s × 30 | up to 60s to start before liveness counts; the api starts in about 2s |
| readiness | `/readyz` | 5s × 2 | out of the Service within 10s of trouble |
| liveness | `/healthz` | 10s × 3 | 30s of failure before a restart; restarts are expensive |

**Liveness must not check a dependency.** If it checked DynamoDB, a database blip would fail liveness on every pod together, and every pod would restart together: an outage caused by the probe. `/healthz` answers from the process alone.

---

## Kustomize and Helm

**Kustomize for the environments, Helm for something other people install.**

| | Kustomize | Helm |
|---|---|---|
| What you edit | plain YAML, patched | templates rendered from values |
| A typo in a value | a patch targeting nothing fails the build | **ignored without a word**, unless a schema forbids unknown keys |
| Rolling on config change | built in (hashed names) | a `checksum/config` annotation you remember to add |
| Debugging | `kubectl kustomize overlays/prod` | `helm template` |
| Good at | a few environments of your own app | packaging for others, with versions and releases |

The chart's `values.schema.json` rejected six bad values at `helm template` time:

| `--set` | Rejected because |
|---|---|
| `replicaCount=0` | minimum 1 |
| `image.pullPolicy=Sometimes` | not one of `Always`, `IfNotPresent`, `Never` |
| `image.tag=latest` | `latest` is refused; it turns the pull policy to `Always` (Project 10) |
| `resources.limits.cpu=500m` | the chart refuses CPU limits on purpose |
| `secrets.externalSecret.refreshInterval="15 seconds"` | not a duration |
| `replicas=3` | **unknown key**; without `additionalProperties: false`, Helm would render 2 replicas and say nothing |

The last row is Helm's version of Project 10's selector typo. The `not` rules have a weakness: they fail with `'not' failed`, which says nothing about why.

> Further reading: [Kustomize](https://kubectl.docs.kubernetes.io/references/kustomize/), [Helm values schema](https://helm.sh/docs/topics/charts/#schema-files)

---

## What went wrong while building this

- **The node ran out of memory, and Vault and the API server went with it.** Docker Desktop's VM (7.65 GiB) is shared by minikube and every other container on the laptop, here about 4.6 GiB of unrelated services. The minikube profile was 63 days old and had 6 GiB, because `minikube start --memory 4096` does nothing to an existing profile. With two environments, Vault, External Secrets and two Java DynamoDBs, the VM ran out. The prod namespace was deleted and minikube stopped, to protect the other containers. `docs/SETUP.md` now says to check `docker stats` first.
- **The readiness evaluation could not finish** for that reason. It was completed in Project 12; see [Evaluation](#evaluation).
- **The first secret value was the wrong shape** for DynamoDB Local 2.x.
- **`store.py` ignored credentials in the environment** (`kwargs.setdefault`).
- **A memory request above its limit** was refused by the API server, before any pod.
- **`kubectl top` led to the wrong floor**: 62Mi working set, 34Mi anonymous.
