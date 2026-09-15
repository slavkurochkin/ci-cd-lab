# CI/CD Engineering Learning Roadmap

A project-based curriculum ordered from a first green check to a governed delivery platform.
Each project isolates one part of the path code takes from a laptop to production, includes a hands-on lab with a verifier, and ends with measurable evaluation.

Everything here runs on free tiers. See [docs/COST.md](docs/COST.md) for the exact boundaries and the resources this curriculum never provisions.

## The Stack

```
                    ┌─────────────────────────────┐
                    │  foundations/               │
                    │  DELIVERY_PRINCIPLES.md     │  ← read alongside, not before
                    └─────────────────────────────┘

  AUTOMATION ─────────────────────────────────────────────────────────
   1. Pipelines & the Build Contract
                    ↓
   2. Speed & Cost: Caching, Matrices, Artifacts
                    ↓
   3. Abstraction, Service Containers & the Local Loop
                    ↓
   4. Trust: Permissions, OIDC & Supply Chain
                    ↓
   5. Building & Publishing Containers
                    ↓
  ══════════ 🏁 Capstone A — The Golden Pipeline ══════════
                    ↓
  INFRASTRUCTURE ─────────────────────────────────────────────────────
   6. Terraform Fundamentals
                    ↓
   7. State, Drift & Collaboration
                    ↓
   8. Modules & Composition
                    ↓
   9. Terraform in CI
                    ↓
  ══════ 🏁 Capstone B — Reproducible Cloud Foundation ══════
                    ↓
  ORCHESTRATION ──────────────────────────────────────────────────────
  10. Kubernetes Fundamentals
                    ↓
  11. Configuration & Packaging
                    ↓
  12. Rollouts, Failure & Forensics
                    ↓
  13. Deploying from CI
                    ↓
  14. GitOps with Argo CD
                    ↓
  ═════════ 🏁 Capstone C — The Delivery Platform ═════════
                    ↓
  DELIVERY & GOVERNANCE ──────────────────────────────────────────────
  15. Progressive Delivery
                    ↓
  16. Observability & Deployment Signals
                    ↓
  17. Supply Chain & Policy Enforcement
                    ↓
  18. Reliability, Cost & Scale
```

---

## Project 1 — Pipelines & the Build Contract

**Goal:** Get one workflow running on every pull request, and make it impossible to merge without it.

### Concepts
- What continuous integration actually guarantees, and what it does not
- The GitHub Actions object model: workflow → job → step → action, and where the runner fits
- Events and triggers: `push`, `pull_request`, `workflow_dispatch`, `schedule`
- The **build contract** — the set of checks every change must survive: format, lint, type, test
- Runners: GitHub-hosted vs self-hosted, and what a fresh VM per job costs you in setup time
- Branch protection and required status checks — the mechanism that converts a workflow into a gate
- Reading a failed run: annotations, step logs, and the difference between a failing step and a failing job

### Build
- `.github/workflows/lab-01-ci.yml` running lint and tests for both `app/api` and `app/worker`
- Branch protection on `main` requiring both checks to pass
- A deliberately failing PR that proves the gate holds

### Tools
GitHub Actions, `ruff`, `pytest`, `vitest`, `gh` CLI

### Evaluation
- Every PR shows two required checks; neither can be bypassed by a normal push
- A PR with a failing test cannot be merged
- Total workflow wall-clock time recorded as your baseline for Project 2

### Key Lesson
A pipeline nobody is required to pass is documentation, not a gate. The value of CI is created entirely by branch protection.

---

## Project 2 — Speed & Cost: Caching, Matrices, Artifacts

**Goal:** Cut your pipeline's wall-clock time in half without removing a single check.

### Concepts
- Jobs run in parallel by default; `needs` is what makes them sequential — and every `needs` edge is latency you chose
- **Matrix builds**: one job definition, many runners, across languages and versions
- Dependency caching: how `actions/cache` keys work, why `restore-keys` prefixes matter, and how a key that never hits costs more than no cache at all
- Cache scoping rules on GitHub — branch isolation, the 10 GB repository limit, and eviction
- **Artifacts** vs cache: artifacts move data forward between jobs, cache moves data forward between runs
- `concurrency` groups: cancelling superseded runs instead of paying for work nobody will read
- Path filters and change detection in a monorepo — not building the worker when only the API changed

### Build
- `lab-02-ci.yml` with a matrix over both services and two runtime versions
- Correct cache configuration for `uv` and `npm`, with measured hit rates
- A `needs` graph that fans out then converges on a single required check
- A timing comparison table: baseline vs optimized, wall-clock and runner-minutes

### Tools
`actions/cache`, `actions/upload-artifact`, `dorny/paths-filter`

### Evaluation
- Second run of an unchanged branch is measurably faster than the first (cache hit)
- Changing only `app/api` does not run worker jobs
- Pushing twice quickly cancels the first run

### Key Lesson
Cache key design is the whole game. A key too specific never hits; a key too loose serves you someone else's dependencies.

---

## Project 3 — Abstraction, Service Containers & the Local Loop

**Goal:** Delete the copy-pasted YAML by turning your pipeline into an interface, test against a real dependency instead of a mock, and stop pushing to find out whether a workflow works.

### Concepts

**Abstraction**
- **Reusable workflows** (`workflow_call`): typed `inputs`, `outputs`, and `secrets`, and the `secrets: inherit` shorthand
- **Composite actions**: bundling steps that always travel together, and why they cannot contain jobs
- Choosing between them — a composite action replaces steps, a reusable workflow replaces jobs
- JavaScript and Docker actions — when leaving YAML is worth it
- Versioning your own actions: tags, moving major tags, and the SHA-pinning tension
- Calling workflows across repositories, and the permissions that requires
- The three-level limit on nested reusable workflows, and how to design within it
- Driving a matrix from an input with `fromJSON`, since matrices cannot be passed directly

