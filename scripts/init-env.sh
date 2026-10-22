#!/usr/bin/env bash
# Prepare .env for docker compose + app (single env file).
#
#   ./scripts/init-env.sh
#   ./scripts/init-env.sh --force
#   ./scripts/init-env.sh --tag 1.2.3 --market-app-url https://app.example.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FORCE=0
NATIVE=0
PORT_FROM_CLI=0
TAG_FROM_CLI=0
MARKET_FROM_CLI=0
BASE_FROM_CLI=0
DB_HOST_FROM_CLI=0
# Default image tag = package version (never "latest" — audit H2).
IMAGE_TAG="${CONNECTOR_VERSION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(
  grep -E '^version\s*=' "${REPO_ROOT}/pyproject.toml" 2>/dev/null \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
)}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
MARKET_APP_URL=""
BASE_URL=""
DB_HOST=""
EXPOSED_PORT="${DEFAULT_PORT}"

usage() {
  cat <<USAGE
Использование: $(basename "$0") [опции]

Создаёт / обновляет .env (секреты + compose/native-переменные).

  --force                 перезаписать секреты
  --native                native-режим: DB__HOST=127.0.0.1 (не compose host «db»)
  --tag TAG               тег GHCR (default: из .env или version в pyproject.toml)
  --market-app-url URL    override MARKET_APP_URL (default: из .env или ${DEFAULT_MARKET_APP_URL})
  --base-url URL          override BASE_URL (default: из .env или http://HOST:PORT)
  --port PORT             EXPOSED_APP_PORT (default: из .env или ${DEFAULT_PORT})
  --db-host HOST          override DB__HOST
  -h, --help

Значения из .env сохраняются, если не переданы явно через CLI.
Если есть устаревший connector.env — один раз мигрируем в .env.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --native) NATIVE=1; shift ;;
    --tag) IMAGE_TAG="${2:-}"; TAG_FROM_CLI=1; shift 2 ;;
    --market-app-url) MARKET_APP_URL="${2:-}"; MARKET_FROM_CLI=1; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; BASE_FROM_CLI=1; shift 2 ;;
    --port) EXPOSED_PORT="${2:-}"; PORT_FROM_CLI=1; shift 2 ;;
    --db-host) DB_HOST="${2:-}"; DB_HOST_FROM_CLI=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестная опция: $1" ;;
  esac
done

CONFIG_ROOT="${CONNECTOR_INSTALL_DIR:-${REPO_ROOT}}"
cd "${CONFIG_ROOT}"

ENV_FILE="${CONFIG_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"
LEGACY_FILE="${CONFIG_ROOT}/connector.env"

if [[ ! -f "${EXAMPLE_FILE}" ]]; then
  die "Нет .env.example в ${REPO_ROOT}"
fi

# Merge KEY=VALUE from src into dst when dst lacks the key or has an empty value.
merge_env_from() {
  local src="$1" dst="$2"
  local line key val cur
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *"="* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    cur="$(env_get "${dst}" "${key}" || true)"
    if [[ -z "${cur}" ]]; then
      env_set "${dst}" "${key}" "${val}"
    fi
  done <"${src}"
}

# --- create / migrate .env ---
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${LEGACY_FILE}" ]]; then
    cp "${LEGACY_FILE}" "${ENV_FILE}"
    log_warn "Мигрировали connector.env → .env"
    log_info "Устаревший connector.env больше не нужен — можно удалить"
  else
    cp "${EXAMPLE_FILE}" "${ENV_FILE}"
    log_ok "Создан .env из .env.example"
  fi
else
  if [[ -f "${LEGACY_FILE}" ]]; then
    merge_env_from "${LEGACY_FILE}" "${ENV_FILE}"
    log_warn "Найден устаревший connector.env — недостающие ключи влиты в .env"
    log_info "Используется только .env. Удалите connector.env, когда убедитесь, что всё работает"
  elif [[ "${FORCE}" -eq 1 ]]; then
    log_warn "Перегенерирую секреты в существующем .env (--force)"
  else
    log_ok ".env уже есть — секреты не трогаем"
  fi
fi

need_secret() {
  local key="$1"
  local cur
  cur="$(env_get "${ENV_FILE}" "${key}" || true)"
  [[ -z "${cur}" ]]
}

