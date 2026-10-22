#!/usr/bin/env bash
# Shared helpers + Astrum TUI for Bitrix24 Asterisk Connector installers.

set -euo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
fi

case "$(locale charmap 2>/dev/null || true)" in
  UTF-8) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

PRODUCT_NAME="Asterisk Connector"
PRODUCT_SLUG="bitrix24-asterisk-connector"
GHCR_IMAGE="ghcr.io/astrum-studio/asterisk24-connector"
INSTALLER_REPO="Astrum-Studio/asterisk24-connector-installer"
DEFAULT_PORT="8079"
DEFAULT_NATIVE_INSTALL_DIR="/opt/asterisk24-connector"
DEFAULT_CONNECTOR_USER="connector"
MIN_PYTHON="3.12"
# Fixed marketplace app for Astrum Bitrix24 ↔ Asterisk product.
DEFAULT_MARKET_APP_URL="https://app-11.astrum.agency"

# ─── Colors (Astrum brand #2653F2) ───────────────────────────
_astrum_color_ok() {
  [[ "${NO_COLOR:-}" == "1" && -z "${FORCE_COLOR:-}" ]] && return 1
  [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]] || return 1
  [[ "${TERM:-dumb}" == "dumb" ]] && return 1
  return 0
}

if _astrum_color_ok; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BLUE=$'\033[38;5;27m'
  C_BLUE_H=$'\033[38;5;69m'
  C_WHITE=$'\033[38;5;255m'
  C_GREEN=$'\033[38;5;79m'
  C_YELLOW=$'\033[38;5;220m'
  C_RED=$'\033[38;5;203m'
  C_CYAN=$'\033[38;5;117m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_BLUE='' C_BLUE_H='' C_WHITE=''
  C_GREEN='' C_YELLOW='' C_RED='' C_CYAN=''
fi

log_info()  { printf "  ${C_BLUE}›${C_RESET}  %s\n" "$*"; }
log_ok()    { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
log_warn()  { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
log_err()   { printf "  ${C_RED}✖${C_RESET}  %s\n" "$*" >&2; }

# Full installer output (spinner-captured command output included) lands here.
if [[ -z "${INSTALL_LOG:-}" ]]; then
  if [[ "${EUID}" -eq 0 && -w /var/log ]]; then
    INSTALL_LOG="/var/log/connector-install.log"
  else
    INSTALL_LOG="${TMPDIR:-/tmp}/connector-install-$(id -u).log"
  fi
fi

die() {
  # die "что случилось" ["что сделать"]
  log_err "$1"
  if [[ -n "${2:-}" ]]; then
    printf "     ${C_DIM}Что сделать: %s${C_RESET}\n" "$2" >&2
  fi
  [[ -s "${INSTALL_LOG}" ]] && printf "     ${C_DIM}Подробный лог: %s${C_RESET}\n" "${INSTALL_LOG}" >&2
  exit 1
}

# Mask secrets for display: abcd…wxyz (keeps first/last 4 when long enough).
mask_secret() {
  local s="${1:-}"
  local n=${#s}
  if (( n == 0 )); then
    printf '(пусто)'
    return
  fi
  if (( n <= 8 )); then
    printf '********'
    return
  fi
  printf '%s…%s' "${s:0:4}" "${s: -4}"
}

log_step() {
  local current="$1" total="$2" title="$3"
  local i
  printf "\n  "
  for ((i = 1; i <= total; i++)); do
    if [[ "$i" -lt "$current" ]]; then
      printf "${C_GREEN}●${C_RESET} "
    elif [[ "$i" -eq "$current" ]]; then
      printf "${C_BLUE}●${C_RESET} "
    else
      printf "${C_DIM}○${C_RESET} "
    fi
  done
  printf " ${C_DIM}%d/%d${C_RESET}  ${C_BOLD}%s${C_RESET}\n" "${current}" "${total}" "${title}"
  printf "  ${C_DIM}────────────────────────────────────────────${C_RESET}\n"
}

ask_yes() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
    return 0
  fi
  # Prompt on stderr so callers can capture only the answer via $(ask_yes …)
  # without swallowing the visible UI (stdout may be a pipe).
  printf "  ${C_BLUE}?${C_RESET}  %s ${C_DIM}[Y/n]${C_RESET} " "${prompt}" >&2
  read -r answer || true
  case "${answer:-Y}" in
    y|Y|yes|YES|'') return 0 ;;
    *) return 1 ;;
  esac
}

ask_value() {
  local prompt="$1" default="$2"
  local value=""
  if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
    printf '%s' "${default}"
    return
  fi
  # Must use stderr: MARKET_APP_URL="$(ask_value …)" captures stdout.
  printf "  ${C_BLUE}?${C_RESET}  %s ${C_DIM}[%s]${C_RESET} " "${prompt}" "${default}" >&2
  read -r value || true
  printf '%s' "${value:-$default}"
}

