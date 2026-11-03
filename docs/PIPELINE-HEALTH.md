# Pipeline health: flaky tests, sharding and time-to-feedback

Measure the pipeline the way you measure the service. Project 18, part 1: a flake detector checked against tests that are flaky on purpose, quarantine and retries compared on the same suite, sharding measured on a laptop and across runners, and a report of runner minutes and time-to-feedback from this repository's own Actions history, which found the slowest job and halved its slowest step.

| Path | What |
|---|---|
| [`scripts/flaky.py`](../scripts/flaky.py) | runs a suite N times in shuffled order and reports tests with both outcomes |
| [`scripts/flaky_fixture/`](../scripts/flaky_fixture) | three tests flaky on purpose (order, randomness, timing), their quarantine and its `conftest.py` |
| [`scripts/shard_fixture/`](../scripts/shard_fixture) | 48 tests of 0.25s, for measuring sharding |
| [`scripts/pipeline_report.py`](../scripts/pipeline_report.py) | runner minutes by workflow, p50/p95 time-to-feedback, slowest jobs; definitions in its docstring |
| [`.github/workflows/pipeline-health.yml`](../.github/workflows/pipeline-health.yml) | weekly flake check, and the cross-runner sharding measurement |

```bash
python3 scripts/flaky.py --runs 20 --cwd app/api -- \
  uv run --extra dev --with pytest-randomly pytest -q --no-cov --junitxml={junit}
python3 scripts/pipeline_report.py --days 30
```

Run November 3, 2026, on a 16-core Mac and on GitHub's `ubuntu-latest` runners.

---

## Evaluation (part 1)

| Roadmap check | Result |
|---|---|
| Known flaky tests are identified automatically, not by reputation | The detector finds the three planted flaky tests and none of the 14 stable ones, locally and in CI, where a weekly job checks that it still does. The api suite (44 tests) and the worker suite (18) had **0** flaky tests in 20 shuffled runs each. |
| p95 time-to-feedback is a number you can quote and have reduced | **p50 1.2 min, p95 2.5 min** over 70 pull-request commits in 30 days. The slowest pull-request job, Terraform `static` (p95 1.6 min), went from 95–97s to **68–73s** over three runs each, by validating its six directories in parallel. The repository-wide p95 is measured again once enough new pull requests have run. |

Preview environments, cost reports and break-glass are parts 2 and 3.

---

## Flaky tests: find them by running, not by remembering

**Run the suite many times in shuffled order, and call a test flaky only when the same code gave it both outcomes.** One red build says a test failed, not that it is flaky. `scripts/flaky.py` runs the command N times with a fresh JUnit file each time, and reports every test that both passed and failed, with its failure rate. A test that failed in every run is reported apart: it is broken, not flaky.

The fixture has one flaky test per common cause:

```
30 runs of 17 tests in 6s; 25 of 30 runs were red

flaky: 3
   21/30    70%  test_reads_cache_left_by_another_test     order: needs another test to run first
   10/30    33%  test_finishes_within_deadline              timing: a 10ms deadline on 4-12ms of work
    4/30    13%  test_random_sample_is_unique               randomness: no fixed seed
```

Three flaky tests made 25 of 30 builds red. The team's experience of that is "CI is broken", not "three tests are flaky".

The first version of the fixture missed the random test: it failed about 1 run in 37, not the 1 in 5 its comment claimed, and 30 runs did not catch it. A flake with failure rate p shows up in n runs with probability 1 − (1 − p)ⁿ; at p = 2.7% that is 56% for 30 runs. Rare flakes need many runs, or the record of every CI run.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Order dependence** | a test reads state another test left behind | it passes in file order and fails when shuffled or run alone | a test that fails only when the suite is split or reordered, never when run by itself to debug |
| **Unseeded randomness** | `random` with no fixed seed | some inputs fail | a failure no one can reproduce, because the next run picks other values |
| **Timing** | a deadline close to the work's duration | a slower or busier machine misses it | green on a laptop, red on a shared runner |

