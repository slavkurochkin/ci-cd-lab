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

WORKDIR /app

COPY package.json package-lock.json ./

# TODO(lab-05-d): The scan will fail on this image too, and the findings will
# be stranger: pacote, brace-expansion, ip-address. None of those are in
# package.json.
#
# Find out what ships them, then ask whether this image needs it at all. The
# entrypoint is `node`, not `npm`.
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=builder /app/src ./src

ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA \
    NODE_ENV=production

USER node

CMD ["node", "--experimental-strip-types", "src/index.ts"]