run_spinner() {
  local msg="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift

  if [[ ! -t 1 ]] || [[ "${NO_COLOR:-}" == "1" ]]; then
    log_info "${msg}"
    local rc_plain=0
    { printf '\n## %s | %s\n' "$(date '+%F %T')" "${msg}"; "$@"; } 2>&1 | tee -a "${INSTALL_LOG}" || rc_plain=${PIPESTATUS[0]}
    return "${rc_plain}"
  fi

  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local logfile
  logfile="$(mktemp)"
  "$@" >"${logfile}" 2>&1 &
  local pid=$!
  local i=0

  while kill -0 "${pid}" 2>/dev/null; do
    printf "\r  ${C_BLUE}%s${C_RESET}  %s" "${frames[i % ${#frames[@]}]}" "${msg}"
    i=$((i + 1))
    sleep 0.08
  done

  local rc=0
  wait "${pid}" || rc=$?
  { printf '\n## %s | %s (rc=%s)\n' "$(date '+%F %T')" "${msg}" "${rc}"; cat "${logfile}"; } >>"${INSTALL_LOG}" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    printf "\r  ${C_GREEN}✔${C_RESET}  %s\033[K\n" "${msg}"
  else
    printf "\r  ${C_RED}✖${C_RESET}  %s\033[K\n" "${msg}"
    cat "${logfile}" >&2 || true
  fi
  rm -f "${logfile}"
  return $rc
}

# /health is public. /status requires auth (X-Connector-Token / cookie) — do not poll it unauthenticated.
wait_health() {
  local msg="$1"
  local port="$2"
  local max_sec="${3:-90}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local start
  start="$(date +%s)"

  while true; do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      if [[ -t 1 ]]; then
        printf "\r  ${C_GREEN}✔${C_RESET}  %s\033[K\n" "${msg}"
      else
        log_ok "${msg}"
      fi
      return 0
    fi
    local now
    now="$(date +%s)"
    if [[ $((now - start)) -ge $max_sec ]]; then
      if [[ -t 1 ]]; then
        printf "\r  ${C_YELLOW}⚠${C_RESET}  %s\033[K\n" "${msg}"
      else
        log_warn "${msg}"
      fi
      return 1
    fi
    if [[ -t 1 ]]; then
      printf "\r  ${C_BLUE}%s${C_RESET}  %s" "${frames[i % ${#frames[@]}]}" "${msg}"
    fi
    i=$((i + 1))
    sleep 0.2
  done
}

# Backward-compatible alias: previously polled /status without auth (always 401 after audit).
wait_status() {
  wait_health "$@"
}

# Optional: probe /status with connector API key (X-Connector-Token). Returns 0 on HTTP 200.
check_status_authed() {
  local port="$1"
  local api_key="$2"
  if [[ -z "${api_key}" ]]; then
    return 1
  fi
  curl -fsS -H "X-Connector-Token: ${api_key}" "http://127.0.0.1:${port}/status" >/dev/null 2>&1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Команда не найдена: $1"
}

gen_password() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=' | head -c "${len}"
    return
  fi
  if [[ -r /dev/urandom ]]; then
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
    return
  fi
  die "Не удалось сгенерировать секрет (нужен openssl или /dev/urandom)"
}

gen_fernet_key() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null && return
  fi
  # Fallback: url-safe base64 of 32 raw bytes → 44-char Fernet key (with = padding).
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr '+/' '-_'
    return
  fi
  die "Нужен python3+cryptography или openssl для ENCRYPTION_KEY"
}

detect_os_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID,,}" in
      ubuntu|debian|linuxmint|pop|elementary) echo debian ;;
      rhel|centos|rocky|almalinux|ol) echo rhel ;;
      fedora) echo fedora ;;
      amzn) echo amzn ;;
      arch|manjaro|endeavouros) echo arch ;;
      *)
        case "${ID_LIKE,,}" in
          *debian*) echo debian ;;
          *rhel*|*fedora*) echo rhel ;;
          *arch*) echo arch ;;
          *) echo unknown ;;
        esac
        ;;
    esac
    return
  fi
  echo unknown
}

os_pretty_name() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${PRETTY_NAME:-$ID}"
    return
  fi
  uname -s
}

has_docker() { command -v docker >/dev/null 2>&1; }
has_compose() { docker compose version >/dev/null 2>&1; }
docker_usable() { has_docker && docker info >/dev/null 2>&1; }

