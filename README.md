# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector** — no source code, only binaries and Docker images.

| Artifact | Where |
|----------|--------|
| Native binary | [GitHub Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) (`connector-linux-amd64.tar.gz`) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (private — use deploy token) |

## Install

На целевом сервере можно стартовать **из любой папки** (часто `/`). Один скачанный `install.sh` сам подтянет полный установщик в `/opt/asterisk24-connector-installer` и продолжит.

```bash
cd /
INSTALLER_TAG=v1.0.1
BINARY_TAG=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${INSTALLER_TAG}/install.sh" -o install.sh
sudo bash install.sh --mode native --version "${BINARY_TAG}" --yes
```

Docker (нужен токен GHCR):

```bash
cd /
INSTALLER_TAG=v1.0.1
BINARY_TAG=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${INSTALLER_TAG}/install.sh" -o install.sh
sudo bash install.sh --mode docker --version "${BINARY_TAG}" --ghcr-token "$GHCR_TOKEN" --yes
```

`INSTALLER_TAG` — тег репозитория установщика (скрипты). `BINARY_TAG` — релиз с бинарником на [Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) (сейчас `v1.0.0`).

**One-liner без файла в `/`:**

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode native --version "${VER}" --yes
```

**Или клон:**

```bash
VER=v1.0.0
git clone --depth 1 --branch "${VER}" https://github.com/Astrum-Studio/asterisk24-connector-installer.git
cd asterisk24-connector-installer
sudo bash install.sh --mode native --version "${VER}" --yes
```

## Contents

- `install.sh` — entrypoint
- `docker-compose.yml` — five services (app + workers) + Postgres
- `deploy/systemd/` — unit templates for native binary layout
- `scripts/init-env.sh` — generates `.env` and `db.env`

Connector source is proprietary and not published.
