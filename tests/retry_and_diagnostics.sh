#!/usr/bin/env bash
# Isolated regression tests: never read the user's config or contact BorgBase.
# Variables and mocks are consumed by the dynamically sourced functions.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
export HOME="$test_dir/home" XDG_CONFIG_HOME="$test_dir/config" XDG_STATE_HOME="$test_dir/state"
export XDG_CACHE_HOME="$test_dir/cache" XDG_RUNTIME_DIR="$test_dir/runtime"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
# Load definitions only, before the script's CLI/UI and config loading.
# shellcheck disable=SC1090
source <(sed '/^# -------------------- Main --------------------/,$d' "$repo_dir/borgbase_manager.sh")
trap - ERR
UI_LANG=en
LOG_FILE="$test_dir/upload.log"
BORG_NICE=()
UPLOAD_RETRY_DELAY=0
UPLOAD_MAX_RETRIES=2
REPO="$test_dir/repo"
rc=0 upload_error_hint=""

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1' ($3)"; }
reset_case() {
    rm -f "$STOP_REQUEST_FILE" "$test_dir/calls"
    : > "$LOG_FILE"
    AUTO_RETRY_ON_SSH_DISCONNECT=yes
    UPLOAD_MAX_RETRIES=2
    rc=0 upload_error_hint=""
}
# Files retain mock state across Borg's pipeline subshells.
borg() {
    echo x >> "$test_dir/calls"
    if [[ "$mock_mode" == success ]] || { [[ "$mock_mode" == recover ]] && [[ $(wc -l < "$test_dir/calls") -gt 1 ]]; }; then
        printf '10 MB O 10 MB C 5 MB D 1 N file\r'
        return 0
    fi
    printf '%s\n' "$mock_error" >&2
    return 2
}
mkdir -p "$test_dir/source"
printf 'file\n' > "$test_dir/includes"
for mode in directory image; do
    for mock_error in 'client_loop: send disconnect: Broken pipe' 'Connection reset by peer' 'Timeout, server backup.example not responding.' 'ssh: connect to host backup.example port 22: Connection timed out' 'Temporary failure in name resolution' 'Connection closed by remote host' 'Network is unreachable' 'No route to host' 'Connection refused' 'Could not resolve hostname backup.example'; do
        reset_case
        mock_mode=recover
        if [[ "$mode" == image ]]; then
            run_upload_create "$test_dir/source" archive "$test_dir/includes" > /dev/null || fail "$mode reconnect"
        else
            run_upload_create "$test_dir/source" archive > /dev/null || fail "$mode reconnect"
        fi
        assert_eq "$(wc -l < "$test_dir/calls")" 2 "$mode retry count"
    done
done
echo 'PASS: image and directory uploads recover from ten network errors'
reset_case
mock_mode=fail mock_error='Connection reset by peer'
run_upload_create "$test_dir/source" archive > /dev/null && fail 'expected exhausted retries' || result=$?
assert_eq "$result" 2 'Borg exit status'
assert_eq "$(wc -l < "$test_dir/calls")" 3 'bounded retries'
echo 'PASS: exhausted retries preserve Borg failure'
for mock_error in 'Permission denied (publickey).' 'Repository is corrupted' 'No space left on device'; do
    reset_case
    run_upload_create "$test_dir/source" archive > /dev/null && fail 'expected permanent failure' || result=$?
    assert_eq "$result" 2 'permanent failure'
    assert_eq "$(wc -l < "$test_dir/calls")" 1 'no retry for permanent error'
