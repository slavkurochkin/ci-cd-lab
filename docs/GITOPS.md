# GitOps with Argo CD

The cluster pulls its state from Git instead of CI pushing into it. CI's last step is a pull request that changes one digest; Argo CD notices the merge and rolls the environment out. Project 14, on EKS.

| Path | What |
|---|---|
| [`deploy/bootstrap/root.yaml`](../deploy/bootstrap/root.yaml) | the one Application applied by hand |
| [`deploy/apps/`](../deploy/apps) | one Application per file: Argo CD itself, `api-dev`, `api-staging` (app-of-apps) |
| [`deploy/argocd/`](../deploy/argocd) | Argo CD v3.5.6, pinned, with resource requests |
| [`deploy/envs/dev`](../deploy/envs/dev), [`staging`](../deploy/envs/staging) | **what runs in each environment**: a digest, a replica count, `ENVIRONMENT` |
| [`k8s/overlays/eks/table-check.yaml`](../k8s/overlays/eks/table-check.yaml) | a Sync hook that checks the table before a rollout |
| [`.github/workflows/promote-dev.yml`](../.github/workflows/promote-dev.yml) | CI's last step: a pull request bumping dev's digest |

```bash
make eks-up               # ~15 min; billing starts
make argocd-bootstrap     # Argo CD, then the root Application; everything else comes from Git
kubectl -n argocd get applications
make eks-down
```

Run on EKS 1.35, 2 × `t3.small`, Argo CD v3.5.6, October 2026.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| No CI job holds cluster credentials any more | `deploy-eks.yml` and the `lab-eks-deploy` role are gone (`aws iam get-role`: `NoSuchEntity`). No workflow calls `kubectl` or `aws eks`, the promote workflow has no AWS role and no `id-token` permission, and `gh secret list` is empty. |
| A manual change to a live Deployment is reverted within the sync interval | An image change was reverted in **0.4s**, a replica change in **2.3s**. An added env var was **never** reverted, and the Application stayed `Synced`. See below. |
| "What is running in staging?" is answered by a file in Git | `deploy/envs/staging/kustomization.yaml`, `digest: sha256:4cfbe4d8…`, and `git log -- deploy/envs` lists every promotion. |
| A cluster destroyed and rebuilt returns to its declared state without deploying anything | `make eks-down` (24 resources destroyed, sweep clean), `make eks-up`, then only `make argocd-bootstrap`: both environments **Synced and Healthy 71s** after the bootstrap started, on the digest Git declares (`4cfbe4d8…`), 1 and 2 replicas, serving orders. The data did not come back; see the drill. |

---

## Push and pull: who holds the key

**Let the cluster pull, so nothing outside it needs a credential for it.** In Project 13 the deploy job held a role that could edit the `lab` namespace. Anyone who could change that workflow on `main` could use it. Now the only identity that can change the cluster runs inside the cluster: Argo CD's own ServiceAccount. It reads a public repository over HTTPS, so it needs no Git credential either.

| | Push (Project 13) | Pull (this project) |
|---|---|---|
| Who changes the cluster | a CI job, with an IAM role and an access entry | Argo CD, inside the cluster |
| What CI needs | cluster access | write access to a pull request |
| What is running | whatever the last successful run applied | what `main` says, always |
| A change made by hand | stays until the next deploy | reverted (for fields Git declares) |
| Cluster lost | redeploy every service | bootstrap Argo CD; it rebuilds the rest |

The config lives in `deploy/` in this repository. Most teams keep it in a separate repository, so that a config change does not run the app's CI and the two have different people allowed to merge. Here one repository keeps the lab self-contained; the cost is visible below, where every merge to `main` produces a new promotion pull request.

