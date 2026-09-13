# ci-cd-lab

A practice-first CI/CD curriculum: GitHub Actions, Terraform on AWS, and Kubernetes, from a first green check to a governed delivery platform.

Eighteen projects across four domains, three cumulative capstones, and a lab for each — theory in the README, deliberate gaps in real config files, and a verifier that tells you when you have closed them.

**Tracks A and B cost $0** — public repository (unlimited runner minutes) and AWS free tier only. **Track C costs about $10–25/month** from Project 13, where the cluster becomes a real EKS cluster you create at the start of a session and destroy at the end of it (`make eks-up` / `make eks-down`, ~$0.21/hr while up). Projects 10–12 stay on minikube and stay free. See [docs/COST.md](docs/COST.md) for the rates, the teardown procedure, and the resources this curriculum still never creates.

**→ [ROADMAP.md](ROADMAP.md) is the curriculum.** Start there.

---

## Quickstart

```bash
make doctor        # what you have, what you need, and when you need it
make test          # the sample app's suites should pass before you wire up a pipeline
make lab LAB=01    # install Lab 01's starter files at their real paths
```

Then open [`labs/01_first_pipeline/README.md`](labs/01_first_pipeline/README.md), fix the TODOs, and:

```bash
make verify LAB=01
```

---

## How a lab works

Each lab has a teaching README, a **starter** with deliberate gaps, a **verifier**, and a **solution**.

Starter files are installed at their *real* path — `.github/workflows/`, `infra/`, `k8s/` — because that is the only place the tools that read them will look. A workflow in a lab folder is not a workflow. `labs/NN_*/starter/` keeps a pristine copy so you can start over.

```
make lab LAB=02        install the starter
make verify LAB=02     run the verifier
make solution LAB=02   diff your work against the reference
make reset LAB=02      discard your edits, start again
make status            which labs are installed, untouched, or edited
```

Verifiers are pytest files under `labs/NN_*/verify/`. Most assertions are static — parse the YAML or HCL and check the structure — but each lab ends with **live** tests that use `gh` or `kubectl` to confirm the thing actually ran. Those skip until you push. A skip is not a pass.

---

## Layout

```
ROADMAP.md          the curriculum: 18 projects, 3 capstones, 4 domains
foundations/        the six ideas the tools are implementations of
docs/COST.md        cost rates, teardown procedure, the never-provision list
docs/SETUP.md       what to install, and when
app/api             sample Python service (FastAPI, pytest, uv)
app/worker          sample TypeScript worker (vitest, npm)
labs/               one directory per lab: README, starter, solution, verify
.github/workflows   where workflow starters are installed
infra/              Terraform: starters land here (Track B), infra/eks is the Track C cluster
k8s/                where manifest starters are installed   (Track C)
scripts/            doctor, labctl, aws-guard, aws-sweep, eks-down, labcheck helpers
```

### Why two services

`app/api` is Python, `app/worker` is TypeScript, and both are deliberately boring — the pipeline is the subject, not the app. Two languages exist to force the problems that only appear in real pipelines: build matrices, per-ecosystem caching, path-filtered change detection, two images from one repository, and independent version streams.

---

## Progress

Three labs are built; the roadmap describes all eighteen. That gap is intentional — the plan runs ahead of the implementation, and the format is worth getting wrong early and cheaply.

| Track | Projects | Runs on | Status |
|---|---|---|---|
| A — Automation (GitHub Actions) | 1–5 + Capstone A | GitHub-hosted runners | Labs 01–03 built |
| B — Infrastructure (Terraform, AWS) | 6–9 + Capstone B | AWS free tier | Planned |
| C — Orchestration (Kubernetes) | 10–14 + Capstone C | minikube (10–12), EKS (13–14) | Planned |
| D — Delivery & Governance | 15–18 | Both | Planned |

`make status` shows where you are.
