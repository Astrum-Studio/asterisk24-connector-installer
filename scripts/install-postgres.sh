#!/usr/bin/env bash
# Ensure PostgreSQL is available and create connector DB/role from .env.
#
#   ./scripts/install-postgres.sh
#   ./scripts/install-postgres.sh --yes --env-file /opt/.../.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSUME_YES=0
ENV_FILE="${REPO_ROOT}/.env"
SKIP_INSTALL=0

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции]

Проверяет/устанавливает PostgreSQL и создаёт БД/роль из .env.

  -y, --yes           Без подтверждений
  --env-file PATH     Путь к .env (default: ${REPO_ROOT}/.env)
  --skip-install      Не ставить пакеты — только создать роль/БД
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестная опция: $1" ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || die "Нет .env: ${ENV_FILE}"

DB_HOST="$(env_get "${ENV_FILE}" DB__HOST)"
DB_PORT="$(env_get "${ENV_FILE}" DB__PORT)"
DB_USER="$(env_get "${ENV_FILE}" DB__USER)"
DB_PASSWORD="$(env_get "${ENV_FILE}" DB__PASSWORD)"
DB_NAME="$(env_get "${ENV_FILE}" DB__NAME)"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-connector}"
DB_NAME="${DB_NAME:-connector}"
[[ -n "${DB_PASSWORD}" ]] || die "DB__PASSWORD пуст в ${ENV_FILE}"

pg_ready() {
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -h "${DB_HOST}" -p "${DB_PORT}" >/dev/null 2>&1
    return $?
  fi
  # Fallback: TCP connect
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import socket; s=socket.create_connection(('${DB_HOST}', int('${DB_PORT}')), 3); s.close()" 2>/dev/null
    return $?
  fi
  return 1
}

install_postgres_packages() {
  local family
  family="$(detect_os_family)"
  require_root_or_sudo "установки PostgreSQL"
  case "${family}" in
    debian)
      ${SUDO} apt-get update -qq
      ${SUDO} apt-get install -y -qq postgresql postgresql-contrib
      ;;
    rhel|fedora|amzn)
      if command -v dnf >/dev/null 2>&1; then
        ${SUDO} dnf -y install postgresql-server postgresql
        if [[ ! -d /var/lib/pgsql/data ]] && [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
          ${SUDO} postgresql-setup --initdb 2>/dev/null || ${SUDO} /usr/bin/postgresql-setup --initdb 2>/dev/null || true
        fi
      else
        ${SUDO} yum -y install postgresql-server postgresql
      fi
      ;;
    arch)
      ${SUDO} pacman -Sy --noconfirm postgresql
      if [[ ! -d /var/lib/postgres/data ]]; then
        ${SUDO} -u postgres initdb -D /var/lib/postgres/data 2>/dev/null || true
      fi
      ;;
    *)
      die "Автоустановка PostgreSQL не поддерживается для ${family}"
      ;;
  esac
  ${SUDO} systemctl enable --now postgresql 2>/dev/null \
    || ${SUDO} systemctl enable --now postgresql.service 2>/dev/null \
    || true
}

if pg_ready; then
  log_ok "PostgreSQL доступен на ${DB_HOST}:${DB_PORT}"
elif [[ "${SKIP_INSTALL}" -eq 1 ]]; then
  die "PostgreSQL недоступен на ${DB_HOST}:${DB_PORT} (--skip-install)"
else
  if [[ "${DB_HOST}" != "127.0.0.1" && "${DB_HOST}" != "localhost" ]]; then
    die "PostgreSQL недоступен на ${DB_HOST}:${DB_PORT}. Для удалённого хоста установите БД вручную или укажите --db-host."
  fi
  if ! ask_yes "Установить и запустить PostgreSQL локально?"; then
    die "Без PostgreSQL native-установка невозможна"
  fi
  install_postgres_packages
  # Wait for listen
  for _ in $(seq 1 30); do
    pg_ready && break
    sleep 1
  done
  pg_ready || die "PostgreSQL не отвечает после установки"
  log_ok "PostgreSQL установлен и запущен"
fi

# Quote PostgreSQL identifiers safely (audit L7).
pg_quote_ident() {
  local ident="$1"
  printf '"%s"' "${ident//\"/\"\"}"
}

# Create role + database via local peer auth when possible.
create_sql() {
  local sql q_user q_db
  q_user="$(pg_quote_ident "${DB_USER}")"
  q_db="$(pg_quote_ident "${DB_NAME}")"
  # Password via dollar-quoting to avoid injection from .env.
  sql=$(cat <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER//\'/\'\'}') THEN
    CREATE ROLE ${q_user} LOGIN PASSWORD \$pwd\$${DB_PASSWORD}\$pwd\$;
  ELSE
    ALTER ROLE ${q_user} WITH LOGIN PASSWORD \$pwd\$${DB_PASSWORD}\$pwd\$;
  END IF;
END
\$\$;
SELECT 'ok_role';
SQL
)
  if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    echo "${sql}" | sudo -u postgres psql -v ON_ERROR_STOP=1 -q
  elif [[ "${EUID}" -eq 0 ]] && id postgres >/dev/null 2>&1; then
    echo "${sql}" | su -s /bin/bash postgres -c "psql -v ON_ERROR_STOP=1 -q"
  else
    PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -v ON_ERROR_STOP=1 -q <<<"SELECT 1;" 2>/dev/null \
      || die "Не удалось подключиться к PostgreSQL для создания роли (нужен peer-доступ пользователя postgres)"
    return 0
  fi

  local exists
  if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME//\'/\'\'}'" || true)"
  else
    exists="$(su -s /bin/bash postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME//\'/\'\'}'\"" || true)"
  fi
  if [[ "${exists}" != "1" ]]; then
    if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE ${q_db} OWNER ${q_user};"
    else
      su -s /bin/bash postgres -c "psql -v ON_ERROR_STOP=1 -q -c \"CREATE DATABASE ${q_db} OWNER ${q_user};\""
    fi
  fi
}

create_sql
log_ok "БД ${DB_NAME} / роль ${DB_USER} готовы"
