#!/usr/bin/env bash
# The platform's admission policies, run before the cluster runs them.
# Project 17.
#
#   ./scripts/policy-check.sh
#
# 1. Every environment in deploy/envs, rendered, must pass every policy in
#    deploy/platform, signature included. A pull request that promotes an
#    unsigned digest fails here instead of half-way through an Argo CD sync.
# 2. Every object in deploy/platform/tests/refused.yaml must be refused.
#    A policy edit that stops refusing one of them fails here.
#
# Needs the kyverno CLI, python3 with PyYAML, and network access to GHCR and Rekor.
set -euo pipefail
cd "$(dirname "$0")/.."

policies=(deploy/platform/require-signed-images.yaml deploy/platform/pinned-own-images.yaml deploy/platform/non-root.yaml)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for env in dev staging prod; do
  # Workloads only. The CLI refuses a file holding a kind it has no schema
  # for, such as ExternalSecret, and the policies only look at pods.
  kubectl kustomize "deploy/envs/${env}" \
    | python3 -c 'import sys, yaml; yaml.safe_dump_all([d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] in ("Deployment", "Job", "Pod")], sys.stdout)' \
    > "${work}/${env}.yaml"
  echo "== ${env}: must pass"
  kyverno apply "${policies[@]}" --resource "${work}/${env}.yaml"
done

echo "== refused.yaml: every object must be refused"
# One object at a time. The CLI reports a failed check per object, but an
# error (a digest with nothing to verify, say) only as a count; at admission
# an error refuses the pod too, because the webhook fails closed.
python3 - deploy/platform/tests/refused.yaml "$work" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for i, d in enumerate(docs):
    with open(f"{sys.argv[2]}/refused-{i:02d}-{d['kind']}-{d['metadata']['name']}.yaml", "w") as f:
        yaml.safe_dump(d, f)
PY
admitted=0
for f in "$work"/refused-*.yaml; do
  name=$(basename "$f" .yaml | cut -d- -f3-)
  summary=$(kyverno apply "${policies[@]}" --resource "$f" 2>&1 | grep '^pass:' || true)
  if [[ "$summary" =~ fail:\ [1-9] || "$summary" =~ error:\ [1-9] ]]; then
    echo "  refused   ${name}   (${summary})"
  else
    echo "  ADMITTED  ${name}   (${summary})"
    admitted=$((admitted + 1))
  fi
done
if [ "$admitted" -ne 0 ]; then
  echo "FAIL: ${admitted} object(s) in refused.yaml were admitted" >&2
  exit 1
fi
