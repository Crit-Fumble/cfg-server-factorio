#!/usr/bin/env bash
#
# cfg-server-factorio entrypoint.
#
# Boot flow:
#   1. Seed /factorio/config/config.ini so Factorio's write dir is the
#      mounted volume and not the root-owned /opt/factorio (see below).
#   2. Assemble the mod set:
#        a. seed mods/mod-list.json from FACTORIO_MODS on first boot,
#        b. install or remove the bundled crit-fumble-link service mod
#           (FACTORIO_SERVICE_MOD — default off, see the mods section),
#        c. download any enabled-but-missing mod from the Factorio mod
#           portal (requires FACTORIO_USERNAME + FACTORIO_TOKEN).
#   3. Generate /factorio/server-settings.json from FACTORIO_* env vars
#      on first boot (a mounted/pre-written file wins if present).
#   4. Seed /factorio/server-adminlist.json from FACTORIO_ADMINS on first
#      boot. In-game /promote persists to the same file, so it is seeded
#      once and never regenerated — a pre-written file always wins.
#   5. If no save exists in /factorio/saves/, create a fresh map —
#      from FACTORIO_MAP_PRESET (one of the game's own presets, e.g.
#      death-world), or from mounted map-gen-settings.json /
#      map-settings.json, which win over the preset.
#   6. Launch factorio --start-server-load-latest. tini (PID 1) reaps
#      zombies and forwards SIGTERM so the server autosaves cleanly on
#      `docker stop` instead of leaving a torn map.
#
# Env knobs (defaults match Dockerfile ENV) — see the README table.
#
# Files under /factorio that core-server (or a self-hoster) may pre-write —
# every one of them wins over the env-driven seeding:
#   server-settings.json     full server config (env template only seeds it)
#   server-adminlist.json    JSON array of Factorio usernames with admin
#   mods/mod-list.json       which mods are enabled (the portal sync reads it)
#   map-gen-settings.json    world generation — applied only at map creation
#   map-settings.json        runtime balance — applied only at map creation
#
# Either of those two also OVERRIDES FACTORIO_MAP_PRESET, which is the
# no-JSON way to ask for one of the game's built-in world characters.

set -euo pipefail

ROOT=/factorio
SETTINGS="$ROOT/server-settings.json"
ADMINLIST="$ROOT/server-adminlist.json"
SAVES_DIR="$ROOT/saves"
MODS_DIR="$ROOT/mods"
MOD_LIST="$MODS_DIR/mod-list.json"
SAVE_NAME="${FACTORIO_SAVE_NAME:-cfg-world}"
SAVE_FILE="$SAVES_DIR/${SAVE_NAME}.zip"
FACTORIO_BIN=/opt/factorio/bin/x64/factorio
CONFIG_DIR="$ROOT/config"
CONFIG_INI="$CONFIG_DIR/config.ini"

# The platform service mod bundled into this image (built from mod/ by the
# Dockerfile). Never fetched from the portal — the image is its source.
LINK_NAME=crit-fumble-link
LINK_BUNDLE_DIR=/opt/cfg/mods

# Mods that ship with the game/DLC (or with this image) and must never be
# looked up on the mod portal.
SYNC_EXCLUDE='["base","elevated-rails","quality","space-age","crit-fumble-link"]'

log() { echo "[cfg-server-factorio] $*"; }
die() { echo "[cfg-server-factorio] ERROR: $*" >&2; exit 1; }

mkdir -p "$SAVES_DIR" "$CONFIG_DIR" "$MODS_DIR"

# ── 1. config.ini — point Factorio's WRITE dir at the mounted volume ────────
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
  log "seeding $CONFIG_INI (write-data → $ROOT)"
  cat > "$CONFIG_INI" <<-EOF
	[path]
	read-data=/opt/factorio/data
	write-data=$ROOT
	EOF
fi

# ── 2. Mods ─────────────────────────────────────────────────────────────────
#
# The single manifest is Factorio's own mods/mod-list.json. core-server writes
# it for hosted installs; a self-hoster can mount one, or seed it from
# FACTORIO_MODS (comma-separated mod names) on first boot. The sync step then
# downloads whatever is enabled there but has no zip yet.

