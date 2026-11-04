# Deploying from CI

> **Retired in Project 14.** Argo CD now pulls from Git, so `deploy-eks.yml` and the `lab-eks-deploy` role were removed: no CI job holds cluster credentials. They are in Git history at commit `f5fb462`. See [GITOPS.md](GITOPS.md).

A workflow that deploys the api to a real EKS cluster it cannot see, holds no AWS key and no kubeconfig, and reports success only after the rollout has converged and a smoke test has passed through the load balancer. Project 13, about $0.20 for the session.

| Path | What |
|---|---|
| [`.github/workflows/deploy-eks.yml`](../.github/workflows/deploy-eks.yml) | image job (digest) → deploy job (apply, gate, smoke, rollback) |
| [`.github/scripts/smoke-eks.sh`](../.github/scripts/smoke-eks.sh) | what "deployed" has to mean |
| [`k8s/overlays/eks/`](../k8s/overlays/eks) | the shared base, minus local-only pieces, plus Pod Identity and a LoadBalancer |
| [`infra/eks/`](../infra/eks) | the cluster, the deploy role, the Pod Identity role and the table |
| [`scripts/eks-down.sh`](../scripts/eks-down.sh) | teardown in the order AWS needs |

```bash
make eks-up                                         # ~15 min; billing starts
gh variable set AWS_EKS_DEPLOY_ROLE_ARN --body "$(terraform -chdir=infra/eks output -raw deploy_role_arn)"
gh workflow run deploy-eks.yml                      # deploy main
gh workflow run deploy-eks.yml -f fault=crash       # must fail and roll back
gh workflow run deploy-eks.yml -f fault=wrong-version
ASSUME_YES=1 make eks-down                          # always last
```

Run on EKS 1.35 (`v1.35.9-eks`), 2 × `t3.small`, us-east-1, October 2026. The cluster existed for about 65 minutes.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| A deliberately broken image causes a failed workflow and an automatic rollback | Two kinds, both **failed** runs with an automatic `rollout undo`. `fault=crash`: caught by the rollout gate, 58s after apply. `fault=wrong-version`: passed the gate, caught by the smoke test (`git_sha=fault-injected`). |
| The deployed pod's image is a digest, not a mutable tag | Both pods ran `…/ci-cd-lab/api@sha256:2249bd7a…`, the digest main CI published as `sha-c368d34…`; later `@sha256:20a95bbc…` for `ca57f84`. |
| The workflow never reports success while pods are still `ContainerCreating` | The gate step logged `0 of 2 updated replicas are available...` then `1 of 2` before `successfully rolled out`, and the crash fault failed the run at that step. |
| No AWS key and no kubeconfig in GitHub secrets | `gh secret list` and `gh secret list --env eks` both print nothing. The repository has no secrets at all. |
| `make eks-down` leaves `make aws-sweep` completely empty, including the load balancer | `Destroy complete! Resources: 27 destroyed.` then the sweep: EKS clusters, EC2 instances, load balancers, Classic ELBs, EBS volumes, unattached EIPs all `none`. `Account is clean.` |

---

## The runner cannot see the cluster, and does not need to

**Give the deploy job an identity, not a credential.** Projects 10–12 ran on minikube on the laptop, which no GitHub runner can reach. EKS's API server is public, so reachability is solved; access is not. The three usual answers:

| | How it works | What it costs you |
|---|---|---|
| **`kind` in the runner** | create a throwaway cluster inside the job | it tests manifests, not a deploy. Nothing real is changed, which is why earlier "deploys" in CI were quietly cheating |
| **Self-hosted runner** | a runner inside the network that can see the cluster | a machine to patch, and a credential that lives on it |
| **Push with OIDC** (this project) | the job proves who it is to AWS, gets a 1-hour role session, generates a kubeconfig | the cluster API must be reachable from the internet |
| **Pull (GitOps)** | the cluster pulls from Git | Project 14 |

The deploy job's whole credential chain, with nothing stored:

```
GitHub OIDC token (sub = repo:slavkurochkin/ci-cd-lab:environment:eks)
  → sts:AssumeRoleWithWebIdentity → lab-eks-deploy (1-hour session)
  → aws eks update-kubeconfig        (needs only eks:DescribeCluster)
  → aws eks get-token, per kubectl call
  → EKS access entry → AmazonEKSEditPolicy, namespace lab only
```

