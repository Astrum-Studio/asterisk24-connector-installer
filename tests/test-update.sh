#!/usr/bin/env bash
# Offline tests for connectorctl update / auto-update (native + docker).
# GitHub is mocked with a file:// tree; systemctl/docker/pg_* are stubs. No root, no network.
#
#   bash tests/test-update.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
export NO_COLOR=1 LC_ALL=C.UTF-8
FAILS=0 PASSES=0

# ─── tiny assert helpers ────────────────────────────────────
ok()   { PASSES=$((PASSES + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1" "output lacks [$3]"$'\n'"$(sed 's/^/         | /' <<<"${2:0:1500}")"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then fail "$1" "output unexpectedly has [$3]"; else ok "$1"; fi; }
filehas() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else fail "$1" "$2 lacks [$3]"; fi; }
filehasnt() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "$2 unexpectedly has [$3]"; else ok "$1"; fi; }
exists() { if [[ -e "$2" ]]; then ok "$1"; else fail "$1" "missing $2"; fi; }
absent() { if [[ -e "$2" ]]; then fail "$1" "unexpected $2"; else ok "$1"; fi; }

furl() { if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s' "$(cygpath -m "$1")"; else printf 'file://%s' "$1"; fi; }

# ─── mock GitHub ────────────────────────────────────────────
OWNER_REPO="Astrum-Studio/asterisk24-connector-installer"
GH="${W}/gh"
API_DIR="${GH}/api/repos/${OWNER_REPO}"
WEB_DIR="${GH}/web/${OWNER_REPO}"
RAW_DIR="${GH}/raw/${OWNER_REPO}"
mkdir -p "${API_DIR}" "${WEB_DIR}/releases/download" "${WEB_DIR}/archive/refs/tags" "${RAW_DIR}"
ALL_TAGS=()
export CONNECTOR_UPDATE_API_URL CONNECTOR_UPDATE_WEB_URL CONNECTOR_UPDATE_RAW_URL CONNECTOR_UPDATE_GHCR_URL
CONNECTOR_UPDATE_API_URL="$(furl "${GH}/api")"
CONNECTOR_UPDATE_WEB_URL="$(furl "${GH}/web")"
CONNECTOR_UPDATE_RAW_URL="$(furl "${GH}/raw")"
CONNECTOR_UPDATE_GHCR_URL="$(furl "${GH}/ghcr")"   # no such files → "image exists" (unknown)

write_indexes() {
  local t json="" atom=""
  for t in "${ALL_TAGS[@]}"; do
    json+="{\"tag_name\": \"${t}\", \"draft\": false, \"prerelease\": false},"
    atom+="<entry><id>tag:github.com,2008:Repository/1/${t}</id><link rel=\"alternate\" href=\"https://github.com/${OWNER_REPO}/releases/tag/${t}\"/></entry>"
  done
  printf '[%s{"tag_name": "v0.0.1-rc1", "draft": false, "prerelease": true}]' "${json}" >"${API_DIR}/releases"
  printf '<feed>%s</feed>' "${atom}" >"${WEB_DIR}/releases.atom"
}

# publish_tag TAG KIND  (good | bad = health fails | noasset | badsum)
unpublish_tag() {
  local t keep=()
  for t in "${ALL_TAGS[@]}"; do [[ "${t}" == "$1" ]] || keep+=("${t}"); done
  ALL_TAGS=("${keep[@]}"); rm -rf "${WEB_DIR}/releases/download/$1"; write_indexes
}

publish_tag() {
  local tag="$1" kind="${2:-good}" d="${WEB_DIR}/releases/download/$1" b="${W}/build/$1" v="${1#v}" cl
  ALL_TAGS+=("${tag}")
  # CHANGELOG at this tag: sections for every tag published so far
  cl="# Changelog"$'\n'
  local t
  for t in "${ALL_TAGS[@]}"; do cl+=$'\n'"## ${t} (2026-01-01)"$'\n\n'"- change in ${t}"$'\n'; done
  mkdir -p "${RAW_DIR}/${tag}"; printf '%s\n' "${cl}" >"${RAW_DIR}/${tag}/CHANGELOG.md"
  # installer archive (scripts + deploy from this checkout + marker)
  local a="${W}/arch/asterisk24-connector-installer-${v}"
  mkdir -p "${a}"; cp -r "${REPO}/scripts" "${REPO}/deploy" "${a}/"; cp "${REPO}/install.sh" "${REPO}/docker-compose.yml" "${a}/"
  printf '%s\n' "${tag}" >"${a}/scripts/MARK"
  tar -czf "${WEB_DIR}/archive/refs/tags/${tag}.tar.gz" -C "${W}/arch" "asterisk24-connector-installer-${v}"
  if [[ "${kind}" != "noasset" ]]; then
    mkdir -p "${d}" "${b}/connector-linux-amd64/db/migrations"
    {
      printf '#!/bin/sh\n# %s %s\n' "$([[ "${kind}" == bad ]] && echo BAD || echo GOOD)" "${tag}"
      printf 'case "$1" in migrate) echo "migrate %s" >> "$MIGRATE_LOG"; echo "rev-%s" > "$DBREV_FILE";; esac\n' "${tag}" "${v}"
    } >"${b}/connector-linux-amd64/connector"
    chmod +x "${b}/connector-linux-amd64/connector"
    echo "# env" >"${b}/connector-linux-amd64/db/migrations/env.py"
    tar -czf "${d}/connector-linux-amd64.tar.gz" -C "${b}" connector-linux-amd64
    (cd "${d}" && sha256sum connector-linux-amd64.tar.gz >SHA256SUMS)
    [[ "${kind}" == badsum ]] && printf '%064d  connector-linux-amd64.tar.gz\n' 0 >"${d}/SHA256SUMS"
  fi
  write_indexes
}

publish_tag v1.0.0 good
publish_tag v1.0.4 good
publish_tag v1.0.5 good
publish_tag v1.0.7 noasset      # release with no binary (changelog-only)
publish_tag v1.1.0 good
publish_tag v2.0.0 good

# ─── stubs ──────────────────────────────────────────────────
BIN="${W}/bin"; mkdir -p "${BIN}"
CALLS="${W}/calls.log"; : >"${CALLS}"
export CALLS
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"${BIN}/$1"; chmod +x "${BIN}/$1"; }
stub systemctl 'echo "systemctl $*" >>"$CALLS"; case "$1" in is-active) echo active;; show) echo "";; esac; exit 0'
stub journalctl 'exit 0'
stub chown 'exit 0'
stub sudo 'if [[ "$1" == "-u" ]]; then shift 2; fi; exec "$@"'
stub runuser 'shift 3; exec "$@"'
stub pg_dump 'while [[ $# -gt 0 ]]; do [[ "$1" == "-f" ]] && { echo DUMP >"$2"; exit 0; }; shift; done; exit 1'
stub pg_restore 'echo "pg_restore $*" >>"$CALLS"; exit 0'
stub psql 'cat "$DBREV_FILE" 2>/dev/null; exit 0'
stub docker '
echo "docker $*" >>"$CALLS"
args=" $* "
case "$args" in
  *" exec -T db pg_dump "*) echo DOCKER-DUMP; exit 0 ;;
  *" exec -T db psql "*) cat "$DBREV_FILE" 2>/dev/null; exit 0 ;;
  *" run --rm --no-deps -T app migrate"*)
     v="$(grep -E "^CONNECTOR_VERSION=" .env | cut -d= -f2)"; echo "migrate $v" >>"$MIGRATE_LOG"; echo "rev-$v" >"$DBREV_FILE"; exit 0 ;;
