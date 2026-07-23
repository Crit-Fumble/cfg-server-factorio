# Contributing to cfg-server-factorio

This repo is a thin container around the official Factorio dedicated server —
a `Dockerfile`, an `entrypoint.sh`, and nothing else. There is no Node
toolchain and no test suite; **Docker is the only prerequisite**.

## Build & run locally

```bash
docker build -t cfg-server-factorio:local .
docker run --rm -p 34197:34197/udp -v "$PWD/saves:/factorio" cfg-server-factorio:local
```

The README documents the env-var config knobs and the CFG-hosted usage. When
changing `entrypoint.sh`, verify by hand that a fresh container still
auto-creates a world, that a mounted `server-settings.json` still takes
precedence over the env template, and that `docker stop` completes the final
autosave (SIGTERM via tini).

## Commit messages & PRs

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat`, `fix`, `chore`, `docs`, `ci`, `build`). Fork, branch from `main`,
describe how you tested the container, and explain the *why* in the PR
description.

## License

Contributions are accepted under [AGPL-3.0-only](LICENSE). This repo must stay
thin packaging — never vendor any of Wube's intellectual property.
