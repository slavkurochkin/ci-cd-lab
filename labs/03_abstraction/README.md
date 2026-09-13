# Lab 03 — Abstraction, Service Containers & the Local Loop

> **Roadmap:** Project 3 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Turn the pipeline into an interface, test against a real database instead of a mock, and stop pushing to find out whether a workflow works.

---

## Concepts

### The duplication you are actually removing

Lab 02 ended with two jobs that differ in about six lines and agree on twenty. Add a third service and you copy it again. The instinct is to make the YAML cleverer — a matrix over services, an `include:` block carrying per-service commands.

That instinct is wrong, and it is worth naming why before reaching for any GitHub feature. A matrix whose legs run different commands produces a job **whose steps are data**: no linter can check them, no reader can follow them, and every new service adds a branch to a string. You have moved the duplication, not removed it.

The actual fix is upstream of the pipeline. **Give every service the same interface**, and the pipeline stops needing to know what a service is:

```
app/api/Makefile          app/worker/Makefile
  install                   install
  lint                      lint
  test                      test
  test-integration          test-integration
```

Now the pipeline runs `make lint` in `app/${{ inputs.service }}` and is finished. It does not know that one service is Python and the other TypeScript, and it does not need to. Adding a Go service means writing a Makefile with four targets, not editing the pipeline at all.

This is the whole lesson of the lab, and the two GitHub features below are only worth learning once you have it: **uniformity in what you are building is what makes the thing building it simple.** Abstraction in the YAML can only ever compensate for the absence of it.

---

### Composite actions vs reusable workflows

Two mechanisms, and the choice between them is not a matter of taste.

|  | Composite action | Reusable workflow |
|---|---|---|
| Replaces | steps | jobs |
| Lives in | `.github/actions/<name>/action.yml` | `.github/workflows/<name>.yml` |
| Invoked by | `uses:` **inside** a job's steps | `uses:` **as** a job |
| Can set `runs-on` | no | yes |
| Can contain jobs | no | yes |
| Can use `secrets:` | no — pass as inputs | yes, including `secrets: inherit` |
| Runs on | the caller's runner | its own runners |

The rule: **if what repeats is a sequence of steps inside one job, write a composite action. If what repeats is a whole job — or several — write a reusable workflow.** This lab uses both, because both kinds of repetition exist: setting up a toolchain is steps, and the whole lint/test/upload shape is a job.

Two things about composite actions catch everyone once:

- **Every `run:` step must declare `shell:`.** Workflows default it to bash; composite actions have no default, and the error message (`Required property is missing: shell`) does not appear until the action runs.
- **Inputs are always strings.** There is no `type:` on a composite action input. `if: inputs.enabled == 'true'` compares strings, and `if: inputs.enabled` is true for the string `"false"`.

> Further reading: [GitHub Docs — Reusing workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)

---

### The reusable workflow as an interface

A reusable workflow declared with `workflow_call` has a signature: typed `inputs`, typed `outputs`, and explicitly-passed `secrets`. That signature is the contract, and it is what makes the workflow reviewable independently of its callers.

Three details matter in practice.

**`type:` is mandatory on `workflow_call` inputs** — `string`, `boolean`, or `number`. The workflow will not parse without it. This is the opposite of composite actions and there is no way to remember which is which except by meeting the error.

**A matrix cannot be an input.** Inputs are only strings, booleans and numbers, so there is no way to pass a list. The idiom is to pass JSON as a string and unpack it at the other end:

```yaml
# caller
with:
  versions: '["3.11", "3.12", "3.13"]'

# callee
strategy:
  matrix:
    version: ${{ fromJSON(inputs.versions) }}
```

**Job outputs from a matrixed job are last-writer-wins.** Every leg writes the output and the last one to finish wins — with no defined ordering between legs. An output whose value depends on `matrix.*` is therefore non-deterministic. An output that does not depend on the matrix is fine, and that distinction is the only thing keeping this lab's `coverage-artifact` honest.

Two more constraints worth knowing before you design around them: **nesting is limited to three levels**, and **a job that calls a reusable workflow may not also declare `steps`, `runs-on`, or `timeout-minutes`.** The called workflow owns all of that; declaring it in the caller is a parse error.