> Further reading: [pytest-randomly](https://github.com/pytest-dev/pytest-randomly)

---

## Quarantine, retries, or neither

**Quarantine known flaky tests so they cannot block a merge but still run; do not hide them with retries.** `scripts/flaky_fixture/conftest.py` reads `quarantine.txt` (written by `flaky.py --quarantine`) and marks each listed test `xfail(strict=False)`: it runs, a failure shows as `x`, and the build stays green.

Measured on the fixture, 40 runs each, retries with `pytest-rerunfailures`:

| | red builds | failures in the final result | reruns |
|---|---|---|---|
| neither | 29/40 | order 14, timing 15, random 9 | 0 |
| `--reruns 2` | 24/40 | order 21, timing 5, random **0** | 79 |
| quarantine | **0/40** | (all three still run and are reported) | 0 |

Retries fixed the test that fails by chance, partly fixed the timing one, and did nothing for the order-dependent one: a rerun happens in the same process, with the same missing state. They also hid 79 failures in 40 builds, each of which cost a rerun's time. In this repository's last 30 days, re-run attempts spent 13 of 787 runner minutes.

Two traps found while building this:

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Quarantine hides tests from the detector** | the quarantine applies during detection runs too | quarantined tests report as skipped | the CI check found **0** flaky tests in a suite with three, so a fixed test would never leave quarantine either. `flaky.py` now sets `FLAKY_DETECT=1` and the quarantine switches itself off |
| **Retries that repeat the failure** | `pytest-randomly` reseeds `random` before every test, reruns included | a rerun gets the same "random" values | retries rescued nothing, until `--randomly-dont-reset-seed` |

> Further reading: [pytest-rerunfailures](https://github.com/pytest-dev/pytest-rerunfailures)

---

## Sharding: what a worker costs

**Measure the overhead of a shard before adding one.** Parallel test runs save time only when the work being split is larger than the cost of each new worker.

On the laptop, with `pytest-xdist` (median of three):

| workers | api suite (44 tests) | slow fixture (48 × 0.25s) |
|---|---|---|
| none | **0.7s** | 12.4s |
| 2 | 0.9s | 6.5s |
| 4 | 1.0s | 3.5s |
| 8 | 1.2s | 2.1s |
| 16 | 1.6s | **1.7s** |

Across runners, the slow fixture split by `pipeline-health-shard.yml` (two runs):

| shards | test step, slowest shard | wall clock, first job start to last finish | runner minutes |
|---|---|---|---|
| 1 | 13–14s | 21–24s | 0.3–0.4 |
| 2 | 8–11s | 19–28s | 0.6–0.9 |
| 4 | 5–6s | 27–28s | 1.4–1.6 |
| 8 | 4–5s | 24–37s | 2.0–2.9 |

The test step shrank as expected, and the wall clock did not: each runner spends about 15 seconds starting, checking out and installing before it runs a test. Eight shards cost up to seven times the runner minutes for no faster answer. A real suite would need several minutes of test time per shard before splitting it across runners paid off; the api suite, under a second, is slower with any parallelism at all.

> Further reading: [pytest-xdist](https://pytest-xdist.readthedocs.io/)

---

## Where CI time goes

**Decide what time-to-feedback means, then let the slowest job tell you what to cut.** From `scripts/pipeline_report.py --days 30` (definitions in its docstring):

```
777 workflow runs since 2026-10-04

| workflow           | runs | runner minutes | share | in re-runs |
| Lab 03 CI          | 145  | 322            | 41%   | 5          |
| Terraform          | 136  | 216            | 28%   | 1          |
| Lab 02 CI          | 139  | 86             | 11%   | 1          |
| Lab 01 CI          | 139  | 70             | 9%    | 4          |
| Dependabot updates | 13   | 37             | 5%    | 0          |
| (8 more)           | 205  | 56             | 7%    | 2          |
| total              | 777  | 787            |       | 13         |

time-to-feedback over 70 pull-request commits:
  p50 1.2 min   p95 2.5 min   max 4.3 min
  queue wait per commit: p50 0.1 min   p95 0.2 min

slowest pull-request jobs (p95):
  1.6 min  Terraform / static
  1.4 min  Lab 03 CI / worker / worker image
```

Queue time is near zero: on a public repository's hosted runners, jobs start within seconds. The time is in the jobs. A public repository's standard runners are free, so these minutes cost nothing here; on a private repository they are the bill, and the share column is where to look first.

`static` spent 47 of its ~95 seconds in `terraform validate` across six directories, one after another. The first fix was a shared provider cache (`TF_PLUGIN_CACHE_DIR`). On the laptop it cut six `init`s from 88s to 36s; on a runner it changed nothing (47s), because a runner downloads the provider quickly and the time goes into starting the AWS provider and loading its schema, about 8 seconds per directory on one CPU of four. Validating the directories four at a time:

| | `terraform validate` | `static` job |
|---|---|---|
| in series (3 runs) | 47–48s | 95–97s |
| four in parallel (3 runs) | 19–22s | 68–73s |

A broken module checked locally still failed the step, with its error shown for every directory that uses it.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **A laptop measurement** | an optimisation timed on a fast disk and a slow network | the runner's bottleneck is different | a change that halved local time and left CI exactly as it was |
| **Retries counted as success** | a re-run attempt turns the run green | the time and the flake disappear from the record | green history, and minutes nobody accounts for |
| **Mean instead of p95** | the average of fast and slow runs | the slow tail is what people wait on | a "1 minute pipeline" that takes 4 when it matters |

> Further reading: [GitHub: workflow run usage](https://docs.github.com/en/rest/actions/workflow-runs)

---

## What went wrong while building this

- **The CI flake check found nothing at first**, because the committed quarantine also applied to the detector. Fixed with `FLAKY_DETECT=1`.
- **The shard jobs failed in 2 seconds**: the repository's root `pyproject.toml` pytest settings applied to the fixture and changed `--collect-only -q` into a per-file count. The jobs pass `-c /dev/null --rootdir .`.
- **The api flake check failed on a runner** with pytest exit code 4: its test tools are the `dev` extra, installed on the laptop and not on a fresh runner. The detector now prints pytest's output when a run leaves no JUnit file.
- **Dependabot runs each have a unique name**, which filled the report with one row per run. The report groups them by workflow path.
- **The first queue measurement counted `needs` chains as queueing** and reported a p50 of 1.1 minutes; the correct figure is 0.1.
- **The modules are validated against a different AWS provider than the one they run with.** The environments' lock files pin `hashicorp/aws` 5.100.0. The modules commit no lock file, so CI resolves the newest, 6.71.0. A module change that breaks on 5.x but validates on 6.x passes this check. Not fixed here; the fix is a version constraint in each module.
