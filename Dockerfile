# syntax=docker/dockerfile:1.7
#
# cfg-server-factorio — thin container around the official Factorio dedicated
# server binary. No mods baked in, no Steam dependency — just the upstream
# headless tarball from factorio.com, extracted onto debian-slim, run as
# non-root.
#
# Saves live in /factorio (volume mount). The entrypoint generates a minimal
# server-settings.json from env vars on first boot if none is mounted, and
# creates a fresh map if no save exists.
#
# IMPORTANT: Factorio's multiplayer is UDP/34197. Not HTTP. Caddy + the proxy
# layer above core-server don't apply; the host port maps directly and the
# player connects via `<host>:<udp-port>` in Factorio's "Connect to address"
# UI. The OVH host needs `ufw allow <port>/udp` for any port that should
# accept connections.
#
# Build:
#   docker build -t cfg-server-factorio:local .
#
# Run (local test):
#   docker run --rm -p 34197:34197/udp -v $(pwd)/saves:/factorio \
#     cfg-server-factorio:local

# The pinned version is the OWNER-ACKNOWLEDGED upstream release, kept honest by
# the daily `upstream-watch` workflow in cfg-core-dev-tools: when upstream
# stable moves past this pin, it opens a bump PR against `next` and pings
# Discord, so upstream movement is always visible and on the record.
#
# ⚠️ This pin does NOT gate what ships ("notify mode", owner decision
# 2026-08-06). CI resolves the current stable from
# https://factorio.com/api/latest-releases at build time and overrides this ARG,
# so published images track upstream automatically. That is deliberate, not
# lazy: Factorio multiplayer requires an EXACT client/server version match, and
# Steam auto-updates clients. A server gated on a human review becomes
# unreachable the moment upstream moves — which is exactly what happened at
# 2.0.76 vs a 2.0.77 client. The pin flips from record to build input ("gate
# mode") only when kind QA can vouch for a bump automatically.
ARG FACTORIO_VERSION=2.0.77

FROM debian:bookworm-slim AS extract

ARG FACTORIO_VERSION
# `get-download/<version>/headless/linux64` 302-redirects to a tokenized
# dl.factorio.com URL. curl follows the redirect; the token is per-request
# so we can't cache it across builds (and shouldn't try).
ARG FACTORIO_URL=https://factorio.com/get-download/${FACTORIO_VERSION}/headless/linux64

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl -fsSL -o factorio.tar.xz "$FACTORIO_URL" && \
    tar -xJf factorio.tar.xz && \
    rm factorio.tar.xz && \
    # Tarball extracts as `factorio/` with a stable layout: bin/, data/, etc.
    # Move it whole to /opt/factorio so the runtime image just COPYs one dir.
    mv factorio /opt/factorio && \
    chmod +x /opt/factorio/bin/x64/factorio

# ── Bundled crit-fumble-link service mod ────────────────────────────────────
# Zipped in its own stage so editing the mod never re-downloads the Factorio
# tarball (and vice versa). Factorio requires the zip's top-level dir to be
# `<name>_<version>`, matching info.json.
FROM debian:bookworm-slim AS modpack

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
      jq zip && \
    rm -rf /var/lib/apt/lists/*

COPY mod/ /build/mod/
RUN set -eu; \
    version=$(jq -er .version /build/mod/crit-fumble-link/info.json); \
    mkdir -p /opt/cfg/mods; \
    cd /build/mod; \
    cp -r crit-fumble-link "crit-fumble-link_${version}"; \
    zip -qr "/opt/cfg/mods/crit-fumble-link_${version}.zip" "crit-fumble-link_${version}"

# ── Final runtime image ─────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG FACTORIO_VERSION
LABEL org.opencontainers.image.title="cfg-server-factorio"
LABEL org.opencontainers.image.description="Crit-Fumble Factorio dedicated server container"
LABEL org.opencontainers.image.source="https://github.com/Crit-Fumble/cfg-server-factorio"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.version="${FACTORIO_VERSION}"

# Factorio's headless binary is a 64-bit native ELF; needs libstdc++ + libgcc.
# tini reaps zombies and forwards SIGTERM so `docker stop` does a clean
# autosave-and-exit instead of leaving a torn map.
# curl + jq serve the entrypoint's mod-portal sync (download enabled-but-
# missing mods at boot) and its mod-list.json editing.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq libstdc++6 libgcc-s1 tini && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --uid 1000 --user-group --no-create-home --shell /usr/sbin/nologin factorio

COPY --from=extract /opt/factorio /opt/factorio
COPY --from=modpack /opt/cfg /opt/cfg
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /factorio: where saves + config live. Mount a per-installation host dir here.
# /opt/factorio: read-only binary tree; factorio user owns nothing in it.
RUN mkdir -p /factorio/saves /factorio/mods && \
    chown -R factorio:factorio /factorio

USER factorio
WORKDIR /factorio

# 34197/udp is Factorio's only required listener. RCON is intentionally
# omitted from this image; if/when an admin surface needs it, expose
# --rcon-port at runtime and add a TCP port mapping.
EXPOSE 34197/udp

# FACTORIO_SERVICE_MOD defaults OFF: Factorio requires connecting clients to
# match the server's mod set, so the bundled crit-fumble-link mod must be
# published on the mod portal (client "Sync mods" source) before any server
# enables it. core-server flips it per-installation once that holds.
ENV FACTORIO_SAVE_NAME=cfg-world \
    FACTORIO_PORT=34197 \
    FACTORIO_MAX_PLAYERS=16 \
    FACTORIO_VISIBILITY_PUBLIC=false \
    FACTORIO_VISIBILITY_LAN=true \
    FACTORIO_REQUIRE_USER_VERIFICATION=true \
    FACTORIO_AUTOSAVE_INTERVAL=10 \
    FACTORIO_NAME="Crit-Fumble Factorio Server" \
    FACTORIO_DESCRIPTION="Hosted by Crit-Fumble" \
    FACTORIO_PASSWORD="" \
    FACTORIO_MODS="" \
    FACTORIO_ADMINS="" \
    FACTORIO_USERNAME="" \
    FACTORIO_TOKEN="" \
    FACTORIO_SERVICE_MOD=false \
    FACTORIO_MAP_PRESET=""

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
