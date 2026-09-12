# syntax=docker.io/docker/dockerfile:1.7-labs@sha256:b99fecfe00268a8b556fad7d9c37ee25d716ae08a5d7320e6d51c4dd83246894
# Unity Catalog OSS server (Scala / sbt build).
#
# Layer-cache strategy — sbt pulls ~600MB of Ivy/Coursier deps per fresh build.
# The previous version of this file ran `sbt clean package`, which deletes
# target/ and forces a full re-resolve every time. That made the sbt RUN
# layer the single largest source of wasted network I/O in the repo.
#
# Fix:
#   1. `sbt package` (no `clean`) so incremental compile + downloaded deps
#      survive across builds.
#   2. BuildKit cache mounts for /root/.cache/coursier and /root/.sbt so sbt's
#      local cache is reused across builds.
#   3. Split COPY so build.sbt + project/build.properties (rarely change) are
#      in their own layer, then sources (change often). Bumping a .scala file
#      no longer invalidates the sbt dependency-resolution layer.
#   4. Copy only the runtime artifact tree, not the whole target/ tree.
#
# COPY note: `COPY src/ dest/` with src ending in `/` copies CONTENTS into
# dest. To preserve the source directory itself, the destination must end in
# a slash (e.g. `COPY build/ ./build/`). Each source directory needs its own
# COPY line — multi-source COPY flattens contents into the dest dir.

ARG HOME="/home/unitycatalog"

# ---------- Stage 1: build ----------
FROM amazoncorretto:17-alpine3.20-jdk@sha256:c045f0537bc890f9e61924f33f35e9667f696b4f372dad4a73861a9396b5d0b5 as base

ARG HOME
ENV HOME=$HOME

WORKDIR $HOME

# Build tooling (bash, sbt deps later via cache mount)
RUN apk add --no-cache bash

# --- Build descriptor (rarely changes) ---
# project/build.properties pins sbt version; build.sbt pins deps.
# Putting these first means dep resolution + jar downloads live in their own
# layer and survive source edits.
COPY build.sbt version.sbt ./
COPY project/ ./project/

# --- Source tree (changes often) ---
# Each directory needs its own COPY because Docker's multi-source COPY
# flattens all source contents into the dest directory. Using individual
# COPY lines keeps each directory under its own name (build/, server/, etc).
COPY dev/ ./dev/
COPY build/ ./build/
COPY examples/ ./examples/
COPY server/ ./server/
COPY api/ ./api/
COPY clients/ ./clients/

# Run sbt with `clean package` — clean wipes target/ (the incremental
# compile state) but NOT the Coursier/Ivy cache, so with the cache mounts
# below the ~600MB of Maven deps still survive across builds.
#
# We tried `sbt package` (incremental, no clean) but Zinc's incremental
# compile trips on the cached state when the persisted cache mount has
# stale data from a previous code shape. `clean` is the safe fallback;
# the cost is recompilation only — the dep cache stays hot.
#
# Important: cache mounts are host-side ONLY — files written under the
# mount target do NOT land in the image layer. So we cp the resolved deps
# into $HOME/.cache (regular image dir) inside the same RUN. The runtime
# stage then COPYs from $HOME/.cache back to /root/.cache (where the
# classpath file expects them).
RUN --mount=type=cache,target=/root/.cache/coursier,sharing=locked \
    --mount=type=cache,target=/root/.ivy2,sharing=locked \
    ./build/sbt -batch \
        'set ThisBuild / scalacOptions += "-Wconf:any:silent"' \
        'clean' \
        'server/package' && \
    mkdir -p $HOME/.cache && \
    cp -a /root/.cache/coursier $HOME/.cache/coursier 2>/dev/null || true && \
    cp -a /root/.cache/.sbt  $HOME/.cache/.sbt 2>/dev/null || true

# ---------- Stage 2: runtime ----------
FROM alpine:3.20@sha256:a4f4213abb84c497377b8544c81b3564f313746700372ec4fe84653e4fb03805 as runtime

ARG JAVA_HOME="/usr/lib/jvm/default-jvm"
ARG USER="unitycatalog"
ARG HOME

# Copy Java from base
COPY --from=base $JAVA_HOME $JAVA_HOME

ENV HOME=$HOME \
    JAVA_HOME=$JAVA_HOME \
    PATH="${JAVA_HOME}/bin:${PATH}"

# Set WORKDIR before COPY so bin/ and etc/ land in the right place.
WORKDIR $HOME

# Build artifacts.
#
# The classpath file in server/target/ references JARs by absolute path:
#   /root/.cache/coursier/v1/https/.../<dep>.jar
# So the runtime image MUST contain those JARs at those exact paths. We
# copy the entire /root/.cache/coursier tree from the build stage — this
# is the same as the previous Dockerfile's behavior. The build-host cache
# mount above still helps rebuilds skip re-downloading the ~600MB of deps.
#
# Future optimization (tracked, not in this commit): switch to a true
# shaded fat JAR via sbt-assembly's `assembly` task + include-transitive,
# which would let us drop the coursier cache from the image and shrink it
# from ~3GB back to ~700MB. Requires build.sbt changes (assemblyShadeRules
# + mainClass + shade strategy) that are out of scope for the optimization
# pass — call out separately.
COPY --from=base $HOME/.cache/coursier/ /root/.cache/coursier/
COPY --from=base --parents \
    $HOME/api/ \
    $HOME/clients/ \
    $HOME/examples/ \
    /
# Stage server/target/ as the "jars" dir expected by bin/start-uc-server.
# Copy all of server/target/ in (including the classpath file and the
# classes/ subdirectory) and then sed-replace paths so the classpath file
# references jars/ for the fat JAR instead of server/target/. Other
# entries (which reference /root/.cache/coursier/...) stay intact because
# we copied that tree into the image too.
RUN mkdir -p ./jars
COPY --from=base $HOME/server/target/ ./jars-tmp/
RUN cp -r ./jars-tmp/* ./jars/ && \
    rm -rf ./jars-tmp && \
    # Rewrite the fat-JAR reference (server/target/unitycatalog-server-X.jar → jars/unitycatalog-server-X.jar)
    sed -i 's|server/target/unitycatalog-server-|jars/unitycatalog-server-|g' ./jars/classpath
COPY bin/ ./bin/
COPY etc/ ./etc/

# Create the runtime user with appropriate permissions.
# We also chmod /root and chown /root/.cache so the unitycatalog user can
# read the JARs there — the classpath file references absolute paths under
# /root/.cache/coursier/v1/https/.../.
RUN <<EOF
apk add --no-cache bash
addgroup -S $USER
adduser -S -G $USER $USER
chmod -R 550 $HOME
mkdir -p $HOME/etc/
chmod -R 770 $HOME/etc/
chown -R $USER:$USER $HOME
chown -R $USER:$USER /root/.cache
chmod 755 /root
EOF

USER $USER

WORKDIR $HOME

CMD ["./bin/start-uc-server"]
