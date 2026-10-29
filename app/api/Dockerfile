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

# Apply the distribution's security updates.
#
# A base image tag is a snapshot of someone else's patching cadence, not a
# promise of current packages. python:3.12-slim rebuilds on its own schedule,
# so a freshly pulled image still carried 12 fixable HIGH/CRITICAL findings --
# Debian had published the fixes, the image had not picked them up.
#
# This runs at build time, so the result is baked into the layer rather than
# happening on every container start.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1001 app \
 && useradd --system --uid 1001 --gid app --no-create-home app

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/src /app/src

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# AWS Lambda Web Adapter (Capstone B). A Lambda extension: inside Lambda it
# turns invocations into HTTP requests to uvicorn on port 8000, so this image
# runs on Lambda with no handler code. Anywhere else it is a file nobody runs,
# and the image behaves as before -- which is what lets Track C run the same
# image on Kubernetes. Pinned by digest, like everything else this image pulls.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0@sha256:17cfd08eff1dfea3f6a9a1e9c65fdac80aa4919b6085e746615530f43f57d2f1 \
     /lambda-adapter /opt/extensions/lambda-adapter

# The adapter forwards to this port, and only once this path answers. The
# default path is "/", which this app does not serve.
ENV AWS_LWA_PORT=8000 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz

# Stamped by the pipeline; /version reports it back so you can prove what is running.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

USER app
EXPOSE 8000

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--app-dir", "/app/src"]
