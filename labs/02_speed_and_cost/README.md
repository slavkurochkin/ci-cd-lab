# Lab 02 — Speed & Cost: Caching, Matrices, Artifacts

> **Roadmap:** Project 2 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Cut your pipeline's wall-clock time and runner-minute cost roughly in half, without removing a single check from the contract.

---

## Concepts

### Feedback latency is the metric

Pipeline speed is not a vanity number. It sets the length of the loop between making a mistake and finding out, and that length determines behaviour. Under about five minutes, people wait for the result. Past ten, they context-switch and come back later — which means the fix arrives after they have forgotten the details, and often after someone else has built on the broken commit.

So the target is not "fast." The target is **inside the window where a human will still be paying attention**, and every second you remove from a pipeline is removed from every future run by everyone.

The second metric is **runner-minutes**, which is money. On a public repository GitHub-hosted runners are free, which makes this lab cost nothing — but the habits transfer directly to private repos where a Linux runner is about $0.008/minute and a macOS runner is ten times that.

---

### Jobs are parallel; `needs` is what makes them slow

Jobs run concurrently by default. Every `needs:` edge you add is latency you chose, so it should buy something concrete:

- **A real data dependency.** Deploy genuinely cannot start before build.
- **Cost avoidance.** Don't run a 20-minute integration suite if the 10-second lint already failed.

What `needs:` should never buy is tidiness. Sequencing two independent jobs so the log reads nicely converts a 3-minute pipeline into a 6-minute one and hides half the failures until the next run.

The shape to aim for is a **diamond**: fan out wide, then converge on one aggregate job.

```
                  ┌──> api (py3.11) ─┐
  changes ──┬────>├──> api (py3.12) ─┤
            │     └──> api (py3.13) ─┤
            └────────> worker ───────┴──> ci-passed
```

---

### Caching: the key is the whole design

A cache is a lookup dictionary. It saves a directory — usually your installed dependencies — under a **key**, so a later run can restore it instead of doing the work again.

**The rule: key on a hash of the lock file.** When dependencies change, the lock file changes, the hash changes, and you get a new key — which is precisely when you *want* the old cache thrown away. Any other key is wrong in one of two directions, and the important thing is that **both look green**:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Too specific** | keyed on the commit SHA — `cache-${{ github.sha }}` | every commit mints a new key, so no run ever finds a prior cache | green check, full save cost on every run, zero time saved |
| **Too loose** | keyed on a constant — `cache-v1` | the key never changes, even when dependencies do | green check, and CI is testing a lockfile nobody has |

Neither failure produces a red X. A cache step that is silently useless and one that is silently lying are indistinguishable from the run summary — you have to read the restore log or compare timings to tell.

`restore-keys` softens the first case: it gives a **prefix fallback**, so when the exact hash misses you still restore the closest older cache and reinstall only what moved. Most dependencies do not change in any given commit, which is what makes a partial hit worth far more than nothing.

**The monorepo trap.** `actions/setup-node` and `astral-sh/setup-uv` both look for a lock file in the **repository root** by default. This repo has none — they live in `app/api/` and `app/worker/`. The setting is spelled differently for each, which is its own small trap:

| Action | Input |
|---|---|
| `actions/setup-node` | `cache-dependency-path` |
| `astral-sh/setup-uv` | `cache-dependency-glob` |

Note that `working-directory` does **not** help here. It governs `run:` steps; it has no effect on where a `uses:` action looks for files. Get this wrong and the action reports success while caching nothing — the same failure you met in Lab 01, where the worker job could not find `app/worker/package-lock.json`.

**Scope.** A branch can read caches from itself and from the default branch, but **not** from sibling branches. So the first run on a new branch usually misses unless `main` has already warmed it.

> Further reading: [GitHub Docs — Caching dependencies to speed up workflows](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/cache-dependencies)

---

### Matrices, and where they stop being the right tool

A **matrix** expands one job definition into many, one per combination — the same steps run against a different Python version, OS, or database engine.

