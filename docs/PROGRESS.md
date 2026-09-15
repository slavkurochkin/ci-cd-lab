# What we built, and why it matters

A plain-language record of Labs 01–03 and the security work in Project 4.
Written to be read start to finish, not skimmed for commands.

**Repository:** https://github.com/slavkurochkin/ci-cd-lab
**Status:** Labs 01, 02 and 03 passing. Project 4 complete.
**Next:** Project 5, then Capstone A. See the Progress table in `ROADMAP.md`.
**Cost so far:** $0. The only AWS resources that exist are free ones.

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

## Project 4 — Take the keys out of the pipeline

Everything so far was about correctness. This part is about what a pipeline is
allowed to do, and what happens if someone gets into it.

We ran a security scanner called `zizmor` over the workflows. It found **47
problems**. Four kinds:

### 1. The pipeline had more power than it needed

Every job was running with whatever permissions the repository default gave it.
The default happened to be safe, but a default is a setting someone can change
later, and then nine jobs quietly gain powers nobody reviewed.

Each workflow now states what it needs, in the file itself:

```yaml
permissions:
  contents: read
```

### 2. Checking out the code left a password lying around

When a job downloads your code, the tool it uses saves an access token into a
hidden file in that folder. It stays there for the rest of the job. If any
later step packages up that folder and uploads it, the token goes with it — and
uploaded files can be downloaded by anyone who can see the run.

Nothing here pushes code back, so nothing needs that token. Eight checkout
steps now say `persist-credentials: false`.

### 3. We were trusting labels instead of code

The pipeline used tools written by other people, referred to by a label like
`v4`. A label is a pointer, and the person who owns the tool can move it
whenever they like. If their account were compromised, `v4` could be pointed at
malicious code and your next run would execute it.

All 17 references now name an **exact commit** instead of a label. A commit
cannot be changed after the fact. We also added **Dependabot**, which proposes
updates weekly — because pinning to an exact version and never updating is its
own kind of problem.

### 4. Two things we were already doing right

The scanner checks for two attacks that actually get repositories compromised:
running untrusted code from forks, and pasting text from a pull request title
straight into a shell command. Neither was present.

**Result: 47 problems down to 6, with zero of high or medium severity.** The
six remaining are style preferences, not risks.

---

## The bigger piece: no passwords at all

The normal way for a pipeline to reach a cloud account is to paste an access
key into the repository's secret storage. That key does not expire. It works
from anywhere. If it ever leaks, you find out later.

**We set it up so no key exists.**

The mechanism is called OIDC, and it works like a passport check:

1. The pipeline asks GitHub for a signed statement about itself: *"this is a
   run in the repository slavkurochkin/ci-cd-lab."*
2. It hands that statement to AWS.
3. AWS checks the signature, confirms the statement names a repository it
   trusts, and hands back credentials valid for **one hour**.

There is no key to store, no key to rotate, and no key to leak. `gh secret
list` on this repository is empty and stays empty.

`docs/OIDC.md` explains the mechanism properly, including the claims, the trust
policy, and how to debug it when it refuses.

We proved it with a workflow that asks AWS "who am I?" and checks the answer:

```
arn:aws:sts::<account-id>:assumed-role/ci-cd-lab-ci/GitHubActions
OK: short-lived session, no stored key
```

### Why it lives in its own folder

The trust setup was originally written inside the Kubernetes cluster's
configuration. That was wrong for two reasons:

- An AWS account can hold **only one** of these trust registrations. Any second
  thing needing it would fail.
- The cluster is created and destroyed every session. The trust relationship
  should last for years.

Things with different lifespans belong in different places. It now lives in
`infra/ci-oidc/`, costs **nothing**, and is meant to stay.

### The role can do nothing

The identity we created has **no permissions attached at all**. Asking "who am
I?" requires no permission, so this proves the login works while granting
access to nothing. Permissions get added later, when there is something to
manage. A credential that can do nothing is a safe thing to leave switched on.

### The bug that only a real run could find

The first attempt failed. The error said:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That message names no cause. The configuration looked correct, Terraform
validated it, and the plan read exactly as intended.

