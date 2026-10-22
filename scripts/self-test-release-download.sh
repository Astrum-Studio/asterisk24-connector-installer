#!/usr/bin/env bash
# CI/local: download connector Release assets and verify checksum (no install).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAG="${1:-v1.0.0}"
case "${TAG}" in v*) ;; *) TAG="v${TAG#v}" ;; esac
ASSET="connector-linux-amd64.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

url="https://github.com/${INSTALLER_REPO}/releases/download/${TAG}/${ASSET}"
sums="https://github.com/${INSTALLER_REPO}/releases/download/${TAG}/SHA256SUMS"
curl -fsSL "${url}" -o "${TMP}/${ASSET}"
curl -fsSL "${sums}" -o "${TMP}/SHA256SUMS"
verify_release_tarball "${TMP}" "${ASSET}"
if ! tar -tzf "${TMP}/${ASSET}" | grep -q '^connector-linux-amd64/connector$'; then
  die "Tarball missing connector-linux-amd64/connector"
fi
log_ok "Release ${TAG} download + checksum OK"
