# CI/CD Lab -- entry point for every task in this repo.
#
#   make doctor              check your toolchain
#   make lab LAB=01          install a lab's starter files at their real paths
#   make verify LAB=01       run that lab's verifier
#   make reset LAB=01        discard your edits and restore the starter
#   make solution LAB=01     diff your files against the reference solution
#
# Lab numbers may be written 1 or 01.

.DEFAULT_GOAL := help
.PHONY: help doctor status labs lab verify verify-all reset solution \
        test test-integration lint fmt build-images run-api ci-local \
        aws-sweep eks-up eks-down eks-cost argocd-bootstrap \
        platform-up where promote rollback clean

LAB ?=
PYTEST := uv run pytest

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo ""
	@echo "  CI/CD Lab"
	@echo "  ---------"
	@echo "  Curriculum:  ROADMAP.md          Cost rules:  docs/COST.md"
	@echo ""
	@echo "  Getting started"
	@echo "    make doctor              check the toolchain and print install commands"
	@echo "    make status              which labs are installed, untouched, or edited"
	@echo ""
	@echo "  Working a lab"
	@echo "    make lab LAB=01          install starter files at their real paths"
	@echo "    make verify LAB=01       run the verifier for that lab"
	@echo "    make solution LAB=01     diff your work against the reference"
	@echo "    make reset LAB=01        discard your edits, restore the starter"
	@echo ""
	@echo "  The sample app"
	@echo "    make test                run both service test suites"
	@echo "    make test-integration    start DynamoDB Local and run integration tests"
	@echo "    make lint                lint and format-check both services"
	@echo "    make fmt                 apply formatting to both services"
	@echo "    make build-images        build both container images"
	@echo "    make run-api             serve the API on http://localhost:8000"
	@echo "    make ci-local JOB=api    run one pipeline job locally with act"
	@echo ""
	@echo "  AWS (Track B, and Track C from Project 13)"
	@echo "    make eks-up              create the lab cluster (~15 min, starts billing)"
	@echo "    make eks-down            destroy it and sweep for orphans -- end every session"
	@echo "    make eks-cost            this month's spend by service"
	@echo "    make aws-sweep           list everything billable in the pinned region"
	@echo ""

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

doctor:
	@./scripts/doctor.sh

status:
	@uv run --quiet python scripts/labctl.py status

labs: status

# ---------------------------------------------------------------------------
# Labs
# ---------------------------------------------------------------------------

require-lab:
ifndef LAB
	$(error LAB is not set. Try: make $(MAKECMDGOALS) LAB=01)
endif

lab: require-lab
	@uv run --quiet python scripts/labctl.py install $(LAB)
	@echo ""
	@echo "  Read:   $$(uv run --quiet python scripts/labctl.py readme $(LAB))"
	@echo "  Verify: make verify LAB=$(LAB)"
	@echo ""

verify: require-lab
	@$(PYTEST) $$(uv run --quiet python scripts/labctl.py readme $(LAB) | xargs dirname)/verify