**The rule: a matrix is for homogeneous variation.** The moment the legs need different commands, it is the wrong tool. You can force it with `include:` and a per-entry command string, but you end up with a job whose steps are data — which no linter can check and no reader can follow. That is why this lab matrices the API over three Python versions and leaves the worker as its own job: **three Python versions are the same thing three times; a Python service and a Node service are two different things.**

Three settings decide whether a matrix produces information or just a bill:

| Setting | What it is for | What happens if you get it wrong |
|---|---|---|
| **`fail-fast: false`** | keeps the other legs running after one fails | the default `true` cancels every sibling on the first failure, destroying the only thing a version matrix exists to tell you — whether the break is version-specific |
| **`name:` includes the value** | labels each leg, e.g. `api (3.12)` | the checks list shows N identical rows and you cannot tell which one is red |
| **something references `matrix.<value>`** | actually varies the environment | N identical jobs at N times the cost, all green, all testing the same default version |

The third is the one that catches everyone once, because it is invisible: the matrix expands, the UI shows three legs, they all pass, and nothing was ever tested twice.

**Cost is part of the design.** Three Python versions is three times the runner-minutes, forever, on every push. Matrix the versions you actually support and would act on a failure in — typically your lowest supported version and the current release — not every version that exists. A leg whose failure would not change what you do is a leg you are paying to ignore.

> Further reading: [GitHub Docs — Running variations of jobs in a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations)

---

### Artifacts vs cache

Both move files out of a job and both are configured with a `uses:` step, which is why they get confused. They answer opposite questions.

**The rule: if this disappeared, would the run still be correct?** Yes → cache. No → artifact. A cache is an optimisation and must be safe to miss; an artifact is output and must be there.

| | Cache | Artifact |
|---|---|---|
| Moves data | between **runs** | between **jobs**, and to you |
| Correctness | must be safe to miss | must be there |
| Lifetime | evicted (7 days unused, 10 GB repo cap) | retained (default 90 days) |
| Typical use | dependencies, build layers | test reports, coverage, binaries |

Getting the direction wrong is not symmetrical. Treating a cache as an artifact wastes storage; treating an artifact as a cache means the file your next job needs is sometimes simply absent, and the job fails on a Tuesday for no reason you changed.

Two ways the upload itself goes wrong:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Colliding names** | the same artifact name uploaded from every matrix leg | on `upload-artifact@v4` a name must be unique within a run — it is an error, not a merge | the run fails on the second leg to finish, so *which* leg fails varies between runs |
| **Hoarding** | leaving `retention-days` at its default | every coverage report is kept for 90 days | nothing at all, until the storage quota does — artifacts bill against your account's storage, separately from the cache's 10 GB repo cap |

The fix for the first is to put the matrix value in the name — `coverage-${{ matrix.python-version }}`, the same value that distinguishes the job. The fix for the second is to ask how long you would actually look: a coverage report you read for ten minutes does not need three months.

---

### Path filters and the skipped-check trap

In a monorepo most changes touch one service, and building the other is pure waste. **Path filtering** removes it — and combined with branch protection it introduces the quietest failure mode in this curriculum.

**The rule: never require a path-filtered job.** Gate the service jobs on change detection, add an aggregate job that inspects their results, and require only the aggregate. Everything below is why.

The first instinct — `on: pull_request: paths:` — is the wrong tool: it filters the **entire workflow**, so nothing runs and nothing reports. What you want is a small `changes` job that computes what moved and exposes it as outputs, with the service jobs gated by `if:`. That works, and it leads straight into two failures that are opposites of each other:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Pending forever** | a path-filtered job (`worker`) is a required check | a PR touching only `app/api` skips `worker`, and a skipped job never reports a status | the check sits *Expected*, the merge button never unlocks, and there is no red X to fix |
| **False-positive green** | `if: always()` on the aggregate with no result check | the job runs even when its dependencies failed, checks nothing, and exits 0 | a green tick that means nothing — `\|\| true` from Lab 01 in a better suit |

> **A skipped job never reports a status. A required status check that never reports blocks the pull request forever.**