esac
exit 0'
export PATH="${BIN}:${PATH}"
export MIGRATE_LOG="${W}/migrate.log" DBREV_FILE="${W}/dbrev"
: >"${MIGRATE_LOG}"; echo "rev-1.0.4" >"${DBREV_FILE}"

# ─── fake installations ─────────────────────────────────────
make_installer_tree() {   # DIR
  mkdir -p "$1"; cp -r "${REPO}/scripts" "${REPO}/deploy" "$1/"; cp "${REPO}/docker-compose.yml" "${REPO}/install.sh" "$1/"
}

NINST="${W}/ninst"; NROOT="${W}/opt/connector"
make_installer_tree "${NINST}"
mkdir -p "${NROOT}/config" "${NROOT}/db/migrations"
printf '#!/bin/sh\n# GOOD v1.0.4\ncase "$1" in migrate) echo "migrate v1.0.4" >> "$MIGRATE_LOG";; esac\n' >"${NROOT}/connector"; chmod +x "${NROOT}/connector"
printf 'DB__HOST=127.0.0.1\nDB__PORT=5432\nDB__USER=connector\nDB__NAME=connector\nDB__PASSWORD=s3cret\nEXPOSED_APP_PORT=8079\nCONNECTOR__API_KEY=keep-me\n' >"${NROOT}/.env"
printf 'keep: true\n' >"${NROOT}/config/connector.yaml"
printf 'MODE=native\nINSTALL_DIR=%s\nVERSION=v1.0.4\nPORT=8079\n' "${NROOT}" >"${NROOT}/.install-meta"