**Service containers**
- `services:` — sidecar containers on the runner network, started before your steps
- Health checks: `--health-cmd`, `--health-interval`, `--health-retries`, and what "healthy" actually asserts
- The images that ship no health-check tool, and why a readiness wait-loop is then your job
- Port mapping, and why the address differs between a container job and a runner job
- Integration tests as a separate marker, so the fast suite stays fast
- When a real dependency beats a mock, and the cases where it does not

**The local loop**
- Testing a workflow without pushing: `act`, and what it cannot simulate (OIDC, most `github` context, cache backends)
- `workflow_dispatch` on a branch as the fallback when `act` will not do
- Why an edit-push-wait cycle is a feedback latency problem in its own right

### Build
- `.github/actions/setup-service/` — a composite action doing toolchain setup, cache restore, and install
- `.github/workflows/reusable-service-ci.yml` — one workflow, parameterized by service, exposing outputs
- `.github/workflows/lab-03-ci.yml` — two thin caller jobs and an aggregate check
- An integration job running the API's suite against DynamoDB Local as a service container
- `.actrc` and a `make ci-local` target for running jobs on your laptop

### Tools
`workflow_call`, composite actions, `services:`, `amazon/dynamodb-local`, `act`, `gh workflow view`

### Evaluation
- Adding a third service requires only a new caller job, no copied steps
- Changing the lint rule in one place changes it for both services
- The reusable workflow exposes at least one output the caller consumes
- The integration suite runs against a real DynamoDB and is skipped when one is absent
- You can run a job locally and see it fail before you push

### Key Lesson
Copy-pasted YAML is the technical debt you notice last and pay for longest. And a pipeline you can only test by pushing is a pipeline with a ten-minute edit loop — the thing every other lesson in this track is trying to eliminate.

---

## Project 4 — Trust: Permissions, OIDC & Supply Chain

**Goal:** Get to zero long-lived cloud credentials in your repository, and understand every place a pipeline can be attacked.

### Concepts
- `GITHUB_TOKEN` and the default permission set — scoping down from write-all to what each job actually needs
- **Environments**: required reviewers, wait timers, and environment-scoped secrets as a deployment gate
- Why `pull_request_target` on a public repository is dangerous, and the exact shape of the attack
- Script injection through `${{ github.event.* }}` interpolation, and why untrusted input belongs in `env:`, not inline
- **OIDC federation**: how a short-lived token from GitHub becomes a temporary AWS role session, and what the trust policy's `sub` claim must pin
- Third-party action risk: tag mutability, SHA pinning, and what a compromised action can reach
- Automated review: `actionlint` for correctness, `zizmor` for security, Dependabot for drift

### Build
- Explicit least-privilege `permissions:` on every job in the repo
- An AWS IAM OIDC provider and role, assumable *only* by this repo on this branch
- A workflow that reads an AWS caller identity with no stored secret
- All third-party actions pinned to 40-character SHAs, enforced by a check
- A `production` environment with a required reviewer

### Tools
`aws-actions/configure-aws-credentials`, `actionlint`, `zizmor`, AWS IAM

### Evaluation
- `gh secret list` contains no AWS access key
- The OIDC role cannot be assumed from a different branch or a fork
- `zizmor` reports no high-severity findings
- A push to `production` blocks on your approval

### Key Lesson
The credential you never issued is the one that cannot leak. OIDC is not a convenience feature; it removes an entire category of incident.

---

## Project 5 — Building & Publishing Containers

**Goal:** Produce an image you can prove came from a specific commit, built by a specific workflow, containing known dependencies.

### Concepts
- Multi-stage Dockerfiles: build tooling that never ships, and why layer order determines rebuild cost
- BuildKit cache backends: `gha`, registry cache, and inline cache
- Multi-architecture builds with `buildx` and QEMU — and what they cost you in time
- Tagging strategy: immutable digest, commit SHA, semantic version — and why `latest` is a trap
- Registries: GHCR vs ECR, authentication paths, visibility, and lifecycle policies
- **SBOM** — what a software bill of materials lists and what questions it answers during an incident
- Vulnerability scanning as a gate: severity thresholds, ignore files, and the maintenance burden they create
- **Build provenance attestation**: signed evidence linking image → commit → workflow run

### Build
- `app/api/Dockerfile` and `app/worker/Dockerfile`, both multi-stage and non-root
- A build workflow with registry cache, pushing SHA and semver tags to GHCR
- SBOM generation attached to each image
- A Trivy scan that fails the build on HIGH or CRITICAL
- Provenance attestation via `actions/attest-build-provenance`

### Tools
`docker/build-push-action`, `buildx`, `syft`, `trivy`, `cosign`

### Evaluation
- Image size under a stated budget for both services
- A rebuild with no source change is a near-total cache hit
- `gh attestation verify` succeeds against the pushed image
- Introducing a vulnerable dependency fails the pipeline

### Key Lesson
An image tag is a promise about reproducibility, and a mutable tag breaks that promise silently. Digests are the only identifier that cannot lie to you.

---

> ## 🏁 Checkpoint — Start [Capstone A: The Golden Pipeline](#capstone-a--the-golden-pipeline)
> You have finished the **Automation** domain (Projects 1–5). You know how to build, test, secure, and publish. Build Capstone A now to assemble those five projects into the single pipeline every later track will depend on.

---

## Capstone A — The Golden Pipeline

**Start after:** Project 5
**Builds on:** Projects 1–5
**Goal:** One reusable pipeline that takes any service in this repo from pull request to a signed, attested, scanned image — with no stored credentials.

**Scenario:** You are the first platform engineer on a small team. Two services exist today; five will exist next quarter. Whatever you build now is what every future service inherits.

### What You Build
- A single reusable workflow: lint → typecheck → test → coverage gate → build → SBOM → scan → sign → push to ECR via OIDC
- Two caller workflows, one per service, each configuration only
- Path-filtered triggering so a change to one service does not rebuild the other
- Automatic release notes and semantic version tagging on merge to `main`
- A `CONTRIBUTING.md` documenting the build contract for future contributors

