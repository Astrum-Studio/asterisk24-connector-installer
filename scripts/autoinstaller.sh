#!/usr/bin/env bash
# One-liner bootstrap: clone public installer at release tag and run install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/Astrum-Studio/asterisk24-connector-installer/v1.0.0/scripts/autoinstaller.sh \
#     | sudo bash -s -- --mode docker --version v1.0.0 --ghcr-token "$TOKEN" --yes
set -euo pipefail

_AUTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_AUTO_DIR}/lib/common.sh"

INSTALLER_REPO="${INSTALLER_REPO:-Astrum-Studio/asterisk24-connector-installer}"
INSTALLER_GIT="${INSTALLER_GIT:-https://github.com/${INSTALLER_REPO}.git}"
DEFAULT_WORK_DIR="${DEFAULT_WORK_DIR:-/opt/asterisk24-connector-installer}"
DEFAULT_REF="${DEFAULT_REF:-v1.0.0}"

MODE="docker"
REF="${DEFAULT_REF}"
WORK_DIR=""
ASSUME_YES=0
SKIP_DOCKER=0
GHCR_TOKEN=""
EXPOSED_PORT=""
EXTRA_ARGS=()

usage() {
  cat <<EOF
Asterisk24 Connector autoinstaller (binary distribution).

  curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/v1.0.0/scripts/autoinstaller.sh \\
    | sudo bash -s -- --mode native --version v1.0.0 --yes

Options: --mode docker|native  --version|--ref TAG  --install-dir DIR
         --ghcr-token TOKEN  --skip-docker  --port N  -y/--yes  -h/--help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --version|--ref) REF="${2:-}"; shift 2 ;;
    --install-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="${2:-}"; shift 2 ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --port) EXPOSED_PORT="${2:-}"; shift 2 ;;
    --base-url|--market-app-url)
      EXTRA_ARGS+=("$1" "${2:-}"); shift 2 ;;
    --no-start|--force-env) EXTRA_ARGS+=("$1"); shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[[ -n "${REF}" ]] || REF="${DEFAULT_REF}"
case "${REF}" in v*) ;; *) REF="v${REF#v}" ;; esac
WORK_DIR="${WORK_DIR:-${DEFAULT_WORK_DIR}}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: curl … | sudo bash -s -- …" >&2
  exit 1
fi
command -v git >/dev/null 2>&1 || die "git is required" "apt install git"

log_info "Syncing ${INSTALLER_REPO} @ ${REF} → ${WORK_DIR}"
sync_installer_git_repo "${REF}" "${WORK_DIR}" "${INSTALLER_GIT}"

chmod +x "${WORK_DIR}/install.sh" "${WORK_DIR}/scripts/"*.sh 2>/dev/null || true

INSTALL_ARGS=(--mode "${MODE}" --version "${REF}")
[[ -n "${GHCR_TOKEN}" ]] && INSTALL_ARGS+=(--ghcr-token "${GHCR_TOKEN}")
[[ -n "${EXPOSED_PORT}" ]] && INSTALL_ARGS+=(--port "${EXPOSED_PORT}")
[[ "${SKIP_DOCKER}" -eq 1 ]] && INSTALL_ARGS+=(--skip-docker)
[[ "${ASSUME_YES}" -eq 1 ]] && INSTALL_ARGS+=(--yes)
INSTALL_ARGS+=("${EXTRA_ARGS[@]}")

exec bash "${WORK_DIR}/install.sh" "${INSTALL_ARGS[@]}"
