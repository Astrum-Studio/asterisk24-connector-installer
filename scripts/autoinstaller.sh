#!/usr/bin/env bash
# curl …/autoinstaller.sh | sudo bash -s -- --mode native --version v1.0.0 --yes
# Must work when stdin is a pipe (no BASH_SOURCE, no local files).
set -eo pipefail

INSTALLER_REPO="${INSTALLER_REPO:-Astrum-Studio/asterisk24-connector-installer}"
WORK_DIR="${INSTALLER_WORK_DIR:-/opt/asterisk24-connector-installer}"
REF="v1.0.1"
MODE="docker"
ASSUME_YES=0
SKIP_DOCKER=0
GHCR_TOKEN=""
EXPOSED_PORT=""
EXTRA_ARGS=()

die() {
  echo "autoinstaller: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: curl -fsSL .../autoinstaller.sh | sudo bash -s -- [options]

  --mode docker|native   --version vX.Y.Z   --install-dir DIR
  --ghcr-token TOKEN (optional)   --skip-docker   --port N   -y/--yes
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
    --base-url|--market-app-url) EXTRA_ARGS+=("$1" "${2:-}"); shift 2 ;;
    --no-start|--force-env) EXTRA_ARGS+=("$1"); shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[[ -n "${REF}" ]] || REF="v1.0.0"
case "${REF}" in v*) ;; *) REF="v${REF#v}" ;; esac

[[ "$(id -u)" -eq 0 ]] || die "run as root: curl … | sudo bash -s -- …"
command -v curl >/dev/null 2>&1 || die "install curl"
command -v tar >/dev/null 2>&1 || die "install tar"

url="https://github.com/${INSTALLER_REPO}/archive/refs/tags/${REF}.tar.gz"
tmp="$(mktemp -d)"
echo "›  Downloading installer ${REF} → ${WORK_DIR}"
curl -fsSL "${url}" -o "${tmp}/installer.tgz" || die "cannot download ${url}"
tar -xzf "${tmp}/installer.tgz" -C "${tmp}"
src="$(find "${tmp}" -maxdepth 1 -type d -name 'asterisk24-connector-installer-*' | head -1)"
[[ -n "${src}" && -f "${src}/install.sh" ]] || die "bad installer archive"
mkdir -p "$(dirname "${WORK_DIR}")"
rm -rf "${WORK_DIR}"
mv "${src}" "${WORK_DIR}"
rm -rf "${tmp}"
chmod +x "${WORK_DIR}/install.sh" "${WORK_DIR}/scripts/"*.sh 2>/dev/null || true

args=(--mode "${MODE}" --version "${REF}")
[[ -n "${GHCR_TOKEN}" ]] && args+=(--ghcr-token "${GHCR_TOKEN}")
[[ -n "${EXPOSED_PORT}" ]] && args+=(--port "${EXPOSED_PORT}")
[[ "${SKIP_DOCKER}" -eq 1 ]] && args+=(--skip-docker)
[[ "${ASSUME_YES}" -eq 1 ]] && args+=(--yes)
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && args+=("${EXTRA_ARGS[@]}")

exec bash "${WORK_DIR}/install.sh" "${args[@]}"
