# infra/eks

The cluster Projects 13 and 14 deploy to. Roughly **$0.19/hour** while it exists,
**$0** when it does not.

```bash
cp terraform.tfvars.example terraform.tfvars   # set github_repo
make eks-up                                    # ~15 min
# ... work the lab ...
make eks-down                                  # the last command of every session
```

## Why this is complete code and not a starter with gaps

Every other lab in this repository hands you a file with TODOs in it. This one
does not, because the cluster is the *setting* for Project 13, not its subject.
The lesson is the deploy workflow — OIDC, digest propagation, a gated rollout,
an automatic rollback. Making you hand-write a VPC first would teach Terraform
mechanics you already met in Track B and delay the part that is actually new.

Read it, though. It is commented for reading, and the comments are mostly about
the failure each line prevents.

## What it creates

| | | Cost |
|---|---|---|
| VPC, 2 public subnets, IGW | Two AZs because EKS requires two. No NAT. | $0 |
| EKS control plane | `authentication_mode = "API"` | $0.10/hr |
| Managed node group | 2 × `t3.small` (AL2023), fixed size; free-plan accounts cannot launch `t3.medium` | $0.042/hr |
| Addons | vpc-cni, kube-proxy, coredns, **eks-pod-identity-agent** | $0 |
| Public IPv4 | One per node (no NAT) | ~$0.01/hr |
| Pod Identity associations | ServiceAccount `api` in `api-dev`, `api-staging`, `api-prod`, each → its own role | $0 |
| DynamoDB tables | `lab-orders-<env>`, one per environment, each reachable only by its role. On-demand, always-free tier | $0 |

A `Service` of type LoadBalancer adds a Classic ELB, about $0.035/hr with its
addresses. Terraform does not create it and does not know about it; see the
teardown note below.

The api's namespaces are created by Argo CD, not here (`make argocd-bootstrap`,
Project 14). This stack owns the AWS side of each environment, and Argo CD
the cluster side; neither manages a resource the other does.

## How a pod gets AWS credentials

`identity.tf`: EKS Pod Identity binds the `api` ServiceAccount in each
`api-<env>` namespace to that environment's IAM role, and the agent hands the
pod short-lived STS credentials. No key exists, and a dev pod's credentials
reach only the dev table.

Until Project 14 a `ci.tf` here gave a CI deploy job its own role and an EKS
access entry. With Argo CD pulling from Git, no CI job needs the cluster, and
both were removed. They are in Git history (Project 13, `docs/DEPLOYING-FROM-CI.md`).

Not a job for a secrets manager. Vault (Project 11) holds application
secrets; putting an AWS key in it would undo this file.

## Teardown

Use `make eks-down`, not `terraform destroy`.

`terraform destroy` alone will hang and then fail if a `Service` of type
LoadBalancer is live: Kubernetes created that ELB, Terraform has never heard of
it, and its ENIs hold your subnets open. `scripts/eks-down.sh` deletes those
Services first, then runs destroy, then deletes anything that survived, then
sweeps. It is safe to run twice.

State is **local**. Project 7 moved the long-lived stacks to S3 and left this one, because nothing here outlives a session. If you
lose the state file, `make eks-down` still empties the account, because it does
not rely on Terraform knowing what exists.
