#!/usr/bin/env bash
# Helpers for locating Asterisk/FreePBX call recordings (MixMonitor).
# Sourced by scripts/connectorctl (detect-recordings, fix-recordings, doctor).
# Requires lib/common.sh (log_*, DEFAULT_CONNECTOR_USER) to be sourced first.

# Print candidate recording dirs as "score<TAB>path<TAB>reason", best first.
# Return 1 if nothing was found.
list_recordings_candidates() {
  local tmp spool conf d score reason recent
  tmp="$(mktemp)"
  declare -A seen=()

  _rec_add() {
    local path="$1" base_score="$2" why="$3" real
    [[ -n "${path}" && -d "${path}" ]] || return 0
    real="$(readlink -f "${path}" 2>/dev/null || printf '%s' "${path}")"
    [[ -n "${seen[${real}]:-}" ]] && return 0
    seen["${real}"]=1
    recent="$(find "${real}" -type f \( -name '*.wav' -o -name '*.WAV' -o -name '*.mp3' -o -name '*.gsm' -o -name '*.ogg' \) \
      -mtime -7 2>/dev/null | head -50 | wc -l | tr -d ' ')"
    score=$((base_score + ${recent:-0}))
    printf '%s\t%s\t%s\n' "${score}" "${real}" "${why}; свежих файлов: ${recent:-0}" >>"${tmp}"
  }

  # Explicit configuration wins.
  [[ -n "${RECORDINGS_DIR:-}" ]] && _rec_add "${RECORDINGS_DIR}" 500 "RECORDINGS_DIR из окружения"
  [[ -n "${RECORDINGS_PATH:-}" ]] && _rec_add "${RECORDINGS_PATH}" 490 "RECORDINGS_PATH из окружения"

  # astspooldir from asterisk.conf -> <spool>/monitor
  for conf in /etc/asterisk/asterisk.conf /usr/local/etc/asterisk/asterisk.conf; do
    [[ -r "${conf}" ]] || continue
    spool="$(sed -nE 's/^[[:space:]]*astspooldir[[:space:]]*(=>|=)[[:space:]]*([^;[:space:]]+).*/\2/p' "${conf}" | head -1)"
    [[ -n "${spool}" ]] && _rec_add "${spool}/monitor" 300 "astspooldir в ${conf}"
  done

  # Well-known locations (FreePBX / vanilla Asterisk / ISPsystem-style).
  for d in /var/spool/asterisk/monitor /var/spool/asterisk/recording \
           /var/spool/asterisk/recordings /var/lib/asterisk/monitor \
           /var/lib/asterisk/recordings /usr/local/var/spool/asterisk/monitor; do
    _rec_add "${d}" 100 "стандартный путь"
  done

  unset -f _rec_add
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    return 1
  fi
  sort -t$'\t' -k1,1nr "${tmp}"
  rm -f "${tmp}"
}

# Print the best recordings dir. Return 1 if none.
detect_recordings_dir() {
  local best
  best="$(list_recordings_candidates 2>/dev/null | head -1 | cut -f2)" || return 1
  [[ -n "${best}" ]] || return 1
  printf '%s\n' "${best}"
}

# systemd ProtectHome value: false when recordings or install dir live under /home or /root.
recordings_protect_home_value() {
  local rec="${1:-}" root="${2:-}" p
  for p in "${rec}" "${root}"; do
    case "${p}" in /root|/root/*|/home|/home/*) printf 'false\n'; return 0 ;; esac
  done
  printf 'true\n'
}

# Make DIR readable for USER (best effort): ACL if available, else join the dir's group.
ensure_recordings_readable() {
  local dir="${1:?dir}" user="${2:-${DEFAULT_CONNECTOR_USER:-connector}}" grp
  [[ -d "${dir}" ]] || return 1
  if runuser -u "${user}" -- test -r "${dir}" -a -x "${dir}" 2>/dev/null; then
    return 0
  fi
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -m "u:${user}:rX" "${dir}" 2>/dev/null \
      && setfacl -d -R -m "u:${user}:rX" "${dir}" 2>/dev/null || true
  fi
  if ! runuser -u "${user}" -- test -r "${dir}" 2>/dev/null; then
    grp="$(stat -c '%G' "${dir}" 2>/dev/null || true)"
    if [[ -n "${grp}" && "${grp}" != "root" && "${grp}" != "UNKNOWN" ]]; then
      usermod -aG "${grp}" "${user}" 2>/dev/null \
        && log_warn "Пользователь ${user} добавлен в группу ${grp}; перезапустите сервисы"
    fi
  fi
  runuser -u "${user}" -- test -r "${dir}" 2>/dev/null
}