**Authentication is not authorization.** IAM decides who the job is; the access entry decides what it may do in the cluster. Run from the job:

```
kubectl -n lab auth can-i patch deployments   → yes
kubectl auth can-i list nodes                 → no
```

**A role of its own, trusted from one environment.** The shared CI role trusts `main` and `v*` tags. A job with `environment: eks` presents a different OIDC subject, `…:environment:eks`, so it could not use that role at all. The deploy role trusts exactly that subject (`StringEquals`, no wildcard), and the `eks` environment only allows protected branches. The role is created and destroyed with the cluster: between sessions there is no deploy credential to misuse.

> Further reading: [Configuring OpenID Connect in AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services), [EKS access entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)

---

## Pod Identity: the pod's credentials

**Bind a ServiceAccount to a role, and put nothing in the pod.** The association in `infra/eks/identity.tf` names a namespace (`lab`) and a ServiceAccount (`api`). EKS injected this into each api pod:

```
AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
```

An endpoint and a token file, not a key. boto3 finds them without configuration. `grep -i "AWS_ACCESS_KEY|AWS_SECRET"` over the Deployment, ConfigMaps and Secrets in `lab`: 0 matches. The smoke test's order (`total 24.99`) was in the real `lab-orders` table, read back from the laptop with `aws dynamodb get-item`.

IRSA, the older mechanism, does the same through an OIDC provider per cluster and an annotation on the ServiceAccount. Every older cluster uses it; a new one should not need it.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **ServiceAccount name mismatch** | the pod runs as `default`, the association says `api` | no credentials, and nothing checks the names match | `Unable to locate credentials` from the SDK |
| **Agent addon missing** | no `eks-pod-identity-agent` | the injected endpoint answers nothing | the same message, with a correct association |
| **Trust policy without `sts:TagSession`** | `Action = "sts:AssumeRole"` only | Pod Identity always tags the session | `AccessDenied`, with no mention of tagging |

