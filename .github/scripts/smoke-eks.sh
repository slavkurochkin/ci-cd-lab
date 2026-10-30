#!/usr/bin/env bash
# Smoke test for the api on EKS, through its load balancer. Project 13.
#
# Asserts what a user would notice, not what Kubernetes reports:
#   - the service answers from outside the cluster
#   - every answer comes from the commit this run deployed (EXPECTED_SHA)
#   - an order can be written and read back, which needs Pod Identity
#     credentials and the real table
# "The pod is Running" is not on the list: a pod serving the wrong build, or
# one with no AWS credentials, is Running too.
set -euo pipefail

: "${EXPECTED_SHA:?}"
NAMESPACE="${NAMESPACE:-lab}"

fail() { echo "::error::smoke: $*"; exit 1; }

# A new load balancer gets a hostname within a minute or so, and starts
# passing traffic once its health checks see the nodes, which takes longer.
host=""
for _ in $(seq 1 60); do
  host=$(kubectl -n "${NAMESPACE}" get service api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "${host}" ] && break
  sleep 5
done
[ -n "${host}" ] || fail "service api has no load balancer hostname after 5 minutes"
url="http://${host}"
echo "load balancer: ${url}"

for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "${url}/healthz" >/dev/null 2>&1; then
    echo "reachable after ${i} attempt(s)"
    break
  fi
  [ "${i}" -eq 60 ] && fail "${url}/healthz did not answer within 5 minutes"
  sleep 5
done

# Twenty requests, so both replicas answer. Every one must be the new build.
for _ in $(seq 1 20); do
  got=$(curl -fsS --max-time 5 "${url}/version" | jq -r .git_sha)
  [ "${got}" = "${EXPECTED_SHA}" ] || fail "/version reports git_sha=${got}, expected ${EXPECTED_SHA}"
done
echo "/version: 20 of 20 answers from ${EXPECTED_SHA}"

order='{"items":[{"sku":"smoke","quantity":2,"unit_price":10.0}]}'
created=$(curl -sS --max-time 10 -w '\n%{http_code}' -H 'content-type: application/json' -d "${order}" "${url}/orders")
code=$(tail -n1 <<<"${created}")
body=$(sed '$d' <<<"${created}")
[ "${code}" = "201" ] || fail "POST /orders returned ${code}: ${body}"
id=$(jq -r .order_id <<<"${body}")
total=$(jq -r .total <<<"${body}")

read_back=$(curl -fsS --max-time 10 "${url}/orders/${id}") || fail "GET /orders/${id} failed"
[ "$(jq -r .total <<<"${read_back}")" = "${total}" ] || fail "order ${id} read back as ${read_back}"
echo "/orders: wrote ${id} (total ${total}) and read it back"
