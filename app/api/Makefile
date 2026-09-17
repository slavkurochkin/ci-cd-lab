# Every service in this repository exposes the same targets. That uniform
# interface is what lets one reusable workflow build all of them without
# knowing anything about Python -- see labs/03_abstraction.
.PHONY: install lint fmt typecheck test coverage test-integration

install:
	uv sync --extra dev

lint:
	uv run ruff check .
	uv run ruff format --check .

fmt:
	uv run ruff format .
	uv run ruff check --fix .

typecheck:
	uv run mypy src

test:
	uv run pytest

# The coverage gate. Separate from `test` so the fast loop stays fast and the
# gate is a deliberate step -- see [tool.coverage.report] in pyproject.toml for
# what the floor excludes and why.
coverage:
	uv run pytest --cov=api --cov-report=term --cov-report=xml

# Needs a DynamoDB. Locally:
#   docker run -d --rm -p 8000:8000 --name dynamodb-local amazon/dynamodb-local
#   DYNAMODB_ENDPOINT=http://localhost:8000 make test-integration
test-integration:
	uv run pytest -m integration
