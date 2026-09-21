# Contributing

This repository is a CI/CD curriculum and a working repository at the same
time. Both halves have rules, and they are different rules.

---

## The build contract

Every service in `app/` answers to the same six commands. That is the whole
reason one pipeline can build all of them without knowing what language any of
them is written in.

| | What it does | Must pass before merge |
|---|---|---|
| `make install` | install dependencies | — |
| `make lint` | format check and lint | **yes** |
| `make typecheck` | static types | **yes** |
| `make test` | unit tests | **yes** |
| `make coverage` | tests with a coverage floor | **yes** |
| `make test-integration` | tests needing a real dependency | yes, where one exists |

Run all of them from the repository root:

```bash
make test        # both services
make lint        # both services
```

Or one service:

```bash
cd app/api && make coverage
```

### Adding a service

Write a `Makefile` with those six targets and a `Dockerfile`. Then add four
lines to `.github/workflows/lab-03-ci.yml`:

```yaml
  newservice:
    needs: changes
    if: github.event_name != 'pull_request' || needs.changes.outputs.newservice == 'true'
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: ./.github/workflows/reusable-service-ci.yml
    with:
      service: newservice
      versions: '["22"]'
      publish: ${{ github.ref == 'refs/heads/main' }}
```

Add it to the `changes` job's path filters, and to `ci-passed`'s `needs`.

**Nothing in the pipeline changes.** If you find yourself editing
`reusable-service-ci.yml` to accommodate a service, the service is the thing
that is wrong.

---

## The coverage floor

Coverage thresholds live with each service — `[tool.coverage.report]` in
`app/api/pyproject.toml`, `coverage.thresholds` in
`app/worker/vitest.config.ts`. What counts as covered is a property of the
code, not of the pipeline.

**They are floors, not targets.** Raise them when the real number rises. Never
lower one to make a build pass; if coverage dropped, either add the test or
explain in the pull request why the drop is correct.

**What they do not measure.** These count whether a line executed. A test with
no assertions raises them. The gate stops coverage falling silently; it cannot
tell anyone the tests are any good, and no automated gate can.

`app/api` excludes `store.py` from its floor. That file is the DynamoDB
boundary and is covered by `tests/integration/`, which the default run skips.
Measuring it in the unit floor would report 32% and invite unit tests that mock
the very boundary the integration tests exist to check.

---

## Workflows

### Pinning

Every third-party action is pinned to a **commit SHA**, with the version as a
trailing comment:

```yaml
uses: dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d # v4.0.3
```

A tag is a pointer its owner can move. This is not a style preference —
`zizmor` treats an unpinned action as an error, so the `Security` workflow
fails on one.

Dependabot proposes updates weekly with a seven-day cooldown. Minor and patch
arrive grouped; **majors arrive one per pull request**, so a red run names its
own cause.

### Permissions

Every workflow declares `permissions:` explicitly. The repository default is
safe, but a default is a setting someone can change; a declaration travels with
the file.

**A called workflow cannot request more than its caller granted.** If you add a
permission inside `reusable-service-ci.yml`, grant it on the calling job too —
otherwise the run fails to start, before any job, with no log to read.

### Before pushing a workflow change

```bash
actionlint                                    # syntax and expressions
zizmor --offline --config .github/zizmor.yml .github/   # security
make ci-local JOB=api                         # run a job locally
```

`act` tells you the workflow is wired correctly. Only a real run tells you it
works — see `labs/03_abstraction/README.md` for what `act` cannot reproduce.

---

## Pull requests

`ci-passed` is the only required status check. It aggregates every service's
result and treats a **skipped** job as acceptable, which is what lets path
filtering work: a change to `app/api` skips the worker entirely, and the merge
button stays unlocked.

**Do not make an individual service job a required check.** A path-filtered job
that is skipped never reports a status, and a required check that never reports
blocks the pull request forever — with no red X and nothing to fix.

Images publish only from `main`. A pull request builds and scans — that is the
gate — and pushes nothing.

---

## The labs

`labs/01_first_pipeline` through `labs/05_containers` are graded exercises, not
documentation. Each has a starter with deliberate gaps, a verifier, and a
reference solution.

```bash
make lab LAB=02        # install the starter at its real path
make verify LAB=02     # grade it
make solution LAB=02   # diff against the reference
make reset LAB=02      # discard your edits
```

**Some lab targets already exist solved on `main`**, because the project was
worked before the lab was written. Those labs say so and tell you to branch
first.

Two workflows exist only as lab artifacts and gate nothing:
`lab-01-ci.yml` and `lab-02-ci.yml`. They still run on every push, which costs
about 79 seconds of runner time per merge. That is deliberate — see
`docs/PIPELINE.md` — but it is not something to copy into a real repository.

`publish.yml` is Lab 05's artifact and is `workflow_dispatch` only. Its steps
live in `reusable-service-ci.yml` now. Do not re-enable its triggers; every
image would publish twice.

---

## AWS

Track B onward bills real money. `docs/COST.md` is the authority, and its rule
is short:

> If a resource bills by the hour whether or not you use it, it does not
> outlive the session that created it.

- `make eks-up` starts the cluster. `make eks-down` is the **last command of
  every session** — it deletes LoadBalancer Services first, then destroys, then
  sweeps for orphans.
- Never run bare `terraform destroy` on `infra/eks`. Kubernetes-created load
  balancers hold network interfaces Terraform does not know about, and the VPC
  destroy hangs.
- `make aws-sweep` lists everything billable. Run it before you call a session
  finished.

`infra/ci-oidc` is the exception: it costs nothing and is meant to stay
applied.

---

## Commits

Branch rather than committing to `main`. `main` is protected with
`enforce_admins: false`, so a direct push succeeds and GitHub logs it as a
bypass.

That it is possible is not permission to do it.
