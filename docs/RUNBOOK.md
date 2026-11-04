# Runbook: shipping and reverting the api

For a new team member. You do not need to read the code. Every change to what runs is a pull request; nothing is deployed with `kubectl`.

| Environment | File that decides what runs | How it changes |
|---|---|---|
| dev | `deploy/envs/dev/kustomization.yaml` | CI opens a pull request after every merge to `main` |
| staging | `deploy/envs/staging/kustomization.yaml` | `make promote FROM=dev TO=staging` |
| prod | `deploy/envs/prod/kustomization.yaml` | `make promote FROM=staging TO=prod` |

---

## Ship a change

1. Open a pull request with your change. Merge it when `ci-passed` and `terraform-passed` are green.
2. CI tests, scans and publishes the image, then opens **"Promote <commit> to dev"**. Its checks wait for approval: in Actions, open each held run and press **Approve and run**. It merges itself when they pass.
3. Within about 5 minutes Argo CD rolls dev out. Check: `make where` shows dev on your commit, `matches`, `Synced/Healthy`.
4. `make promote FROM=dev TO=staging`. Wait for `make where` to show staging on your commit.
5. `make promote FROM=staging TO=prod`. Same check.

Each promotion is a one-line pull request that merges itself once its checks pass. You never copy a digest.

---

## Revert a change

```bash
make rollback ENV=prod
```

This opens a pull request that reverts the last change to prod's file, and merges itself when its checks pass. Prod is back about 2 minutes after the merge (measured: 1m 16s).

**Do not use `kubectl rollout undo`, `kubectl edit` or `kubectl scale`.** Argo CD puts the cluster back to what Git says within seconds, so your change disappears. A field Git does not mention (an extra env var) is not put back, and nothing reports it, which is worse.

---

## When a deploy does not arrive

`make where` shows the environment `OutOfSync`, with `last sync Failed`. The release was turned away **before it took traffic**: the old version is still serving. Find out why:

```bash
kubectl -n api-prod logs job/preflight        # the line starting PREFLIGHT FAILED
```

| You see | It means |
|---|---|
| `table …: AccessDeniedException` | the table name is wrong, or it is another environment's table |
| `the app exited with code …` | the new image does not start |
| `the image carries no build identity` | the image was not built by CI |
| `the app reports environment …` | the environment's config is wrong |

Fix it with a new pull request, or `make rollback ENV=<env>` to return to the last version.

---

## Start and stop the platform

The cluster bills about $0.19/hour, so it exists only while someone is working.

```bash
make platform-up     # ~13 minutes: cluster, Argo CD, all three environments, then `make where`
make eks-down        # always last: deletes the cluster, then sweeps the account
```

Nothing has to be redeployed after `platform-up`: every environment comes back to what its file says. **The data does not come back.** The orders tables are deleted with the cluster.

---

## Know the limits

- dev, staging and prod share two nodes. A heavy test in dev slows prod.
- Each environment's pods can reach only their own table, but any pod can call another environment's api over the network.
- The pre-flight check catches a release that fails at start or on its first order. It does not catch one that fails later, under real traffic.
