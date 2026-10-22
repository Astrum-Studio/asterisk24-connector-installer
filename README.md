# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector** — no source code, only binaries and Docker images.

| Artifact | Where |
|----------|--------|
| Native binary | [GitHub Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) (`connector-linux-amd64.tar.gz`) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (private — use deploy token) |

## Install

С любой директории на сервере (в т.ч. `/`). **Не сохраняйте скрипт в файл** — pipe в `bash`:

**Native:**

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode native --version "${VER}" --yes
```

**Docker** (нужен `GHCR_TOKEN`):

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode docker --version "${VER}" --ghcr-token "$GHCR_TOKEN" --yes
```

Autoinstaller клонирует этот репозиторий на тег `VER` в `/opt/asterisk24-connector-installer` и вызывает `install.sh`.

<details>
<summary>Альтернатива: git clone</summary>

```bash
VER=v1.0.0
git clone --depth 1 --branch "${VER}" https://github.com/Astrum-Studio/asterisk24-connector-installer.git
cd asterisk24-connector-installer
sudo bash install.sh --mode native --version "${VER}" --yes
```

</details>

## Contents

- `scripts/autoinstaller.sh` — one-liner entrypoint
- `install.sh` — вызывается из клона или autoinstaller
- `docker-compose.yml` — five services (app + workers) + Postgres
- `deploy/systemd/` — unit templates for native binary layout
- `scripts/init-env.sh` — generates `.env` and `db.env`

Connector source is proprietary and not published.
