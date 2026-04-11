#!/usr/bin/env bash
# BorgBase Backup Manager v1.8.6
#
# Features / Fixes:
# - SECURITY FIX: Uses BORG_PASSCOMMAND to prevent environment leak
# - SPACE OPTIMIZATION: Runs Prune/Compact BEFORE Create to free up space first.
# - SMART PRUNE: Different retention policies for Panzerbackup vs. Data backups
# - INTERACTIVE CLEANUP: Manual selection with immediate deletion
# - AUTO-DETECT: Automatically finds newest mounted Panzerbackup
# - INTERACTIVE PRUNE: Shows archives before deletion for safety
# - UI: Always handles DE/EN selection, better progress output.
# - ROBUSTNESS: Better error handling and connection testing.
# - BUGFIX: Fixed crash on missing .env file.
# - BUGFIX: Fixed crash on connection test failure
# - BUGFIX: Fixed confusing confirmation when no archives selected
# - BUGFIX: Upload now continues when user skips manual deletion
# - BUGFIX: Fixed placeholder replacement in archive names
# - BUGFIX: Fixed {hostname}/{date} substitution using sed (bash brace issue)
# - IMPROVED: Clear log messages after upload/download
# - IMPROVED: AUTO_ACCEPT_HOSTKEY=yes by default (ssh-keyscan on first connect)
# - FIXED: Passphrase file is stored in plaintext but protected via chmod 600;
#          wizard text now correctly states this instead of claiming encryption.
#
# Requirements:
# bash >= 4, borg >= 1.2, ssh, findmnt(optional), ssh-keygen(optional), ssh-keyscan(optional)
set -euo pipefail
set -E
trap 'rc=$?; echo "ERROR at line $LINENO: $BASH_COMMAND (rc=$rc)" >&2; exit $rc' ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# -------------------- Colors --------------------
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; NC=$'\e[0m'
    BOLD=$'\e[1m'
else
    R=""; G=""; Y=""; B=""; C=""; NC=""
    BOLD=""
fi

# -------------------- UI constants --------------------
APP_NAME="BorgBase Backup Manager"
APP_VERSION="v1.8.6"

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
PRUNE_NEEDED_FLAG="${RUNTIME_DIR}/borgbase-prune-needed"

# -------------------- Defaults --------------------
UI_LANG="${UI_LANG:-}"
REPO="${REPO:-ssh://user@user.repo.borgbase.com/./repo}"
SRC_DIR="${SRC_DIR:-}"
SSH_KEY="${SSH_KEY:-}"
PREFERRED_KEY_HINT="${PREFERRED_KEY_HINT:-vorta}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
LOG_FILE="${LOG_FILE:-$DEFAULT_STATE_DIR/borgbase-manager.log}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-$DEFAULT_PASSPHRASE_FILE}"
SSH_KEY_PASSPHRASE_FILE="${SSH_KEY_PASSPHRASE_FILE:-$DEFAULT_SSHKEY_PASSPHRASE_FILE}"
PRUNE="${PRUNE:-yes}"
KEEP_LAST="${KEEP_LAST:-14}"
KEEP_LAST_PANZERBACKUP="${KEEP_LAST_PANZERBACKUP:-1}"
PANZERBACKUP_ARCHIVE_NAME="${PANZERBACKUP_ARCHIVE_NAME:-panzerbackup-{hostname}-{date}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
BORG_LOCK_WAIT="${BORG_LOCK_WAIT:-60}"
BORG_TEST_LOCK_WAIT="${BORG_TEST_LOCK_WAIT:-1}"
# CHANGED: default is now "yes" so first-time connections work automatically
AUTO_ACCEPT_HOSTKEY="${AUTO_ACCEPT_HOSTKEY:-yes}"
AUTO_TEST_SSH="${AUTO_TEST_SSH:-yes}"
AUTO_TEST_REPO="${AUTO_TEST_REPO:-yes}"
INHIBIT_SLEEP="${INHIBIT_SLEEP:-yes}"          # prevents sleep/idle while worker runs (systemd-inhibit)
INHIBIT_WHAT="${INHIBIT_WHAT:-sleep:idle}"
INHIBIT_MODE="${INHIBIT_MODE:-block}"
INHIBIT_WHY="${INHIBIT_WHY:-BorgBase Backup Manager}"

BORG_CHECKPOINT_INTERVAL="${BORG_CHECKPOINT_INTERVAL:-300}"   # seconds (helps survive interruptions)
PRUNE_BEFORE_CREATE="${PRUNE_BEFORE_CREATE:-yes}"             # unattended cleanup before create

# -------------------- Load config --------------------
load_env() {
    # Fix: Use if-statements to avoid set -e crash if file is missing
    # shellcheck disable=SC1090
    if [[ -r "$ENV_FILE" ]]; then
        source "$ENV_FILE"
    fi
    if [[ -r "./.env" ]]; then
        # shellcheck disable=SC1091
        source "./.env"
    fi
}

# -------------------- i18n --------------------
say() { local de="$1" en="$2"; [[ "${UI_LANG:-de}" == "en" ]] && echo -e "$en" || echo -e "$de"; }

pause() {
    local msg="${1:-}"
    [[ -n "$msg" ]] && read -r -p "$msg" _ || read -r -p "" _
}

# -------------------- Status (JOB + CONN) --------------------
set_job_status() { echo "$1" > "$JOB_STATUS_FILE"; }
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
        rm -f "$JOB_STATUS_FILE" "$CONN_STATUS_FILE" "$START_FILE" "$PRUNE_NEEDED_FLAG" 2>/dev/null || true
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

# -------------------- Template placeholder replacement --------------------
replace_placeholder() {
    local template="$1"
    local placeholder="$2"
    local value="$3"
    printf '%s' "$template" | sed -E "s|\{${placeholder}[-_]?\}|${value}|g"
}

# -------------------- Archive name generation (robust) --------------------
sanitize_for_archive_component() {
    local s="${1:-}"
    s="${s// /_}"
    s="$(printf '%s' "$s" | tr -cs 'A-Za-z0-9._+-' '_' | sed -E 's/^_+//; s/_+$//')"
    [[ -n "$s" ]] || s="unknown"
    echo "$s"
}

sanitize_archive_name() {
    local name="${1:-}"
    name="${name//::/_}"
    name="${name//\//_}"
    name="${name//\\/__}"
    name="${name//\{/_}"
    name="${name//\}/_}"
    name="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._+-' '_' | sed -E 's/^_+//; s/_+$//')"
    [[ -n "$name" ]] || name="backup-unknown-$(date +%Y-%m-%d-%H%M%S)"
    echo "$name"
}

normalize_panzer_template() {
    local t="${1:-}"
    t="$(printf '%s' "$t" | sed -E 's/\{hostname[-_ ]*\{date\}\}/\{hostname\}-\{date\}/g')"
    echo "$t"
}

build_panzer_archive_name() {
    local src_dir="$1"
    local host ts template name
    host="$(extract_hostname_from_panzerbackup "$src_dir" 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
    host="$(sanitize_for_archive_component "$host")"
    ts="$(date +%Y-%m-%d-%H%M%S)"

    template="$(normalize_panzer_template "${PANZERBACKUP_ARCHIVE_NAME:-panzerbackup-{hostname}-{date}}")"
    name="$template"

    if [[ "$name" =~ \{hostname[-_]?\} ]]; then
        name="$(replace_placeholder "$name" "hostname" "$host")"
    else
        name="${name}-${host}"
    fi

    if [[ "$name" =~ \{date[-_]?\} ]]; then
        name="$(replace_placeholder "$name" "date" "$ts")"
    else
        name="${name}-${ts}"
    fi

    if [[ "$name" == *"{"* || "$name" == *"}"* ]]; then
        name="panzerbackup-${host}-${ts}"
    fi

    echo "$(sanitize_archive_name "$name")"
}

build_data_archive_name() {
    local host ts
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
    host="$(sanitize_for_archive_component "$host")"
    ts="$(date +%Y-%m-%d-%H%M%S)"
    echo "$(sanitize_archive_name "${host}-${ts}")"
}

# -------------------- Repo parsing --------------------
_repo_authority() { local r="$1"; r="${r#ssh://}"; r="${r%%/*}"; echo "$r"; }
_repo_path() { local r="$1"; r="${r#ssh://}"; r="${r#*@}"; r="${r#*/}"; echo "/$r"; }
_user_from_repo() { local a; a="$(_repo_authority "$1")"; echo "${a%%@*}"; }
_host_from_repo() { local a hostport; a="$(_repo_authority "$1")"; hostport="${a#*@}"; echo "${hostport%%:*}"; }
_port_from_repo() { local a hostport; a="$(_repo_authority "$1")"; hostport="${a#*@}"; if [[ "$hostport" == *:* ]]; then echo "${hostport##*:}"; else echo ""; fi; }
_knownhosts_host_from_repo() { local h p; h="$(_host_from_repo "$1")"; p="$(_port_from_repo "$1")"; if [[ -n "$p" ]]; then echo "[${h}]:${p}"; else echo "$h"; fi; }
_ssh_port_opt_from_repo() { local p; p="$(_port_from_repo "$1")"; if [[ -n "$p" ]]; then echo "-p $p"; else echo ""; fi; }

# -------------------- SSH Agent Management --------------------
start_ssh_agent_if_needed() {
    if [[ -n "${SSH_AGENT_PID:-}" ]] && ps -p "$SSH_AGENT_PID" >/dev/null 2>&1; then
        return 0
    fi
    eval "$(ssh-agent -s)" >/dev/null 2>&1
    return 0
}

