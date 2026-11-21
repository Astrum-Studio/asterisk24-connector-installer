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

## Обновление

Команда `connectorctl` ставится вместе с коннектором (и для native, и для docker). Версии берутся из GitHub Releases этого репозитория (токен не нужен; при лимите API есть запасные источники).

```bash
sudo connectorctl update --check          # только проверить: последняя версия + CHANGELOG между версиями
sudo connectorctl update                  # обновить до последней minor/patch в пределах текущей мажорной
sudo connectorctl update --allow-major    # перейти на новую мажорную версию
sudo connectorctl update --version v1.0.5 # конкретная версия, в том числе откат на старую
```

Коды выхода `update --check`: `0` — актуально, `10` — есть обновление, `11` — есть только новая мажорная, `1` — ошибка.
Коды `update`: `0` ок, `1` ошибка до изменений, `3` не удалось, **выполнен откат**, `4` откат не удался, `5` уже идёт другое обновление.

Что делает обновление:

1. Берёт замок (два обновления одновременно не идут) и делает бэкап (`connectorctl backup`: БД + `.env`). `--skip-backup` отключает бэкап.
2. **Native:** скачивает бинарник и `SHA256SUMS` релиза, проверяет сумму, заменяет файлы коннектора (`.env`, `config/`, `.install-meta` не трогаются; прежняя версия остаётся в `<install-dir>/.rollback/`), выполняет миграции, перезапускает службы. **Docker:** меняет `CONNECTOR_VERSION` (и `CONNECTOR_IMAGE_TAG`, если он есть) в `.env`, `docker compose pull`, миграции, `up -d`.
3. Проверяет здоровье (`/health`, службы/контейнеры). Если проверка не прошла — **автоматический откат** на прежнюю версию (код/образ и `.env`). Если миграции успели изменить схему БД, БД восстанавливается из бэкапа (с предупреждением: данные после бэкапа теряются).
4. Записывает версию в `.install-meta` и обновляет скрипты установщика из релиза (в git-клоне скрипты не трогаются).

Понижение версии (`--version` старее установленной) не откатывает схему БД — при проблемах восстановите БД из бэкапа.

`connectorctl update --source DIR` оставлен для совместимости (переустановка native из каталога установщика).

### Автообновление (по умолчанию включено)

```bash
sudo connectorctl auto-update status       # включено/выключено, последняя проверка, результат, версия
sudo connectorctl auto-update enable [--window 03:00-05:00] [--every 24]
sudo connectorctl auto-update disable     # полностью удаляет timer/cron и настройки
```

- **Включается автоматически** при установке (autoinstaller / `install.sh`, native и docker); отключить при установке: флаг `--no-auto-update`. На уже установленных системах включается при ближайшем ручном `connectorctl update` — с сообщением в выводе; после `auto-update disable` повторно не включается. Это systemd timer `connectorctl-update.timer` (если systemd нет — запись в `/etc/cron.d`), который раз в час запускает `connectorctl auto-update run`.
- Политика: только minor/patch, **мажорные никогда автоматически**; обновление идёт только внутри окна (локальное время, окно через полночь допустимо, по умолчанию 03:00–05:00) и не чаще раза в `--every` часов (по умолчанию 24). Если автообновление до версии X откатилось, X помечается проблемной и автоматически не пробуется повторно, пока не выйдет следующая версия (ручной `update` по-прежнему доступен).
- Внешних уведомлений нет: результат в журнале (`journalctl -u connectorctl-update`; для cron — `/var/log/connectorctl-update.log`) и в `connectorctl auto-update status` (последняя проверка, результат, версия).

### Установки до механизма обновления

Docker-установки без `connectorctl` и native-установки с версией скриптов старше этого релиза: один раз скачайте скрипты нужного релиза в каталог установщика (`.env` и `.install-meta` не перезаписываются):

```bash
VER=vX.Y.Z   # релиз с механизмом обновления
cd /opt/asterisk24-connector-installer   # каталог установщика (для docker — там же docker-compose.yml и .env)
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/archive/refs/tags/${VER}.tar.gz" \
  | sudo tar -xz --strip-components=1 --exclude='.env' --exclude='.install-meta' --exclude='db.env'
sudo ln -sf "$PWD/scripts/connectorctl" /usr/local/bin/connectorctl
```

Не запускайте повторно `autoinstaller.sh` на работающей docker-установке: он пересоздаёт каталог установщика, где лежит `.env`.

### Тесты

```bash
bash tests/test-update.sh   # офлайн: GitHub и systemctl/docker/psql замоканы
```
