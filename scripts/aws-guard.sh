#!/usr/bin/env bash
# Refuse to run an AWS-touching command unless the blast radius is bounded.
# Wrap any apply:  ./scripts/aws-guard.sh terraform apply
#
# Checks, in order: credentials resolve; the account is the one you nominated
# as your lab account; the region is the single pinned region; a budget exists;
# and month-to-date spend is still under that budget.
#
# From Project 13 this account runs a real EKS cluster, so the budget check is
# no longer ceremony -- it is the thing standing between a forgotten cluster
# and a three-figure surprise.

set -euo pipefail

RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; RESET=$'\033[0m'

fail() { printf '%sblocked:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || fail "aws CLI not installed (brew install awscli)"

aws sts get-caller-identity >/dev/null 2>&1 \
  || fail "AWS credentials do not resolve"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_LAB_REGION:-${AWS_REGION:-}}"

[ -n "$REGION" ] || fail "AWS_LAB_REGION is not set. Pin one region so there is one place to sweep."

if [ -n "${AWS_LAB_ACCOUNT_ID:-}" ] && [ "$ACCOUNT" != "$AWS_LAB_ACCOUNT_ID" ]; then
  fail "credentials resolve to account $ACCOUNT, but AWS_LAB_ACCOUNT_ID is $AWS_LAB_ACCOUNT_ID"
fi

if [ -z "${AWS_LAB_ACCOUNT_ID:-}" ]; then
  printf '%swarning:%s AWS_LAB_ACCOUNT_ID is unset -- nothing verifies this is your lab account (%s)\n' \
    "$YELLOW" "$RESET" "$ACCOUNT" >&2
fi

BUDGETS=$(aws budgets describe-budgets --account-id "$ACCOUNT" \
  --query 'length(Budgets)' --output text 2>/dev/null || echo 0)
[ "$BUDGETS" != "0" ] || fail "no AWS Budget on account $ACCOUNT -- create one first (Project 6, docs/COST.md)"

# Month-to-date spend against the lab budget. Pick it by name rather than by
# position: an account often also carries AWS's default $1 zero-spend budget,
# and measuring against that one would block every apply the moment a cluster
# runs for five hours. Override the name with AWS_LAB_BUDGET_NAME.
BUDGET_NAME="${AWS_LAB_BUDGET_NAME:-ci-cd-lab-monthly}"
read -r LIMIT SPEND <<<"$(aws budgets describe-budgets --account-id "$ACCOUNT" \
  --query "Budgets[?BudgetName=='$BUDGET_NAME'].[BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount] | [0]" \
  --output text 2>/dev/null || echo "0 0")"

# No budget by that name: fall back to the largest limit on the account, so a
# renamed or hand-made budget still gates the apply instead of silently not.
if [ -z "${LIMIT:-}" ] || [ "${LIMIT:-None}" = "None" ]; then
  read -r LIMIT SPEND <<<"$(aws budgets describe-budgets --account-id "$ACCOUNT" \
    --query 'reverse(sort_by(Budgets,&to_number(BudgetLimit.Amount)))[0].[BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' \
    --output text 2>/dev/null || echo "0 0")"
  printf '%swarning:%s no budget named %s -- measuring against the largest one instead\n' \
    "$YELLOW" "$RESET" "$BUDGET_NAME" >&2
fi

if [ "${LIMIT:-0}" != "0" ] && [ "${LIMIT:-None}" != "None" ]; then
  OVER=$(awk -v s="${SPEND:-0}" -v l="$LIMIT" 'BEGIN{print (s+0 >= l+0) ? 1 : 0}')
  [ "$OVER" = "0" ] || fail "month-to-date spend \$$SPEND has reached the \$$LIMIT budget -- run 'make eks-down' and check 'make eks-cost'"
  printf '%sguard ok:%s account %s, region %s, $%s of $%s budget used this month\n' \
    "$GREEN" "$RESET" "$ACCOUNT" "$REGION" "${SPEND:-0}" "$LIMIT"
else
  printf '%sguard ok:%s account %s, region %s, %s budget(s)\n' "$GREEN" "$RESET" "$ACCOUNT" "$REGION" "$BUDGETS"
fi

# A cluster you forgot is the expensive failure mode, so say so before an apply.
RUNNING=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null | tr '\t' ' ' || true)
if [ -n "${RUNNING// /}" ]; then
  printf '%snote:%s EKS already running in %s: %s (~$4.50/day)\n' \
    "$YELLOW" "$RESET" "$REGION" "$RUNNING" >&2
fi

[ "$#" -gt 0 ] || exit 0
exec "$@"
