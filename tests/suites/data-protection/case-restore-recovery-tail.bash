#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/test-root.bash
source "$SCRIPT_DIR/../../lib/test-root.bash"
ROOT="$VW_TEST_REPO_ROOT"
export VAULTWARDEN_RESTORE_RECOVERY_SHARD=tail
"$SCRIPT_DIR/case-restore-recovery.bash" "$@"

cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

check_fresh_host_restore_bootstrap() (
set -euo pipefail
restore_tmp="$(mktemp -d)"
cleanup_restore_bootstrap() {
  if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then
    sudo -n rm -rf -- "$restore_tmp" 2>/dev/null || true
  else
    rm -rf -- "$restore_tmp"
  fi
}
trap cleanup_restore_bootstrap EXIT INT TERM HUP

mock_bin="$restore_tmp/bin"
mkdir -p "$mock_bin" "$restore_tmp/home/.config/rclone" "$restore_tmp/missing-state"
cat > "$mock_bin/rclone" <<'EOF_RCLONE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RCLONE_CALLS:?}"
case "${1:-}" in
  lsf)
    [[ "${*: -1}" == *'/db' ]] && printf 'db_backup_20260803_000000.sqlite3.age\n'
    ;;
  lsl)
    printf '123 2026-08-03 00:00:00.000000000 db_backup_20260803_000000.sqlite3.age\n'
    ;;
  listremotes)
    printf 'testremote:\n'
    ;;
esac
EOF_RCLONE
chmod 0755 "$mock_bin/rclone"
printf '[testremote]\ntype = local\n' > "$restore_tmp/home/.config/rclone/rclone.conf"
chmod 0600 "$restore_tmp/home/.config/rclone/rclone.conf"

fresh_output="$restore_tmp/fresh-list.out"
rclone_calls="$restore_tmp/rclone-calls.log"
: > "$rclone_calls"
if ! env \
  PATH="$mock_bin:$PATH" \
  HOME="$restore_tmp/home" \
  PROJECT_STATE_DIR="$restore_tmp/missing-state" \
  VW_CONFIG_INSTALLED_ENV_FILE="$restore_tmp/missing-installed.env" \
  RCLONE_REMOTE_NAME=testremote \
  RCLONE_REMOTE_PATH=testpath \
  RCLONE_CONFIG="$restore_tmp/home/.config/rclone/rclone.conf" \
  RCLONE_CALLS="$rclone_calls" \
  bash ./restore.sh list --remote >"$fresh_output" 2>&1; then
  cat "$fresh_output" >&2
  fail "fresh-host remote inventory rejected explicit session configuration"
fi
grep -Fq 'db_backup_20260803_000000.sqlite3.age' "$fresh_output" \
  || { cat "$fresh_output" >&2; fail "fresh-host remote inventory did not list the remote backup"; }
grep -Fq 'testremote:testpath/db' "$rclone_calls" \
  || { cat "$rclone_calls" >&2; fail "fresh-host remote inventory did not use session remote values"; }

run_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 77
  fi
}

bootstrap_output="$restore_tmp/bootstrap-restore.out"
bootstrap_ops_dir="$restore_tmp/bootstrap-operations"
bootstrap_ops_lock="$restore_tmp/bootstrap-operations.lock"
bootstrap_rc=0
printf 'q\n' | run_root env \
  PATH="$mock_bin:$PATH" \
  HOME="$restore_tmp/home" \
  PROJECT_STATE_DIR="$restore_tmp/missing-state" \
  VW_CONFIG_INSTALLED_ENV_FILE="$restore_tmp/missing-installed.env" \
  RCLONE_REMOTE_NAME=testremote \
  RCLONE_REMOTE_PATH=testpath \
  RCLONE_CONFIG="$restore_tmp/home/.config/rclone/rclone.conf" \
  RCLONE_CALLS="$rclone_calls" \
  PUID=1000 \
  PGID=1000 \
  VW_OPERATIONS_STATE_DIR="$bootstrap_ops_dir" \
  VW_OPERATIONS_LOCK="$bootstrap_ops_lock" \
  bash ./restore.sh interactive --remote --force >"$bootstrap_output" 2>&1 \
  || bootstrap_rc=$?
