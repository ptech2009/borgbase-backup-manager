#!/usr/bin/env bash
# BorgBase Backup Manager
#
# Design goals:
# - Shows EXACT upload candidate (filename + mtime + size) BEFORE any network/SSH work
# - Deterministic SSH: if SSH_KEY/SSH_KNOWN_HOSTS are set -> they are enforced (no autodetect)
# - Non-interactive SSH: ssh -T + BatchMode=yes + RequestTTY=no (won’t hang waiting for input)
# - Background workers with correct rc handling (no “rc=0” on failures)
# - User-writable runtime dir for STATUS/PID (no sudo needed)
#
# Config precedence (later overrides earlier):
#   1) /etc/borgbase-manager.env
#   2) ./.env
#   3) process environment
#
# Recommended: set REPO + SSH_KEY + SSH_KNOWN_HOSTS in your env file.
#
# ShellCheck notes:
# shellcheck disable=SC1091

set -euo pipefail
set -E
trap 'rc=$?; printf "FEHLER in Zeile %s beim Kommando: %s (RC=%s)\n" "${LINENO}" "${BASH_COMMAND}" "${rc}" >&2; exit "${rc}"' ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ====== COLORS ======
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; NC=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; NC=""
fi

# ====== LOAD ENV ======
if [[ -r /etc/borgbase-manager.env ]]; then . /etc/borgbase-manager.env; fi
if [[ -r ./.env ]]; then . ./.env; fi

export LC_ALL=C

# ====== DEFAULTS (GitHub-safe) ======
: "${SRC_DIR:=/mnt/panzerbackup-pm}"
: "${REPO:=}"

# Deterministic SSH (set explicitly for predictable behavior)
: "${SSH_KEY:=}"             # e.g. /home/user/.ssh/id_ed25519_borgbase
: "${SSH_KNOWN_HOSTS:=}"     # e.g. /home/user/.ssh/known_hosts

# Optional: Borg repo passphrase file (only if repo encryption is enabled)
: "${PASSPHRASE_FILE:=}"     # e.g. /home/user/.config/borg/passphrase

# Log file (if not writable, auto-fallback to user state)
: "${LOG_FILE:=/var/log/borgbase-manager.log}"

: "${PRUNE:=yes}"
: "${KEEP_LAST:=1}"

: "${SSH_CONNECT_TIMEOUT:=5}"
: "${BORG_LOCK_WAIT:=5}"

# Disable slow / interactive network validation by default
: "${AUTO_ACCEPT_HOSTKEY:=no}"
: "${AUTO_TEST_SSH:=no}"
: "${AUTO_TEST_REPO:=no}"

# ====== EFFECTIVE IDENTITY (sudo-safe) ======
EFFECTIVE_USER="${SUDO_USER:-${USER:-}}"
[[ -n "$EFFECTIVE_USER" ]] || EFFECTIVE_USER="$(id -un 2>/dev/null || echo root)"

EFFECTIVE_HOME="${HOME:-}"
if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  EFFECTIVE_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
fi
: "${EFFECTIVE_HOME:=${HOME:-/root}}"

# Bind SSH_KNOWN_HOSTS to effective home if not set explicitly
if [[ -z "${SSH_KNOWN_HOSTS}" ]]; then
  SSH_KNOWN_HOSTS="${EFFECTIVE_HOME}/.ssh/known_hosts"
fi

# ====== USER-WRITABLE RUNTIME DIR (STATUS/PID) ======
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -d "$RUNTIME_DIR" || ! -w "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="${EFFECTIVE_HOME}/.cache"
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || RUNTIME_DIR="/tmp"
fi

: "${STATUS_FILE:=${RUNTIME_DIR}/borgbase-status}"
: "${PID_FILE:=${RUNTIME_DIR}/borgbase-worker.pid}"

init_runtime() {
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
  : > "$STATUS_FILE" 2>/dev/null || true
  : > "$PID_FILE" 2>/dev/null || true

  if [[ ! -w "$STATUS_FILE" ]]; then
    printf "%sFEHLER: STATUS_FILE nicht schreibbar: %s%s\n" "$R" "$STATUS_FILE" "$NC" >&2
    exit 1
  fi
}

# ====== I18N ======
choose_language() {
  local choice="${UI_LANG:-}"
  if [[ -z "$choice" ]]; then
    printf "Choose language / Sprache wählen:\n  1) English\n  2) Deutsch\n"
    read -r -p "> " choice || choice=""
  fi
  case "$choice" in
    1|en|EN|English|english) UI_LANG="en" ;;
    2|de|DE|Deutsch|deutsch) UI_LANG="de" ;;
    *) UI_LANG="de" ;;
  esac
  export UI_LANG
}

say() {
  local de="$1" en="$2"
  [[ "${UI_LANG:-de}" == "en" ]] && printf "%b\n" "$en" || printf "%b\n" "$de"
}