# Prefer a routable LAN/WAN address for BASE_URL; fall back to localhost.
detect_public_host() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${ip}" && "${ip}" != "127.0.0.1" ]]; then
    printf '%s' "${ip}"
    return
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
    return
  fi
  printf '127.0.0.1'
}

default_base_url() {
  local port="${1:-$DEFAULT_PORT}"
  printf 'http://%s:%s' "$(detect_public_host)" "${port}"
}

require_root_or_sudo() {
  local reason="${1:-установки}"
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    return
  fi
  die "Нужны права root или sudo для ${reason}"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) echo "${arch}" ;;
  esac
}

arch_supported() {
  case "$(detect_arch)" in
    x86_64|aarch64) return 0 ;;
    *) return 1 ;;
  esac
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || -d /sys/fs/cgroup/systemd ]]
}

# Clone or update public installer repo at an exact tag (handles moved tags / stale /opt).
sync_installer_git_repo() {
  local ref="$1" work_dir="$2" git_url="${3:-https://github.com/${INSTALLER_REPO}.git}"
  case "${ref}" in v*) ;; *) ref="v${ref#v}" ;; esac
  mkdir -p "$(dirname "${work_dir}")"
  if [[ -d "${work_dir}/.git" ]]; then
    git -C "${work_dir}" fetch --depth 1 origin "refs/tags/${ref}:refs/tags/${ref}" --force 2>/dev/null \
      || git -C "${work_dir}" fetch --depth 1 origin "${ref}" --force 2>/dev/null \
      || git -C "${work_dir}" fetch --depth 1 origin --force
    git -C "${work_dir}" checkout -f "${ref}"
    git -C "${work_dir}" reset --hard "${ref}"
  elif ! git clone --depth 1 --branch "${ref}" "${git_url}" "${work_dir}" 2>/dev/null; then
    git clone --depth 1 "${git_url}" "${work_dir}"
    git -C "${work_dir}" checkout -f "${ref}"
    git -C "${work_dir}" reset --hard "${ref}"
  fi
}

# Verify Release tarball (SHA256SUMS may use basename or CI paths).
verify_release_tarball() {
  local dir="$1" asset="$2" sums_file="${3:-SHA256SUMS}"
  local expected actual line path
  [[ -f "${dir}/${asset}" ]] || die "Missing ${asset}"
  [[ -f "${dir}/${sums_file}" ]] || die "Missing ${sums_file}"
  line="$(grep -E "${asset}|connector-linux-amd64" "${dir}/${sums_file}" | head -1 || true)"
  expected="$(awk '{print $1}' <<<"${line}")"
  [[ -n "${expected}" ]] || expected="$(awk '{print $1; exit}' "${dir}/${sums_file}")"
  [[ -n "${expected}" ]] || die "SHA256SUMS has no hash"
  actual="$(sha256sum "${dir}/${asset}" | awk '{print $1}')"
  [[ "${expected}" == "${actual}" ]] || die "Checksum mismatch for ${asset}"
}

ensure_native_packages() {
  require_root_or_sudo "native install"
  local family
  family="$(detect_os_family)"
  case "${family}" in
    debian)
      local missing=()
      for pkg in curl ca-certificates rsync tar; do
        dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing: ${missing[*]}"
        ${SUDO} apt-get update -qq
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
      fi
      ;;
    *)
      for cmd in curl rsync tar; do
        command -v "${cmd}" >/dev/null 2>&1 || die "Missing command: ${cmd}"
      done
      ;;
  esac
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi
  return 1
}

python_version_ok() {
  local bin="${1:-python3}"
  command -v "${bin}" >/dev/null 2>&1 || return 1
  "${bin}" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)" 2>/dev/null
}

find_python() {
  local cand
  for cand in python3.13 python3.12 python3; do
    if python_version_ok "${cand}"; then
      command -v "${cand}"
      return 0
    fi
  done
  return 1
}

has_uv() {
  command -v uv >/dev/null 2>&1
}

env_set() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "${file}"; then
    local escaped
    escaped="$(printf '%s' "${value}" | sed -e 's/[\/&]/\\&/g')"
    sed -i.bak -E "s|^${key}=.*|${key}=${escaped}|" "${file}"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

env_get() {
  local file="$1" key="$2"
  grep -E "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2-
}

product_version() {
  local root="${1:-${REPO_ROOT}}" v=""
  v="$(grep -m1 -E '^version[[:space:]]*=' "${root}/pyproject.toml" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')"
  if [[ -d "${root}/.git" ]] && command -v git >/dev/null 2>&1; then
    local g
    g="$(git -C "${root}" describe --tags --always --dirty 2>/dev/null || true)"
    [[ -n "${g}" ]] && v="${v:-?} (${g})"
  fi
  printf '%s' "${v:-unknown}"
}

