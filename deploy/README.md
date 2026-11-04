# deploy

What the cluster runs, as Argo CD reads it from `main`. Project 14; the write-up is [`docs/GITOPS.md`](../docs/GITOPS.md).

| Path | What |
|---|---|
| `bootstrap/root.yaml` | the one Application applied by hand (`make argocd-bootstrap`) |
| `apps/` | one Application per file: `argocd`, `api-dev`, `api-staging` |
| `argocd/` | Argo CD v3.5.6, pinned |
| `envs/dev`, `envs/staging` | the digest, replicas and `ENVIRONMENT` each environment runs |

To change what runs in an environment, change its file in a pull request. CI opens dev's for every commit on `main` (`.github/workflows/promote-dev.yml`); staging is promoted by copying dev's digest.