### Integration Challenges (the point)
- The coverage gate must fail the build without becoming a number people game
- OIDC role trust must be tight enough to reject forks but loose enough for both callers
- Cache keys must be shared where useful and isolated where not — the two ecosystems disagree
- Signing needs an identity, and the identity comes from the same OIDC flow as the registry push
- Path filters and required status checks interact badly: a skipped required check blocks merges forever

### Deliverables
- A pull request that cannot merge until every gate passes
- A merge to `main` producing a verifiable, signed image in ECR
- A timing and cost report: runner-minutes per merge, projected monthly
- An architecture diagram of the pipeline

### Key Lesson
The pipeline is a product with users, and its users are engineers under time pressure. If it is slow, unclear, or flaky, they will find the bypass — and the bypass is where incidents come from.

---

## Project 6 — Terraform Fundamentals

**Goal:** Learn the plan/apply loop on resources that cost nothing, then create your first real AWS resources deliberately.

### Concepts
- Declarative vs imperative infrastructure, and what "desired state" buys you
- The **resource graph**: how Terraform derives ordering from references, and why explicit `depends_on` is usually a smell
- The lifecycle: `init` → `validate` → `plan` → `apply` → `destroy`
- Reading a plan: create, update in place, **replace** (the dangerous one), and destroy
- HCL types: strings, lists, maps, objects, `for` expressions, and the type constraints on variables
- `variable`, `output`, `locals`, `data` — and which of the four causes surprise most often
- Providers, provider versions, and the lock file
- Where costs actually come from in AWS, and the always-free surface this curriculum lives inside

### Build
- A root module using only `random`, `local`, and `tls` — zero cost, full lifecycle
- A second root module creating an S3 bucket with versioning, encryption, and public access blocked
- An AWS Budget resource with a $5 alert wired to your email
- A plan you read line by line before applying, and a `destroy` you verify

### Tools
Terraform, AWS provider, `aws` CLI, AWS Budgets

### Evaluation
- You can predict the plan output before running it
- `terraform destroy` leaves the account with no billable resources
- `make aws-sweep` confirms it independently

### Key Lesson
Terraform's power is the plan, not the apply. The plan is where you find out what you actually said, as opposed to what you meant.

---

## Project 7 — State, Drift & Collaboration

**Goal:** Move state off your laptop and learn to repair the gap between what Terraform believes and what AWS contains.

### Concepts
- What state actually stores, and why it holds secrets in plaintext
- Remote backends: S3 with native state locking, and what a lock prevents
- **Drift**: how it happens (console changes, other tools, provider defaults) and how `plan` reveals it
- `import` and `import` blocks — adopting resources Terraform did not create
- `moved` blocks — refactoring without destroying
- `terraform state` surgery: `list`, `show`, `rm`, `mv`, and the blast radius of each
- `-target` as a fire escape, not a habit
- Environment separation: workspaces vs separate directories, and why directories usually win
- Backend bootstrapping: the chicken-and-egg of storing state for the thing that creates the state store

### Build
- An S3 backend with versioning and native locking, bootstrapped and then adopted via `import`
- A deliberate drift exercise: change a resource in the console, detect and reconcile it
- A refactor moving resources into a nested module using `moved` blocks, with a zero-change plan as proof
- `dev/` and `prod/` root directories sharing modules but not state

### Tools
Terraform S3 backend, `terraform import`, `moved` blocks

### Evaluation
- Two concurrent `apply` attempts — the second is blocked by the lock
- A console-side change is detected and reconciled without recreating the resource
- The module refactor produces `No changes.`

### Key Lesson
State is the only thing Terraform cannot recreate. Treat the backend like a production database, because that is what it is.

---

## Project 8 — Modules & Composition

**Goal:** Write a module other people could use without reading its source.

### Concepts
- The module interface: variables in, outputs out, and everything else private
- `for_each` vs `count` — and why `count` makes list reordering destructive
- `dynamic` blocks: when repetition is genuinely data-driven, and when it is obfuscation
- Validation layers: `variable` `validation`, `precondition`, `postcondition`, `check`
- Data sources and remote state as composition seams
- Module versioning and sources: local paths, Git refs, the registry
- **`terraform test`**: native unit tests that assert on a plan without applying anything
- Designing for the consumer: sensible defaults, required inputs kept few, outputs that are actually useful

### Build
- A reusable module (tagged ECR repository with lifecycle policy) with a documented interface
- `terraform test` files covering the default case, an override, and an expected validation failure
- A consuming root module that instantiates it `for_each` over a service map
- Auto-generated docs via `terraform-docs`

### Tools
`terraform test`, `terraform-docs`, `tflint`

### Evaluation
- `terraform test` passes and includes at least one negative case
- Adding a service to the map is a one-line change
- The module README documents every variable and output without you writing it by hand

### Key Lesson
A module's version is a contract. Break it silently and you break every consumer's next apply — at the worst possible moment, which is during their unrelated emergency.

---

## Project 9 — Terraform in CI

**Goal:** Make the pipeline the only thing that holds credentials, and the only thing that applies.

### Concepts
- The plan/apply split across PR and merge, and why the applied plan should be the reviewed plan
- Posting a readable plan as a PR comment, and truncating it without hiding the dangerous parts
- Environment approvals as the human gate on `apply`
- OIDC end to end: plan with a read-only role, apply with a write role
- **Policy as code**: `checkov` and `conftest`/OPA for rules like "no public S3", "every resource tagged", "no wildcard IAM"
- Scheduled **drift detection** that opens an issue instead of silently correcting
- Promotion between environments: tfvars, not branches
- Handling apply failures: partial state, retries, and why an apply must be safe to re-run

### Build
- `lab-09-terraform.yml`: `fmt` → `validate` → `tflint` → `checkov` → `plan` → comment
- An apply job gated on the `infra-prod` environment reviewer, consuming the saved plan file
- A nightly drift-detection workflow that opens a GitHub issue on non-empty plan
- At least three custom policy rules that fail a deliberately bad PR

