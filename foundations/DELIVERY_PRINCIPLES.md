# Delivery Principles

A parallel track to the [roadmap](../ROADMAP.md), read alongside it rather than before it.

The numbered projects teach tools. This document teaches the six ideas those tools are implementations of — the ones that stay true when GitHub Actions is replaced by something else, and that explain why the tools have the shape they do.

Each cluster is framed around **the delivery failure mode it explains**, and follows the same rhythm as the roadmap: Concepts → Build → Evaluation → Key Lesson.

---

## Cluster 1 — Integration Frequency

**The failure mode:** the two-week branch that takes three days to merge, and breaks something a fortnight after the code was written.

### Concepts

The word in "continuous integration" that carries the meaning is **integration**, not the testing. Integration is the act of reconciling your work with everyone else's, and it is the thing that gets harder the longer you postpone it — not linearly, but roughly with the square of the divergence, because every pair of conflicting changes has to be reconciled against every other.

**Trunk-based development** is the response: everyone merges to one shared branch at least daily, and branches live hours, not weeks. This sounds reckless until you notice what it forces. If you must merge daily, you cannot merge half-finished features — so you need a way to ship incomplete work safely, which is what feature flags and **branch by abstraction** are for. The discipline creates the capability.

There is a second, quieter cost to long branches: they make your test results stale. A green check on a branch that is two weeks behind `main` is a statement about a codebase that no longer exists. This is the **semantic conflict** — two changes that merge cleanly at the text level and are incompatible in meaning. No merge tool detects it; only running the tests on the merged result does.

The counter-argument is real: trunk-based development requires strong tests, because there is no long stabilization window to catch mistakes in. That is a chicken-and-egg problem, and the way out is to raise both together, not to wait for perfect tests.

### Build
- Measure your own branch lifetimes: `git log --format='%H %ci' main` against branch points
- Practise branch by abstraction on one change: ship the seam first, the implementation second
- Configure "require branches to be up to date before merging" and notice what it costs you

### Evaluation
- Median branch lifetime, in hours
- Number of merge conflicts per week, before and after
- How often `main` is red, and for how long

### Key Lesson
Merge pain scales with divergence, not with change size. A team that merges ten times a day has ten trivial merges; a team that merges once a fortnight has one merge that ruins an afternoon and nobody can review honestly.

---

## Cluster 2 — Deployment Is Not Release

**The failure mode:** every rollback requires a build, so every incident is at least one build long.

### Concepts

These are two different events that most teams conflate:

- **Deployment** is a technical act: new code is now running on infrastructure.
- **Release** is a business act: users are now experiencing that code.

Bind them together and every user-facing decision requires a deploy, which means every reversal requires a build, which means your minimum time-to-recover is your build time — measured while the incident is ongoing.

Separate them and the vocabulary of delivery opens up. **Dark launching** deploys code that runs but affects nobody. **Feature flags** turn exposure into a runtime decision. **Canary releases** expose a percentage. **Ring deployments** expose a population, ordered by how much you dare break them. In every case the rollback is a config change measured in seconds, not a pipeline run measured in minutes.

The cost is real and worth naming: flags multiply the number of states your system can be in, and a flag left in place for a year becomes permanent untested branching. **Flag debt** is a genuine maintenance burden, and flags need expiry dates the way branches need short lives.

### Build
- One feature behind a runtime flag, toggled without deploying
- Measure time-to-disable via flag vs time-to-revert via pipeline
- A flag inventory with owners and removal dates

### Evaluation
- Time to disable a bad feature, in seconds
- Number of live flags, and the age of the oldest
- Whether a rollback ever requires a build

### Key Lesson
The fastest rollback is the one that does not need a build. Separating deployment from release turns your worst-case recovery time from a pipeline duration into a config propagation delay.

---

## Cluster 3 — Idempotency and Convergence

**The failure mode:** the deploy script that works the first time and fails the second, so nobody dares re-run it after a partial failure — exactly when re-running is what you need.

### Concepts

An **idempotent** operation produces the same end state whether applied once or five times. `mkdir /opt/app` is not idempotent; `mkdir -p /opt/app` is. That difference decides whether a half-finished deploy can be fixed by running it again or requires someone to reason about what state the machine is in at 3am.

**Convergence** is the stronger version, and the one Terraform and Kubernetes are both built on: you describe the desired end state, and the system computes the operations needed to reach it from wherever it currently is. You never write the steps. This is why `terraform apply` is safe to re-run and why a Kubernetes controller keeps working after you delete a pod by hand.

The distinction that matters in practice: **imperative tools break differently from declarative ones.** An imperative script fails at a known step, leaving a state you can reason about but must repair by hand. A declarative system does not fail halfway so much as *converge to something you did not intend* — and finding out what it thinks the desired state is becomes the debugging task. Both are recoverable; they need completely different instincts.

Declarative is not automatically better. It requires the system to model everything you care about, and the moment you need something outside the model, you are writing imperative escape hatches inside a declarative wrapper — which is the worst of both.

### Build
- Take a deploy script and make every step idempotent; run it three times in a row
- Interrupt a `terraform apply` halfway, then re-run it and read what it does
- Delete a Kubernetes resource by hand and watch the controller restore it

### Evaluation
- Every automation in the repo is safe to re-run
- A partial failure needs no manual repair before retrying
- You can state, for any tool you use, what happens when it is interrupted

### Key Lesson
Automation you are afraid to re-run is not automation, it is a ritual. The question that separates them: what happens if this runs twice?

---

## Cluster 4 — Blast Radius and the Unit of Rollback

**The failure mode:** a bad change ships alongside nine good ones, and reverting it means reverting all ten.

### Concepts

