# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector** — бинарник и Docker-образ без исходного кода.

| Artifact | Where |
|----------|--------|
| Native binary | [Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) `connector-linux-amd64.tar.gz` |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (**public**) |

## Install

Одна команда, без `git`, без сохранения скрипта в файл:

**Native (systemd):**

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode native --version "${VER}" --yes
```

**Docker (Compose):**

```bash
VER=v1.0.0
curl -fsSL "https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/${VER}/scripts/autoinstaller.sh" \
  | sudo bash -s -- --mode docker --version "${VER}" --yes
```

Каталог: `/opt/asterisk24-connector-installer` (compose + `.env`) или `/opt/asterisk24-connector` (native).

`--ghcr-token` нужен только если образ снова сделают приватным.

## Contents

- `scripts/autoinstaller.sh` — entrypoint
- `docker-compose.yml` — app + workers + Postgres
- `deploy/systemd/` — native units
