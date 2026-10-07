# Contributing to cfg-server-factorio

This repo is a thin container around the official Factorio dedicated server —
a `Dockerfile`, an `entrypoint.sh`, and the small `mod/crit-fumble-link/`
service mod (plain Lua, zipped at image build). There is no Node toolchain
and no test suite; **Docker is the only prerequisite**.

## Build & run locally

```bash
docker build -t cfg-server-factorio:local .
docker run --rm -p 34197:34197/udp -v "$PWD/saves:/factorio" cfg-server-factorio:local
```

The README documents the env-var config knobs and the CFG-hosted usage. When
changing `entrypoint.sh`, verify by hand that a fresh container still
auto-creates a world, that a mounted `server-settings.json` still takes
precedence over the env template, and that `docker stop` completes the final
autosave (SIGTERM via tini). When touching the mod pipeline, also verify that
`FACTORIO_SERVICE_MOD=true` installs + loads `crit-fumble-link` (the boot log
shows its control.lua checksum), that unsetting it removes the zip *and* its
`mod-list.json` entry, and that a mod-list entry with no zip and no
`FACTORIO_USERNAME`/`FACTORIO_TOKEN` fails the boot loudly instead of
starting without the mod.

Any change under `mod/crit-fumble-link/` needs an `info.json` version bump and
a mod-portal upload of that same version (`releases/init_upload`). Joining
clients fetch the mod from the portal via "Sync mods with server", so the
image's bundled copy and the portal's copy of a version must be identical.
Compare them by diffing file contents, never zip sha1, because builds re-zip
with fresh timestamps. Uploads use the CritFumbleGaming account's portal API
key, `FACTORIO_API_KEY` in CFG's private dev-tools `.env`, which also carries
the Edit Mods usage. It never enters this repo, and neither it nor a signed
upload URL is ever printed.

⚠️ On Apple Silicon, build with `--platform linux/amd64` (as CI does) —
a default build produces an arm64 rootfs and the x86_64 Factorio binary
dies with a Rosetta ELF-loader error at boot.

## Commit messages & PRs

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat`, `fix`, `chore`, `docs`, `ci`, `build`). Fork, branch from `next` (the release-candidate branch;
`main` is released truth and only ever fast-forwarded to),
describe how you tested the container, and explain the *why* in the PR
description.

## License

Contributions are accepted under [AGPL-3.0-only](LICENSE). This repo must stay
thin packaging — never vendor any of Wube's intellectual property.
