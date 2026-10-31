#!/usr/bin/env bash
# What is where, and which commit put it there. `make where`. Capstone C.
#
# Built from three sources, none kept by hand:
#   Git      deploy/envs/<env>: the digest declared, and the commit that set it
#   GHCR     the image's own GIT_SHA: which commit the digest was built from
#   cluster  what is running and what Argo CD says (only when reachable)
set -euo pipefail
cd "$(dirname "$0")/.."

git fetch -q origin main 2>/dev/null || true
ref=origin/main
live=0
kubectl -n argocd get applications >/dev/null 2>&1 && live=1

printf '| env | declared digest | built from | set by (on main) | running | Argo CD |\n'
printf '|---|---|---|---|---|---|\n'
for env in dev staging prod; do
  file="deploy/envs/${env}/kustomization.yaml"
  digest=$( (git show "${ref}:${file}" 2>/dev/null || true) | awk '/digest: sha256:/ {print $2}')
  [ -n "${digest}" ] || continue
  built=$(scripts/image-commit.sh "${digest}" 2>/dev/null || echo "?")
  setby=$(git log -1 --format='%h %s (%cs %cr)' "${ref}" -- "${file}")
  running="—"; argo="cluster not reachable"
  if [ "${live}" = 1 ]; then
    image=$(kubectl -n "api-${env}" get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    running="${image##*@}"; running="${running:0:19}"
    [ "${image##*@}" = "${digest}" ] && running="${running} (matches)"
    argo=$(kubectl -n argocd get application "api-${env}" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}, last sync {.status.operationState.phase}' 2>/dev/null || echo "no Application")
  fi
  # shellcheck disable=SC2016  # the backticks are Markdown, not a command
  printf '| %s | `%s` | `%s` | %s | %s | %s |\n' "${env}" "${digest:0:19}" "${built:0:7}" "${setby}" "${running}" "${argo}"
done
