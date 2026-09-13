#!/usr/bin/env bash
# Check the toolchain for this curriculum and print exactly what to install.
# Tools are grouped by the track that first needs them -- nothing here is
# required before the track that uses it.

set -uo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

missing_required=0
missing_optional=()

check() {
  local name="$1" track="$2" install="$3" required="$4"
  local version=""

  if command -v "$name" >/dev/null 2>&1; then
    case "$name" in
      docker)    version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') ;;
      kubectl)   version=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -1 | cut -d'"' -f4) ;;
      minikube)  version=$(minikube version --short 2>/dev/null) ;;
      terraform) version=$(terraform version -json 2>/dev/null | grep -o '"terraform_version": *"[^"]*"' | cut -d'"' -f4) ;;
      aws)       version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2) ;;
      helm)      version=$(helm version --short 2>/dev/null) ;;
      doppler)   version=$(doppler --version 2>/dev/null) ;;
      *)         version=$("$name" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    esac
    printf '  %s✓%s %-12s %-10s %s%s%s\n' "$GREEN" "$RESET" "$name" "${version:-installed}" "$DIM" "$track" "$RESET"
  elif [ "$required" = "required" ]; then
    printf '  %s✗%s %-12s %-10s %s%s%s\n' "$RED" "$RESET" "$name" "MISSING" "$DIM" "$track" "$RESET"
    missing_required=$((missing_required + 1))
    missing_optional+=("$install")
  else
    printf '  %s○%s %-12s %-10s %s%s%s\n' "$YELLOW" "$RESET" "$name" "later" "$DIM" "$track" "$RESET"
    missing_optional+=("$install")
  fi
}

echo
echo "Toolchain"
echo "---------"
check git       "everywhere"      "git"                        required
check make      "everywhere"      "make"                       required
check uv        "app/api"         "uv"                         required
check node      "app/worker"      "node"                       required
check gh        "Track A  (1-5)"  "gh"                         required
check actionlint "Track A  (1-5)" "actionlint"                 optional
check docker    "Track A  (5+)"   "--cask docker"              optional
check terraform "Track B, C (13)" "terraform"                  optional
check aws       "Track B, C (13)" "awscli"                     optional
check tflint    "Track B  (8-9)"  "tflint"                     optional
check checkov   "Track B  (9)"    "checkov"                    optional
check kubectl   "Track C (10-14)" "kubernetes-cli"             optional
check minikube  "Track C (10-12)" "minikube"                   optional
check doppler   "Track C (11)"    "dopplerhq/cli/doppler"      optional
check helm      "Track C (11)"    "helm"                       optional
check argocd    "Track C (14)"    "argocd"                     optional
check trivy     "Track D (17)"    "trivy"                      optional
check cosign    "Track D (17)"    "cosign"                     optional

echo
echo "Services"
echo "--------"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    printf '  %s✓%s docker daemon is running\n' "$GREEN" "$RESET"
  else
    printf '  %s✗%s docker daemon is NOT running %s(open Docker Desktop)%s\n' "$RED" "$RESET" "$DIM" "$RESET"
  fi
fi
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf '  %s✓%s gh is authenticated as %s\n' "$GREEN" "$RESET" "$(gh api user -q .login 2>/dev/null || echo '?')"
  else
    printf '  %s✗%s gh is not authenticated %s(run: gh auth login)%s\n' "$RED" "$RESET" "$DIM" "$RESET"
  fi
fi
if command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity >/dev/null 2>&1; then
    printf '  %s✓%s aws credentials resolve (account %s)\n' "$GREEN" "$RESET" "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  else
    printf '  %s○%s aws credentials do not resolve %s(only needed from Track B)%s\n' "$YELLOW" "$RESET" "$DIM" "$RESET"
  fi
fi

if [ ${#missing_optional[@]} -gt 0 ]; then
  echo
  echo "Install what you are missing"
  echo "----------------------------"
  echo "  brew install ${missing_optional[*]}"
fi

echo
if [ "$missing_required" -gt 0 ]; then
  printf '%s%d required tool(s) missing.%s Track A cannot start until they are installed.\n\n' "$RED" "$missing_required" "$RESET"
  exit 1
fi
printf '%sReady for Track A.%s Optional tools are only needed by the track named beside them.\n\n' "$GREEN" "$RESET"