---

### Service containers

Some tests are only meaningful against the real thing. This repository's `OrderStore` converts `float` to `Decimal` on the way into DynamoDB and back on the way out — because DynamoDB rejects `float` outright. A mocked store accepts floats happily and the test passes, right up until production.

`services:` gives a job sidecar containers on the runner's Docker network, started before the first step:

```yaml
services:
  dynamodb:
    image: amazon/dynamodb-local:2.5.2
    ports:
      - 8000:8000
```

**Networking differs by job type**, which is the most common confusion. A job running *directly on the runner* reaches the service through the mapped host port, on `localhost:8000`. A job running *inside a container* is on the same Docker network and reaches it by service name, `dynamodb:8000`, with no port mapping needed. The same YAML behaves differently depending on something declared elsewhere.

**Health checks are best-effort.** `options: --health-cmd pg_isready --health-interval 10s --health-retries 5` works beautifully for `postgres:16`, because that image contains `pg_isready`. The health command runs *inside* the service container, so it can only use tools that image ships. `amazon/dynamodb-local` is a JRE and an application — no curl, no wget, no shell health tool. There is nothing for `--health-cmd` to run.

So the readiness wait becomes the job's problem, and skipping it produces the worst class of failure: a race that passes on a fast runner and fails on a slow one, intermittently, forever.

Finally, **pin the image**. `amazon/dynamodb-local:latest` turns an upstream release into a failing build on a commit that changed nothing.

> Further reading: [GitHub Docs — About service containers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/use-containerized-services)

---

### Integration tests as a separate marker

Adding a real dependency to the test suite is a direct attack on Lab 02's feedback-latency work, unless you keep the two suites apart. This repo uses a pytest marker:

```toml
addopts = "-q -m 'not integration'"
```

The default run excludes them, so `make test` stays under a second. `make test-integration` runs only them, and they skip cleanly when `DYNAMODB_ENDPOINT` is unset — so a contributor with no Docker still gets a working `make test` rather than a wall of errors.

That single environment variable is also what makes the code portable: identical application code talks to a service container in CI and a real table in AWS. Capstone B changes nothing but the value.

---

### The local loop

Everything in this lab so far has been about the pipeline's speed. This section is about *your* speed while editing the pipeline.

The default loop for a workflow change is commit → push → wait → read logs. That is minutes, for a class of mistake — a typo in a shell line, a wrong `working-directory`, a missing `shell:` — that is decided in the first two seconds of the job. It is the same feedback-latency problem as a slow test suite, applied to the thing you built to fix feedback latency.

