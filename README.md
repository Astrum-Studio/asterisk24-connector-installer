# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector** — no source code, only binaries and Docker images.

| Artifact | Where |
|----------|--------|
| Native binary | [GitHub Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) (`connector-linux-amd64.tar.gz`) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (private — use deploy token) |

## Install

**One-liner (recommended):**

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode native --version "${VER}" --yes
```

Docker:

```bash
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode docker --version "${VER}" --ghcr-token "$GHCR_TOKEN" --yes
```

**Or clone the installer repo** (not a lone `install.sh` file):

```bash
VER=v1.0.0
git clone --depth 1 --branch "${VER}" https://github.com/Astrum-Studio/asterisk24-connector-installer.git
cd asterisk24-connector-installer
sudo bash install.sh --mode native --version "${VER}" --yes
```

A downloaded-only `install.sh` will auto-clone into `/opt/asterisk24-connector-installer` and continue.

## Contents

- `install.sh` — entrypoint
- `docker-compose.yml` — five services (app + workers) + Postgres
- `deploy/systemd/` — unit templates for native binary layout
- `scripts/init-env.sh` — generates `.env` and `db.env`

Connector source is proprietary and not published.