if [[ "${FORCE}" -eq 1 ]] || need_secret CONNECTOR__API_KEY; then
  env_set "${ENV_FILE}" CONNECTOR__API_KEY "$(gen_password 40)"
  log_ok "CONNECTOR__API_KEY"
fi

if [[ "${FORCE}" -eq 1 ]] || need_secret CONNECTOR__ENCRYPTION_KEY; then
  env_set "${ENV_FILE}" CONNECTOR__ENCRYPTION_KEY "$(gen_fernet_key)"
  log_ok "CONNECTOR__ENCRYPTION_KEY"
fi

if [[ "${FORCE}" -eq 1 ]] || need_secret CONNECTOR__RECORDING_SIGNING_KEY; then
  env_set "${ENV_FILE}" CONNECTOR__RECORDING_SIGNING_KEY "$(gen_password 40)"
  log_ok "CONNECTOR__RECORDING_SIGNING_KEY"
fi

if [[ "${FORCE}" -eq 1 ]] || need_secret DB__PASSWORD; then
  env_set "${ENV_FILE}" DB__PASSWORD "$(gen_password 32)"
  log_ok "DB__PASSWORD"
fi

env_set "${ENV_FILE}" DEBUG "false"
env_set "${ENV_FILE}" ENV "production"

# --- EXPOSED_APP_PORT: CLI > existing > default ---
existing_port="$(env_get "${ENV_FILE}" EXPOSED_APP_PORT || true)"
if [[ "${PORT_FROM_CLI}" -eq 1 ]]; then
  env_set "${ENV_FILE}" EXPOSED_APP_PORT "${EXPOSED_PORT}"
  log_ok "EXPOSED_APP_PORT · ${EXPOSED_PORT} (--port)"
elif [[ -n "${existing_port}" ]]; then
  EXPOSED_PORT="${existing_port}"
  log_ok "EXPOSED_APP_PORT · ${EXPOSED_PORT} (из .env)"
else
  env_set "${ENV_FILE}" EXPOSED_APP_PORT "${DEFAULT_PORT}"
  EXPOSED_PORT="${DEFAULT_PORT}"
  log_ok "EXPOSED_APP_PORT · ${EXPOSED_PORT} (по умолчанию)"
fi

# --- MARKET_APP_URL: CLI > existing > default ---
existing_market="$(env_get "${ENV_FILE}" MARKET_APP_URL || true)"
if [[ "${MARKET_FROM_CLI}" -eq 1 ]]; then
  env_set "${ENV_FILE}" MARKET_APP_URL "${MARKET_APP_URL}"
  log_ok "MARKET_APP_URL · ${MARKET_APP_URL} (--market-app-url)"
elif [[ -n "${existing_market}" ]]; then
  MARKET_APP_URL="${existing_market}"
  log_ok "MARKET_APP_URL · ${MARKET_APP_URL} (из .env)"
else
  MARKET_APP_URL="${DEFAULT_MARKET_APP_URL}"
  env_set "${ENV_FILE}" MARKET_APP_URL "${MARKET_APP_URL}"
  log_ok "MARKET_APP_URL · ${MARKET_APP_URL} (по умолчанию)"
fi

# --- BASE_URL: CLI > existing > auto from port ---
existing_base="$(env_get "${ENV_FILE}" BASE_URL || true)"
if [[ "${BASE_FROM_CLI}" -eq 1 ]]; then
  env_set "${ENV_FILE}" BASE_URL "${BASE_URL}"
  log_ok "BASE_URL · ${BASE_URL} (--base-url)"
elif [[ -n "${existing_base}" ]]; then
  BASE_URL="${existing_base}"
  log_ok "BASE_URL · ${BASE_URL} (из .env)"
else
  BASE_URL="$(default_base_url "${EXPOSED_PORT}")"
  env_set "${ENV_FILE}" BASE_URL "${BASE_URL}"
  log_ok "BASE_URL · ${BASE_URL} (по умолчанию)"
fi

# --- DB__HOST: CLI > native default > existing > example ---
existing_db_host="$(env_get "${ENV_FILE}" DB__HOST || true)"
if [[ "${DB_HOST_FROM_CLI}" -eq 1 ]]; then
  env_set "${ENV_FILE}" DB__HOST "${DB_HOST}"
  log_ok "DB__HOST · ${DB_HOST} (--db-host)"
