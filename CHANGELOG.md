# Changelog

## Unreleased

- `connectorctl update`: real updates for **native and docker** — `--check` (latest version + CHANGELOG, exit code 0/10/11), minor/patch within the current major by default, `--allow-major`, `--version vX.Y.Z` (including downgrade). Native: release binary + `SHA256SUMS` verification, atomic swap, previous version kept in `.rollback/`. Docker: `CONNECTOR_VERSION` in `.env`, `compose pull` + `up -d`.
- Safety: lock file, backup before update, migrations, health-check, **automatic rollback** (DB restored from the backup only if migrations ran).
- `connectorctl auto-update enable|disable|status`: optional systemd timer (cron fallback), minor/patch only, time window, off by default; results in journal and `status`.
- Docker installs now get `connectorctl` and `.install-meta`.
- Offline tests: `tests/test-update.sh`.

## v1.0.3 (2026-10-22) — supported

- Fix native install as root: `migrate` via `runuser` (was `${SUDO} -u` → `-u: command not found`).

## v1.0.1 (2026-10-22)

- **Install:** `curl` autoinstaller from **GitHub Releases** (not `raw.githubusercontent.com`).
- Native: binary + `SHA256SUMS` from this release; Docker: public `ghcr.io/astrum-studio/asterisk24-connector`.
- Autoinstaller: no `git`, works with `curl | bash -s`.
- Optional `--ghcr-token` only for private registries.

## v1.0.0 — deprecated

Broken install paths (raw CDN cache, bad `SHA256SUMS` paths, piped autoinstaller). **Use v1.0.1.**

## v1.0.3
- Alembic migrations in native binary tarball.

## v1.0.4
- connectorctl + uninstall-native; install symlink to /usr/local/bin.


## v1.0.7
- Fix: add missing scripts/lib/detect-recordings.sh (connectorctl failed to source it).
- Connector: opt-in AMI inbound redirect, Bitrix workday queue pause, call trace (see connector release).
