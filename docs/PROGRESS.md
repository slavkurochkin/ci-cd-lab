# What we built, and why it matters

A plain-language record of Labs 01–03. Written to be read start to finish, not
skimmed for commands.

**Repository:** https://github.com/slavkurochkin/ci-cd-lab
**Status:** Track A complete. Labs 01, 02 and 03 all passing.
**Cost so far:** $0. Nothing has ever run in AWS.

---

## The idea behind all of it

You have two small services in one repository: `app/api` (Python) and
`app/worker` (TypeScript). The goal of the whole curriculum is to build a
pipeline that checks every change to them automatically, before the change
reaches the main branch.

The word for this is **CI**, continuous integration. It does not mean "run
tests." It means: *every change is checked the same way, on a machine that is
not yours, before it becomes official.* The two halves that matter are "the
same way" and "not yours." Your laptop has your settings, your installed
tools, and files you forgot you created. A fresh machine has none of that.

---

## Lab 01 — Make the pipeline real

**What existed before:** a workflow file that only ran when you clicked a
button. Nobody clicks the button. It protected nothing.

**What we did:**

| Change | Why |
|---|---|
| Run on every pull request and every push to `main` | A check that runs sometimes is a suggestion, not a rule |
| Removed `\|\| true` from the test step | That text makes a command always report success, even when tests fail |
| Added formatting and lint checks | Catching an unused import in 5 seconds beats catching it in 5 minutes |
| Added a second job for the worker service | Only one of two services was being checked |
| Added `timeout-minutes` | A stuck job can otherwise run for six hours |
| Turned on branch protection | This is the part that makes GitHub refuse the merge |

### The thing worth remembering

We deliberately broke a test, pushed it, and watched what happened.

**Before branch protection:** the pull request went green. A failing test,
reported as success, with a merge button ready to go.

**After branch protection:** the same failing test produced `BLOCKED`. Same
code, same workflow, different outcome — because a *result* had been turned
into a *requirement*.

That is the entire distinction. A workflow reports. Branch protection decides.
Most people who say "we have CI" only have the first one.

### The benefit

Nobody has to remember to run the tests. Nobody can merge a broken change by
accident. The check is not a habit or a team agreement; it is enforced by the
system, on every change, whether anyone is paying attention or not.

---

## Lab 02 — Make it cheaper and smarter

Lab 01's pipeline was correct and wasteful. Every change rebuilt everything.

**What we did:**

**Cancel runs nobody will read.** Push three commits in a minute and you get
three runs, but you only look at the last one. A `concurrency` block cancels
the older ones automatically — except on `main`, where every run is kept,
because that run is the permanent record that a released commit passed.

**Cache dependencies.** Downloading the same libraries on every run is wasted
time. The cache saves them and restores them next time.

**Test three Python versions instead of one.** If the code breaks on Python
3.11 but works on 3.13, you now find out from the pipeline rather than from a
user.

**Only build what changed.** A change to `app/api` no longer rebuilds
`app/worker`. A small job works out which service was touched, and the other
one is skipped.

**Keep the coverage reports.** They are uploaded as files you can download,
and they survive the machine being destroyed.

### The trap this lab exists to teach

Skipping a job creates a problem. A skipped job reports **nothing** — not
success, not failure. And a required check that reports nothing blocks the
pull request **forever**. No error to fix. No way forward except turning
protection off.

The fix is one extra job, `ci-passed`, which looks at the others and decides:

- a service that **passed** is fine
- a service that was **skipped** is also fine
- a service that **failed** is not

That single job becomes the required check instead of the individual ones. We
proved it works: a pull request that touched only `app/api` had `worker` sit
grey and skipped, and the merge button stayed unlocked.

### The benefit, measured honestly

We measured before and after rather than guessing:

| | Before (Lab 01) | After (Lab 02) |
|---|---|---|
| Jobs for a change to one service | 2 of 2, always | 5 of 6 |
| Machine-seconds for that change | ~22s | 50s |
| Machine-seconds when everything runs | ~22s | 64s |

**The pipeline got more expensive, and that is the right answer.** Before, it
tested one Python version. Now it tests three, plus runs a real database test.
You are paying for information you did not previously have.