> Further reading: [Argo CD core concepts](https://argo-cd.readthedocs.io/en/stable/core_concepts/)

---

## Bootstrap: one Application by hand, the rest from Git

**Apply one thing by hand, and make it the thing that applies everything else.** `make argocd-bootstrap` applies `deploy/argocd` (Argo CD itself) and `deploy/bootstrap/root.yaml`. The root Application points at `deploy/apps`, and each file there is another Application. That includes `argocd.yaml`, which points back at `deploy/argocd`: from then on, an Argo CD upgrade is a pull request changing the version in that file.

On a fresh cluster, from the start of the bootstrap command:

```
t=35s  api-dev=OutOfSync/Healthy  api-staging=OutOfSync/Healthy  argocd=—                 root=Synced/Healthy
t=46s  api-dev=OutOfSync/Healthy  api-staging=OutOfSync/Healthy  argocd=Synced/Progressing root=Synced/Healthy
t=56s  api-dev=Synced/Healthy     api-staging=Synced/Healthy     argocd=Synced/Healthy     root=Synced/Healthy
```

Each environment then served its own name (`'environment': 'dev'`, `'environment': 'staging'`) and wrote an order to DynamoDB and read it back, through Pod Identity bound in its namespace.

**Upstream Argo CD sets no resource requests.** All seven of its workloads would be BestEffort, first to be killed when a node runs short; Project 11 watched that happen to Vault. `deploy/argocd` adds requests for the application controller, repo server, server and redis, and scales Dex (single sign-on) and notifications to 0. On two 2 GiB nodes that is memory the api needs.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **`stable` instead of a version** | `…/argo-cd/stable/manifests/install.yaml` | a rebuild next month installs a different Argo CD | the same Git commit produces a different cluster |
| **Prune on Argo CD's own Application** | `prune: true` in `apps/argocd.yaml` | a bad change to `deploy/argocd` deletes part of Argo CD | the tool that would undo the mistake is the thing it removed |
| **CRDs applied client-side** | `kubectl apply` without `--server-side` | the `applicationsets.argoproj.io` CRD is 335 KiB, and client-side apply copies it into an annotation limited to 256 KiB | `metadata.annotations: Too long`; `make argocd-bootstrap` uses `--server-side` |

---

## Self-heal: what it puts back, and what it never sees

**Self-heal reverts changes to fields Git declares. A field Git does not mention is not drift, and stays.** Three changes to the live staging Deployment, each timed until it was back:

| Change | Reverted after |
|---|---|
| `kubectl set image` to a `:sha-c368d34…` tag | **0.4s** |
| `kubectl scale --replicas=5` (Git says 2) | **2.3s** |
| `kubectl set env DEBUG=true` (Git declares no `env`) | **not reverted in 120s**; `sync=Synced health=Healthy` |

The first two were fast because Argo CD watches the resources it manages and reacts to the change event; the polling interval (below) is for changes in Git. The image change did happen: ReplicaSet `api-56fb77b87`, with the tag, was created and scaled to 0 within the second. The replica change scaled the ReplicaSet to 5 and back.

The env var is the one to remember. It rolled out to both staging pods, and Argo CD reported the Application as `Synced`. With server-side apply each field has an owner, and Argo CD compares only the fields it owns. `DEBUG` belongs to `kubectl-set`, so as far as Argo CD can tell, nothing differs from Git. It was removed by hand.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Edit to a declared field** | `kubectl edit` the image, replicas, a label | self-heal reverts it | a ReplicaSet that existed for a second; the edit "did not take" |
| **Field Git does not declare** | an added env var, annotation or sidecar | not drift by Argo CD's comparison | `Synced`, `Healthy`, and a pod running config no file mentions |
| **Self-heal off** | `automated` without `selfHeal` | drift is reported but left alone | `OutOfSync` in the UI until someone syncs |

> Further reading: [Automated sync policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)

---

## Ordering: sync waves and a hook

**When one step must succeed before the rollout, make it a hook in an earlier wave.** Each environment syncs in three waves:

| Wave | What | Why there |
|---|---|---|
| −2 | ServiceAccount `api`, ConfigMap `api-config-…` | the check below runs under that ServiceAccount and reads that ConfigMap |
| −1 | Job `table-check`, an Argo CD `Sync` hook | asserts the table is `ACTIVE` with key `order_id`, through Pod Identity |
| 0 | Deployment, Service, PodDisruptionBudget | only once the check passed |

The check printed `lab-orders: status=ACTIVE key=['order_id']` in both namespaces, before any api pod existed. It is a stand-in for a database migration. The key is the one Project 13 found wrong (`pk`) in the Terraform: with this hook, that mistake stops the sync instead of failing every order after the rollout.

It is not a `PreSync` hook, the usual choice for migrations, because `PreSync` runs before anything is applied. On a new namespace the ServiceAccount and ConfigMap it needs would not exist yet, and the Job would sit in `CreateContainerConfigError`.

> Further reading: [Sync phases and waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)

---

## Promotion is a pull request

**To change what runs in an environment, change its file.** Dev, by CI:

```
20:55  Lab 03 CI passes on main (e0c89ac); Promote to dev opens #69, auto-merge on
       #69's checks: action_required (held: a bot opened the pull request)
       held runs approved by hand; checks run and pass
21:12:27  #69 merged:  deploy/envs/dev  digest: sha256:20a95bbc… → sha256:4cfbe4d8…
21:14:25  Argo CD syncs api-dev (1m58s later). dev serves git_sha e0c89ac.
```

Staging, by a person: #70 copies dev's digest into `deploy/envs/staging`, one line. Merged at 21:15:27; Argo CD synced at 21:20:35, **5m 8s** later. There is no webhook from GitHub to the cluster, so Argo CD notices a merge on its next poll of Git: `timeout.reconciliation` is 120s, plus up to 60s of `timeout.reconciliation.jitter`, in v3.5.6's defaults. That covers dev's 1m58s. Staging's 5m8s is longer than the poll interval plus a two-pod rollout explains, and this session did not find out why.

What staging runs is now a question for Git:

```
$ git log --oneline -- deploy/envs
65b12ae Promote e0c89ac to staging (#70)
bf43c18 Promote e0c89ac to dev (#69)
e0c89ac Project 14 (part 1): Argo CD pulls from Git; CI only proposes a digest (#68)
```

The digest is from GHCR, not ECR. GHCR is public, so the nodes pull with no credentials and no AWS account ID is committed. Main CI pushes the same digest to both registries.

**The pull request from CI needs one approval.** A pull request opened with `GITHUB_TOKEN` does start its workflows, but GitHub holds them as `action_required` until someone approves the run. Auto-merge then waits on checks that never report. Two things did not help:

- The workflow first started the required checks itself with `gh workflow run` on the branch. The api image job's ECR Public role trusts `pull_request` events and `main`, not `workflow_dispatch` on a branch: `Not authorized to perform sts:AssumeRoleWithWebIdentity`. That failed run's `ci-passed` then blocked the merge. Removed.
- Every merge to `main` builds a new image (the commit is stamped into it), so every merge opens another promotion. Merging #70 opened #71, `Promote 65b12ae to dev`, which stayed held during this session.

A GitHub App token instead of `GITHUB_TOKEN` would remove the click, at the cost of a private key to store and rotate. This repository keeps the click: approving a promotion is a reasonable place for a person.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Bot pull request, checks held** | the PR is opened with `GITHUB_TOKEN` | runs wait for approval | `action_required` runs; auto-merge waiting with no checks reported |
| **"Allow GitHub Actions to create pull requests" off** | the repository default | `gh pr create` is refused | the promote run fails at the pull request step |
| **No webhook** | the cluster cannot be reached from GitHub | Argo CD finds merges by polling | 2 to 5 minutes between merge and rollout, measured |

---

## The rebuild drill

**Destroy the cluster, build a new one, and give it only the bootstrap.** If what comes back matches Git, the cluster was declared. If something is missing, someone had been changing it by hand.

Before: dev and staging both declared `sha256:4cfbe4d8…` (#69, #70). `make eks-down` destroyed 24 resources and the sweep printed `Account is clean.` `make eks-up` built a new cluster whose only namespaces were `default`, `kube-node-lease`, `kube-public` and `kube-system`. Then `make argocd-bootstrap`, and nothing else:

```
t=43s  root=—                                     (bootstrap command returns)
t=49s  api-dev=OutOfSync  api-staging=OutOfSync  argocd=—                 root=Synced/Healthy
t=60s  api-dev=OutOfSync  api-staging=OutOfSync  argocd=Synced/Progressing
t=65s  api-dev=Synced/Healthy  api-staging=Synced/Progressing  argocd=Synced/Healthy
t=71s  api-dev=Synced/Healthy  api-staging=Synced/Healthy      argocd=Synced/Healthy
```

```
api-dev:     1/1 ready, api@sha256:4cfbe4d8…   lab-orders: status=ACTIVE key=['order_id']   e0c89ac dev, order written
api-staging: 2/2 ready, api@sha256:4cfbe4d8…   lab-orders: status=ACTIVE key=['order_id']   e0c89ac staging, order written
```

Promotion #71, opened by CI while the drill ran, was still waiting for its approval, so the declared state did not move during it.

**Git restores the declared state, not the data.** The `lab-orders` table is part of `infra/eks` and was destroyed with the cluster. An order written before the drill (`f5ce75c4…`) was gone afterwards; the table held only the 2 orders written after it. A real table lives outside the cluster's lifecycle, with its own backups, as Capstone B's do in `infra/envs`.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Change made only in the cluster** | `kubectl apply` of something not in `deploy/` | the rebuild does not have it | a feature that "worked yesterday" and is missing after the rebuild |
| **Data in the cluster's lifecycle** | a table, volume or bucket created and destroyed with the cluster | the rebuild brings back an empty one | every resource `Healthy`, every record gone |
| **Bootstrap not in Git** | Argo CD installed by hand, with a version from memory | the rebuild installs a different Argo CD | the same commit produces a different platform |

---

## What went wrong while building this

- **The required checks never ran on CI's first promotion pull request.** They were held for approval, and the extra runs the workflow started failed on an AWS trust policy (above). Fixed by removing the extra runs and approving the held ones; the remaining approval step is documented in the workflow.
- **An added env var survived self-heal, and the Application said `Synced`.** Not a bug in Argo CD: it compares the fields it owns. It was removed by hand.
- **Upstream Argo CD has no resource requests**, so it would run BestEffort on 2 GiB nodes. Requests added in `deploy/argocd`.
- **A `PreSync` hook would not have worked on a new namespace**, because nothing it needs exists yet. Found while designing the table check; it is a `Sync` hook in wave −1.
- **Committing a digest would have committed the account ID**, because ECR's hostname contains it. The environments pin GHCR instead.
