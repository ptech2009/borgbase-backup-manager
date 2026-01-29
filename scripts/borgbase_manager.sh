#!/usr/bin/env bash
# BorgBase Backup Manager
#
# Features / Fixes:
# - ALWAYS show a language selector on interactive start (DE/EN) before the menu (requested).
#   - Default selection is the last saved UI_LANG (from ENV_FILE or env), but prompt is shown every time.
#   - Non-interactive runs (no TTY) will not prompt and will keep UI_LANG (or default to de).
# - No hard exit from menu when connection test fails (set -e + ERR trap safe handling)
# - Repo lock timeout is treated as WARNING (or OK if own worker running), not "connection failed"
# - Live progress display is more readable (convert CR -> NL, de-duplicate repeated lines)
# - Menu shows BOTH:
#   - current JOB/activity status (what the script is doing right now)
#   - last connection/repo status (connectivity)
# - After successful upload/download: a clear, unambiguous "UPLOAD: Abgeschlossen ..." / "DOWNLOAD: Abgeschlossen ..."
#
# Requirements:
#   bash >= 4, borg >= 1.2, ssh, findmnt(optional), ssh-keygen(optional), ssh-keyscan(optional)

set -euo pipefail
set -E

trap 'rc=$?; echo "ERROR at line $LINENO: $BASH_COMMAND (rc=$rc)" >&2; exit $rc' ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# -------------------- Colors --------------------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; NC=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; NC=""
fi

# -------------------- UI constants --------------------
STATUS_FIELD_WIDTH=49
strip_ansi() { sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

pad_to_width() {
  local width="$1"
  local s="$2"
  local plain len pad
  plain="$(printf '%s' "$s" | strip_ansi)"
  len="${#plain}"
  if (( len >= width )); then
    printf '%s' "$s"
    return 0
  fi
  pad=$((width - len))
  printf '%s%*s' "$s" "$pad" ""
}

format_duration() {
  local sec="${1:-0}"
  local h m s
  h=$((sec/3600))
  m=$(((sec%3600)/60))
  s=$((sec%60))
  if (( h > 0 )); then
    printf "%dh %02dm %02ds" "$h" "$m" "$s"
  else
    printf "%dm %02ds" "$m" "$s"
  fi
}

# -------------------- Paths (per-user) --------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/borgbase-backup-manager"
ENV_FILE="${CONFIG_DIR}/borgbase-manager.env"
DEFAULT_PASSPHRASE_FILE="${CONFIG_DIR}/borg_passphrase"
DEFAULT_SSHKEY_PASSPHRASE_FILE="${CONFIG_DIR}/sshkey_passphrase"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/borgbase-backup-manager"

mkdir -p "$CONFIG_DIR" "$DEFAULT_STATE_DIR" 2>/dev/null || true

# Runtime dir for PID/STATUS
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -d "$RUNTIME_DIR" || ! -w "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/borgbase-backup-manager"
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || RUNTIME_DIR="/tmp"
fi

# Separate status channels:
JOB_STATUS_FILE="${RUNTIME_DIR}/borgbase-job-status"
CONN_STATUS_FILE="${RUNTIME_DIR}/borgbase-conn-status"
PID_FILE="${RUNTIME_DIR}/borgbase-worker.pid"
START_FILE="${RUNTIME_DIR}/borgbase-worker.start"

# -------------------- Defaults (GitHub-safe placeholders) --------------------
# UI_LANG can be set by environment or stored in ENV_FILE.
UI_LANG="${UI_LANG:-}"

REPO="${REPO:-ssh://user@user.repo.borgbase.com/./repo}"  # placeholder
SRC_DIR="${SRC_DIR:-}"                                    # empty => auto-detect panzerbackup
SSH_KEY="${SSH_KEY:-}"                                    # empty => auto-detect
PREFERRED_KEY_HINT="${PREFERRED_KEY_HINT:-}"              # optional hint (e.g. "newvorta")
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"

LOG_FILE="${LOG_FILE:-$DEFAULT_STATE_DIR/borgbase-manager.log}"

PASSPHRASE_FILE="${PASSPHRASE_FILE:-$DEFAULT_PASSPHRASE_FILE}"                        # repo passphrase file
SSH_KEY_PASSPHRASE_FILE="${SSH_KEY_PASSPHRASE_FILE:-$DEFAULT_SSHKEY_PASSPHRASE_FILE}" # optional ssh-key passphrase file

PRUNE="${PRUNE:-yes}"
KEEP_LAST="${KEEP_LAST:-1}"

SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
BORG_LOCK_WAIT="${BORG_LOCK_WAIT:-5}"            # worker lock-wait
BORG_TEST_LOCK_WAIT="${BORG_TEST_LOCK_WAIT:-1}"  # connection test lock-wait (short; lock => warning)

AUTO_ACCEPT_HOSTKEY="${AUTO_ACCEPT_HOSTKEY:-no}" # if yes: ssh-keyscan (optional)
AUTO_TEST_SSH="${AUTO_TEST_SSH:-yes}"
AUTO_TEST_REPO="${AUTO_TEST_REPO:-yes}"

# -------------------- Load config --------------------
load_env() {
  # shellcheck disable=SC1090
  [[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

  if [[ -r "./.env" ]]; then
    # shellcheck disable=SC1091
    source "./.env"
  fi
}

# -------------------- i18n --------------------
say() { local de="$1" en="$2"; [[ "${UI_LANG:-de}" == "en" ]] && echo -e "$en" || echo -e "$de"; }

pause_tty() {
  local msg="${1:-}"
  [[ -n "$msg" ]] && read -r -p "$msg" _ || read -r -p "" _
}

# -------------------- Status (JOB + CONN) --------------------
set_job_status()  { echo "$1" > "$JOB_STATUS_FILE"; }
set_conn_status() { echo "$1" > "$CONN_STATUS_FILE"; }

get_job_status() {
  if [[ -s "$JOB_STATUS_FILE" ]]; then
    tail -n1 "$JOB_STATUS_FILE"
  else
    say "Kein Job aktiv." "No job active."
  fi
}

get_conn_status() {
  if [[ -s "$CONN_STATUS_FILE" ]]; then
    tail -n1 "$CONN_STATUS_FILE"
  else
    say "Repo/Verbindung: nicht getestet." "Repo/connection: not tested."
  fi
}

get_job_status_formatted() {
  local s; s="$(get_job_status)"

  # If worker is running, optionally append runtime
  if is_running; then
    if [[ -s "$START_FILE" ]]; then
      local start now dur
      start="$(cat "$START_FILE" 2>/dev/null || echo 0)"
      now="$(date +%s)"
      dur=$((now - start))
      s="${s} ($(format_duration "$dur"))"
    else
      s="${s} (running)"
    fi
  fi

  if [[ "$s" == *"FEHLER"* || "$s" == *"ERROR"* || "$s" == *"failed"* ]]; then
    echo "${R}${s}${NC}"
  elif [[ "$s" == *"WARN"* || "$s" == *"gesperrt"* || "$s" == *"locked"* || "$s" == *"BUSY"* ]]; then
    echo "${Y}${s}${NC}"
  elif [[ "$s" == *"Abgeschlossen"* || "$s" == *"Finished"* || "$s" == OK* ]]; then
    echo "${G}${s}${NC}"
  elif [[ "$s" == *"UPLOAD"* || "$s" == *"DOWNLOAD"* ]]; then
    echo "${Y}${s}${NC}"
  else
    echo "$s"
  fi
}

get_conn_status_formatted() {
  local s; s="$(get_conn_status)"
  if [[ "$s" == *"FEHLER"* || "$s" == *"ERROR"* || "$s" == *"failed"* ]]; then
    echo "${R}${s}${NC}"
  elif [[ "$s" == *"WARN"* || "$s" == *"gesperrt"* || "$s" == *"locked"* || "$s" == *"BUSY"* ]]; then
    echo "${Y}${s}${NC}"
  elif [[ "$s" == *"Verbindung erfolgreich"* || "$s" == *"Connection established"* || "$s" == OK* ]]; then
    echo "${G}${s}${NC}"
  else
    echo "$s"
  fi
}

# -------------------- Process tracking --------------------
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; return 1; }
  ps -p "$pid" >/dev/null 2>&1 && return 0
  rm -f "$PID_FILE"
  return 1
}

clear_status() {
  if ! is_running; then
    rm -f "$JOB_STATUS_FILE" "$CONN_STATUS_FILE" "$START_FILE" 2>/dev/null || true
  fi
}

# -------------------- Log file --------------------
ensure_logfile_writable() {
  local dir
  dir="$(dirname -- "$LOG_FILE")"
  mkdir -p "$dir" 2>/dev/null || true
  if touch "$LOG_FILE" 2>/dev/null; then
    return 0
  fi
  LOG_FILE="/tmp/borgbase-manager.log"
  touch "$LOG_FILE" 2>/dev/null || true
}

# -------------------- Helpers --------------------
expand_path() {
  local p="${1:-}"
  [[ -z "$p" ]] && { echo ""; return 0; }
  if [[ "$p" == "~/"* ]]; then echo "$HOME/${p#~/}"; return 0; fi
  if [[ "$p" == "~" ]]; then echo "$HOME"; return 0; fi
  echo "$p"
}

human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'function human(x){s="B KiB MiB GiB TiB PiB";split(s,a," ");i=1;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,a[i])} BEGIN{print human(b)}'
}