### Tools
`checkov`, `conftest`, `tflint`, GitHub environments, `actions/github-script`

### Evaluation
- A PR adding a public S3 bucket is blocked by policy, not by a reviewer noticing
- The plan comment is readable by someone who does not know Terraform
- Manually changing a resource in the console produces an issue by morning

### Key Lesson
Manual apply from a laptop is how environments diverge. The moment two people can apply, "what is in prod" becomes a question nobody can answer from Git.

---

> ## 🏁 Checkpoint — Start [Capstone B: Reproducible Cloud Foundation](#capstone-b--reproducible-cloud-foundation)
> You have finished the **Infrastructure** domain (Projects 6–9). Build Capstone B now to provision a complete, real, free-tier AWS environment entirely from the pipeline you built in Capstone A — and then prove you can delete all of it.

---

## Capstone B — Reproducible Cloud Foundation

**Start after:** Project 9
**Builds on:** Capstone A, Projects 6–9
**Goal:** A complete AWS environment that exists only because Terraform says so, created and destroyed by CI, costing $0.

**Scenario:** Your team needs a dev environment. You will be asked for a second one within a month, and asked to delete the first one within a quarter. Build so that both requests are one pull request each.

### What You Build
- Networking-free serverless topology: Lambda running `app/api`, API Gateway HTTP API, DynamoDB table
- ECR repositories with lifecycle policies, provisioned by the Project 8 module
- IAM: OIDC provider, a plan role and an apply role, least privilege for both
- S3 + native locking backend, bootstrapped and self-managed
- Budget alarms and cost tags on every resource
- `dev` and `staging` environments from the same modules, differing only in tfvars

### Integration Challenges (the point)
- The pipeline needs an ECR repository to push to, and Terraform needs an image to deploy — resolving that ordering without a manual step
- The apply role must be able to create IAM roles without being able to escalate itself
- Lambda deployment couples image digest to infrastructure state; changing one must not silently drift the other
- Bootstrapping the state backend with Terraform that has no backend yet
- Free tier is per-account, not per-environment: two environments must still cost nothing

### Deliverables
- A single PR that stands up an entire environment from nothing
- A single PR that destroys it, with `make aws-sweep` proving the account is empty
- A cost report showing $0.00 for the month
- An architecture diagram and a runbook for "the apply failed halfway"

### Key Lesson
Infrastructure you cannot confidently delete is infrastructure you will be afraid to change. Teardown is not the end of the lifecycle; it is the test of it.

---

## Project 10 — Kubernetes Fundamentals

**Runs on:** minikube, locally, free.
**Goal:** Understand the reconciliation loop well enough that Kubernetes stops surprising you.

### Concepts
- The **reconciliation loop**: declared state, observed state, and controllers closing the gap forever
- The API server as the only source of truth, and `kubectl` as just an HTTP client
- Pods, ReplicaSets, Deployments — and which one you should almost never create directly
- Labels and **selectors**: the loose coupling that makes a typo silently do nothing
- Services and `kube-proxy`: ClusterIP, NodePort, and how DNS resolves a service name
- Namespaces as a scope, not a security boundary
- Resource lifecycle: `apply` vs `create`, and how server-side apply tracks field ownership
- `minikube` topology: what is a node, what is your laptop, and where images actually live

### Build
- Deployments and Services for both `app/api` and `app/worker` on minikube
- Manual scaling, deletion, and self-healing demonstrations
- A deliberate label/selector mismatch, diagnosed from `kubectl` output alone
- Local image loading so pods run your build, not something from a registry

### Tools
minikube, `kubectl`, `k9s` (optional)

### Evaluation
- Deleting a pod results in a new one without you doing anything
- You can reach the API through a Service by name from inside the cluster
- You can explain, from `kubectl get endpoints`, why a broken selector produces no error

### Key Lesson
You do not tell Kubernetes what to do; you tell it what should be true, and it argues with reality on your behalf, forever. Most confusion comes from expecting an imperative answer to a declarative statement.

> **Why this one is local.** Projects 10–12 are where you break things on purpose, and a broken pod should cost a `kubectl delete`, not a fifteen-minute cluster rebuild. Nothing in the reconciliation loop, in Kustomize, or in the failure taxonomy behaves differently on EKS. Project 13 is where that stops being true.

---

## Project 11 — Configuration & Packaging

**Runs on:** minikube, locally, free.
**Goal:** Separate configuration from image, and stop hand-writing manifests per environment.

### Concepts
- ConfigMaps and Secrets — and why a Secret is base64, not encryption
- **So what do you actually do**: an external secrets store, synced in by an operator
- The bootstrap problem: the operator needs a credential to fetch your credentials, and the two honest answers (a service token you must plant, or OIDC)
- Injection styles: `env`, `envFrom`, volume mounts, and which ones pick up changes without a restart
- **Probes**: liveness, readiness, startup — what each one does when it fails, and the outage a wrong one causes
- Requests vs limits: scheduling, CPU throttling, and what an OOMKill looks like from the outside
- QoS classes and eviction order
- `HorizontalPodAutoscaler` and the metrics it needs to exist
- **Kustomize**: bases, overlays, patches, and generators — templating without a templating language
- **Helm**: charts, values, releases, and the moment `helm template` becomes your debugger
- Choosing between them honestly, including the case for using both

### Build
- Config and secrets extracted from both deployments
- Correct liveness/readiness/startup probes with justified thresholds
- Resource requests and limits derived from measured usage
- A Kustomize base with `dev` and `prod` overlays
- A hand-written Helm chart for the API, with a values schema
- The API's secrets moved out of the manifests into **Doppler**, synced in by the Doppler Kubernetes Operator, with the Deployment auto-reloading on change

### Tools
Kustomize, Helm, `kubectl top`, metrics-server, Doppler + its Kubernetes Operator