# key/value row: print_kv "Метка" "значение" ["подсказка"]
print_kv() {
  local pad=$((22 - ${#1}))
  ((pad < 1)) && pad=1
  printf "  ${C_DIM}%s%*s${C_RESET} %b" "$1" "${pad}" "" "$2"
  [[ -n "${3:-}" ]] && printf "  ${C_DIM}%b${C_RESET}" "$3"
  printf '\n'
}

print_banner() {
  printf '\n'
  printf "  ${C_BLUE}${C_BOLD}%s${C_RESET}  ${C_DIM}v%s${C_RESET}\n" "${PRODUCT_NAME}" "$(product_version "${REPO_ROOT}")"
  printf "  ${C_DIM}Asterisk ↔ Bitrix24 · Astrum Agency · astrum.agency${C_RESET}\n"
  printf "  ${C_BLUE}────────────────────────────────────────────────────${C_RESET}\n"
}

# Compact environment summary (no fixed-width box: long paths must not break layout).
print_meta() {
  local mode="${1:-docker}"
  print_kv "Система" "$(os_pretty_name) · $(detect_arch)"
  print_kv "Режим" "${mode}"
  print_kv "Запущено из" "${REPO_ROOT}"
  if has_docker && [[ "${mode}" == "docker" ]]; then
    print_kv "Docker" "$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
  fi
  printf '\n'
}

# Title + aligned rows shown before anything on the system is touched.
print_plan_header() {
  printf "\n  ${C_BOLD}План установки${C_RESET}\n"
  printf "  ${C_DIM}────────────────────────────────────────────────────${C_RESET}\n"
}

print_success_card() {
  local host="$1" port="$2" api_key="$3" image_tag="${4:-native}"
  local mode="${5:-docker}"
  local base="http://${host}:${port}"
  if [[ "${UPGRADE:-0}" -eq 1 ]]; then
    printf "\n  ${C_GREEN}${C_BOLD}✔ Обновление завершено${C_RESET}\n"
  else
    printf "\n  ${C_GREEN}${C_BOLD}✔ Установка завершена${C_RESET}\n"
  fi
  printf "  ${C_GREEN}────────────────────────────────────────────────────${C_RESET}\n\n"

  printf "  ${C_BOLD}Доступ${C_RESET}\n"
  print_kv "Мастер настройки" "${base}/connector/setup"
  print_kv "Health" "${base}/health" "публичный"
  print_kv "Status" "${base}/status" "нужен X-Connector-Token"
  if [[ "${mode}" != "native" ]]; then
    print_kv "Образ" "${GHCR_IMAGE}:${image_tag}"
  fi
  printf '\n'

  printf "  ${C_BOLD}API-ключ коннектора${C_RESET}\n"
  if [[ "${UPGRADE:-0}" -eq 1 ]]; then
    printf "  ${C_DIM}Не изменён (%s). Показать: sudo connectorctl key${C_RESET}\n\n" "$(mask_secret "${api_key}")"
  else
    print_kv "Маска" "$(mask_secret "${api_key}")"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "${api_key}"
    if [[ "${mode}" == "native" ]]; then
      printf "  ${C_DIM}Сохраните. Повторно: sudo connectorctl key${C_RESET}\n\n"
    else
      printf "  ${C_DIM}Хранится в .env (CONNECTOR__API_KEY)${C_RESET}\n\n"
    fi
  fi

  printf "  ${C_BOLD}Дальше${C_RESET}\n"
  printf "    1. Откройте мастер, введите API-ключ\n"
  printf "    2. Market App → ключ портала → шаг «Портал» в мастере\n"
  printf "    3. Добавьте сотрудников (extension) в приложении Маркета\n"
  printf "    4. Включите HTTPS (см. deploy/Caddyfile.example) и обновите BASE_URL\n\n"

  printf "  ${C_BOLD}Обслуживание${C_RESET}\n"
  if [[ "${mode}" == "native" ]]; then
    print_kv "connectorctl status" "состояние служб и /health"
    print_kv "connectorctl doctor" "диагностика: БД, ключи, права, сеть"
    print_kv "connectorctl logs -f" "логи API (logs ami|outbox|cel|recording|all)"
    print_kv "connectorctl restart" "перезапуск всех служб"
    print_kv "connectorctl backup" "дамп БД + конфигурация"
    print_kv "connectorctl update" "обновление из клона репозитория"
  else
    print_kv "docker compose ps" "состояние контейнеров"
    print_kv "docker compose logs -f" "логи"
    print_kv "docker compose pull && up -d" "обновление"
  fi
  printf "\n  ${C_DIM}Полный лог установки: %s${C_RESET}\n\n" "${INSTALL_LOG}"
}
