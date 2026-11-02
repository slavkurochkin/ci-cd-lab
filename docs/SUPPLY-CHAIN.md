# Supply chain and policy enforcement

Decide at admission what may run, not in review. Project 17: CI signs every image with cosign; Kyverno refuses unsigned images, images by tag, foreign images, root and privileged containers; the deploy identity can update Deployments and nothing else; External Secrets copies tokens from SSM into the api.

| Path | What |
|---|---|
| [`.github/workflows/reusable-service-ci.yml`](../.github/workflows/reusable-service-ci.yml) | keyless `cosign sign`, and a `verify-signature` job with no permissions |
| [`deploy/platform/`](../deploy/platform) | the admission policies, the namespaces and the deploy identity |
| [`deploy/platform/tests/refused.yaml`](../deploy/platform/tests/refused.yaml) | eight objects the policies must refuse |
| [`scripts/policy-check.sh`](../scripts/policy-check.sh) | runs every environment and every refused object through the policies, offline |
| [`infra/eks/secrets.tf`](../infra/eks/secrets.tf) | the SSM roles and the permissions boundary |
| [`app/api/src/api/tokens.py`](../app/api/src/api/tokens.py) | admin tokens read from a mounted Secret on each request |

```bash
./scripts/policy-check.sh                    # needs the kyverno CLI (docs/SETUP.md)
TF_VAR_node_count=3 make platform-up         # EKS + Argo CD + Kyverno + External Secrets
```

Run November 2, 2026: GitHub Actions, Kyverno 1.19.1 and External Secrets 2.13.0 on EKS 1.35, three `t3.small` nodes.

---

## Evaluation

| Roadmap check | Result |
|---|---|
| An unsigned image is rejected at admission with a clear message | **Met.** An image pushed with no signature was refused for cluster admin and for the deploy identity: `image is not signed by this repository's CI`. The same pod with a signed digest was admitted. |
| The deploy ServiceAccount cannot read Secrets or create Pods directly | **Met.** 13 `can-i` checks: only `patch deployments` in dev and staging is allowed. Reading a Secret and creating a Pod were refused for real. |
| Rotating a value in SSM updates the pod without a redeploy | **Not measured yet.** The secret store never became Ready on the cluster (see the last section), so the api pods never started. The fix is in this change and is applied at the next session. |

---

## Signing: what counts as a signature

**Verify the signer, not that a signature exists.** CI signs each image keylessly: GitHub's OIDC token gets a short-lived Fulcio certificate naming the workflow, and the signature is logged in Rekor. The check pins the identity to `reusable-service-ci.yml` on `main` or a `v*` tag of this repository. Kyverno's own image, signed by Kyverno's CI, is refused by the same policy.

The surprise: every image CI built since Capstone A already passed. `cosign verify` 3.x and Kyverno both read Sigstore bundles from the registry, and GitHub's `attest-build-provenance` writes one, signed by the same workflow certificate. A provenance attestation counts as a signature. To get an image that fails, one was pushed by a throwaway workflow with no signing step and no attestation (`cosign verify`: `no signatures found`), used for the test, and deleted.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Existence check** | the policy asks for any signature, or any signer | a signature from someone else's CI passes | a green admission for an image this repository never built |
| **Attestation as signature** | provenance is attached by the same workflow | the "unsigned" test image is signed after all | the rejection test passes when it should fail, and nobody notices the test proves nothing |
| **A skipped verify job** | `verify-signature` needs a job that was skipped | the skip spreads down the `needs` chain | a green pipeline in which the worker's signature was never checked (fixed in #104 with `always()` and a result check) |