> **On Doppler.** Doppler holds *application* secrets and syncs them into real Kubernetes Secrets on an interval. It is not a substitute for cloud identity — that is Project 13's Pod Identity, and putting an AWS access key in Doppler would reintroduce exactly the long-lived credential Pod Identity exists to delete. The two compose: identity first, then secrets. If you would rather stay vendor-neutral, the **External Secrets Operator** reads the same way from AWS Secrets Manager or from Doppler itself, and the manifests barely change.

### Evaluation
- `kustomize build overlays/prod` differs from dev in replicas, resources, and config only
- A pod with a deliberately failing readiness probe never receives traffic
- `helm template` output is valid and `helm lint` passes

### Key Lesson
A readiness probe that returns 200 unconditionally converts a rolling update into an outage. The probe is not a health check for you; it is a traffic-routing decision for the cluster.

A second one, from the secrets half: every secrets system bottoms out in one credential you cannot fetch from itself. Knowing where yours lives is the difference between a secure setup and a decorated one.

---

## Project 12 — Rollouts, Failure & Forensics

**Runs on:** minikube, locally, free.
**Goal:** Diagnose five broken deployments from evidence, and understand exactly what a rolling update does.

### Concepts
- Rolling update mechanics: `maxSurge`, `maxUnavailable`, and the arithmetic of available replicas
- `Recreate` strategy and the cases that require it
- Rollout history, `kubectl rollout undo`, and why the revision limit matters
- `PodDisruptionBudget`: protecting availability during voluntary disruption
- The failure taxonomy: `ImagePullBackOff`, `CrashLoopBackOff`, `Pending`, `Evicted`, `CreateContainerConfigError`
- Reading events — the record most people skip, containing most of the answer
- `kubectl debug` and ephemeral containers for images with no shell
- `terminationGracePeriodSeconds` and `preStop` — why your service drops requests during deploys

### Build
- A rolling update observed replica-by-replica while serving live traffic
- A failed rollout detected by `kubectl rollout status` and rolled back
- Five pre-broken deployments in `k8s/broken/`, each diagnosed and fixed from evidence
- Graceful shutdown wired into both services, verified with zero dropped requests

### Tools
`kubectl rollout`, `kubectl describe`, `kubectl debug`, `hey` or `k6`

### Evaluation
- Zero failed requests during a rolling update under load
- Each of the five broken deployments correctly diagnosed before being fixed
- You can state the exact number of available pods at each step of a rollout

### Key Lesson
`kubectl describe` before `kubectl logs`. Most failures are decided before the container ever starts, and logs from a container that never ran tell you nothing.

---

## Project 13 — Deploying from CI

**Runs on:** EKS. ~$0.21/hr while up — `make eks-up` to start, `make eks-down` to stop. See [docs/COST.md](docs/COST.md).
**Goal:** Get a workflow to deploy to a real cluster it cannot see, and only report success when the rollout has actually converged.

### Concepts
- The reachability problem, for real: a GitHub-hosted runner cannot see your laptop, and now the cluster is not on your laptop either
- The three honest answers: ephemeral `kind` in the runner, a self-hosted runner, or pull-based GitOps — and why the first one was quietly cheating
- **GitHub OIDC → IAM role**: the runner assumes a role with no stored AWS key, then calls `aws eks get-token`
- **EKS Pod Identity**: how a *pod* gets AWS credentials — an association, an agent, and short-lived STS tokens with nothing on disk. IRSA is the predecessor you will meet in every existing cluster; know both, reach for Pod Identity
- Cluster authorization is not cluster authentication: an IAM principal still needs an access entry or an RBAC binding
- Image tag propagation: passing an immutable digest from build job to deploy job
- `kubectl rollout status --timeout` as the gate, and what happens when you omit it
- Post-deploy smoke tests: what to assert, and why "the pod is Running" is not one of them
- Automatic rollback on failure, and the states where rollback is also unsafe
- Deployment records: annotating a rollout with the commit that caused it
- **What a `Service` of type LoadBalancer actually creates**, who owns it, and why it outlives the cluster

### Build
- `infra/eks/` — Terraform for a two-node cluster in public subnets, no NAT, torn down nightly
- A workflow that authenticates by OIDC, deploys to EKS, and holds no kubeconfig secret
- The API reading DynamoDB through **Pod Identity**, with no key anywhere in the manifest
- Digest (not tag) propagation from the build job through `outputs`
- A gated `rollout status` step with a real timeout
- Smoke tests hitting the service through its LoadBalancer
- Automatic `rollout undo` on smoke-test failure, with the run marked failed
- A teardown step, and a sweep that proves the ELB went with it

### Tools
Terraform, EKS, `aws-actions/configure-aws-credentials`, `kubectl`, job `outputs`, `helm upgrade --atomic`

### Evaluation
- A deliberately broken image causes a failed workflow and an automatic rollback
- The deployed pod's image is a digest, not a mutable tag
- The workflow never reports success while pods are still `ContainerCreating`
- No AWS key and no kubeconfig exists in GitHub secrets — `gh secret list` proves it
- `make eks-down` leaves `make aws-sweep` completely empty, including the load balancer

### Key Lesson
A deploy that reports success before the rollout converges is reporting the wrong thing. `kubectl apply` returns when the API server accepts your intent, not when it becomes true.

And the one the bill teaches: deleting a cluster does not delete what the cluster created. The ELB behind your Service was made by Kubernetes, not Terraform, and it will happily outlive both.

---

## Project 14 — GitOps with Argo CD

**Runs on:** EKS. `make eks-up` / `make eks-down` each session.
**Goal:** Invert the deployment direction — let the cluster pull from Git instead of letting CI push into the cluster.

### Concepts
- Push vs pull delivery, and the credential asymmetry that makes pull safer
- Argo CD's model: `Application`, source, destination, sync policy
- Automated sync, **self-heal**, and prune — and the three ways each one surprises you
- The app-of-apps pattern for managing many applications declaratively
- Sync waves and hooks for ordering (migrations before rollout)
- Drift reconciliation: what happens when someone runs `kubectl edit` in production
- Environment promotion as a pull request that changes a pinned digest
- Repository layout: app source vs config, and why they usually separate

