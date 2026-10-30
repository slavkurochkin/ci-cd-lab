#!/usr/bin/env bash
# Tear down everything Track C creates, in the order AWS actually requires.
#
# This does NOT trust Terraform. `terraform destroy` is step 2 of 4 here,
# because the two things that strand an EKS teardown are both invisible to it:
#
#   1. A Service of type LoadBalancer creates an ELB that Terraform never saw.
#      The ELB holds ENIs in your subnets, so the VPC refuses to delete and
#      `terraform destroy` hangs for 20 minutes and then fails. Deleting the
#      Kubernetes Service first is what releases them.
#   2. A PersistentVolume with reclaimPolicy Retain leaves its EBS volume
#      behind, billing quietly at $0.08/GB/month forever.
#
# Run it at the end of every session. It is safe to run twice.

set -uo pipefail

REGION="${AWS_LAB_REGION:-${AWS_REGION:-}}"
RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf '%sblocked:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$GREEN" "$RESET" "$1"; }

# Load balancers, classic and v2, tagged as belonging to an EKS cluster.
# Printed as "<kind> <id>". Kubernetes' cloud provider tags every load
# balancer it creates with kubernetes.io/cluster/<name>.
cluster_lbs() {
  local arn name
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null); do
    aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query "TagDescriptions[0].Tags[?starts_with(Key, 'kubernetes.io/cluster/')].Key" \
      --output text 2>/dev/null | grep -q . && echo "v2 $arn"
  done
  for name in $(aws elb describe-load-balancers --region "$REGION" \
      --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null); do
    aws elb describe-tags --region "$REGION" --load-balancer-names "$name" \
      --query "TagDescriptions[0].Tags[?starts_with(Key, 'kubernetes.io/cluster/')].Key" \
      --output text 2>/dev/null | grep -q . && echo "classic $name"
  done
  return 0
}

command -v aws >/dev/null 2>&1 || fail "aws CLI not installed (brew install awscli)"
aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS credentials do not resolve"
[ -n "$REGION" ] || fail "AWS_LAB_REGION is not set. Pin one region so there is one place to sweep."

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ -n "${AWS_LAB_ACCOUNT_ID:-}" ] && [ "$ACCOUNT" != "$AWS_LAB_ACCOUNT_ID" ]; then
  fail "credentials resolve to account $ACCOUNT, but AWS_LAB_ACCOUNT_ID is $AWS_LAB_ACCOUNT_ID"
fi

CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)

if [ -z "$CLUSTERS" ]; then
  printf '%sNo EKS clusters in %s.%s Checking for orphans anyway.\n' "$DIM" "$REGION" "$RESET"
else
  echo
  printf '%sThis will destroy, in account %s / region %s:%s\n' "$YELLOW" "$ACCOUNT" "$REGION" "$RESET"
  while IFS= read -r c; do printf '    cluster  %s\n' "$c"; done <<<"$CLUSTERS"
  printf '    plus every node group, load balancer and EBS volume they created.\n\n'
  if [ "${ASSUME_YES:-}" != "1" ]; then
    printf 'Type the region name (%s) to confirm: ' "$REGION"
    read -r reply
    [ "$reply" = "$REGION" ] || fail "not confirmed, nothing deleted"
  fi
fi

# --- 1. Release load balancers while the API server can still be reached ----
if [ -n "$CLUSTERS" ] && command -v kubectl >/dev/null 2>&1; then
  while IFS= read -r c; do
    step "releasing LoadBalancer Services in $c"
    if aws eks update-kubeconfig --name "$c" --region "$REGION" >/dev/null 2>&1; then
      svcs=$(kubectl get svc --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
      if [ -z "$svcs" ]; then
        echo "    none"
      else
        while IFS=' ' read -r ns name; do
          [ -n "$name" ] || continue
          echo "    deleting svc $ns/$name"
          kubectl delete svc "$name" -n "$ns" --timeout=120s >/dev/null 2>&1 || true
        done <<<"$svcs"
        # The Service object goes at once; the load balancer behind it
        # takes longer, and its ENIs hold the subnets until it is gone.
        # Wait for AWS to say so instead of guessing how long that takes.
        for _ in $(seq 1 30); do
          left=$(cluster_lbs)
          [ -z "$left" ] && { echo "    load balancers gone"; break; }
          echo "    waiting for AWS to delete: $(awk '{print $2}' <<<"$left" | sed 's#.*/##' | tr '\n' ' ')"
          sleep 10
        done
      fi
    else
      printf '    %scould not reach the API server -- skipping, step 4 will catch the leftovers%s\n' "$DIM" "$RESET"
    fi
  done <<<"$CLUSTERS"
fi

# --- 2. Let Terraform destroy what it owns --------------------------------
if [ -d "$ROOT/infra/eks" ] && [ -n "$(find "$ROOT/infra/eks" -name '*.tf' -print -quit 2>/dev/null)" ]; then
  step "terraform destroy in infra/eks"
  (cd "$ROOT/infra/eks" && terraform destroy -auto-approve) || \
    printf '    %sdestroy failed -- step 3 deletes what it left%s\n' "$YELLOW" "$RESET"
else
  printf '\n%sNo Terraform under infra/eks yet (Project 13 creates it) -- deleting directly.%s\n' "$DIM" "$RESET"
fi

# --- 3. Delete any cluster Terraform did not ------------------------------
CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)
if [ -n "$CLUSTERS" ]; then
  while IFS= read -r c; do
    step "deleting cluster $c"
    ngs=$(aws eks list-nodegroups --cluster-name "$c" --region "$REGION" \
      --query 'nodegroups[]' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)
    while IFS= read -r ng; do
      [ -n "$ng" ] || continue
      echo "    deleting nodegroup $ng"
      aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" --region "$REGION" >/dev/null 2>&1 || true
    done <<<"$ngs"
    while IFS= read -r ng; do
      [ -n "$ng" ] || continue
      echo "    waiting for nodegroup $ng to drain (a few minutes)"
      aws eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
    done <<<"$ngs"
    aws eks delete-cluster --name "$c" --region "$REGION" >/dev/null 2>&1 || true
    echo "    waiting for the control plane to go"
    aws eks wait cluster-deleted --name "$c" --region "$REGION" 2>/dev/null || true
    echo "    gone"
  done <<<"$CLUSTERS"
fi

# --- 3b. Load balancers Kubernetes made that nothing deleted ---------------
# Step 1 cannot reach a cluster that is half-deleted or whose kubeconfig is
# gone, and Terraform never knew about these. Delete them by their tag.
left=$(cluster_lbs)
if [ -n "$left" ]; then
  step "deleting load balancers left by Kubernetes"
  while read -r kind id; do
    echo "    $kind $id"
    if [ "$kind" = v2 ]; then
      aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$id" || true
    else
      aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$id" || true
    fi
  done <<<"$left"
fi
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
  echo "    deleting security group $sg left by Kubernetes"
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 || \
    printf '    %scould not delete %s yet (still attached?)%s\n' "$YELLOW" "$sg" "$RESET"
done

# --- 4. Report what is still billing --------------------------------------
step "sweeping for leftovers"
"$ROOT/scripts/aws-sweep.sh"

printf '%sAnything still listed under "Metered" is billing you now.%s\n' "$DIM" "$RESET"
printf '%sEBS volumes and load balancers are the two that survive a clean destroy.%s\n\n' "$DIM" "$RESET"