> Further reading: [Sigstore: keyless signing](https://docs.sigstore.dev/cosign/signing/overview/)

---

## Admission: refused, and why

**Refuse at admission what you would refuse in review.** Four policies in `deploy/platform/`: signed by this repository's CI; only `ghcr.io/slavkurochkin/ci-cd-lab/` images, by digest; `runAsNonRoot: true` on every container; no privileged containers. Each object below was sent with `kubectl create` on the cluster:

```
unsigned             require-signed-images: image is not signed by this repository's CI
foreign-image        pinned-own-images: only ghcr.io/slavkurochkin/ci-cd-lab/ images may run here; refused: nginx:latest
own-image-by-tag     require-signed-images error: failed to resolve digest ... sha-44e43e9: MANIFEST_UNKNOWN
no-run-as-non-root   non-root: every container must set runAsNonRoot: true ...; not set for: api
container-overrides  non-root: (same)
privileged           non-root: privileged containers are not allowed
Deployment, nginx    pinned-own-images: ... refused: nginx:1.29
zero digest          require-signed-images error: ... MANIFEST_UNKNOWN
kubectl debug        pinned-own-debug-images: debug containers must use a ghcr.io/slavkurochkin/ci-cd-lab/ image by digest; refused: busybox:1.36
```

`scripts/policy-check.sh` runs the same objects and every environment through the Kyverno CLI in CI (`policy.yml`), so a bad change fails the pull request before Argo CD sees it.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Autogen switched off** | a policy matching Pods also matches `pods/ephemeralcontainers` | Kyverno stops generating the Deployment rule, with no warning | a bad Deployment is admitted; its ReplicaSet then fails to create pods, and the Deployment just sits at 0 ready |
| **Errors that refuse** | `failurePolicy: Fail` and a registry lookup that fails | an error refuses the pod the same as a failed check | a tag that no longer exists is refused with `MANIFEST_UNKNOWN`, not a policy message |
| **CLI counts, no reasons** | `kyverno apply` on an image it cannot fetch | the CLI reports `error: 1` and nothing else | the offline check must count errors as refusals, or it fails for the wrong reason |

The debug policy is split from the Pod policy for the first row. On the cluster it shows `READY false` (its reporting lacks permissions on `pods/ephemeralcontainers`) and still refuses, as the last line shows.

> Further reading: [Kyverno: ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)

---

## The deploy identity

**Give the deployer Deployments in dev and staging, and nothing else.** `deployers/deployer` is bound to a ClusterRole that can get, list, watch, patch and update Deployments, through RoleBindings in `api-dev` and `api-staging`. Prod changes only through Git.

```
get/list secrets -n api-dev      no        create pods -n api-dev       no
create pods/exec -n api-dev      no        get pods, pods/log -n api-dev  no
create/delete deployments        no        create rolebindings          no
patch deployments -n api-prod    no        patch externalsecrets        no
patch deployments -n api-dev     yes       patch deployments -n api-staging  yes
```

`kubectl set image` to the unsigned digest, as the deployer: refused by `require-signed-images`.

RBAC alone is not enough. A server dry-run, as the deployer, added a volume from the `admin-tokens` Secret to the Deployment's pod template, and it was accepted. Anyone who can change a Deployment can mount any Secret in its namespace into a pod and read it from there. The admission policies limit what that pod can run, which is why both are needed.

> Further reading: [Kubernetes: RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)

---

## Secrets from SSM

**The namespace an ExternalSecret lives in decides what it can read, not the key it asks for.** External Secrets runs one controller for every namespace. Its role can only assume `lab-secrets-reader`, with the session tag `esoNamespace` set to the ExternalSecret's namespace (`sessionTagsPolicy: Simple`). That role reads `/ci-cd-lab/${aws:PrincipalTag/esoNamespace}/*`. The ClusterSecretStore accepts only `api-dev`, `api-staging` and `api-prod`. A permissions boundary caps every pod role in the cluster.

The api reads its admin tokens from the mounted Secret file on each request, rereading when the file changes. An environment variable would be read once, at start.

What happened on the cluster: the store stayed `InvalidProviderConfig`. External Secrets validates a ClusterSecretStore by assuming the reader role outside any namespace, and the first trust policy required `esoNamespace` to match `api-*`:

```
AccessDenied: ... assumed-role/lab-eso-controller/... is not authorized to perform:
sts:TagSession on resource: arn:aws:iam::<account>:role/lab-secrets-reader
```

Every ExternalSecret then refused with `ClusterSecretStore "ssm" is not ready`, Argo CD held the api Deployments behind them, and no api pod started. The condition is removed in this change; the read policy and the store's namespace list still do the isolation. Applying it needed a Terraform apply during the session that was not available, so the rotation, the cross-namespace AccessDenied and the boundary test wait for the next session.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **One role for every namespace** | the controller's own role reads `/ci-cd-lab/*` | an ExternalSecret in dev asks for prod's key | prod's token in a dev Secret, synced without an error |
| **Validation outside a namespace** | a trust condition on the namespace tag | the store's own check fails it | `InvalidProviderConfig`, then every ExternalSecret `not ready` |
| **Secret as environment variable** | `envFrom` a synced Secret | the value is read once at start | the Secret changes and the pod keeps the old token until it restarts |

> Further reading: [External Secrets: AWS Parameter Store](https://external-secrets.io/latest/provider/aws-parameter-store/)

---

## What went wrong while building this

- **Nothing was refused by the first rejection test.** The "unsigned" image carried a provenance attestation, which counts as a signature.
- **The secret store never became Ready**, for the reason above. It cost the rotation measurement.
- **`make platform-up` stopped at once** without `AWS_LAB_REGION`, and **`make eks-down` stopped** at its region confirmation when run without a terminal (`echo us-east-1 | make eks-down`). Neither created or deleted anything.
- **The policy message named one workflow** (`lab-03-ci.yml`) when `publish.yml` signs through the same reusable workflow. Reworded.
- **Two nodes were not enough.** Kyverno and External Secrets add pods past the 22 two `t3.small` nodes hold; the session ran three.
- **Cluster time**: `make platform-up` started 21:49 UTC, `make aws-sweep` printed `Account is clean.` at 22:24. About 35 minutes at about $0.21/hr, roughly $0.12 of credit.
