# Every service in this repository exposes the same targets. That uniform
# interface is what lets one reusable workflow build all of them without
# knowing anything about Python -- see labs/03_abstraction.
.PHONY: install lint fmt test test-integration

install:
	uv sync --extra dev

lint:
	uv run ruff check .
	uv run ruff format --check .

fmt:
	uv run ruff format .
	uv run ruff check --fix .

test:
	uv run pytest

# Needs a DynamoDB. Locally:
#   docker run -d --rm -p 8000:8000 --name dynamodb-local amazon/dynamodb-local
#   DYNAMODB_ENDPOINT=http://localhost:8000 make test-integration
test-integration:
	uv run pytest -m integration