DINST="${W}/dinst"
make_installer_tree "${DINST}"
printf 'DB__USER=connector\nDB__NAME=connector\nEXPOSED_APP_PORT=8079\nCONNECTOR_VERSION=1.0.4\nCONNECTOR_IMAGE_TAG=1.0.4\n' >"${DINST}/.env"
printf 'MODE=docker\nVERSION=v1.0.4\n' >"${DINST}/.install-meta"

export CONNECTORCTL_ALLOW_NONROOT=1 CONNECTORCTL_HEALTH_TIMEOUT=2 CONNECTORCTL_HEALTH_INTERVAL=1
export CONNECTORCTL_BACKUP_DIR="${W}/backups" CONNECTORCTL_LOCK_FILE="${W}/lock/update.lock"
export CONNECTORCTL_STATE_DIR="${W}/state" CONNECTORCTL_CONF_DIR="${W}/conf"
export CONNECTORCTL_SYSTEMD_DIR="${W}/systemd" CONNECTORCTL_CRON_DIR="${W}/cron"
export CONNECTORCTL_LOG_FILE="${W}/update.log"
export T_ROOT="${NROOT}" T_DROOT="${DINST}"

OUT="" RC=0
ctl() {  # ctl native|docker args…  → OUT, RC
  local m="$1" tree env_extra=()
  shift
  if [[ "${m}" == native ]]; then
    tree="${NINST}"
    env_extra=(CONNECTOR_INSTALL_DIR="${NROOT}" CONNECTORCTL_MODE=native
      CONNECTORCTL_TEST_HEALTH='grep -q GOOD "$T_ROOT/connector"')
  else
    tree="${DINST}"
    env_extra=(CONNECTORCTL_MODE=docker
      CONNECTORCTL_TEST_HEALTH='! grep -q "^CONNECTOR_VERSION=1.1.1" "$T_DROOT/.env"')
  fi
  OUT="$(env "${env_extra[@]}" bash "${tree}/scripts/connectorctl" "$@" 2>&1)"; RC=$?
}
nmeta() { grep -E "^$1=" "${NROOT}/.install-meta" | tail -1 | cut -d= -f2-; }
denv()  { grep -E "^$1=" "${DINST}/.env" | cut -d= -f2-; }

# ═══════════════════════════════════════════════════════════
echo "== semver / pure functions"
# shellcheck source=/dev/null
( set +u
  source "${REPO}/scripts/lib/common.sh"; source "${REPO}/scripts/lib/update.sh"; source "${REPO}/scripts/lib/autoupdate.sh"
  [[ "$(ver_cmp v1.0.4 v1.0.10)" == -1 ]] && [[ "$(ver_cmp 1.2.0 v1.1.9)" == 1 ]] \
    && [[ "$(ver_cmp v2.0.0 2.0.0)" == 0 ]] && [[ "$(ver_major v12.3.4)" == 12 ]] \
    && ver_valid v1.2.3 && ! ver_valid v1.2 && ! ver_valid latest \
    && auto_in_window 03:30 03:00 05:00 && ! auto_in_window 05:00 03:00 05:00 \
    && ! auto_in_window 02:59 03:00 05:00 && auto_in_window 23:30 22:00 02:00 \
    && auto_in_window 01:00 22:00 02:00 && ! auto_in_window 12:00 22:00 02:00 \
    && auto_in_window 08:15 08:00 09:00
) && ok "ver_cmp / ver_valid / ver_major / auto_in_window" || fail "pure functions"

# ═══════════════════════════════════════════════════════════
echo "== update --check (native)"
ctl native update --check
eq "check: exit 10 when update available" "${RC}" 10
has "check: shows installed" "${OUT}" "v1.0.4"
has "check: picks newest in-major with artifact (v1.1.0, skips asset-less v1.0.7)" "${OUT}" "Доступно"
has "check: target v1.1.0" "${OUT}" "v1.1.0"
has "check: mentions newer major" "${OUT}" "v2.0.0"
has "check: changelog of target" "${OUT}" "change in v1.1.0"
has "check: changelog of skipped release between" "${OUT}" "change in v1.0.7"
hasnt "check: no changelog of installed version" "${OUT}" "change in v1.0.4"
eq "check changed nothing: meta" "$(nmeta VERSION)" v1.0.4