elif [[ "${NATIVE}" -eq 1 ]]; then
  # Native install talks to local Postgres, not the compose service name «db».
  if [[ -z "${existing_db_host}" || "${existing_db_host}" == "db" ]]; then
    env_set "${ENV_FILE}" DB__HOST "127.0.0.1"
    log_ok "DB__HOST · 127.0.0.1 (--native)"
  else
    log_ok "DB__HOST · ${existing_db_host} (из .env, --native)"
  fi
elif [[ -n "${existing_db_host}" ]]; then
  log_ok "DB__HOST · ${existing_db_host} (из .env)"
fi

# Ensure DB defaults exist for native (USER/NAME/PORT).
if [[ -z "$(env_get "${ENV_FILE}" DB__USER || true)" ]]; then
  env_set "${ENV_FILE}" DB__USER "connector"
fi
if [[ -z "$(env_get "${ENV_FILE}" DB__NAME || true)" ]]; then
  env_set "${ENV_FILE}" DB__NAME "connector"
fi
if [[ -z "$(env_get "${ENV_FILE}" DB__PORT || true)" ]]; then
  env_set "${ENV_FILE}" DB__PORT "5432"
fi

# --- CONNECTOR_VERSION (GHCR tag): CLI > existing > default ---
existing_tag="$(env_get "${ENV_FILE}" CONNECTOR_VERSION || true)"
existing_tag="${existing_tag:-$(env_get "${ENV_FILE}" CONNECTOR_IMAGE_TAG || true)}"
if [[ "${TAG_FROM_CLI}" -eq 1 ]]; then
  env_set "${ENV_FILE}" CONNECTOR_VERSION "${IMAGE_TAG}"
  env_set "${ENV_FILE}" CONNECTOR_IMAGE_TAG "${IMAGE_TAG}"
  log_ok "CONNECTOR_VERSION · ${IMAGE_TAG} (--tag)"
elif [[ -n "${existing_tag}" ]]; then
  IMAGE_TAG="${existing_tag}"
  env_set "${ENV_FILE}" CONNECTOR_VERSION "${IMAGE_TAG}"
  env_set "${ENV_FILE}" CONNECTOR_IMAGE_TAG "${IMAGE_TAG}"
  log_ok "CONNECTOR_VERSION · ${IMAGE_TAG} (из .env)"
elif [[ "${NATIVE}" -eq 0 ]]; then
  env_set "${ENV_FILE}" CONNECTOR_VERSION "${IMAGE_TAG}"
  env_set "${ENV_FILE}" CONNECTOR_IMAGE_TAG "${IMAGE_TAG}"
  log_ok "CONNECTOR_VERSION · ${IMAGE_TAG} (по умолчанию)"
elif [[ -z "${existing_tag}" ]]; then
  env_set "${ENV_FILE}" CONNECTOR_VERSION "${IMAGE_TAG}"
  env_set "${ENV_FILE}" CONNECTOR_IMAGE_TAG "${IMAGE_TAG}"
  log_ok "CONNECTOR_VERSION · ${IMAGE_TAG}"
fi

# Minimal db.env for compose postgres (no connector secrets — audit).
DB_ENV_FILE="${REPO_ROOT}/db.env"
{
  printf 'POSTGRES_USER=%s\n' "$(env_get "${ENV_FILE}" DB__USER || echo connector)"
  printf 'POSTGRES_PASSWORD=%s\n' "$(env_get "${ENV_FILE}" DB__PASSWORD || true)"
  printf 'POSTGRES_DB=%s\n' "$(env_get "${ENV_FILE}" DB__NAME || echo connector)"
} > "${DB_ENV_FILE}"
chmod 600 "${DB_ENV_FILE}" 2>/dev/null || true
log_ok "db.env (только Postgres)"

chmod 600 "${ENV_FILE}" 2>/dev/null || true

API_KEY="$(env_get "${ENV_FILE}" CONNECTOR__API_KEY)"
log_info "Ключ коннектора: ${API_KEY:0:8}…"
log_ok ".env готов (chmod 600)"
