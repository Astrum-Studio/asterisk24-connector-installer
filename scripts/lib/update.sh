#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with connectorctl and the other lib
# Update engine for connectorctl (native systemd + docker compose installs).
# Sourced by scripts/connectorctl after lib/common.sh.
#
# Expects these globals from connectorctl:
#   MODE (native|docker)  ROOT  ENV_FILE  META_FILE  UNITS[]  INSTALLER_ROOT
# and helpers: meta_get env_val app_port http_code need_root cmd_backup
#
# Exit codes of `connectorctl update`:
#   0 ok / up to date      1 error before any change     3 failed, rolled back
#   4 failed, rollback failed   5 another update is running
#  10 (--check) update available   11 (--check) only a newer major is available

UPD_API="${CONNECTOR_UPDATE_API_URL:-https://api.github.com}"
UPD_WEB="${CONNECTOR_UPDATE_WEB_URL:-https://github.com}"
UPD_RAW="${CONNECTOR_UPDATE_RAW_URL:-https://raw.githubusercontent.com}"
UPD_GHCR="${CONNECTOR_UPDATE_GHCR_URL:-https://ghcr.io}"
UPD_ASSET="connector-linux-amd64.tar.gz"
UPD_PROTECTED=(.env .install-meta config .rollback .stage)
UPD_NOTE=""
UPD_TARGET=""
UPD_NEWER_MAJOR=""
UPD_RESULT=""

# ─── semver ─────────────────────────────────────────────────

