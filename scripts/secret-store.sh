#!/usr/bin/env bash
# The ClusterSecretStore `ssm`, and a first admin token for each environment
# that has none. Project 17.
#
#   ./scripts/secret-store.sh        # after `make argocd-bootstrap`
#
# Not in Git because it names an IAM role ARN, which contains the account
# ID. Everything else about it is here: the store reads SSM through the
# secrets-reader role, tagging the session with the namespace of the
# ExternalSecret being served, so each namespace reads /ci-cd-lab/<itself>/*
# and nothing else (infra/eks/secrets.tf).
#
# Tokens are created here, never in Terraform: a value Terraform creates is a
# value in its state file. A parameter that already exists is left alone, so
# running this again does not rotate anything.
set -euo pipefail
cd "$(dirname "$0")/.."

region=${AWS_LAB_REGION:-us-east-1}
role=$(terraform -chdir=infra/eks output -raw secrets_reader_role_arn)

echo "waiting for the External Secrets CRDs ..."
until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do sleep 5; done

kubectl apply -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ssm
spec:
  # Only the api namespaces may use this store. Without this, an
  # ExternalSecret in any namespace could read through it.
  conditions:
    - namespaceRegexes: ["^api-(dev|staging|prod)$"]
  provider:
    aws:
      service: ParameterStore
      region: ${region}
      role: ${role}
      # Adds esoNamespace, the ExternalSecret's namespace, to the session.
      # The role's policy turns that tag into the only path it can read.
      sessionTagsPolicy: Simple
YAML

for env in dev staging prod; do
  name="/ci-cd-lab/api-${env}/admin-tokens"
  if aws ssm get-parameter --region "$region" --name "$name" >/dev/null 2>&1; then
    echo "${name}: exists, left alone"
  else
    aws ssm put-parameter --region "$region" --name "$name" --type SecureString \
      --value "$(openssl rand -hex 24)" >/dev/null
    echo "${name}: created"
  fi
done
