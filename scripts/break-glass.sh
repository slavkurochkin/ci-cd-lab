#!/usr/bin/env bash
# Deploy a digest without CI or review, and leave an audit trail. Project 18.
#
#   scripts/break-glass.sh <env> <sha256:digest> "<reason>"            to main
#   scripts/break-glass.sh <env> <sha256:digest> "<reason>" --drill    to a drill branch
#
# For when the pipeline is down and production is not. It skips the pull
# request and its checks, nothing else:
#
#   - the digest must carry this repository's CI signature (checked here with
#     cosign, and again by Kyverno at admission: break-glass cannot run an
#     image CI did not build);
#   - the change is a Git commit, so Argo CD deploys it the usual way and a
#     revert undoes it;
#   - an issue labelled `break-glass` is filed before this script exits,
#     naming who, when, what and why. .github/workflows/break-glass-audit.yml
#     files one too, for any deploy/envs change on main that did not come
#     through a pull request, in case this script was not used.
#
# Pushing to main needs an admin: main is protected with enforce_admins off,
# and the push shows in GitHub's audit log as a bypass. That is the point.
#
# --drill pushes to break-glass-drill instead, and titles the issue DRILL:
# the whole path, exercised, without changing what runs.
set -euo pipefail
cd "$(dirname "$0")/.."

env="${1:?env: dev, staging or prod}"
digest="${2:?digest: sha256:...}"
reason="${3:?reason, in a sentence}"
drill=false
[ "${4:-}" = "--drill" ] && drill=true

file="deploy/envs/${env}/kustomization.yaml"
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
image="ghcr.io/${repo}/api@${digest}"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "not a digest: $digest" >&2; exit 2; }

echo "== 1. is ${digest:0:19}… signed by this repository's CI?"
cosign verify "$image" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github\.com/${repo//./\\.}/\.github/workflows/reusable-service-ci\.yml@refs/(heads/main|tags/v.+)$" \
  >/dev/null
echo "   yes"

echo "== 2. commit"
git fetch -q origin main
current=$(git show "origin/main:${file}" | awk '/digest: sha256:/ {print $2}')
[ "$current" != "$digest" ] || { echo "${env} already runs ${digest}"; exit 0; }
target=main
$drill && target=break-glass-drill
work=$(mktemp -d)
trap 'git worktree remove --force "$work" >/dev/null 2>&1 || true' EXIT
git worktree add -q --detach "$work" origin/main
sed -i.bak -E "s|^(    digest: )sha256:[0-9a-f]{64}$|\1${digest}|" "${work}/${file}"
rm -f "${work}/${file}.bak"
who=$(gh api user --jq .login)
title="Break-glass: ${env} to ${digest:7:12}"
$drill && title="DRILL ${title}"
git -C "$work" commit -q -m "$title" -m "$reason" \
  -m "Break-glass-by: ${who}" -m "Previous-digest: ${current}" -- "$file"
sha=$(git -C "$work" rev-parse HEAD)
force=()
$drill && force=(--force)
git -C "$work" push -q ${force[@]+"${force[@]}"} origin "HEAD:refs/heads/${target}"
echo "   pushed ${sha:0:7} to ${target}"

echo "== 3. audit issue"
gh label create break-glass --color B60205 --description "Deploy that skipped CI and review" 2>/dev/null || true
url=$(gh issue create --label break-glass --title "$title" --body "$(cat <<EOF
A deploy skipped the pull request and its checks.

| | |
|---|---|
| who | @${who} |
| when | $(date -u +%Y-%m-%dT%H:%M:%SZ) |
| environment | \`${env}\` |
| from | \`${current}\` |
| to | \`${digest}\` |
| commit | ${sha} on \`${target}\` |
| signature | verified with cosign before the push |

**Why:** ${reason}

Before closing this issue:
- [ ] the change is reviewed by someone other than ${who}
- [ ] the pipeline failure that made this necessary has its own issue
- [ ] main matches what runs (no follow-up revert pending)
EOF
)")
echo "   ${url}"
