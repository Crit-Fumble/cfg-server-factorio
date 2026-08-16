# cfg-server-factorio

Thin container around the official [Factorio dedicated server](https://factorio.com/download/headless). Used by Crit-Fumble's Server Manager to host per-user Factorio instances under the `kind=factorio` adapter.

No Steam dependency — just the upstream headless tarball, extracted onto `debian-slim`, run as a non-root user (`uid=1000`), with saves, mods and config living in a `/factorio` volume. Mods are downloaded from the [Factorio mod portal](https://mods.factorio.com) at boot (see below); the only mod baked into the image is the optional, default-off `crit-fumble-link` service mod.

## Run standalone

```sh
docker run --rm -p 34197:34197/udp -v $(pwd)/saves:/factorio \
  ghcr.io/crit-fumble/cfg-server-factorio:latest
```

First boot generates a fresh `cfg-world.zip` (default settings — see env vars). The server autosaves every 10 minutes and on clean exit; `docker stop` forwards SIGTERM via tini so the final save completes before shutdown.

**Factorio uses UDP, not TCP.** Caddy + HTTP proxies don't apply — the player connects via Factorio's "Connect to address" UI using `<host>:<udp-port>`. The host needs `ufw allow <port>/udp` (or equivalent) for any port that should accept connections.

## Config knobs (env vars)

| var | default | meaning |
|---|---|---|
| `FACTORIO_SAVE_NAME` | `cfg-world` | save basename for the first auto-creation |
| `FACTORIO_PORT` | `34197` | listen port (UDP) |
| `FACTORIO_MAX_PLAYERS` | `16` | player cap; `0` = unlimited |
| `FACTORIO_VISIBILITY_PUBLIC` | `false` | list on factorio.com matchmaking |
| `FACTORIO_VISIBILITY_LAN` | `true` | broadcast on LAN |
| `FACTORIO_REQUIRE_USER_VERIFICATION` | `true` | require Factorio.com auth |
| `FACTORIO_AUTOSAVE_INTERVAL` | `10` | minutes between autosaves |
| `FACTORIO_NAME` | _Crit-Fumble Factorio Server_ | shown in server browser |
| `FACTORIO_DESCRIPTION` | _Hosted by Crit-Fumble_ | shown in server browser |
| `FACTORIO_PASSWORD` | _(empty)_ | server password |
| `FACTORIO_MODS` | _(empty)_ | comma-separated mod names; seeds `mods/mod-list.json` on first boot |
| `FACTORIO_ADMINS` | _(empty)_ | comma-separated Factorio usernames; seeds `server-adminlist.json` on first boot |
| `FACTORIO_USERNAME` | _(empty)_ | factorio.com username — needed for mod downloads + public listing |
| `FACTORIO_TOKEN` | _(empty)_ | factorio.com token (profile page / `player-data.json`) |
| `FACTORIO_SERVICE_MOD` | `false` | install + enable the bundled `crit-fumble-link` service mod |
| `FACTORIO_MAP_PRESET` | _(empty)_ | one of the game's built-in map-gen presets (e.g. `death-world`) — applied only when the first map is created |

The env vars are **first-boot seeds**. Every file below can instead be pre-written into the volume (core-server does exactly that for hosted installs) and always wins over its env template:

| file in `/factorio` | role |
|---|---|
| `server-settings.json` | full server config |
| `server-adminlist.json` | JSON array of admin usernames — in-game `/promote` persists here too, so it is never regenerated |
| `mods/mod-list.json` | which mods are enabled (Factorio's own format; the boot sync reads it) |
| `map-gen-settings.json` | world generation — applied only when the first map is created |
| `map-settings.json` | runtime balance (pollution, biters, …) — applied only at map creation |

## World presets

`FACTORIO_MAP_PRESET` names one of Factorio's **own** map-gen presets, so a world
gets its character from a single word instead of two hand-maintained JSON files:

`default` (changes nothing) · `death-world` · `death-world-marathon` · `rich-resources` ·
`marathon` · `rail-world` · `ribbon-world` · `lakes` · `island`

The list comes from `data/base/prototypes/map-gen-presets.lua` inside the image, which
is the authority — check there after a Factorio upgrade rather than trusting this line.

A preset is the better default because it carries **both halves** of a world's
character at once. `death-world`, for example, sets enemy frequency/size and the
starting area (the `map-gen-settings.json` half) *and* the evolution + pollution
factors (the `map-settings.json` half). Verified against 2.0.77: creating with
`--preset death-world` reproduces every documented death-world value on both sides,
so nothing here has to carry a copy of upstream's numbers.

⚠️ It applies **only at first map creation**, like the two JSON files — changing it
later does nothing to an existing save. And if either JSON file is present the preset
is ignored (logged), keeping the "pre-written files always win" rule above intact.

An unknown preset name makes Factorio exit 1 (`Preset "x" doesn't exist.`), which
fails the boot immediately — the name is validated by the game, not by this image, so
it never drifts from what the installed version actually ships.

## Mods

`mods/mod-list.json` is the single manifest. At boot the entrypoint downloads every enabled mod that has no zip in `/factorio/mods` yet, from the Factorio mod portal, verifying each file's sha1. Portal downloads are account-gated, so `FACTORIO_USERNAME` + `FACTORIO_TOKEN` must be set for the sync to work.

A missing mod that cannot be downloaded **fails the boot on purpose**: loading a save without a mod it was played with silently deletes that mod's entities from the map. Downtime is recoverable; a stripped save is not.

Already-downloaded mods are never re-downloaded or auto-updated — drop the zip (or bump `mod-list.json` and delete the old zip) to update. Dependencies are not auto-resolved; list them explicitly.

## Admins

`server-adminlist.json` (JSON array of Factorio usernames) is passed via `--server-adminlist`. Seed it with `FACTORIO_ADMINS` or pre-write the file; in-game `/promote` / `/demote` (and RCON's) persist to the same file, which is why the entrypoint seeds it only when absent.

## The `crit-fumble-link` service mod

`mod/crit-fumble-link/` is a control-stage-only mod (no prototypes — adding or removing it never alters a map) bundled into the image. It is the platform's service-admin channel, the Factorio analogue of Crit-Fumble's FoundryVTT plugin — with one big difference: Factorio mods are fully sandboxed (no network, no filesystem reads), so the platform **pulls** over RCON instead of the mod phoning home:

```
/silent-command rcon.print(remote.call("cfg", "status"))   → one JSON line
/silent-command rcon.print(remote.call("cfg", "announce", "msg"))
```

Note Factorio warns once per session before the first Lua console command ("using Lua console commands will disable achievements — repeat to proceed"); an RCON client must issue one throwaway command to prime the channel.

⚠️ **`FACTORIO_SERVICE_MOD` defaults to `false`, deliberately.** Factorio requires every connecting client to run the exact same mod set as the server. Until `crit-fumble-link` is published on the mod portal (where the client's "Sync mods with server" button can fetch it), enabling it makes the server unjoinable. Turning it off again is safe and idempotent — the entrypoint removes the zip and its `mod-list.json` entry.

## CFG-hosted usage

> ℹ️ **`cfg-core-server` is a private CFG repo.** The paths below are named for orientation —
> they are not links you can open. **Nothing in this repo depends on them:** the container runs
> standalone with the `docker run` above, and the CFG integration is one consumer of it, not a
> requirement.

Core-server provisions one container per `UserAppInstallation` via the Server Manager kind-registry:

- adapter: `cfg-core-server/src/services/server-manager/kinds/factorio.ts`
- launcher: `cfg-core-server/src/services/factorio/launch.ts`
- volume: `/mnt/cfg_user_storage/users/<userId>/installations/<installationId>/data/` → `/factorio`

Billing tick (CT per uptime hour) is owned by the adapter, same shape as `kinds/foundryvtt.ts` and `kinds/terraria.ts`.

## Build

```sh
docker build -t cfg-server-factorio:local .
# Pin to a specific Factorio version:
docker build --build-arg FACTORIO_VERSION=2.0.76 -t cfg-server-factorio:2.0.76 .
```

CI publishes `ghcr.io/crit-fumble/cfg-server-factorio` on main + tagged releases (see `.github/workflows/build.yml`).

## License

AGPL-3.0-only. Factorio itself is © Wube Software; the dedicated server binary is freely redistributable per [Wube's terms](https://www.factorio.com/terms-of-service). This repo contains only the thin packaging — none of Wube's intellectual property is vendored.