[`act`](https://github.com/nektos/act) runs workflow jobs in Docker containers on your laptop. Configured through `.actrc`, `make ci-local JOB=api` gives you a result in seconds.

**Know what it cannot do before you trust it.** act approximates the runner; it does not reproduce it:

- **OIDC token minting** does not work — everything in Project 4 needs a real run
- **Most of the `github` context** is synthetic: no real PR number, no real event payload
- **The Actions cache backend** is not the real one, so cache-hit behaviour proves nothing
- **`services:` networking** works but differs from GitHub's
- **The runner image is not GitHub's image**, so "tool not found" may be act's fault or yours

Which gives the honest division of labour: **act tells you the workflow is wired correctly. Only a real run tells you it works.** The fallback when act will not do is `workflow_dispatch` on a branch — still a push, but no PR ceremony.

---

## Setup

```bash
make lab LAB=03
```

Four files this time:

```
.github/actions/setup-service/action.yml   composite action
.github/workflows/reusable-service-ci.yml  reusable workflow
.github/workflows/lab-03-ci.yml            the caller
.actrc                                     local loop config
```

Optional but recommended:

```bash
brew install act actionlint
```

Confirm the uniform interface exists before you build a pipeline on top of it:

```bash
cd app/api    && make lint && make test
cd app/worker && make lint && make test
```

Both services respond to the same four targets. That is the foundation the rest of this lab rests on.

Then confirm the integration suite works locally, so a red pipeline later is a pipeline problem:

```bash
make test-integration     # starts DynamoDB Local, runs them, tears it down
```

---

## Tasks

Work them in order — D cannot be tested before B exists.

### Task A — The composite action (`TODO(lab-03-a1/a2/a3)`)

Covers: composite action structure, untyped inputs, the `shell:` requirement.

In `.github/actions/setup-service/action.yml`: declare `service` and `version` inputs, gate the uv and Node setup steps on `service`, and give the `run:` step a `shell:`.

**What to observe:**
- The install step needs no per-service branch, because both services expose `make install`. Count how many steps needed an `if:` and how many did not — that ratio is the payoff from the uniform interface.
- Remove `shell: bash` and run it. The error appears at runtime, not at parse time. Nothing catches it locally except actually running the action.

**Questions to reflect on:**
- Composite action inputs are untyped strings. What does `if: inputs.version` evaluate to when `version` is the string `"false"`?
- This action sets up a toolchain but does not check out the repository. Why is that the caller's job?

---

### Task B — The reusable workflow's interface (`TODO(lab-03-b)`)

Covers: `workflow_call`, typed inputs, workflow outputs, last-writer-wins.

In `reusable-service-ci.yml`: replace the trigger with `workflow_call`, declare the three typed inputs, and expose a `coverage-artifact` output wired to the `test` job. Then read it in the caller's `ci-passed` job.

**What to observe:**
- Omit a `type:` on one input. The workflow does not parse — a much better failure than the composite action's runtime error, and the opposite convention. There is no logic to it; you learn it by meeting it.
- The verifier rejects a job output containing `matrix.`. Work out why before reading the message.

**Questions to reflect on:**
- What would you have to change to make `coverage-artifact` correct *and* matrix-dependent?
- A reusable workflow can take `secrets: inherit`. Why is that convenient and also the thing you would flag in review?

---

### Task C — A matrix from an input (`TODO(lab-03-c)`)

Covers: `fromJSON`, and the limits of the input type system.

Add `strategy.matrix.version: ${{ fromJSON(inputs.versions) }}`, with `fail-fast: false` and the version in the job `name:`.

**What to observe:**
- The caller passes `'["3.11", "3.12", "3.13"]'` — a string that happens to contain JSON. Break the quoting and the error surfaces at expansion time, in the callee, far from the caller that caused it.
- The worker now gets a Node 20/22 matrix. Lab 02 asked what would justify one; this is the answer.

**Questions to reflect on:**
- Inputs cannot be lists. Is passing JSON strings a reasonable workaround or a sign the interface wants splitting?
- Where would you validate that `versions` is well-formed, given the caller and callee are different files?

---

### Task D — The caller (`TODO(lab-03-d1/d2)`)

Covers: calling a reusable workflow, the no-`steps` rule, shared-file change detection.

Add `api` and `worker` jobs that `uses:` the reusable workflow, keeping their `needs: changes` and `if:` gating. Then extend both path filters to cover the three pipeline files.

**What to observe:**
- Compare `lab-03-ci.yml` with `lab-02-ci.yml`. The contract is *larger* — it now runs integration tests too — and each service is four lines.
- Copy `runs-on: ubuntu-latest` across from Lab 02 out of habit. The workflow fails to parse, with an error naming the job.
- In the checks list, reusable workflow jobs appear as `api / api (3.11)`. Branch protection matches on that full string.

**Questions to reflect on:**
- Adding a service is now one caller job. What is still duplicated between the two callers, and is it worth removing?
- The composite action and the reusable workflow are versioned with the repo, so a change takes effect everywhere at once. When would you want them in a separate repo with tags instead?

---

### Task E — The service container (`TODO(lab-03-e)`)

Covers: `services:`, readiness, port mapping, image pinning.

Add the `integration` job: gated on `inputs.run-integration-tests`, with a pinned `amazon/dynamodb-local` service container on port 8000, a readiness wait, and `make test-integration` with `DYNAMODB_ENDPOINT` set.

**What to observe:**
- Delete the wait loop and push a few times. It usually passes. That is what a race looks like before it becomes an incident.
- Try `options: --health-cmd "curl -f http://localhost:8000"` instead. It fails — the health command runs *inside* a container with no curl.
- Comment out `ports:` and watch the connection refuse. The container is running; it is just not reachable from a job on the runner.

**Questions to reflect on:**
- `test_floats_survive_the_decimal_boundary` passes against a mock and would have shipped a bug. What else in your systems is only true against the real dependency?
- Service containers make this job slower than the unit job. What is the rule for deciding what earns a real dependency?
- If the integration job runs inside a container instead of on the runner, what breaks, and what is the one-line fix?

---

### Task F — The local loop (`TODO(lab-03-f)`)

Covers: `act`, and the honesty about what it cannot do.

Fill in `.actrc` with the runner image mapping, container architecture, and artifact server path. Then:

```bash
make ci-local JOB=api
```

**What to observe:**
- The first run pulls a large image. Subsequent runs are seconds.
- Break something on purpose — a wrong `working-directory` — and fix it without pushing. Time both loops. That difference is the entire justification.
- Then find something act gets wrong. Cache steps report hits that mean nothing.

**Questions to reflect on:**
- act cannot mint OIDC tokens, so none of Project 4 is locally testable. How would you design a workflow so the untestable parts are as small as possible?
- Where is the line between "act said yes so I will push" and "act cannot answer this, push and watch"?

---

## Verify

```bash
make verify LAB=03
```

Forty-five assertions across four files.

| Group | What it proves |
|---|---|
| Composite action | Correct `using`, both services gated, `version` consumed, **every `run:` has a `shell:`** |
| Untyped vs typed | Action inputs have no `type:`; `workflow_call` inputs all do |
| Interface | Output declared, wired to a job, and **not matrix-dependent** |
| Service agnosticism | The reusable workflow mentions no `uv run`, `npm ci`, `pytest`, `ruff` or `vitest` |
| Caller | Delegates, has no `steps`/`runs-on`/`timeout-minutes`, keeps its gating, consumes the output |
| Change detection | All three pipeline files retrigger both services |
| Service container | Declared, **pinned**, port-mapped, waited for, `DYNAMODB_ENDPOINT` set |
| Local loop | `.actrc` complete, `make ci-local` exists |

`test_reusable_workflow_is_service_agnostic` is the one that enforces the lab's actual point: if the workflow mentions `pytest`, it cannot build the worker, and you have written a Python pipeline wearing a generic name.

The last three tests are live: `actionlint` on both workflows if installed, and a real successful run via `gh`. Push before you call this done — nothing here proves `fromJSON` expands correctly or that the service container starts.

---

## Evaluation Checklist

- [ ] What repeats as *steps* versus as *jobs*, and which mechanism does each want?
- [ ] Why does every `run:` in a composite action need `shell:` when workflows do not?
- [ ] Composite action inputs and `workflow_call` inputs disagree about `type:`. Which way round?
- [ ] Why can't a matrix be passed as an input, and what is the idiom instead?
- [ ] Why is a job output that references `matrix.*` non-deterministic?
- [ ] What three things may a job **not** declare when it calls a reusable workflow?
- [ ] A service container reached on `localhost:8000` from one job and `dynamodb:8000` from another. What differs?
- [ ] Why can't `--health-cmd` work for `amazon/dynamodb-local`, and what do you do instead?
- [ ] Name three things `act` cannot simulate.
- [ ] The real fix for duplicated pipeline YAML was not a GitHub feature. What was it?

## What's Next

**Lab 04 — Trust: Permissions, OIDC & Supply Chain**

Your pipeline is fast, DRY, and tests against a real dependency. It also runs with a token scoped to write almost everything, calls third-party actions by a mutable tag, and has no way to reach AWS except a long-lived access key you have not created yet — and should never create. Lab 04 scopes `GITHUB_TOKEN` down per job, federates to an AWS role with OIDC so no credential is ever stored, pins every third-party action to a SHA, and walks the exact shape of the `pull_request_target` attack that a public repository makes available to anyone who can open a pull request.