load_ssh_key_to_agent() {
    [[ -z "${SSH_KEY:-}" ]] && return 0
    [[ ! -r "$SSH_KEY" ]] && return 0
    
    if ssh-add -l 2>/dev/null | grep -q "$SSH_KEY"; then
        return 0
    fi
    
    if [[ -f "$SSH_KEY_PASSPHRASE_FILE" && -r "$SSH_KEY_PASSPHRASE_FILE" ]]; then
        cat "$SSH_KEY_PASSPHRASE_FILE" | SSH_ASKPASS_REQUIRE=never ssh-add "$SSH_KEY" 2>/dev/null || {
            DISPLAY=:0 SSH_ASKPASS="$(which ssh-askpass 2>/dev/null || echo /bin/false)" \
                ssh-add "$SSH_KEY" < "$SSH_KEY_PASSPHRASE_FILE" 2>/dev/null || return 1
        }
    else
        ssh-add "$SSH_KEY" 2>/dev/null || {
            echo -e "${Y}$(say 'SSH-Key hat eine Passphrase.' 'SSH key has a passphrase.')${NC}"
            echo "$(say 'Geben Sie die SSH-Key-Passphrase ein:' 'Enter SSH key passphrase:')"
            ssh-add "$SSH_KEY" || return 1
        }
    fi
    return 0
}

# -------------------- Passphrase handling --------------------
# NOTE: The passphrase file is stored as PLAINTEXT, protected only by
# file permissions (chmod 600). It is NOT encrypted. Access requires
# knowing the filesystem path and having the user's/root's credentials.
load_repo_passphrase() {
    if [[ -n "${PASSPHRASE_FILE:-}" && -f "$PASSPHRASE_FILE" ]]; then
        # Ensure permissions are tight every time we read it
        chmod 600 "$PASSPHRASE_FILE" 2>/dev/null || true
        unset BORG_PASSPHRASE
        export BORG_PASSCOMMAND="cat $(printf '%q' "$PASSPHRASE_FILE")"
        return 0
    fi
    if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
        export BORG_PASSPHRASE
        return 0
    fi
    return 1
}

# -------------------- Borg env setup --------------------
setup_borg_env() {
    ensure_logfile_writable
    SSH_KNOWN_HOSTS="$(expand_path "$SSH_KNOWN_HOSTS")"
    mkdir -p "$(dirname -- "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
    touch "$SSH_KNOWN_HOSTS" 2>/dev/null || true
    
    resolve_ssh_key || true
    # Always run ensure_known_hosts so new hosts are added automatically
    ensure_known_hosts
    
    if [[ -n "${SSH_KEY:-}" && -r "${SSH_KEY}" ]]; then
        start_ssh_agent_if_needed
        if ! load_ssh_key_to_agent; then
            echo -e "${R}$(say 'FEHLER: SSH-Key konnte nicht geladen werden.' 'ERROR: Could not load SSH key.')${NC}"
            return 1
        fi
    fi
    
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
        set_conn_status "$(say 'FEHLER: Repo-Passphrase fehlt.' 'ERROR: Missing repo passphrase.')"
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
        p="${p%\"}"; p="${p#\"}"; p="$(expand_path "$p")"
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
        while IFS= read -r -d '' f; do keys+=( "$f" ); done < <(find "$d" -maxdepth 1 -type f -name "*${PREFERRED_KEY_HINT}*" -print0 2>/dev/null || true)
    fi
    
    local common=(id_ed25519 id_ed25519_* id_rsa id_ecdsa id_dsa)
    local c
    for c in "${common[@]}"; do
        while IFS= read -r -d '' f; do keys+=( "$f" ); done < <(find "$d" -maxdepth 1 -type f -name "$c" -print0 2>/dev/null || true)
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
    if [[ -n "$k" && -r "$k" ]]; then SSH_KEY="$k"; return 0; fi
    
    k="$(detect_ssh_key_standard 2>/dev/null || true)"
    if [[ -n "$k" && -r "$k" ]]; then SSH_KEY="$k"; return 0; fi
    
    SSH_KEY=""
    return 0
}

# -------------------- known_hosts helper --------------------
# CHANGED: AUTO_ACCEPT_HOSTKEY defaults to "yes".
# On first connection to a new host, ssh-keyscan fetches and stores the
# host key automatically. After that, StrictHostKeyChecking=yes verifies it.
# This means: first connection = trust on first use (TOFU).
# Subsequent connections = strict verification (no MITM possible after first use).
ensure_known_hosts() {
    [[ "${AUTO_ACCEPT_HOSTKEY}" == "yes" ]] || return 0
    command -v ssh-keygen >/dev/null 2>&1 || return 0
    command -v ssh-keyscan >/dev/null 2>&1 || return 0
    
    local plain_host port host_for_kh
    plain_host="$(_host_from_repo "${REPO}")"
    port="$(_port_from_repo "${REPO}")"
    host_for_kh="$(_knownhosts_host_from_repo "${REPO}")"
    
    mkdir -p "$(dirname -- "$SSH_KNOWN_HOSTS")" 2>/dev/null || true
    touch "$SSH_KNOWN_HOSTS" 2>/dev/null || true
    
    # Already known? Nothing to do.
    if ssh-keygen -F "$host_for_kh" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
        return 0
    fi
    
    say "SSH: Hostkey für ${host_for_kh} fehlt – wird automatisch eingetragen (TOFU)..." \
        "SSH: Missing hostkey for ${host_for_kh} – adding automatically (TOFU)..."
    
    local keyscan_out=""
    if [[ -n "$port" ]]; then
        keyscan_out="$(timeout "${SSH_CONNECT_TIMEOUT}" ssh-keyscan -H -p "$port" -t ed25519,ecdsa,rsa "$plain_host" 2>/dev/null || true)"
    else
        keyscan_out="$(timeout "${SSH_CONNECT_TIMEOUT}" ssh-keyscan -H -t ed25519,ecdsa,rsa "$plain_host" 2>/dev/null || true)"
    fi
    
    if [[ -z "$keyscan_out" ]]; then
        echo -e "${R}$(say "FEHLER: ssh-keyscan für ${plain_host} fehlgeschlagen. Hostkey konnte nicht abgerufen werden." \
            "ERROR: ssh-keyscan for ${plain_host} failed. Could not retrieve host key.")${NC}"
        return 1
    fi
    
    echo "$keyscan_out" >> "$SSH_KNOWN_HOSTS"
    echo -e "${G}$(say "✓ Hostkey für ${host_for_kh} eingetragen." "✓ Host key for ${host_for_kh} added.")${NC}"
    return 0
}

