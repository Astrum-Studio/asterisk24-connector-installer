#!/usr/bin/env bash
# Root on a test host: dry native layout without starting systemd (port 8099).
set -euo pipefail
VER="${1:-v1.0.1}"
DIR="${2:-/opt/asterisk24-connector-smoke}"
PORT="${3:-8099}"
curl -fsSL "https://github.com/Astrum-Studio/asterisk24-connector-installer/releases/download/${VER}/autoinstaller.sh" \
  | bash -s -- --mode native --version "${VER}" --yes --no-start --install-dir "${DIR}" --port "${PORT}"
test -x "${DIR}/connector"
"${DIR}/connector" probe 2>/dev/null || true
echo "OK: ${DIR} (port ${PORT}, not started)"
