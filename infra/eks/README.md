# infra/eks

The cluster Projects 13 and 14 deploy to. Roughly **$0.21/hour** while it exists,
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
| Managed node group | 2 × `t3.medium`, fixed size | $0.083/hr |
| Addons | vpc-cni, kube-proxy, coredns, **eks-pod-identity-agent** | $0 |
| GitHub OIDC provider + deploy role | Scoped to one repo, Edit on one namespace | $0 |
| Pod Identity association | ServiceAccount `api` → a DynamoDB role | $0 |
| DynamoDB table | On-demand, always-free tier | $0 |

A `Service` of type LoadBalancer adds an NLB at ~$0.023/hr. Terraform does not
create it and does not know about it — see the teardown note below.

## The two identities, which are not the same thing

`identity.tf` is how a **pod** gets AWS credentials: EKS Pod Identity binds a
ServiceAccount to an IAM role, and the agent hands the pod short-lived STS
credentials. No key exists.

`ci.tf` is how a **runner** gets them: GitHub OIDC, then a separate EKS access
entry for authorization *inside* the cluster. Authentication and authorization
are different resources here, and an IAM principal with no access entry
authenticates perfectly and then gets `Unauthorized` from the API server.

Neither is a job for a secrets manager. Doppler (Project 11) holds application
secrets; putting an AWS key in it would undo both of these files.

## Teardown

Use `make eks-down`, not `terraform destroy`.

`terraform destroy` alone will hang and then fail if a `Service` of type
LoadBalancer is live: Kubernetes created that ELB, Terraform has never heard of
it, and its ENIs hold your subnets open. `scripts/eks-down.sh` deletes those
Services first, then runs destroy, then deletes anything that survived, then
sweeps. It is safe to run twice.

State is **local**, deliberately — remote state is Project 8's subject. If you
lose the state file, `make eks-down` still empties the account, because it does
not rely on Terraform knowing what exists.
