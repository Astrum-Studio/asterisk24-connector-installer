#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with connectorctl and the other lib
# connectorctl auto-update: systemd timer (or cron) that runs `connectorctl update --auto`.
# Policy: minor/patch only (never major), inside a local-time window, at most once per interval.
# Results go to the journal / log file and to `connectorctl auto-update status`. Off by default.
# Sourced by scripts/connectorctl after lib/update.sh.

AUTO_CONF_DIR="${CONNECTORCTL_CONF_DIR:-/etc/connectorctl}"
AUTO_STATE_DIR="${CONNECTORCTL_STATE_DIR:-/var/lib/connectorctl}"
AUTO_CONF="${AUTO_CONF_DIR}/auto-update.conf"
AUTO_STATE="${AUTO_STATE_DIR}/auto-update.state"
AUTO_SYSTEMD_DIR="${CONNECTORCTL_SYSTEMD_DIR:-/etc/systemd/system}"
AUTO_CRON_FILE="${CONNECTORCTL_CRON_DIR:-/etc/cron.d}/connectorctl-auto-update"
AUTO_LOG_FILE="${CONNECTORCTL_LOG_FILE:-/var/log/connectorctl-update.log}"
AUTO_DEFAULT_WINDOW="03:00-05:00"
AUTO_DEFAULT_EVERY=24
AUTO_SKIP_VERSION=""

auto_conf_get()  { env_get "${AUTO_CONF}" "$1" 2>/dev/null || true; }
auto_state_get() { env_get "${AUTO_STATE}" "$1" 2>/dev/null || true; }
auto_state_set() { mkdir -p "${AUTO_STATE_DIR}"; touch "${AUTO_STATE}"; env_set "${AUTO_STATE}" "$1" "$2"; }

auto_use_systemd() {
  [[ "${CONNECTORCTL_FORCE_CRON:-0}" == "1" ]] && return 1
  [[ "${CONNECTORCTL_FORCE_SYSTEMD:-0}" == "1" ]] && return 0
  has_systemd
}

auto_ctl_path() {
  if [[ -x /usr/local/bin/connectorctl ]]; then printf '/usr/local/bin/connectorctl'; else printf '%s' "${SELF}"; fi
}

# HH:MM → minutes since midnight (10# avoids octal parsing of 08/09)
auto_minutes() { local h="${1%%:*}" m="${1##*:}"; printf '%d' $((10#${h} * 60 + 10#${m})); }

# auto_in_window NOW START END (all HH:MM); supports windows crossing midnight
auto_in_window() {
  local n s e
  n="$(auto_minutes "$1")"; s="$(auto_minutes "$2")"; e="$(auto_minutes "$3")"
  if ((s == e)); then return 0; fi          # equal bounds: any time
  if ((s < e)); then ((n >= s && n < e)); else ((n >= s || n < e)); fi
}

auto_epoch() { printf '%s' "${CONNECTORCTL_EPOCH:-$(date +%s)}"; }
auto_human() { date -d "@$1" '+%F %T' 2>/dev/null || date -r "$1" '+%F %T' 2>/dev/null || printf '%s' "$1"; }

# Called from upd_on_exit when update runs with --auto.
auto_record_exit() {
  local rc="$1" res="${UPD_RESULT:-}" msg="" now
  now="$(auto_epoch)"
  if [[ -z "${res}" ]]; then
    res="failed"
    msg="выход с кодом ${rc} до завершения"
  fi
  case "${res}" in
    updated)         msg="обновлено до ${UPD_TARGET}" ;;
    up-to-date)      msg="актуальная версия" ;;
    major-available) msg="есть новая мажорная версия ${UPD_NEWER_MAJOR:-} (автоматически не ставится)" ;;
    skipped)         msg="версия ${UPD_TARGET} пропущена (ранее откатывалась)" ;;
    rolled-back)     msg="обновление до ${UPD_TARGET} не удалось, откат выполнен" ;;
    rollback-failed) msg="обновление до ${UPD_TARGET} не удалось, откат не завершён!" ;;
    busy)            msg="другое обновление уже выполняется" ;;
    failed)          msg="${msg:-ошибка обновления}" ;;
  esac
  auto_state_set LAST_ATTEMPT "${now}"
  auto_state_set LAST_RESULT "${res}"
  auto_state_set LAST_MESSAGE "${msg}"
  auto_state_set LAST_VERSION "$(upd_current_version 2>/dev/null || true)"
  case "${res}" in
    failed|busy) ;;  # not conclusive: retry on the next tick inside the window
    *) auto_state_set LAST_CHECK "${now}" ;;
  esac
  case "${res}" in
    rolled-back|rollback-failed) auto_state_set SKIP_VERSION "${UPD_TARGET}" ;;
    updated) auto_state_set SKIP_VERSION "" ;;
  esac
  log_info "auto-update: ${res} — ${msg}"
  return 0
}