The answer was in AWS's audit log. GitHub's signed statement says:

```
repo:slavkurochkin@67211311/ci-cd-lab@1367903510:pull_request
```

Those numbers are GitHub's internal IDs for the account and the repository. Our
rule expected the older format without them, so the two never matched.

GitHub added the numbers on purpose: names can be changed, IDs cannot. If
someone renamed a repository, a rule based on names could be pointed at the
wrong thing. The rule now accepts both spellings.

**The lesson is the same one from Lab 01.** Everything that could be checked
without running it passed. Only a real attempt found the problem. Every
published example of this setup still shows the old format, including the copy
that was already sitting in this repository.

---

## Finishing Project 4

The three items left over were all closed:

**The scanner now runs in the pipeline**, on every pull request and once a
week. The weekly run matters: tools get published and labels get moved, so a
clean scan today says nothing about next month.

**It also enforces the exact-version rule.** The scanner treats a label where a
commit should be as an error, so there was no need for a separate check. This
was verified by putting a label back and watching the job fail.

**A deployment gate exists.** A job can now declare that it targets
`production`, and it will not start until a person approves it. We ran one and
watched it sit waiting.

That gate turned out to be more than a button. When a job runs under it, the
statement GitHub signs about that job changes:

```
repo:OWNER@<id>/NAME@<id>:environment:production
```

An AWS identity can require exactly that. Which means the credential cannot be
obtained by opening a pull request, or by pushing to a branch — **only by a job
a human approved.** That is the piece Project 6 needs, and it now exists.

One more thing worth recording: the update tool's first proposal bundled
**fifteen major version jumps across five tools** into one pull request. The
tests passed, but had they failed, the cause could have been any of the five.
The configuration was changed so that routine updates stay bundled and major
ones arrive separately. The very next batch also demonstrated the new one-week
waiting period, holding back a release published two days earlier.

---

## What you have now

| | |
|---|---|
| **Pull requests are checked automatically** | api and worker, three Python versions, two Node versions |
| **Broken code cannot be merged** | proven by actually breaking a test and watching it block |
| **Only what changed gets built** | proven by a pull request where one job skipped and the merge stayed open |
| **The build is written once** | adding a service means a Makefile, not a pipeline edit |
| **Tests run against a real database** | catching a class of bug a fake would hide |
| **The pipeline holds no passwords** | AWS access with nothing stored, proven by a real run |
| **Tools are pinned to exact versions** | a supplier cannot change what runs under you |
| **A human can gate a deployment** | proven by a job that waited for approval |
| **The pipeline checks itself** | a workflow scanner runs on every change and weekly |
| **Nothing costs money yet** | the only AWS resources that exist are free |

Fifteen merged pull requests, twenty-five commits on `main`, three saved
checkpoints you can return to (`lab-01-solved`, `lab-02-solved`,
`lab-03-solved`).

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

**4. The credential you never created cannot leak.** Most pipelines hold a
permanent key because that is the obvious way to do it. Swapping it for a
one-hour credential issued on demand removes the whole category of "someone
found our key" — not by being careful with it, but by not having one.

**5. Passing every check you can run offline proves nothing about the parts
you cannot.** The trust rule was valid, correct-looking, matched every
published example, and was rejected the first time a real request arrived. The
same thing happened in Lab 01 with a workflow that parsed perfectly and had
never run.

---

## What comes next

**Project 5 — Building & Publishing Containers**, then **Capstone A**.

Projects 1 to 5 are one group, and the capstone assembles them into the single
pipeline every later track builds on. It is tempting to jump straight to
Terraform; that skips the part that produces the images everything later
deploys.

After that, Track B, Projects 6–9: infrastructure as code with Terraform, and
the first point where AWS starts billing.

Two rules from `docs/COST.md` that begin to matter there:

- If something bills by the hour whether you use it or not, it does not survive
  the session that created it.
- `make eks-down` is the last command of every session, and `make aws-sweep`
  shows what is still running.

Nothing bills today. The cluster from Project 13 costs about $0.21/hour while
it exists and $0 when it does not, which is roughly $1 for a four-hour session.
