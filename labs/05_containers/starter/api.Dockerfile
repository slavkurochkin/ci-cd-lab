# Multi-stage: build tooling never reaches the runtime image.
# Layer order is deliberate -- dependencies before source, so a source-only
# change reuses the dependency layer. Lab 05 measures the difference.

FROM python:3.12-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependencies first: this layer is cached until pyproject.toml changes.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

# Then the source, which changes on every commit.
COPY src ./src
RUN uv sync --frozen --no-dev


FROM python:3.12-slim AS runtime

# TODO(lab-05-d): The scan in TODO(lab-05-c) will fail on this image, and the
# findings will all be Debian packages you did not choose -- gzip, libpcre2,
# libsqlite3, libssl3.
#
# Pulling a fresher base image helps and does not fix it. Work out why, then
# fix it here. Measure the image before and after: the fix is not free, and
# knowing what it costs is part of the answer.
RUN groupadd --system --gid 1001 app \
 && useradd --system --uid 1001 --gid app --no-create-home app

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/src /app/src

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Stamped by the pipeline; /version reports it back so you can prove what is running.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

USER app
EXPOSE 8000

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--app-dir", "/app/src"]
