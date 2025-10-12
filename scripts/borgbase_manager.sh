#!/usr/bin/env bash
# BorgBase Backup Manager (Release)
# Purpose:
#   - Upload/Download of Panzerbackup artifacts to/from a BorgBase repository
#   - CLI entrypoints and an interactive TUI-like menu
#   - systemd-friendly (Service/Timer can call: borgbase_manager.sh upload)
#
# Configuration order (highest priority last-loaded env wins):
#   1) /etc/borgbase-manager.env      # recommended for systemd EnvironmentFile
#   2) ./.env                         # optional for local testing
#   3) Runtime environment variables
#
# Required variables (defaults/placeholders):
#   REPO="ssh://<YOUR_USER>@<YOUR_USER>.repo.borgbase.com/./repo"
#   SSH_KEY="/path/to/id_ed25519"
#   PASSPHRASE_FILE="/secure/path/passphrase"
#   SRC_DIR="/mnt/panzerbackup-pm"    # auto-detected if not valid
#   LOG_FILE="/var/log/borgbase-manager.log"
#   PRUNE="yes"  # yes|no
#   KEEP_LAST="1"
#
# Notes:
#   - No secrets are hardcoded. Provide via env files or unit files.
#   - Workers run with a minimal, explicit environment (env -i) to avoid leaks.

set -euo pipefail
set -E
trap 'rc=$?; echo "FEHLER in Zeile $LINENO beim Kommando: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ====== LOAD ENV ======
if [[ -r /etc/borgbase-manager.env ]]; then
  # shellcheck disable=SC1091
  . /etc/borgbase-manager.env
fi
if [[ -r ./.env ]]; then
  # shellcheck disable=SC1091
  . ./.env
fi

# ====== DEFAULTS / PLACEHOLDERS ======
export LC_ALL=C

: "${SRC_DIR:=/mnt/panzerbackup-pm}"
: "${REPO:=ssh://<YOUR_USER>@<YOUR_USER>.repo.borgbase.com/./repo}"

: "${SSH_KEY:=/path/to/id_ed25519}"
: "${PASSPHRASE_FILE:=/secure/path/passphrase}"

: "${LOG_FILE:=/var/log/borgbase-manager.log}"
: "${STATUS_FILE:=/tmp/borg-status}"
: "${PID_FILE:=/tmp/borg-upload.pid}"

: "${PRUNE:=yes}"
: "${KEEP_LAST:=1}"

# ====== I18N: Language selection & helpers ======
choose_language() {
  local choice="${UI_LANG:-}"
  if [[ -z "$choice" ]]; then
    echo "Choose language / Sprache wählen:"
    echo "  1) English"
    echo "  2) Deutsch"
    read -rp "> " choice || choice=""
  fi
  case "$choice" in
    1|en|EN|English|english) UI_LANG="en" ;;
    2|de|DE|Deutsch|deutsch) UI_LANG="de" ;;
    *) UI_LANG="de" ;;  # default: German
  esac
  export UI_LANG
}

# say "DE text" "EN text"
say() {
  local de="$1" en="$2"
  if [[ "${UI_LANG}" == "en" ]]; then echo "$en"; else echo "$de"; fi
}

# prompt_yes_no -> 0=yes  1=no
prompt_yes_no() {
  local de="$1" en="$2" ans
  if [[ "${UI_LANG}" == "en" ]]; then
    read -rp "$en [y/N]: " ans || return 1
    [[ "$ans" =~ ^[Yy]$ ]]
  else
    read -rp "$de [j/N]: " ans || return 1
    [[ "$ans" =~ ^[Jj]$ ]]
  fi
}

# ====== LOGGING ======
log_start() {
  local dir
  dir="$(dirname -- "$LOG_FILE")"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "=========================================="
  echo "Start: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
}
log_end() {
  echo "=========================================="
  echo "Ende:  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo ""
}

