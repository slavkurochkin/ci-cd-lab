# Multi-stage: dev dependencies (typescript, eslint, vitest) never ship.

FROM node:22-slim AS builder

WORKDIR /app

# Dependencies first: cached until package-lock.json changes.
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src

# Typecheck in the image build too, so a broken image cannot be produced quietly.
RUN npx tsc --noEmit


FROM node:22-slim AS runtime

# See the note in app/api/Dockerfile: a base image tag is a snapshot of
# someone else's patching cadence, not a promise of current packages.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./

# Install production dependencies, then delete npm itself.
#
# npm ships a large dependency tree of its own (pacote, brace-expansion,
# ip-address and friends), and those count as vulnerabilities in this image
# even though nothing here ever runs npm again -- the entrypoint is `node`.
# A package manager in a runtime image is attack surface you are not using.
RUN npm ci --omit=dev \
 && npm cache clean --force \
 && rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/bin/npm \
           /usr/local/bin/npx

COPY --from=builder /app/src ./src

ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA \
    NODE_ENV=production

USER node

CMD ["node", "--experimental-strip-types", "src/index.ts"]