# Add/ensure-enabled or remove one entry in mod-list.json.
ensure_mod_list_entry() {
  local name="$1" mode="$2" tmp
  [ -f "$MOD_LIST" ] || echo '{"mods":[{"name":"base","enabled":true}]}' > "$MOD_LIST"
  tmp=$(mktemp)
  if [ "$mode" = "absent" ]; then
    jq --arg n "$name" '.mods |= map(select(.name != $n))' "$MOD_LIST" > "$tmp"
  else
    jq --arg n "$name" '
      if any(.mods[]; .name == $n)
      then .mods |= map(if .name == $n then .enabled = true else . end)
      else .mods += [{ name: $n, enabled: true }]
      end' "$MOD_LIST" > "$tmp"
  fi
  mv "$tmp" "$MOD_LIST"
}

# 2a. Seed mod-list.json from FACTORIO_MODS (first boot only — the file wins).
if [ ! -f "$MOD_LIST" ] && [ -n "${FACTORIO_MODS:-}" ]; then
  log "seeding $MOD_LIST from FACTORIO_MODS"
  jq -n --arg mods "$FACTORIO_MODS" '{
    mods: ([{ name: "base", enabled: true }] +
           ($mods | split(",") | map(gsub("^\\s+|\\s+$"; "")) |
            map(select(length > 0)) | map({ name: ., enabled: true })))
  }' > "$MOD_LIST"
fi

# 2b. The bundled crit-fumble-link service mod.
#
# ⚠️ Default OFF, deliberately: Factorio requires every CONNECTING CLIENT to
# run the exact same mod set as the server. Until crit-fumble-link is
# published on the Factorio mod portal (where the client's "Sync mods with
# server" button can fetch it), enabling this makes the server unjoinable —
# "missing mod" with no way to install it. core-server flips it on
# per-installation once the portal listing exists.
link_zip=$(compgen -G "$LINK_BUNDLE_DIR/${LINK_NAME}_*.zip" | head -n 1 || true)
if [ "${FACTORIO_SERVICE_MOD:-false}" = "true" ]; then
  [ -n "$link_zip" ] || die "FACTORIO_SERVICE_MOD=true but no ${LINK_NAME} bundle in $LINK_BUNDLE_DIR"
  target="$MODS_DIR/$(basename "$link_zip")"
  if [ ! -f "$target" ]; then
    # Version changed (or first install): drop stale copies, install bundled.
    rm -f "$MODS_DIR/${LINK_NAME}"_*.zip
    cp "$link_zip" "$target"
    log "installed service mod $(basename "$link_zip")"
  fi
  ensure_mod_list_entry "$LINK_NAME" present
else
  # Opt-out is idempotent: remove any previously-installed copy so the mod
  # set matches what clients will be asked for.
  if compgen -G "$MODS_DIR/${LINK_NAME}_*.zip" > /dev/null; then
    rm -f "$MODS_DIR/${LINK_NAME}"_*.zip
    log "removed service mod (FACTORIO_SERVICE_MOD != true)"
  fi
  [ -f "$MOD_LIST" ] && ensure_mod_list_entry "$LINK_NAME" absent
fi

