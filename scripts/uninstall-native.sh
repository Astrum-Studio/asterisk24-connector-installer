#!/usr/bin/env bash
# Remove a native (systemd) install of Asterisk Connector.
#
# По умолчанию снимает только службы и команду connectorctl:
# код, .env и база данных остаются — переустановка подхватит их.
#
#   sudo connectorctl uninstall                # службы + connectorctl
#   sudo connectorctl uninstall --purge        # + каталог установки (.env, venv)
#   sudo connectorctl uninstall --purge --drop-db --remove-user   # полное удаление

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSUME_YES=0
PURGE=0
DROP_DB=0
REMOVE_USER=0
NO_BACKUP=0
INSTALL_DIR="${INSTALL_DIR:-}"
CTL_LINK="/usr/local/bin/connectorctl"
BACKUP_DIR="/var/backups/bitrix24-asterisk-connector"
SYSTEMD_UNITS=(
  connector-app
  connector-ami
  connector-outbox
  connector-cel
  connector-recording
)

usage() {
  cat <<EOT
Использование: $(basename "$0") [опции]

Удаляет native-установку (systemd). Без флагов данные сохраняются.

  -y, --yes            не задавать вопросов (опасные действия всё равно требуют флагов)
  --install-dir DIR    каталог установки (default: определяется автоматически)
  --purge              удалить каталог установки, включая .env и venv
  --drop-db            удалить базу данных и роль PostgreSQL (необратимо)
  --remove-user        удалить системного пользователя ${DEFAULT_CONNECTOR_USER}
  --no-backup          не делать резервную копию перед --purge/--drop-db
  -h, --help
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --purge|--purge-files) PURGE=1; shift ;;
    --drop-db) DROP_DB=1; shift ;;
    --remove-user) REMOVE_USER=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

require_root_or_sudo "удаления native-служб"

# Locate the install: explicit flag > connectorctl symlink > default.
if [[ -z "${INSTALL_DIR}" && -L "${CTL_LINK}" ]]; then
  INSTALL_DIR="$(cd "$(dirname "$(readlink -f "${CTL_LINK}")")/.." && pwd)"
fi
INSTALL_DIR="${INSTALL_DIR:-${DEFAULT_NATIVE_INSTALL_DIR}}"
INSTALL_DIR="${INSTALL_DIR%/}"
ENV_FILE="${INSTALL_DIR}/.env"

# Refuse to rm -rf anything that is not clearly our install.
if [[ "${PURGE}" -eq 1 ]]; then
  if [[ ! -f "${INSTALL_DIR}/pyproject.toml" ]] \
    || ! grep -q 'name = "bitrix24-asterisk-connector"' "${INSTALL_DIR}/pyproject.toml"; then
    die "${INSTALL_DIR} не похож на установку коннектора — --purge отменён"
  fi
fi

env_read() { ${SUDO} grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true; }

printf '\n'
print_plan_header
print_kv "Каталог" "${INSTALL_DIR}" "$([[ -d "${INSTALL_DIR}" ]] && echo найден || echo 'не найден')"
print_kv "Службы" "остановить и удалить (${#SYSTEMD_UNITS[@]})"
print_kv "connectorctl" "удалить"
print_kv "Каталог установки" "$([[ "${PURGE}" -eq 1 ]] && echo 'УДАЛИТЬ (.env, venv, код)' || echo 'сохранить')"
print_kv "База данных" "$([[ "${DROP_DB}" -eq 1 ]] && echo 'УДАЛИТЬ (необратимо)' || echo 'сохранить')"
print_kv "Пользователь" "$([[ "${REMOVE_USER}" -eq 1 ]] && echo "удалить ${DEFAULT_CONNECTOR_USER}" || echo 'сохранить')"
printf '\n'

ask_yes "Продолжить?" || { log_warn "Отменено, ничего не изменено"; exit 0; }

# Irreversible actions need an explicit typed confirmation even with --yes absent.
if [[ "${DROP_DB}" -eq 1 && "${ASSUME_YES}" -eq 0 ]]; then
  printf "  ${C_RED}?${C_RESET}  Для удаления БД введите ${C_BOLD}DROP${C_RESET}: " >&2
  read -r typed || true
  [[ "${typed:-}" == "DROP" ]] || { log_warn "БД не тронута, отмена"; exit 0; }
