#!/usr/bin/env bash
# Offline checks: worker-workday in docker-compose.yml, native systemd unit, connectorctl sync-units.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi; }

COMPOSE="${ROOT}/docker-compose.yml"
UNIT="${ROOT}/deploy/systemd/connector-workday.service"

# ── docker ──
check "compose: service worker-workday present" grep -q '^  worker-workday:' "${COMPOSE}"
check "compose: command worker workday" grep -q 'command: \["worker", "workday"\]' "${COMPOSE}"
check "compose: workday heartbeat path" grep -q '/tmp/connector-workday.heartbeat' "${COMPOSE}"
check "compose: workday not behind a profile" bash -c "! sed -n '/^  worker-workday:/,/^  worker-recording:/p' '${COMPOSE}' | grep -q profiles"
check "compose: connector.yaml mount is not mandatory" bash -c "! grep -v '^ *#' '${COMPOSE}' | grep -q 'connector.yaml'"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  cp "${COMPOSE}" "${tmp}/docker-compose.yml"
  printf 'CONNECTOR_VERSION=1.0.0\nDB__PASSWORD=x\n' >"${tmp}/.env"; : >"${tmp}/db.env"
  check "compose: docker compose config lists worker-workday" bash -c "cd '${tmp}' && docker compose config --services | grep -qx worker-workday"
  rm -rf "${tmp}"
else
  printf 'skip docker compose config (docker not available)\n'
fi

# ── native ──
check "unit: file exists" test -f "${UNIT}"
check "unit: ExecStart worker workday" grep -q '^ExecStart=__INSTALL_DIR__/connector worker workday$' "${UNIT}"
check "unit: SyslogIdentifier" grep -q '^SyslogIdentifier=connector-workday$' "${UNIT}"
for f in scripts/install-native.sh scripts/uninstall-native.sh scripts/connectorctl; do
  check "${f}: lists connector-workday" grep -q 'connector-workday' "${ROOT}/${f}"
done
for u in "${ROOT}"/deploy/systemd/connector-*.service; do
  n="$(basename "${u}" .service)"
  check "install-native lists ${n}" grep -q "${n}" "${ROOT}/scripts/install-native.sh"
done

# ── connectorctl sync-units (old install without the workday unit) ──
tmp="$(mktemp -d)"; bin="${tmp}/bin"; sysd="${tmp}/systemd"; mkdir -p "${bin}" "${sysd}" "${tmp}/opt"
printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "${tmp}" >"${bin}/systemctl"; chmod +x "${bin}/systemctl"
for n in connector-app connector-ami connector-outbox connector-cel connector-recording; do : >"${sysd}/${n}.service"; done
run() { PATH="${bin}:${PATH}" CONNECTORCTL_SYSTEMD_DIR="${sysd}" CONNECTOR_INSTALL_DIR="${tmp}/opt" bash "${ROOT}/scripts/connectorctl" sync-units; }
out="$(run 2>&1)"; rc=$?
[[ ${rc} -eq 0 ]] && ok "sync-units: exit 0" || { bad "sync-units: exit ${rc}: ${out}"; }
check "sync-units: workday unit installed" test -s "${sysd}/connector-workday.service"
check "sync-units: placeholders rendered" bash -c "! grep -q '__' '${sysd}/connector-workday.service'"
check "sync-units: install dir substituted" grep -q "${tmp}/opt/connector worker workday" "${sysd}/connector-workday.service"
check "sync-units: existing units untouched" bash -c "[[ ! -s '${sysd}/connector-app.service' ]]"
check "sync-units: enable --now only for workday" grep -qx 'systemctl enable --now connector-workday' "${tmp}/calls"
: >"${tmp}/calls"
out="$(run 2>&1)"
check "sync-units: idempotent (no systemctl calls)" bash -c "[[ ! -s '${tmp}/calls' ]]"
rm -rf "${tmp}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