mv "${API_DIR}/releases" "${API_DIR}/releases.off"
ctl native update --check
eq "API unavailable → atom fallback works (exit 10)" "${RC}" 10
has "API fallback is announced" "${OUT}" "releases.atom"
mv "${API_DIR}/releases.off" "${API_DIR}/releases"

mv "${WEB_DIR}/releases.atom" "${WEB_DIR}/releases.atom.off"; mv "${API_DIR}/releases" "${API_DIR}/releases.off"
ctl native update --check
eq "no release source at all → exit 1" "${RC}" 1
has "clear error without releases" "${OUT}" "Не удалось получить список релизов"
mv "${WEB_DIR}/releases.atom.off" "${WEB_DIR}/releases.atom"; mv "${API_DIR}/releases.off" "${API_DIR}/releases"

# ═══════════════════════════════════════════════════════════
echo "== native update: minor/patch within major"
ctl native update
eq "update exit 0" "${RC}" 0
eq "meta VERSION = v1.1.0" "$(nmeta VERSION)" v1.1.0
eq "meta PREVIOUS_VERSION = v1.0.4" "$(nmeta PREVIOUS_VERSION)" v1.0.4
filehas "binary replaced" "${NROOT}/connector" "GOOD v1.1.0"
filehas ".env preserved" "${NROOT}/.env" "CONNECTOR__API_KEY=keep-me"
filehas "config preserved" "${NROOT}/config/connector.yaml" "keep: true"
exists "previous code kept for rollback" "${NROOT}/.rollback/v1.0.4/connector"
filehas "previous binary is the old one" "${NROOT}/.rollback/v1.0.4/connector" "GOOD v1.0.4"
exists "migrations bundle installed" "${NROOT}/db/migrations/env.py"
filehas "migrate ran with new binary" "${MIGRATE_LOG}" "migrate v1.1.0"
filehas "services stopped+restarted" "${CALLS}" "systemctl restart"
exists "backup created before update" "$(ls "${W}"/backups/connector-*.tar.gz 2>/dev/null | head -1)"
exists "installer scripts refreshed from release" "${NINST}/scripts/MARK"
absent "stage cleaned up" "${NROOT}/.stage"

ctl native update
eq "second update: up to date (exit 0)" "${RC}" 0
has "second update: message" "${OUT}" "обновлений нет"
has "second update: newer major hint" "${OUT}" "v2.0.0"
ctl native update --check
eq "check after update: exit 11 (only new major)" "${RC}" 11

echo "== native update: major only with --allow-major, explicit version, downgrade"
ctl native update --allow-major
eq "--allow-major exit 0" "${RC}" 0
eq "now v2.0.0" "$(nmeta VERSION)" v2.0.0
ctl native update --check
eq "check at newest: exit 0" "${RC}" 0
ctl native update --version v1.0.5
eq "--version downgrade exit 0" "${RC}" 0
eq "downgraded to v1.0.5" "$(nmeta VERSION)" v1.0.5
has "downgrade warns about DB schema" "${OUT}" "Понижение версии"
filehas "downgraded binary" "${NROOT}/connector" "GOOD v1.0.5"
ctl native update --version v1.0.7
eq "--version without artifact → exit 1" "${RC}" 1
eq "nothing changed after refusal" "$(nmeta VERSION)" v1.0.5
ctl native update --version nonsense
eq "invalid --version → exit 1" "${RC}" 1
ctl native update --version v1.1.0
eq "back to v1.1.0" "$(nmeta VERSION)" v1.1.0

echo "== native: checksum mismatch"
publish_tag v1.1.2 badsum
ctl native update --version v1.1.2
eq "bad checksum → exit 1" "${RC}" 1
has "bad checksum message" "${OUT}" "Checksum mismatch"
eq "version unchanged after bad checksum" "$(nmeta VERSION)" v1.1.0
filehas "binary unchanged after bad checksum" "${NROOT}/connector" "GOOD v1.1.0"
absent "stage removed after bad checksum" "${NROOT}/.stage"
unpublish_tag v1.1.2

