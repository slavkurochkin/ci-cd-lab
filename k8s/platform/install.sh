#!/usr/bin/env bash
# Project 11: what the manifests assume is already in the cluster.
#
#   metrics-server            requests and limits come from measured usage
#   Vault (dev mode)          the secrets store; stands in for Doppler or AWS
#                             Secrets Manager, and costs nothing
#   External Secrets Operator syncs a Vault secret into a Kubernetes Secret
#   Reloader                  restarts a Deployment when its Secret changes
#
# Local only. Vault in dev mode keeps everything in memory, unseals itself and
# uses the root token "root". That is a lab convenience and nothing else: a
# restart loses every secret, and the token is in this file.
#
# Safe to run twice.
set -euo pipefail

ESO_CHART_VERSION="2.12.0"
VAULT_CHART_VERSION="0.34.1"
RELOADER_CHART_VERSION="2.2.18"

helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null
helm repo update >/dev/null

minikube addons enable metrics-server >/dev/null

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_CHART_VERSION" --namespace external-secrets --create-namespace --wait

helm upgrade --install reloader stakater/reloader \
  --version "$RELOADER_CHART_VERSION" --namespace reloader --create-namespace --wait

helm upgrade --install vault hashicorp/vault \
  --version "$VAULT_CHART_VERSION" --namespace vault --create-namespace \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --set injector.enabled=false \
  --wait
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s

vault() { kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault "$@"; }

# The secret itself. DynamoDB Local does not check the credentials are right,
# but since 2.0 it does check the shape: an access key ID of letters and
# digits only. The first value here was `lab-api`, and every call failed with
# UnrecognizedClientException. Rotating it is what shows the reload.
vault kv put secret/lab/api \
  AWS_ACCESS_KEY_ID=labapi \
  AWS_SECRET_ACCESS_KEY="$(head -c 18 /dev/urandom | base64)" >/dev/null

# The bootstrap problem: External Secrets needs a credential to fetch the
# credentials. Here it is the cluster's own identity. Vault verifies a
# Kubernetes ServiceAccount token with the API server and maps that one
# account to a policy that can read that one path. No token is planted
# anywhere, which is the same answer OIDC gave CI in Project 4.
vault auth enable kubernetes >/dev/null 2>&1 || true
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null
kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN=root vault policy write lab-api - >/dev/null <<'POLICY'
path "secret/data/lab/api" {
  capabilities = ["read"]
}
POLICY
# audience=vault: only a token minted for Vault is accepted. Without it, a
# ServiceAccount token issued for any other purpose would also work, and Vault
# warns about exactly that.
vault write auth/kubernetes/role/lab-api \
  bound_service_account_names=api-secrets-reader \
  bound_service_account_namespaces=lab-dev,lab-prod \
  audience=vault \
  policies=lab-api ttl=15m >/dev/null

echo "platform ready: metrics-server, Vault (dev), External Secrets $ESO_CHART_VERSION, Reloader $RELOADER_CHART_VERSION"