> Further reading: [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

---

## Deploy a digest, and pass it between jobs

**The image job hands the deploy job a digest, and only a digest.** Main CI already tests, scans and publishes every commit on `main` as `sha-<commit>`. The image job does not build again; it asks ECR what that tag points to, in 4 seconds:

```
sha-c368d34a29a4cb3ea46703edd5fbfa633a046739 is sha256:2249bd7a42cbc8f0abeebd7ceba108f90ac56c63517a51e33f72f4a2f80e6b16
```

The deploy job writes a two-line kustomization around `k8s/overlays/eks` that pins `newName` and `digest`, so the registry, and the account ID in it, is never committed. Running pods:

```
api-86744b97f9-7bk6v   ip-10-42-1-245   …/ci-cd-lab/api@sha256:2249bd7a…
api-86744b97f9-gcgdq   ip-10-42-0-160   …/ci-cd-lab/api@sha256:2249bd7a…
```

Only the digest crosses between jobs, for a second reason: the registry host contains the account ID, and once the credentials action masks it, GitHub drops any job output that contains a masked value.

---

## The gate, the smoke test, and the rollback

**`kubectl apply` returns when the API server has accepted the change. Gate on `kubectl rollout status`, then test what a user would notice.** The first deploy, step by step:

| Step | Time | What it logged |
|---|---|---|
| Apply | 4s | `deployment.apps/api serverside-applied` |
| Wait for the rollout | 6s | `0 of 2 updated replicas are available...` → `1 of 2` → `successfully rolled out` |
| Smoke test | 78s | `reachable after 15 attempt(s)` (a new load balancer), `/version: 20 of 20 answers from c368d34…`, `/orders: wrote c4bb7681… (total 24.99) and read it back` |

The smoke test asserts three things: the service answers through the load balancer, **every** answer comes from the commit this run deployed, and an order can be written and read back, which needs Pod Identity and the real table. "The pod is Running" is not one of them: a pod serving the wrong build is Running, and so is one with no AWS credentials.

**Two broken images, two different catches:**

```
fault=crash           run 41117226672
  Wait for the rollout   1 out of 2 new replicas have been updated...
                         error: deployment "api" exceeded its progress deadline      (58s)
  Roll back              deploy failed; rolling back to revision 1
                         now running: …/ci-cd-lab/api@sha256:2249bd7a…
fault=wrong-version   run 41118129503
  Wait for the rollout   deployment "api" successfully rolled out                      (5s)
  Smoke test             smoke: /version reports git_sha=fault-injected, expected ca57f84…
  Roll back              rolling back to revision 3 … successfully rolled out
```

Both runs ended **failed**. A rollback is a recovery, not a success, and a green run after one would hide that the commit is broken.

The two catches cost different amounts. The crash never served a request: with `maxUnavailable: 0` the old pods stayed until a new one was ready, and none ever was. The wrong version passed readiness and **served real traffic** through the load balancer for the seconds between the rollout finishing and the rollback completing. A smoke test after the deploy finds a bad build only after users can reach it.

**Where rollback is unsafe or impossible:**

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **First deploy fails** | no earlier revision | `rollout undo` has nothing to go to | the workflow says so and leaves the broken pods for inspection |
| **Change outside the pod template** | a new ConfigMap key, a Service change, a schema migration | undo restores only the Deployment's template | the old pods come back next to config or data they do not understand |
| **The next deploy after a rollback** | `rollout undo` writes the image under manager `kubectl` | server-side apply refuses to take the field | `Apply failed with 1 conflict: conflict with "kubectl" ... .image` (fixed; see below) |

**A record of what made each revision.** The workflow sets `kubernetes.io/change-cause` to the commit, run and fault:

```
REVISION  CHANGE-CAUSE
2         c368d34 run 41117226672 fault=crash
4         ca57f84 run 41118129503 fault=wrong-version
5         c368d34 run 41116848292 fault=none
6         ca57f84 run 41118329613 fault=none
```

`rollout undo` does not restore a revision number; it reissues the old template as a new revision. The first good deploy was revision 1, became 3 after the first rollback and 5 after the second, keeping its change-cause each time.

> Further reading: [kubectl rollout](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/)

---

## The load balancer belongs to Kubernetes

**Delete LoadBalancer Services before destroying the cluster.** `type: LoadBalancer` made the in-tree AWS cloud provider create a **Classic** ELB, `a068d23b…-149170119.us-east-1.elb.amazonaws.com`. No Terraform file mentions it, and `terraform destroy` would not have deleted it.

`make eks-down` deleted the Service first and polled AWS until the load balancer was gone, which it was at the first check. Terraform then destroyed 27 resources, but the internet gateway took **6m 53s**, waiting for the load balancer's network interfaces to be released. The node group took 8m 12s, the control plane 1m 50s.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Bare `terraform destroy`** | the Service still exists | the ELB holds ENIs in the subnets | the VPC or IGW destroy hangs, then fails |
| **Cluster deleted, ELB not** | the cluster went first, by console or a failed run | nothing will ever delete the ELB | `make aws-sweep` lists it under Classic ELBs, billing ~$0.025/hr plus its addresses |

---

## What went wrong while building this

- **Kubernetes 1.31 was the default, and it is in extended support.** Extended support bills the control plane at $0.60/hr instead of $0.10, with nothing else to show for it. Found with `aws eks describe-cluster-versions` before the first apply. Now 1.35, in standard support until March 2027.
- **The DynamoDB table's key was `pk`; the app writes `order_id`.** Every order would have failed with a `ValidationException`. Found by reading `store.py` against `identity.tf`, before the first apply.
- **The account cannot launch `t3.medium`.** It is on AWS's free plan, which only allows free-tier-eligible types. The node group sat in `CREATING` for 25 minutes with an empty health report; the reason was only in the Auto Scaling group's activity: `The specified instance type is not eligible for Free Tier`. Nodes are now `t3.small` (2 GiB, 11 pods), which also halves their cost.
- **The session was moved to another terminal mid-apply, which killed Terraform.** The cluster and everything before it were in the state; the node group existed in AWS but not in the state. It was deleted by hand (`aws eks delete-nodegroup`) and `make eks-up` re-run, which created only the 2 missing resources.
- **The first deploy after a rollback failed at `Apply`**, with the field conflict above, so the rollback that ran could never be followed by a fix. The workflow now applies with `--force-conflicts`: the pipeline owns the image field, and an undo is a temporary override. Project 10 met the same conflict from `kubectl scale`.
- **The account ID was in the public run logs** of the first three runs, through image references. `mask-aws-account-id: true` masks it from run 41118129503 on.
- **`scripts/eks-down.sh` was overwritten by mistake.** A `cat` from the wrong directory reported it missing, and a new one was written over it. The original was restored from Git; only the load-balancer wait and the tagged-leftover deletion were kept from the new one.
