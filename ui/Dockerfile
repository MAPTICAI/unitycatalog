# syntax=docker.io/docker/dockerfile:1.7-labs@sha256:b99fecfe00268a8b556fad7d9c37ee25d716ae08a5d7320e6d51c4dd83246894
# Unity Catalog UI (React + Vite + node:18).
#
# Layer-cache strategy:
#   - apt-get install jq in its own RUN so apt cache hits survive across builds
#     where only package.json or yarn.lock changes.
#   - jq mutates package.json (to inject the proxy host) is fine but the yarn
#     install layer is keyed off package.json + yarn.lock content only.
#   - 'yarn install' is the slow step (~hundreds of MB) — keep it as a single
#     RUN with a cache mount for /usr/local/share/.cache/yarn.

FROM node:18@sha256:c6ae79e38498325db67193d391e6ec1d224d96c693a8a4d943498556716d3783

ARG PROXY_HOST=server
WORKDIR /ui

# --- System deps (jq for package.json proxy injection) ---
# Separated from yarn install so a yarn.lock change doesn't redo apt.
RUN apt-get update && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# --- npm/yarn deps ---
COPY package.json yarn.lock ./

# Inject proxy host then install deps. The mutation only re-runs when
# PROXY_HOST changes; yarn install re-runs when package.json or yarn.lock
# change. Both are infrequent relative to source code edits.
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn,sharing=locked \
    set -ex; \
    jq --arg proxy "http://$PROXY_HOST:8080" '.proxy = $proxy' package.json > temp.json && \
    mv temp.json package.json && \
    yarn install --network-timeout 1000000 --frozen-lockfile

# --- App source — copied LAST so source edits only invalidate this layer ---
COPY --exclude=package.json --exclude=yarn.lock . ./

CMD ["yarn", "start"]