# -------------------- Repo parsing (port-aware) --------------------
_repo_authority() {
  local r="$1"
  r="${r#ssh://}"
  r="${r%%/*}"
  echo "$r"
}

_user_from_repo() {
  local a; a="$(_repo_authority "$1")"
  echo "${a%%@*}"
}

_host_from_repo() {
  local a hostport
  a="$(_repo_authority "$1")"
  hostport="${a#*@}"
  echo "${hostport%%:*}"
}

_port_from_repo() {
  local a hostport
  a="$(_repo_authority "$1")"
  hostport="${a#*@}"
  if [[ "$hostport" == *:* ]]; then
    echo "${hostport##*:}"
  else
    echo ""
  fi
}

_knownhosts_host_from_repo() {
  local h p
  h="$(_host_from_repo "$1")"
  p="$(_port_from_repo "$1")"
  if [[ -n "$p" ]]; then
    echo "[${h}]:${p}"
  else
    echo "$h"
  fi
}

_ssh_port_opt_from_repo() {
  local p
  p="$(_port_from_repo "$1")"
  if [[ -n "$p" ]]; then
    echo "-p" "$p"
  else
    echo ""
  fi
}

# -------------------- Env file writer --------------------
write_env_file() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  cat > "$ENV_FILE" <<EOF
# BorgBase Backup Manager - User config
# Location: $ENV_FILE
# Notes:
# - Keep repo passphrase in PASSPHRASE_FILE (chmod 600). Do NOT store it inline.
# - Leave SSH_KEY="" to enable auto-detection.

UI_LANG="${UI_LANG:-de}"

REPO="${REPO}"
SRC_DIR="${SRC_DIR}"

SSH_KEY="${SSH_KEY}"
PREFERRED_KEY_HINT="${PREFERRED_KEY_HINT}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS}"

PASSPHRASE_FILE="${PASSPHRASE_FILE}"
SSH_KEY_PASSPHRASE_FILE="${SSH_KEY_PASSPHRASE_FILE}"

LOG_FILE="${LOG_FILE}"

PRUNE="${PRUNE}"
KEEP_LAST="${KEEP_LAST}"

SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT}"
BORG_LOCK_WAIT="${BORG_LOCK_WAIT}"
BORG_TEST_LOCK_WAIT="${BORG_TEST_LOCK_WAIT}"

AUTO_ACCEPT_HOSTKEY="${AUTO_ACCEPT_HOSTKEY}"
AUTO_TEST_SSH="${AUTO_TEST_SSH}"
AUTO_TEST_REPO="${AUTO_TEST_REPO}"
EOF
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# -------------------- Startup language selector (FIXED) --------------------
startup_language_selector_force() {
  [[ -t 0 && -t 1 ]] || {
    [[ -z "${UI_LANG:-}" ]] && UI_LANG="de"
    return 0
  }

  local def="${UI_LANG:-de}"
  case "$def" in
    de|en) ;;
    *) def="de" ;;
  esac

  echo ""
  echo "============================================================"
  echo "Language / Sprache"
  echo "============================================================"
  echo "1) Deutsch"
  echo "2) English"
  echo ""

  local prompt_default="1"
  [[ "$def" == "en" ]] && prompt_default="2"

  local choice=""
  while true; do
    read -r -p "Select / Auswahl [1-2] (default ${prompt_default}): " choice || choice="$prompt_default"
    [[ -z "$choice" ]] && choice="$prompt_default"
    case "$choice" in
      1) UI_LANG="de"; break ;;
      2) UI_LANG="en"; break ;;
      de|DE) UI_LANG="de"; break ;;
      en|EN) UI_LANG="en"; break ;;
      *) echo "Invalid / Ungültig. Please choose 1 or 2." ;;
    esac
  done

  write_env_file >/dev/null 2>&1 || true
  return 0
}

