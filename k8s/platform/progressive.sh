#!/usr/bin/env bash
# Argo Rollouts, for Project 15. Pinned, like everything else the platform
# installs. Idempotent: run it again to repair.
set -euo pipefail

VERSION=v1.10.1
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argo-rollouts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/${VERSION}/install.yaml"
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
echo "Argo Rollouts ${VERSION} ready"
