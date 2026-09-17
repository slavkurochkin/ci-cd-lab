# Lab 05 — Building & Publishing Containers

> **Roadmap:** Project 5 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Produce an image you can prove came from a specific commit, built by a specific workflow, containing known dependencies.

---

## Before you start

**This lab's files already exist in solved form on `main`**, and two of them are the Dockerfiles your images are built from. Work on a branch:

```bash
git switch -c lab-05
make reset LAB=05
```

To abandon the attempt:

```bash
git checkout main -- .github/workflows/publish.yml app/api/Dockerfile app/worker/Dockerfile
```

The starter Dockerfiles are deliberately missing two fixes. You are meant to find them the way they were found the first time: by watching the scan fail.

---

## Concepts

### A tag is a promise about reproducibility

An image can be referred to three ways, and only one of them cannot lie to you.

| | Example | Can it change under you |
|---|---|---|
| Mutable tag | `latest`, `v1` | **yes** — ask twice, get different images |
| Immutable-by-convention tag | `sha-4674d37…` | only if someone force-pushes it |
| **Digest** | `sha256:76a046e0…` | **no** — it *is* the content |

`latest` is not a version. It is a pointer to whatever was pushed most recently, which means an incident review that starts "which image was running" ends in a guess.

Publish the commit SHA, publish semver for humans reading a release page, and **deploy the digest**.