# -------------------- Panzerbackup SRC auto-detection --------------------
detect_src_dir() {
  has_upload_set() {
    shopt -s nullglob
    local files=( "$1"/panzer_*.img.zst.gpg )
    shopt -u nullglob
    (( ${#files[@]} > 0 ))
  }

  if [[ -n "${SRC_DIR:-}" && -d "$SRC_DIR" ]] && has_upload_set "$SRC_DIR"; then
    return 0
  fi

  say "Versuche, Panzerbackup-Volume automatisch zu finden..." \
      "Trying to auto-detect a Panzerbackup volume..."

  local bases=(/mnt /media /run/media)
  local candidates=()
  local base d

  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' d; do candidates+=( "$d" ); done \
      < <(find "$base" -maxdepth 4 -type d -iname "*panzerbackup*" -print0 2>/dev/null || true)
  done

  if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r d; do [[ -d "$d" ]] && candidates+=( "$d" ); done \
      < <(findmnt -rno TARGET | awk 'BEGIN{IGNORECASE=1}/panzerbackup/{print}')
  fi

  (( ${#candidates[@]} )) && mapfile -t candidates < <(printf "%s\n" "${candidates[@]}" | awk '!seen[$0]++')

  local valid=()
  for d in "${candidates[@]:-}"; do
    has_upload_set "$d" && valid+=( "$d" )
  done

  if (( ${#valid[@]} == 0 )); then
    say "Kein Verzeichnis mit panzer_*.img.zst.gpg gefunden. Bitte SRC_DIR manuell angeben." \
        "No directory containing panzer_*.img.zst.gpg found. Please enter SRC_DIR manually."
    local manual=""
    read -r -p "$(say 'SRC_DIR Pfad: ' 'SRC_DIR path: ')" manual || return 1
    manual="$(expand_path "$manual")"
    [[ -d "$manual" ]] && has_upload_set "$manual" || {
      set_job_status "FEHLER: SRC_DIR ungültig (keine panzer_*.img.zst.gpg gefunden)"
      return 1
    }
    SRC_DIR="$manual"
    return 0
  fi

  local best_dir="" best_mtime=0 newest mt
  for d in "${valid[@]}"; do
    newest="$(ls -1t "$d"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
    [[ -n "$newest" ]] || continue
    mt="$(stat -c %Y "$newest" 2>/dev/null || echo 0)"
    (( mt > best_mtime )) && { best_mtime="$mt"; best_dir="$d"; }
  done

  SRC_DIR="$best_dir"
  say "${G}Backup-Verzeichnis gefunden: $SRC_DIR${NC}" "${G}Detected backup directory: $SRC_DIR${NC}"
  return 0
}

# -------------------- Upload selection --------------------
get_latest_backup_base() {
  local latest_img
  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  [[ -n "$latest_img" ]] || return 1
  echo "${latest_img%.img.zst.gpg}"
}

show_upload_selection() {
  local base img sha sfd mt_epoch mt_h size_bytes size_h
  base="$(get_latest_backup_base)" || {
    set_job_status "FEHLER: Kein Backup im Quellverzeichnis gefunden"
    return 1
  }

  img="${base}.img.zst.gpg"
  sha="${base}.img.zst.gpg.sha256"
  sfd="${base}.sfdisk"

  for f in "$img" "$sha" "$sfd"; do
    [[ -f "$f" ]] || { set_job_status "FEHLER: Datei fehlt: $(basename "$f")"; return 1; }
  done

  mt_epoch="$(stat -c %Y "$img" 2>/dev/null || echo 0)"
  mt_h="$(date -d "@$mt_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "n/a")"
  size_bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"
  size_h="$(human_bytes "$size_bytes")"

  echo ""
  say "${B}Geplantes Upload-Set (NEUESTES Backup):${NC}" "${B}Planned upload set (LATEST backup):${NC}"
  echo "  SRC_DIR : $SRC_DIR"
  echo "  IMG     : $(basename "$img")"
  echo "  Datum   : $mt_h"
  echo "  Größe   : $size_h ($size_bytes Bytes)"
  echo "  SHA     : $(basename "$sha")"
  echo "  SFDISK  : $(basename "$sfd")"
  echo ""
}

# -------------------- SSH key auto-detection --------------------
detect_ssh_key_from_ssh_config() {
  local cfg="$HOME/.ssh/config"
  [[ -r "$cfg" ]] || return 1

  local ids=()
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*IdentityFile[[:space:]]+(.+)$ ]] || continue
    local p="${BASH_REMATCH[1]}"
    p="${p%\"}"; p="${p#\"}"
    p="$(expand_path "$p")"
    ids+=( "$p" )
  done < "$cfg"

  (( ${#ids[@]} )) || return 1

  local p
  for p in "${ids[@]}"; do
    [[ -n "${PREFERRED_KEY_HINT:-}" ]] || continue
    [[ "$p" == *"$PREFERRED_KEY_HINT"* ]] && [[ -r "$p" ]] && { echo "$p"; return 0; }
  done
  for p in "${ids[@]}"; do
    [[ "$p" == *"ed25519"* ]] && [[ -r "$p" ]] && { echo "$p"; return 0; }
  done
  for p in "${ids[@]}"; do
    [[ -r "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

detect_ssh_key_standard() {
  local keys=()
  local d="$HOME/.ssh"
  [[ -d "$d" ]] || return 1

  if [[ -n "${PREFERRED_KEY_HINT:-}" ]]; then
    while IFS= read -r -d '' f; do keys+=( "$f" ); done \
      < <(find "$d" -maxdepth 1 -type f -name "*${PREFERRED_KEY_HINT}*" -print0 2>/dev/null || true)
  fi

  local common=(id_ed25519 id_ed25519_* id_rsa id_ecdsa id_dsa)
  local c
  for c in "${common[@]}"; do
    while IFS= read -r -d '' f; do keys+=( "$f" ); done \
      < <(find "$d" -maxdepth 1 -type f -name "$c" -print0 2>/dev/null || true)
  done

  (( ${#keys[@]} )) || return 1
  mapfile -t keys < <(printf "%s\n" "${keys[@]}" | awk '!seen[$0]++')

  local f
  for f in "${keys[@]}"; do
    [[ "$f" == *.pub ]] && continue
    [[ -r "$f" ]] || continue
    [[ "$f" == *"ed25519"* ]] && { echo "$f"; return 0; }
  done
  for f in "${keys[@]}"; do
    [[ "$f" == *.pub ]] && continue
    [[ -r "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

resolve_ssh_key() {
  if [[ -n "${SSH_KEY:-}" ]]; then
    local k; k="$(expand_path "$SSH_KEY")"
    [[ -r "$k" ]] && { SSH_KEY="$k"; return 0; }
    return 1
  fi

  local k=""
  k="$(detect_ssh_key_from_ssh_config 2>/dev/null || true)"
  if [[ -n "$k" && -r "$k" ]]; then
    SSH_KEY="$k"
    return 0
  fi

  k="$(detect_ssh_key_standard 2>/dev/null || true)"
  if [[ -n "$k" && -r "$k" ]]; then
    SSH_KEY="$k"
    return 0
  fi

  SSH_KEY=""
  return 0
}

# -------------------- known_hosts helper --------------------
ensure_known_hosts() {
  [[ "${AUTO_ACCEPT_HOSTKEY}" == "yes" ]] || return 0
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  command -v ssh-keyscan >/dev/null 2>&1 || return 0

  local host plain_host port host_for_kh
  plain_host="$(_host_from_repo "${REPO}")"
  port="$(_port_from_repo "${REPO}")"
  host_for_kh="$(_knownhosts_host_from_repo "${REPO}")"

  mkdir -p "$(dirname -- "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
  touch "$SSH_KNOWN_HOSTS" 2>/dev/null || true

  if ssh-keygen -F "$host_for_kh" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
    return 0
  fi

  say "SSH: Hostkey für ${host_for_kh} fehlt – füge via ssh-keyscan hinzu..." \
      "SSH: Missing hostkey for ${host_for_kh} — adding via ssh-keyscan..."

  if [[ -n "$port" ]]; then
    timeout "${SSH_CONNECT_TIMEOUT}" ssh-keyscan -H -p "$port" -t ed25519,ecdsa,rsa "$plain_host" >> "$SSH_KNOWN_HOSTS" 2>/dev/null || true
  else
    timeout "${SSH_CONNECT_TIMEOUT}" ssh-keyscan -H -t ed25519,ecdsa,rsa "$plain_host" >> "$SSH_KNOWN_HOSTS" 2>/dev/null || true
  fi
}

# -------------------- Repo passphrase handling --------------------
load_repo_passphrase() {
  if [[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]]; then
    export BORG_PASSPHRASE
    BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"
    return 0
  fi
  if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
    export BORG_PASSPHRASE
    return 0
  fi
  return 1
}

# -------------------- Borg env setup (deterministic) --------------------
setup_borg_env() {
  ensure_logfile_writable

  SSH_KNOWN_HOSTS="$(expand_path "$SSH_KNOWN_HOSTS")"
  mkdir -p "$(dirname -- "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
  touch "$SSH_KNOWN_HOSTS" 2>/dev/null || true

  resolve_ssh_key || true
  ensure_known_hosts

  local port_opt
  port_opt="$(_ssh_port_opt_from_repo "${REPO}")"

  local ssh_base
  ssh_base="ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} ${port_opt}"

  if [[ -n "${SSH_KEY:-}" && -r "${SSH_KEY}" ]]; then
    export BORG_RSH="${ssh_base} -i ${SSH_KEY} -o IdentitiesOnly=yes"
  else
    export BORG_RSH="${ssh_base}"
  fi

  if ! load_repo_passphrase; then
    set_conn_status "$(say 'FEHLER: Repo-Passphrase fehlt (PASSPHRASE_FILE ungültig/Datei fehlt). Bitte Wizard (8) ausführen.' \
                        'ERROR: Missing repo passphrase (invalid/missing PASSPHRASE_FILE). Please run Wizard (8).')"
    return 1
  fi

  return 0
}

# -------------------- Connection test --------------------
test_ssh_auth() {
  [[ "${AUTO_TEST_SSH}" == "yes" ]] || return 0

  local host user out port_opt
  host="$(_host_from_repo "${REPO}")"
  user="$(_user_from_repo "${REPO}")"
  port_opt="$(_ssh_port_opt_from_repo "${REPO}")"

  # shellcheck disable=SC2086
  out="$(ssh -T -o RequestTTY=no -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
    ${port_opt} \
    ${SSH_KEY:+-i "$SSH_KEY" -o IdentitiesOnly=yes} \
    "${user}@${host}" -- borg --version 2>&1 || true)"

  echo "$out" >> "$LOG_FILE" 2>/dev/null || true

  if echo "$out" | grep -qiE 'host key verification failed|remote host identification has changed'; then
    set_conn_status "FEHLER: SSH Hostkey Problem (known_hosts)."
    return 1
  fi
  if echo "$out" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    set_conn_status "FEHLER: SSH Auth fehlgeschlagen (publickey)."
    return 1
  fi
  if echo "$out" | grep -qiE 'enter passphrase for key|incorrect passphrase|bad passphrase'; then
    set_conn_status "FEHLER: SSH-Key Passphrase benötigt/falsch."
    return 1
  fi

  echo "$out" | grep -qiE '^borg ' || {
    set_conn_status "FEHLER: SSH Test fehlgeschlagen."
    return 1
  }

  return 0
}

is_lock_timeout_output() {
  grep -qiE 'Failed to create/acquire the lock|lock\.exclusive|timeout\)\.|repository is already locked|Could not acquire lock' <<<"$1"
}

test_borg_repo() {
  [[ "${AUTO_TEST_REPO}" == "yes" ]] || return 0

  local out rc
  out="$(borg info --lock-wait "${BORG_TEST_LOCK_WAIT}" "${REPO}" 2>&1)" || rc=$? || true
  rc="${rc:-0}"

  echo "$out" >> "$LOG_FILE" 2>/dev/null || true

  if (( rc == 0 )); then
    return 0
  fi

  if is_lock_timeout_output "$out"; then
    if is_running; then
      set_conn_status "OK: Repo erreichbar (BUSY/Lock durch laufenden Job)."
      return 0
    fi
    set_conn_status "WARNUNG: Repo gesperrt (Lock-Timeout) – später erneut versuchen."
    return 2
  fi

  return 1
}

test_connection() {
  setup_borg_env || return 1

  if ! test_ssh_auth; then
    return 1
  fi

  if test_borg_repo; then
    set_conn_status "OK: Verbindung erfolgreich hergestellt."
    echo -e "${G}$(say 'Verbindung erfolgreich hergestellt.' 'Connection established successfully.')${NC}"
    [[ -n "${SSH_KEY:-}" ]] && echo "SSH_KEY: $SSH_KEY"
    echo "REPO: $REPO"
    return 0
  else
    local rc=$?
    if (( rc == 2 )); then
      echo -e "${Y}$(say 'Repo ist derzeit gesperrt (Lock). SSH/Passphrase sind OK.' 'Repo is currently locked. SSH/passphrase are OK.')${NC}"
      return 2
    fi
    set_conn_status "FEHLER: Repo-Verbindung fehlgeschlagen."
    return 1
  fi
}

# -------------------- Startup repo status check --------------------
startup_repo_check() {
  ensure_logfile_writable

  if [[ ! -r "$ENV_FILE" ]]; then
    set_conn_status "$(say 'Hinweis: Keine Konfiguration gefunden. Bitte Wizard (8) ausführen.' \
                        'Note: No configuration found. Please run Wizard (8).')"
    return 0
  fi

  load_env || true

  PASSPHRASE_FILE="$(expand_path "${PASSPHRASE_FILE:-$DEFAULT_PASSPHRASE_FILE}")"
  if [[ "$PASSPHRASE_FILE" != /* ]]; then
    PASSPHRASE_FILE="$DEFAULT_PASSPHRASE_FILE"
    write_env_file || true
  fi

  if [[ ! -f "$PASSPHRASE_FILE" || ! -s "$PASSPHRASE_FILE" ]]; then
    set_conn_status "$(say 'FEHLER: Repo-Passphrase fehlt (Passphrase-Datei fehlt/leer). Wizard (8) ausführen.' \
                        'ERROR: Repo passphrase missing (passphrase file missing/empty). Run Wizard (8).')"
    return 0
  fi

  # Do not overwrite JOB status here; only refresh CONN status
  if test_connection >/dev/null 2>&1; then :; else :; fi
  return 0
}

# -------------------- Config wizard helpers --------------------
read_line() {
  local prompt="$1" varname="$2" def="$3"
  local in=""
  read -r -p "${prompt} [${def}]: " in || in="$def"
  [[ -z "$in" ]] && in="$def"
  printf -v "$varname" '%s' "$in"
}

read_secret() {
  local prompt="$1"
  local out=""
  # shellcheck disable=SC2162
  read -s -p "$prompt" out || out=""
  echo ""
  echo "$out"
}

ensure_repo_format_minimal() {
  [[ "$REPO" == ssh://* ]] || return 1
  [[ "$REPO" == *"@"* ]] || return 1
  return 0
}

prompt_repo_passphrase_loop() {
  mkdir -p "$(dirname -- "$PASSPHRASE_FILE")" 2>/dev/null || true
  while true; do
    local p1 p2
    p1="$(read_secret "$(say 'Repo-Passphrase: ' 'Repo passphrase: ')")"
    p2="$(read_secret "$(say 'Repo-Passphrase (wiederholen): ' 'Repo passphrase (repeat): ')")"
    if [[ -z "$p1" || "$p1" != "$p2" ]]; then
      echo -e "${R}$(say 'Passphrase leer oder stimmt nicht überein. Bitte erneut.' 'Passphrase empty or does not match. Please retry.')${NC}"
      continue
    fi
    printf '%s' "$p1" > "$PASSPHRASE_FILE"
    chmod 600 "$PASSPHRASE_FILE" 2>/dev/null || true
    export BORG_PASSPHRASE="$p1"
    return 0
  done
}

configure_wizard() {
  echo ""
  echo "============================================================"
  echo "$(say 'Konfiguration (Wizard)' 'Configuration (Wizard)')"
  echo "============================================================"

  startup_language_selector_force || true

  while true; do
    read_line "$(say 'BorgBase Repo URL (ssh://user@host[:port]/./repo)' 'BorgBase repo URL (ssh://user@host[:port]/./repo)')" REPO "$REPO"
    if ensure_repo_format_minimal; then
      break
    fi
    echo -e "${R}$(say 'Ungültiges REPO-Format. Muss mit ssh:// beginnen und user@host enthalten.' 'Invalid REPO format. Must start with ssh:// and include user@host.')${NC}"
  done

  local src_in=""
  read -r -p "$(say 'Quellverzeichnis (SRC_DIR) - Enter für Auto-Detection panzerbackup' 'Source directory (SRC_DIR) - Enter for panzerbackup auto-detection') [auto]: " src_in || src_in=""
  src_in="$(expand_path "$src_in")"
  if [[ -z "$src_in" || "$src_in" == "auto" || "$src_in" == "AUTO" ]]; then
    SRC_DIR=""
  else
    SRC_DIR="$src_in"
  fi

  read_line "$(say 'Preferred SSH key hint (optional, e.g. newvorta)' 'Preferred SSH key hint (optional, e.g. newvorta)')" PREFERRED_KEY_HINT "${PREFERRED_KEY_HINT:-}"

  local key_in=""
  read -r -p "$(say 'SSH_KEY Pfad (leer lassen für Auto-Detection)' 'SSH_KEY path (leave empty for auto-detection)') [auto]: " key_in || key_in=""
  key_in="$(expand_path "$key_in")"
  if [[ -z "$key_in" || "$key_in" == "auto" || "$key_in" == "AUTO" ]]; then
    SSH_KEY=""
  else
    SSH_KEY="$key_in"
  fi

  read_line "$(say 'SSH known_hosts Pfad' 'SSH known_hosts path')" SSH_KNOWN_HOSTS "$SSH_KNOWN_HOSTS"
  SSH_KNOWN_HOSTS="$(expand_path "$SSH_KNOWN_HOSTS")"

  read_line "$(say 'Pfad zur Repo-Passphrase-Datei (empfohlen)' 'Repo passphrase file path (recommended)')" PASSPHRASE_FILE "$PASSPHRASE_FILE"
  PASSPHRASE_FILE="$(expand_path "$PASSPHRASE_FILE")"
  if [[ "$PASSPHRASE_FILE" != /* ]]; then
    echo -e "${Y}$(say 'Hinweis: PASSFILE muss ein absoluter Pfad sein. Setze Default.' 'Note: PASSFILE must be an absolute path. Using default.')${NC}"
    PASSPHRASE_FILE="$DEFAULT_PASSPHRASE_FILE"
  fi
  mkdir -p "$(dirname -- "$PASSPHRASE_FILE")" 2>/dev/null || true

  read_line "$(say 'Pfad zur SSH-Key-Passphrase-Datei (optional)' 'SSH key passphrase file path (optional)')" SSH_KEY_PASSPHRASE_FILE "$SSH_KEY_PASSPHRASE_FILE"
  SSH_KEY_PASSPHRASE_FILE="$(expand_path "$SSH_KEY_PASSPHRASE_FILE")"
  if [[ "$SSH_KEY_PASSPHRASE_FILE" != /* ]]; then
    echo -e "${Y}$(say 'Hinweis: SSHKEY_PASSFILE muss ein absoluter Pfad sein. Setze Default.' 'Note: SSHKEY_PASSFILE must be an absolute path. Using default.')${NC}"
    SSH_KEY_PASSPHRASE_FILE="$DEFAULT_SSHKEY_PASSPHRASE_FILE"
  fi
  mkdir -p "$(dirname -- "$SSH_KEY_PASSPHRASE_FILE")" 2>/dev/null || true

  ensure_logfile_writable

  if [[ -z "${SRC_DIR:-}" ]]; then
    detect_src_dir || true
  fi

  if [[ -z "${SSH_KEY:-}" ]]; then
    resolve_ssh_key || true
  fi

  write_env_file
  load_env || true

  if [[ ! -f "$PASSPHRASE_FILE" || ! -s "$PASSPHRASE_FILE" ]]; then
    echo -e "${Y}$(say 'Repo-Passphrase eingeben (wird in Datei gespeichert).' 'Enter repo passphrase (will be stored in file).')${NC}"
    prompt_repo_passphrase_loop
  fi

  while true; do
    echo ""
    echo "$(say 'Teste Verbindung zum Repo...' 'Testing repository connection...')"
    if test_connection; then
      break
    else
      rc=$?
      if (( rc == 2 )); then
        echo -e "${Y}$(say 'Repo ist gesperrt (Lock). Das ist ok, wenn gerade ein Job läuft.' 'Repo is locked. This is ok if a job is currently running.')${NC}"
        break
      fi
    fi

    echo -e "${R}$(say 'Verbindung fehlgeschlagen.' 'Connection failed.')${NC}"

    local ans=""
    read -r -p "$(say 'REPO/SSH_KEY ändern? (y/n) ' 'Change REPO/SSH_KEY? (y/n) ')" ans || ans="n"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      configure_wizard
      return $?
    fi

    prompt_repo_passphrase_loop
    write_env_file
  done

  echo -e "${G}$(say 'Konfiguration gespeichert.' 'Configuration saved.')${NC}"
  return 0
}

ensure_config_exists() {
  if [[ ! -r "$ENV_FILE" ]]; then
    configure_wizard || return 1
  else
    load_env || true
  fi
}

# -------------------- Live progress (readable) --------------------
follow_log_live() {
  ensure_logfile_writable
  [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE" 2>/dev/null || true

  echo ""
  echo "$(say 'Live-Progress: Log wird verfolgt (bereinigt). Beenden mit Ctrl+C.' 'Live progress: following log (cleaned). Exit with Ctrl+C.')"
  echo "$(say "LOG_FILE: $LOG_FILE" "LOG_FILE: $LOG_FILE")"
  echo ""

  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL tail -n 200 -f "$LOG_FILE" \
      | sed -u 's/\r/\n/g' \
      | awk 'NF{ if($0!=prev){print; prev=$0} }'
  else
    tail -n 200 -f "$LOG_FILE" \
      | sed -u 's/\r/\n/g' \
      | awk 'NF{ if($0!=prev){print; prev=$0} }'
  fi
}

# -------------------- Workers --------------------
create_worker_file() {
  local name="$1"
  local f
  f="$(mktemp "${RUNTIME_DIR}/${name}.XXXXXX")"
  chmod 700 "$f" 2>/dev/null || true
  echo "$f"
}

do_upload_background() {
  set_job_status "UPLOAD: Start..."
  date +%s > "$START_FILE" 2>/dev/null || true

  local worker
  worker="$(create_worker_file "borg-upload-worker.sh")"

  cat > "$worker" <<'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; echo "Worker ERROR at line $LINENO: $BASH_COMMAND (rc=$rc)" >> "$LOG_FILE"; set_job_status "ERROR: Upload failed (see log)"; rm -f "$PID_FILE" "$START_FILE"; exit $rc' ERR
export LC_ALL=C

set_job_status() { echo "$1" > "$JOB_STATUS_FILE"; }

if [[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]]; then
  export BORG_PASSPHRASE
  BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"
fi
: "${BORG_PASSPHRASE:?Missing BORG_PASSPHRASE (set PASSPHRASE_FILE or env)}"

START_TIME=$(date +%s)

{
  exec >> "$LOG_FILE" 2>&1
  echo "=========================================="
  echo "Worker Start (Upload): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo "ENV: HOME=${HOME:-<unset>} USER=${USER:-<unset>} LOGNAME=${LOGNAME:-<unset>}"
  echo "ENV: SSH_KEY=${SSH_KEY:-<unset>}"
  echo "ENV: SSH_KNOWN_HOSTS=${SSH_KNOWN_HOSTS:-<unset>}"
  echo "ENV: BORG_RSH=${BORG_RSH:-<unset>}"
  echo "------------------------------------------"

  set_job_status "UPLOAD: Suche letztes Backup..."

  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  if [[ -z "${latest_img}" ]]; then
    set_job_status "ERROR: No backup found in source directory"
    rm -f "$PID_FILE" "$START_FILE"
    exit 1
  fi

  base="${latest_img%.img.zst.gpg}"
  img="${base}.img.zst.gpg"
  sha="${base}.img.zst.gpg.sha256"
  sfd="${base}.sfdisk"

  for f in "$img" "$sha" "$sfd"; do
    [[ -f "$f" ]] || { set_job_status "ERROR: Missing file: $(basename "$f")"; rm -f "$PID_FILE" "$START_FILE"; exit 1; }
  done

  HOST="$(hostname -s)"
  NOW="$(date +%Y-%m-%d_%H-%M)"
  ARCHIVE="Backup-${HOST}-${NOW}"

  set_job_status "UPLOAD: Erstelle Archiv ${ARCHIVE}..."
  INCLUDE_LIST="$(mktemp)"
  trap 'rm -f "$INCLUDE_LIST"' EXIT

  {
    echo "$img"
    echo "$sha"
    echo "$sfd"
    [[ -f "${SRC_DIR}/LATEST_OK" ]] && echo "${SRC_DIR}/LATEST_OK"
    [[ -f "${SRC_DIR}/LATEST_OK.sha256" ]] && echo "${SRC_DIR}/LATEST_OK.sha256"
    [[ -f "${SRC_DIR}/LATEST_OK.sfdisk" ]] && echo "${SRC_DIR}/LATEST_OK.sfdisk"
    [[ -f "${SRC_DIR}/panzerbackup.log" ]] && echo "${SRC_DIR}/panzerbackup.log"
  } > "$INCLUDE_LIST"

  set_job_status "UPLOAD: Upload läuft (Details via Menü 9 / Log)..."
  borg create --lock-wait "${BORG_LOCK_WAIT:-5}" --stats --progress --compression lz4 \
    "${REPO}::${ARCHIVE}" --paths-from-stdin < "$INCLUDE_LIST"

  if [[ "${PRUNE}" == "yes" ]]; then
    set_job_status "UPLOAD: Prune/Retention läuft..."
    borg prune -v --list --lock-wait "${BORG_LOCK_WAIT:-5}" "${REPO}" \
      --glob-archives "Backup-${HOST}-*" --keep-last="${KEEP_LAST}" || true

    set_job_status "UPLOAD: Compact läuft..."
    borg compact --lock-wait "${BORG_LOCK_WAIT:-5}" "${REPO}" || true
  fi

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FMT="$(printf '%02dm:%02ds\n' $((DURATION%3600/60)) $((DURATION%60)))"

  # Clear, unambiguous final status:
  set_job_status "UPLOAD: Abgeschlossen - ${ARCHIVE} (Dauer: ${DURATION_FMT})"

  rm -f "$PID_FILE" "$START_FILE"
}
EOFWORKER

  chmod +x "$worker"

  env -i \
    PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$USER" \
    LC_ALL=C UI_LANG="${UI_LANG:-de}" \
    SRC_DIR="$SRC_DIR" REPO="$REPO" \
    SSH_KEY="${SSH_KEY:-}" SSH_KNOWN_HOSTS="$SSH_KNOWN_HOSTS" SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
    PASSPHRASE_FILE="$PASSPHRASE_FILE" \
    LOG_FILE="$LOG_FILE" JOB_STATUS_FILE="$JOB_STATUS_FILE" PID_FILE="$PID_FILE" START_FILE="$START_FILE" \
    PRUNE="$PRUNE" KEEP_LAST="$KEEP_LAST" \
    BORG_LOCK_WAIT="$BORG_LOCK_WAIT" \
    BORG_RSH="$BORG_RSH" \
    nohup setsid "$worker" &>/dev/null &

  echo $! > "$PID_FILE"
}

do_download_background() {
  local selected_archive="$1"
  set_job_status "DOWNLOAD: Start..."
  date +%s > "$START_FILE" 2>/dev/null || true

  local worker
  worker="$(create_worker_file "borg-download-worker.sh")"

  cat > "$worker" <<'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; echo "Worker ERROR at line $LINENO: $BASH_COMMAND (rc=$rc)" >> "$LOG_FILE"; set_job_status "ERROR: Download failed (see log)"; rm -f "$PID_FILE" "$START_FILE"; exit $rc' ERR
export LC_ALL=C

set_job_status() { echo "$1" > "$JOB_STATUS_FILE"; }

if [[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]]; then
  export BORG_PASSPHRASE
  BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"
fi
: "${BORG_PASSPHRASE:?Missing BORG_PASSPHRASE (set PASSPHRASE_FILE or env)}"

START_TIME=$(date +%s)

{
  exec >> "$LOG_FILE" 2>&1
  echo "=========================================="
  echo "Worker Start (Download): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  set_job_status "DOWNLOAD: Extrahiere ${SELECTED_ARCHIVE}..."

  [[ -d "$SRC_DIR" ]] || { set_job_status "ERROR: Target directory not found"; rm -f "$PID_FILE" "$START_FILE"; exit 1; }
  [[ -w "$SRC_DIR" ]] || { set_job_status "ERROR: Target directory not writable"; rm -f "$PID_FILE" "$START_FILE"; exit 1; }

  cd "$SRC_DIR"
  borg extract --lock-wait "${BORG_LOCK_WAIT:-5}" --progress "${REPO}::${SELECTED_ARCHIVE}"

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FMT="$(printf '%02dm:%02ds\n' $((DURATION%3600/60)) $((DURATION%60)))"

  set_job_status "DOWNLOAD: Abgeschlossen - ${SELECTED_ARCHIVE} (Dauer: ${DURATION_FMT})"
  rm -f "$PID_FILE" "$START_FILE"
}
EOFWORKER

  chmod +x "$worker"

  env -i \
    PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$USER" \
    LC_ALL=C UI_LANG="${UI_LANG:-de}" \
    SELECTED_ARCHIVE="$selected_archive" SRC_DIR="$SRC_DIR" REPO="$REPO" \
    SSH_KEY="${SSH_KEY:-}" SSH_KNOWN_HOSTS="$SSH_KNOWN_HOSTS" SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
    PASSPHRASE_FILE="$PASSPHRASE_FILE" \
    LOG_FILE="$LOG_FILE" JOB_STATUS_FILE="$JOB_STATUS_FILE" PID_FILE="$PID_FILE" START_FILE="$START_FILE" \
    BORG_LOCK_WAIT="$BORG_LOCK_WAIT" \
    BORG_RSH="$BORG_RSH" \
    nohup setsid "$worker" &>/dev/null &

  echo $! > "$PID_FILE"
}

# -------------------- Repo actions --------------------
list_archives() {
  say "Verfügbare Archive im Repository:" "Available archives in repository:"
  echo ""
  borg list --lock-wait 1 "${REPO}" | nl -w2 -s') ' || {
    say "${Y}Hinweis: Zugriff fehlgeschlagen oder Repo gesperrt.${NC}" "${Y}Note: access failed or repo locked.${NC}"
  }
  echo ""
}

select_archive() {
  local archives=()
  mapfile -t archives < <(borg list --short "${REPO}" 2>/dev/null || true)
  (( ${#archives[@]} )) || { say "Keine Archive gefunden." "No archives found."; return 1; }
  for i in "${!archives[@]}"; do printf "  %2d) %s\n" $((i+1)) "${archives[$i]}"; done
  echo ""
  local choice
  read -r -p "$(say "Archive-Nummer (1-${#archives[@]}): " "Archive number (1-${#archives[@]}): ")" choice || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#archives[@]} )) || { say "Ungültige Auswahl" "Invalid selection"; return 1; }
  echo "${archives[$((choice-1))]}"
}

# -------------------- Settings menu --------------------
show_settings_menu() {
  clear
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  [[ "${UI_LANG:-de}" == "en" ]] \
    && echo "║                  Settings / Configuration                  ║" \
    || echo "║                Einstellungen / Konfiguration               ║"
  echo "╠════════════════════════════════════════════════════════════╣"

  local pass_exists="no"
  [[ -f "$PASSPHRASE_FILE" && -s "$PASSPHRASE_FILE" ]] && pass_exists="yes"

  local sshkey_exists="no"
  [[ -n "${SSH_KEY:-}" && -r "${SSH_KEY}" ]] && sshkey_exists="yes"

  printf "║  ENV_FILE: %-46s ║\n" "${ENV_FILE:0:46}"
  printf "║  SRC_DIR: %-47s ║\n" "${SRC_DIR:0:47}"
  printf "║  REPO: %-50s ║\n" "${REPO:0:50}"
  printf "║  SSH_KEY: %-47s ║\n" "${SSH_KEY:0:47}"
  printf "║  SSH_KEY_EXISTS: %-39s ║\n" "${sshkey_exists:0:39}"
  printf "║  KEY_HINT: %-46s ║\n" "${PREFERRED_KEY_HINT:0:46}"
  printf "║  KNOWN_HOSTS: %-41s ║\n" "${SSH_KNOWN_HOSTS:0:41}"
  printf "║  PASSFILE: %-44s ║\n" "${PASSPHRASE_FILE:0:44}"
  printf "║  PASSFILE_EXISTS: %-39s ║\n" "${pass_exists:0:39}"
  printf "║  SSHKEY_PASSFILE: %-37s ║\n" "${SSH_KEY_PASSPHRASE_FILE:0:37}"
  printf "║  LOG_FILE: %-46s ║\n" "${LOG_FILE:0:46}"
  printf "║  JOB_STATUS_FILE: %-37s ║\n" "${JOB_STATUS_FILE:0:37}"
  printf "║  CONN_STATUS_FILE: %-36s ║\n" "${CONN_STATUS_FILE:0:36}"
  printf "║  PID_FILE: %-44s ║\n" "${PID_FILE:0:44}"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "$(say 'Tipp: Konfiguration ändern über Menüpunkt 8 (Wizard).' 'Tip: Change configuration via menu option 8 (Wizard).')"
  echo ""
  pause_tty "$(say 'Weiter mit Enter...' 'Press Enter...')"
}

# -------------------- Main menu --------------------
show_menu() {
  while true; do
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && echo "║          BorgBase Backup Manager - Main Menu               ║" \
      || echo "║          BorgBase Backup Manager - Hauptmenü               ║"
    echo "╠════════════════════════════════════════════════════════════╣"

    if [[ "${UI_LANG:-de}" == "en" ]]; then
      echo "║  1) Upload backup to BorgBase                              ║"
      echo "║  2) Download backup from BorgBase                          ║"
      echo "║  3) List all archives                                      ║"
      echo "║  4) Test repo connection                                   ║"
      echo "║  5) View log file                                          ║"
      echo "║  6) Show settings                                          ║"
      echo "║  7) Clear status                                           ║"
      echo "║  8) Reconfigure (Wizard)                                   ║"
      echo "║  9) Live progress (follow log)                             ║"
      echo "║  q) Quit                                                   ║"
    else
      echo "║  1) Backup zu BorgBase hochladen                           ║"
      echo "║  2) Backup von BorgBase herunterladen                      ║"
      echo "║  3) Alle Archive auflisten                                 ║"
      echo "║  4) Verbindung zum Repo testen                             ║"
      echo "║  5) Log-Datei anzeigen                                     ║"
      echo "║  6) Einstellungen anzeigen                                 ║"
      echo "║  7) Status löschen                                         ║"
      echo "║  8) Konfiguration neu (Wizard)                             ║"
      echo "║  9) Live Progress (Log folgen)                             ║"
      echo "║  q) Beenden                                                ║"
    fi

    echo "╠════════════════════════════════════════════════════════════╣"

    # JOB line
    local job_line; job_line="$(get_job_status_formatted)"
    local job_padded; job_padded="$(pad_to_width "$STATUS_FIELD_WIDTH" "$job_line")"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && printf "║  Job:    %s ║\n" "$job_padded" \
      || printf "║  Job:    %s ║\n" "$job_padded"

    # CONN line
    local conn_line; conn_line="$(get_conn_status_formatted)"
    local conn_padded; conn_padded="$(pad_to_width "$STATUS_FIELD_WIDTH" "$conn_line")"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && printf "║  Repo:   %s ║\n" "$conn_padded" \
      || printf "║  Repo:   %s ║\n" "$conn_padded"

    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    local choice=""
    if ! read -r -p "$(say 'Ihre Wahl: ' 'Your choice: ')" choice; then
      echo ""
      break
    fi

    case "$choice" in
      1)
        ensure_config_exists || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        detect_src_dir || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        show_upload_selection || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }

        if test_connection; then
          :
        else
          rc=$?
          if (( rc == 2 )); then
            echo -e "${Y}$(say 'Repo ist gesperrt (Lock). Upload kann trotzdem versucht werden (wartet auf Lock).' 'Repo is locked. You may still try upload (will wait for lock).')${NC}"
          else
            echo -e "${R}$(say 'Upload ist gesperrt, solange SSH/Repo nicht erreichbar ist.' 'Upload is blocked until SSH/repo is reachable.')${NC}"
            pause_tty "$(say 'Weiter...' 'Continue...')"
            continue
          fi
        fi

        if is_running; then
          echo -e "${Y}$(say 'Ein Job läuft bereits.' 'A job is already running.')${NC}"
          pause_tty "$(say 'Weiter...' 'Continue...')"
          continue
        fi

        pause_tty "$(say 'Enter = Upload starten (CTRL+C zum Abbrechen) ' 'Press Enter to start upload (CTRL+C to abort) ')"
        do_upload_background
        echo -e "${G}$(say 'Upload im Hintergrund gestartet.' 'Upload started in background.')${NC}"
        echo -e "${Y}$(say 'Tipp: Menüpunkt 9 = Live Progress (Log folgen).' 'Tip: menu 9 = Live progress (follow log).')${NC}"
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      2)
        ensure_config_exists || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        detect_src_dir || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }

        if test_connection; then
          :
        else
          rc=$?
          if (( rc == 2 )); then
            echo -e "${Y}$(say 'Repo ist gesperrt (Lock). Download kann trotzdem versucht werden (wartet auf Lock).' 'Repo is locked. You may still try download (will wait for lock).')${NC}"
          else
            echo -e "${R}$(say 'Download ist gesperrt, solange SSH/Repo nicht erreichbar ist.' 'Download is blocked until SSH/repo is reachable.')${NC}"
            pause_tty "$(say 'Weiter...' 'Continue...')"
            continue
          fi
        fi

        if is_running; then
          echo -e "${Y}$(say 'Ein Job läuft bereits.' 'A job is already running.')${NC}"
          pause_tty "$(say 'Weiter...' 'Continue...')"
          continue
        fi

        local archive=""
        archive="$(select_archive)" || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        do_download_background "$archive"
        echo -e "${G}$(say 'Download im Hintergrund gestartet.' 'Download started in background.')${NC}"
        echo -e "${Y}$(say 'Tipp: Menüpunkt 9 = Live Progress (Log folgen).' 'Tip: menu 9 = Live progress (follow log).')${NC}"
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      3)
        ensure_config_exists || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        if test_connection; then
          :
        else
          rc=$?
          if (( rc != 2 )); then
            pause_tty "$(say 'Weiter...' 'Continue...')"
            continue
          fi
        fi
        list_archives
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      4)
        ensure_config_exists || { pause_tty "$(say 'Weiter...' 'Continue...')"; continue; }
        if test_connection; then
          :
        else
          rc=$?
          if (( rc == 2 )); then
            echo -e "${Y}$(say 'Repo ist gesperrt (Lock). Verbindung/SSH ist OK.' 'Repo is locked. Connectivity/SSH is OK.')${NC}"
          else
            echo -e "${R}$(say 'Verbindungstest fehlgeschlagen. Details im Log (Menüpunkt 5).' 'Connection test failed. See log (menu 5).')${NC}"
          fi
        fi
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      5)
        ensure_logfile_writable
        if [[ -f "$LOG_FILE" ]]; then
          less "$LOG_FILE"
        else
          echo -e "${Y}$(say 'Log-Datei existiert noch nicht.' 'Log file does not exist yet.')${NC}"
          pause_tty "$(say 'Weiter...' 'Continue...')"
        fi
        ;;

      6)
        ensure_config_exists || true
        show_settings_menu
        ;;

      7)
        clear_status
        echo -e "${G}$(say 'Status gelöscht.' 'Status cleared.')${NC}"
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      8)
        load_env || true
        configure_wizard
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;

      9)
        follow_log_live
        ;;

      q|Q)
        exit 0
        ;;

      *)
        echo -e "${R}$(say 'Ungültige Auswahl.' 'Invalid choice.')${NC}"
        pause_tty "$(say 'Weiter...' 'Continue...')"
        ;;
    esac
  done
}

# -------------------- CLI entrypoints --------------------
cmd="${1:-}"

if [[ -z "$cmd" ]]; then
  load_env || true
  startup_language_selector_force || true
  startup_repo_check || true
  show_menu
  exit 0
fi

load_env || true

case "$cmd" in
  config)
    startup_language_selector_force || true
    configure_wizard
    ;;
  test)
    startup_language_selector_force || true
    ensure_config_exists
    if test_connection; then :; else :; fi
    ;;
  upload)
    startup_language_selector_force || true
    ensure_config_exists
    detect_src_dir
    show_upload_selection
    if test_connection; then :; else :; fi
    is_running && { echo "Already running."; exit 1; }
    do_upload_background
    ;;
  download)
    startup_language_selector_force || true
    ensure_config_exists
    detect_src_dir
    if test_connection; then :; else :; fi
    is_running && { echo "Already running."; exit 1; }
    archive="$(select_archive)"
    do_download_background "$archive"
    ;;
  list)
    startup_language_selector_force || true
    ensure_config_exists
    if test_connection; then :; else :; fi
    list_archives
    ;;
  status)
    echo "$(get_job_status)"
    echo "$(get_conn_status)"
    ;;
  menu)
    startup_language_selector_force || true
    startup_repo_check || true
    show_menu
    ;;
  *)
    echo "Usage: $0 {menu|config|test|upload|download|list|status}"
    exit 1
    ;;
esac