# 2c. Download enabled-but-missing mods from the mod portal.
#
# Auth: mod portal downloads are account-gated. FACTORIO_USERNAME +
# FACTORIO_TOKEN (from factorio.com → profile, or player-data.json) are
# required for the download step only — everything else works without them.
#
# Failing a download is FATAL, not a warning: booting a save without a mod it
# was played with silently deletes that mod's entities from the map. Downtime
# is recoverable; a stripped save is not.
sync_mods() {
  [ -f "$MOD_LIST" ] || return 0
  local wanted
  wanted=$(jq -r --argjson skip "$SYNC_EXCLUDE" \
    '.mods[] | select(.enabled == true) | .name
     | select(. as $n | $skip | index($n) | not)' "$MOD_LIST")
  [ -n "$wanted" ] || return 0

  local missing=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    compgen -G "$MODS_DIR/${name}_*.zip" > /dev/null || missing+=("$name")
  done <<< "$wanted"
  [ "${#missing[@]}" -gt 0 ] || return 0

  if [ -z "${FACTORIO_USERNAME:-}" ] || [ -z "${FACTORIO_TOKEN:-}" ]; then
    die "mod-list.json enables mods with no zip present (${missing[*]}) and \
FACTORIO_USERNAME/FACTORIO_TOKEN are unset, so they cannot be downloaded. \
Refusing to boot without them — loading a save without its mods destroys \
mod-built entities."
  fi

  # Portal releases declare compatibility as major.minor ("2.0").
  local server_version major_minor
  server_version=$("$FACTORIO_BIN" --version | grep -oEm1 '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  major_minor=${server_version%.*}

  rm -f "$MODS_DIR"/.*.part 2>/dev/null || true
  local encoded release file_name sha1 download_url tmp user_enc token_enc
  user_enc=$(jq -rn --arg v "$FACTORIO_USERNAME" '$v|@uri')
  token_enc=$(jq -rn --arg v "$FACTORIO_TOKEN" '$v|@uri')
  for name in "${missing[@]}"; do
    log "downloading mod: $name (Factorio $major_minor)"
    encoded=$(jq -rn --arg n "$name" '$n|@uri')
    release=$(curl -fsSL "https://mods.factorio.com/api/mods/${encoded}" \
      | jq --arg fv "$major_minor" \
          '[.releases[] | select(.info_json.factorio_version == $fv)]
           | sort_by(.released_at) | last') \
      || die "mod portal lookup failed for $name"
    if [ -z "$release" ] || [ "$release" = "null" ]; then
      die "no release of $name is compatible with Factorio $major_minor"
    fi
    file_name=$(jq -r '.file_name' <<<"$release")
    sha1=$(jq -r '.sha1' <<<"$release")
    download_url=$(jq -r '.download_url' <<<"$release")
    tmp="$MODS_DIR/.${file_name}.part"
    curl -fsSL -o "$tmp" \
      "https://mods.factorio.com${download_url}?username=${user_enc}&token=${token_enc}" \
      || { rm -f "$tmp"; die "download failed for $name"; }
    if [ "$(sha1sum "$tmp" | cut -d' ' -f1)" != "$sha1" ]; then
      rm -f "$tmp"
      die "checksum mismatch for $name — usually an invalid FACTORIO_USERNAME/\
FACTORIO_TOKEN (the portal serves an HTML login page instead of the zip)"
    fi
    mv "$tmp" "$MODS_DIR/$file_name"
    log "installed $file_name"
  done
}
sync_mods

# ── 3. server-settings.json ─────────────────────────────────────────────────
if [ -f "$SETTINGS" ]; then
  log "using existing server-settings.json at $SETTINGS"
else
  log "generating server-settings.json from env"
  # Heredoc with bash variable expansion. Use jq-style booleans
  # explicitly so 'false' / 'true' aren't quoted as strings — Factorio
  # rejects 'true' (string) where it expects a bool.
  #
  # username/token double as the factorio.com identity for PUBLIC server
  # listing — a server with visibility.public=true is rejected by the
  # matchmaking API without them.
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
  "username": "${FACTORIO_USERNAME:-}",
  "password": "",
  "token": "${FACTORIO_TOKEN:-}",
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

# ── 4. server-adminlist.json ────────────────────────────────────────────────
# Seed-if-absent only: in-game /promote and /demote persist to this same
# file, so regenerating it from env on every boot would silently undo them.
if [ ! -f "$ADMINLIST" ] && [ -n "${FACTORIO_ADMINS:-}" ]; then
  log "seeding server-adminlist.json from FACTORIO_ADMINS"
  jq -n --arg a "$FACTORIO_ADMINS" \
    '$a | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' \
    > "$ADMINLIST"
fi

# ── 5. Create a fresh save if none exists ───────────────────────────────────
# One-shot — subsequent boots reuse the latest save (autosaves count, so a
# previously-loaded server keeps its progress across container restarts).
# Runs AFTER mod assembly so a modded world generates with its mods active
# (mod ores, terrain, etc.), and honors mounted map-gen/map-settings files.
if ! compgen -G "$SAVES_DIR/*.zip" > /dev/null; then
  CREATE_FLAGS=()
  if [ -f "$ROOT/map-gen-settings.json" ]; then
    CREATE_FLAGS+=(--map-gen-settings "$ROOT/map-gen-settings.json")
    log "using map-gen-settings.json for world creation"
  fi
  if [ -f "$ROOT/map-settings.json" ]; then
    CREATE_FLAGS+=(--map-settings "$ROOT/map-settings.json")
    log "using map-settings.json for world creation"
  fi
  # FACTORIO_MAP_PRESET names one of the game's OWN map-gen presets
  # (data/base/prototypes/map-gen-presets.lua): death-world,
  # death-world-marathon, rich-resources, marathon, rail-world,
  # ribbon-world, lakes, island — or `default`, which changes nothing.
  #
  # Preferred over hand-written JSON because a preset carries BOTH halves
  # of a world's character in one name — the basic_settings that land in
  # map-gen-settings.json (enemy frequency/size, starting area) AND the
  # advanced_settings that land in map-settings.json (evolution factors,
  # pollution ageing). Verified against 2.0.77: `--preset death-world`
  # reproduces every documented death-world value on both sides, so the
  # platform never has to carry a copy of upstream's numbers.
  #
  # Pre-written files win, per this script's standing contract — if the
  # operator mounted either one they are configuring by hand, and a preset
  # silently merging into that is the confusing outcome.
  if [ -n "${FACTORIO_MAP_PRESET:-}" ]; then
    if [ "${#CREATE_FLAGS[@]}" -gt 0 ]; then
      log "ignoring FACTORIO_MAP_PRESET=${FACTORIO_MAP_PRESET} — mounted map-gen/map-settings JSON wins"
    else
      CREATE_FLAGS+=(--preset "$FACTORIO_MAP_PRESET")
      log "using map-gen preset '${FACTORIO_MAP_PRESET}' for world creation"
    fi
  fi
  log "no save found — creating $SAVE_FILE"
  "$FACTORIO_BIN" --config "$CONFIG_INI" --create "$SAVE_FILE" "${CREATE_FLAGS[@]}"
  # A bad preset name exits 1 (`Preset "x" doesn't exist.`) and `set -e`
  # already stops us there. This guards the other shape: --create
  # reporting success while leaving no file behind. Without it the next
  # line launches --start-server-load-latest against an empty saves/ dir,
  # and the container dies complaining about no save rather than about
  # whatever actually went wrong during creation.
  [ -f "$SAVE_FILE" ] || die "map creation reported success but left no save at $SAVE_FILE"
fi

# ── 6. Launch ───────────────────────────────────────────────────────────────
# RCON — the platform's admin channel (activity probe player counts, the
# Avatars roster, and the crit-fumble-link remote interface). Enabled only
# when a password is provided (core-server passes a per-install derived one);
# a bare `docker run` without it gets no RCON listener at all. The port is
# container-internal — core-server dials it by container name over the shared
# docker network; it is NEVER published to a host port, so the derived
# password is a second gate, not the only one.
LAUNCH_FLAGS=()
if [ -n "${FACTORIO_RCON_PASSWORD:-}" ]; then
  LAUNCH_FLAGS+=(--rcon-port "${FACTORIO_RCON_PORT:-27015}" --rcon-password "$FACTORIO_RCON_PASSWORD")
  log "RCON enabled on tcp/${FACTORIO_RCON_PORT:-27015} (docker-network only)"
fi
if [ -f "$ADMINLIST" ]; then
  LAUNCH_FLAGS+=(--server-adminlist "$ADMINLIST")
fi

log "starting Factorio server on UDP port ${FACTORIO_PORT:-34197}"
exec "$FACTORIO_BIN" \
  --config "$CONFIG_INI" \
  --start-server-load-latest \
  --port "${FACTORIO_PORT:-34197}" \
  --server-settings "$SETTINGS" \
  "${LAUNCH_FLAGS[@]}"
