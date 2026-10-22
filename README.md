# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector** — no source code, only binaries and Docker images.

| Artifact | Where |
|----------|--------|
| Native binary | [GitHub Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) (`connector-linux-amd64.tar.gz`) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (private — use deploy token) |

## Install

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/install.sh" -o install.sh
# Verify SHA256SUMS from the release, then:
sudo bash install.sh --mode native --version "${VER}"
```

Docker:

```bash
sudo bash install.sh --mode docker --version v1.0.0 --ghcr-token "$GHCR_TOKEN"
```

## Contents

- `install.sh` — entrypoint
- `docker-compose.yml` — five services (app + workers) + Postgres
- `deploy/systemd/` — unit templates for native binary layout
- `scripts/init-env.sh` — generates `.env` and `db.env`

Connector source is proprietary and not published.