ver_strip() { local v="${1#v}"; v="${v%%[-+]*}"; printf '%s' "${v}"; }
ver_tag()   { printf 'v%s' "$(ver_strip "$1")"; }
ver_valid() { [[ "$(ver_strip "$1")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
ver_major() { local v; v="$(ver_strip "$1")"; printf '%s' "${v%%.*}"; }

# ver_cmp A B → prints -1 (A<B), 0, 1 (A>B)
ver_cmp() {
  local a b i x y
  IFS=. read -r -a a <<<"$(ver_strip "$1")"
  IFS=. read -r -a b <<<"$(ver_strip "$2")"
  for i in 0 1 2; do
    x=$((10#${a[i]:-0})); y=$((10#${b[i]:-0}))
    if ((x < y)); then printf '%s' -1; return 0; fi
    if ((x > y)); then printf '%s' 1; return 0; fi
  done
  printf '%s' 0
}

# ─── GitHub Releases ────────────────────────────────────────

# upd_http_get URL OUTFILE → prints HTTP status (200 for file://, 000 on transport error)
upd_http_get() {
  local url="$1" out="$2" code auth=()
  if [[ -n "${GITHUB_TOKEN:-}" && "${url}" == "${UPD_API}"* ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  code="$(curl -sSL --connect-timeout 10 --max-time 120 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: connectorctl' \
    "${auth[@]+"${auth[@]}"}" -o "${out}" -w '%{http_code}' "${url}" 2>/dev/null)" || code="000"
  if [[ "${url}" == file://* ]]; then
    [[ -s "${out}" ]] && code=200 || code=000
  fi
  printf '%s' "${code}"
}

upd_stable_sorted() {
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | sort -V -r
}

# Sets UPD_TAGS (stable release tags, newest first). Falls back API → atom feed → /releases/latest.
upd_list_tags() {
  local tmp code tags="" via=""
  tmp="$(mktemp)"
  UPD_NOTE=""
  code="$(upd_http_get "${UPD_API}/repos/${INSTALLER_REPO}/releases" "${tmp}")"
  if [[ "${code}" == "200" ]]; then
    tags="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "${tmp}" | sed -E 's/.*"([^"]+)"$/\1/' | upd_stable_sorted || true)"
    via=api
  else
    case "${code}" in
      403|429) UPD_NOTE="лимит запросов GitHub API (HTTP ${code}) — использую releases.atom" ;;
      000)     UPD_NOTE="GitHub API недоступен (сеть/DNS) — пробую releases.atom" ;;
      *)       UPD_NOTE="GitHub API ответил HTTP ${code} — пробую releases.atom" ;;
    esac
  fi
  if [[ -z "${tags}" ]]; then
    code="$(upd_http_get "${UPD_WEB}/${INSTALLER_REPO}/releases.atom" "${tmp}")"
    if [[ "${code}" == "200" ]]; then
      tags="$(grep -oE '/releases/tag/[^"<]+' "${tmp}" | sed -E 's|.*/releases/tag/||' | upd_stable_sorted || true)"
      via=atom
    fi
  fi
  if [[ -z "${tags}" && "${UPD_WEB}" == http* ]]; then
    local eff
    eff="$(curl -sSLI --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' \
      "${UPD_WEB}/${INSTALLER_REPO}/releases/latest" 2>/dev/null || true)"
    tags="$(printf '%s\n' "${eff##*/}" | upd_stable_sorted || true)"
    [[ -n "${tags}" ]] && { via=latest; UPD_NOTE="${UPD_NOTE:+${UPD_NOTE}; }виден только последний релиз"; }
  fi
  rm -f "${tmp}" "${tmp}.err"
  if [[ -z "${tags}" ]]; then
    log_err "Не удалось получить список релизов ${INSTALLER_REPO}"
    printf "     ${C_DIM}%s${C_RESET}\n" "Проверьте доступ к github.com (прокси/файрвол) или укажите версию: connectorctl update --version vX.Y.Z" >&2
    return 1
  fi
  UPD_SOURCE="${via}"
  UPD_TAGS="${tags}"
}

upd_native_asset_exists() {
  curl -fsSL --connect-timeout 10 --max-time 30 -r 0-0 -o /dev/null \
    "${UPD_WEB}/${INSTALLER_REPO}/releases/download/$1/${UPD_ASSET}" 2>/dev/null
}

# Best effort: anonymous GHCR manifest probe. Unknown → treated as existing.
upd_docker_image_exists() {
  local tag="${1#v}" repo="${GHCR_IMAGE#ghcr.io/}" token code
  token="$(curl -fsS --connect-timeout 10 --max-time 20 "${UPD_GHCR}/token?scope=repository:${repo}:pull" 2>/dev/null \
    | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  [[ -n "${token}" ]] || return 0
  code="$(curl -sS -o /dev/null -I -w '%{http_code}' --connect-timeout 10 --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "${UPD_GHCR}/v2/${repo}/manifests/${tag}" 2>/dev/null || true)"
  [[ "${code}" != "404" ]]
}

upd_artifact_exists() {
  if [[ "${MODE}" == "docker" ]]; then upd_docker_image_exists "$1"; else upd_native_asset_exists "$1"; fi
}

# upd_resolve CURRENT ALLOW_MAJOR(0|1) → sets UPD_TARGET (newest allowed) and UPD_NEWER_MAJOR
upd_resolve() {
  local cur="$1" allow="$2" tag
  UPD_TARGET=""; UPD_NEWER_MAJOR=""
  upd_list_tags || return 1
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue
    [[ "$(ver_cmp "${tag}" "${cur}")" == "1" ]] || continue
    upd_artifact_exists "${tag}" || continue
    if [[ "${allow}" == "1" || "$(ver_major "${tag}")" == "$(ver_major "${cur}")" ]]; then
      UPD_TARGET="${tag}"
      break
    fi
    [[ -n "${UPD_NEWER_MAJOR}" ]] || UPD_NEWER_MAJOR="${tag}"
  done <<<"${UPD_TAGS}"
  return 0
}

# upd_changelog FROM TO → CHANGELOG sections with FROM < version <= TO (best effort)
upd_changelog() {
  local from="$1" to="$2" tmp code
  tmp="$(mktemp)"
  code="$(upd_http_get "${UPD_RAW}/${INSTALLER_REPO}/${to}/CHANGELOG.md" "${tmp}")"
  if [[ "${code}" != "200" ]]; then rm -f "${tmp}"; return 1; fi
  awk -v from="$(ver_strip "${from}")" -v to="$(ver_strip "${to}")" '
    function num(v,  p) { split(v, p, "."); return p[1]*1000000 + p[2]*1000 + p[3] }
    /^## / {
      show = 0
      if (match($0, /v?[0-9]+\.[0-9]+\.[0-9]+/)) {
        v = substr($0, RSTART, RLENGTH); sub(/^v/, "", v)
        if (num(v) > num(from) && num(v) <= num(to)) show = 1
      }
    }
    show { print }
  ' "${tmp}"
  rm -f "${tmp}"
}

# ─── installed version / state ──────────────────────────────

upd_current_version() {
  local v=""
  if [[ "${MODE}" == "docker" ]]; then
    v="$(env_val CONNECTOR_VERSION)"
    [[ -n "${v}" ]] || v="$(env_val CONNECTOR_IMAGE_TAG)"
  else
    v="$(meta_get VERSION)"
  fi
  [[ -n "${v}" ]] && ver_valid "${v}" && ver_tag "${v}" || true
}

meta_set() { touch "${META_FILE}"; env_set "${META_FILE}" "$1" "$2"; }

# ─── lock ───────────────────────────────────────────────────

UPD_LOCK_DIR=""
upd_unlock() {
  if [[ -n "${UPD_LOCK_DIR}" ]]; then rm -rf "${UPD_LOCK_DIR}" 2>/dev/null || true; UPD_LOCK_DIR=""; fi
}

upd_lock() {
  local f="${CONNECTORCTL_LOCK_FILE:-/var/lock/connectorctl-update.lock}"
  mkdir -p "$(dirname "${f}")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${f}"
    flock -n 9 || return 1
    return 0
  fi
  # No flock: mkdir lock with PID file; steal if the owner died.
  local d="${f}.d" pid
  if ! mkdir "${d}" 2>/dev/null; then
    pid="$(cat "${d}/pid" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then return 1; fi
    rm -rf "${d}"; mkdir "${d}" 2>/dev/null || return 1
  fi
  printf '%s' "$$" >"${d}/pid"
  UPD_LOCK_DIR="${d}"
}

# ─── health ─────────────────────────────────────────────────

upd_dc() { (cd "${ROOT}" && docker compose "$@"); }

upd_health_once() {
  if [[ -n "${CONNECTORCTL_TEST_HEALTH:-}" ]]; then
    bash -c "${CONNECTORCTL_TEST_HEALTH}" >/dev/null 2>&1
    return $?
  fi
  local code unit
  code="$(http_code "http://127.0.0.1:$(app_port)/health")"
  [[ "${code}" == "200" ]] || return 1
  if [[ "${MODE}" == "native" ]]; then
    for unit in "${UNITS[@]}"; do
      [[ "$(systemctl is-active "${unit}" 2>/dev/null || true)" == "active" ]] || return 1
    done
  else
    local id state health
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      state="$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null || true)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${id}" 2>/dev/null || true)"
      [[ "${state}" == "running" ]] || return 1
      [[ "${health}" != "unhealthy" && "${health}" != "starting" ]] || return 1
    done < <(upd_dc ps -q 2>/dev/null)
  fi
  return 0
}

upd_health_wait() {
  local max="${CONNECTORCTL_HEALTH_TIMEOUT:-120}" step="${CONNECTORCTL_HEALTH_INTERVAL:-3}" start now
  start="$(date +%s)"
  while true; do
    if upd_health_once; then return 0; fi
    now="$(date +%s)"
    ((now - start >= max)) && return 1
    sleep "${step}"
  done
}

upd_diag() {
  printf "\n  ${C_DIM}Диагностика:${C_RESET}\n"
  if [[ "${MODE}" == "native" ]]; then
    local u
    for u in "${UNITS[@]}"; do
      printf "  ${C_DIM}%-22s %s${C_RESET}\n" "${u}" "$(systemctl is-active "${u}" 2>/dev/null || echo unknown)"
    done
    journalctl -u connector-app -n 15 --no-pager 2>/dev/null | sed 's/^/     /' || true
  else
    upd_dc ps 2>/dev/null | sed 's/^/     /' || true
    upd_dc logs --tail 15 app 2>/dev/null | sed 's/^/     /' || true
  fi
  printf '  → connectorctl doctor / connectorctl logs\n'
}

# ─── database helpers ───────────────────────────────────────

upd_db_rev() {
  local out=""
  if [[ "${MODE}" == "docker" ]]; then
    out="$(upd_dc exec -T db psql -U "$(env_val DB__USER)" -d "$(env_val DB__NAME)" -tAc \
      'SELECT version_num FROM alembic_version' 2>/dev/null || true)"
  elif command -v psql >/dev/null 2>&1; then
    out="$(PGPASSWORD="$(env_val DB__PASSWORD)" psql -h "$(env_val DB__HOST)" -p "$(env_val DB__PORT)" \
      -U "$(env_val DB__USER)" -d "$(env_val DB__NAME)" -tAc 'SELECT version_num FROM alembic_version' 2>/dev/null || true)"
  fi
  printf '%s' "$(tr -d '[:space:]' <<<"${out}")"
}

upd_restore_db() {
  local backup="$1" tmp rc=0
  [[ -f "${backup}" ]] || { log_err "Файл бэкапа не найден: ${backup}"; return 1; }
  tmp="$(mktemp -d)"
  tar -xzf "${backup}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; }
  [[ -f "${tmp}/db.dump" ]] || { rm -rf "${tmp}"; return 1; }
  if [[ "${MODE}" == "docker" ]]; then
    upd_dc exec -T db pg_restore --clean --if-exists --no-owner \
      -U "$(env_val DB__USER)" -d "$(env_val DB__NAME)" <"${tmp}/db.dump" || rc=$?
  else
    PGPASSWORD="$(env_val DB__PASSWORD)" pg_restore --clean --if-exists --no-owner \
      -h "$(env_val DB__HOST)" -p "$(env_val DB__PORT)" \
      -U "$(env_val DB__USER)" -d "$(env_val DB__NAME)" "${tmp}/db.dump" || rc=$?
  fi
  rm -rf "${tmp}"
  return "${rc}"
}

# Docker backup (same archive layout as native cmd_backup).
upd_backup_docker() {
  local dir="${1:-${DEFAULT_BACKUP_DIR}}" ts out tmp
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${dir}"; chmod 700 "${dir}"
  tmp="$(mktemp -d)"
  if ! upd_dc exec -T db pg_dump -Fc -U "$(env_val DB__USER)" "$(env_val DB__NAME)" >"${tmp}/db.dump"; then
    rm -rf "${tmp}"; log_err "pg_dump в контейнере db не удался"; return 1
  fi
  cp "${ENV_FILE}" "${tmp}/env"
  cp "${META_FILE}" "${tmp}/install-meta" 2>/dev/null || true
  out="${dir}/connector-${ts}.tar.gz"
  (umask 077; tar -C "${tmp}" -czf "${out}" .)
  chmod 600 "${out}"
  rm -rf "${tmp}"
  LAST_BACKUP="${out}"
  log_ok "Бэкап: ${out} ($(du -h "${out}" | cut -f1))"
}

# ─── native apply ───────────────────────────────────────────

upd_native_download() {
  local tag="$1" stage="$2" base="${UPD_WEB}/${INSTALLER_REPO}/releases/download/$1"
  log_info "Скачиваю ${UPD_ASSET} (${tag})…"
  curl -fsSL --connect-timeout 10 --max-time 900 "${base}/${UPD_ASSET}" -o "${stage}/${UPD_ASSET}" \
    || { log_err "Не удалось скачать ${base}/${UPD_ASSET}"; return 1; }
  curl -fsSL --connect-timeout 10 --max-time 60 "${base}/SHA256SUMS" -o "${stage}/SHA256SUMS" \
    || { log_err "Не удалось скачать SHA256SUMS (${tag})"; return 1; }
  ( verify_release_tarball "${stage}" "${UPD_ASSET}" ) || return 1
  log_ok "Контрольная сумма совпала"
  tar -xzf "${stage}/${UPD_ASSET}" -C "${stage}" || { log_err "Не удалось распаковать архив"; return 1; }
  [[ -x "${stage}/connector-linux-amd64/connector" ]] || { log_err "В архиве нет connector-linux-amd64/connector"; return 1; }
}

upd_is_protected() {
  local n="$1" p
  for p in "${UPD_PROTECTED[@]}"; do [[ "${n}" == "${p}" ]] && return 0; done
  return 1
}

# Move current code entries aside (into PREV) and move new ones in. Local files are untouched.
upd_native_swap() {
  local new="$1" prev="$2" name
  mkdir -p "${prev}"
  : >"${prev}/.entries"
  while IFS= read -r name; do
    upd_is_protected "${name}" && continue
    printf '%s\n' "${name}" >>"${prev}/.entries"
    if [[ -e "${ROOT}/${name}" || -L "${ROOT}/${name}" ]]; then
      mv "${ROOT}/${name}" "${prev}/${name}" || return 1
    fi
    mv "${new}/${name}" "${ROOT}/${name}" || return 1
  done < <(ls -A "${new}")
  return 0
}

upd_native_unswap() {
  local prev="$1" name
  [[ -f "${prev}/.entries" ]] || return 1
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    rm -rf "${ROOT:?}/${name}"
    if [[ -e "${prev}/${name}" || -L "${prev}/${name}" ]]; then
      mv "${prev}/${name}" "${ROOT}/${name}" || return 1
    fi
  done <"${prev}/.entries"
}

upd_native_fix_perms() {
  local prev="$1" name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    chown -R root:root "${ROOT}/${name}" 2>/dev/null || true
    chmod -R go+rX,go-w "${ROOT}/${name}" 2>/dev/null || true
  done <"${prev}/.entries"
  chmod 755 "${ROOT}/connector" 2>/dev/null || true
}

upd_native_migrate() {
  run_as_user "${DEFAULT_CONNECTOR_USER}" env ENV_FILE="${ENV_FILE}" CONNECTOR_HOME="${ROOT}" \
    "${ROOT}/connector" migrate
}

# upd_native_apply TAG CURRENT SKIP_BACKUP → 0 ok, 1 nothing changed, 3 rolled back, 4 rollback failed
upd_native_apply() {
  local tag="$1" cur="$2" skip_backup="$3" stage="${ROOT}/.stage" prev
  local rev_before rev_after migrated=0 backup=""
  rm -rf "${stage}"; mkdir -p "${stage}"
  upd_native_download "${tag}" "${stage}" || { rm -rf "${stage}"; return 1; }

  if [[ "${skip_backup}" == "1" ]]; then
    log_warn "Резервная копия пропущена (--skip-backup)"
  else
    log_info "Резервная копия перед обновлением"
    LAST_BACKUP=""
    if ! cmd_backup; then log_err "Бэкап не удался — обновление отменено"; rm -rf "${stage}"; return 1; fi
    backup="${LAST_BACKUP:-}"
  fi
  rev_before="$(upd_db_rev)"

  prev="${ROOT}/.rollback/${cur:-previous}"
  rm -rf "${ROOT}/.rollback"; mkdir -p "${prev}"

  log_info "Останавливаю службы…"
  systemctl stop "${UNITS[@]}" 2>/dev/null || true

  if ! upd_native_swap "${stage}/connector-linux-amd64" "${prev}"; then
    log_err "Не удалось заменить файлы коннектора"
    upd_native_rollback "${prev}" "${backup}" 0 "${rev_before}"
    return $?
  fi
  upd_native_fix_perms "${prev}"
  rm -rf "${stage}"

  log_info "Миграции БД…"
  if ! upd_native_migrate; then
    log_err "Миграции завершились с ошибкой"
    upd_native_rollback "${prev}" "${backup}" 1 "${rev_before}"
    return $?
  fi
  migrated=1

  systemctl daemon-reload 2>/dev/null || true
  log_info "Запускаю службы…"
  systemctl restart "${UNITS[@]}" 2>/dev/null || true
  log_info "Проверка работоспособности (health-check)…"
  if upd_health_wait; then
    return 0
  fi
  log_err "Health-check не пройден после обновления до ${tag}"
  upd_diag
  upd_native_rollback "${prev}" "${backup}" "${migrated}" "${rev_before}"
}

# upd_native_rollback PREV BACKUP MIGRATED REV_BEFORE
upd_native_rollback() {
  local prev="$1" backup="$2" migrated="$3" rev_before="$4" rev_after restore=0
  log_warn "Откат на предыдущую версию…"
  systemctl stop "${UNITS[@]}" 2>/dev/null || true
  if ! upd_native_unswap "${prev}"; then
    log_err "Откат файлов не удался. Предыдущая версия: ${prev}"
    return 4
  fi
  if [[ "${migrated}" == "1" ]]; then
    rev_after="$(upd_db_rev)"
    if [[ -z "${rev_before}" || -z "${rev_after}" || "${rev_before}" != "${rev_after}" ]]; then
      restore=1
    fi
  fi
  if [[ "${restore}" == "1" ]]; then
    if [[ -n "${backup}" ]]; then
      log_warn "Миграции могли изменить схему БД — восстанавливаю БД из бэкапа ${backup}"
      log_warn "Данные, записанные после бэкапа, будут потеряны"
      upd_restore_db "${backup}" || { log_err "Восстановление БД не удалось. Бэкап: ${backup}"; return 4; }
    else
      log_warn "Схема БД могла измениться, а бэкапа нет (--skip-backup) — восстановите БД вручную"
    fi
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart "${UNITS[@]}" 2>/dev/null || true
  if upd_health_wait; then
    log_ok "Откат выполнен: работает предыдущая версия"
    return 3
  fi
  log_err "После отката health-check тоже не прошёл"
  upd_diag
  return 4
}

# ─── docker apply ───────────────────────────────────────────

upd_docker_set_version() {
  local v="${1#v}"
  env_set "${ENV_FILE}" CONNECTOR_VERSION "${v}"
  if grep -qE '^CONNECTOR_IMAGE_TAG=' "${ENV_FILE}"; then
    env_set "${ENV_FILE}" CONNECTOR_IMAGE_TAG "${v}"
  fi
}

upd_docker_apply() {
  local tag="$1" cur="$2" skip_backup="$3" backup="" rev_before rev_after migrated=0
  local saved="${ROOT}/.rollback/env.${cur:-previous}"
  local services=(app worker-ami worker-outbox worker-cel worker-recording)

  if [[ "${skip_backup}" == "1" ]]; then
    log_warn "Резервная копия пропущена (--skip-backup)"
  else
    log_info "Резервная копия перед обновлением"
    LAST_BACKUP=""
    upd_backup_docker || { log_err "Бэкап не удался — обновление отменено"; return 1; }
    backup="${LAST_BACKUP:-}"
  fi
  rev_before="$(upd_db_rev)"
  mkdir -p "${ROOT}/.rollback"; chmod 700 "${ROOT}/.rollback"
  cp -p "${ENV_FILE}" "${saved}"

  upd_docker_set_version "${tag}"
  log_info "docker compose pull (${tag#v})…"
  if ! upd_dc pull; then
    log_err "Не удалось скачать образ ${GHCR_IMAGE}:${tag#v}"
    cp -p "${saved}" "${ENV_FILE}"
    return 1
  fi

  log_info "Останавливаю сервисы коннектора…"
  upd_dc stop "${services[@]}" 2>/dev/null || true
  log_info "Миграции БД…"
  if ! upd_dc run --rm --no-deps -T app migrate; then
    log_err "Миграции завершились с ошибкой"
    upd_docker_rollback "${saved}" "${backup}" 1 "${rev_before}"
    return $?
  fi
  migrated=1
  log_info "docker compose up -d…"
  upd_dc up -d --remove-orphans || true
  log_info "Проверка работоспособности (health-check)…"
  if upd_health_wait; then
    return 0
  fi
  log_err "Health-check не пройден после обновления до ${tag}"
  upd_diag
  upd_docker_rollback "${saved}" "${backup}" "${migrated}" "${rev_before}"
}

upd_docker_rollback() {
  local saved="$1" backup="$2" migrated="$3" rev_before="$4" rev_after restore=0
  local services=(app worker-ami worker-outbox worker-cel worker-recording)
  log_warn "Откат на предыдущий образ…"
  cp -p "${saved}" "${ENV_FILE}" || { log_err "Не удалось восстановить .env из ${saved}"; return 4; }
  upd_dc stop "${services[@]}" 2>/dev/null || true
  if [[ "${migrated}" == "1" ]]; then
    rev_after="$(upd_db_rev)"
    if [[ -z "${rev_before}" || -z "${rev_after}" || "${rev_before}" != "${rev_after}" ]]; then restore=1; fi
  fi
  if [[ "${restore}" == "1" ]]; then
    if [[ -n "${backup}" ]]; then
      log_warn "Миграции могли изменить схему БД — восстанавливаю БД из бэкапа ${backup}"
      log_warn "Данные, записанные после бэкапа, будут потеряны"
      upd_restore_db "${backup}" || { log_err "Восстановление БД не удалось. Бэкап: ${backup}"; return 4; }
    else
      log_warn "Схема БД могла измениться, а бэкапа нет (--skip-backup) — восстановите БД вручную"
    fi
  fi
  upd_dc up -d --remove-orphans || true
  if upd_health_wait; then
    log_ok "Откат выполнен: работает предыдущая версия"
    return 3
  fi
  log_err "После отката health-check тоже не прошёл"
  upd_diag
  return 4
}

# ─── installer tree refresh (scripts, units, compose) ───────

# Replace scripts/, deploy/, compose etc. with the target release's copy (per-file atomic mv,
# safe while this script runs). Skipped for git clones and for releases without update support.
upd_refresh_installer() {
  local tag="$1" tmp src rel changed=0 f
  [[ -d "${INSTALLER_ROOT}/.git" ]] && { log_info "Каталог установщика — git-клон: скрипты не трогаю (git pull)"; return 0; }
  tmp="$(mktemp -d "${INSTALLER_ROOT}/.stage-installer.XXXXXX")" || return 0
  if ! curl -fsSL --connect-timeout 10 --max-time 120 \
      "${UPD_WEB}/${INSTALLER_REPO}/archive/refs/tags/${tag}.tar.gz" -o "${tmp}/a.tgz" 2>/dev/null \
      || ! tar -xzf "${tmp}/a.tgz" -C "${tmp}" 2>/dev/null; then
    log_warn "Не удалось обновить скрипты установщика (${tag}) — оставляю текущие"
    rm -rf "${tmp}"; return 0
  fi
  src="$(find "${tmp}" -maxdepth 1 -type d -name 'asterisk24-connector-installer-*' | head -1)"
  if [[ -z "${src}" || ! -f "${src}/scripts/lib/update.sh" ]]; then
    log_info "Релиз ${tag} без механизма обновления: скрипты установщика не меняю"
    rm -rf "${tmp}"; return 0
  fi
  while IFS= read -r f; do
    rel="${f#"${src}"/}"
    case "${rel}" in
      scripts/*|deploy/*|install.sh|docker-compose.yml|.env.example|README.md|CHANGELOG.md) ;;
      *) continue ;;
    esac
    if [[ ! -f "${INSTALLER_ROOT}/${rel}" ]] || ! cmp -s "${f}" "${INSTALLER_ROOT}/${rel}"; then
      mkdir -p "$(dirname "${INSTALLER_ROOT}/${rel}")"
      cp -p "${f}" "${INSTALLER_ROOT}/${rel}.new" && mv -f "${INSTALLER_ROOT}/${rel}.new" "${INSTALLER_ROOT}/${rel}"
      [[ "${rel}" == "docker-compose.yml" ]] && changed=1
    fi
  done < <(find "${src}" -type f)
  rm -rf "${tmp}"
  log_ok "Скрипты установщика обновлены до ${tag}"
  if [[ "${changed}" == "1" && "${MODE}" == "docker" ]]; then
    log_info "docker-compose.yml изменился — применяю (up -d)"
    upd_dc up -d --remove-orphans || log_warn "docker compose up -d после обновления compose-файла не удался"
  fi
  return 0
}

# ─── commands ───────────────────────────────────────────────

upd_usage() {
  cat <<EOF
Использование:
  connectorctl update --check [--allow-major]   только проверить (ничего не меняет)
  connectorctl update [--allow-major]            обновить до последней версии в рамках мажорной
  connectorctl update --version vX.Y.Z           конкретная версия (в том числе откат на старую)
  connectorctl update --source DIR               legacy: переустановка из каталога установщика

Опции: --skip-backup  --install-dir DIR  --yes
Коды выхода --check: 0 актуально, 10 есть обновление, 11 есть только новая мажорная, 1 ошибка.
Коды выхода update:  0 ок, 1 ошибка до изменений, 3 неудача + откат выполнен, 4 откат не удался, 5 занято.
EOF
}

upd_print_changelog() {
  local from="$1" to="$2" cl
  cl="$(upd_changelog "${from}" "${to}" 2>/dev/null || true)"
  if [[ -n "${cl}" ]]; then
    printf "\n  ${C_BOLD}Изменения (%s → %s):${C_RESET}\n" "${from}" "${to}"
    sed 's/^/    /' <<<"${cl}"
    printf '\n'
  else
    printf "  ${C_DIM}CHANGELOG для %s недоступен${C_RESET}\n" "${to}"
  fi
}

upd_check() {
  local cur="$1" allow="$2"
  upd_resolve "${cur}" "${allow}" || return 1
  [[ -n "${UPD_NOTE}" ]] && log_warn "${UPD_NOTE}"
  print_kv "Режим" "${MODE}"
  print_kv "Установлено" "${cur}"
  if [[ -n "${UPD_TARGET}" ]]; then
    print_kv "Доступно" "${C_GREEN}${UPD_TARGET}${C_RESET}"
    [[ -n "${UPD_NEWER_MAJOR}" ]] && print_kv "Новая мажорная" "${UPD_NEWER_MAJOR}" "(только с --allow-major)"
    upd_print_changelog "${cur}" "${UPD_TARGET}"
    printf "  Обновить: ${C_BOLD}sudo connectorctl update${C_RESET}\n\n"
    UPD_RESULT="available"
    return 10
  fi
  if [[ -n "${UPD_NEWER_MAJOR}" ]]; then
    print_kv "Доступно" "${UPD_NEWER_MAJOR}" "(новая мажорная версия)"
    upd_print_changelog "${cur}" "${UPD_NEWER_MAJOR}"
    printf "  Обновить: ${C_BOLD}sudo connectorctl update --allow-major${C_RESET}\n\n"
    UPD_RESULT="major-available"
    return 11
  fi
  log_ok "Установлена актуальная версия (${cur})"
  UPD_RESULT="up-to-date"
  return 0
}

# Legacy path: reinstall from an installer directory (kept for compatibility).
upd_legacy_source() {
  local source="$1" ver native
  [[ -f "${source}/install.sh" ]] || die "Не найден install.sh в ${source}"
  log_info "Источник обновления: ${source}"
  log_info "Резервная копия перед обновлением"
  cmd_backup
  ver="$(meta_get VERSION)"
  [[ -n "${ver}" ]] || ver="v$(product_version "${ROOT}")"
  native="${source}/scripts/install-native.sh"
  if [[ -f "${native}" ]]; then
    exec bash "${native}" --yes --install-dir "${ROOT}" --port "$(app_port)" --version "${ver}"
  fi
  exec bash "${source}/install.sh" --mode native --yes --install-dir "${ROOT}" \
    --port "$(app_port)" --version "${ver}"
}

upd_on_exit() {
  local rc=$?
  upd_unlock
  rm -rf "${ROOT}/.stage" 2>/dev/null || true
  if [[ "${UPD_AUTO:-0}" == "1" ]] && declare -F auto_record_exit >/dev/null; then
    auto_record_exit "${rc}"
  fi
  return "${rc}"
}

cmd_update() {
  local orig=("$@") check=0 allow_major=0 want="" skip_backup=0 source="" new_root=""
  trap upd_on_exit EXIT
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check=1; shift ;;
      --allow-major) allow_major=1; shift ;;
      --version) want="${2:-}"; [[ -n "${want}" ]] || die "--version требует значение (vX.Y.Z)"; shift 2 ;;
      --skip-backup) skip_backup=1; shift ;;
      --source) source="${2:-}"; shift 2 ;;
      --install-dir) new_root="${2:-}"; shift 2 ;;
      --auto) UPD_AUTO=1; shift ;;
      -y|--yes) shift ;;
      -h|--help) upd_usage; return 0 ;;
      *) die "Неизвестная опция update: $1" ;;
    esac
  done
  if [[ "${UPD_AUTO:-0}" == "1" ]]; then allow_major=0; [[ -z "${want}" ]] || die "--auto несовместим с --version"; fi
  if [[ -n "${new_root}" ]]; then
    ROOT="${new_root}"; ENV_FILE="${ROOT}/.env"; META_FILE="${ROOT}/.install-meta"
  fi

  if [[ "${check}" == "0" || "${MODE}" == "docker" ]]; then need_root update "${orig[@]}"; fi
  if [[ -n "${source}" ]]; then
    [[ "${MODE}" == "native" ]] || die "--source поддерживается только для native"
    upd_legacy_source "${source}"
  fi

  local cur target
  cur="$(upd_current_version)"
  [[ -n "${cur}" ]] || die "Не удалось определить установленную версию" \
    "$([[ "${MODE}" == docker ]] && echo "проверьте CONNECTOR_VERSION в ${ENV_FILE}" || echo "проверьте VERSION в ${META_FILE}")"
  printf '\n  %s · обновление\n' "${PRODUCT_NAME}"
  printf "  ${C_DIM}────────────────────────────────────────────────────${C_RESET}\n"

  if [[ "${check}" == "1" ]]; then
    local rc=0
    upd_check "${cur}" "${allow_major}" || rc=$?
    return "${rc}"
  fi

  if [[ -n "${want}" ]]; then
    ver_valid "${want}" || die "Некорректная версия: ${want} (ожидается vX.Y.Z)"
    target="$(ver_tag "${want}")"
    if [[ "$(ver_cmp "${target}" "${cur}")" == "0" ]]; then
      log_ok "Уже установлена ${cur}"; UPD_RESULT="up-to-date"; return 0
    fi
    [[ "$(ver_cmp "${target}" "${cur}")" == "-1" ]] && log_warn "Понижение версии ${cur} → ${target}: схема БД не откатывается автоматически"
    upd_artifact_exists "${target}" || die "Релиз ${target} не найден (нет артефакта для режима ${MODE})"
  else
    upd_resolve "${cur}" "${allow_major}" || return 1
    [[ -n "${UPD_NOTE}" ]] && log_warn "${UPD_NOTE}"
    if [[ -z "${UPD_TARGET}" ]]; then
      if [[ -n "${UPD_NEWER_MAJOR}" ]]; then
        log_ok "В рамках ${cur%%.*}.x обновлений нет. Доступна новая мажорная: ${UPD_NEWER_MAJOR}"
        printf "  ${C_DIM}Для перехода: connectorctl update --allow-major  (прочитайте CHANGELOG)${C_RESET}\n"
        UPD_RESULT="major-available"
      else
        log_ok "Установлена актуальная версия (${cur})"; UPD_RESULT="up-to-date"
      fi
      return 0
    fi
    target="${UPD_TARGET}"
  fi

  if [[ "${UPD_AUTO:-0}" == "1" && "${target}" == "${AUTO_SKIP_VERSION:-}" ]]; then
    log_warn "Версия ${target} ранее откатывалась — пропускаю до выхода новой"
    UPD_RESULT="skipped"; UPD_TARGET="${target}"
    return 0
  fi

  print_kv "Было" "${cur}"
  print_kv "Станет" "${target}"
  upd_print_changelog "${cur}" "${target}"

  if ! upd_lock; then
    log_err "Другое обновление уже выполняется (замок: ${CONNECTORCTL_LOCK_FILE:-/var/lock/connectorctl-update.lock})"
    UPD_RESULT="busy"
    return 5
  fi

  local rc=0
  if [[ "${MODE}" == "docker" ]]; then
    upd_docker_apply "${target}" "${cur}" "${skip_backup}" || rc=$?
  else
    upd_native_apply "${target}" "${cur}" "${skip_backup}" || rc=$?
  fi

  case "${rc}" in
    0)
      meta_set MODE "${MODE}"
      meta_set PREVIOUS_VERSION "${cur}"
      meta_set VERSION "${target}"
      meta_set UPDATED_AT "$(date '+%F %T')"
      UPD_RESULT="updated"; UPD_TARGET="${target}"
      upd_refresh_installer "${target}" || true
      log_ok "Обновлено: ${cur} → ${target}"
      ;;
    1) UPD_RESULT="failed"; log_err "Обновление не выполнено, система не менялась" ;;
    3) UPD_RESULT="rolled-back"; UPD_TARGET="${target}"
       log_err "Обновление до ${target} не удалось, выполнен откат на ${cur}" ;;
    *) UPD_RESULT="rollback-failed"; UPD_TARGET="${target}"
       log_err "Обновление до ${target} не удалось, откат не завершён — нужен ручной разбор"
       printf "     ${C_DIM}Предыдущая версия: %s/.rollback, бэкап: %s${C_RESET}\n" "${ROOT}" "${LAST_BACKUP:-—}" ;;
  esac
  return "${rc}"
}