Skipped and successful are different states and branch protection accepts only one of them. Grey is neither green nor red, and that third state is the whole problem.

**The aggregate pattern, in order:**

1. **Detect.** A `changes` job using `dorny/paths-filter@v3`, exposing one output per service.
2. **Gate.** `needs: changes` plus an `if:` on each service job. Include the workflow file itself in every filter — otherwise a PR that only edits the pipeline skips every job and the pipeline change ships untested.
3. **Aggregate.** One `ci-passed` job, `needs:` everything, `if: always()` so it runs even when its dependencies did not, and a body that reads `needs.<job>.result` — treating `skipped` as fine and `failure` or `cancelled` as not.
4. **Require.** Mark `ci-passed` as the only required check, and remove the service jobs from protection.

Step 3 is load-bearing in both halves. `if: always()` without the result check is the false-positive green above; the result check without `always()` never runs at all.

Path filters also behave differently outside a pull request. On `push` or `workflow_dispatch` there is no base branch to diff against, so the filters report nothing changed and every job skips. On `main` you want the opposite — build everything — so your `if:` has to handle the non-PR case explicitly.

---

### Concurrency: not paying for answers nobody reads

Push three commits in a minute and you get three runs. You will read the last one. The other two finish into an empty room, and you paid for both.

A `concurrency` block puts runs into a named **group** and, with `cancel-in-progress: true`, kills the superseded ones. The group key is the entire design — it decides what counts as "superseded," and both ways of getting it wrong are worse than having no concurrency block at all.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Key too broad** | a group key that does not vary by ref, e.g. a bare workflow name | every branch shares one group, so your colleague's push cancels your run | runs dying for no visible reason, blamed on flakiness for weeks |
| **Cancelling `main`** | the same branch-keyed group applied to the default branch | merge twice in quick succession and the first merge's run is cancelled | a released commit whose only evidence is a cancelled run — neither pass nor fail |

**The rule: key on the ref, and make `main` unique.** `github.ref` (or `github.head_ref` on a PR) scopes the group to one branch. For the default branch you want the opposite of cancellation — every merged commit deserves its own run, because that run *is* the record that the released commit passed. Adding `github.run_id` to the key on `main` makes each run its own group, so nothing can supersede it.

The asymmetry is the point. On a feature branch the latest answer is the only one that matters. On `main` every answer is a permanent record, and a cancelled run is not a record of anything.

---

## Setup

```bash
make lab LAB=02
```

That writes `.github/workflows/lab-02-ci.yml`, which starts as a copy of Lab 01's finished pipeline. Lab 01's workflow stays where it is: keeping both lets you compare them run for run.

**Record your baseline before you change anything.** Push the branch, let both workflows run once, and write down the numbers.

List recent runs **with their IDs** — you need one for the next command:

```bash
gh run list --workflow lab-01-ci.yml --limit 5 \
  --json databaseId,conclusion,displayTitle \
  --jq '.[] | "\(.databaseId)  \(.conclusion)  \(.displayTitle[0:50])"'
```

Then measure one run. This prints each job's duration and the totals, so you do not have to subtract timestamps by hand — substitute a real ID for `RUN_ID`:

```bash
RUN_ID=34735066921   # <- from the list above

gh run view "$RUN_ID" --json jobs,createdAt,updatedAt --jq '
  (.jobs | map((.completedAt|fromdate) - (.startedAt|fromdate))) as $d |
  "wall-clock: \((.updatedAt|fromdate)-(.createdAt|fromdate))s",
  "job-seconds: \($d|add)s across \($d|length) jobs",
  (.jobs[] | "  \(.name): \(((.completedAt|fromdate)-(.startedAt|fromdate)))s")'
```

**Wall-clock and job-seconds are different numbers and they move for different reasons.** Wall-clock includes time queueing for a runner, which you do not control and which varies by an order of magnitude — a run measured at 46s of wall-clock can be 24s of work and 22s of waiting. Job-seconds is what you are billed for and what this lab's changes actually move. Record both; judge by the second.

