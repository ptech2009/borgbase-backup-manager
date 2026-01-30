#!/usr/bin/env bash
# BorgBase Backup Manager
#
# Features / Fixes:
# - SECURITY FIX: Uses BORG_PASSCOMMAND instead of BORG_PASSPHRASE to prevent environment leak
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

_repo_path() {
  local r="$1"
  r="${r#ssh://}"
  r="${r#*@}"
  r="${r#*/}"
  echo "/$r"
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
    echo "-p $p"
  else
    echo ""
  fi
}

# -------------------- Passphrase handling (SECURE) --------------------
# SECURITY: Use BORG_PASSCOMMAND instead of BORG_PASSPHRASE to avoid env leak
load_repo_passphrase() {
  if [[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]]; then
    # SECURITY FIX: Set BORG_PASSCOMMAND instead of BORG_PASSPHRASE
    # This prevents the passphrase from being visible in process environment
    unset BORG_PASSPHRASE
    export BORG_PASSCOMMAND="cat $(printf '%q' "$PASSPHRASE_FILE")"
    return 0
  fi
  if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
    # Fallback: if BORG_PASSPHRASE is already set (legacy), keep it
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

# -------------------- SSH Key detection --------------------
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

detect_src_dir() {
  if [[ -n "$SRC_DIR" ]]; then
    SRC_DIR="$(expand_path "$SRC_DIR")"
    [[ -d "$SRC_DIR" ]] || { echo -e "${R}$(say "SRC_DIR existiert nicht: $SRC_DIR" "SRC_DIR does not exist: $SRC_DIR")${NC}"; return 1; }
    return 0
  fi
  
  local possible=(
    "$HOME/panzerbackup"
    "/home/$(logname 2>/dev/null || echo "$USER")/panzerbackup"
  )
  
  for d in "${possible[@]}"; do
    if [[ -d "$d" ]]; then
      SRC_DIR="$d"
      return 0
    fi
  done
  
  echo -e "${R}$(say 'Kein panzerbackup-Verzeichnis gefunden. Bitte SRC_DIR setzen.' 'No panzerbackup directory found. Please set SRC_DIR.')${NC}"
  return 1
}

# -------------------- Borg version compatibility --------------------
BORG_VERSION_CACHE=""

detect_borg_version() {
  if [[ -n "$BORG_VERSION_CACHE" ]]; then
    echo "$BORG_VERSION_CACHE"
    return 0
  fi
  
  local version_output
  version_output="$(borg --version 2>&1 || true)"
  
  if [[ "$version_output" =~ borg[[:space:]]([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    BORG_VERSION_CACHE="$major"
    echo "$major"
    return 0
  fi
  
  # Default to 1 if detection fails
  BORG_VERSION_CACHE="1"
  echo "1"
}

# Borg 1.x uses 'list', Borg 2.x uses 'rlist'
borg_list_cmd() {
  local version
  version="$(detect_borg_version)"
  if [[ "$version" == "2" ]]; then
    echo "rlist"
  else
    echo "list"
  fi
}

# -------------------- Borg wrappers --------------------
borg_with_ssh() {
  setup_borg_env || return 1
  borg "$@"
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
    set_conn_status "$(say 'FEHLER: SSH Hostkey Problem (known_hosts).' 'ERROR: SSH hostkey problem (known_hosts).')"
    return 1
  fi
  if echo "$out" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    set_conn_status "$(say 'FEHLER: SSH Auth fehlgeschlagen (publickey).' 'ERROR: SSH auth failed (publickey).')"
    return 1
  fi
  if echo "$out" | grep -qiE 'enter passphrase for key|incorrect passphrase|bad passphrase'; then
    set_conn_status "$(say 'FEHLER: SSH-Key Passphrase benötigt/falsch.' 'ERROR: SSH key passphrase required/incorrect.')"
    return 1
  fi

  echo "$out" | grep -qiE '^borg ' || {
    set_conn_status "$(say 'FEHLER: SSH Test fehlgeschlagen.' 'ERROR: SSH test failed.')"
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
      set_conn_status "$(say 'OK: Repo erreichbar (BUSY/Lock durch laufenden Job).' 'OK: Repo reachable (BUSY/Lock by running job).')"
      return 0
    fi
    set_conn_status "$(say 'WARNUNG: Repo gesperrt (Lock-Timeout) – später erneut versuchen.' 'WARNING: Repo locked (lock timeout) – try again later.')"
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
    set_conn_status "$(say 'OK: Verbindung erfolgreich hergestellt.' 'OK: Connection established successfully.')"
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
    set_conn_status "$(say 'FEHLER: Repo-Verbindung fehlgeschlagen.' 'ERROR: Repo connection failed.')"
    return 1
  fi
}

# -------------------- Upload/Download logic --------------------
show_upload_selection() {
  echo ""
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo -e "${B}$(say 'Backup hochladen (Upload)' 'Upload Backup')${NC}"
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo ""
  echo "$(say "Quellverzeichnis: $SRC_DIR" "Source directory: $SRC_DIR")"
  echo "$(say "Ziel-Repo:        $REPO" "Target repo:      $REPO")"
  echo ""
  
  if [[ ! -d "$SRC_DIR" ]]; then
    echo -e "${R}$(say 'FEHLER: Quellverzeichnis existiert nicht!' 'ERROR: Source directory does not exist!')${NC}"
    return 1
  fi
  
  local size; size="$(du -sb "$SRC_DIR" 2>/dev/null | awk '{print $1}')"
  echo "$(say "Größe:            $(human_bytes "$size")" "Size:             $(human_bytes "$size")")"
  echo ""
}

do_upload_background() {
  ensure_logfile_writable
  
  (
    echo "$$" > "$PID_FILE"
    date +%s > "$START_FILE"
    
    set_job_status "$(say 'UPLOAD: Wird vorbereitet...' 'UPLOAD: Preparing...')"
    
    {
      echo ""
      echo "==================================================="
      echo "$(say 'UPLOAD GESTARTET' 'UPLOAD STARTED'): $(date)"
      echo "==================================================="
      echo ""
    } | tee -a "$LOG_FILE"
    
    # Setup Borg environment (includes SECURITY FIX: BORG_PASSCOMMAND)
    if ! setup_borg_env; then
      set_job_status "$(say 'UPLOAD: FEHLER – Borg-Setup fehlgeschlagen' 'UPLOAD: ERROR – Borg setup failed')"
      rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
      exit 1
    fi
    
    local archive_name="backup-$(date +%Y%m%d-%H%M%S)"
    
    set_job_status "$(say "UPLOAD: $archive_name läuft..." "UPLOAD: $archive_name running...")"
    
    echo "$(say "Erstelle Archiv: $archive_name" "Creating archive: $archive_name")" | tee -a "$LOG_FILE"
    
    if borg create --stats --progress --compression lz4 \
         "${REPO}::${archive_name}" "$SRC_DIR" 2>&1 | \
         awk '{gsub(/\r/,"\n"); print}' | \
         awk '!seen[$0]++' | \
         tee -a "$LOG_FILE"; then
      
      echo "" | tee -a "$LOG_FILE"
      echo "$(say '✓ Archiv erfolgreich erstellt.' '✓ Archive created successfully.')" | tee -a "$LOG_FILE"
      
      if [[ "${PRUNE:-yes}" == "yes" ]]; then
        set_job_status "$(say 'UPLOAD: Prune läuft...' 'UPLOAD: Pruning...')"
        echo "$(say 'Räume alte Archive auf (prune)...' 'Pruning old archives...')" | tee -a "$LOG_FILE"
        
        if borg prune --list --keep-last="${KEEP_LAST:-1}" "$REPO" 2>&1 | tee -a "$LOG_FILE"; then
          echo "$(say '✓ Prune erfolgreich.' '✓ Prune successful.')" | tee -a "$LOG_FILE"
        else
          echo -e "${Y}$(say 'WARNUNG: Prune fehlgeschlagen (nicht kritisch).' 'WARNING: Prune failed (not critical).')${NC}" | tee -a "$LOG_FILE"
        fi
        
        set_job_status "$(say 'UPLOAD: Compact läuft...' 'UPLOAD: Compacting...')"
        echo "$(say 'Kompaktiere Repo...' 'Compacting repo...')" | tee -a "$LOG_FILE"
        
        if borg compact "$REPO" 2>&1 | tee -a "$LOG_FILE"; then
          echo "$(say '✓ Compact erfolgreich.' '✓ Compact successful.')" | tee -a "$LOG_FILE"
        else
          echo -e "${Y}$(say 'WARNUNG: Compact fehlgeschlagen (nicht kritisch).' 'WARNING: Compact failed (not critical).')${NC}" | tee -a "$LOG_FILE"
        fi
      fi
      
      {
        echo ""
        echo "==================================================="
        echo "$(say 'UPLOAD ABGESCHLOSSEN' 'UPLOAD FINISHED'): $(date)"
        echo "==================================================="
        echo ""
      } | tee -a "$LOG_FILE"
      
      set_job_status "$(say 'UPLOAD: Abgeschlossen (Archiv: '"$archive_name"')' 'UPLOAD: Finished (archive: '"$archive_name"')')"
    else
      {
        echo ""
        echo "==================================================="
        echo "$(say 'UPLOAD FEHLGESCHLAGEN' 'UPLOAD FAILED'): $(date)"
        echo "==================================================="
        echo ""
      } | tee -a "$LOG_FILE"
      
      set_job_status "$(say 'UPLOAD: FEHLER – siehe Log' 'UPLOAD: ERROR – see log')"
    fi
    
    rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
  ) &
  
  disown
}

select_archive() {
  echo "$(say 'Lade Archive...' 'Loading archives...')"
  
  local list_cmd
  list_cmd="$(borg_list_cmd)"
  
  local archives=()
  mapfile -t archives < <(borg_with_ssh "$list_cmd" --short "$REPO" 2>/dev/null | sort -r)
  
  if (( ${#archives[@]} == 0 )); then
    echo -e "${R}$(say 'Keine Archive im Repo gefunden.' 'No archives found in repo.')${NC}"
    return 1
  fi
  
  echo ""
  echo "$(say 'Verfügbare Archive:' 'Available archives:')"
  local i=1
  for a in "${archives[@]}"; do
    echo "  $i) $a"
    ((i++))
  done
  echo ""
  
  local choice=""
  read -r -p "$(say 'Wähle Archiv (Nummer): ' 'Select archive (number): ')" choice
  
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#archives[@]} )); then
    echo -e "${R}$(say 'Ungültige Auswahl.' 'Invalid selection.')${NC}"
    return 1
  fi
  
  echo "${archives[$((choice-1))]}"
}

do_download_background() {
  local archive="${1:-}"
  [[ -z "$archive" ]] && { echo "No archive specified."; return 1; }
  
  ensure_logfile_writable
  
  (
    echo "$$" > "$PID_FILE"
    date +%s > "$START_FILE"
    
    set_job_status "$(say 'DOWNLOAD: Wird vorbereitet...' 'DOWNLOAD: Preparing...')"
    
    {
      echo ""
      echo "==================================================="
      echo "$(say 'DOWNLOAD GESTARTET' 'DOWNLOAD STARTED'): $(date)"
      echo "$(say "Archiv: $archive" "Archive: $archive")"
      echo "==================================================="
      echo ""
    } | tee -a "$LOG_FILE"
    
    # Setup Borg environment (includes SECURITY FIX: BORG_PASSCOMMAND)
    if ! setup_borg_env; then
      set_job_status "$(say 'DOWNLOAD: FEHLER – Borg-Setup fehlgeschlagen' 'DOWNLOAD: ERROR – Borg setup failed')"
      rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
      exit 1
    fi
    
    set_job_status "$(say "DOWNLOAD: $archive läuft..." "DOWNLOAD: $archive running...")"
    
    echo "$(say "Extrahiere Archiv: $archive" "Extracting archive: $archive")" | tee -a "$LOG_FILE"
    echo "$(say "Ziel: $SRC_DIR" "Target: $SRC_DIR")" | tee -a "$LOG_FILE"
    
    if borg extract --progress "${REPO}::${archive}" 2>&1 | \
         awk '{gsub(/\r/,"\n"); print}' | \
         awk '!seen[$0]++' | \
         tee -a "$LOG_FILE"; then
      
      {
        echo ""
        echo "==================================================="
        echo "$(say 'DOWNLOAD ABGESCHLOSSEN' 'DOWNLOAD FINISHED'): $(date)"
        echo "==================================================="
        echo ""
      } | tee -a "$LOG_FILE"
      
      set_job_status "$(say 'DOWNLOAD: Abgeschlossen (Archiv: '"$archive"')' 'DOWNLOAD: Finished (archive: '"$archive"')')"
    else
      {
        echo ""
        echo "==================================================="
        echo "$(say 'DOWNLOAD FEHLGESCHLAGEN' 'DOWNLOAD FAILED'): $(date)"
        echo "==================================================="
        echo ""
      } | tee -a "$LOG_FILE"
      
      set_job_status "$(say 'DOWNLOAD: FEHLER – siehe Log' 'DOWNLOAD: ERROR – see log')"
    fi
    
    rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
  ) &
  
  disown
}

list_archives() {
  echo "$(say 'Lade Archive...' 'Loading archives...')"
  echo ""
  
  local list_cmd
  list_cmd="$(borg_list_cmd)"
  
  if borg_with_ssh "$list_cmd" "$REPO" 2>&1 | tee -a "$LOG_FILE"; then
    echo ""
    echo -e "${G}$(say 'Archive erfolgreich geladen.' 'Archives loaded successfully.')${NC}"
  else
    echo ""
    echo -e "${R}$(say 'Fehler beim Laden der Archive.' 'Error loading archives.')${NC}"
    return 1
  fi
}

# -------------------- Config wizard --------------------
ensure_config_exists() {
  if [[ ! -r "$ENV_FILE" ]]; then
    echo -e "${Y}$(say 'Keine Konfiguration gefunden.' 'No configuration found.')${NC}"
    echo "$(say 'Bitte führe den Konfigurationswizard aus (Menüpunkt 8 oder: config).' 'Please run configuration wizard (menu 8 or: config).')"
    return 1
  fi
  
  if [[ ! -r "$PASSPHRASE_FILE" ]]; then
    echo -e "${Y}$(say 'Repo-Passphrase-Datei fehlt.' 'Repo passphrase file missing.')${NC}"
    echo "$(say 'Bitte führe den Konfigurationswizard aus (Menüpunkt 8 oder: config).' 'Please run configuration wizard (menu 8 or: config).')"
    return 1
  fi
  
  return 0
}

configure_wizard() {
  echo ""
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo -e "${B}$(say 'Konfigurationswizard' 'Configuration Wizard')${NC}"
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo ""
  
  local new_repo="${REPO}"
  read -r -p "$(say "Repo URL [$new_repo]: " "Repo URL [$new_repo]: ")" input
  [[ -n "$input" ]] && new_repo="$input"
  
  local new_src="${SRC_DIR}"
  read -r -p "$(say "Quellverzeichnis [$new_src]: " "Source directory [$new_src]: ")" input
  [[ -n "$input" ]] && new_src="$input"
  
  local detected_key=""
  detected_key="$(detect_ssh_key 2>/dev/null || true)"
  local new_key="${SSH_KEY:-$detected_key}"
  read -r -p "$(say "SSH-Key [$new_key]: " "SSH key [$new_key]: ")" input
  [[ -n "$input" ]] && new_key="$input"
  
  echo ""
  echo "$(say 'Repo-Passphrase (wird sicher gespeichert):' 'Repo passphrase (will be stored securely):')"
  read -r -s -p "  Passphrase: " p1
  echo ""
  read -r -s -p "  $(say 'Wiederhole:' 'Repeat:')" p2
  echo ""
  
  if [[ "$p1" != "$p2" ]]; then
    echo -e "${R}$(say 'Passphrasen stimmen nicht überein!' 'Passphrases do not match!')${NC}"
    return 1
  fi
  
  if [[ -z "$p1" ]]; then
    echo -e "${R}$(say 'Passphrase darf nicht leer sein!' 'Passphrase cannot be empty!')${NC}"
    return 1
  fi
  
  echo ""
  echo "$(say 'Optional: SSH-Key-Passphrase (falls dein SSH-Key geschützt ist):' 'Optional: SSH key passphrase (if your SSH key is protected):')"
  read -r -s -p "  $(say 'SSH-Key-Passphrase (Enter = überspringen): ' 'SSH key passphrase (Enter = skip): ')" ssh_pass
  echo ""
  
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
  
  # SECURITY: Write passphrase directly to file, NEVER export to environment
  umask 077
  echo "$p1" > "$PASSPHRASE_FILE"
  chmod 600 "$PASSPHRASE_FILE" 2>/dev/null || true
  
  if [[ -n "$ssh_pass" ]]; then
    echo "$ssh_pass" > "$SSH_KEY_PASSPHRASE_FILE"
    chmod 600 "$SSH_KEY_PASSPHRASE_FILE" 2>/dev/null || true
  fi
  
  cat > "$ENV_FILE" <<EOF
# BorgBase Backup Manager Config
REPO="$new_repo"
SRC_DIR="$new_src"
SSH_KEY="$new_key"
PASSPHRASE_FILE="$PASSPHRASE_FILE"
SSH_KEY_PASSPHRASE_FILE="$SSH_KEY_PASSPHRASE_FILE"
UI_LANG="${UI_LANG:-de}"
EOF
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  
  echo ""
  echo -e "${G}$(say 'Konfiguration gespeichert.' 'Configuration saved.')${NC}"
  echo ""
  
  load_env || true
  
  if [[ "${AUTO_TEST_SSH:-yes}" == "yes" ]]; then
    echo "$(say 'Teste SSH-Verbindung...' 'Testing SSH connection...')"
    test_connection || true
  fi
}

# -------------------- Settings menu --------------------
show_settings_menu() {
  echo ""
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo -e "${B}$(say 'Einstellungen' 'Settings')${NC}"
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo ""
  echo "REPO:                 $REPO"
  echo "SRC_DIR:              $SRC_DIR"
  echo "SSH_KEY:              $SSH_KEY"
  echo "PASSPHRASE_FILE:      $PASSPHRASE_FILE"
  echo "SSH_KEY_PASSPHRASE_FILE: $SSH_KEY_PASSPHRASE_FILE"
  echo "LOG_FILE:             $LOG_FILE"
  echo "PRUNE:                ${PRUNE:-yes}"
  echo "KEEP_LAST:            ${KEEP_LAST:-1}"
  echo "UI_LANG:              ${UI_LANG:-de}"
  echo ""
  pause_tty "$(say 'Weiter...' 'Continue...')"
}

# -------------------- Live log --------------------
follow_log_live() {
  ensure_logfile_writable
  
  if [[ ! -f "$LOG_FILE" ]]; then
    echo -e "${Y}$(say 'Log-Datei existiert noch nicht.' 'Log file does not exist yet.')${NC}"
    pause_tty "$(say 'Weiter...' 'Continue...')"
    return 0
  fi
  
  echo ""
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo -e "${B}$(say 'Live Progress (Log folgen)' 'Live Progress (Follow Log)')${NC}"
  echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
  echo "$(say 'Drücke CTRL+C zum Beenden' 'Press CTRL+C to exit')"
  echo ""
  
  tail -f "$LOG_FILE"
}

# -------------------- Startup helpers --------------------
startup_language_selector_force() {
  if [[ ! -t 0 ]]; then
    return 0
  fi
  
  local current="${UI_LANG:-de}"
  local default_choice="1"
  [[ "$current" == "en" ]] && default_choice="2"
  
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Language / Sprache"
  echo "════════════════════════════════════════════════════════════"
  echo "  1) Deutsch (de)"
  echo "  2) English (en)"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  
  local choice=""
  read -r -p "Wahl/Choice [$default_choice]: " choice
  [[ -z "$choice" ]] && choice="$default_choice"
  
  case "$choice" in
    1) UI_LANG="de" ;;
    2) UI_LANG="en" ;;
    *) UI_LANG="de" ;;
  esac
  
  export UI_LANG
  
  if [[ -w "$ENV_FILE" ]]; then
    sed -i.bak '/^UI_LANG=/d' "$ENV_FILE" 2>/dev/null || true
    echo "UI_LANG=\"$UI_LANG\"" >> "$ENV_FILE"
  fi
}

startup_repo_check() {
  if [[ "${AUTO_TEST_REPO:-yes}" != "yes" ]]; then
    return 0
  fi
  
  if ! ensure_config_exists 2>/dev/null; then
    return 0
  fi
  
  echo ""
  echo "$(say 'Prüfe Repo-Verbindung im Hintergrund...' 'Checking repo connection in background...')"
  (test_connection >/dev/null 2>&1 &)
}

# -------------------- Menu --------------------
show_menu() {
  while true; do
    clear
    
    echo "════════════════════════════════════════════════════════════"
    if [[ "${UI_LANG:-de}" == "en" ]]; then
      echo "║            BorgBase Backup Manager (Secure)            ║"
    else
      echo "║          BorgBase Backup Manager (Sicher)              ║"
    fi
    echo "════════════════════════════════════════════════════════════"
    echo ""
    
    if [[ "${UI_LANG:-de}" == "en" ]]; then
      echo "║  1) Upload backup to BorgBase                              ║"
      echo "║  2) Download backup from BorgBase                          ║"
      echo "║  3) List all archives                                      ║"
      echo "║  4) Test connection to repo                                ║"
      echo "║  5) Show log file                                          ║"
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