### Build
- Argo CD installed on the EKS cluster, managing itself
- An `Application` per service per environment via app-of-apps
- CI's final step reduced to committing a new digest to the config repo
- A self-heal demonstration: a manual `kubectl edit` reverted automatically
- A promotion PR moving `dev` → `staging`
- A **rebuild drill**: `make eks-down`, then `make eks-up`, then bootstrap Argo CD and watch it reconstitute both environments from Git with no further input

### Tools
Argo CD, Kustomize, `argocd` CLI

### Evaluation
- No CI job holds cluster credentials any more
- A manual change to a live Deployment is reverted within the sync interval
- "What is running in staging?" is answered by a file in Git
- A cluster destroyed and rebuilt from scratch returns to its declared state without you deploying anything

### Key Lesson
With GitOps, "what is running in prod?" becomes a `git log`, not an investigation. That is the whole benefit, and it is worth more than it sounds.

The nightly teardown stops being a chore here and starts being the proof. A platform that cannot survive losing its cluster was never declarative; it was just a cluster someone had been editing carefully.

---

> ## 🏁 Checkpoint — Start [Capstone C: The Delivery Platform](#capstone-c--the-delivery-platform)
> You have finished the **Orchestration** domain (Projects 10–14). Build Capstone C now to connect everything: a merge becomes a signed image, becomes a Terraform-managed registry entry, becomes a reconciled cluster state, across three environments.

---

## Capstone C — The Delivery Platform

**Start after:** Project 14
**Builds on:** Capstones A and B, Projects 10–14
**Goal:** One merge to `main` traceable end to end, through build, provenance, registry, reconciliation, promotion, verification, and rollback.

**Scenario:** You are handing this platform to a team of six. They will not read your code. They need to ship on their first day and roll back on their second.

### What You Build
- The Golden Pipeline from Capstone A producing a signed, attested image
- Terraform-managed ECR from Capstone B holding it
- Argo CD reconciling `dev` automatically from a pinned digest
- Promotion to `staging` and `prod` by pull request, each a single-line digest change
- Smoke tests as sync hooks, with automatic rollback on failure
- A deployment dashboard: what is where, and which commit put it there
- A documented cold-start path: from an empty AWS account to three reconciled environments, in one command and one wait

### Integration Challenges (the point)
- The digest must survive four handoffs without anyone typing it
- Argo CD must not fight Terraform over resources both believe they own
- The whole platform must come back from `make eks-down` without a human remembering a step
- A rollback in `prod` must be a Git operation, not a `kubectl` operation, or the next sync undoes it
- Three environments in one cluster means namespaces, RBAC, and honest limits about what this simulates
- The dashboard must be derivable from Git and cluster state, not maintained by hand

### Deliverables
- A single merge, traced end to end with timestamps at each stage
- A deliberately bad deploy that rolls itself back without human action
- A one-page runbook a new team member can follow to ship and to revert
- A full architecture diagram of the delivery path

### Key Lesson
Delivery is a chain of handoffs, and every handoff where a human retypes a value is a place the chain breaks. The platform's job is to make the correct path the only path.

---

## Project 15 — Progressive Delivery

**Goal:** Stop treating deploy and release as the same event.

### Concepts
- **Deploy vs release**: shipping code to production without exposing it to users
- Canary deployments: traffic percentage, step duration, and the analysis that decides to continue
- Blue/green: instant cutover, instant rollback, double the resources
- Argo Rollouts: `Rollout` resource, steps, analysis templates, automatic abort
- Metric-driven promotion: choosing a signal that actually indicates harm
- Feature flags: runtime control, flag debt, and the testing matrix explosion
- Ring-based rollout and the population you dare to break first

### Build
- An Argo `Rollout` with a canary strategy and pause steps
- An `AnalysisTemplate` querying real metrics to auto-promote or abort
- A feature-flagged endpoint in `app/api` toggled without deploying
- A failing canary that aborts on its own

### Tools
Argo Rollouts, Prometheus, a flag library or config-map-backed flags

### Evaluation
- A bad version reaches at most the configured canary percentage of traffic
- The abort happens without human intervention
- A feature can be enabled and disabled with no deploy

### Key Lesson
Separating deploy from release turns a rollback into a config change. The fastest rollback is one that does not need a build.

---

## Project 16 — Observability & Deployment Signals

**Goal:** Measure your own delivery process, then use those measurements as a gate.

### Concepts
- The four **DORA** metrics: deployment frequency, lead time for changes, change failure rate, time to restore — and how to compute each from your own data
- Deployment markers and correlating a release with a metric change
- The three signals: metrics, logs, traces — and the questions each is bad at
- **SLOs and error budgets**: turning reliability into a number you can spend
- Error-budget-based deploy gating: freezing releases when the budget is exhausted
- Alert design: symptom-based alerting, and why "CPU is high" pages nobody usefully
- Instrumenting a pipeline: build duration, queue time, flake rate, cache hit rate

### Build
- A DORA metrics collector reading the GitHub API for this repo
- Prometheus + Grafana on minikube scraping both services
- Deploy annotations on dashboards, correlating rollouts with error rates
- An SLO with an error budget, and a workflow that blocks deploys when it is spent

### Tools
Prometheus, Grafana, `gh api`, OpenTelemetry

### Evaluation
- All four DORA metrics computed from real data with a stated methodology
- A dashboard where a bad deploy is visible within a minute
- A deliberately exhausted error budget blocks the next deploy

### Key Lesson
You cannot improve deployment frequency without first making lead time and failure rate visible. Teams that only measure frequency ship faster and break more, and call it progress.

---

## Project 17 — Supply Chain & Policy Enforcement

**Goal:** Make the cluster refuse anything you cannot prove the origin of.

