# Same targets as every other service in this repository. See app/api/Makefile.
.PHONY: install lint fmt typecheck test coverage test-integration

install:
	npm ci

lint:
	npm run lint
	npm run format:check

fmt:
	npm run format

typecheck:
	npm run build

test:
	npm run test

# The coverage gate. Thresholds live in vitest.config.ts.
coverage:
	npm run test:coverage

# The worker has no external dependencies, so it has nothing to integrate with.
# The target exists so the pipeline can call it unconditionally.
test-integration:
	@echo "worker: no integration tests"
