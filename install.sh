#!/usr/bin/env bash
# Public installer: native binary or Docker (GHCR). No source code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

MODE="docker"
ASSUME_YES=0
NO_START=0
FORCE_ENV=0
VERSION="${CONNECTOR_VERSION:-1.0.0}"
GHCR_TOKEN=""
EXPOSED_PORT="${DEFAULT_PORT}"

usage() {
  print_banner
  cat <<EOF

  ${C_BOLD}Asterisk Connector installer${C_RESET} (binary distribution)

  $(basename "$0") --mode native|docker --version vX.Y.Z [options]

  ${C_BLUE}--mode${C_RESET} MODE          native | docker (default: docker)
  ${C_BLUE}--version${C_RESET} TAG        release tag, e.g. v1.0.0
  ${C_BLUE}--ghcr-token${C_RESET} TOKEN   required for docker (private GHCR)
  ${C_BLUE}--port${C_RESET} PORT          host port (default ${DEFAULT_PORT})
  ${C_BLUE}-y, --yes${C_RESET}             non-interactive
  ${C_BLUE}--no-start${C_RESET}           config only
  ${C_BLUE}--force-env${C_RESET}          regenerate secrets

  ${C_DIM}Example:${C_RESET}
    curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/install.sh -o install.sh
    sudo bash install.sh --mode native --version v1.0.0
    sudo bash install.sh --mode docker --version v1.0.0 --ghcr-token "\$TOKEN"

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --version) VERSION="${2#v}"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="${2:-}"; shift 2 ;;
    --port) EXPOSED_PORT="${2:-}"; shift 2 ;;
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
    [[ "${PORT_FROM_CLI:-0}" -eq 1 ]] && ARGS+=(--port "${EXPOSED_PORT}")
    [[ "${NO_START}" -eq 1 ]] && ARGS+=(--no-start)
    [[ "${FORCE_ENV}" -eq 1 ]] && ARGS+=(--force-env)
    [[ "${ASSUME_YES}" -eq 1 ]] && ARGS+=(-y)
    exec bash "${REPO_ROOT}/scripts/install-native.sh" "${ARGS[@]}"
    ;;
  docker)
    [[ -n "${GHCR_TOKEN}" ]] || die "Docker mode requires --ghcr-token (private GHCR image)"
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u USER --password-stdin 2>/dev/null \
      || echo "${GHCR_TOKEN}" | docker login ghcr.io --username "token" --password-stdin
    INIT_ARGS=(--tag "${CONNECTOR_VERSION}")
    [[ "${FORCE_ENV}" -eq 1 ]] && INIT_ARGS+=(--force)
    INIT_ARGS+=(--port "${EXPOSED_PORT}")
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