### Concepts
- Signing with `cosign`, keyless signing, and the transparency log
- The gap between signing and verifying — signing alone changes nothing
- **Admission control**: validating vs mutating webhooks, and where policy actually stops a deploy
- Kyverno or Gatekeeper policies: signature required, digest required, no `latest`, no privileged
- Kubernetes RBAC: Roles, ClusterRoles, bindings, and ServiceAccount token scope
- Least-privilege IAM for the deploy path, and the permissions boundary pattern
- Secret management: External Secrets Operator pulling from SSM Parameter Store, and rotation
- SLSA levels: what each one claims and what evidence it requires

### Build
- Keyless `cosign` signing in the build pipeline, with verification as a separate job
- A Kyverno policy rejecting unsigned images, proven with a real rejection
- Policies enforcing digest-only references and non-root containers
- RBAC so the deploy identity can update Deployments and nothing else
- External Secrets pulling a value from SSM into a running pod

### Tools
`cosign`, Kyverno, External Secrets Operator, AWS SSM Parameter Store

### Evaluation
- An unsigned image is rejected at admission with a clear message
- The deploy ServiceAccount cannot read Secrets or create Pods directly
- Rotating a value in SSM updates the pod without a redeploy

### Key Lesson
Signing without verification at admission is theatre. The enforcement point is the cluster, because that is the last place before code runs.

---

## Project 18 — Reliability, Cost & Scale

**Goal:** Make the pipeline something people trust at 5pm on a Friday.

### Concepts
- **Flaky tests**: detection through repeated runs, quarantine, and why retries hide the cost instead of paying it
- Test sharding and the parallelism/overhead curve
- Monorepo change detection: building only what moved, and the correctness trap in "only"
- **Ephemeral preview environments** per PR, and guaranteeing teardown when the PR is abandoned
- The unit of isolation: a namespace per PR, not a cluster per PR, and the arithmetic that decides it
- **One shared ingress, not a LoadBalancer per preview** — which of the two multiplies with open PRs, and which is flat
- What actually runs out first: pods per node, not IPs per subnet, and why the famous answer is the wrong one here
- Teardown triggers that actually fire: `pull_request: closed` covers merge *and* abandon, but not a PR that sits open for three weeks
- Runner economics: hosted vs self-hosted, larger runners, and when queue time dominates
- **Cost allocation tags**: the thing that makes "who spent this?" answerable at all, and why a tag applied after the fact answers nothing
- Showback vs chargeback, and why a leaderboard changes behaviour more than a dashboard nobody opens
- Pipeline SLOs: p50 and p95 time-to-feedback as tracked numbers
- Incident response for delivery: rollback runbooks, break-glass paths, and the audit trail a break-glass must leave

### Build
- A flake detector running the suite repeatedly and quarantining unstable tests
- Sharded test execution with measured speedup and overhead
- Preview environments as a **namespace per PR** on the one lab cluster, created on open and destroyed on close
- A scheduled reaper that deletes preview namespaces older than N days, because the `closed` trigger does not fire on a PR nobody closes
- A single ingress controller behind one load balancer, routing `pr-<n>.<domain>` to the matching namespace — so the tenth preview costs the same as the first
- A measured capacity ceiling: how many previews this cluster actually holds, established by filling it until pods go `Pending`
- A runner-minute cost report by workflow
- **A weekly cost report posted to Slack**: AWS spend grouped by cost-allocation tag and by service, ranked, with the week-over-week delta — plus runner minutes by workflow in the same message
- Budget alerts routed to the same channel through SNS, so the fast signal and the weekly audit land in one place
- A break-glass deploy path that works when CI is down and files an audit issue automatically

### Tools
`pytest-randomly`, `pytest-xdist`, `gh api`, GitHub deployments API, Cost Explorer API, EventBridge Scheduler, Lambda, SNS, Slack incoming webhooks

> **On the Slack cost report.** Two pieces, and they are worth building separately.
> The **alert** path needs no code: Budgets → SNS → AWS Chatbot posts threshold
> breaches into a channel, free. The **digest** is a scheduled Lambda calling Cost
> Explorer `GetCostAndUsage`, grouped by a tag dimension, formatted as a ranked
> list and posted to a webhook. In a company that grouping is `Team` or `Owner`
> and you get the leaderboard; in a one-person lab account, group by `Lab` and
> `Service` instead — same code, and it tells you which project actually cost you
> the money. Note that Cost Explorer API requests cost **$0.01 each**, so a daily
> digest is $0.30/month and a per-minute poll is a bill of its own; this is the
> rare AWS API where the metering is the design constraint.
>
> The prerequisite is boring and non-negotiable: tag every resource at creation
> in `infra/`, and activate the tags as cost-allocation tags in Billing. Untagged
> spend shows up as one anonymous lump, and tags do not apply retroactively — the
> week you forget is permanently unattributable.

> **On preview environments: a namespace per PR, never a cluster per PR.**
> An EKS control plane bills $0.10/hour regardless of how little runs on it, so
> the cost of cluster-per-PR scales with the number of PRs *open*, not the amount
> of work being done. Five open PRs is ~$360/month of idle control planes, which
> is more than this entire curriculum's budget spent on nothing. A namespace per
> PR on the existing lab cluster is effectively free, and the teardown is a
> `kubectl delete namespace` rather than a fifteen-minute destroy that can strand
> a load balancer.
>
> What you give up is real and worth stating: namespaces share a control plane,
> a CNI, and a node pool, so they do not isolate cluster-scoped resources (CRDs,
> webhooks, RBAC at cluster scope) and they do not protect you from a noisy
> neighbour without ResourceQuotas. If the change under review touches any of
> those, a namespace preview cannot validate it and you should say so rather than
> pretend. **ResourceQuota and LimitRange per preview namespace are not optional
> here** — they are the only thing standing between one PR's load test and
> everyone else's pods.
>
> The general form of the rule: pick the *smallest* unit that isolates what the
> change can actually break. Reaching for a whole cluster is usually a failure to
> ask what needed isolating.

