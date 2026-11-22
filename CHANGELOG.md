# Changelog

## Unreleased
- **Workday worker out of the box:** docker `worker-workday` service (command `worker workday`, heartbeat healthcheck `/tmp/connector-workday.heartbeat`, enabled by default) and native `connector-workday.service` (installed and enabled by install-native, removed by uninstall-native, available in `connectorctl logs|start|stop|restart workday`). The worker stays idle until the feature is enabled in the app settings; no manual compose/`connector.yaml` edits needed (a custom `connector.yaml` mount stays optional).
- `connectorctl sync-units`: installs and starts missing systemd units on existing native installs.
- **Migration:** docker — bump `CONNECTOR_VERSION`, replace `docker-compose.yml` with the one from the release, `docker compose pull && docker compose up -d --remove-orphans`. Native — update, then `sudo connectorctl sync-units`.
- Tests: `tests/test-workday.sh` (+ CI, shellcheck).

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