pause_tty() {
  local msg="${1:-}"
  if [[ -n "$msg" ]]; then
    read -r -p "$msg" _ || true
  else
    read -r -p "" _ || true
  fi
}

# ====== STATUS ======
set_status() { printf "%s\n" "$1" > "$STATUS_FILE"; }

get_status() {
  if [[ -s "$STATUS_FILE" ]]; then
    tail -n1 "$STATUS_FILE"
  else
    [[ "${UI_LANG:-de}" == "en" ]] && printf "Initializing status...\n" || printf "Status wird initialisiert...\n"
  fi
}

get_status_formatted() {
  local s; s="$(get_status)"
  if [[ "$s" == *"FEHLER"* || "$s" == *"ERROR"* || "$s" == *"failed"* ]]; then
    printf "%b\n" "${R}${s}${NC}"
  elif [[ "$s" == *"Abgeschlossen"* || "$s" == *"Finished"* || "$s" == OK* ]]; then
    printf "%b\n" "${G}${s}${NC}"
  elif [[ "$s" == *"UPLOAD"* || "$s" == *"DOWNLOAD"* ]]; then
    printf "%b\n" "${Y}${s}${NC}"
  else
    printf "%b\n" "$s"
  fi
}

# ====== PROCESS CHECK ======
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; return 1; }
  if ps -p "$pid" >/dev/null 2>&1 || pgrep -P "$pid" >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$PID_FILE"
  return 1
}

clear_status() { ! is_running && rm -f "$STATUS_FILE" 2>/dev/null || true; }

# ====== LOG FILE (writable fallback) ======
ensure_logfile_writable() {
  local dir
  dir="$(dirname -- "$LOG_FILE")"
  mkdir -p "$dir" 2>/dev/null || true

  if touch "$LOG_FILE" 2>/dev/null; then
    return 0
  fi

  LOG_FILE="${EFFECTIVE_HOME}/.local/state/borgbase-manager.log"
  mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || {
    LOG_FILE="/tmp/borgbase-manager.log"
    touch "$LOG_FILE" 2>/dev/null || true
  }
}

# ====== SSH HELPERS ======
_host_from_repo() { local r="$1"; r="${r#ssh://}"; r="${r%%/*}"; printf "%s\n" "${r#*@}"; }
_user_from_repo() { local r="$1"; r="${r#ssh://}"; r="${r%%/*}"; printf "%s\n" "${r%%@*}"; }