> **The load balancer multiplies; the VPC and subnets do not.**
> Getting the namespace decision right and then giving every preview namespace
> its own `Service` of type LoadBalancer rebuilds the same bill in miniature: an
> NLB is ~$0.023/hour, one per Service, so five open PRs is ~$80/month of idle
> load balancers. Route all previews through **one** ingress controller behind
> **one** load balancer, splitting on hostname (`pr-123.<domain>`) or path. One
> load balancer, N environments, flat cost — that is what makes namespace-per-PR
> genuinely cheap rather than merely cheaper.
>
> Subnets and VPCs, by contrast, are free. There is no per-subnet or per-VPC
> charge; the money is in what you attach to them — NAT gateways, VPC endpoints,
> idle Elastic IPs — and `infra/eks/network.tf` attaches none of those on purpose.
>
> They are a **capacity** limit, though, and on this cluster the intuitive answer
> is the wrong one. The VPC CNI gives every pod a real VPC address, which makes
> IP exhaustion the famous EKS failure mode — but do the arithmetic before
> believing it applies:
>
> | | |
> |---|---|
> | Two `/24` subnets | 502 usable IPs |
> | `t3.medium` max pods | 3 ENIs × 6 IPs − 1 = 17 per node |
> | Two nodes, less DaemonSets | **~28 schedulable pods** |
>
> The node ceiling binds roughly eighteen times harder than the address space.
> Previews here run out of CPU and scheduling room, not IPs; a `Pending` pod on
> this cluster is an `Insufficient cpu` event, and reading it as a networking
> problem will cost you an afternoon. On a cluster with larger nodes the ratio
> inverts and IP exhaustion becomes real — which is the actual lesson. Know which
> limit you are near, rather than which one is famous.

### Evaluation
- Known flaky tests are identified automatically, not by reputation
- No orphaned preview environment survives a closed PR
- Five simultaneous preview environments cost the same as one — if they do not, the isolation unit is wrong
- `aws elbv2 describe-load-balancers` returns exactly one entry no matter how many previews are open
- You can state this cluster's preview ceiling as a number, and say which resource imposes it
- p95 time-to-feedback is a number you can quote and have reduced
- The Slack digest attributes 100% of the month's spend to a tag — no "untagged" row

### Key Lesson
Pipeline reliability is a product feature. Every flaky test spends someone's trust, and once the team stops believing a red build, the build has stopped working regardless of what it reports.

---

## Each Project Should Include

| Artifact | Why |
|---|---|
| Architecture diagram | Forces you to name the components and the direction data flows. Most confusion is a missing arrow. |
| Working lab with a verifier | Proof you did it, not a memory that you read it. `make verify LAB=NN` is the acceptance test. |
| Measured baseline | Speed, cost, and reliability claims mean nothing without a before number. |
| Failure exercise | Every project includes at least one deliberate break, because you learn the system by watching it fail. |
| Write-up | A short note on what surprised you. The surprises are the actual learning; they fade within a week. |

## The Four Domains (How Senior Engineers Think About This)

| Domain | Projects | The question it answers |
|---|---|---|
| **Automation** | 1–5 | Can a change be built, tested, and packaged without a human touching it? |
| **Infrastructure** | 6–9 | Does the environment exist because a file says so, and can I recreate or delete it on demand? |
| **Orchestration** | 10–14 | Once the artifact exists, how does it become a running thing, and how does it stop being one? |
| **Delivery & Governance** | 15–18 | Can we ship often, prove what shipped, and limit the damage when it is wrong? |

The capstones sit deliberately on the seams between domains, because the seams are where real systems break. Anyone can make a pipeline pass in isolation; the work is making the handoffs survive contact with each other.

| Capstone | Start after | Builds on | Domains | You end up with |
|---|---|---|---|---|
| **A — The Golden Pipeline** | Project 5 | Projects 1–5 | Automation | A reusable pipeline producing signed, scanned images with zero stored credentials |
| **B — Reproducible Cloud Foundation** | Project 9 | A, Projects 6–9 | Automation + Infrastructure | An entire AWS environment created and destroyed by pull request, at $0 |
| **C — The Delivery Platform** | Project 14 | A, B, Projects 10–14 | All four | One merge traced from commit to running pod, with automatic rollback — on a cluster that rebuilds itself from Git |

## Progress

| # | Project | Lab | Status |
|---|---|---|---|
| 1 | Pipelines & the Build Contract | [`labs/01_first_pipeline`](labs/01_first_pipeline) | Built |
| 2 | Speed & Cost | [`labs/02_speed_and_cost`](labs/02_speed_and_cost) | Built |
| 3 | Abstraction, Service Containers & the Local Loop | [`labs/03_abstraction`](labs/03_abstraction) | Built |
| 4 | Trust: Permissions, OIDC & Supply Chain | no lab — worked from this file | **Done** |
| 5 | Building & Publishing Containers | — | Planned |
| A | Capstone — The Golden Pipeline | — | Planned |
| 6 | Terraform Fundamentals | — | Planned |
| 7 | State, Drift & Collaboration | — | Planned |
| 8 | Modules & Composition | — | Planned |
| 9 | Terraform in CI | — | Planned |
| B | Capstone — Reproducible Cloud Foundation | — | Planned |
| 10 | Kubernetes Fundamentals | — | Planned |
| 11 | Configuration & Packaging | — | Planned |
| 12 | Rollouts, Failure & Forensics | — | Planned |
| 13 | Deploying from CI | — | Planned |
| 14 | GitOps with Argo CD | — | Planned |
| C | Capstone — The Delivery Platform | — | Planned |
| 15 | Progressive Delivery | — | Planned |
| 16 | Observability & Deployment Signals | — | Planned |
| 17 | Supply Chain & Policy Enforcement | — | Planned |
| 18 | Reliability, Cost & Scale | — | Planned |

**Built** means a lab exists with a starter, a verifier and a README.
**Done** means the project was worked directly from this file, with no graded
lab. Project 4 was done that way; `docs/PROGRESS.md` records what was built and
`docs/OIDC.md` explains the part that needed it.

Projects 1–5 are the Automation domain, and **Capstone A** assembles them. Do
not skip from 4 to Track B: Project 5 produces the container images, and the
capstone is what every later track builds on.
