#!/usr/bin/env bash
#
# cfg-server-factorio entrypoint.
#
# Boot flow:
#   1. Generate /factorio/server-settings.json from FACTORIO_* env vars
#      on first boot (user-mounted file wins if present).
#   2. Seed /factorio/config/config.ini so Factorio's write dir is the
#      mounted volume and not the root-owned /opt/factorio (see below).
#   3. If no save exists in /factorio/saves/, create a fresh map.
#   4. Launch factorio --start-server-load-latest. tini (PID 1) reaps
#      zombies and forwards SIGTERM so the server autosaves cleanly on
#      `docker stop` instead of leaving a torn map.
#
# Env knobs (defaults match Dockerfile ENV):
#   FACTORIO_SAVE_NAME            — save basename for the first auto-creation
#   FACTORIO_PORT                 — listen port (default 34197)
#   FACTORIO_MAX_PLAYERS          — player cap (0 = unlimited)
#   FACTORIO_VISIBILITY_PUBLIC    — list on factorio.com matchmaking
#   FACTORIO_VISIBILITY_LAN       — broadcast on LAN
#   FACTORIO_REQUIRE_USER_VERIFICATION — require Factorio.com auth
#   FACTORIO_AUTOSAVE_INTERVAL    — minutes between autosaves
#   FACTORIO_NAME / DESCRIPTION   — what shows in the server browser
#   FACTORIO_PASSWORD             — server password ('' = none)
#
# A user-supplied /factorio/server-settings.json (mounted in by core-server)
# wins over the env-driven template.

set -euo pipefail

ROOT=/factorio
SETTINGS="$ROOT/server-settings.json"
SAVES_DIR="$ROOT/saves"
SAVE_NAME="${FACTORIO_SAVE_NAME:-cfg-world}"
SAVE_FILE="$SAVES_DIR/${SAVE_NAME}.zip"
FACTORIO_BIN=/opt/factorio/bin/x64/factorio
CONFIG_DIR="$ROOT/config"
CONFIG_INI="$CONFIG_DIR/config.ini"

mkdir -p "$SAVES_DIR" "$CONFIG_DIR"

# Point Factorio's WRITE dir at the mounted volume.
#
# The upstream tarball ships config-path.cfg with
# `use-system-read-write-data-directories=false`, which makes the write dir the
# application root — so the binary tries to create /opt/factorio/.lock (plus
# player-data.json, temp/, mods/) on every boot. That tree is root-owned and we
# run as `factorio`, so the lock fails with EACCES and the process exits 1
# before doing anything. Passing an explicit --config bypasses config-path.cfg
# entirely and keeps /opt/factorio read-only, as the Dockerfile intends.
#
# Seed-if-absent, so a user who mounts their own config.ini keeps it.
if [ ! -f "$CONFIG_INI" ]; then
  echo "[cfg-server-factorio] seeding $CONFIG_INI (write-data → $ROOT)"
  cat > "$CONFIG_INI" <<-EOF
	[path]
	read-data=/opt/factorio/data
	write-data=$ROOT
	EOF
fi

if [ -f "$SETTINGS" ]; then
  echo "[cfg-server-factorio] using mounted server-settings.json at $SETTINGS"
else
  echo "[cfg-server-factorio] generating server-settings.json from env"
  # Heredoc with bash variable expansion. Use jq-style booleans
  # explicitly so 'false' / 'true' aren't quoted as strings — Factorio
  # rejects 'true' (string) where it expects a bool.
  cat > "$SETTINGS" <<EOF
{
  "name": "${FACTORIO_NAME:-Crit-Fumble Factorio Server}",
  "description": "${FACTORIO_DESCRIPTION:-Hosted by Crit-Fumble}",
  "tags": [],
  "max_players": ${FACTORIO_MAX_PLAYERS:-16},
  "visibility": {
    "public": ${FACTORIO_VISIBILITY_PUBLIC:-false},
    "lan": ${FACTORIO_VISIBILITY_LAN:-true}
  },
  "username": "",
  "password": "",
  "token": "",
  "game_password": "${FACTORIO_PASSWORD:-}",
  "require_user_verification": ${FACTORIO_REQUIRE_USER_VERIFICATION:-true},
  "max_upload_in_kilobytes_per_second": 0,
  "max_upload_slots": 5,
  "minimum_latency_in_ticks": 0,
  "ignore_player_limit_for_returning_players": false,
  "allow_commands": "admins-only",
  "autosave_interval": ${FACTORIO_AUTOSAVE_INTERVAL:-10},
  "autosave_slots": 5,
  "afk_autokick_interval": 0,
  "auto_pause": true,
  "only_admins_can_pause_the_game": true,
  "autosave_only_on_server": true,
  "non_blocking_saving": true
}
EOF
fi

# Create a fresh save if none exists. This is one-shot — subsequent boots
# reuse the latest save (autosaves count, so a previously-loaded server
# keeps its progress across container restarts).
if ! compgen -G "$SAVES_DIR/*.zip" > /dev/null; then
  echo "[cfg-server-factorio] no save found — creating $SAVE_FILE"
  "$FACTORIO_BIN" --config "$CONFIG_INI" --create "$SAVE_FILE"
fi

echo "[cfg-server-factorio] starting Factorio server on UDP port ${FACTORIO_PORT:-34197}"
exec "$FACTORIO_BIN" \
  --config "$CONFIG_INI" \
  --start-server-load-latest \
  --port "${FACTORIO_PORT:-34197}" \
  --server-settings "$SETTINGS"
