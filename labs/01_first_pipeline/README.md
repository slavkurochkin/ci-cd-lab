# Lab 01 — Pipelines & the Build Contract

> **Roadmap:** Project 1 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Get one workflow running on every pull request, and make it impossible to merge without it.

---

## Concepts

### What continuous integration actually guarantees

CI is often described as "running tests automatically," which undersells it. The guarantee is narrower and more useful: **every change is verified against the same contract, in the same environment, before it becomes part of the mainline.** The value is not that tests run — you could run them locally. The value is that they run somewhere you do not control, on a machine with none of your local state, on every change without exception.

That last clause is doing the work. A check that runs on most changes is not a contract; it is a suggestion. The failure mode is not "CI is broken," it is "CI is green and the mainline is broken anyway," which is worse because it teaches people to trust a signal that is not load-bearing.

> Further reading: [Martin Fowler — Continuous Integration](https://martinfowler.com/articles/continuousIntegration.html)

---

### The object model: workflow, job, step, action

Four nested things, and mixing them up causes most early confusion.

A **workflow** is one YAML file in `.github/workflows/`. It has triggers and one or more jobs.

A **job** is a unit of scheduling. Each job gets its own fresh virtual machine — a **runner** — with nothing on it but the base image. Jobs run in parallel by default. Two jobs share no filesystem, no processes, and no environment; anything one job produces that another needs has to be passed explicitly.

A **step** is one command or one action inside a job. Steps run in order on the same runner and do share a filesystem. If a step exits non-zero, the job fails and later steps are skipped.

An **action** is a reusable step you invoke with `uses:`. `actions/checkout` is an action; so is `astral-sh/setup-uv`.

```
workflow  (.github/workflows/lab-01-ci.yml)
├── job: api        ← fresh Ubuntu VM
│   ├── step: checkout
│   ├── step: install uv
│   └── step: run tests
└── job: worker     ← different fresh Ubuntu VM, running at the same time
    ├── step: checkout
    └── step: run tests
```

The single most common beginner surprise: a file written in one job does not exist in another. That is not a bug, it is the isolation you are paying for.

> Further reading: [GitHub Docs — Workflow syntax](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions)

---

### Events and triggers

The `on:` block decides when a workflow runs. Four triggers cover almost everything in this curriculum:

| Trigger | Fires when | Why you want it |
|---|---|---|
| `pull_request` | A PR is opened or updated | The gate. This is the one that protects `main`. |
| `push` | Commits land on a branch | Verifies the merge commit itself. |
| `workflow_dispatch` | You press a button | Testing the pipeline without opening a PR. |
| `schedule` | On a cron | Drift detection, nightly builds, dependency checks. |

**The rule: `pull_request` and `push: main` are both required, and they answer different questions.** Two ways to get `on:` wrong, and this lab starts you in the second one:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **`pull_request` alone** | it feels sufficient — the PR is where review happens | a PR is tested as a *simulated merge* into `main` **as of when CI ran**. Someone else merging in the meantime invalidates it, and two individually-green PRs can merge into a broken `main` — a **semantic conflict** | every PR green, `main` broken, and no single commit to blame |
| **`workflow_dispatch` alone** | the workflow is written but never attached to an event | nothing runs unless a human presses a button, and nobody presses it | an Actions tab that looks healthy because it is empty |

The second is the state this lab hands you in Task A. Look at the Actions tab before you change it — an unattached pipeline is indistinguishable from no pipeline, and considerably more reassuring.

> Further reading: [GitHub Docs — Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)

---

### The build contract

The **build contract** is the set of checks every change must survive. For this repository it is three things, deliberately ordered cheapest-first:

1. **Format** — is the code formatted the way the project formats code? Seconds. No judgment involved, so it should never be a review comment.
2. **Lint** — does the code contain patterns known to cause problems? Seconds.
3. **Test** — does the code do what it claims? Longer.

Order matters because feedback latency matters. If the lint check runs after a four-minute test suite, you wait four minutes to learn about an unused import. Put the fast, high-frequency failures first.

What belongs in the contract is a real decision. Too little and it does not protect you; too much and people route around it. The test: **would you be comfortable merging a change that failed this check?** If yes, it does not belong in the contract — move it to a non-blocking job.

---

### A check that cannot fail

This is the failure mode this lab is built around.

```yaml
- name: Run tests
  run: uv run pytest || true      # ← always exits 0
```

The step shows a green tick. The job shows a green tick. The PR shows a passing check. The tests failed. Everyone downstream believes something false, and they believe it because of a green tick you gave them.

**The rule: for every step you add, ask what would have to happen for this step to fail.** If you cannot answer, it is not checking anything. `|| true` is only the most obvious way to lose that answer:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **`\|\| true`** | appended to silence a noisy step "for now" | the shell's exit code becomes 0 regardless of the command's | green |
| **`continue-on-error: true`** | added to unblock a branch, never removed | the step is allowed to fail without failing the job | green, with a small warning icon almost nobody reads |
| **A suite that collects nothing** | a renamed directory, a bad marker, a wrong `working-directory` | pytest exits 0 when it runs zero tests; so do most runners | green, and *faster than usual* — the only visible symptom |
| **A script without `set -e`** | several commands in one `run:` block | shells do not stop on error; only the **last** command's exit code becomes the step's | green, when the failure was three lines from the end |
| **`if: always()` on a step** | copied from an upload step that genuinely needs it | the step runs after a failure, and its own success masks the earlier one | green |

Four of the five look identical from the outside: a passing check. The third is the only one with a tell, and the tell is that your pipeline got *faster* — which reads as good news.

This is why the question is about failure rather than success. "Did this pass?" has the same answer in all five rows. "What would make this fail?" has no answer in any of them.

---

### Branch protection is what makes CI a gate

A workflow, by itself, has no authority. It runs, it reports, and anyone can merge over the top of a red X. **Branch protection** is the setting that converts a reported result into a required one — and it is configured on the repository, not in the workflow file.

The link between them is the **check name**, which is the job's `name:` (or its ID if unnamed). You mark check names as required; GitHub then refuses the merge until those names report success.

This coupling has a sharp edge you will meet in Lab 02: if you add path filters so a job is *skipped* rather than run, a required check that never reports leaves the PR blocked forever. Skipped and successful are different states, and branch protection only accepts one of them.

**Protection is a policy, and policies have an override.** With `enforce_admins: false` — what Task F sets, deliberately — a repository admin can still merge over a red X, and a direct `git push` to `main` succeeds with nothing but a line in the output:

```
remote: Bypassed rule violations for refs/heads/main:
remote: - 2 of 2 required status checks are expected.
```

No extra flag, no confirmation, no `--force`. The same protection that made a failing test un-mergeable through a PR is a normal push away from irrelevant. Notice how little friction that is, and notice that the bypass is recorded — which is the only reason it is defensible at all.

> Further reading: [GitHub Docs — About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

---

### Reading a failed run

When a run goes red, work top-down:

1. **The run summary** shows which *job* failed. Other jobs may have been cancelled — cancelled is not failed, and their state tells you nothing.
2. **The failed step** is highlighted in the job log. Expand it; the last 20 lines are usually the whole story.
3. **Annotations** appear at the top of the run and are worth reading first — many tools emit them, and they link straight to the file and line.
4. **The exit code** tells you whether the tool ran and disagreed with you (non-zero from the tool) or never ran at all (`command not found`, exit 127). These call for completely different fixes and are easy to confuse.

Re-running a job is free and reproduces the environment exactly. Re-running because you think it is flaky, without recording that you did, is how flakiness becomes permanent — Project 18 deals with that properly.

---

## Setup

You need `uv`, `node`, `gh`, and `make`. Check with:

```bash
make doctor
```

Install the lab's starter file:

```bash
make lab LAB=01
```

That writes `.github/workflows/lab-01-ci.yml` — the real path, because that is the only place GitHub looks. Open it; it contains five TODOs.

Confirm the suites you are about to wire up actually pass locally, so a red pipeline later means a pipeline problem and not an app problem:

```bash
make test
```

---

## Tasks

All five tasks are in `.github/workflows/lab-01-ci.yml`. Work them in order — each one makes the next one meaningful.

### Task A — Make it run when it matters (`TODO(lab-01-a)`)

Covers: events, triggers, why `push: main` is not redundant with `pull_request`.

The workflow currently runs only on `workflow_dispatch`. Add `pull_request` scoped to PRs targeting `main`, and `push` scoped to `main`. Keep `workflow_dispatch`.

**What to observe:**
- Before you change anything, look at the Actions tab. The workflow exists and has never run. That is what an unattached pipeline looks like.
- After the change, a PR shows the check inline in the conversation view. That placement is most of the behavioural effect — the result appears where the decision is made.

**Questions to reflect on:**
- A PR is tested as a merge of your branch into `main` *at the time CI ran*. What can change between then and the merge button?
- If you only had budget for one of `pull_request` or `push: main`, which protects you more, and what exactly do you give up?

---

### Task B — Make the check capable of failing (`TODO(lab-01-b)`)

Covers: exit codes as the pipeline's only signal.

The test step ends in `|| true`. Before deleting it, break a test on purpose and push, so you see the run go green with a failing suite. Then remove `|| true` and watch the same commit go red.

```bash
# make a test fail, then put it back
sed -i '' 's/== 25.5/== 99.9/' app/api/tests/test_orders.py
```

**What to observe:**
- With `|| true`, the failing pytest output is right there in the log, under a green tick. Nobody reads logs on a green run — that is the whole point of a green run.
- The check name in the PR is identical in both cases. Nothing in the UI hints that one of them is lying.

**Questions to reflect on:**
- What is the difference in blast radius between a pipeline that is *red when it should be green*, and one that is *green when it should be red*?
- `continue-on-error: true` is sometimes correct. When?

---

### Task C — Complete the contract for the API (`TODO(lab-01-c)`)

Covers: the build contract, ordering checks by cost.

The api job runs tests but never lints. Add a step that runs `uv run ruff check .` and `uv run ruff format --check .`, placed **before** the test step.

**What to observe:**
- Both commands go in one step with a multi-line `run:`. If the first fails, the second never runs — steps use `set -e` semantics by default.
- `ruff format --check` reports and fails; `ruff format` would rewrite. CI must never rewrite your code silently.

**Questions to reflect on:**
- Lint and test in one step or two? One step fails faster; two steps show you which one failed without opening the log. Which do you prefer, and would you answer differently for a suite that takes ten minutes?

---

### Task D — Cover the second service (`TODO(lab-01-d)`)

Covers: job independence, parallelism, the repetition that motivates Lab 03.

Add a `worker` job doing for `app/worker` what the api job does for `app/api`: checkout, `actions/setup-node` with Node 22, `npm ci`, `npm run lint` and `npm run format:check`, then `npm test`. It must **not** declare `needs: api`.

**What to observe:**
- The two jobs start at the same time. Total wall-clock is the slower of the two, not the sum.
- You just copied the shape of the api job and changed the commands. Notice how much is duplicated — Lab 03 exists because of exactly this.
- Both jobs check out the repository. They must: they are different machines.

**Questions to reflect on:**
- If `worker` had `needs: api`, what would you learn — and not learn — from a run where both services are broken?
- `npm ci` versus `npm install`: which one belongs in CI, and what does the other one do that makes it wrong here?

---

### Task E — Bound the damage (`TODO(lab-01-e)`)

Covers: runner-minute cost, the six-hour default.

Neither job declares `timeout-minutes`, so both inherit GitHub's default of **six hours**. Set a realistic timeout on each — these suites run in seconds.

**What to observe:**
- A timeout is a cost control and a debugging tool. A job that hits its timeout is telling you something specific: it hung, rather than failed.
- The verifier rejects timeouts over 30 minutes for this repo. Ask yourself what number you would pick for a suite that genuinely takes 25 minutes.

**Questions to reflect on:**
- At $0.008/minute for a Linux runner, what does one hung job cost before someone notices on a Friday evening?
- A timeout too tight causes flaky failures under load. How would you choose the number rather than guessing it?

---

### Task F — Make the check required (no TODO; this is repository configuration)

Covers: branch protection, the difference between reporting and gating.

Everything so far still lets you merge over a red X. Push your branch, open a PR, then require both checks.

```bash
git switch -c lab-01
git add .github/workflows/lab-01-ci.yml
git commit -m "Lab 01: build contract for both services"
git push -u origin lab-01
gh pr create --fill
```

Once the run has finished at least once, the check names become selectable:

```bash
gh api -X PUT repos/{owner}/{repo}/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["api", "worker"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

Then prove the gate holds: break a test, push, and try to merge.

**What to observe:**
- The merge button goes from green to disabled, with the failing check named. That change in the UI *is* continuous integration; everything before it was a report.
- `"strict": true` additionally requires the branch to be up to date with `main` before merging. That is the direct answer to the semantic-conflict problem from Task A.
- With `enforce_admins: false`, you can still merge as the repository owner. Notice that you *can*, and notice how tempting it is.

**Questions to reflect on:**
- Branch protection lives in repository settings, not in the workflow file — so it is not code-reviewed and not in Git. What would you lose if someone quietly turned it off?
- Which of the two checks would you make required first if you could only have one?

---

## Verify

```bash
make verify LAB=01
```

The verifier asserts, in the order the tasks appear:

| Test | What it proves |
|---|---|
| `test_runs_on_pull_requests`, `..._targets_main`, `..._push_to_main` | Task A: the workflow is attached to the events that matter |
| `test_manual_trigger_kept` | You did not lose `workflow_dispatch` while editing |
| `test_no_step_swallows_its_exit_code` | Task B: no `\|\| true` anywhere |
| `test_no_job_or_step_continues_on_error` | Task B: the subtle version too |
| `test_both_services_have_a_job` | Task D: the worker job exists |
| `test_worker_job_is_independent_of_api` | Task D: no needless `needs:` edge |
| `test_build_contract_step_present[...]` | Tasks C and D: six parametrized checks, one per contract command per service |
| `test_api_lint_runs_before_tests` | Task C: cheap checks first |
| `test_every_job_has_a_timeout`, `test_timeouts_are_realistic` | Task E |
| `test_actionlint_is_clean` | The workflow is valid — skipped unless `actionlint` is installed |
| `test_workflow_has_actually_run` | Task F: a real run really succeeded — skipped until you push |

The last one is the only test that proves the workflow *works* rather than that it is *shaped correctly*. Static analysis cannot tell you that `astral-sh/setup-uv` resolves or that `npm ci` succeeds on a clean runner. Push the branch before you call this lab done.

Stuck? `make solution LAB=01` diffs your file against the reference. `make reset LAB=01` restores the starter.

---

## Evaluation Checklist

Before moving on, you should be able to answer these:

- [ ] Why does a job need `actions/checkout` when the workflow already lives in the repository?
- [ ] Two jobs, one writes a file and the other reads it. What happens, and why?
- [ ] Your PR is green. Someone else merges to `main`. Is your PR still green, and should it be?
- [ ] Name three ways a step can pass while the thing it checks is broken.
- [ ] What is the exact mechanism that stops a merge when a check fails — and where is it configured?
- [ ] A required check is skipped by a path filter. What happens to the PR?
- [ ] Why does the build contract run format and lint before tests?
- [ ] What is a job's default timeout, and what does that cost you if a job hangs?

## What's Next

**Lab 02 — Speed & Cost: Caching, Matrices, Artifacts**

Your pipeline is correct and slow. Every run reinstalls every dependency from scratch, both services are wired up by copy-paste, and pushing three times in a minute pays for three full runs of which you will read one. Lab 02 measures the baseline you just built, then halves it — with caching, a build matrix, path filters, and concurrency groups — without removing a single check from the contract.