auto_run() {
  local force=0 start end every now_hm last now
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) die "Неизвестная опция auto-update run: $1" ;;
    esac
  done
  if [[ ! -f "${AUTO_CONF}" && "${force}" == "0" ]]; then
    log_info "auto-update не включён (нет ${AUTO_CONF})"; return 0
  fi
  start="$(auto_conf_get WINDOW_START)"; start="${start:-03:00}"
  end="$(auto_conf_get WINDOW_END)";     end="${end:-05:00}"
  every="$(auto_conf_get EVERY_HOURS)";  every="${every:-${AUTO_DEFAULT_EVERY}}"
  if [[ "${force}" == "0" ]]; then
    now_hm="${CONNECTORCTL_NOW:-$(date +%H:%M)}"
    if ! auto_in_window "${now_hm}" "${start}" "${end}"; then
      log_info "auto-update: ${now_hm} вне окна ${start}-${end} — пропуск"; return 0
    fi
    last="$(auto_state_get LAST_CHECK)"; now="$(auto_epoch)"
    # 15 min slack so the daily tick is not pushed to the next day by timer jitter
    if [[ -n "${last}" && $((now - last)) -lt $((every * 3600 - 900)) ]]; then
      log_info "auto-update: последняя проверка $(auto_human "${last}") (интервал ${every} ч) — пропуск"; return 0
    fi
  fi
  AUTO_SKIP_VERSION="$(auto_state_get SKIP_VERSION)"
  UPD_AUTO=1
  log_info "auto-update: проверка обновлений (окно ${start}-${end}, интервал ${every} ч)"
  cmd_update --auto
}