verify-all:
	@$(PYTEST) labs/*/verify

reset: require-lab
	@uv run --quiet python scripts/labctl.py reset $(LAB)

solution: require-lab
	@uv run --quiet python scripts/labctl.py solution $(LAB)

# ---------------------------------------------------------------------------
# Sample app
# ---------------------------------------------------------------------------

# Every service exposes the same targets (install, lint, fmt, test,
# test-integration) in its own Makefile. That uniform interface is what lets
# one reusable workflow build all of them -- see labs/03_abstraction.
SERVICES := api worker

test:
	@for s in $(SERVICES); do echo "==> app/$$s"; $(MAKE) -C app/$$s test || exit 1; done

lint:
	@for s in $(SERVICES); do echo "==> app/$$s"; $(MAKE) -C app/$$s lint || exit 1; done

fmt:
	@for s in $(SERVICES); do $(MAKE) -C app/$$s fmt || exit 1; done

# Integration tests need a real DynamoDB. This starts one, runs them, stops it.
test-integration:
	@docker rm -f dynamodb-local >/dev/null 2>&1 || true
	@docker run -d --rm -p 8000:8000 --name dynamodb-local amazon/dynamodb-local >/dev/null
	@echo "waiting for dynamodb-local..."
	@for i in $$(seq 1 30); do curl -sf -o /dev/null http://localhost:8000 && break; sleep 1; done
	@for s in $(SERVICES); do \
		echo "==> app/$$s"; \
		DYNAMODB_ENDPOINT=http://localhost:8000 AWS_REGION=us-east-1 \
			$(MAKE) -C app/$$s test-integration || { docker rm -f dynamodb-local >/dev/null; exit 1; }; \
	done
	@docker rm -f dynamodb-local >/dev/null

# Run one pipeline job on this laptop instead of pushing and waiting.
#   make ci-local JOB=api
ci-local:
	@command -v act >/dev/null 2>&1 || { echo "act not installed (brew install act)"; exit 1; }
	@act pull_request --job $(or $(JOB),ci-passed) --workflows .github/workflows/lab-03-ci.yml

build-images:
	@docker build -t lab-api:local --build-arg GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo dev) app/api
	@docker build -t lab-worker:local --build-arg GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo dev) app/worker
	@docker images --filter reference='lab-*:local' --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}'

run-api:
	@cd app/api && uv run uvicorn api.main:app --reload --app-dir src

# ---------------------------------------------------------------------------
# AWS safety (Track B onward)
# ---------------------------------------------------------------------------

aws-sweep:
	@./scripts/aws-sweep.sh

# ---------------------------------------------------------------------------
# The lab cluster (Track C, Project 13 onward)
#
# Projects 10-12 run on minikube and cost nothing. From Project 13 the cluster
# is real, because the lessons there -- a runner that cannot reach your laptop,
# pod identity, a LoadBalancer that outlives its Service -- have no local
# equivalent. It bills about $4.50/day while it exists and $0 when it does not,
# so `make eks-down` is the last command of every session.
# ---------------------------------------------------------------------------

eks-up:
	@./scripts/aws-guard.sh true
	@cd infra/eks && terraform init -input=false && terraform apply -auto-approve
	@aws eks update-kubeconfig --name lab --region $${AWS_LAB_REGION:-us-east-1}
	@echo ""
	@echo "  Cluster up. It is billing now. Next: make argocd-bootstrap"
	@echo "  End the session with: make eks-down"
	@echo ""

# Project 14. Installs Argo CD from Git, then hands it the root Application.
# From there the cluster pulls everything else from deploy/ on main; nothing
# deploys to it. Run once after every `make eks-up`.
argocd-bootstrap:
	@kubectl apply --server-side -k deploy/argocd
	@kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
	@kubectl apply -f deploy/bootstrap/root.yaml
	@echo ""
	@echo "  Argo CD is pulling from Git. Watch: kubectl -n argocd get applications -w"

# Capstone C. From an empty account to three reconciled environments: one
# command, one wait. The cluster bills from here; end with `make eks-down`.
platform-up: eks-up argocd-bootstrap
	@echo "waiting for every Application to be Synced and Healthy ..."
	@for app in root argocd api-dev api-staging api-prod; do \
		until [ "$$(kubectl -n argocd get application $$app -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" = "Synced/Healthy" ]; do sleep 5; done; \
		echo "  $$app Synced/Healthy"; \
	done
	@./scripts/where.sh

# What is where, and which commit put it there: from Git, GHCR and the cluster.
where:
	@./scripts/where.sh

# Promote by pull request:  make promote FROM=staging TO=prod
promote:
	@test -n "$(FROM)" -a -n "$(TO)" || { echo "usage: make promote FROM=staging TO=prod"; exit 1; }
	@./scripts/promote.sh $(FROM) $(TO)

# Roll back by pull request:  make rollback ENV=prod
rollback:
	@test -n "$(ENV)" || { echo "usage: make rollback ENV=prod"; exit 1; }
	@./scripts/rollback.sh $(ENV)

eks-down:
	@./scripts/eks-down.sh

eks-cost:
	@aws ce get-cost-and-usage \
		--time-period Start=$$(date -u +%Y-%m-01),End=$$(date -u -v+1m +%Y-%m-01) \
		--granularity MONTHLY --metrics UnblendedCost \
		--group-by Type=DIMENSION,Key=SERVICE \
		--query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`0`]' \
		--output table

clean:
	@rm -rf app/api/.pytest_cache app/api/.ruff_cache app/api/.coverage
	@rm -rf app/worker/coverage
	@find . -name __pycache__ -type d -prune -exec rm -rf {} +
	@echo "cleaned"
