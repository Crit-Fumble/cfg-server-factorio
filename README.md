# cfg-server-factorio

Thin container around the official [Factorio dedicated server](https://factorio.com/download/headless). Used by Crit-Fumble's Server Manager to host per-user Factorio instances under the `kind=factorio` adapter.

No mods baked in, no Steam dependency — just the upstream headless tarball, extracted onto `debian-slim`, run as a non-root user (`uid=1000`), with saves living in a `/factorio` volume.

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

A user-supplied `/factorio/server-settings.json` (e.g. mounted in by core-server) takes precedence over the env-driven template.

## CFG-hosted usage

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
