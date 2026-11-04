#!/usr/bin/env bash
# Prints a Deployment's replica counts every time they change. Project 12.
#
#   k8s/rollout/watch.sh lab-prod api
#
# One line per change, so a rollout reads as a sequence of steps:
#   total      pods that exist, old and new, not counting terminating ones
#   updated    pods from the new template
#   ready      pods passing readiness
#   available  ready pods that have stayed ready for minReadySeconds
#   terminating  pods already told to stop
set -euo pipefail

ns="${1:?namespace}"
deploy="${2:?deployment}"
selector="app.kubernetes.io/name=${deploy}"

start=$(date +%s)
last=""
while true; do
  status=$(kubectl -n "${ns}" get deploy "${deploy}" -o \
    jsonpath='{.status.replicas} {.status.updatedReplicas} {.status.readyReplicas} {.status.availableReplicas}')
  read -r total updated ready available <<<"${status}"
  terminating=$(kubectl -n "${ns}" get pods -l "${selector}" -o \
    jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}x{end}' | wc -c | tr -d ' ')
  line="total=${total:-0} updated=${updated:-0} ready=${ready:-0} available=${available:-0} terminating=${terminating}"
  if [[ "${line}" != "${last}" ]]; then
    printf 't=%3ss  %s\n' "$(( $(date +%s) - start ))" "${line}"
    last="${line}"
  fi
  sleep 0.5
done