The number that shows this lab's actual work is the first row: **6 jobs became
5** on a single-service change. With two services that is a small saving. With
six services you would skip five of them, and the saving grows every time
someone adds a service.

One honest finding: **caching did not make anything faster here.** The
dependency folders are small enough that downloading a saved copy costs about
as much as installing fresh. That is worth knowing rather than assuming. The
lesson of that task turned out to be *measure*, not *add a cache*.

---

## Lab 03 — Stop repeating yourself

By the end of Lab 02, the two services had nearly identical instructions
written out twice. Adding a third service would mean copying it a third time.

**The obvious fix is the wrong one.** You could write clever pipeline code with
conditions like "if this is the Python service, do X." That does not remove the
duplication; it hides it, and every new service adds another branch.

**What we did instead:** made the two services *look the same from the
outside*. Both now answer to the same four commands:

```
make install    make lint    make test    make test-integration
```

The pipeline calls those four commands and never needs to know which service it
is talking to. One service runs Python underneath, the other runs Node. The
pipeline cannot tell and does not care.

Then we wrote the instructions **once**, in a file any workflow can call, and
each service became four lines of configuration:

```yaml
api:
  uses: ./.github/workflows/reusable-service-ci.yml
  with:
    service: api
    versions: '["3.11", "3.12", "3.13"]'
    run-integration-tests: true
```

### The benefit

**Adding a fourth service now means writing a Makefile with four targets. The
pipeline does not change at all.**

That is the real result. And fixing a bug in the build process fixes it for
every service at once, rather than in three places where you will miss one.

### The real-database test

We also added a test that runs against an actual DynamoDB, not a fake one.

This matters because of a specific bug. The database refuses to store
Python `float` values — they must be converted first. A fake database accepts
floats happily and the test passes. Then it breaks in production.

The database runs as a throwaway container next to the job. It starts empty,
gets destroyed when the job ends, and needs no AWS account. **It has never
cost anything.**

One detail that would have caused an occasional mysterious failure: the
container takes a second or two to start, and if the tests begin too early they
fail. The usual fix is a health check, but this particular image has no tools
inside it to run one. So the wait had to be written as a step in the job
instead. Intermittent failures are the hardest kind to diagnose, and this is
the sort of small detail that causes them.

---

## What you have now

| | |
|---|---|
| **Pull requests are checked automatically** | api and worker, three Python versions, two Node versions |
| **Broken code cannot be merged** | proven by actually breaking a test and watching it block |
| **Only what changed gets built** | proven by a pull request where one job skipped and the merge stayed open |
| **The build is written once** | adding a service means a Makefile, not a pipeline edit |
| **Tests run against a real database** | catching a class of bug a fake would hide |
| **Nothing costs money yet** | 0 AWS resources, $0 spent |

Five pull requests, sixteen commits, three saved checkpoints you can return to
(`lab-01-solved`, `lab-02-solved`, `lab-03-solved`).

---

## Three ideas worth carrying to real work

**1. A green check is only as good as what would make it red.** For every step
in a pipeline, ask what would have to happen for it to fail. `|| true`,
`continue-on-error`, and a test suite that finds no tests all produce the same
confident green tick and mean nothing. If you cannot answer the question, the
step is not checking anything.

**2. Reporting and enforcing are different things.** A workflow that runs and a
workflow that blocks a merge are separated by one repository setting. Teams say
"we have CI" when they only have the first. Worth checking which one you have.

**3. Make things uniform before making the tooling clever.** Most pipeline
complexity is compensation for services that behave differently from each
other. Give them the same four commands and the clever pipeline code becomes
unnecessary.

---

## What comes next

Track B, Projects 6–9: infrastructure as code with Terraform, and the first
point where AWS starts billing.

Two rules from `docs/COST.md` that begin to matter there:

- If something bills by the hour whether you use it or not, it does not survive
  the session that created it.
- `make eks-down` is the last command of every session, and `make aws-sweep`
  shows what is still running.

Nothing bills today. The cluster from Project 13 costs about $0.21/hour while
it exists and $0 when it does not, which is roughly $1 for a four-hour session.