done
echo 'PASS: auth, corruption and disk errors do not retry'
reset_case
AUTO_RETRY_ON_SSH_DISCONNECT=no
mock_error='Connection reset by peer'
run_upload_create "$test_dir/source" archive > /dev/null && fail 'retry disabled' || result=$?
assert_eq "$(wc -l < "$test_dir/calls")" 1 'retry disabled'
reset_case
retry_wait() { atomic_write "$STOP_REQUEST_FILE" 'manual'; return 1; }
run_upload_create "$test_dir/source" archive > /dev/null && fail 'expected stop' || result=$?
assert_eq "$result" 130 'stop during retry wait'
assert_eq "$(wc -l < "$test_dir/calls")" 1 'no retry after stop'
echo 'PASS: retry disabling and manual stop'
reset_case
mock_mode=success
# Fail only the progress filter; other log pipes must remain usable.
borg_progress_lines() { cat; return 7; }
run_upload_create "$test_dir/source" archive > /dev/null && fail 'log pipeline failure reported success' || result=$?
assert_eq "$result" 2 'pipeline failure'
unset -f borg_progress_lines
# Restore the real definitions for stream and local Borg checks.
# shellcheck disable=SC1090
source <(sed '/^# -------------------- Main --------------------/,$d' "$repo_dir/borgbase_manager.sh")
trap - ERR
UI_LANG=en
BORG_NICE=()
echo 'PASS: progress pipeline errors are not reported as success'
# A CR-only log must produce only its last records, not a multi-MB line.
LOG_FILE="$test_dir/cr.log"
awk 'BEGIN { for (i=1;i<=10000;i++) printf "progress %d\r", i }' > "$LOG_FILE"
assert_eq "$(recent_log_lines 2)" $'progress 9999\nprogress 10000' 'bounded CR log'
# Socket selection must ignore other jobs, including PIDs sharing a prefix.
ss() {
    cat <<'SOCKETS'
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
ESTAB 0 0 127.0.0.1:123 127.0.0.2:22 users:(("ssh",pid=123,fd=3))
     cubic bytes_acked:123456 bytes_retrans:789
ESTAB 0 0 127.0.0.1:124 127.0.0.3:22 users:(("ssh",pid=1234,fd=3))
     cubic bytes_acked:999999 bytes_retrans:888
ESTAB 0 0 127.0.0.1:125 127.0.0.4:22 users:(("ssh",pid=456,fd=3))
     cubic bytes_acked:100 bytes_retrans:20
SOCKETS
}
assert_eq "$(worker_tcp_counters 123)" '123456 789 1' 'socket owner'
assert_eq "$(worker_tcp_counters $'123\n456')" '123556 809 2' 'multiple sockets'
worker_tcp_counters 999 >/dev/null && fail 'unrelated SSH counted as progress'
unset -f ss
REPO='ssh://user@backup.example/./repo'
ps() {
    cat <<'PROCESSES'
42 1 bash bash manager --worker upload
43 42 bash bash upload-pipeline
100 43 ssh ssh user@backup.example borg serve
101 1 ssh ssh user@backup.example borg serve
102 42 ssh ssh user@other.example borg serve
PROCESSES
}
assert_eq "$(worker_ssh_pids 42)" 100 'only SSH descendants on matching host'
unset -f ps
echo 'PASS: bounded logs and TCP counters scoped to worker SSH'
cli_output="$(cd "$test_dir" && UI_LANG=en bash "$repo_dir/borgbase_manager.sh" diagnose)"
[[ "$cli_output" == *'No job is currently running.'* ]] || fail 'diagnose CLI without active job'
echo 'PASS: diagnose CLI runs without credentials or sleep inhibition'
# Verify line buffering before the producer finishes; a tiny single update used
# to remain in tr output buffers until thousands of bytes had accumulated.
export -f borg_progress_lines
python3 - <<'PY'
import os, select, subprocess
p = subprocess.Popen(['bash', '-c', "{ printf 'first\\r'; sleep 5; } | borg_progress_lines"], stdout=subprocess.PIPE, start_new_session=True)
try:
    assert select.select([p.stdout], [], [], 2)[0], 'first progress update was buffered'
    assert p.stdout.readline() == b'first\n'
finally:
    import signal
    os.killpg(p.pid, signal.SIGTERM)
    p.wait()
PY
echo 'PASS: live progress is flushed before process exit'
unset -f borg
if command -v borg >/dev/null 2>&1; then
    LOG_FILE="$test_dir/real.log"
    REPO="$test_dir/real-repo"
    rc=0 upload_error_hint=""
    rm -f "$STOP_REQUEST_FILE"
    borg init --encryption=none "$REPO"
    printf 'real backup data\n' > "$test_dir/source/file"
    run_upload_create "$test_dir/source" real-directory > /dev/null || fail 'real directory create'
    run_upload_create "$test_dir/source" real-image "$test_dir/includes" > /dev/null || fail 'real paths-from-stdin create'
    assert_eq "$(borg list --short "$REPO" | wc -l)" 2 'real archives'
    assert_eq "$(borg extract --stdout "$REPO::real-image" file)" 'real backup data' 'restored contents'
    borg check "$REPO"
    echo 'PASS: real Borg directory/image create, restore and repository check'
fi