# ====== AUTO-DETECTION (case-insensitive substring '*panzerbackup*') ======
# Scans common mount roots, including user-specific media mounts (/media/*/*, /run/media/*/*)
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

  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue
    # case-insensitive substring match: *panzerbackup*, depth-limited for speed
    while IFS= read -r -d '' d; do
      candidates+=( "$d" )
    done < <(find "$base" -maxdepth 3 -type d -iname "*panzerbackup*" -print0 2>/dev/null || true)
  done

  # Additionally inspect mounted targets for substring 'panzerbackup'
  if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r mnt; do
      [[ -d "$mnt" ]] && candidates+=( "$mnt" )
    done < <(findmnt -rno TARGET | awk 'BEGIN{IGNORECASE=1}/panzerbackup/{print}')
  fi

  # De-duplicate
  if (( ${#candidates[@]} )); then
    mapfile -t candidates < <(printf "%s\n" "${candidates[@]}" | awk '!seen[$0]++')
  fi

  # Keep only directories containing a valid upload set
  local valid=()
  for d in "${candidates[@]}"; do
    has_upload_set "$d" && valid+=( "$d" )
  done

  (( ${#valid[@]} )) || { say "Kein Verzeichnis mit panzer_*.img.zst.gpg gefunden." "No directory containing panzer_*.img.zst.gpg found."; return 1; }

  # Pick the directory with the newest artifact
  local best_dir="" best_mtime=0
  for d in "${valid[@]}"; do
    local newest mt
    newest="$(ls -1t "$d"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
    [[ -n "$newest" ]] || continue
    mt=$(stat -c %Y "$newest" 2>/dev/null || echo 0)
    (( mt > best_mtime )) && { best_mtime=$mt; best_dir="$d" ;}
  done

  [[ -n "$best_dir" ]] || { say "Kein passendes Backup-Verzeichnis gefunden." "No suitable backup directory found."; return 1; }
  SRC_DIR="$best_dir"
  say "Backup-Verzeichnis gefunden: $SRC_DIR" "Detected backup directory: $SRC_DIR"
}

# ====== BORG ENV SETUP ======
setup_borg_env() {
  if [[ -n "${SSH_KEY:-}" && -r "$SSH_KEY" ]]; then
    export BORG_RSH="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"
  else
    export BORG_RSH="ssh -o IdentitiesOnly=no"
  fi
  if [[ -f "$PASSPHRASE_FILE" ]]; then
    export BORG_PASSPHRASE="$(cat "$PASSPHRASE_FILE")"
  fi
  local dir; dir="$(dirname -- "$LOG_FILE")"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  [[ -e "$LOG_FILE" ]] || : > "$LOG_FILE"
}

# ====== STATUS ======
set_status() { echo "$1" > "$STATUS_FILE"; }
get_status() {
  if [[ -s "$STATUS_FILE" ]]; then
    tail -n1 "$STATUS_FILE"
    return 0
  fi

  if [[ "${UI_LANG}" == "en" ]]; then
    echo "Initializing status..."
  else
    echo "Status wird initialisiert..."
  fi
}
clear_status() { ! is_running && rm -f "$STATUS_FILE"; }

# ====== PROCESS CHECK ======
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; return 1; }
  if ps -p "$pid" >/dev/null || pgrep -P "$pid" >/dev/null; then
    return 0
  fi
  rm -f "$PID_FILE"
  return 1
}

# ====== HELPERS ======
sum_bytes_files() {
  local t=0 f sz
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    t=$(( t+sz ))
  done
  echo "$t"
}

calc_upload_set_bytes() {
  local latest_img base img sha sfd files=()
  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  [[ -n "$latest_img" ]] || { echo 0; return; }
  base="${latest_img%.img.zst.gpg}"
  img="${base}.img.zst.gpg"
  sha="${base}.img.zst.gpg.sha256"
  sfd="${base}.sfdisk"
  files+=("$img" "$sha" "$sfd")
  [[ -f "${SRC_DIR}/LATEST_OK" ]] && files+=("${SRC_DIR}/LATEST_OK")
  [[ -f "${SRC_DIR}/LATEST_OK.sha256" ]] && files+=("${SRC_DIR}/LATEST_OK.sha256")
  [[ -f "${SRC_DIR}/LATEST_OK.sfdisk" ]] && files+=("${SRC_DIR}/LATEST_OK.sfdisk")
  [[ -f "${SRC_DIR}/panzerbackup.log" ]] && files+=("${SRC_DIR}/panzerbackup.log")
  sum_bytes_files "${files[@]}"
}

# ====== PRE-FLIGHT ======
preflight_space_check() {
  local upload_bytes
  upload_bytes="$(calc_upload_set_bytes)"
  if [[ "$upload_bytes" -le 0 ]]; then
    set_status "FEHLER: Kein gültiges Upload-Set gefunden."
    say "Abbruch: Kein gültiges Upload-Set." "Abort: No valid upload set."
    return 1
  fi
  set_status "OK: Upload-Set gültig – Größe: $upload_bytes Bytes"
  say "OK: Upload-Set gefunden – Größe: ${upload_bytes} Bytes" \
      "OK: Upload set found – size: ${upload_bytes} bytes"
  return 0
}

# ====== REPOSITORY ACTIONS ======
list_archives() {
  say "Verfügbare Archive im Repository:" "Available archives in repository:"
  echo ""
  if ! borg list --lock-wait 1 "${REPO}" | nl -w2 -s') '; then
    say "Hinweis: Repository ist derzeit gesperrt (laufender Upload/Download)." \
        "Note: Repository is currently locked (running upload/download)."
  fi
  echo ""
}

select_archive() {
  local archives=()
  mapfile -t archives < <(borg list --short "${REPO}")
  (( ${#archives[@]} )) || { say "Keine Archive im Repository gefunden." "No archives found in repository."; exit 1; }
  say "Verfügbare Archive:" "Available archives:"
  for i in "${!archives[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${archives[$i]}"
  done
  echo ""
  if [[ "${UI_LANG}" == "en" ]]; then
    read -rp "Archive number (1-${#archives[@]}): " choice || { echo "Input aborted."; exit 1; }
  else
    read -rp "Archive-Nummer (1-${#archives[@]}): " choice || { echo "Eingabe beendet."; exit 1; }
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#archives[@]} )) || { say "Ungültige Auswahl" "Invalid selection"; exit 1; }
  echo "${archives[$((choice-1))]}"
}

# ====== WORKERS ======
do_upload_background() {
  set_status "UPLOAD: Wird gestartet..."
  cat > /tmp/borg-upload-worker.sh << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; echo "FEHLER (Worker Upload) in Zeile $LINENO: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR

# Expected via env:
# SRC_DIR REPO SSH_KEY PASSPHRASE_FILE LOG_FILE STATUS_FILE PID_FILE PRUNE KEEP_LAST UI_LANG
export LC_ALL=C

# Configure BORG_RSH
if [[ -n "${SSH_KEY:-}" && -r "$SSH_KEY" ]]; then
  export BORG_RSH="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"
else
  export BORG_RSH="ssh -o IdentitiesOnly=no"
fi

[[ -f "$PASSPHRASE_FILE" ]] && export BORG_PASSPHRASE="$(cat "$PASSPHRASE_FILE")"
set_status() { echo "$1" > "$STATUS_FILE"; }

say() { if [[ "${UI_LANG}" == "en" ]]; then echo "$2"; else echo "$1"; fi; }

{
  exec >> "$LOG_FILE" 2>&1
  echo "=========================================="
  echo "Worker Start (Upload): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  set_status "UPLOAD: Ermittle neuestes Backup..."
  HOST="$(hostname -s)"; NOW="$(date +%Y-%m-%d_%H-%M)"; ARCHIVE_PREFIX="Backup-${HOST}"

  latest_img="$(ls -1t "${SRC_DIR}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
  if [[ -z "${latest_img}" ]]; then set_status "FEHLER: Kein Backup im Quellverzeichnis gefunden"; rm -f "$PID_FILE"; exit 1; fi

  base="${latest_img%.img.zst.gpg}"
  img="${base}.img.zst.gpg"; sha="${base}.img.zst.gpg.sha256"; sfd="${base}.sfdisk"
  for f in "$img" "$sha" "$sfd"; do [[ -f "$f" ]] || { set_status "FEHLER: Datei fehlt: $(basename "$f")"; rm -f "$PID_FILE"; exit 1; }; done

  ARCHIVE="${ARCHIVE_PREFIX}-${NOW}"
  set_status "UPLOAD: Erstelle Archiv ${ARCHIVE}..."

  INCLUDE_LIST="$(mktemp)"; trap 'rm -f "$INCLUDE_LIST"' EXIT
  { echo "$img"; echo "$sha"; echo "$sfd";
    [[ -f "${SRC_DIR}/LATEST_OK" ]] && echo "${SRC_DIR}/LATEST_OK"
    [[ -f "${SRC_DIR}/LATEST_OK.sha256" ]] && echo "${SRC_DIR}/LATEST_OK.sha256"
    [[ -f "${SRC_DIR}/LATEST_OK.sfdisk" ]] && echo "${SRC_DIR}/LATEST_OK.sfdisk"
    [[ -f "${SRC_DIR}/panzerbackup.log" ]] && echo "${SRC_DIR}/panzerbackup.log"
  } > "$INCLUDE_LIST"

  set_status "UPLOAD: Lade Daten hoch..."
  borg create --stats --progress --compression lz4 "${REPO}::${ARCHIVE}" --paths-from-stdin < "$INCLUDE_LIST"

  if [[ "${PRUNE}" == "yes" ]]; then
    set_status "UPLOAD: Lösche alte Archive..."
    borg prune -v --list "${REPO}" --glob-archives "Backup-${HOST}-*" --keep-last="${KEEP_LAST}"
    set_status "UPLOAD: Komprimiere Repository..."
    borg compact "${REPO}"
  fi

  set_status "UPLOAD: Abgeschlossen - ${ARCHIVE}"
  echo "=========================================="
  echo "Worker Ende (Upload): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x /tmp/borg-upload-worker.sh
  env -i \
    PATH="$PATH" LC_ALL="$LC_ALL" UI_LANG="${UI_LANG:-de}" \
    SRC_DIR="$SRC_DIR" REPO="$REPO" \
    SSH_KEY="$SSH_KEY" PASSPHRASE_FILE="$PASSPHRASE_FILE" \
    LOG_FILE="$LOG_FILE" STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    PRUNE="$PRUNE" KEEP_LAST="$KEEP_LAST" \
    nohup setsid /tmp/borg-upload-worker.sh &> /dev/null &

  echo $! > "$PID_FILE"
}

do_download_background() {
  local selected_archive="$1"
  set_status "DOWNLOAD: Wird gestartet..."
  cat > /tmp/borg-download-worker.sh << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; echo "FEHLER (Worker Download) in Zeile $LINENO: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR

# Expected via env:
# SELECTED_ARCHIVE SRC_DIR REPO SSH_KEY PASSPHRASE_FILE LOG_FILE STATUS_FILE PID_FILE UI_LANG
export LC_ALL=C

if [[ -n "${SSH_KEY:-}" && -r "$SSH_KEY" ]]; then
  export BORG_RSH="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"
else
  export BORG_RSH="ssh -o IdentitiesOnly=no"
fi

[[ -f "$PASSPHRASE_FILE" ]] && export BORG_PASSPHRASE="$(cat "$PASSPHRASE_FILE")"
set_status() { echo "$1" > "$STATUS_FILE"; }
say() { if [[ "${UI_LANG}" == "en" ]]; then echo "$2"; else echo "$1"; fi; }

{
  exec >> "$LOG_FILE" 2>&1
  echo "=========================================="
  echo "Worker Start (Download): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  set_status "DOWNLOAD: Starte Download von ${SELECTED_ARCHIVE}..."
  [[ -d "$SRC_DIR" ]] || { set_status "FEHLER: Zielverzeichnis nicht gefunden"; rm -f "$PID_FILE"; exit 1; }
  [[ -w "$SRC_DIR" ]] || { set_status "FEHLER: Zielverzeichnis nicht schreibbar"; rm -f "$PID_FILE"; exit 1; }

  set_status "DOWNLOAD: Extrahiere ${SELECTED_ARCHIVE}..."
  cd "$SRC_DIR"
  borg extract --progress "${REPO}::${SELECTED_ARCHIVE}"

  set_status "DOWNLOAD: Abgeschlossen - ${SELECTED_ARCHIVE}"
  echo "=========================================="
  echo "Worker Ende (Download): $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x /tmp/borg-download-worker.sh
  env -i \
    PATH="$PATH" LC_ALL="$LC_ALL" UI_LANG="${UI_LANG:-de}" \
    SELECTED_ARCHIVE="$selected_archive" SRC_DIR="$SRC_DIR" \
    REPO="$REPO" SSH_KEY="$SSH_KEY" PASSPHRASE_FILE="$PASSPHRASE_FILE" \
    LOG_FILE="$LOG_FILE" STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    nohup setsid /tmp/borg-download-worker.sh &> /dev/null &

  echo $! > "$PID_FILE"
}

# ====== STARTERS ======
do_upload() {
  if is_running; then
    say "Ein Vorgang läuft bereits!" "A job is already running!"
    say "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    return 1
  fi
  if ! preflight_space_check; then
    say "Upload wurde NICHT gestartet (Preflight fehlgeschlagen)." \
        "Upload NOT started (preflight failed)."
    return 1
  fi
  clear_status
  say "Starte Upload im Hintergrund..." "Starting upload in background..."
  do_upload_background
  echo ""
  say "Upload wurde gestartet." "Upload started."
  say "Verwende Option 7), um den Fortschritt zu sehen." "Use option 7) to watch progress."
  echo ""
}

do_download() {
  if is_running; then
    say "Ein Vorgang läuft bereits!" "A job is already running!"
    say "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    return 1
  fi
  clear_status
  say "Backup von BorgBase herunterladen" "Download backup from BorgBase"
  echo ""
  local SELECTED_ARCHIVE
  SELECTED_ARCHIVE="$(select_archive)"
  echo ""
  say "Gewähltes Archiv: ${SELECTED_ARCHIVE}" "Selected archive: ${SELECTED_ARCHIVE}"
  echo ""
  say "Archiv-Inhalt:" "Archive contents:"
  borg list --lock-wait 1 "${REPO}::${SELECTED_ARCHIVE}" || true
  echo ""
  if ! prompt_yes_no "Dieses Archiv nach ${SRC_DIR} extrahieren?" \
                     "Extract this archive to ${SRC_DIR}?"; then
    say "Abgebrochen" "Cancelled"
    return 0
  fi
  echo ""
  say "Starte Download im Hintergrund..." "Starting download in background..."
  do_download_background "$SELECTED_ARCHIVE"
  echo ""
  say "Download wurde gestartet." "Download started."
  say "Verwende Option 7), um den Fortschritt zu sehen." "Use option 7) to watch progress."
  echo ""
}

# ====== PROGRESS ======
show_progress() {
  { clear 2>/dev/null || printf '\033c'; } || true
  echo "=========================================="
  say "         Fortschritt Live-Anzeige" "         Live progress view"
  echo "=========================================="
  echo ""

  if ! is_running; then
    say "Kein Vorgang läuft aktuell." "No job is currently running."
    echo ""
    if [[ -f "$STATUS_FILE" ]]; then
      local last_status
      last_status="$(get_status)"
      say "Letzter Status: ${last_status}" "Last status: ${last_status}"
    fi
    echo ""
    if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to return..." _ || true
    else read -rp "Drücke Enter um zurückzukehren..." _ || true; fi
    return 0
  fi

  if [[ "${UI_LANG}" == "en" ]]; then echo "CTRL+C to stop viewing (job keeps running!)"
  else echo "STRG+C zum Beenden der Anzeige (Vorgang läuft weiter!)"; fi
  echo ""

  filter_log() {
    awk '
      BEGIN{skip=0}
      /^Traceback \(most recent call last\):/ {skip=1; next}
      skip && NF==0 {skip=0; next}
      skip {next}
      /^[[:space:]]+File ".*", line [0-9]+, in / {next}
      /borg\.helpers\.process\.SigTerm/ {next}
      /BrokenPipeError: \[Errno 32\] Broken pipe/ {next}
      {print}
    '
  }

  slice_to_last_worker() {
    awk '
      { lines[NR]=$0 }
      /^Worker Start \((Upload|Download)\):/ { last=NR }
      END{
        if (NR==0) exit
        start=(last>0?(last>1?last-1:last):(NR>50?NR-49:1))
        for (i=start;i<=NR;i++) print lines[i]
      }
    ' "$LOG_FILE"
  }

  cleanup() { trap - INT TERM; }
  trap cleanup INT TERM

  while is_running; do
    { clear 2>/dev/null || printf '\033c'; } || true
    echo "=========================================="
    say "         Fortschritt Live-Anzeige" "         Live progress view"
    echo "=========================================="
    echo ""
    if [[ "${UI_LANG}" == "en" ]]; then echo "CTRL+C to stop viewing (job keeps running!)"
    else echo "STRG+C zum Beenden der Anzeige (Vorgang läuft weiter!)"; fi
    echo ""
    say "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    echo "=========================================="
    say "Live-Log (aktueller Lauf, max. 80 Zeilen):" "Live log (current run, max. 80 lines):"
    echo "=========================================="

    if [[ -f "$LOG_FILE" ]]; then
      slice_to_last_worker | filter_log | tail -n 80
    else
      say "(Kein Log vorhanden)" "(No log present)"
    fi

    sleep 2
  done

  echo ""
  echo "=========================================="
  say "Vorgang abgeschlossen!" "Job finished!"
  say "Finaler Status: $(get_status)" "Final status: $(get_status)"
  echo "=========================================="
  echo ""
  if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to return..." _ || true
  else read -rp "Drücke Enter um zurückzukehren..." _ || true; fi
}

# ====== LIST / INFO / DELETE / STOP ======
do_list() { list_archives; }

do_info() {
  say "Repository-Informationen:" "Repository information:"
  echo ""
  if ! borg info --lock-wait 1 "${REPO}"; then
    say "Hinweis: Repository ist derzeit gesperrt (laufender Upload/Download)." \
        "Note: Repository is currently locked (an upload/download is running)."
    say "Details, sobald der Vorgang fertig ist. Zwischenstand unter 7) Progress." \
        "Details once the job finishes. Check interim status via option 7) Progress."
    return 1
  fi
  echo ""
  echo "------------------------------------------"
  list_archives
}

do_delete() {
  if is_running; then
    say "Ein Vorgang läuft, Löschen nicht möglich." "A job is running; delete not possible."
    return 1
  fi
  say "Archiv aus Repository löschen" "Delete archive from repository"
  echo ""
  local SELECTED_ARCHIVE
  SELECTED_ARCHIVE="$(select_archive)"
  echo ""
  say "WARNUNG: Archiv wird permanent gelöscht!" "WARNING: Archive will be deleted permanently!"
  say "       Archiv: ${SELECTED_ARCHIVE}" "       Archive: ${SELECTED_ARCHIVE}"
  echo ""
  if ! prompt_yes_no "Wirklich löschen?" "Really delete?"; then
    say "Abgebrochen" "Cancelled"
    return 0
  fi
  echo ""
  say "Lösche Archiv..." "Deleting archive..."
  borg delete "${REPO}::${SELECTED_ARCHIVE}"
  echo ""
  say "Gebe Speicherplatz frei (compact)..." "Reclaiming space (compact)..."
  borg compact "${REPO}"
  say "Archiv gelöscht: ${SELECTED_ARCHIVE}" "Deleted archive: ${SELECTED_ARCHIVE}"
}

do_stop() {
  if ! is_running; then
    say "Kein Vorgang läuft." "No job is running."
    return 0
  fi
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    say "PID-Datei leer oder fehlt – nichts zu stoppen." "PID file empty or missing — nothing to stop."
    rm -f "$PID_FILE"
    return 0
  fi
  say "Stoppe laufenden Vorgang (PID: $pid) und Kindprozesse..." \
      "Stopping running job (PID: $pid) and child processes..."
  if ! prompt_yes_no "Wirklich stoppen?" "Really stop?"; then
    say "Abbruch." "Aborted."
    return 0
  fi
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill  -TERM "$pid" 2>/dev/null || true
  sleep 1
  if ps -p "$pid" >/dev/null || pgrep -P "$pid" >/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill  -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
  set_status "GESTOPPT: Manuell abgebrochen"
  say "Vorgang gestoppt." "Job stopped."
  if ! is_running; then
    borg break-lock "${REPO}" >/dev/null 2>&1 || true
  fi
}

# ====== MENU ======
show_menu() {
  { clear 2>/dev/null || printf '\033c'; } || true
  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║        BorgBase Backup Manager                ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""
  echo "Repository: ${REPO}"
  echo "Lokal:      ${SRC_DIR}"
  echo ""
  if is_running; then
    say "STATUS: Vorgang läuft!" "STATUS: Job running!"
    echo "        $(get_status)"
  else
    say "STATUS: Bereit" "STATUS: Ready"
    [[ -f "$STATUS_FILE" ]] && say "        Letzter Status: $(get_status)" "        Last status: $(get_status)"
  fi
  echo ""
  say "1) Upload   - Neuestes lokales Backup hochladen" "1) Upload   - Upload latest local backup"
  say "2) Download - Backup von BorgBase herunterladen" "2) Download - Download backup from BorgBase"
  say "3) List     - Alle Archive anzeigen"             "3) List     - Show all archives"
  say "4) Info     - Repository-Informationen"          "4) Info     - Repository information"
  say "5) Delete   - Archiv löschen"                    "5) Delete   - Delete archive"
  say "6) Stop     - Laufenden Vorgang abbrechen"       "6) Stop     - Stop running job"
  say "7) Progress - Fortschritt anzeigen (Live)"       "7) Progress - Show live progress"
  say "8) Exit"                                        "8) Exit"
  echo ""
}

# ====== MAIN ======
choose_language
detect_src_dir || { say "FEHLER: Kein gültiges Backup-Verzeichnis gefunden. Bitte mounten/Pfad prüfen." "ERROR: No valid backup directory found. Please mount/check path."; exit 1; }
setup_borg_env

# CLI entrypoints
if [[ $# -gt 0 ]]; then
  case "$1" in
    upload)   if preflight_space_check; then do_upload_background; else say "Upload NICHT gestartet (Preflight fehlgeschlagen)." "Upload NOT started (preflight failed)."; exit 1; fi ;;
    download) do_download_background "${2:?ARCHIV angeben / specify ARCHIVE}";;
    list)     do_list ;;
    info)     do_info ;;
    delete)   shift; borg delete "${REPO}::${1:?ARCHIV angeben / specify ARCHIVE}" && borg compact "${REPO}" ;;
    stop)     do_stop ;;
    *) say "Verwendung: $0 [upload|download ARCHIV|list|info|delete ARCHIV|stop]" \
           "Usage: $0 [upload|download ARCHIVE|list|info|delete ARCHIVE|stop]"; exit 1 ;;
  esac
  exit 0
fi

# Interactive menu loop
while true; do
  show_menu
  if [[ "${UI_LANG}" == "en" ]]; then
    if ! read -rp "Choice (1-8): " choice; then echo "No input (EOF) — exiting."; exit 0; fi
  else
    if ! read -rp "Auswahl (1-8): " choice; then echo "Keine Eingabe erkannt (EOF) – beende."; exit 0; fi
  fi
  case "${choice:-}" in
    1) do_upload;   if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    2) do_download; if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    3) { clear 2>/dev/null || printf '\033c'; } || true; do_list; if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    4) { clear 2>/dev/null || printf '\033c'; } || true; do_info; if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    5) { clear 2>/dev/null || printf '\033c'; } || true; do_delete; if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    6) do_stop;     if [[ "${UI_LANG}" == "en" ]]; then read -rp "Press Enter to continue..." _ || true; else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    7) show_progress ;;
    8) if [[ "${UI_LANG}" == "en" ]]; then echo "Goodbye!"; else echo "Auf Wiedersehen!"; fi; exit 0 ;;
    *) if [[ "${UI_LANG}" == "en" ]]; then echo "Invalid selection"; else echo "Ungültige Auswahl"; fi; sleep 1 ;;
  esac
done
