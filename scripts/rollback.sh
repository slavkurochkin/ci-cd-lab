#!/usr/bin/env bash
# Roll an environment back, in Git.   make rollback ENV=prod    Capstone C.
#
# Reverts the last commit that changed deploy/envs/<env>, as a pull request.
# Not `kubectl rollout undo`: Argo CD's self-heal puts the cluster back to
# what Git says within seconds, so an undo in the cluster is undone.
set -euo pipefail
cd "$(dirname "$0")/.."

env="${1:?env}"
file="deploy/envs/${env}/kustomization.yaml"
git fetch -q origin main
last=$(git log -1 --format=%H origin/main -- "${file}")
subject=$(git log -1 --format=%s "${last}")
echo "reverting ${last:0:7}: ${subject}"

branch="rollback/${env}-${last:0:7}"
git switch -q -c "${branch}" origin/main
git revert --no-edit "${last}" >/dev/null
# A revert must change only this environment. A commit that touched other
# files too is reverted in full only by a person who has read it.
changed=$(git diff --name-only HEAD~1 HEAD)
[ "${changed}" = "${file}" ] || { git switch -q -; git branch -q -D "${branch}"; echo "${last:0:7} changed more than ${file}: ${changed}"; exit 1; }
git push -q -u origin "${branch}"
gh pr create --base main --head "${branch}" --title "Roll back ${env}: revert \"${subject}\"" \
  --body "Reverts ${last} in \`${file}\`. Argo CD rolls ${env} back when this merges."
gh pr merge --auto --squash --delete-branch
git switch -q -
