# Asterisk24 Connector Installer

Public installer for **Astrum Bitrix24 Asterisk Connector**.

| Artifact | Where |
|----------|--------|
| Native binary | [Releases](https://github.com/Astrum-Studio/asterisk24-connector-installer/releases) |
| Docker image | `ghcr.io/astrum-studio/asterisk24-connector` (public) |

## Install

**Native:**

```bash
VER=v1.0.4
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/releases/download/${VER}/autoinstaller.sh" \
  | bash -s -- --mode native --version "${VER}" --yes
```

**Docker:**

```bash
VER=v1.0.4
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/releases/download/${VER}/autoinstaller.sh" \
  | bash -s -- --mode docker --version "${VER}" --yes
```

Скрипт с **Releases** (не `raw.githubusercontent.com` — у старых тегов там кэш). Каталог: `/opt/asterisk24-connector-installer` или `/opt/asterisk24-connector` (native).

## Воркер workday (Timeman → QueuePause)

Служба `worker-workday` (docker) / `connector-workday` (native) входит в установку и включена по умолчанию.
Пока функция не включена в настройках приложения (настройки приходят через sync в `portals.settings_json`),
воркер ничего не делает. Редактировать `connector.yaml` и compose вручную не нужно: монтирование
собственного `connector.yaml` остаётся опциональным (пример в комментарии в `docker-compose.yml`).

Healthcheck (docker): heartbeat `/tmp/connector-workday.heartbeat`, `--max-age 120`.
Логи (native): `connectorctl logs workday -f`.

**Установленные ранее:**

- Docker: поднимите `CONNECTOR_VERSION` в `.env` и обновите compose-файл из релиза, затем
  `docker compose pull && docker compose up -d --remove-orphans` — появится новый сервис.
  Если используется `connectorctl update` из механизма обновления, он сам подтягивает свежий `docker-compose.yml`
  из тега и делает `up -d`.
- Native: после обновления бинарника и скриптов установщика выполните `sudo connectorctl sync-units` — он
  доустановит и запустит недостающий `connector-workday` (уже установленные службы не трогает).
  Повторная установка (`install-native.sh` / `connectorctl update --source`) создаёт юнит сама.

Тесты: `bash tests/test-workday.sh`.
