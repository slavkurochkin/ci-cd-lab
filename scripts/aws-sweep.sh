#!/usr/bin/env bash
# List every billable resource this curriculum knows how to create, plus the
# expensive ones it never should have. Run after every `terraform destroy`.
#
# `terraform destroy` exiting 0 is not proof the account is empty: a partial
# apply can orphan resources Terraform no longer tracks, and anything created
# in the console was never tracked at all. This checks reality.
#
# From Project 13 the account holds a real EKS cluster, so this script also
# reports the metered resources -- what they are, and roughly what they cost
# per day while they exist. An empty "Metered" section is the end of a session.

set -uo pipefail

REGION="${AWS_LAB_REGION:-${AWS_REGION:-us-east-1}}"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not installed (brew install awscli)" >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials do not resolve. Run 'aws configure' or export a profile." >&2
  exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
findings=0
metered=0

echo
echo "Sweeping account $ACCOUNT in $REGION"
echo "-------------------------------------------"

# $1 = label, $2..$n = command producing one line per resource
report() {
  local label="$1"; shift
  local output
  output=$("$@" 2>/dev/null | tr -d '\r' | grep -v '^\s*$' || true)
  if [ -z "$output" ]; then
    printf '  %s✓%s %-26s none\n' "$GREEN" "$RESET" "$label"
  else
    printf '  %s!%s %-26s\n' "$RED" "$RESET" "$label"
    while IFS= read -r line; do printf '      %s\n' "$line"; done <<<"$output"
    findings=$((findings + 1))
  fi
}

# Same, but for resources that are legitimately up while you work a lab.
# $1 = label, $2 = rough cost per day, $3.. = command
meter() {
  local label="$1" cost="$2"; shift 2
  local output
  output=$("$@" 2>/dev/null | tr -d '\r' | grep -v '^\s*$' || true)
  if [ -z "$output" ]; then
    printf '  %s✓%s %-26s none\n' "$GREEN" "$RESET" "$label"
  else
    printf '  %s$%s %-26s %s~%s/day%s\n' "$YELLOW" "$RESET" "$label" "$DIM" "$cost" "$RESET"
    while IFS= read -r line; do printf '      %s\n' "$line"; done <<<"$output"
    metered=$((metered + 1))
  fi
}

echo
echo "Metered -- fine while you are working, must be zero when you stop"
meter "EKS clusters"       "2.40" aws eks list-clusters --region "$REGION" \
  --query 'clusters[]' --output text
meter "EC2 instances"      "2.00" aws ec2 describe-instances --region "$REGION" \
  --filters 'Name=instance-state-name,Values=running,pending,stopping,stopped' \
  --query 'Reservations[].Instances[].InstanceId' --output text
meter "Load balancers"     "0.55" aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text
meter "Classic ELBs"       "0.55" aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
meter "EBS volumes"        "0.03" aws ec2 describe-volumes --region "$REGION" \
  --query 'Volumes[].VolumeId' --output text
meter "Unattached EIPs"    "0.12" aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId==`null`].PublicIp' --output text

echo
echo "Should never exist"
report "NAT gateways"      aws ec2 describe-nat-gateways --region "$REGION" \
  --filter 'Name=state,Values=available,pending' --query 'NatGateways[].NatGatewayId' --output text
report "RDS instances"     aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[].DBInstanceIdentifier' --output text

echo
echo "Free tier -- expected, but should be empty after a full teardown"
report "Lambda functions"  aws lambda list-functions --region "$REGION" \
  --query 'Functions[].FunctionName' --output text
report "API Gateway APIs"  aws apigatewayv2 get-apis --region "$REGION" \
  --query 'Items[].Name' --output text
report "DynamoDB tables"   aws dynamodb list-tables --region "$REGION" \
  --query 'TableNames[]' --output text
report "ECR repositories"  aws ecr describe-repositories --region "$REGION" \
  --query 'repositories[].repositoryName' --output text
report "S3 buckets"        aws s3api list-buckets --query 'Buckets[].Name' --output text

echo
echo "Guardrails -- these SHOULD exist"
budgets=$(aws budgets describe-budgets --account-id "$ACCOUNT" \
  --query 'Budgets[].BudgetName' --output text 2>/dev/null || true)
if [ -n "$budgets" ]; then
  printf '  %s✓%s %-26s %s\n' "$GREEN" "$RESET" "Budgets" "$budgets"
else
  printf '  %s!%s %-26s none -- create one before your first apply (Project 6)\n' \
    "$RED" "$RESET" "Budgets"
  findings=$((findings + 1))
fi

echo
if [ "$findings" -eq 0 ] && [ "$metered" -eq 0 ]; then
  printf '%sAccount is clean.%s\n' "$GREEN" "$RESET"
else
  [ "$metered" -gt 0 ] && printf '%s%d metered resource group(s) still running.%s Run '\''make eks-down'\'' when you stop.\n' \
    "$YELLOW" "$metered" "$RESET"
  [ "$findings" -gt 0 ] && printf '%s%d finding(s).%s Anything listed there is billing you or missing.\n' \
    "$RED" "$findings" "$RESET"
  printf '%sS3 buckets holding Terraform state are expected to persist -- check the names.%s\n' \
    "$DIM" "$RESET"
fi
echo
