#!/usr/bin/env bash
# Public installer: native binary or Docker (GHCR). No source code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

if [[ ! -f "${REPO_ROOT}/scripts/lib/common.sh" ]]; then
  echo "Use autoinstaller (do not download install.sh alone):" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/v1.0.0/scripts/autoinstaller.sh | sudo bash -s -- --mode native --version v1.0.0 --yes" >&2
  exit 1
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
INSTALL_DIR=""
INSTALL_DIR_FROM_CLI=0
MARKET_APP_URL=""
BASE_URL=""

usage() {
  print_banner
  cat <<EOF

  ${C_BOLD}Asterisk Connector installer${C_RESET} (binary distribution)

  ${C_DIM}One-liner (рекомендуется):${C_RESET}
    curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/scripts/autoinstaller.sh \\
      | sudo bash -s -- --mode docker --version v1.0.0 --yes
    curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/scripts/autoinstaller.sh \\
      | sudo bash -s -- --mode native --version v1.0.0 --yes

  ${C_DIM}Из клона установщика:${C_RESET}  $(basename "$0") --mode native|docker --version vX.Y.Z [опции]

  ${C_BLUE}--mode${C_RESET} MODE          native | docker (default: docker)
  ${C_BLUE}--version${C_RESET} TAG        release tag, e.g. v1.0.0
  ${C_BLUE}--install-dir${C_RESET} DIR    native install path (default: /opt/asterisk24-connector)
  ${C_BLUE}--ghcr-token${C_RESET} TOKEN   optional (public GHCR image; for private registries)
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
    --install-dir) INSTALL_DIR="${2:-}"; INSTALL_DIR_FROM_CLI=1; shift 2 ;;
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
    [[ "${INSTALL_DIR_FROM_CLI}" -eq 1 ]] && ARGS+=(--install-dir "${INSTALL_DIR}")
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
    if [[ -n "${GHCR_TOKEN}" ]]; then
      echo "${GHCR_TOKEN}" | docker login ghcr.io --username "token" --password-stdin
    fi
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
