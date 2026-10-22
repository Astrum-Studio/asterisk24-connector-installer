# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector**.

| Artifact | Where |
|----------|--------|
| Native binary | [Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (public) |

## Install

**Native:**

```bash
VER=v1.0.3
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/releases/download/${VER}/autoinstaller.sh" \
  | bash -s -- --mode native --version "${VER}" --yes
```

**Docker:**

```bash
VER=v1.0.3
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/releases/download/${VER}/autoinstaller.sh" \
  | bash -s -- --mode docker --version "${VER}" --yes
```

Скрипт с **Releases** (не `raw.githubusercontent.com` — у старых тегов там кэш). Каталог: `/opt/asterisk24-connector-installer` или `/opt/asterisk24-connector` (native).