echo "== native: health-check failure → automatic rollback"
publish_tag v1.1.1 bad
: >"${CALLS}"; echo "rev-1.1.0" >"${DBREV_FILE}"
ctl native update --version v1.1.1
eq "failed update → exit 3 (rolled back)" "${RC}" 3
has "rollback announced" "${OUT}" "Откат"
has "DB restore warning (migrations ran)" "${OUT}" "восстанавливаю БД из бэкапа"
filehas "pg_restore called" "${CALLS}" "pg_restore"
eq "meta stays v1.1.0" "$(nmeta VERSION)" v1.1.0
filehas "previous binary restored" "${NROOT}/connector" "GOOD v1.1.0"
filehas ".env intact after rollback" "${NROOT}/.env" "CONNECTOR__API_KEY=keep-me"
unpublish_tag v1.1.1

echo "== lock"
mkdir -p "${W}/lock"
if command -v flock >/dev/null 2>&1; then
  ( exec 9>"${CONNECTORCTL_LOCK_FILE}"; flock 9; sleep 6 ) & HOLDER=$!
else
  mkdir -p "${CONNECTORCTL_LOCK_FILE}.d"; sleep 6 & HOLDER=$!; echo "${HOLDER}" >"${CONNECTORCTL_LOCK_FILE}.d/pid"
fi
sleep 1
ctl native update --version v1.0.5
eq "concurrent update refused (exit 5)" "${RC}" 5
has "lock message" "${OUT}" "уже выполняется"
eq "locked run changed nothing" "$(nmeta VERSION)" v1.1.0
kill "${HOLDER}" 2>/dev/null; wait "${HOLDER}" 2>/dev/null
rm -rf "${CONNECTORCTL_LOCK_FILE}.d"
ctl native update --version v1.0.5
eq "lock released afterwards" "${RC}" 0
ctl native update --version v1.1.0

# ═══════════════════════════════════════════════════════════
echo "== docker"
ctl docker update --check
eq "docker check: exit 10" "${RC}" 10
has "docker check: mode" "${OUT}" "docker"
has "docker check: installed v1.0.4" "${OUT}" "v1.0.4"
: >"${CALLS}"
ctl docker update
eq "docker update exit 0" "${RC}" 0
eq "CONNECTOR_VERSION bumped (no v prefix)" "$(denv CONNECTOR_VERSION)" 1.1.0
eq "CONNECTOR_IMAGE_TAG synced" "$(denv CONNECTOR_IMAGE_TAG)" 1.1.0
filehas "compose pull" "${CALLS}" "docker compose pull"
filehas "compose migrate" "${CALLS}" "run --rm --no-deps -T app migrate"
filehas "compose up -d" "${CALLS}" "up -d"
eq "docker meta VERSION" "$(grep -E '^VERSION=' "${DINST}/.install-meta" | tail -1 | cut -d= -f2)" v1.1.0
exists "docker backup created" "$(ls "${W}"/backups/connector-*.tar.gz 2>/dev/null | tail -1)"
ctl docker update
has "docker: up to date in major" "${OUT}" "обновлений нет"
ctl docker update --version v1.0.5
eq "docker downgrade exit 0" "${RC}" 0
eq "docker downgraded" "$(denv CONNECTOR_VERSION)" 1.0.5
ctl docker update --version v1.1.0
echo "rev-1.1.0" >"${DBREV_FILE}"; : >"${CALLS}"
publish_tag v1.1.1 bad
ctl docker update --version v1.1.1
eq "docker health failure → exit 3" "${RC}" 3
eq "docker .env restored" "$(denv CONNECTOR_VERSION)" 1.1.0
has "docker rollback announced" "${OUT}" "Откат"
has "docker DB restore (migrations ran)" "${OUT}" "восстанавливаю БД из бэкапа"
unpublish_tag v1.1.1
ctl docker status
eq "native-only command refused in docker mode" "${RC}" 1
has "docker mode hint" "${OUT}" "только для native"

# ═══════════════════════════════════════════════════════════
echo "== auto-update"
ctl native auto-update status
has "status when disabled" "${OUT}" "выключено"

ctl native auto-update enable --window 25:00-05:00
eq "invalid window rejected" "${RC}" 1

CONNECTORCTL_FORCE_CRON=1 ctl native auto-update enable --window 02:00-04:00 --every 12
eq "enable (cron) exit 0" "${RC}" 0
exists "cron file created" "${CONNECTORCTL_CRON_DIR}/connectorctl-auto-update"
filehas "cron runs auto-update run" "${CONNECTORCTL_CRON_DIR}/connectorctl-auto-update" "auto-update run"
filehas "conf window" "${CONNECTORCTL_CONF_DIR}/auto-update.conf" "WINDOW_START=02:00"
filehas "conf interval" "${CONNECTORCTL_CONF_DIR}/auto-update.conf" "EVERY_HOURS=12"
CONNECTORCTL_FORCE_CRON=1 ctl native auto-update disable
absent "cron removed" "${CONNECTORCTL_CRON_DIR}/connectorctl-auto-update"
absent "conf removed" "${CONNECTORCTL_CONF_DIR}/auto-update.conf"

