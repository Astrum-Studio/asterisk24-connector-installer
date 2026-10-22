#!/usr/bin/env bash
# Public installer: native binary or Docker (GHCR). No source code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# curl …/install.sh alone has no scripts/ tree — clone installer at --version and re-exec.
if [[ ! -f "${REPO_ROOT}/scripts/lib/common.sh" ]]; then
  INSTALLER_REPO="${INSTALLER_REPO:-Astrum-Studio/asterisk24-connector-installer}"
  INSTALLER_GIT="${INSTALLER_GIT:-https://github.com/${INSTALLER_REPO}.git}"
  WORK_DIR="${INSTALLER_WORK_DIR:-/opt/asterisk24-connector-installer}"
  REF="v1.0.0"
  args=("$@")
  i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --version)
        REF="${args[$((i + 1))]:-}"
        REF="${REF#v}"
        REF="v${REF}"
        i=$((i + 2))
        ;;
      *) i=$((i + 1)) ;;
    esac
  done
  [[ -n "${REF}" ]] || REF="v1.0.0"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo bash install.sh …" >&2
    exit 1
  fi
  command -v git >/dev/null 2>&1 || {
    echo "git is required to bootstrap the installer" >&2
    exit 1
  }
  echo "›  Fetching full installer ${INSTALLER_REPO} @ ${REF} → ${WORK_DIR}" >&2
  mkdir -p "$(dirname "${WORK_DIR}")"
  if [[ -d "${WORK_DIR}/.git" ]]; then
    git -C "${WORK_DIR}" fetch --depth 1 origin "refs/tags/${REF}:refs/tags/${REF}" --force 2>/dev/null \
      || git -C "${WORK_DIR}" fetch --depth 1 origin "${REF}" --force 2>/dev/null \
      || git -C "${WORK_DIR}" fetch --depth 1 origin --force
    git -C "${WORK_DIR}" checkout -f "${REF}"
    git -C "${WORK_DIR}" reset --hard "${REF}"
  elif ! git clone --depth 1 --branch "${REF}" "${INSTALLER_GIT}" "${WORK_DIR}" 2>/dev/null; then
    git clone --depth 1 "${INSTALLER_GIT}" "${WORK_DIR}"
    git -C "${WORK_DIR}" checkout -f "${REF}"
    git -C "${WORK_DIR}" reset --hard "${REF}"
  fi
  chmod +x "${WORK_DIR}/install.sh" "${WORK_DIR}/scripts/"*.sh 2>/dev/null || true
  exec bash "${WORK_DIR}/install.sh" "$@"
fi

# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

MODE="docker"
ASSUME_YES=0
NO_START=0
FORCE_ENV=0
SKIP_DOCKER=0
VERSION="${CONNECTOR_VERSION:-1.0.0}"
GHCR_TOKEN=""
EXPOSED_PORT="${DEFAULT_PORT}"
PORT_FROM_CLI=0
MARKET_APP_URL=""
BASE_URL=""

usage() {
  print_banner
  cat <<EOF

  ${C_BOLD}Asterisk Connector installer${C_RESET} (binary distribution)

  ${C_DIM}One-liner (рекомендуется):${C_RESET}
    curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/scripts/autoinstaller.sh \\
      | sudo bash -s -- --mode docker --version v1.0.0 --ghcr-token "\$TOKEN" --yes
    curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/scripts/autoinstaller.sh \\
      | sudo bash -s -- --mode native --version v1.0.0 --yes

  ${C_DIM}Из клона установщика:${C_RESET}  $(basename "$0") --mode native|docker --version vX.Y.Z [опции]

  ${C_BLUE}--mode${C_RESET} MODE          native | docker (default: docker)
  ${C_BLUE}--version${C_RESET} TAG        release tag, e.g. v1.0.0
  ${C_BLUE}--ghcr-token${C_RESET} TOKEN   required for docker (private GHCR)
  ${C_BLUE}--skip-docker${C_RESET}        Docker уже установлен
  ${C_BLUE}--port${C_RESET} PORT          host port (default ${DEFAULT_PORT})
  ${C_BLUE}-y, --yes${C_RESET}             non-interactive
  ${C_BLUE}--no-start${C_RESET}           config only
  ${C_BLUE}--force-env${C_RESET}          regenerate secrets

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --version) VERSION="${2#v}"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="${2:-}"; shift 2 ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --port) EXPOSED_PORT="${2:-}"; PORT_FROM_CLI=1; shift 2 ;;
    --market-app-url) MARKET_APP_URL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

export CONNECTOR_VERSION="${VERSION#v}"
YES=()
[[ "${ASSUME_YES}" -eq 1 ]] && YES=(--yes)

case "${MODE}" in
  native)
    ARGS=(--version "v${CONNECTOR_VERSION}")
    [[ "${PORT_FROM_CLI}" -eq 1 ]] && ARGS+=(--port "${EXPOSED_PORT}")
    [[ "${NO_START}" -eq 1 ]] && ARGS+=(--no-start)
    [[ "${FORCE_ENV}" -eq 1 ]] && ARGS+=(--force-env)
    [[ "${ASSUME_YES}" -eq 1 ]] && ARGS+=(-y)
    [[ -n "${MARKET_APP_URL}" ]] && ARGS+=(--market-app-url "${MARKET_APP_URL}")
    [[ -n "${BASE_URL}" ]] && ARGS+=(--base-url "${BASE_URL}")
    exec bash "${REPO_ROOT}/scripts/install-native.sh" "${ARGS[@]}"
    ;;
  docker)
    require_root_or_sudo "docker install"
    [[ "${SKIP_DOCKER}" -eq 0 ]] && bash "${REPO_ROOT}/scripts/install-docker.sh" "${YES[@]+"${YES[@]}"}"
    [[ -n "${GHCR_TOKEN}" ]] || die "Docker mode requires --ghcr-token (private GHCR image)"
    echo "${GHCR_TOKEN}" | docker login ghcr.io --username "token" --password-stdin
    INIT_ARGS=(--tag "${CONNECTOR_VERSION}")
    [[ "${FORCE_ENV}" -eq 1 ]] && INIT_ARGS+=(--force)
    [[ "${PORT_FROM_CLI}" -eq 1 ]] && INIT_ARGS+=(--port "${EXPOSED_PORT}")
    [[ -n "${MARKET_APP_URL}" ]] && INIT_ARGS+=(--market-app-url "${MARKET_APP_URL}")
    [[ -n "${BASE_URL}" ]] && INIT_ARGS+=(--base-url "${BASE_URL}")
    bash "${REPO_ROOT}/scripts/init-env.sh" "${INIT_ARGS[@]}"
    export CONNECTOR_VERSION
    cd "${REPO_ROOT}"
    if [[ "${NO_START}" -eq 0 ]]; then
      docker compose pull
      docker compose up -d
    fi
    log_ok "Docker stack configured (CONNECTOR_VERSION=${CONNECTOR_VERSION})"
    ;;
  *)
    die "Unknown mode: ${MODE}"
    ;;
esac