# -------------------- Panzerbackup Auto-Detection --------------------
detect_newest_panzerbackup() {
    local media_base="/media/$USER"
    [[ -d "$media_base" ]] || return 1
    
    local dirs=()
    
    while IFS= read -r -d '' dir; do
        dirs+=( "$dir" )
    done < <(find "$media_base" -maxdepth 2 -type d -iname "*panzerbackup*" -print0 2>/dev/null || true)
    
    [[ ${#dirs[@]} -eq 0 ]] && return 1
    
    local newest_time=0
    local newest_dir=""
    
    for dir in "${dirs[@]}"; do
        local files=()
        while IFS= read -r -d '' f; do
            files+=( "$f" )
        done < <(find "$dir" -maxdepth 1 -type f \( -name "panzer_*.img.zst.gpg" -o -name "panzer_*.img.zst" \) ! -name "*.part" -print0 2>/dev/null || true)
        
        for f in "${files[@]}"; do
            local mtime
            mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            if (( mtime > newest_time )); then
                newest_time=$mtime
                newest_dir="$dir"
            fi
        done
    done
    
    [[ -n "$newest_dir" ]] && { echo "$newest_dir"; return 0; }
    return 1
}

# -------------------- Extract hostname from Panzerbackup files --------------------
extract_hostname_from_panzerbackup() {
    local dir="$1"
    [[ ! -d "$dir" ]] && return 1
    
    local newest_file=""
    local newest_time=0
    
    while IFS= read -r -d '' f; do
        local mtime
        mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if (( mtime > newest_time )); then
            newest_time=$mtime
            newest_file="$f"
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name "panzer_*.img.zst.gpg" -o -name "panzer_*.img.zst" \) ! -name "*.part" -print0 2>/dev/null || true)
    
    [[ -z "$newest_file" ]] && return 1
    
    local basename
    basename="$(basename "$newest_file")"
    
    if [[ "$basename" =~ ^panzer_(.+)-panzerbackup ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    elif [[ "$basename" =~ ^panzer_(.+)_panzerbackup ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    elif [[ "$basename" =~ ^panzer_([^_]+) ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    fi
    
    hostname 2>/dev/null || echo "unknown"
    return 0
}

# -------------------- Backup type detection --------------------
is_panzerbackup_source() {
    local dir="$1"
    [[ "$dir" =~ [Pp][Aa][Nn][Zz][Ee][Rr][Bb][Aa][Cc][Kk][Uu][Pp] ]] && return 0
    find "$dir" -maxdepth 1 -type f \( -name "panzer_*.img.zst.gpg" -o -name "panzer_*.img.zst" \) ! -name "*.part" -print0 2>/dev/null | grep -qz . && return 0
    return 1
}

detect_src_dir() {
    local detected_dir
    detected_dir="$(detect_newest_panzerbackup 2>/dev/null || true)"
    
    if [[ -n "$detected_dir" && -d "$detected_dir" ]]; then
        echo -e "${G}$(say '✓ Gemountetes Panzerbackup gefunden!' '✓ Mounted Panzerbackup found!')${NC}"
        echo "  → $detected_dir"
        SRC_DIR="$detected_dir"
        return 0
    fi
    
    if [[ -n "$SRC_DIR" ]]; then
        SRC_DIR="$(expand_path "$SRC_DIR")"
        [[ -d "$SRC_DIR" ]] || { 
            echo -e "${R}$(say "Konfiguriertes SRC_DIR existiert nicht: $SRC_DIR" "Configured SRC_DIR does not exist: $SRC_DIR")${NC}"
            return 1
        }
        return 0
    fi
    
    local possible=("$HOME/panzerbackup" "/home/$USER/panzerbackup")
    for d in "${possible[@]}"; do
        if [[ -d "$d" ]]; then SRC_DIR="$d"; return 0; fi
    done
    
    echo -e "${R}$(say 'FEHLER: Kein Panzerbackup-Verzeichnis gefunden!' 'ERROR: No Panzerbackup directory found!')${NC}"
    echo ""
    echo "$(say 'Bitte stellen Sie sicher, dass:' 'Please ensure that:')"
    echo "  $(say '1) Ein USB-Stick mit Panzerbackup gemountet ist (unter /media/'"$USER"')' '1) A USB stick with Panzerbackup is mounted (under /media/'"$USER"')')"
    echo "  $(say '2) Oder konfigurieren Sie SRC_DIR manuell' '2) Or configure SRC_DIR manually')"
    echo ""
    return 1
}

# -------------------- Borg version compatibility --------------------
BORG_VERSION_CACHE=""

detect_borg_version() {
    if [[ -n "$BORG_VERSION_CACHE" ]]; then echo "$BORG_VERSION_CACHE"; return 0; fi
    local version_output
    version_output="$(borg --version 2>&1 || true)"
    if [[ "$version_output" =~ borg[[:space:]]([0-9]+)\.([0-9]+) ]]; then
        local major="${BASH_REMATCH[1]}"
        BORG_VERSION_CACHE="$major"
        echo "$major"
        return 0
    fi
    BORG_VERSION_CACHE="1"
    echo "1"
}

borg_list_cmd() {
    local version
    version="$(detect_borg_version)"
    if [[ "$version" == "2" ]]; then echo "rlist"; else echo "list"; fi
}

borg_with_ssh() { setup_borg_env || return 1; borg "$@"; }

# -------------------- Connection test --------------------
test_ssh_auth() {
    [[ "${AUTO_TEST_SSH}" == "yes" ]] || return 0
    local host user out port_opt
    host="$(_host_from_repo "${REPO}")"
    user="$(_user_from_repo "${REPO}")"
    port_opt="$(_ssh_port_opt_from_repo "${REPO}")"
    
    out="$(ssh -T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" ${port_opt} ${SSH_KEY:+-i "$SSH_KEY" -o IdentitiesOnly=yes} "${user}@${host}" -- borg --version 2>&1 || true)"
    echo "$out" >> "$LOG_FILE" 2>/dev/null || true
    
    if echo "$out" | grep -qiE 'host key verification failed|remote host identification has changed'; then
        set_conn_status "$(say 'FEHLER: SSH Hostkey Problem. Bitte known_hosts prüfen.' 'ERROR: SSH hostkey problem. Please check known_hosts.')"
        echo -e "${R}$(say 'FEHLER: SSH Hostkey-Verifikation fehlgeschlagen!' 'ERROR: SSH host key verification failed!')${NC}"
        echo -e "${Y}$(say "  → Tipp: Führe manuell aus: ssh-keyscan -t ed25519 ${host} >> ${SSH_KNOWN_HOSTS}" \
            "  → Hint: Run manually: ssh-keyscan -t ed25519 ${host} >> ${SSH_KNOWN_HOSTS}")${NC}"
        return 1
    fi
    if echo "$out" | grep -qiE 'permission denied|no supported authentication methods'; then
        set_conn_status "$(say 'FEHLER: SSH Auth fehlgeschlagen.' 'ERROR: SSH auth failed.')"; return 1
    fi
    echo "$out" | grep -qiE '^borg ' || { set_conn_status "$(say 'FEHLER: SSH Test fehlgeschlagen.' 'ERROR: SSH test failed.')"; return 1; }
    return 0
}

test_borg_repo() {
    [[ "${AUTO_TEST_REPO}" == "yes" ]] || return 0
    local out rc=0
    out="$(borg info --lock-wait "${BORG_TEST_LOCK_WAIT}" "${REPO}" 2>&1)" || rc=$?
    echo "$out" >> "$LOG_FILE" 2>/dev/null || true
    
    if (( rc == 0 )); then return 0; fi
    
    if echo "$out" | grep -qiE 'Failed to create/acquire the lock|lock\.exclusive|timeout'; then
        if is_running; then
            set_conn_status "$(say 'OK: Repo erreichbar (BUSY).' 'OK: Repo reachable (BUSY).')"
            return 0
        fi
        set_conn_status "$(say 'WARNUNG: Repo gesperrt (Lock-Timeout).' 'WARNING: Repo locked (timeout).')"
        return 2
    fi
    return 1
}

test_connection() {
    local conn_rc=0
    
    if ! setup_borg_env; then
        echo -e "${R}$(say 'Borg-Setup fehlgeschlagen.' 'Borg setup failed.')${NC}"
        return 1
    fi
    
    if ! test_ssh_auth; then
        echo -e "${R}$(say 'SSH-Authentifizierung fehlgeschlagen.' 'SSH authentication failed.')${NC}"
        return 1
    fi
    
    test_borg_repo || conn_rc=$?
    
    if (( conn_rc == 0 )); then
        set_conn_status "$(say 'OK: Verbindung erfolgreich hergestellt.' 'OK: Connection established successfully.')"
        echo -e "${G}$(say '✓ Verbindung erfolgreich hergestellt.' '✓ Connection established successfully.')${NC}"
        [[ -n "${SSH_KEY:-}" ]] && echo "  SSH_KEY: $SSH_KEY"
        echo "  REPO: $REPO"
        return 0
    elif (( conn_rc == 2 )); then
        echo -e "${Y}$(say 'Repo ist derzeit gesperrt (Lock), aber erreichbar.' 'Repo is currently locked but reachable.')${NC}"
        return 0
    else
        set_conn_status "$(say 'FEHLER: Repo-Verbindung fehlgeschlagen.' 'ERROR: Repo connection failed.')"
        echo -e "${R}$(say 'Repo-Verbindung fehlgeschlagen.' 'Repo connection failed.')${NC}"
        return 1
    fi
}

# -------------------- Smart Prune Logic --------------------
get_archive_prefix_for_source() {
    local src_dir="$1"
    local is_panzer=0
    
    is_panzerbackup_source "$src_dir" && is_panzer=1
    
    if (( is_panzer )); then
        local hostname_extracted
        hostname_extracted="$(extract_hostname_from_panzerbackup "$src_dir" 2>/dev/null || true)"
        [[ -z "$hostname_extracted" ]] && hostname_extracted="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
        hostname_extracted="$(sanitize_for_archive_component "$hostname_extracted")"
        echo "panzerbackup-${hostname_extracted}"
        return 0
    else
        local hostname_clean
        hostname_clean="$(hostname 2>/dev/null || echo "unknown")"
        echo "$hostname_clean"
        return 0
    fi
}

# -------------------- Interactive manual archive selection with IMMEDIATE deletion --------------------
interactive_archive_selection() {
    echo ""
    echo -e "${C}$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')${NC}"
    echo -e "${C}$(say '  MANUELLE ARCHIV-AUSWAHL FÜR LÖSCHUNG' '  MANUAL ARCHIVE SELECTION FOR DELETION')${NC}"
    echo -e "${C}$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')${NC}"
    echo ""
    
    local list_cmd
    list_cmd="$(borg_list_cmd)"
    local all_archives=()
    mapfile -t all_archives < <(borg_with_ssh "$list_cmd" --short "$REPO" 2>/dev/null | sort -r)
    
    if (( ${#all_archives[@]} == 0 )); then
        echo -e "${G}$(say '✓ Keine Archive im Repository vorhanden' '✓ No archives in repository')${NC}"
        echo ""
        return 0
    fi
    
    echo "$(say 'Alle Archive im Repository:' 'All archives in repository:')"
    echo ""
    
    local i
    for i in "${!all_archives[@]}"; do
        local num=$((i+1))
        printf "  %2d) %s\n" "$num" "${all_archives[$i]}"
    done
    
    echo ""
    echo -e "${Y}$(say 'Geben Sie die Nummern der zu löschenden Archive ein (z.B. 1 3 5 oder 1-3)' 'Enter numbers of archives to delete (e.g. 1 3 5 or 1-3)')${NC}"
    echo "$(say 'Oder drücken Sie Enter um ohne Löschen fortzufahren' 'Or press Enter to continue without deleting')"
    echo ""
    
    local selection
    read -r -p "$(say 'Archive zum Löschen: ' 'Archives to delete: ')" selection
    
    if [[ -z "$selection" ]]; then
        echo "$(say 'Keine Archive zum Löschen ausgewählt. Upload wird fortgesetzt.' 'No archives selected for deletion. Upload will continue.')"
        return 0
    fi
    
    local to_delete=()
    local ranges=($selection)
    
    for range in "${ranges[@]}"; do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for ((n=start; n<=end; n++)); do
                if (( n >= 1 && n <= ${#all_archives[@]} )); then
                    to_delete+=( "${all_archives[$((n-1))]}" )
                fi
            done
        elif [[ "$range" =~ ^[0-9]+$ ]]; then
            local n="$range"
            if (( n >= 1 && n <= ${#all_archives[@]} )); then
                to_delete+=( "${all_archives[$((n-1))]}" )
            fi
        fi
    done
    
    mapfile -t to_delete < <(printf "%s\n" "${to_delete[@]}" | sort -u)
    
    if (( ${#to_delete[@]} == 0 )); then
        echo -e "${Y}$(say 'Keine gültigen Archive ausgewählt.' 'No valid archives selected.')${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${R}$(say 'Diese Archive werden GELÖSCHT:' 'These archives will be DELETED:')${NC}"
    for archive in "${to_delete[@]}"; do
        echo -e "  ${R}✗ $archive${NC}"
    done
    
    echo ""
    echo -e "${Y}$(say 'WARNUNG: Diese Aktion kann nicht rückgängig gemacht werden!' 'WARNING: This action cannot be undone!')${NC}"
    echo ""
    
    read -r -p "$(say 'Wirklich löschen? (JA zum Bestätigen): ' 'Really delete? (type YES to confirm): ')" confirm
    
    if [[ "$confirm" != "JA" && "$confirm" != "YES" ]]; then
        echo "$(say 'Löschvorgang abgebrochen.' 'Deletion cancelled.')"
        return 1
    fi
    
    echo ""
    echo "$(say '┌─ Lösche ausgewählte Archive... ───────────────────────┐' '┌─ Deleting selected archives... ────────────────────────┐')"
    echo ""
    
    local deleted_count=0
    local failed_count=0
    
    for archive in "${to_delete[@]}"; do
        echo -n "$(say "Lösche: $archive ... " "Deleting: $archive ... ")"
        if borg delete "${REPO}::${archive}" 2>&1 | tee -a "$LOG_FILE" >/dev/null; then
            echo -e "${G}✓ OK${NC}"
            deleted_count=$((deleted_count + 1))
        else
            echo -e "${R}✗ FEHLER${NC}"
            failed_count=$((failed_count + 1))
        fi
    done
    
    echo ""
    echo "$(say '└─────────────────────────────────────────────────────────┘' '└─────────────────────────────────────────────────────────┘')"
    echo ""
    
    if (( deleted_count > 0 )); then
        echo -e "${G}$(say "✓ $deleted_count Archive erfolgreich gelöscht" "✓ $deleted_count archives successfully deleted")${NC}"
    fi
    if (( failed_count > 0 )); then
        echo -e "${R}$(say "✗ $failed_count Archive konnten nicht gelöscht werden" "✗ $failed_count archives could not be deleted")${NC}"
    fi
    
    echo ""
    echo "$(say 'Gebe Speicherplatz frei (Compact)...' 'Freeing up space (Compact)...')"
    if borg compact "$REPO" 2>&1 | tee -a "$LOG_FILE"; then
        echo -e "${G}$(say '✓ Compact erfolgreich' '✓ Compact successful')${NC}"
    else
        echo -e "${Y}$(say '⚠ Compact fehlgeschlagen' '⚠ Compact failed')${NC}"
    fi
    
    echo ""
    return 0
}

show_prune_preview() {
    local src_dir="$1"
    local is_panzer=0
    
    is_panzerbackup_source "$src_dir" && is_panzer=1
    
    echo ""
    echo "$(say '┌─ WARNUNG: Löschen von alten Backups ──────────────────┐' '┌─ WARNING: Deleting old backups ────────────────────────┐')"
    echo "$(say '│ Diese Archive werden gelöscht: │' '│ These archives will be deleted: │')"
    echo "$(say '└─────────────────────────────────────────────────────────┘' '└─────────────────────────────────────────────────────────┘')"
    echo ""
    
    local archive_prefix
    archive_prefix="$(get_archive_prefix_for_source "$src_dir")" || return 1
    
    local list_cmd
    list_cmd="$(borg_list_cmd)"
    local all_archives=()
    mapfile -t all_archives < <(borg_with_ssh "$list_cmd" --short "$REPO" 2>/dev/null | sort -r)
    
    local matching_archives=()
    for archive in "${all_archives[@]}"; do
        if [[ "$archive" == "$archive_prefix"* ]]; then
            matching_archives+=( "$archive" )
        fi
    done
    
    local total=${#matching_archives[@]}
    local keep
    
    if (( is_panzer )); then
        keep=${KEEP_LAST_PANZERBACKUP:-1}
        echo -e "${B}$(say 'Backup-Typ: PANZERBACKUP' 'Backup type: PANZERBACKUP')${NC}"
        echo "$(say 'Präfix-Filter: '"$archive_prefix"'*' 'Prefix filter: '"$archive_prefix"'*')"
    else
        keep=${KEEP_LAST:-14}
        echo -e "${B}$(say 'Backup-Typ: DATENBACKUP' 'Backup type: DATA BACKUP')${NC}"
        echo "$(say 'Präfix-Filter: '"$archive_prefix"'-*' 'Prefix filter: '"$archive_prefix"'-*')"
    fi
    echo ""
    
    if (( total == 0 )); then
        echo -e "${Y}$(say '⚠ Keine passenden Archive gefunden' '⚠ No matching archives found')${NC}"
        echo ""
        echo "$(say 'Möchten Sie manuell Archive zum Löschen auswählen?' 'Do you want to manually select archives for deletion?')"
        read -r -p "$(say '(j/n): ' '(y/n): ')" manual_select
        
        if [[ "$manual_select" =~ ^[jJyY] ]]; then
            interactive_archive_selection
            return $?
        else
            echo "$(say 'Keine Archive werden gelöscht. Upload wird fortgesetzt.' 'No archives will be deleted. Upload will continue.')"
            return 0
        fi
    fi
    
    if (( total <= keep )); then
        echo -e "${G}$(say '✓ Keine Archive zum Löschen (nur '"$total"' vorhanden, behalte '"$keep"')' '✓ No archives to delete (only '"$total"' exist, keeping '"$keep"')')${NC}"
        echo ""
        echo "$(say 'Vorhandene Archive:' 'Existing archives:')"
        for archive in "${matching_archives[@]}"; do
            echo -e "  ${G}✓ $archive${NC}"
        done
        echo ""
        return 0
    fi
    
    local to_delete=$((total - keep))
    echo "$(say 'Gesamt: '"$total"' Archive | Behalten: '"$keep"' | Löschen: '"$to_delete" 'Total: '"$total"' archives | Keep: '"$keep"' | Delete: '"$to_delete")"
    echo ""
    
    echo "$(say 'BEHALTEN (neueste):' 'KEEPING (newest):')"
    for (( i=0; i<keep && i<total; i++ )); do
        echo -e "  ${G}✓ ${matching_archives[$i]}${NC}"
    done
    
    echo ""
    echo "$(say 'LÖSCHEN (älteste):' 'DELETING (oldest):')"
    for (( i=keep; i<total; i++ )); do
        echo -e "  ${R}✗ ${matching_archives[$i]}${NC}"
    done
    
    echo ""
    echo -e "${Y}$(say 'ACHTUNG: Diese Aktion kann nicht rückgängig gemacht werden!' 'CAUTION: This action cannot be undone!')${NC}"
    echo ""
    
    return 2
}

# -------------------- Upload/Download logic --------------------
show_upload_selection() {
    echo ""
    echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
    echo -e "${B}$(say 'Backup hochladen (Upload) - SMART PRUNE MODE' 'Upload Backup - SMART PRUNE MODE')${NC}"
    echo "$(say '═══════════════════════════════════════════════════════════' '═══════════════════════════════════════════════════════════')"
    echo ""
    
    if ! detect_src_dir; then
        return 1
    fi
    
    echo ""
    echo "$(say "Quellverzeichnis: $SRC_DIR" "Source directory: $SRC_DIR")"
    echo "$(say "Ziel-Repo: $REPO" "Target repo: $REPO")"
    
    local is_panzer=0
    is_panzerbackup_source "$SRC_DIR" && is_panzer=1
    
    if (( is_panzer )); then
        echo -e "${B}$(say "Backup-Typ: PANZERBACKUP (behalte ${KEEP_LAST_PANZERBACKUP} Archive)" "Backup type: PANZERBACKUP (keep ${KEEP_LAST_PANZERBACKUP} archives)")${NC}"
    else
        echo -e "${B}$(say "Backup-Typ: DATENBACKUP (behalte ${KEEP_LAST} Archive)" "Backup type: DATA BACKUP (keep ${KEEP_LAST} archives)")${NC}"
    fi
    
    echo ""
    echo -e "${Y}$(say "HINWEIS: Um Speicherplatz zu sparen, werden alte Backups ZUERST gelöscht." "NOTE: To save space, old backups are deleted FIRST.")${NC}"
    echo ""
    
    if [[ ! -d "$SRC_DIR" ]]; then
        echo -e "${R}$(say 'FEHLER: Quellverzeichnis existiert nicht!' 'ERROR: Source directory does not exist!')${NC}"
        return 1
    fi
    
    local size; size="$(du -sb "$SRC_DIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    echo "$(say "Größe: $(human_bytes "$size")" "Size: $(human_bytes "$size")")"
    echo ""
    
    read -r -p "$(say 'Dieses Verzeichnis für Upload verwenden? (j/n): ' 'Use this directory for upload? (y/n): ')" confirm
    if [[ ! "$confirm" =~ ^[jJyY] ]]; then
        echo "$(say 'Upload abgebrochen.' 'Upload cancelled.')"
        return 1
    fi
    
    return 0
}

do_upload_background() {
    if is_running; then
        echo -e "${Y}$(say '⚠ Es läuft bereits ein Job.' '⚠ A job is already running.')${NC}"
        return 1
    fi

    ensure_logfile_writable

    if ! detect_src_dir >/dev/null 2>&1; then
        echo -e "${R}$(say '✗ Kein gültiges Backup-Verzeichnis gefunden.' '✗ No valid backup directory found.')${NC}"
        return 1
    fi

    echo -e "${G}$(say 'Starte Upload im Hintergrund (detached)...' 'Starting upload in background (detached)...')${NC}"
    start_detached_worker upload --src-dir "$SRC_DIR"
}

# -------------------- Detached worker launcher --------------------
start_detached_worker() {
    local mode="${1:?mode}"
    shift || true

    ensure_logfile_writable

    nohup setsid "$0" --worker "$mode" "$@" </dev/null >/dev/null 2>&1 &
    local pid=$!

    echo "$pid" > "$PID_FILE"
    date +%s > "$START_FILE" 2>/dev/null || true
    set_job_status "$(say "JOB gestartet (PID: $pid)" "Job started (PID: $pid)")"
}

# -------------------- Worker: Upload (foreground implementation) --------------------
worker_upload() {
    local src_dir="${1:-$SRC_DIR}"

    ensure_logfile_writable
    echo "$$" > "$PID_FILE"
    date +%s > "$START_FILE" 2>/dev/null || true

    cleanup_worker_files() {
        rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
    }
    trap cleanup_worker_files EXIT

    set_job_status "$(say 'UPLOAD: Wird vorbereitet...' 'UPLOAD: Preparing...')"

    {
        echo ""
        echo "==================================================="
        echo "$(say 'UPLOAD GESTARTET' 'UPLOAD STARTED'): $(date)"
        echo "==================================================="
        echo "$(say "Quelle: ${src_dir}" "Source: ${src_dir}")"
        echo ""
    } | tee -a "$LOG_FILE"

    if ! setup_borg_env; then
        set_job_status "$(say 'UPLOAD: FEHLER – Borg-Setup fehlgeschlagen' 'UPLOAD: ERROR – Borg setup failed')"
        echo -e "${R}$(say '✗ FEHLER: Borg-Setup fehlgeschlagen' '✗ ERROR: Borg setup failed')${NC}" | tee -a "$LOG_FILE"
        return 1
    fi

    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        if detect_src_dir >/dev/null 2>&1; then
            src_dir="$SRC_DIR"
        fi
    fi
    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        set_job_status "$(say 'UPLOAD: FEHLER – Quelle nicht gefunden' 'UPLOAD: ERROR – source not found')"
        echo -e "${R}$(say '✗ FEHLER: Quellverzeichnis nicht gefunden' '✗ ERROR: Source directory not found')${NC}" | tee -a "$LOG_FILE"
        return 1
    fi

    local is_panzer="no"
    if is_panzerbackup_source "$src_dir"; then
        is_panzer="yes"
    fi

    local archive_prefix keep_setting prune_pattern archive_name
    archive_prefix="$(get_archive_prefix_for_source "$src_dir")"

    if [[ "$is_panzer" == "yes" ]]; then
        keep_setting="${KEEP_LAST_PANZERBACKUP:-3}"
        prune_pattern="${archive_prefix}-*"
    else
        keep_setting="${KEEP_LAST:-7}"
        prune_pattern="${archive_prefix}-*"
    fi

    if [[ "${PRUNE:-yes}" == "yes" ]] && { [[ "${PRUNE_BEFORE_CREATE:-yes}" == "yes" ]] || [[ -f "$PRUNE_NEEDED_FLAG" ]]; }; then
        rm -f "$PRUNE_NEEDED_FLAG" 2>/dev/null || true
        set_job_status "$(say 'UPLOAD: Prune/Compact (vorher)...' 'UPLOAD: Prune/Compact (pre)...')"
        echo "$(say '┌─ SMART-PRUNE (vor Upload) ────────────────────────────┐' '┌─ SMART PRUNE (before upload) ────────────────────────┐')" | tee -a "$LOG_FILE"
        echo "$(say "│ Pattern: ${prune_pattern}" "│ Pattern: ${prune_pattern}")" | tee -a "$LOG_FILE"
        echo "$(say "│ Keep last: ${keep_setting}" "│ Keep last: ${keep_setting}")" | tee -a "$LOG_FILE"
        echo "$(say '└───────────────────────────────────────────────────────┘' '└───────────────────────────────────────────────────────┘')" | tee -a "$LOG_FILE"

        borg prune --lock-wait "$BORG_LOCK_WAIT" --list --glob-archives "${prune_pattern}" --keep-last "${keep_setting}" "$REPO" 2>&1 | tee -a "$LOG_FILE" || true
        borg compact --lock-wait "$BORG_LOCK_WAIT" "$REPO" 2>&1 | tee -a "$LOG_FILE" || true
        echo "" | tee -a "$LOG_FILE"
    fi

    if [[ "$is_panzer" == "yes" ]]; then
        archive_name="$(build_panzer_archive_name "$src_dir")"
    else
        archive_name="$(build_data_archive_name)"
    fi

    set_job_status "$(say "UPLOAD: ${archive_name} läuft..." "UPLOAD: ${archive_name} running...")"

    echo "$(say '┌─ Erstelle neues Archiv ─────────────────────────────────┐' '┌─ Creating new archive ──────────────────────────────────┐')" | tee -a "$LOG_FILE"
    echo "$(say "│ Archiv-Name: ${archive_name}" "│ Archive name: ${archive_name}")" | tee -a "$LOG_FILE"
    echo "$(say "│ Quelle: ${src_dir}" "│ Source: ${src_dir}")" | tee -a "$LOG_FILE"
    echo "$(say '└─────────────────────────────────────────────────────────┘' '└─────────────────────────────────────────────────────────┘')" | tee -a "$LOG_FILE"

    local rc=0

    if [[ "$is_panzer" == "yes" ]]; then
        local latest_img base img sha sfd
        latest_img="$(ls -1t "${src_dir}"/panzer_*.img.zst.gpg 2>/dev/null | head -n1 || true)"
        if [[ -z "$latest_img" ]]; then
            set_job_status "$(say 'UPLOAD: FEHLER – Keine panzer_*.img.zst.gpg gefunden' 'UPLOAD: ERROR – No panzer_*.img.zst.gpg found')"
            echo -e "${R}$(say '✗ FEHLER: Keine panzer_*.img.zst.gpg gefunden' '✗ ERROR: No panzer_*.img.zst.gpg found')${NC}" | tee -a "$LOG_FILE"
            return 1
        fi
        base="${latest_img%.img.zst.gpg}"
        img="${base}.img.zst.gpg"
        sha="${base}.img.zst.gpg.sha256"
        sfd="${base}.sfdisk"

        local include_file create_out
        include_file="$(mktemp)"
        create_out="$(mktemp)"

        {
            echo "$(basename "$img")"
            echo "$(basename "$sha")"
            echo "$(basename "$sfd")"
            [[ -f "${src_dir}/LATEST_OK" ]] && echo "LATEST_OK"
            [[ -f "${src_dir}/LATEST_OK.sha256" ]] && echo "LATEST_OK.sha256"
            [[ -f "${src_dir}/LATEST_OK.sfdisk" ]] && echo "LATEST_OK.sfdisk"
            [[ -f "${src_dir}/panzerbackup.log" ]] && echo "panzerbackup.log"
        } > "$include_file"

        echo "" | tee -a "$LOG_FILE"
        echo "$(say 'Dateien (Panzerbackup):' 'Files (Panzerbackup):')" | tee -a "$LOG_FILE"
        sed 's/^/  - /' "$include_file" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"

        if ( cd "$src_dir" && borg create --lock-wait "$BORG_LOCK_WAIT" --checkpoint-interval "$BORG_CHECKPOINT_INTERVAL" \
                --stats --progress --compression lz4 \
                "${REPO}::${archive_name}" --paths-from-stdin < "$include_file" ) 2>&1 \
                | tr '\r' '\n' | tee -a "$LOG_FILE" | tee "$create_out"; then
            rc=0
        else
            rc="${PIPESTATUS[0]:-1}"
        fi

        rm -f "$include_file" "$create_out" 2>/dev/null || true

    else
        local create_out
        create_out="$(mktemp)"

        if borg create --lock-wait "$BORG_LOCK_WAIT" --checkpoint-interval "$BORG_CHECKPOINT_INTERVAL" \
                --stats --progress --compression lz4 \
                "${REPO}::${archive_name}" "${src_dir}" 2>&1 \
                | tr '\r' '\n' | tee -a "$LOG_FILE" | tee "$create_out"; then
            rc=0
        else
            rc="${PIPESTATUS[0]:-1}"
        fi

        rm -f "$create_out" 2>/dev/null || true
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo ""
        echo "$(say '┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓' '┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓')" | tee -a "$LOG_FILE"
        echo "$(say '┃ ✓ UPLOAD ERFOLGREICH ┃' '┃ ✓ UPLOAD SUCCESSFUL ┃')" | tee -a "$LOG_FILE"
        echo "$(say '┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛' '┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛')" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        set_job_status "$(say '✓ UPLOAD: Abgeschlossen' '✓ UPLOAD: Finished')"

        if [[ "${PRUNE_AFTER_CREATE:-yes}" == "yes" && "${PRUNE:-yes}" == "yes" ]]; then
            set_job_status "$(say 'UPLOAD: Prune/Compact (nachher)...' 'UPLOAD: Prune/Compact (post)...')"
            borg prune --lock-wait "$BORG_LOCK_WAIT" --list --glob-archives "${prune_pattern}" --keep-last "${keep_setting}" "$REPO" 2>&1 | tee -a "$LOG_FILE" || true
            borg compact --lock-wait "$BORG_LOCK_WAIT" "$REPO" 2>&1 | tee -a "$LOG_FILE" || true
            set_job_status "$(say '✓ UPLOAD: Abgeschlossen' '✓ UPLOAD: Finished')"
        fi

        return 0
    fi

    echo ""
    echo "$(say '┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓' '┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓')" | tee -a "$LOG_FILE"
    echo "$(say '┃ ✗ UPLOAD FEHLGESCHLAGEN ┃' '┃ ✗ UPLOAD FAILED ┃')" | tee -a "$LOG_FILE"
    echo "$(say '┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛' '┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛')" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "$(say ' Siehe Log für Details: '"$LOG_FILE" ' See log for details: '"$LOG_FILE")" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    set_job_status "$(say '✗ UPLOAD: FEHLER – siehe Log' '✗ UPLOAD: ERROR – see log')"
    return "$rc"
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
        i=$((i + 1))
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
    if [[ -z "$archive" ]]; then
        echo -e "${R}$(say '✗ Kein Archiv angegeben.' '✗ No archive specified.')${NC}"
        return 1
    fi

    if is_running; then
        echo -e "${Y}$(say '⚠ Es läuft bereits ein Job.' '⚠ A job is already running.')${NC}"
        return 1
    fi

    ensure_logfile_writable

    local dest_dir="${DOWNLOAD_DEST_DIR:-$PWD}"
    echo -e "${G}$(say 'Starte Download im Hintergrund (detached)...' 'Starting download in background (detached)...')${NC}"
    start_detached_worker download --archive "$archive" --dest-dir "$dest_dir"
}

# -------------------- Worker: Download (foreground implementation) --------------------
worker_download() {
    local archive="${1:-}"
    local dest_dir="${2:-${DOWNLOAD_DEST_DIR:-$PWD}}"

    if [[ -z "$archive" ]]; then
        echo "worker_download: missing archive" | tee -a "$LOG_FILE"
        return 2
    fi

    ensure_logfile_writable
    echo "$$" > "$PID_FILE"
    date +%s > "$START_FILE" 2>/dev/null || true

    cleanup_worker_files() {
        rm -f "$PID_FILE" "$START_FILE" 2>/dev/null || true
    }
    trap cleanup_worker_files EXIT

    set_job_status "$(say 'DOWNLOAD: Wird vorbereitet...' 'DOWNLOAD: Preparing...')"

    {
        echo ""
        echo "==================================================="
        echo "$(say 'DOWNLOAD GESTARTET' 'DOWNLOAD STARTED'): $(date)"
        echo "==================================================="
        echo "$(say "Archiv: ${archive}" "Archive: ${archive}")"
        echo "$(say "Ziel: ${dest_dir}" "Destination: ${dest_dir}")"
        echo ""
    } | tee -a "$LOG_FILE"

    if ! setup_borg_env; then
        set_job_status "$(say 'DOWNLOAD: FEHLER – Borg-Setup fehlgeschlagen' 'DOWNLOAD: ERROR – Borg setup failed')"
        echo -e "${R}$(say '✗ FEHLER: Borg-Setup fehlgeschlagen' '✗ ERROR: Borg setup failed')${NC}" | tee -a "$LOG_FILE"
        return 1
    fi

    mkdir -p "$dest_dir" 2>/dev/null || true
    if ! cd "$dest_dir" 2>/dev/null; then
        set_job_status "$(say 'DOWNLOAD: FEHLER – Zielverzeichnis nicht erreichbar' 'DOWNLOAD: ERROR – destination not accessible')"
        echo -e "${R}$(say '✗ FEHLER: Zielverzeichnis nicht erreichbar' '✗ ERROR: destination not accessible')${NC}" | tee -a "$LOG_FILE"
        return 1
    fi

    set_job_status "$(say "DOWNLOAD: ${archive} läuft..." "DOWNLOAD: ${archive} running...")"

    echo "$(say '┌─ Extract Archiv ────────────────────────────────────────┐' '┌─ Extract archive ───────────────────────────────────────┐')" | tee -a "$LOG_FILE"
    echo "$(say "│ Archiv: ${archive}" "│ Archive: ${archive}")" | tee -a "$LOG_FILE"
    echo "$(say "│ Ziel: $(pwd)" "│ Destination: $(pwd)")" | tee -a "$LOG_FILE"
    echo "$(say '└─────────────────────────────────────────────────────────┘' '└─────────────────────────────────────────────────────────┘')" | tee -a "$LOG_FILE"

    local rc=0
    if borg extract --lock-wait "$BORG_LOCK_WAIT" --progress "${REPO}::${archive}" 2>&1 | tr '\r' '\n' | tee -a "$LOG_FILE"; then
        rc=0
    else
        rc="${PIPESTATUS[0]:-1}"
    fi

    if [[ "$rc" -eq 0 ]]; then
        set_job_status "$(say '✓ DOWNLOAD: Abgeschlossen' '✓ DOWNLOAD: Finished')"
        echo -e "${G}$(say '✓ Download abgeschlossen.' '✓ Download finished.')${NC}" | tee -a "$LOG_FILE"
        return 0
    fi

    set_job_status "$(say '✗ DOWNLOAD: FEHLER – siehe Log' '✗ DOWNLOAD: ERROR – see log')"
    echo -e "${R}$(say '✗ Download fehlgeschlagen – siehe Log.' '✗ Download failed – see log.')${NC}" | tee -a "$LOG_FILE"
    return "$rc"
}

# -------------------- Wizard --------------------
run_wizard() {
    echo ""
    echo "=========================================="
    echo " CONFIGURATION WIZARD"
    echo "=========================================="
    echo ""
    echo "$(say 'Drücke Enter für Standardwerte in Klammern.' 'Press Enter for defaults in brackets.')"
    echo ""
    
    local new_repo new_src new_keep new_keep_panzer new_archive_template
    read -r -p "BorgBase Repo URL [${REPO}]: " new_repo
    [[ -n "$new_repo" ]] && REPO="$new_repo"
    
    read -r -p "Source Directory [${SRC_DIR}]: " new_src
    [[ -n "$new_src" ]] && SRC_DIR="$new_src"
    
    echo ""
    echo "$(say '─── Aufbewahrungsrichtlinien / Retention Policies ───' '─── Retention Policies ───')"
    read -r -p "$(say 'Behalte Datenbackups (KEEP_LAST) ['"${KEEP_LAST}"']: ' 'Keep data backups (KEEP_LAST) ['"${KEEP_LAST}"']: ')" new_keep
    [[ -n "$new_keep" ]] && KEEP_LAST="$new_keep"
    
    read -r -p "$(say 'Behalte Panzerbackups (KEEP_LAST_PANZERBACKUP) ['"${KEEP_LAST_PANZERBACKUP}"']: ' 'Keep Panzerbackups (KEEP_LAST_PANZERBACKUP) ['"${KEEP_LAST_PANZERBACKUP}"']: ')" new_keep_panzer
    [[ -n "$new_keep_panzer" ]] && KEEP_LAST_PANZERBACKUP="$new_keep_panzer"
    
    echo ""
    echo "$(say '─── Panzerbackup Archiv-Name Template ───' '─── Panzerbackup Archive Name Template ───')"
    echo "$(say 'Platzhalter: {hostname} = System-Name, {date} = Zeitstempel' 'Placeholders: {hostname} = system name, {date} = timestamp')"
    echo "$(say 'WICHTIG: Muss "panzerbackup" enthalten (Groß-/Kleinschreibung egal)' 'IMPORTANT: Must contain "panzerbackup" (case-insensitive)')"
    echo "$(say 'Beispiele:' 'Examples:')"
    echo "  - panzerbackup-{hostname}-{date}"
    echo "  - {hostname}-panzerbackup-{date}"
    
    while true; do
        read -r -p "Template [${PANZERBACKUP_ARCHIVE_NAME}]: " new_archive_template
        [[ -z "$new_archive_template" ]] && new_archive_template="${PANZERBACKUP_ARCHIVE_NAME}"
        
        if [[ "$new_archive_template" =~ [Pp][Aa][Nn][Zz][Ee][Rr][Bb][Aa][Cc][Kk][Uu][Pp] ]]; then
            PANZERBACKUP_ARCHIVE_NAME="$new_archive_template"
            echo -e "${G}$(say '✓ Template akzeptiert' '✓ Template accepted')${NC}"
            break
        else
            echo -e "${R}$(say '✗ FEHLER: Template muss "panzerbackup" enthalten!' '✗ ERROR: Template must contain "panzerbackup"!')${NC}"
        fi
    done
    
    echo ""
    echo "$(say '─── SSH-Key ───' '─── SSH Key ───')"
    echo "$(say 'Geben Sie den Pfad zum SSH-Key ein (oder Enter für Auto-Erkennung):' 'Enter the path to the SSH key (or Enter for auto-detection):')"
    read -r -p "SSH Key Path [${SSH_KEY:-}]: " new_key
    if [[ -n "$new_key" ]]; then
        SSH_KEY="$(expand_path "$new_key")"
        if [[ -r "$SSH_KEY" ]]; then
            echo -e "${G}$(say '✓ SSH-Key gesetzt:' '✓ SSH key set:') $SSH_KEY${NC}"
        else
            echo -e "${R}$(say '✗ WARNUNG: SSH-Key nicht lesbar!' '✗ WARNING: SSH key not readable!')${NC}"
        fi
    else
        resolve_ssh_key
        if [[ -n "$SSH_KEY" ]]; then
            echo -e "${G}$(say '✓ Auto-erkannter SSH-Key:' '✓ Auto-detected SSH key:') $SSH_KEY${NC}"
        else
            echo -e "${Y}$(say '⚠ Kein SSH-Key auto-erkannt.' '⚠ No SSH key auto-detected.')${NC}"
        fi
    fi
    
    echo ""
    echo "$(say '─── Repository Passphrase ───' '─── Repository Passphrase ───')"
    # FIXED: Honest description - plaintext file, protected by file permissions only
    echo -e "${Y}$(say 'HINWEIS: Die Passphrase wird als Klartext in einer Datei gespeichert,' \
        'NOTE: The passphrase is stored as plaintext in a file,')${NC}"
    echo -e "${Y}$(say '         die nur für diesen Benutzer lesbar ist (chmod 600).' \
        '         readable only by this user (chmod 600).')${NC}"
    echo -e "${Y}$(say '         Das Borg-Repository selbst ist verschlüsselt.' \
        '         The Borg repository itself is encrypted.')${NC}"
    read -r -s -p "$(say 'Repo Passphrase: ' 'Repo Passphrase: ')" pass
    echo ""
    if [[ -n "$pass" ]]; then
        echo -n "$pass" > "$PASSPHRASE_FILE"
        chmod 600 "$PASSPHRASE_FILE"
        echo -e "${G}$(say '✓ Repository-Passphrase gespeichert (chmod 600).' '✓ Repository passphrase saved (chmod 600).')${NC}"
    fi
    
    echo ""
    echo "$(say '─── SSH-Key Passphrase (optional) ───' '─── SSH Key Passphrase (optional) ───')"
    if [[ -f "$SSH_KEY" ]] && ! ssh-keygen -y -P "" -f "$SSH_KEY" >/dev/null 2>&1; then
        echo -e "${Y}$(say '⚠ Der gewählte SSH-Key ist verschlüsselt und benötigt eine Passphrase.' '⚠ The selected SSH key is encrypted and requires a passphrase.')${NC}"
    else
        echo "$(say 'Falls Ihr SSH-Key eine Passphrase hat, geben Sie diese hier ein.' 'If your SSH key has a passphrase, enter it here.')"
    fi
    echo -e "${Y}$(say 'HINWEIS: Auch diese wird als Klartext (chmod 600) gespeichert.' \
        'NOTE: This is also stored as plaintext (chmod 600).')${NC}"
    echo "$(say 'Leer lassen, wenn der Key keine Passphrase hat.' 'Leave empty if key has no passphrase.')"
    read -r -s -p "SSH Key Passphrase (optional): " sshpass
    echo ""
    if [[ -n "$sshpass" ]]; then
        echo -n "$sshpass" > "$SSH_KEY_PASSPHRASE_FILE"
        chmod 600 "$SSH_KEY_PASSPHRASE_FILE"
        echo -e "${G}$(say '✓ SSH-Key-Passphrase gespeichert (chmod 600).' '✓ SSH key passphrase saved (chmod 600).')${NC}"
    else
        rm -f "$SSH_KEY_PASSPHRASE_FILE" 2>/dev/null || true
        echo "$(say 'Keine SSH-Key-Passphrase gespeichert.' 'No SSH key passphrase saved.')"
    fi
    
    echo ""
    echo "$(say 'Spracheinstellung / Language Setting:' 'Language Setting:')"
    local lang_choice
    read -r -p "de/en [${UI_LANG:-de}]: " lang_choice
    [[ -n "$lang_choice" ]] && UI_LANG="$lang_choice"
    
    cat <<EOF > "$ENV_FILE"
REPO="${REPO}"
SRC_DIR="${SRC_DIR}"
SSH_KEY="${SSH_KEY}"
KEEP_LAST="${KEEP_LAST}"
KEEP_LAST_PANZERBACKUP="${KEEP_LAST_PANZERBACKUP}"
PANZERBACKUP_ARCHIVE_NAME="${PANZERBACKUP_ARCHIVE_NAME}"
UI_LANG="${UI_LANG}"
AUTO_ACCEPT_HOSTKEY="yes"
EOF
    
    echo ""
    echo "$(say '✓ Konfiguration gespeichert in: '"$ENV_FILE" '✓ Configuration saved to: '"$ENV_FILE")"
    echo ""
    
    echo "$(say 'Teste Verbindung...' 'Testing connection...')"
    if test_connection; then
        echo -e "${G}$(say '✓ Setup erfolgreich!' '✓ Setup successful!')${NC}"
    else
        echo -e "${Y}$(say '⚠ Verbindungstest fehlgeschlagen. Bitte Einstellungen prüfen.' '⚠ Connection test failed. Please check settings.')${NC}"
    fi
    sleep 2
}

# -------------------- Sleep inhibition (systemd-inhibit) --------------------
maybe_inhibit_exec() {
    if [[ "${INHIBIT_SLEEP:-yes}" != "yes" ]]; then return 0; fi
    if [[ -n "${_INHIBITED:-}" ]]; then return 0; fi
    if ! command -v systemd-inhibit >/dev/null 2>&1; then return 0; fi
    export _INHIBITED=1
    exec systemd-inhibit --what="${INHIBIT_WHAT}" --mode="${INHIBIT_MODE}" --why="${INHIBIT_WHY}" "$0" "$@"
}

maybe_inhibit_reexec_worker() {
    local mode="${1:-worker}"
    shift || true
    if [[ "${INHIBIT_SLEEP:-yes}" != "yes" ]]; then return 0; fi
    if [[ -n "${_INHIBITED:-}" ]]; then return 0; fi
    if ! command -v systemd-inhibit >/dev/null 2>&1; then return 0; fi
    export _INHIBITED=1
    exec systemd-inhibit --what="${INHIBIT_WHAT}" --mode="${INHIBIT_MODE}" --why="${INHIBIT_WHY} (${mode})" "$0" --worker "$mode" "$@"
}

# -------------------- systemd user units --------------------
install_systemd_user_units() {
    local script_path unit_dir service_file timer_file
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    service_file="${unit_dir}/borgbase-backup-manager.service"
    timer_file="${unit_dir}/borgbase-backup-manager.timer"

    mkdir -p "$unit_dir"

    cat > "$service_file" <<EOF
[Unit]
Description=BorgBase Backup Manager (Upload)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${CONFIG_DIR}/borgbase-manager.env
Environment=INHIBIT_SLEEP=yes
ExecStart=${script_path} upload
EOF

    cat > "$timer_file" <<EOF
[Unit]
Description=Run BorgBase Backup Manager daily

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi

    echo -e "${G}$(say '✓ systemd User-Units geschrieben:' '✓ systemd user units written:')${NC}"
    echo "  - ${service_file}"
    echo "  - ${timer_file}"
    echo ""
    echo "$(say 'Aktivieren (optional):' 'Enable (optional):')"
    echo "  systemctl --user enable --now borgbase-backup-manager.service"
    echo "  systemctl --user enable --now borgbase-backup-manager.timer"
    echo ""
    echo "$(say 'Manuell starten:' 'Manual start:')"
    echo "  systemctl --user start borgbase-backup-manager.service"
}

# -------------------- Repo lock helper --------------------
break_lock_repo() {
    if is_running; then
        echo -e "${Y}$(say '⚠ Job läuft – break-lock jetzt ist riskant.' '⚠ Job running – break-lock is risky now.')${NC}"
        return 1
    fi

    echo -e "${Y}$(say 'WARNUNG: borg break-lock kann laufende Prozesse stören.' 'WARNING: borg break-lock can disrupt running processes.')${NC}"
    echo "$(say 'Tippe BREAK-LOCK zur Bestätigung:' 'Type BREAK-LOCK to confirm:')"
    read -r confirm
    if [[ "$confirm" != "BREAK-LOCK" ]]; then
        echo "$(say 'Abgebrochen.' 'Cancelled.')"
        return 1
    fi

    ensure_logfile_writable
    setup_borg_env || return 1
    borg break-lock "$REPO" 2>&1 | tee -a "$LOG_FILE"
}

# -------------------- Live progress --------------------
live_progress_view() {
    ensure_logfile_writable

    local key=""
    trap 'key="q"' INT

    while true; do
        clear 2>/dev/null || true
        echo "============================================================"
        echo "  $(say 'Live Progress – Log folgen' 'Live progress – follow log')"
        echo "  $(say "PID: $(cat "$PID_FILE" 2>/dev/null || echo '-')" "PID: $(cat "$PID_FILE" 2>/dev/null || echo '-')")"
        echo "  $(say "Job: $(get_job_status_formatted)" "Job: $(get_job_status_formatted)")"
        echo "  $(say "Repo: $(get_conn_status_formatted)" "Repo: $(get_conn_status_formatted)")"
        if [[ -f "$LOG_FILE" ]]; then
            local last_ts now_ts age
            last_ts="$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)"
            now_ts="$(date +%s)"
            age=$((now_ts - last_ts))
            echo "  $(say "Log-Update vor: ${age}s" "Log updated: ${age}s ago")"
        fi
        echo "============================================================"
        echo "$(say 'q = zurück ins Menü' 'q = back to menu')"
        echo ""

        if [[ -f "$LOG_FILE" ]]; then
            tail -n 60 "$LOG_FILE" | tr '\r' '\n'
        else
            echo "$(say 'Noch kein Log vorhanden.' 'No log yet.')"
        fi

        if [[ "$key" == "q" ]]; then break; fi
        read -r -n 1 -t 2 key || true
        if [[ "$key" == "q" ]]; then break; fi

        if ! is_running; then
            echo ""
            echo -e "${Y}$(say 'Kein laufender Job mehr erkannt.' 'No running job detected anymore.')${NC}"
            echo "$(say 'Drücke eine Taste...' 'Press any key...')"
            read -r -n 1 -s || true
            break
        fi
    done

    trap - INT
}

# -------------------- Menu --------------------
show_menu() {
    clear 2>/dev/null || true
    echo -e "${B}${BOLD}============================================================${NC}"
    echo -e "${B}${BOLD}  ${APP_NAME} ${APP_VERSION}${NC}"
    echo -e "${B}${BOLD}============================================================${NC}"
    echo ""
    local job_line; job_line="$(get_job_status_formatted)"
    local conn_line; conn_line="$(get_conn_status_formatted)"
    echo -e "  $(say 'Job:  ' 'Job:  ') ${job_line}"
    echo -e "  $(say 'Repo: ' 'Repo: ') ${conn_line}"
    echo ""
    echo -e "${C}1)  $(say 'Backup zu BorgBase hochladen' 'Upload backup to BorgBase')${NC}"
    echo -e "${C}2)  $(say 'Backup von BorgBase herunterladen' 'Download backup from BorgBase')${NC}"
    echo -e "${C}3)  $(say 'Alle Archive auflisten' 'List all archives')${NC}"
    echo -e "${C}4)  $(say 'Verbindung zum Repo testen' 'Test repo connection')${NC}"
    echo -e "${C}5)  $(say 'Log-Datei anzeigen' 'Show log file')${NC}"
    echo -e "${C}6)  $(say 'Einstellungen anzeigen' 'Show settings')${NC}"
    echo -e "${C}7)  $(say 'Status löschen' 'Clear status')${NC}"
    echo -e "${C}8)  $(say 'Konfiguration neu (Wizard)' 'Reconfigure (wizard)')${NC}"
    echo -e "${C}9)  $(say 'Live Progress (Log folgen)' 'Live progress (follow log)')${NC}"
    echo -e "${C}10) $(say 'systemd User-Service/Timer installieren' 'Install systemd user service/timer')${NC}"
    echo -e "${C}11) $(say 'Repo-Lock brechen (borg break-lock)' 'Break repo lock (borg break-lock)')${NC}"
    echo -e "${C}q)  $(say 'Beenden' 'Quit')${NC}"
    echo ""
}

# -------------------- Main --------------------
load_env

# -------------------- CLI / Worker entrypoints --------------------
if [[ "${1:-}" == "--worker" ]]; then
    shift || true
    worker_mode="${1:-}"
    shift || true

    maybe_inhibit_reexec_worker "$worker_mode" "$@"

    worker_src_dir=""
    worker_archive=""
    worker_dest_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --src-dir)   worker_src_dir="${2:-}"; shift 2 || true ;;
            --archive)   worker_archive="${2:-}"; shift 2 || true ;;
            --dest-dir)  worker_dest_dir="${2:-}"; shift 2 || true ;;
            *) shift || true ;;
        esac
    done

    [[ -n "${worker_src_dir}" ]] && SRC_DIR="${worker_src_dir}"
    [[ -z "${UI_LANG:-}" ]] && UI_LANG="de"

    case "$worker_mode" in
        upload)
            worker_upload "$SRC_DIR"
            exit $?
            ;;
        download)
            if [[ -z "${worker_archive}" ]]; then
                echo "worker: missing --archive" | tee -a "$LOG_FILE"
                exit 2
            fi
            worker_download "${worker_archive}" "${worker_dest_dir}"
            exit $?
            ;;
        *)
            echo "worker: unknown mode '${worker_mode}'" | tee -a "$LOG_FILE"
            exit 2
            ;;
    esac
fi

# Non-interactive CLI mode
if [[ $# -gt 0 ]]; then
    maybe_inhibit_exec "$@"

    [[ -z "${UI_LANG:-}" ]] && UI_LANG="de"

    cmd="$1"
    shift || true

    case "$cmd" in
        upload)
            detect_src_dir >/dev/null 2>&1 || true
            worker_upload "$SRC_DIR"
            exit $?
            ;;
        download)
            if [[ -z "${1:-}" ]]; then
                echo "Usage: $0 download <archive>" >&2
                exit 2
            fi
            worker_download "$1" "${DOWNLOAD_DEST_DIR:-$PWD}"
            exit $?
            ;;
        break-lock)
            break_lock_repo
            exit $?
            ;;
        install-service)
            install_systemd_user_units
            exit $?
            ;;
        status)
            echo "$(get_job_status_formatted)"
            exit 0
            ;;
        *)
            echo "Usage:"
            echo "  $0 upload"
            echo "  $0 download <archive>"
            echo "  $0 break-lock"
            echo "  $0 install-service"
            echo "  $0 status"
            exit 2
            ;;
    esac
fi

# Initial language prompt if interactive
if [[ -t 0 ]]; then
    echo "Select Language / Sprache wählen:"
    echo "1) Deutsch (Standard)"
    echo "2) English"
    read -r -p "1-2: " l
    if [[ "$l" == "2" ]]; then UI_LANG="en"; else UI_LANG="de"; fi
fi

if [[ -z "$SRC_DIR" ]]; then
    detect_src_dir >/dev/null || true
fi

while true; do
    show_menu
    read -r -p "$(say 'Ihre Wahl: ' 'Your choice: ')" choice
    
    case "$choice" in
        1)
            if is_running; then
                echo -e "${R}$(say 'Ein Job läuft bereits!' 'A job is already running!')${NC}"
                pause
            else
                if ! show_upload_selection; then
                    pause
                    continue
                fi
                
                rm -f "$PRUNE_NEEDED_FLAG" 2>/dev/null || true
                
                if [[ "${PRUNE:-yes}" == "yes" ]]; then
                    if ! test_connection; then
                        pause
                        continue
                    fi
                    
                    show_prune_preview "$SRC_DIR"
                    prune_rc=$?
                    
                    if (( prune_rc == 1 )); then
                        echo "$(say 'Upload abgebrochen.' 'Upload cancelled.')"
                        pause
                        continue
                    elif (( prune_rc == 2 )); then
                        read -r -p "$(say 'Alte Backups wie gezeigt löschen? (JA zum Bestätigen): ' 'Delete old backups as shown? (type YES to confirm): ')" prune_confirm
                        if [[ "$prune_confirm" != "JA" && "$prune_confirm" != "YES" ]]; then
                            echo "$(say 'Löschvorgang abgebrochen. Upload wird nicht gestartet.' 'Deletion cancelled. Upload will not start.')"
                            pause
                            continue
                        fi
                        touch "$PRUNE_NEEDED_FLAG"
                    fi
                fi
                
                echo ""
                read -r -p "$(say 'Jetzt Upload starten? (j/n): ' 'Start upload now? (y/n): ')" yn
                if [[ "$yn" =~ ^[jJyY] ]]; then
                    do_upload_background
                    echo "$(say 'Job im Hintergrund gestartet.' 'Job started in background.')"
                    sleep 1
                else
                    rm -f "$PRUNE_NEEDED_FLAG" 2>/dev/null || true
                fi
            fi
            ;;
        2)
            if is_running; then
                echo -e "${R}$(say 'Ein Job läuft bereits!' 'A job is already running!')${NC}"
                pause
            else
                test_connection || { pause; continue; }
                arch="$(select_archive)"
                if [[ -n "$arch" ]]; then
                    do_download_background "$arch"
                    echo "$(say 'Job im Hintergrund gestartet.' 'Job started in background.')"
                    sleep 1
                fi
            fi
            ;;
        3)
            test_connection || { pause; continue; }
            borg_with_ssh "$(borg_list_cmd)" "$REPO"
            pause
            ;;
        4)
            echo "$(say 'Teste Verbindung...' 'Testing connection...')"
            test_connection || true
            pause
            ;;
        5)
            if [[ -f "$LOG_FILE" ]]; then
                less +G "$LOG_FILE"
            else
                echo "No log file found."
                pause
            fi
            ;;
        6)
            echo "════════════════════════════════════════════════════════════"
            echo "$(say ' AKTUELLE EINSTELLUNGEN' ' CURRENT SETTINGS')"
            echo "════════════════════════════════════════════════════════════"
            echo ""
            echo "$(say 'Repository:' 'Repository:') $REPO"
            echo "$(say 'Quellverzeichnis:' 'Source Directory:') $SRC_DIR"
            echo "$(say 'SSH-Key:' 'SSH Key:') $SSH_KEY"
            echo "$(say 'Auto-Accept Hostkey:' 'Auto-Accept Hostkey:') ${AUTO_ACCEPT_HOSTKEY}"
            echo ""
            echo "$(say '─── Aufbewahrungsrichtlinien ───' '─── Retention Policies ───')"
            echo "$(say 'Datenbackups behalten:' 'Keep data backups:') $KEEP_LAST $(say 'Stück' 'archives')"
            echo "$(say 'Panzerbackups behalten:' 'Keep Panzerbackups:') $KEEP_LAST_PANZERBACKUP $(say 'Stück' 'archives')"
            echo ""
            echo "$(say 'Panzerbackup Archiv-Template:' 'Panzerbackup archive template:')"
            echo "  $PANZERBACKUP_ARCHIVE_NAME"
            echo ""
            echo "$(say 'Passphrasen-Status:' 'Passphrase Status:')"
            if [[ -f "$PASSPHRASE_FILE" ]]; then
                perm="$(stat -c '%a' "$PASSPHRASE_FILE" 2>/dev/null || echo '???')"
                echo -e "  ${G}$(say '✓ Repository-Passphrase: gespeichert' '✓ Repository passphrase: saved')${NC} $(say "(Klartext, chmod ${perm})" "(plaintext, chmod ${perm})")"
            else
                echo -e "  ${R}$(say '✗ Repository-Passphrase: FEHLT' '✗ Repository passphrase: MISSING')${NC}"
            fi
            if [[ -f "$SSH_KEY_PASSPHRASE_FILE" ]]; then
                perm2="$(stat -c '%a' "$SSH_KEY_PASSPHRASE_FILE" 2>/dev/null || echo '???')"
                echo -e "  ${G}$(say '✓ SSH-Key-Passphrase: gespeichert' '✓ SSH key passphrase: saved')${NC} $(say "(Klartext, chmod ${perm2})" "(plaintext, chmod ${perm2})")"
            else
                echo "  $(say '○ SSH-Key-Passphrase: nicht gesetzt' '○ SSH key passphrase: not set')"
            fi
            echo ""
            echo "$(say 'Dateien:' 'Files:')"
            echo "  Config: $ENV_FILE"
            echo "  Log: $LOG_FILE"
            echo "  Known Hosts: $SSH_KNOWN_HOSTS"
            echo ""
            pause
            ;;
        7)
            clear_status
            echo "Status cleared."
            sleep 1
            ;;
        8)
            run_wizard
            ;;
        9)
            live_progress_view
            ;;
        10)
            install_systemd_user_units
            pause
            ;;
        11)
            break_lock_repo
            pause
            ;;
        q)
            echo "$(say 'Tschüss!' 'Bye!')"
            exit 0
            ;;
        *)
            ;;
    esac
done