: >"${CALLS}"
CONNECTORCTL_FORCE_SYSTEMD=1 ctl native auto-update enable
eq "enable (systemd) exit 0" "${RC}" 0
exists "service unit rendered" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.service"
exists "timer unit rendered" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.timer"
filehasnt "placeholder replaced" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.service" "__CTL__"
filehas "service runs auto-update run" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.service" "auto-update run"
filehas "timer enabled" "${CALLS}" "enable --now connectorctl-update.timer"
CONNECTORCTL_FORCE_SYSTEMD=1 ctl native auto-update status
has "status enabled" "${OUT}" "включено"
has "status default window" "${OUT}" "03:00-05:00"

echo "-- policy: window"
CONNECTORCTL_NOW=12:00 ctl native auto-update run
eq "outside window: exit 0" "${RC}" 0
has "outside window: skipped" "${OUT}" "вне окна"
eq "outside window: version unchanged" "$(nmeta VERSION)" v1.1.0

echo "-- policy: never major automatically"
CONNECTORCTL_NOW=03:30 CONNECTORCTL_EPOCH=1000000 ctl native auto-update run
eq "inside window, only major available: exit 0" "${RC}" 0
eq "major NOT installed automatically" "$(nmeta VERSION)" v1.1.0
filehas "state: major-available" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "LAST_RESULT=major-available"
CONNECTORCTL_NOW=03:40 CONNECTORCTL_EPOCH=1000600 ctl native auto-update run
has "interval respected (no second check)" "${OUT}" "пропуск"

echo "-- policy: minor/patch installed automatically"
publish_tag v1.1.3 good
rm -f "${CONNECTORCTL_STATE_DIR}/auto-update.state"
CONNECTORCTL_NOW=04:00 CONNECTORCTL_EPOCH=2000000 ctl native auto-update run
eq "auto update exit 0" "${RC}" 0
eq "auto-updated to v1.1.3" "$(nmeta VERSION)" v1.1.3
filehas "state: updated" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "LAST_RESULT=updated"
filehas "state: version" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "LAST_VERSION=v1.1.3"
CONNECTORCTL_FORCE_SYSTEMD=1 ctl native auto-update status
has "status shows result" "${OUT}" "updated"
has "status shows version" "${OUT}" "v1.1.3"

echo "-- policy: rolled-back version is not retried"
publish_tag v1.1.4 bad
echo "rev-1.1.3" >"${DBREV_FILE}"
CONNECTORCTL_NOW=04:00 CONNECTORCTL_EPOCH=3000000 ctl native auto-update run
eq "auto update with failing health → exit 3" "${RC}" 3
eq "version stays v1.1.3 after auto rollback" "$(nmeta VERSION)" v1.1.3
filehas "state: rolled-back" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "LAST_RESULT=rolled-back"
filehas "state: skip version" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "SKIP_VERSION=v1.1.4"
CONNECTORCTL_NOW=04:00 CONNECTORCTL_EPOCH=4000000 ctl native auto-update run
eq "bad version skipped next time: exit 0" "${RC}" 0
filehas "state: skipped" "${CONNECTORCTL_STATE_DIR}/auto-update.state" "LAST_RESULT=skipped"
eq "still v1.1.3" "$(nmeta VERSION)" v1.1.3

echo "-- disable removes everything"
CONNECTORCTL_FORCE_SYSTEMD=1 ctl native auto-update disable
eq "disable exit 0" "${RC}" 0
absent "timer unit removed" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.timer"
absent "service unit removed" "${CONNECTORCTL_SYSTEMD_DIR}/connectorctl-update.service"
absent "state removed" "${CONNECTORCTL_STATE_DIR}/auto-update.state"
filehas "timer disabled via systemctl" "${CALLS}" "disable --now connectorctl-update.timer"
ctl native auto-update run
has "run is a no-op when disabled" "${OUT}" "не включён"

echo "-- native-only guard / legacy"
ctl native update --source "${W}/does-not-exist"
eq "legacy --source with bad dir → exit 1" "${RC}" 1

# ═══════════════════════════════════════════════════════════
echo
echo "passed: ${PASSES}, failed: ${FAILS}"
[[ "${FAILS}" -eq 0 ]]