**Blast radius** is the set of things a change can break. **The unit of rollback** is the smallest thing you can undo independently. Delivery goes badly whenever the second is larger than the first — when undoing one broken thing requires undoing unrelated working things.

Batching is where the two diverge. Ten changes in one deploy means one deploy's worth of overhead, which feels efficient. It also means: when something breaks, you have ten suspects instead of one; the fix reverts nine innocent changes; and the person who has to diagnose it is not the person who wrote the offending line. **Smaller, more frequent deploys are not just faster, they are dramatically easier to debug** — which is why deployment frequency and change failure rate improve together rather than trading off, the single most counter-intuitive finding in the DORA research.

The same logic applies to infrastructure. One Terraform state file for everything means every apply has the blast radius of your entire estate. Splitting state by lifecycle — things that change hourly separated from things that change yearly — bounds it.

And it applies to permissions. An OIDC role scoped to one repository and one branch has a blast radius of that branch. A long-lived access key in a shared secret has a blast radius of everyone who can read it, for as long as it exists.

### Build
- Split one Terraform state by lifecycle and compare plan durations and risk
- Practise `git revert` of a single commit from a batch of ten
- Scope one deploy credential down until something breaks, then back off one step

### Evaluation
- Number of changes per deploy (want: small)
- Whether one change can be reverted without touching others
- Blast radius of each credential in the repo, written down

### Key Lesson
Ship smaller. Not because small changes are less likely to be wrong, but because when a small change is wrong you know immediately which one it was, and undoing it costs nothing anyone else cares about.

---

## Cluster 5 — Immutability

**The failure mode:** the server that has been patched by hand for three years, that nobody dares rebuild because nobody knows what is on it.

### Concepts

**Configuration drift** is the accumulated difference between what a system is supposed to be and what it has become — every hotfix applied by hand, every package installed during an incident, every config edited over SSH. It grows silently, and its cost is paid all at once on the day you need a second identical machine.

**Immutable infrastructure** removes the mechanism rather than the symptom: you never modify a running thing, you replace it. A new version means a new image, a new container, a new instance. Nothing is patched, so nothing drifts.

This is the actual content of "**pets versus cattle**." A pet is a machine with a name, a history, and hand-applied state; you nurse it. Cattle are interchangeable and get replaced without ceremony. The test is direct: **could you delete this and recreate it from source in the next ten minutes?**

Immutability is what makes a container digest meaningful. A tag is a pointer that can move; a digest is a hash of the content and cannot lie. It is also why `latest` is a trap — two machines pulling `latest` an hour apart run different code while reporting the same version.

State is the honest exception. Databases are pets, always, and the discipline is to make the pet population as small and as well-defined as possible, then treat everything else as cattle.

### Build
- Rebuild your local cluster from scratch and time it
- Deploy by digest instead of tag, everywhere
- List every stateful thing you own — that list is your real pet population

### Evaluation
- Time to recreate any non-stateful environment from source
- Number of resources whose current state is not derivable from a repository
- Whether any deployment anywhere references a mutable tag

### Key Lesson
If you cannot delete it and recreate it, you do not fully understand it — and you will find out exactly how little you understand it on the day it dies on its own schedule rather than yours.

---

## Cluster 6 — Feedback Latency

**The failure mode:** a pipeline slow and flaky enough that people learn to work around it, at which point it stops protecting anything while still costing everything.

### Concepts

Every quality mechanism has a **latency** — the delay between introducing a defect and being told. A type checker in your editor is milliseconds. A unit suite is seconds. CI is minutes. Staging is hours. Production is however long until a user complains.

Cost rises sharply along that scale, and not mainly because the fix is harder. It rises because of **context loss**. A defect caught in the editor is fixed by someone holding the entire problem in their head. The same defect caught in staging is fixed by someone reconstructing it from a stack trace, possibly a different person, possibly on a different day.

Which gives the practical rule: **push every check as early as it can meaningfully run.** A lint rule belongs in the editor, not just in CI. A contract test belongs in CI, not just in staging.

Then there is **flakiness**, which is worse than slowness. A slow pipeline delays trust; a flaky pipeline destroys it. Once a red build might mean nothing, every red build gets a re-run before it gets a diagnosis — and at that point the pipeline has stopped working, regardless of what it reports. Flakiness has a compounding social cost that its technical severity never predicts.

The metric to keep is **p95 time to feedback**, not the median. The median describes the good days. The p95 describes what people plan around, and planning around it is what produces the workarounds.

### Build
- Measure p50 and p95 time-to-feedback for your pipeline
- Move one check earlier in the chain and measure the difference
- Run the suite 50 times and quarantine what is not deterministic

### Evaluation
- p95 time to first failure signal
- Flake rate, measured rather than remembered
- Number of manual re-runs per week — the leading indicator of lost trust

### Key Lesson
A pipeline is a product, and engineers under deadline pressure are its users. If it is slow, unclear, or unreliable they will find the bypass — and the bypass is where incidents come from.

---

## How these map to the projects

| Cluster | First appears | Fully exercised |
|---|---|---|
| Integration Frequency | Project 1 — branch protection | Project 18 — preview environments |
| Deployment ≠ Release | Project 12 — rollback | Project 15 — canary and flags |
| Idempotency & Convergence | Project 6 — `terraform apply` | Projects 10, 14 — controllers and GitOps |
| Blast Radius | Project 4 — least-privilege OIDC | Projects 7, 17 — state splitting, RBAC |
| Immutability | Project 5 — digests and tags | Projects 13, 17 — digest deploys, admission policy |
| Feedback Latency | Project 2 — caching and matrices | Project 18 — flake detection, pipeline SLOs |
