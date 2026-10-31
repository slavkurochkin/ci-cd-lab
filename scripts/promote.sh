#!/usr/bin/env bash
# Promote what one environment runs to the next, as a pull request.
#   make promote FROM=staging TO=prod        Capstone C.
#
# Copies FROM's digest into TO's file. Nobody types or pastes a digest: it is
# read from Git, and the pull request names the commit it was built from.
set -euo pipefail
cd "$(dirname "$0")/.."

from="${1:?from env}"; to="${2:?to env}"
git fetch -q origin main
digest=$(git show "origin/main:deploy/envs/${from}/kustomization.yaml" | awk '/digest: sha256:/ {print $2}')
current=$(git show "origin/main:deploy/envs/${to}/kustomization.yaml" | awk '/digest: sha256:/ {print $2}')
[ "${digest}" != "${current}" ] || { echo "${to} already runs ${digest}"; exit 0; }
commit=$(scripts/image-commit.sh "${digest}")

branch="promote/${to}-${commit:0:7}"
git switch -q -c "${branch}" origin/main
sed -i.bak -E "s|^(    digest: )sha256:[0-9a-f]{64}$|\1${digest}|" "deploy/envs/${to}/kustomization.yaml"
rm -f "deploy/envs/${to}/kustomization.yaml.bak"
git commit -q -m "Promote ${commit:0:7} to ${to}" \
  -m "Digest ${digest}, built from ${commit}. Copied from deploy/envs/${from}." \
  "deploy/envs/${to}/kustomization.yaml"
git push -q -u origin "${branch}"
gh pr create --base main --head "${branch}" --title "Promote ${commit:0:7} to ${to}" \
  --body "Changes \`deploy/envs/${to}\` to \`${digest}\`, which ${from} runs now, built from ${commit}. One line. Argo CD rolls ${to} out when this merges; the pre-flight hook turns it away if it fails there."
gh pr merge --auto --squash --delete-branch
git switch -q -