# ====== AUTO-DETECTION of SRC_DIR (case-insensitive '*panzerbackup*') ======
detect_src_dir() {
  has_upload_set() {
    shopt -s nullglob
    local files=( "$1"/panzer_*.img.zst.gpg )
    shopt -u nullglob
    (( ${#files[@]} > 0 ))
  }

  if [[ -d "$SRC_DIR" ]] && has_upload_set "$SRC_DIR"; then
    return 0
  fi

  say "Versuche, Panzerbackup-Volume automatisch zu finden..." \
      "Trying to auto-detect a Panzerbackup volume..."

  local bases=(/mnt /media /run/media)
  local candidates=()

  local base
  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' d; do candidates+=( "$d" ); done \
      < <(find "$base" -maxdepth 3 -type d -iname "*panzerbackup*" -print0 2>/dev/null || true)
  done

  if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r mnt; do [[ -d "$mnt" ]] && candidates+=( "$mnt" ); done \
      < <(findmnt -rno TARGET | awk 'BEGIN{IGNORECASE=1}/panzerbackup/{print}')
  fi

  (( ${#candidates[@]} )) && mapfile -t candidates < <(printf "%s\n" "${candidates[@]}" | awk '!seen[$0]++')

  local valid=()
  local d
  for d in "${candidates[@]:-}"; do has_upload_set "$d" && valid+=( "$d" ); done

  (( ${#valid[@]} )) || {
    say "Kein Verzeichnis mit panzer_*.img.zst.gpg gefunden." \
        "No directory containing panzer_*.img.zst.gpg found."
    return 1
  }

  local best_dir="" best_mtime=0 newest mt
  for d in "${valid[@]}"; do
    newest="$(ls -1t "$d"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
    [[ -n "$newest" ]] || continue
    mt="$(stat -c %Y "$newest" 2>/dev/null || echo 0)"
    (( mt > best_mtime )) && { best_mtime=$mt; best_dir="$d"; }
  done

  [[ -n "$best_dir" ]] || {
    say "Kein passendes Backup-Verzeichnis gefunden." "No suitable backup directory found."
    return 1
  }

  SRC_DIR="$best_dir"
  say "${G}Backup-Verzeichnis gefunden: $SRC_DIR${NC}" "${G}Detected backup directory: $SRC_DIR${NC}"
}

# ====== BACKUP SELECTION (what will be uploaded) ======
human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'function human(x){s="B KiB MiB GiB TiB PiB";split(s,a," ");i=1;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,a[i])} BEGIN{print human(b)}'
}

get_latest_backup_base() {
  local latest_img base
  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  [[ -n "$latest_img" ]] || return 1
  base="${latest_img%.img.zst.gpg}"
  printf "%s\n" "$base"
}

show_upload_selection() {
  local base img sha sfd mt_epoch mt_h size_bytes size_h
  base="$(get_latest_backup_base)" || {
    set_status "FEHLER: Kein Backup im Quellverzeichnis gefunden"
    say "${R}FEHLER: Kein Backup im Quellverzeichnis gefunden.${NC}" \
        "${R}ERROR: No backup found in source directory.${NC}"
    return 1
  }

  img="${base}.img.zst.gpg"
  sha="${base}.img.zst.gpg.sha256"
  sfd="${base}.sfdisk"

  local f
  for f in "$img" "$sha" "$sfd"; do
    [[ -f "$f" ]] || {
      set_status "FEHLER: Datei fehlt: $(basename "$f")"
      say "${R}FEHLER: Datei fehlt: $(basename "$f")${NC}" \
          "${R}ERROR: Missing file: $(basename "$f")${NC}"
      return 1
    }
  done

  mt_epoch="$(stat -c %Y "$img" 2>/dev/null || echo 0)"
  mt_h="$(date -d "@$mt_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "n/a")"
  size_bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"
  size_h="$(human_bytes "$size_bytes")"

  printf "\n"
  say "${B}Geplantes Upload-Set (NEUESTES Backup):${NC}" "${B}Planned upload set (LATEST backup):${NC}"
  printf "  SRC_DIR : %s\n" "$SRC_DIR"
  printf "  IMG     : %s\n" "$(basename "$img")"
  printf "  Datum   : %s\n" "$mt_h"
  printf "  Größe   : %s (%s Bytes)\n" "$size_h" "$size_bytes"
  printf "  SHA     : %s\n" "$(basename "$sha")"
  printf "  SFDISK  : %s\n" "$(basename "$sfd")"
  printf "\n"
}

# ====== PRE-FLIGHT (local only, fast) ======
preflight_space_check() {
  local base img size_bytes
  base="$(get_latest_backup_base)" || { set_status "FEHLER: Kein gültiges Upload-Set gefunden."; return 1; }
  img="${base}.img.zst.gpg"
  size_bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"
  if [[ "$size_bytes" -le 0 ]]; then
    set_status "FEHLER: Upload-Set ungültig (0 Bytes)."
    return 1
  fi
  set_status "OK: Upload-Set gültig – IMG Größe: $size_bytes Bytes"
  return 0
}

# ====== ERROR CLASSIFICATION (log tail) ======
classify_error_from_log_tail() {
  local tail_txt
  tail_txt="$(tail -n 200 "$LOG_FILE" 2>/dev/null || true)"

  if echo "$tail_txt" | grep -qiE 'host key verification failed|remote host identification has changed'; then
    printf "%s\n" "SSH-Hostkey-Problem (known_hosts)."
  elif echo "$tail_txt" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    printf "%s\n" "SSH-Auth fehlgeschlagen (publickey)."
  elif echo "$tail_txt" | grep -qiE 'could not resolve hostname|name or service not known|temporary failure in name resolution'; then
    printf "%s\n" "DNS/Hostname-Auflösung fehlgeschlagen."
  elif echo "$tail_txt" | grep -qiE 'connection timed out|operation timed out|connection refused|no route to host|network is unreachable'; then
    printf "%s\n" "Netzwerk/Firewall/Timeout beim SSH-Zugriff."
  elif echo "$tail_txt" | grep -qiE 'enter passphrase|passphrase is incorrect|wrong passphrase|repository.*is encrypted|encryption.*required'; then
    printf "%s\n" "BORG_PASSPHRASE fehlt/ist falsch (Repo verschlüsselt)."
  elif echo "$tail_txt" | grep -qiE 'repository.*does not exist|not found|doesn.t exist|Repository .* not found'; then
    printf "%s\n" "Repo-Pfad falsch oder Zugriff auf Repo verweigert."
  elif echo "$tail_txt" | grep -qiE 'failed to create/acquire the lock|lock.*failed|repository is already locked|lock timeout'; then
    printf "%s\n" "Repo ist gesperrt (Lock) – ggf. paralleler Lauf."
  else
    printf "%s\n" "Unbekannter Fehler – Details im Log."
  fi
}

# ====== ensure known_hosts entry (optional, fast, non-fatal) ======
ensure_known_hosts() {
  [[ "${AUTO_ACCEPT_HOSTKEY}" == "yes" ]] || return 0
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  command -v ssh-keyscan >/dev/null 2>&1 || return 0

  local host; host="$(_host_from_repo "${REPO}")"
  local kh="${SSH_KNOWN_HOSTS}"

  mkdir -p "$(dirname -- "$kh")" 2>/dev/null || true
  touch "$kh" 2>/dev/null || true

  if ssh-keygen -F "$host" -f "$kh" >/dev/null 2>&1; then
    return 0
  fi

  say "SSH: Hostkey für ${host} fehlt – füge via ssh-keyscan hinzu..." \
      "SSH: Missing hostkey for ${host} — adding via ssh-keyscan..."

  timeout "${SSH_CONNECT_TIMEOUT}" ssh-keyscan -H -t ed25519,ecdsa,rsa "$host" >> "$kh" 2>/dev/null || true
}

# ====== test ssh auth (optional) ======
test_ssh_auth() {
  [[ "${AUTO_TEST_SSH}" == "yes" ]] || return 0

  local host user key out
  host="$(_host_from_repo "${REPO}")"
  user="$(_user_from_repo "${REPO}")"
  key="${SSH_KEY:-}"

  [[ -n "$key" && -r "$key" ]] || {
    set_status "FEHLER: SSH_KEY nicht lesbar: $key"
    return 1
  }

  out="$(ssh -T -o RequestTTY=no -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
    -i "$key" \
    "${user}@${host}" -- borg --version 2>&1 || true)"

  if echo "$out" | grep -qiE 'host key verification failed|remote host identification has changed'; then
    set_status "FEHLER: SSH Hostkey Problem. Bitte known_hosts prüfen."
    printf "%s\n" "$out" >> "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
  if echo "$out" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    set_status "FEHLER: SSH Auth fehlgeschlagen (publickey)."
    printf "%s\n" "$out" >> "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
  return 0
}

test_borg_repo() {
  [[ "${AUTO_TEST_REPO}" == "yes" ]] || return 0
  if ! borg info --lock-wait "${BORG_LOCK_WAIT}" "${REPO}" >> "$LOG_FILE" 2>&1; then
    local msg; msg="$(classify_error_from_log_tail)"
    set_status "FEHLER: Repo-Test fehlgeschlagen: ${msg}"
    return 1
  fi
  return 0
}

# ====== BORG ENV SETUP (deterministic) ======
setup_borg_env() {
  ensure_logfile_writable

  if [[ -z "${REPO}" ]]; then
    set_status "FEHLER: REPO ist nicht gesetzt."
    say "${R}FEHLER: REPO ist nicht gesetzt.${NC}" "${R}ERROR: REPO is not set.${NC}"
    return 1
  fi

  # enforce key if set
  if [[ -n "${SSH_KEY}" && ! -r "${SSH_KEY}" ]]; then
    set_status "FEHLER: SSH_KEY ist gesetzt aber nicht lesbar: ${SSH_KEY}"
    say "${R}FEHLER: SSH_KEY ist gesetzt aber nicht lesbar: ${SSH_KEY}${NC}" \
        "${R}ERROR: SSH_KEY is set but not readable: ${SSH_KEY}${NC}"
    return 1
  fi

  mkdir -p "$(dirname -- "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
  touch "$SSH_KNOWN_HOSTS" 2>/dev/null || true

  ensure_known_hosts

  if [[ -n "${SSH_KEY}" && -r "${SSH_KEY}" ]]; then
    export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    say "SSH-Schlüssel verwendet: $SSH_KEY" "Using SSH key: $SSH_KEY"
  else
    export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    say "${Y}WARNUNG: Kein SSH_KEY gesetzt – nutze Standardidentitäten/Agent.${NC}" \
        "${Y}WARNING: No SSH_KEY set – using default identities/agent.${NC}"
  fi

  if [[ -n "${PASSPHRASE_FILE}" && -f "$PASSPHRASE_FILE" ]]; then
    export BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"
  fi

  test_ssh_auth || return 1
  test_borg_repo || return 1
}

# ====== REPOSITORY ACTIONS ======
list_archives() {
  say "Verfügbare Archive im Repository:" "Available archives in repository:"
  printf "\n"
  if ! borg list --lock-wait 1 "${REPO}" | nl -w2 -s') '; then
    say "${Y}Hinweis: Repository ist ggf. gesperrt oder Zugriff fehlgeschlagen.${NC}" \
        "${Y}Note: Repository may be locked or access failed.${NC}"
  fi
  printf "\n"
}

select_archive() {
  local archives=()
  mapfile -t archives < <(borg list --short "${REPO}")
  (( ${#archives[@]} )) || { say "Keine Archive im Repository gefunden." "No archives found in repository."; return 1; }

  say "Verfügbare Archive:" "Available archives:"
  local i
  for i in "${!archives[@]}"; do printf "  %2d) %s\n" $((i+1)) "${archives[$i]}"; done
  printf "\n"

  local choice
  if [[ "${UI_LANG:-de}" == "en" ]]; then
    read -r -p "Archive number (1-${#archives[@]}): " choice || return 1
  else
    read -r -p "Archive-Nummer (1-${#archives[@]}): " choice || return 1
  fi

  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#archives[@]} )) || { say "Ungültige Auswahl" "Invalid selection"; return 1; }
  printf "%s\n" "${archives[$((choice-1))]}"
}

# ====== WORKERS ======
do_upload_background() {
  set_status "UPLOAD: Wird gestartet..."

  local worker
  worker="$(mktemp /tmp/borg-upload-worker.XXXXXX.sh)"
  cat > "$worker" << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; printf "FEHLER (Worker Upload) in Zeile %s: %s (RC=%s)\n" "${LINENO}" "${BASH_COMMAND}" "${rc}" >&2; exit "${rc}"' ERR
export LC_ALL=C

set_status() { printf "%s\n" "$1" > "$STATUS_FILE"; }

classify_error_from_log_tail() {
  local tail_txt
  tail_txt="$(tail -n 200 "$LOG_FILE" 2>/dev/null || true)"

  if echo "$tail_txt" | grep -qiE 'host key verification failed|remote host identification has changed'; then
    printf "%s\n" "SSH-Hostkey-Problem (known_hosts)."
  elif echo "$tail_txt" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    printf "%s\n" "SSH-Auth fehlgeschlagen (publickey)."
  elif echo "$tail_txt" | grep -qiE 'could not resolve hostname|name or service not known|temporary failure in name resolution'; then
    printf "%s\n" "DNS/Hostname-Auflösung fehlgeschlagen."
  elif echo "$tail_txt" | grep -qiE 'connection timed out|operation timed out|connection refused|no route to host|network is unreachable'; then
    printf "%s\n" "Netzwerk/Firewall/Timeout beim SSH-Zugriff."
  elif echo "$tail_txt" | grep -qiE 'repository.*does not exist|not found|doesn.t exist|Repository .* not found'; then
    printf "%s\n" "Repo-Pfad falsch oder Zugriff auf Repo verweigert."
  elif echo "$tail_txt" | grep -qiE 'failed to create/acquire the lock|lock.*failed|repository is already locked|lock timeout'; then
    printf "%s\n" "Repo ist gesperrt (Lock) – ggf. paralleler Lauf."
  else
    printf "%s\n" "Unbekannter Fehler – Details im Log."
  fi
}

SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"

if [[ -n "${SSH_KEY:-}" && -r "$SSH_KEY" ]]; then
  export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
else
  export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
fi

[[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]] && export BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"

START_TIME=$(date +%s)

{
  exec >> "$LOG_FILE" 2>&1
  printf "==========================================\n"
  printf "Worker Start (Upload): %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "==========================================\n"
  printf "ENV: HOME=%s USER=%s LOGNAME=%s\n" "${HOME:-<unset>}" "${USER:-<unset>}" "${LOGNAME:-<unset>}"
  printf "ENV: SSH_KEY=%s\n" "${SSH_KEY:-<unset>}"
  printf "ENV: SSH_KNOWN_HOSTS=%s\n" "${SSH_KNOWN_HOSTS:-<unset>}"
  printf "ENV: BORG_RSH=%s\n" "${BORG_RSH}"
  printf "------------------------------------------\n"

  set_status "UPLOAD: Ermittle neuestes Backup..."

  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  if [[ -z "${latest_img}" ]]; then
    set_status "FEHLER: Kein Backup im Quellverzeichnis gefunden"
    rm -f "$PID_FILE"
    exit 1
  fi

  base="${latest_img%.img.zst.gpg}"
  img="${base}.img.zst.gpg"
  sha="${base}.img.zst.gpg.sha256"
  sfd="${base}.sfdisk"

  for f in "$img" "$sha" "$sfd"; do
    [[ -f "$f" ]] || { set_status "FEHLER: Datei fehlt: $(basename "$f")"; rm -f "$PID_FILE"; exit 1; }
  done

  HOST="$(hostname -s)"
  NOW="$(date +%Y-%m-%d_%H-%M)"
  ARCHIVE="Backup-${HOST}-${NOW}"

  set_status "UPLOAD: Erstelle Archiv ${ARCHIVE}..."
  INCLUDE_LIST="$(mktemp)"
  trap 'rm -f "$INCLUDE_LIST"' EXIT

  {
    printf "%s\n" "$img"
    printf "%s\n" "$sha"
    printf "%s\n" "$sfd"
    [[ -f "${SRC_DIR}/LATEST_OK" ]] && printf "%s\n" "${SRC_DIR}/LATEST_OK"
    [[ -f "${SRC_DIR}/LATEST_OK.sha256" ]] && printf "%s\n" "${SRC_DIR}/LATEST_OK.sha256"
    [[ -f "${SRC_DIR}/LATEST_OK.sfdisk" ]] && printf "%s\n" "${SRC_DIR}/LATEST_OK.sfdisk"
    [[ -f "${SRC_DIR}/panzerbackup.log" ]] && printf "%s\n" "${SRC_DIR}/panzerbackup.log"
  } > "$INCLUDE_LIST"

  printf "UPLOAD SET:\n"
  cat "$INCLUDE_LIST"
  printf "------------------------------------------\n"

  set_status "UPLOAD: Lade Daten hoch..."

  set +e
  borg create --lock-wait "${BORG_LOCK_WAIT:-5}" --stats --progress --compression lz4 \
    "${REPO}::${ARCHIVE}" --paths-from-stdin < "$INCLUDE_LIST"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    msg="$(classify_error_from_log_tail)"
    set_status "FEHLER: Upload fehlgeschlagen (rc=${rc}) – ${msg}"
    printf "Upload failed with rc=%s – %s\n" "$rc" "$msg"
    rm -f "$PID_FILE"
    exit "$rc"
  fi

  if [[ "${PRUNE}" == "yes" ]]; then
    set_status "UPLOAD: Lösche alte Archive (Prune)..."
    borg prune -v --list --lock-wait "${BORG_LOCK_WAIT:-5}" "${REPO}" \
      --glob-archives "Backup-${HOST}-*" --keep-last="${KEEP_LAST}" || true

    set_status "UPLOAD: Komprimiere Repository (Compact)..."
    borg compact --lock-wait "${BORG_LOCK_WAIT:-5}" "${REPO}" || true
  fi

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FMT="$(printf '%02dm:%02ds\n' $((DURATION%3600/60)) $((DURATION%60)))"

  set_status "UPLOAD: Abgeschlossen - ${ARCHIVE} (Dauer: ${DURATION_FMT})"

  printf "\n------------------------------------------\n"
  printf "  SUCCESS SUMMARY\n"
  printf "  Archive:  %s\n" "${ARCHIVE}"
  printf "  Duration: %s\n" "${DURATION_FMT}"
  printf "  End:      %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "------------------------------------------\n"

  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x "$worker"

  env -i \
    PATH="$PATH" \
    HOME="$EFFECTIVE_HOME" USER="$EFFECTIVE_USER" LOGNAME="$EFFECTIVE_USER" \
    LC_ALL="$LC_ALL" UI_LANG="${UI_LANG:-de}" \
    SRC_DIR="$SRC_DIR" REPO="$REPO" \
    SSH_KEY="$SSH_KEY" SSH_KNOWN_HOSTS="$SSH_KNOWN_HOSTS" SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
    PASSPHRASE_FILE="${PASSPHRASE_FILE:-}" \
    LOG_FILE="$LOG_FILE" STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    PRUNE="$PRUNE" KEEP_LAST="$KEEP_LAST" \
    BORG_LOCK_WAIT="$BORG_LOCK_WAIT" \
    nohup setsid "$worker" &>/dev/null &

  printf "%s\n" "$!" > "$PID_FILE"
}

do_download_background() {
  local selected_archive="$1"
  set_status "DOWNLOAD: Wird gestartet..."

  local worker
  worker="$(mktemp /tmp/borg-download-worker.XXXXXX.sh)"
  cat > "$worker" << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; printf "FEHLER (Worker Download) in Zeile %s: %s (RC=%s)\n" "${LINENO}" "${BASH_COMMAND}" "${rc}" >&2; exit "${rc}"' ERR
export LC_ALL=C

set_status() { printf "%s\n" "$1" > "$STATUS_FILE"; }

classify_error_from_log_tail() {
  local tail_txt
  tail_txt="$(tail -n 200 "$LOG_FILE" 2>/dev/null || true)"

  if echo "$tail_txt" | grep -qiE 'host key verification failed|remote host identification has changed'; then
    printf "%s\n" "SSH-Hostkey-Problem (known_hosts)."
  elif echo "$tail_txt" | grep -qiE 'permission denied \(publickey\)|no supported authentication methods available'; then
    printf "%s\n" "SSH-Auth fehlgeschlagen (publickey)."
  elif echo "$tail_txt" | grep -qiE 'connection timed out|operation timed out|connection refused|no route to host|network is unreachable'; then
    printf "%s\n" "Netzwerk/Firewall/Timeout beim SSH-Zugriff."
  elif echo "$tail_txt" | grep -qiE 'failed to create/acquire the lock|lock.*failed|repository is already locked|lock timeout'; then
    printf "%s\n" "Repo ist gesperrt (Lock) – ggf. paralleler Lauf."
  else
    printf "%s\n" "Unbekannter Fehler – Details im Log."
  fi
}

SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"

if [[ -n "${SSH_KEY:-}" && -r "$SSH_KEY" ]]; then
  export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
else
  export BORG_RSH="ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS} -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
fi

[[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]] && export BORG_PASSPHRASE="$(<"$PASSPHRASE_FILE")"

START_TIME=$(date +%s)

{
  exec >> "$LOG_FILE" 2>&1
  printf "==========================================\n"
  printf "Worker Start (Download): %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "==========================================\n"
  printf "ENV: HOME=%s USER=%s LOGNAME=%s\n" "${HOME:-<unset>}" "${USER:-<unset>}" "${LOGNAME:-<unset>}"
  printf "ENV: SSH_KEY=%s\n" "${SSH_KEY:-<unset>}"
  printf "ENV: SSH_KNOWN_HOSTS=%s\n" "${SSH_KNOWN_HOSTS:-<unset>}"
  printf "ENV: BORG_RSH=%s\n" "${BORG_RSH}"
  printf "------------------------------------------\n"

  set_status "DOWNLOAD: Starte Download von ${SELECTED_ARCHIVE}..."
  [[ -d "$SRC_DIR" ]] || { set_status "FEHLER: Zielverzeichnis nicht gefunden"; rm -f "$PID_FILE"; exit 1; }
  [[ -w "$SRC_DIR" ]] || { set_status "FEHLER: Zielverzeichnis nicht schreibbar"; rm -f "$PID_FILE"; exit 1; }

  set_status "DOWNLOAD: Extrahiere ${SELECTED_ARCHIVE}..."
  cd "$SRC_DIR"

  set +e
  borg extract --lock-wait "${BORG_LOCK_WAIT:-5}" --progress "${REPO}::${SELECTED_ARCHIVE}"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    msg="$(classify_error_from_log_tail)"
    set_status "FEHLER: Download fehlgeschlagen (rc=${rc}) – ${msg}"
    printf "Download failed with rc=%s – %s\n" "$rc" "$msg"
    rm -f "$PID_FILE"
    exit "$rc"
  fi

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FMT="$(printf '%02dm:%02ds\n' $((DURATION%3600/60)) $((DURATION%60)))"

  set_status "DOWNLOAD: Abgeschlossen - ${SELECTED_ARCHIVE} (Dauer: ${DURATION_FMT})"

  printf "\n------------------------------------------\n"
  printf "  SUCCESS SUMMARY (Download)\n"
  printf "  Archive:  %s\n" "${SELECTED_ARCHIVE}"
  printf "  Duration: %s\n" "${DURATION_FMT}"
  printf "------------------------------------------\n"

  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x "$worker"

  env -i \
    PATH="$PATH" \
    HOME="$EFFECTIVE_HOME" USER="$EFFECTIVE_USER" LOGNAME="$EFFECTIVE_USER" \
    LC_ALL="$LC_ALL" UI_LANG="${UI_LANG:-de}" \
    SELECTED_ARCHIVE="$selected_archive" SRC_DIR="$SRC_DIR" REPO="$REPO" \
    SSH_KEY="$SSH_KEY" SSH_KNOWN_HOSTS="$SSH_KNOWN_HOSTS" SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
    PASSPHRASE_FILE="${PASSPHRASE_FILE:-}" \
    LOG_FILE="$LOG_FILE" STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    BORG_LOCK_WAIT="$BORG_LOCK_WAIT" \
    nohup setsid "$worker" &>/dev/null &

  printf "%s\n" "$!" > "$PID_FILE"
}

# ====== MENUS ======
show_settings_menu() {
  while true; do
    clear || true
    printf "\n"
    printf "╔════════════════════════════════════════════════════════════╗\n"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && printf "║                  Settings / Configuration                  ║\n" \
      || printf "║                Einstellungen / Konfiguration               ║\n"
    printf "╠════════════════════════════════════════════════════════════╣\n"

    printf "║  SRC_DIR: %-47s ║\n" "${SRC_DIR}"
    printf "║  REPO: %-50s ║\n" "${REPO:0:50}"
    printf "║  SSH_KEY: %-47s ║\n" "${SSH_KEY:0:47}"
    printf "║  KNOWN_HOSTS: %-41s ║\n" "${SSH_KNOWN_HOSTS:0:41}"
    printf "║  LOG_FILE: %-46s ║\n" "${LOG_FILE:0:46}"
    printf "║  STATUS_FILE: %-41s ║\n" "${STATUS_FILE:0:41}"
    printf "║  PID_FILE: %-44s ║\n" "${PID_FILE:0:44}"
    printf "║  PRUNE: %-49s ║\n" "${PRUNE}"
    printf "║  KEEP_LAST: %-45s ║\n" "${KEEP_LAST}"

    printf "╠════════════════════════════════════════════════════════════╣\n"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && printf "║  b) Back to main menu                                      ║\n" \
      || printf "║  b) Zurück zum Hauptmenü                                   ║\n"
    printf "╚════════════════════════════════════════════════════════════╝\n\n"
    say "Hinweis: Zum Ändern der Einstellungen /etc/borgbase-manager.env oder ./.env bearbeiten." \
        "Note: To change settings, edit /etc/borgbase-manager.env or ./.env"
    printf "\n"
    pause_tty "$(say 'Zurück mit Enter...' 'Back with Enter...')"
    break
  done
}

show_menu() {
  while true; do
    clear || true
    printf "\n"
    printf "╔════════════════════════════════════════════════════════════╗\n"
    [[ "${UI_LANG:-de}" == "en" ]] \
      && printf "║          BorgBase Backup Manager - Main Menu               ║\n" \
      || printf "║          BorgBase Backup Manager - Hauptmenü               ║\n"
    printf "╠════════════════════════════════════════════════════════════╣\n"

    if [[ "${UI_LANG:-de}" == "en" ]]; then
      printf "║  1) Upload backup to BorgBase                              ║\n"
      printf "║  2) Download backup from BorgBase                          ║\n"
      printf "║  3) List all archives                                      ║\n"
      printf "║  4) Show current status                                    ║\n"
      printf "║  5) View log file                                          ║\n"
      printf "║  6) Clear status                                           ║\n"
      printf "║  7) Settings / Configuration                               ║\n"
      printf "║  q) Quit                                                   ║\n"
    else
      printf "║  1) Backup zu BorgBase hochladen                           ║\n"
      printf "║  2) Backup von BorgBase herunterladen                      ║\n"
      printf "║  3) Alle Archive auflisten                                 ║\n"
      printf "║  4) Aktuellen Status anzeigen                              ║\n"
      printf "║  5) Log-Datei anzeigen                                     ║\n"
      printf "║  6) Status löschen                                         ║\n"
      printf "║  7) Einstellungen / Konfiguration                          ║\n"
      printf "║  q) Beenden                                                ║\n"
    fi

    printf "╠════════════════════════════════════════════════════════════╣\n"
    local status_line; status_line="$(get_status_formatted)"
    printf "║  Status: %-49s ║\n" "${status_line}"
    printf "╚════════════════════════════════════════════════════════════╝\n\n"

    local choice
    read -r -p "$(say 'Ihre Wahl: ' 'Your choice: ')" choice || break

    case "$choice" in
      1)
        detect_src_dir || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        preflight_space_check || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        show_upload_selection || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        pause_tty "$(say 'Enter = Upload starten (oder CTRL+C zum Abbrechen) ' 'Press Enter to start upload (CTRL+C to abort) ')"

        setup_borg_env || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }

        if is_running; then
          say "${Y}Ein Upload/Download läuft bereits.${NC}" "${Y}Upload/Download already running.${NC}"
          pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
          continue
        fi

        do_upload_background
        say "${G}Upload wurde im Hintergrund gestartet.${NC}" "${G}Upload started in background.${NC}"
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
      2)
        detect_src_dir || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        setup_borg_env || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }

        if is_running; then
          say "${Y}Ein Upload/Download läuft bereits.${NC}" "${Y}Upload/Download already running.${NC}"
          pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
          continue
        fi

        local archive
        archive="$(select_archive)" || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        do_download_background "$archive"
        say "${G}Download wurde im Hintergrund gestartet.${NC}" "${G}Download started in background.${NC}"
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
      3)
        setup_borg_env || { pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"; continue; }
        list_archives
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
      4)
        printf "\n"
        say "Aktueller Status:" "Current status:"
        get_status_formatted
        printf "\n"
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
      5)
        ensure_logfile_writable
        if [[ -f "$LOG_FILE" ]]; then
          less "$LOG_FILE"
        else
          say "${Y}Log-Datei existiert noch nicht.${NC}" "${Y}Log file does not exist yet.${NC}"
          pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        fi
        ;;
      6)
        clear_status
        say "${G}Status gelöscht.${NC}" "${G}Status cleared.${NC}"
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
      7)
        show_settings_menu
        ;;
      q|Q)
        exit 0
        ;;
      *)
        say "${R}Ungültige Auswahl.${NC}" "${R}Invalid choice.${NC}"
        pause_tty "$(say 'Weiter mit Enter...' 'Continue with Enter...')"
        ;;
    esac
  done
}

# ====== CLI ENTRYPOINTS ======
init_runtime
cmd="${1:-}"

if [[ -z "$cmd" ]]; then
  choose_language
  show_menu
  exit 0
fi

case "$cmd" in
  upload)
    choose_language
    detect_src_dir || exit 1
    preflight_space_check || exit 1
    show_upload_selection || exit 1
    setup_borg_env || exit 1
    is_running && { printf "Already running.\n"; exit 1; }
    do_upload_background
    ;;
  download)
    choose_language
    detect_src_dir || exit 1
    setup_borg_env || exit 1
    is_running && { printf "Already running.\n"; exit 1; }
    archive="$(select_archive)" || exit 1
    do_download_background "$archive"
    ;;
  list)
    choose_language
    setup_borg_env || exit 1
    list_archives
    ;;
  status)
    get_status
    ;;
  menu)
    choose_language
    show_menu
    ;;
  *)
    printf "Usage: %s {upload|download|list|status|menu}\n" "$0"
    exit 1
    ;;
esac