if (( bootstrap_rc == 77 )); then
  if [[ "${CI:-false}" == "true" || "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "mandatory fresh-host restore regression requires passwordless sudo in CI"
  fi
  printf 'SKIP fresh-host restore bootstrap: passwordless sudo unavailable\n'
  exit 0
fi
(( bootstrap_rc == 0 )) || {
  cat "$bootstrap_output" >&2
  fail "fresh-host remote restore did not enter the supported bootstrap path"
}
grep -Fq 'operating in bootstrap/emergency-restore mode' "$bootstrap_output" \
  || { cat "$bootstrap_output" >&2; fail "fresh-host remote restore did not report bootstrap mode"; }
grep -Fq 'db_backup_20260803_000000.sqlite3.age' "$bootstrap_output" \
  || { cat "$bootstrap_output" >&2; fail "fresh-host remote restore did not reach remote selection"; }

invalid_env="$restore_tmp/invalid-installed.env"
printf 'PROJECT_STATE_DIR=%s\n' "$restore_tmp/installed-state" > "$invalid_env"
chmod 0644 "$invalid_env"
invalid_output="$restore_tmp/invalid-restore.out"
ops_dir="$restore_tmp/operations"
ops_lock="$restore_tmp/operations.lock"
if run_root env \
  PATH="$mock_bin:$PATH" \
  HOME="$restore_tmp/home" \
  PROJECT_STATE_DIR="$restore_tmp/missing-state" \
  VW_CONFIG_INSTALLED_ENV_FILE="$invalid_env" \
  VW_OPERATIONS_STATE_DIR="$ops_dir" \
  VW_OPERATIONS_LOCK="$ops_lock" \
  bash ./restore.sh interactive --remote --force >"$invalid_output" 2>&1; then
  cat "$invalid_output" >&2
  fail "restore accepted an insecure installed environment"
fi
grep -Eiq 'insecure permissions|failed to load project environment' "$invalid_output" \
  || { cat "$invalid_output" >&2; fail "invalid installed environment failure was not actionable"; }
[[ ! -e "$ops_dir" && ! -e "$ops_lock" ]] \
  || fail "restore started operation work before rejecting invalid installed configuration"

if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  protected_dir="$restore_tmp/protected-installed"
  protected_env="$protected_dir/vaultwarden.env"
  sudo -n install -d -m 0700 -o root -g root "$protected_dir"
  printf 'PROJECT_STATE_DIR=%s\n' "$restore_tmp/protected-state" \
    | sudo -n tee "$protected_env" >/dev/null
  sudo -n chown root:root "$protected_env"
  sudo -n chmod 0600 "$protected_env"
  protected_output="$restore_tmp/protected-list.out"
  if env \
    PROJECT_STATE_DIR="$restore_tmp/missing-state" \
    VW_CONFIG_INSTALLED_ENV_FILE="$protected_env" \
    bash ./restore.sh list >"$protected_output" 2>&1; then
    cat "$protected_output" >&2
    fail "unprivileged restore inventory bypassed protected installed configuration"
  fi
  grep -Eq 'Re-run .*sudo' "$protected_output" \
    || { cat "$protected_output" >&2; fail "protected installed configuration failure lacked sudo guidance"; }
fi
)
check_fresh_host_restore_bootstrap
pass "fresh-host restore bootstrap and environment gates"

check_restore_private_key_output() (
set -euo pipefail
private_tmp="$(mktemp -d)"
trap 'rm -rf -- "$private_tmp"' EXIT
restore_impl="$ROOT/utilities/restore-run.sh"
sed -n '/^_display_new_key() {/,/^_restore_print_key_ack_abort_guidance() {/p' "$restore_impl" \
  | sed '$d' > "$private_tmp/display-new-key.bash"
[[ -s "$private_tmp/display-new-key.bash" ]] \
  || fail "restore private-key display helper could not be extracted"

private_marker='AGE-SECRET-KEY-1RESTORE-OUTPUT-MUST-NOT-LEAK'
ROTATED_KEY_FILE="$private_tmp/age-key.txt"
ROTATED_KIT_FILE="$private_tmp/recovery-handoff.txt"
ROTATED_PUB_KEY='age1syntheticpublicrecipient'
DRY_RUN=false
FORCE=true
RESTORE_PREVENT_AUTOSTART=false
export ROTATED_KEY_FILE ROTATED_KIT_FILE ROTATED_PUB_KEY DRY_RUN FORCE RESTORE_PREVENT_AUTOSTART
printf '%s\n' "$private_marker" > "$ROTATED_KEY_FILE"
printf '%s\n' "$private_marker" > "$ROTATED_KIT_FILE"
chmod 0600 "$ROTATED_KEY_FILE" "$ROTATED_KIT_FILE"
log_warn() { printf 'WARN %s\n' "$*"; }
log_info() { printf 'INFO %s\n' "$*"; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
_restore_print_manual_start_checklist() { :; }
# shellcheck source=/dev/null
source "$private_tmp/display-new-key.bash"
_display_new_key >"$private_tmp/stdout" 2>"$private_tmp/stderr" \
  || fail "restore protected-key summary failed"
! grep -Fq "$private_marker" "$private_tmp/stdout" "$private_tmp/stderr" \
  || fail "restore summary printed private Age key material"
grep -Fq "Protected handoff: $ROTATED_KIT_FILE" "$private_tmp/stdout" \
  || fail "restore summary omitted the protected handoff path"
grep -Fq 'No private key material was written to terminal output.' "$private_tmp/stdout" \
  || fail "restore summary omitted the private-output prohibition"
)
check_restore_private_key_output
pass "restore private key output stays protected"
