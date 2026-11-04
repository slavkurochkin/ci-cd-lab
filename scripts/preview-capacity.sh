#!/usr/bin/env bash
# How many previews does this cluster hold? Fill it until a pod goes Pending.
# Project 18.
#
#   scripts/preview-capacity.sh [max]        default max 30
#
# Applies deploy/preview, as the ApplicationSet renders it, into namespaces
# pr-901, pr-902, ... with the image dev runs, one at a time. Each must have
# all its pods Ready within 3 minutes. The first preview with a pod that the
# scheduler cannot place ends the run, and its FailedScheduling message says
# which resource ran out. Every namespace it made is deleted at the end.
#
# Needs a running cluster (make platform-up). Run: ~1 min per preview.
set -euo pipefail
cd "$(dirname "$0")/.."
max="${1:-30}"
digest=$(awk '/digest: sha256:/ {print $2}' deploy/envs/dev/kustomization.yaml)
image="ghcr.io/slavkurochkin/ci-cd-lab/api@${digest}"
work=$(mktemp -d)
made=()
cleanup() {
  echo "== deleting ${#made[@]} namespace(s)"
  for ns in ${made[@]+"${made[@]}"}; do kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

render() { # namespace
  rm -rf "$work/r" && mkdir -p "$work/r/deploy" && cp -R deploy/preview "$work/r/deploy/" && cp -R k8s "$work/r/"
  sed -i.bak "s/^namespace: preview$/namespace: $1/" "$work/r/deploy/preview/kustomization.yaml"
  printf 'images:\n  - name: ci-cd-lab/api\n    newName: %s\n    digest: %s\n' \
    "ghcr.io/slavkurochkin/ci-cd-lab/api" "$digest" >> "$work/r/deploy/preview/kustomization.yaml"
  kubectl kustomize "$work/r/deploy/preview" | sed "s/host: preview.invalid/host: $1.preview/"
}

echo "image ${image}"
kubectl get nodes -o custom-columns='NODE:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,PODS:.status.allocatable.pods'
echo "pods running before: $(kubectl get pods -A --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')"

fitted=0
for i in $(seq 1 "$max"); do
  ns="pr-$((900 + i))"
  render "$ns" | kubectl apply --server-side -f - >/dev/null
  made+=("$ns")
  deadline=$((SECONDS + 180))
  while :; do
    pending=$(kubectl -n "$ns" get pods --field-selector=status.phase=Pending -o name 2>/dev/null | head -1)
    if [ -n "$pending" ]; then
      reason=$(kubectl -n "$ns" get events --field-selector "involvedObject.name=${pending#pod/},reason=FailedScheduling" \
        -o jsonpath='{.items[-1:].message}' 2>/dev/null || true)
      if [ -n "$reason" ]; then
        echo "${ns}: ${pending} cannot be scheduled"
        echo "  ${reason}"
        echo "== capacity: ${fitted} previews fitted; preview $i did not"
        kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
        kubectl describe nodes | grep -A8 "Allocated resources" | grep -E "cpu|memory|Allocated" || true
        exit 0
      fi
    fi
    ready=$(kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.status.readyReplicas}/{.spec.replicas} {end}')
    if [ "$ready" = "1/1 1/1 " ]; then break; fi
    if [ "$SECONDS" -gt "$deadline" ]; then
      echo "${ns}: not ready after 3 minutes ($ready)"; kubectl -n "$ns" get pods; exit 1
    fi
    sleep 5
  done
  fitted=$i
  echo "${ns}: ready (${fitted} previews)"
done
echo "== ${max} previews fitted; raise the maximum"