Cold-cache numbers need a cold cache. GitHub keeps caches for seven days, so an ordinary re-run is warm:

```bash
gh cache list                 # what is currently stored
gh cache delete --all         # then re-run to measure cold
```

Fill this in now and again at the end:

| | Baseline (Lab 01) | Optimized (Lab 02) |
|---|---|---|
| Wall-clock, cold cache | | |
| Wall-clock, warm cache | | |
| Total job-seconds | | |
| Jobs run for an api-only change | | |

Without the first column, "it feels faster" is all you will have.

---

## Tasks

All six are in `.github/workflows/lab-02-ci.yml`.

### Task A — Stop paying for superseded runs (`TODO(lab-02-a)`)

Covers: concurrency groups, and why `main` is the exception.

Add a top-level `concurrency` block, keyed per branch, with `cancel-in-progress: true` — and arranged so runs on `main` are never cancelled.

**What to observe:**
- Push twice within a few seconds. The first run's status flips to `cancelled` mid-flight.
- `cancelled` is a distinct conclusion from `failure`. Anything reading run history has to handle three outcomes, not two.

**Questions to reflect on:**
- Why is cancelling a run on `main` worse than cancelling one on a feature branch?
- If two people push to the same branch simultaneously, whose run survives, and is that the right one?

---

### Task B — Cache dependencies (`TODO(lab-02-b)`)

Covers: cache keys, lock files, the monorepo default-path trap.

Enable caching in `astral-sh/setup-uv` (`enable-cache`, `cache-dependency-glob`) and in `actions/setup-node` (`cache`, `cache-dependency-path`). Both must point at the lock file inside the service directory.

**What to observe:**
- Run twice with no dependency change. The second install step's duration is the entire lesson.
- Then change a dependency in `app/api/pyproject.toml`, run `uv lock`, and push. The cache misses — correctly.
- Look at the cache list: `gh cache list`. Note the key, the size, and the branch it belongs to.

**Questions to reflect on:**
- If you omit `cache-dependency-path`, the step still passes. How would you find out it was doing nothing?
- Your cache is 400 MB and the repo limit is 10 GB. What happens on the fiftieth branch?
- Would you cache the `.venv` directory itself instead of uv's download cache? What breaks if the runner's Python version changes?

---

### Task C — Matrix the API over Python versions (`TODO(lab-02-c)`)

Covers: matrices, `fail-fast`, making the legs distinguishable.

Add `strategy.matrix.python-version` with 3.11, 3.12 and 3.13, set `fail-fast: false`, pass the version to `setup-uv`, and put it in the job `name:`.

**What to observe:**
- Three jobs, three checks, all starting simultaneously. Wall-clock barely moves; job-minutes triple. That trade is the decision you are making.
- Deliberately forget to pass `matrix.python-version` to `setup-uv`. Everything is green, and all three legs tested the same interpreter. Nothing warns you.

**Questions to reflect on:**
- Three versions cost 3× the minutes. What would justify it, and what would justify testing only the oldest and newest?
- Why does the worker not get a matrix here? What would have to be true for a Node version matrix to earn its cost?

---

### Task D — Only build what changed (`TODO(lab-02-d)`)

Covers: change detection, job outputs, and the reason Task F exists.

Add a `changes` job using `dorny/paths-filter@v3` with `api` and `worker` filters, expose them as job outputs, and gate both service jobs with `needs: changes` and an `if:`.

Both filters must also match `.github/workflows/lab-02-ci.yml` — otherwise a PR that only edits the pipeline skips every job, and the pipeline change ships untested. And your `if:` has to handle non-PR events, where there is no base to diff against and the filters report nothing changed.

**What to observe:**
- Open a PR touching only `app/api`. The worker job is grey and marked *Skipped*.
- Grey is neither green nor red. That third state is what breaks branch protection, which Task F fixes.

**Questions to reflect on:**
- The api filter matches `app/api/**`. What is the first shared file whose change should rebuild both services and matches neither filter?
- "Only build what changed" is an assumption about coupling. When is that assumption wrong, and what does it cost you when it is?