fi

# ─── Backup before anything irreversible ────────────────────
if [[ ( "${PURGE}" -eq 1 || "${DROP_DB}" -eq 1 ) && "${NO_BACKUP}" -eq 0 && -f "${ENV_FILE}" ]]; then
  if [[ -x "${INSTALL_DIR}/scripts/connectorctl" ]] && command -v pg_dump >/dev/null 2>&1; then
    log_info "Резервная копия перед удалением"
    if ! ${SUDO} "${INSTALL_DIR}/scripts/connectorctl" backup "${BACKUP_DIR}"; then
      log_warn "Бэкап не удался"
      ask_yes "Продолжить без бэкапа?" || exit 1
    fi
  else
    log_warn "pg_dump недоступен — бэкап пропущен"
    ask_yes "Продолжить без бэкапа?" || exit 1
  fi
fi

DB_NAME="$(env_read DB__NAME)"; DB_USER="$(env_read DB__USER)"

# ─── Services ───────────────────────────────────────────────
for name in "${SYSTEMD_UNITS[@]}"; do
  ${SUDO} systemctl disable --now "${name}.service" >/dev/null 2>&1 || true
  ${SUDO} rm -f "/etc/systemd/system/${name}.service"
done
${SUDO} systemctl daemon-reload
${SUDO} systemctl reset-failed 'connector-*' >/dev/null 2>&1 || true
log_ok "Службы остановлены и удалены"

if [[ -L "${CTL_LINK}" ]]; then
  ${SUDO} rm -f "${CTL_LINK}"
  log_ok "Удалена команда connectorctl"
fi

# ─── Database ───────────────────────────────────────────────
if [[ "${DROP_DB}" -eq 1 ]]; then
  if [[ -n "${DB_NAME}" && -n "${DB_USER}" ]]; then
    pg_run() {
      if command -v runuser >/dev/null 2>&1; then
        ${SUDO} runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -c "$1"
      else
        ${SUDO} su -s /bin/bash postgres -c "psql -v ON_ERROR_STOP=1 -q -c \"$1\""
      fi
    }
    if pg_run "DROP DATABASE IF EXISTS \"${DB_NAME}\";" \
      && pg_run "DROP ROLE IF EXISTS \"${DB_USER}\;"; then
      log_ok "БД ${DB_NAME} и роль ${DB_USER} удалены"
    else
      log_warn "Не удалось удалить БД/роль — сделайте вручную (psql от пользователя postgres)"
    fi
  else
    log_warn "Не удалось определить БД из ${ENV_FILE} — пропущено"
  fi
fi

# ─── Files / user ───────────────────────────────────────────
if [[ "${PURGE}" -eq 1 ]]; then
  ${SUDO} rm -rf "${INSTALL_DIR}"
  ${SUDO} rm -rf "/var/cache/${PRODUCT_SLUG}"
  log_ok "Каталог удалён: ${INSTALL_DIR}"
fi

if [[ "${REMOVE_USER}" -eq 1 ]] && id -u "${DEFAULT_CONNECTOR_USER}" >/dev/null 2>&1; then
  if ${SUDO} userdel "${DEFAULT_CONNECTOR_USER}" 2>/dev/null; then
    log_ok "Пользователь ${DEFAULT_CONNECTOR_USER} удалён"
  else
    log_warn "Не удалось удалить пользователя ${DEFAULT_CONNECTOR_USER}"
  fi
fi

# ─── What is left ───────────────────────────────────────────
printf '\n  %sОсталось на сервере%s\n' "${C_BOLD}" "${C_RESET}"
[[ "${PURGE}" -eq 0 ]] && print_kv "Код и .env" "${INSTALL_DIR}" "повторная установка подхватит .env"
[[ "${DROP_DB}" -eq 0 ]] && print_kv "PostgreSQL" "${DB_NAME:-connector}" "данные не тронуты"
[[ -d "${BACKUP_DIR}" ]] && print_kv "Бэкапы" "${BACKUP_DIR}"
print_kv "Клон репозитория" "не затрагивался"
printf '\n'
