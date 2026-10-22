#!/usr/bin/env bash
# Native install from published connector binary (no Python source).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSUME_YES=0
NO_START=0
FORCE_ENV=0
PORT_FROM_CLI=0
VERSION="${CONNECTOR_VERSION:-1.0.0}"
VERSION_FROM_CLI=0
INSTALL_DIR="${DEFAULT_NATIVE_INSTALL_DIR}"
INSTALL_DIR_FROM_CLI=0
EXPOSED_PORT="${DEFAULT_PORT}"
MARKET_APP_URL=""
BASE_URL=""
GHCR_TOKEN=""
SYSTEMD_UNITS=(connector-app connector-ami connector-outbox connector-cel connector-recording)

usage() {
  cat <<EOF
Native install (systemd + binary from GitHub Release).

  $(basename "$0") --version v1.0.0 [options]

  --version TAG     release tag (required unless CONNECTOR_VERSION set)
  --install-dir DIR default: ${DEFAULT_NATIVE_INSTALL_DIR}
  --port PORT       API port (default ${DEFAULT_PORT})
  -y, --yes         non-interactive
  --no-start        prepare only
  --force-env       regenerate secrets
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --version) VERSION="${2#v}"; VERSION_FROM_CLI=1; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; INSTALL_DIR_FROM_CLI=1; shift 2 ;;
    --port) EXPOSED_PORT="${2:-}"; PORT_FROM_CLI=1; shift 2 ;;
    --market-app-url) MARKET_APP_URL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "${VERSION_FROM_CLI}" -eq 1 || -n "${VERSION}" ]] || die "Pass --version vX.Y.Z"
require_root_or_sudo "native install"
has_systemd || die "systemd required"
arch_supported || die "Unsupported CPU arch: $(uname -m)" "Use linux/amd64 or arm64"
ensure_native_packages

TAG="v${VERSION#v}"
ASSET="connector-linux-amd64.tar.gz"
RELEASE_API="https://github.com/${INSTALLER_REPO}/releases/download/${TAG}/${ASSET}"
SUMS_API="https://github.com/${INSTALLER_REPO}/releases/download/${TAG}/SHA256SUMS"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

log_info "Downloading ${ASSET} (${TAG})…"
curl -fsSL "${RELEASE_API}" -o "${TMP}/${ASSET}"
curl -fsSL "${SUMS_API}" -o "${TMP}/SHA256SUMS"
verify_release_tarball "${TMP}" "${ASSET}"

tar -xzf "${TMP}/${ASSET}" -C "${TMP}"
SRC_TREE="${TMP}/connector-linux-amd64"
[[ -x "${SRC_TREE}/connector" ]] || die "Invalid tarball layout"

${SUDO} mkdir -p "${INSTALL_DIR}"
${SUDO} rsync -a --delete "${SRC_TREE}/" "${INSTALL_DIR}/"
${SUDO} chmod 755 "${INSTALL_DIR}/connector"

if ! id -u "${DEFAULT_CONNECTOR_USER}" >/dev/null 2>&1; then
  ${SUDO} useradd --system --home-dir "${INSTALL_DIR}" --no-create-home \
    --shell /usr/sbin/nologin "${DEFAULT_CONNECTOR_USER}"
fi

INIT_ARGS=(--native)
[[ "${FORCE_ENV}" -eq 1 ]] && INIT_ARGS+=(--force)
[[ "${PORT_FROM_CLI}" -eq 1 ]] && INIT_ARGS+=(--port "${EXPOSED_PORT}")
[[ -n "${MARKET_APP_URL}" ]] && INIT_ARGS+=(--market-app-url "${MARKET_APP_URL}")
[[ -n "${BASE_URL}" ]] && INIT_ARGS+=(--base-url "${BASE_URL}")
INIT_ARGS+=(--tag "${VERSION}")
${SUDO} env CONNECTOR_INSTALL_DIR="${INSTALL_DIR}" bash "${REPO_ROOT}/scripts/init-env.sh" "${INIT_ARGS[@]}"

${SUDO} bash "${REPO_ROOT}/scripts/install-postgres.sh" --env-file "${INSTALL_DIR}/.env" $([[ "${ASSUME_YES}" -eq 1 ]] && echo --yes)

for name in "${SYSTEMD_UNITS[@]}"; do
  if ${SUDO} systemctl is-active --quiet "${name}" 2>/dev/null; then
    log_info "Stopping ${name} (upgrade)…"
    ${SUDO} systemctl stop "${name}" || true
  fi
done

PROTECT_HOME=true
case "${INSTALL_DIR}" in /root|/root/*|/home/*) PROTECT_HOME=false ;; esac

for name in "${SYSTEMD_UNITS[@]}"; do
  unit_src="${REPO_ROOT}/deploy/systemd/${name}.service"
  rendered="$(mktemp)"
  sed \
    -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
    -e "s|__LISTEN_PORT__|${EXPOSED_PORT}|g" \
    -e "s|__PROTECT_HOME__|${PROTECT_HOME}|g" \
    "${unit_src}" >"${rendered}"
  ${SUDO} install -m 0644 "${rendered}" "/etc/systemd/system/${name}.service"
  rm -f "${rendered}"
done

${SUDO} chown root:"${DEFAULT_CONNECTOR_USER}" "${INSTALL_DIR}/.env"
${SUDO} chmod 640 "${INSTALL_DIR}/.env"
${SUDO} chown -R root:root "${INSTALL_DIR}"
${SUDO} chmod -R go+rX,go-w "${INSTALL_DIR}"

log_info "Database migrations…"
run_as_user "${DEFAULT_CONNECTOR_USER}" env ENV_FILE="${INSTALL_DIR}/.env" CONNECTOR_HOME="${INSTALL_DIR}" \
  "${INSTALL_DIR}/connector" migrate

${SUDO} systemctl daemon-reload
if [[ "${NO_START}" -eq 0 ]]; then
  ${SUDO} systemctl enable --now "${SYSTEMD_UNITS[@]}"
fi

log_ok "Installed connector ${TAG} → ${INSTALL_DIR}"
