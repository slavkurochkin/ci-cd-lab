# CLAUDE.md

Conventions for working in this repository. Read before writing lab prose or
touching anything that bills.

## What this repo is

A self-paced CI/CD curriculum. `ROADMAP.md` defines 18 projects across four
tracks; `labs/NN_name/` holds the graded ones. Every lab has the same four
parts, and only one of them is the learner's:

| Path | Role |
|---|---|
| `labs/NN_*/starter/` | pristine file with TODOs — never edit |
| `labs/NN_*/solution/` | reference answer — never edit |
| `labs/NN_*/verify/` | pytest suite that grades the work |
| the real path, e.g. `.github/workflows/lab-01-ci.yml` | **the learner's working copy** |

`make lab LAB=NN` installs the starter at its real path. `make reset LAB=NN`
restores it. `make verify LAB=NN` grades it.

## Working mode

**The learner edits the lab files. Claude reviews.** Unless asked directly to
implement something, do not write into a lab's working copy — read verifier
output, explain the failure, point at the line. Fixing it for them removes the
lab. If asked to fix it, fix it.

This does not apply to `labs/*/README.md`, scripts, `infra/`, or docs. Those
are Claude's to edit on request.

## Writing lab documentation

The concept sections in `labs/02_speed_and_cost/README.md` are the reference
implementation of this style. Match them.

**Lead with the rule.** State the thing the reader should do in the first or
second paragraph, in bold. Do not arrive at it after three paragraphs of
context. The reader needs the rule in order to understand why the failures
below it are failures.

**Put failure modes in a table.** Four columns, in this order:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Named failure** | the specific misconfiguration | the mechanism | what the reader observes in the UI or logs |

The fourth column is the one that earns the table. Most CI failures in this
curriculum are quiet — a green check that means nothing, a check that never
reports, a cache that never hits. Two failures that look identical in the UI
and differ only in cause belong side by side, because that shared invisibility
*is* the lesson.

**Name the consequence in experience, not abstraction.** Not "this is worse
than the problem you started with" but "runs dying for no visible reason,
blamed on flakiness for weeks." The reader should recognise the symptom later.

**Name the exact input.** `cache-dependency-path` for `actions/setup-node`,
`cache-dependency-glob` for `astral-sh/setup-uv` — not "point the action at the
lock file." Where two tools spell the same idea differently, say so; that
difference is itself a trap.

**Cross-reference earlier labs by failure, not by number.** "The same failure
you met in Lab 01, where the worker job could not find
`app/worker/package-lock.json`" beats "see Lab 01."

**Formatting.** Unwrapped paragraphs — do not hard-wrap at 80 columns, the
files do not. `---` between sections. One `> Further reading:` link per concept
section, pointing at official docs.

**Accuracy outranks tidiness.** Limits, quotas and API behaviour get checked
before they get written. The 10 GB cap is a cache limit, not an artifact limit;
that distinction is the kind of thing this curriculum exists to get right.

## Plain language

The prose here has a recurring failure: reaching for a clever phrase when a
plain one is shorter and clearer. Six rules, all of them cuts.

**No aphorism at the end of a paragraph.** Stop when the point is made. If a
sentence exists to sound quotable, delete it.

**One em-dash per paragraph, at most.** An em-dash aside is usually a thought
that should be its own sentence or should not be there.

**Use the literal statement unless the metaphor is shorter.** "Nobody looks at
the other two" beats "the other two finish into an empty room."

**Prefer the common word.** `use` not `utilize`. `but` not `however`.
`important` not `load-bearing`. `left over` not `vestigial`. If the word was
chosen because it sounds precise, it is the wrong word.

**Cut the intensifiers**: `genuinely`, `actually`, `precisely`, `deliberately`,
`simply`, `entirely`, `exactly` — unless removing the word changes the meaning.

**Verbs over abstract nouns.** "throws the cache away" not "cache
invalidation." "The two mistakes cost different amounts" not "getting the
direction wrong is not symmetrical."

The test is whether you would say the sentence out loud to a colleague. Keep
concrete detail that does work — "a race that passes on a fast runner and fails
on a slow one" earns its length because it describes the symptom. Cut detail
that only decorates.

## Verification

Run these before claiming anything works:

```bash
make verify LAB=NN                  # the lab's own grader
actionlint .github/workflows/*.yml  # workflow syntax
make test                           # both service suites
shellcheck scripts/*.sh             # if a script changed
terraform fmt -check && terraform validate   # in infra/eks
```

`make doctor` prints `installed` when a version probe *fails*, not when a tool
is missing. A tool showing `installed` rather than a version number means the
probe needs fixing.

## AWS

Track B and Projects 13+ bill real money. `docs/COST.md` is the authority.

**The rule: if a resource bills by the hour whether or not you use it, it does
not outlive the session that created it.**

- `make eks-up` creates the cluster (~$0.21/hr). `make eks-down` is the last
  command of every session — it deletes LoadBalancer Services first, then
  destroys, then sweeps for orphans.
- Never use bare `terraform destroy` on `infra/eks`. Kubernetes-created ELBs
  hold ENIs that Terraform does not know about and cannot delete, and the VPC
  destroy hangs.
- Never provision a NAT Gateway, RDS instance, or a second cluster. `docs/COST.md`
  lists the full set.
- Before telling the user a session is clean, run `make aws-sweep` and report
  what it actually printed.

## Commits

Do not commit or push unless asked. Branch rather than committing to `main`.

`main` is protected with `enforce_admins: false`, so a direct push succeeds and
GitHub logs it as a bypass. That it is possible is not permission to do it.