> Further reading: [OCI — image specification](https://github.com/opencontainers/image-spec/blob/main/descriptor.md#digests)

---

### Layer order decides rebuild cost

A Docker layer is cached until something it depends on changes, and everything after a changed layer rebuilds. So the order of a Dockerfile is a statement about what you expect to change often.

Both Dockerfiles here copy dependency manifests and install, *then* copy source:

```dockerfile
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev   # cached until deps change
COPY src ./src                                        # changes every commit
```

Reverse those two and every commit reinstalls every dependency.

**That ordering buys nothing across CI runs without a cache backend.** A fresh runner has no layers at all, so the cache has to live somewhere the next run can reach — `type=gha` puts it in the Actions cache.

---

### A scan is a gate only if it runs before the push

This is the whole of Task C, and the order is the entire difference:

```
build → scan → push      a vulnerable image is never published
build → push → scan      a vulnerable image is published, then reported
```

Both arrangements go red on a bad image. Only one of them keeps it out of the registry.

**One flag deserves thought rather than copying.** `ignore-unfixed` excludes vulnerabilities with no available patch. Failing on those sounds stricter, and it is worse: there is no action the build can take, so people add blanket ignore files and stop reading any of it.

---

### Two ways the scan gate disappoints you

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Reports instead of gating** | no `exit-code: 1` | findings print, job stays green | a scan step with a tick beside it, and nobody reads the log |
| **Gates the publish but not the merge** | the job is not a required check | the image is blocked; the pull request is not | `UNSTABLE`, a mergeable pull request, and a vulnerable dependency landing on `main` |

The first is Lab 01's `|| true` in a better suit. The second is subtler and is Task E2.

---

### Provenance: what the image actually proves

A signed attestation ties three things together:

```
this digest  ←  built by this workflow  ←  from this commit
```

Verifiable by anyone, with no key stored anywhere — the signing certificate comes from the same OIDC flow as Lab 04's AWS role.

```bash
gh attestation verify oci://ghcr.io/OWNER/REPO/api@sha256:… --repo OWNER/REPO
```

Without it, a registry holds an image and a claim about where it came from. With it, the claim is checkable.

> Further reading: [GitHub Docs — Artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)

---

### A base image is someone else's patching cadence

`python:3.12-slim` is rebuilt on a schedule you do not control. Between rebuilds, Debian publishes security fixes the image does not have.

Pulling a fresher base helps and does not solve it. The image can be current and still be behind the archive it was built from.

This is the fix that costs something, and knowing the cost is part of understanding it: **layers are additive**. Upgrading a package writes the new version into a new layer while the old one still occupies space underneath. You pay for both copies.

---

## Setup

```bash
git switch -c lab-05
make reset LAB=05
```

Record the baseline before changing anything:

```bash
make build-images
docker images --filter 'reference=lab-*:local' --format '{{.Repository}}  {{.Size}}'
```

| | Baseline | After Task D |
|---|---|---|
| `lab-api` size | | |
| `lab-worker` size | | |
| `api` fixable HIGH/CRITICAL | | |
| `worker` fixable HIGH/CRITICAL | | |

Fill it in. Task D makes the images **bigger**, and a column showing that is more honest than a sentence claiming the fix was free.

Scan locally so the feedback loop is seconds rather than a push:

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed lab-api:local
```

---

## Tasks

### Task A — Tag, cache, push (`TODO(lab-05-a)`)

Covers: tagging strategy, cache backends, and why a pull request must not publish.

In `.github/workflows/publish.yml`: compute tags with `docker/metadata-action` (SHA and semver, **no `latest`**), give the build a cache backend, push only when the event is not a pull request, and attach an SBOM.

**What to observe:**
- Run it twice with no source change. The second build should be almost entirely cache hits.
- Then change one line in `src/` and run again. Watch which layers rebuild and which do not.

**Questions to reflect on:**
- Your deployment manifest references an image. Which of the three identifiers should it use, and what breaks if you pick a different one?

---

### Task B — Permissions and the registry login (`TODO(lab-05-b)`)

Covers: the difference between having a right and presenting a credential.

Add the permissions the job needs to push and to sign, and log in to the registry before anything pushes.

**What to observe:**
- Try it without the login step. The failure is a 403 at the push — **after** the build and the scan have already run.
- Notice that a pull request will not show you this, because pull requests skip the push. A step that only runs on `main` has its first execution on `main`.

**Questions to reflect on:**
- `packages: write` was already there and the push still failed. What is the difference between being allowed to do something and being able to prove who you are?

---

### Task C — Make the scan a gate (`TODO(lab-05-c)`)

Covers: ordering, and the one flag worth arguing about.

Scan the locally-built image and fail the job on HIGH or CRITICAL.

**What to observe:**
- Confirm the scan step sits **before** the push step. Reordering them changes nothing about whether the job goes red, and everything about whether a bad image ships.

**Questions to reflect on:**
- Set `ignore-unfixed: false` and look at what appears. Would you act on any of it? What would a team do with a gate that fails on things nobody can fix?

---

### Task D — Fix what the scan found (`TODO(lab-05-d)`)

Covers: base image currency, and runtime attack surface.

The gate will fail on both images. The causes are different and so are the fixes.

**`app/api`** — every finding is a Debian package you did not choose. Pull a fresh `python:3.12-slim` and scan again; the count drops and does not reach zero. Work out why, fix it in the Dockerfile, and **measure the size before and after**.

**`app/worker`** — the findings are `pacote`, `brace-expansion`, `ip-address`. None of these are in `package.json`. Find out what ships them, then ask whether this image needs that thing at all. The entrypoint is `node`.

**What to observe:**
- One fix costs ~50MB, the other costs ~1MB. Both take the count to zero. The difference is worth understanding before you reach for either.

**Questions to reflect on:**
- The api fix bakes today's packages into the image. What has to happen for that image to be out of date again, and would anything tell you?

---

### Task E — Prove it, and make it block (`TODO(lab-05-e1/e2)`)

Covers: attestation, and the difference between blocking a publish and blocking a merge.

1. Attest the build provenance against the pushed digest.
2. Give the image job a name nothing else uses, and add an aggregate job for branch protection to require.

**What to observe:**
- After merging, verify from outside CI:
  ```bash
  gh attestation verify oci://ghcr.io/OWNER/REPO/api@<digest> --repo OWNER/REPO
  ```
- Then run `gh pr checks` on a pull request and count how many things report as `api`. Three other workflows in this repository use that name. **Branch protection matches by name alone.**

**Questions to reflect on:**
- Introduce a dependency with a known HIGH vulnerability and open a pull request. The publish is blocked. Is the *merge*? Check `gh pr view --json mergeStateStatus` before you assume.

---

## Verify

```bash
make verify LAB=05
```

| Test | What it proves |
|---|---|
| `test_tags_are_computed`, `..._tagged_by_commit`, `..._latest_is_not_published` | Task A: tags |
| `test_layer_cache_is_configured` | Task A: the Dockerfile's layer order buys something |
| `test_push_is_skipped_on_pull_requests`, `test_sbom_is_attached` | Task A |
| `test_job_can_write_packages`, `..._can_sign`, `..._registry_login_happens`, `..._login_precedes_push` | Task B |
| `test_image_is_scanned`, `..._scan_fails_the_build`, `..._unfixable_findings_are_ignored` | Task C |
| `test_scan_precedes_push` | Task C: it is a gate, not a report |
| `test_api_image_applies_security_updates` | Task D |
| `test_worker_image_does_not_ship_a_package_manager` | Task D |
| `test_images_run_as_a_non_root_user` | both images |
| `test_provenance_is_attested`, `..._uses_the_pushed_digest` | Task E1 |
| `test_job_names_do_not_collide`, `..._there_is_an_aggregate_to_require` | Task E2 |
| `test_third_party_actions_are_pinned` | Lab 04's rule, still holding |
| `test_the_workflow_has_actually_published` | an image exists |

The last one is again the only test that cannot be satisfied by editing a file.

---

## Key lesson

An image tag is a promise about reproducibility, and a mutable tag breaks that promise silently. Digests are the only identifier that cannot lie to you.

The second lesson is about where a check sits rather than what it checks. The same scan, moved three lines later in the file, stops being a gate and becomes a report — and the same failing job, without a required status check depending on it, blocks a publish while leaving the merge wide open.
