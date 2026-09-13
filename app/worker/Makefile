# Same targets as every other service in this repository. See app/api/Makefile.
.PHONY: install lint fmt test test-integration

install:
	npm ci

lint:
	npm run lint
	npm run format:check

fmt:
	npm run format

test:
	npm run test:coverage

# The worker has no external dependencies, so it has nothing to integrate with.
# The target exists so the pipeline can call it unconditionally.
test-integration:
	@echo "worker: no integration tests"