---

### Task E — Keep the evidence (`TODO(lab-02-e)`)

Covers: artifacts, name collisions, retention.

Generate a coverage report in the api job and upload it with `actions/upload-artifact`. The name must be unique per matrix leg; set a short `retention-days`.

**What to observe:**
- Use the same artifact name in all three legs first. `upload-artifact@v4` errors — v4 made this a hard failure rather than a silent overwrite.
- Download the artifact from the run summary. That file outlived the machine that produced it; nothing else in the job did.

**Questions to reflect on:**
- Coverage: cache or artifact? Apply the "would the run still be correct without it?" test.
- Three coverage reports for one commit. Which one is *the* number, and who decides?

---

### Task F — One check to require (`TODO(lab-02-f)`)

Covers: the skipped-required-check trap, `if: always()`, and `needs.<job>.result`.

Add a `ci-passed` job with `needs: [api, worker]` and `if: always()`, whose body reads `needs.api.result` and `needs.worker.result`, accepts `success` and `skipped`, and fails on anything else. Then make that the required check.

```bash
gh api -X PUT repos/{owner}/{repo}/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["ci-passed"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

**What to observe:**
- Before you switch the required check over, open an api-only PR while `api` and `worker` are still required. The merge button never unlocks — the worker check is pending forever, because a skipped job never reports.
- Write `ci-passed` with `if: always()` and no result check first. Break a test. `ci-passed` is green. That is the most dangerous green tick in this curriculum.

**Questions to reflect on:**
- `cancelled` — should `ci-passed` accept it? What is a cancelled job actually telling you?
- Every service you add needs a new entry in `needs:`. What happens the day someone forgets?
- You now have one required check for a pipeline of five jobs. What did you lose in the checks list, and is it worth it?

---

## Verify

```bash
make verify LAB=02
```

Twenty-six assertions, grouped by task. Notice what they check: not that the pipeline is fast — speed is not statically observable — but that the **mechanisms** which produce speed are present *and* that each one's correctness trap is handled.

| Group | The trap it checks for |
|---|---|
| Concurrency | Group varies by branch; `main` is exempt from cancellation |
| Caching | Both caches point at the service lock file, not the repo root |
| Matrix | `fail-fast: false`; the matrix value is actually consumed and shown in the name |
| Path filters | Both filters match the workflow file itself |
| Artifacts | Unique name per matrix leg; bounded retention |
| Aggregate | `always()` *and* a real result check *and* `skipped` handled distinctly |

The last two tests are the live ones: `actionlint` if installed, and a real successful run via `gh`. Push before you call this done.

`make solution LAB=02` diffs against the reference; `make reset LAB=02` starts over.

---

## Evaluation Checklist

- [ ] What are the two ways to get a cache key wrong, and what does each one look like from the outside?
- [ ] Why does `setup-node` cache nothing in this repo without `cache-dependency-path`?
- [ ] When is a matrix the wrong tool, and what should you use instead?
- [ ] What does `fail-fast: true` cost you in a version matrix?
- [ ] Cache or artifact — and what is the one question that decides it?
- [ ] Why can't you mark a path-filtered job as a required status check?
- [ ] What does `if: always()` do on its own, and why is that worse than not adding it?
- [ ] Why should a concurrency group exempt `main`?
- [ ] Your pipeline got faster. By how much, and how do you know?

## What's Next

**Lab 03 — Abstraction, Service Containers & the Local Loop**

You now have two workflows that share most of their content, and two jobs inside Lab 02 that differ in six lines and agree on twenty. Add a third service and you copy it a third time. Lab 03 removes that duplication — but not the way you expect: the real fix is giving every service the same interface, not making the YAML cleverer. Then it adds the two things this pipeline still cannot do. It runs the API's tests against a real DynamoDB in a service container, because the bug that only appears against a real database is the one a mock is guaranteed to miss. And it puts `act` on your laptop, so a workflow typo costs seconds instead of a push and a four-minute wait.