auto_enable() {
  local window="${AUTO_DEFAULT_WINDOW}" every="${AUTO_DEFAULT_EVERY}" ctl tmpl rendered
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --window) window="${2:-}"; shift 2 ;;
      --every)  every="${2:-}"; every="${every%h}"; shift 2 ;;
      *) die "Неизвестная опция auto-update enable: $1" ;;
    esac
  done
  [[ "${window}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "Окно должно быть в формате HH:MM-HH:MM (локальное время), например 03:00-05:00"
  [[ "${every}" =~ ^[0-9]+$ && "${every}" -ge 1 ]] || die "--every: число часов (1 и больше), например 24"
  ctl="$(auto_ctl_path)"

  mkdir -p "${AUTO_CONF_DIR}" "${AUTO_STATE_DIR}"
  cat >"${AUTO_CONF}" <<CONF
# connectorctl auto-update (managed by: connectorctl auto-update enable)
WINDOW_START=${window%-*}
WINDOW_END=${window#*-}
EVERY_HOURS=${every}
CONF
  chmod 644 "${AUTO_CONF}"

  if auto_use_systemd; then
    for tmpl in connectorctl-update.service connectorctl-update.timer; do
      [[ -f "${INSTALLER_ROOT}/deploy/systemd/${tmpl}" ]] || die "Нет шаблона ${INSTALLER_ROOT}/deploy/systemd/${tmpl}"
      rendered="$(mktemp)"
      sed -e "s|__CTL__|${ctl}|g" "${INSTALLER_ROOT}/deploy/systemd/${tmpl}" >"${rendered}"
      mkdir -p "${AUTO_SYSTEMD_DIR}"
      install -m 0644 "${rendered}" "${AUTO_SYSTEMD_DIR}/${tmpl}"
      rm -f "${rendered}"
    done
    rm -f "${AUTO_CRON_FILE}"
    systemctl daemon-reload
    systemctl enable --now connectorctl-update.timer
    log_ok "Автообновление включено (systemd timer connectorctl-update.timer)"
  else
    mkdir -p "$(dirname "${AUTO_CRON_FILE}")"
    cat >"${AUTO_CRON_FILE}" <<CRON
# connectorctl auto-update: hourly tick; window/interval are enforced by connectorctl
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root ${ctl} auto-update run >>${AUTO_LOG_FILE} 2>&1
CRON
    chmod 644 "${AUTO_CRON_FILE}"
    log_ok "Автообновление включено (cron: ${AUTO_CRON_FILE})"
  fi
  print_kv "Окно" "${window} (локальное время)"
  print_kv "Проверка" "не чаще раза в ${every} ч; только minor/patch, мажорные — вручную"
  print_kv "Журнал" "$(auto_use_systemd && echo 'journalctl -u connectorctl-update' || echo "${AUTO_LOG_FILE}")"
}

auto_disable() {
  if auto_use_systemd; then
    systemctl disable --now connectorctl-update.timer 2>/dev/null || true
  fi
  rm -f "${AUTO_SYSTEMD_DIR}/connectorctl-update.timer" "${AUTO_SYSTEMD_DIR}/connectorctl-update.service" \
        "${AUTO_CRON_FILE}" "${AUTO_CONF}" "${AUTO_STATE}"
  if auto_use_systemd; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed connectorctl-update.service 2>/dev/null || true
  fi
  rmdir "${AUTO_CONF_DIR}" "${AUTO_STATE_DIR}" 2>/dev/null || true
  log_ok "Автообновление выключено: timer/cron и настройки удалены"
}

auto_status() {
  local mech="выключено" start end every last res msg ver
  if [[ -f "${AUTO_SYSTEMD_DIR}/connectorctl-update.timer" ]]; then mech="включено (systemd timer)"
  elif [[ -f "${AUTO_CRON_FILE}" ]]; then mech="включено (cron)"; fi
  printf '\n  %s · автообновление\n' "${PRODUCT_NAME}"
  printf "  ${C_DIM}────────────────────────────────────────────────────${C_RESET}\n"
  print_kv "Состояние" "${mech}"
  if [[ "${mech}" == "выключено" ]]; then
    printf "  ${C_DIM}Включить: sudo connectorctl auto-update enable [--window 03:00-05:00] [--every 24]${C_RESET}\n\n"
    return 0
  fi
  start="$(auto_conf_get WINDOW_START)"; end="$(auto_conf_get WINDOW_END)"; every="$(auto_conf_get EVERY_HOURS)"
  print_kv "Окно" "${start:-03:00}-${end:-05:00} (локальное время)"
  print_kv "Интервал" "${every:-24} ч; только minor/patch"
  if [[ "${mech}" == *systemd* ]] && command -v systemctl >/dev/null 2>&1; then
    print_kv "След. тик" "$(systemctl show connectorctl-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo '—')"
  fi
  last="$(auto_state_get LAST_CHECK)"
  res="$(auto_state_get LAST_RESULT)"; msg="$(auto_state_get LAST_MESSAGE)"; ver="$(auto_state_get LAST_VERSION)"
  if [[ -n "${res}" ]]; then
    print_kv "Последняя проверка" "$([[ -n "${last}" ]] && auto_human "${last}" || echo '—')"
    print_kv "Результат" "${res}" "${msg}"
    print_kv "Версия" "${ver:-—}"
    [[ -n "$(auto_state_get SKIP_VERSION)" ]] && print_kv "Пропускается" "$(auto_state_get SKIP_VERSION)" "(откат; ждём новую версию)"
  else
    print_kv "Последняя проверка" "ещё не было"
  fi
  printf '\n'
}

cmd_auto_update() {
  local sub="${1:-status}"
  [[ $# -gt 0 ]] && shift
  case "${sub}" in
    enable)  need_root auto-update enable "$@"; auto_enable "$@" ;;
    disable) need_root auto-update disable "$@"; auto_disable ;;
    status)  auto_status ;;
    run)     need_root auto-update run "$@"; auto_run "$@" ;;
    -h|--help|help)
      printf 'Использование: connectorctl auto-update enable [--window HH:MM-HH:MM] [--every ЧАСЫ] | disable | status\n' ;;
    *) die "Неизвестная подкоманда auto-update: ${sub} (enable|disable|status)" ;;
  esac
}
