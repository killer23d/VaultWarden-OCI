#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# Integration and systemd contracts.
grep -Fq 'cleanup_expired_recovery_kits "$DRY_RUN" || recovery_cleanup_result=$?' \
  utilities/maintenance-run.sh || fail "maintenance does not invoke recovery fallback cleanup"
grep -Fq '[[ "$recovery_cleanup_result" != "0" ]] && ((++critical_failures))' \
  utilities/maintenance-run.sh || fail "recovery cleanup does not affect final status"
grep -Fq 'ReadWritePaths=-/root/vaultwarden-recovery' \
  systemd/vaultwarden-maintenance.service || fail "maintenance sandbox lacks exact recovery path"
grep -Fq 'OnCalendar=*-*-* 02:05:00' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer schedule changed"
grep -Fq 'Persistent=false' systemd/vaultwarden-maintenance.timer \
  || fail "maintenance timer persistence changed"
if find systemd -maxdepth 1 -type f \
  \( -name 'vaultwarden-recovery-cleanup.service' -o -name 'vaultwarden-recovery-cleanup.timer' \) \
  -print -quit | grep -q .; then
  fail "a separate recovery cleanup unit was added"
fi

cleanup_helpers="$(sed -n '/^_remove_sensitive_file() {/,/^_prepare_recovery_dir() {/p' lib/secrets.sh | sed '$d')"
[[ "$cleanup_helpers" == *'cleanup_expired_recovery_kits()'* ]] \
  || fail "recovery cleanup helper block is missing"

if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  fixture="$(mktemp -d)"
  trap 'sudo -n /bin/rm -rf -- "$fixture" >/dev/null 2>&1 || true' EXIT
  sudo -n chown root:root "$fixture"
  sudo -n chmod 0700 "$fixture"
  sudo -n env \
    RECOVERY_KIT_DIR="$fixture" \
    VW_TEST_MODE=true \
    VW_RECOVERY_CLEANUP_MIN_AGE_SECONDS=60 \
    CLEANUP_HELPERS="$cleanup_helpers" \
    bash -s <<'ROOT_TEST' || fail "recovery cleanup behavior failed"
set -euo pipefail
log_debug() { :; }
log_info() { printf 'INFO %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
eval "$CLEANUP_HELPERS"

make_file() {
  local path="$1" content="${2:-x}"
  printf '%s' "$content" > "$path"
  chmod 0600 "$path"
}
old="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.txt"
young="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120001Z-a1b2c4.txt"
wrong_mode="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120002Z-a1b2c5.txt"
wrong_owner="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120003Z-a1b2c6.txt"
link="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120004Z-a1b2c7.txt"
target="$RECOVERY_KIT_DIR/target"
dir_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120005Z-a1b2c8.txt"
fifo_candidate="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120006Z-a1b2c9.txt"
hard="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120007Z-a1b2ca.txt"
hard_peer="$RECOVERY_KIT_DIR/hard-peer"
metachar="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120008Z-a1b2cb;touch-PWNED.txt"
nonmatching="$RECOVERY_KIT_DIR/unrelated.txt"
handoff="$RECOVERY_KIT_DIR/vaultwarden-setup-credentials-20260727T120000Z.txt"
zip_file="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T120000Z-a1b2c3.zip"

make_file "$old" 'SECRET-MUST-NOT-APPEAR'
make_file "$young"
make_file "$wrong_mode"
chmod 0644 "$wrong_mode"
make_file "$wrong_owner"
chown 65534:65534 "$wrong_owner"
make_file "$target"
ln -s "$target" "$link"
mkdir "$dir_candidate"
mkfifo "$fifo_candidate"
make_file "$hard"
ln "$hard" "$hard_peer"
make_file "$metachar"
make_file "$nonmatching"
make_file "$handoff"
make_file "$zip_file"
touch -d '120 seconds ago' "$old" "$wrong_mode" "$wrong_owner" "$link" \
  "$dir_candidate" "$fifo_candidate" "$hard" "$metachar"

set +e
dry_output="$(cleanup_expired_recovery_kits true 2>&1)"
dry_rc=$?
set -e
(( dry_rc != 0 )) || exit 1
[[ -f "$old" ]] || exit 1
[[ "$dry_output" == *'[DRY RUN] Would remove expired plaintext recovery kit:'* ]] || exit 1
[[ "$dry_output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1

set +e
output="$(cleanup_expired_recovery_kits false 2>&1)"
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ ! -e "$old" ]] || exit 1
[[ -e "$young" && -e "$wrong_mode" && -e "$wrong_owner" ]] || exit 1
[[ -L "$link" && -e "$target" && -d "$dir_candidate" && -p "$fifo_candidate" ]] || exit 1
[[ -e "$hard" && -e "$hard_peer" && -e "$metachar" ]] || exit 1
[[ -e "$nonmatching" && -e "$handoff" && -e "$zip_file" ]] || exit 1
[[ "$output" != *'SECRET-MUST-NOT-APPEAR'* ]] || exit 1
[[ ! -e "$RECOVERY_KIT_DIR/touch-PWNED.txt" ]] || exit 1

/bin/rm -f -- "$wrong_mode" "$wrong_owner" "$link" "$fifo_candidate" \
  "$hard" "$hard_peer" "$metachar" "$young" "$nonmatching" "$handoff" "$zip_file" "$target"
rmdir -- "$dir_candidate"
cleanup_expired_recovery_kits false

# Best-effort overwrite failure still falls back to unlink.
old2="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121000Z-a1b2cc.txt"
make_file "$old2"
touch -d '120 seconds ago' "$old2"
shim_dir="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim_dir/shred"
chmod 0755 "$shim_dir/shred"
PATH="$shim_dir:$PATH" cleanup_expired_recovery_kits false
[[ ! -e "$old2" ]] || exit 1
/bin/rm -rf -- "$shim_dir"

# A complete removal failure is reported and leaves the file in place.
old3="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121100Z-a1b2cd.txt"
make_file "$old3"
touch -d '120 seconds ago' "$old3"
original_remove="$(declare -f _remove_sensitive_file)"
_remove_sensitive_file() { return 1; }
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || exit 1
[[ -e "$old3" ]] || exit 1
eval "$original_remove"
/bin/rm -f -- "$old3"

# A changed identity is never deleted.
race="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121200Z-a1b2ce.txt"
make_file "$race"
touch -d '120 seconds ago' "$race"
real_stat="$(command -v stat)"
stat_counter="$RECOVERY_KIT_DIR/.stat-counter"
printf '0\n' > "$stat_counter"
stat() {
  local last="${!#}" count
  if [[ "$last" == "$race" && "${1:-}" == "-c" ]]; then
    count="$(cat "$stat_counter")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$stat_counter"
    if (( count == 2 )); then
      "$real_stat" "$@" | awk -F: 'BEGIN{OFS=":"} {$2=$2+1; print}'
      return 0
    fi
  fi
  "$real_stat" "$@"
}
set +e
cleanup_expired_recovery_kits false >/dev/null 2>&1
rc=$?
set -e
unset -f stat
(( rc != 0 )) || exit 1
[[ -e "$race" ]] || exit 1
/bin/rm -f -- "$race" "$stat_counter"

# An absent test directory is an idempotent no-op and is not created.
absent="${RECOVERY_KIT_DIR}.absent"
RECOVERY_KIT_DIR="$absent" cleanup_expired_recovery_kits false
[[ ! -e "$absent" ]] || exit 1
ROOT_TEST
else
  printf 'SKIP root-owned recovery fixture: passwordless sudo unavailable\n'
fi

# Cleanup failures are explicit and signal-compatible in both entry points.
setup_source="$(cat setup.sh)"
secrets_source="$(cat utilities/setup-secrets.sh)"
[[ "$setup_source" == *'_setup_remove_sensitive_workspace 0'* ]] \
  || fail "top-level setup lacks explicit pre-summary cleanup"
[[ "$setup_source" == *"trap '_setup_on_signal 129' HUP"* ]] \
  || fail "top-level setup does not preserve HUP status"
[[ "$setup_source" == *"trap '_setup_on_signal 130' INT"* ]] \
  || fail "top-level setup does not preserve INT status"
[[ "$setup_source" == *"trap '_setup_on_signal 143' TERM"* ]] \
  || fail "top-level setup does not preserve TERM status"
[[ "$setup_source" != *'rm -rf "$TMP_WORKDIR" 2>/dev/null || true'* ]] \
  || fail "top-level setup still suppresses workspace cleanup failure"
[[ "$secrets_source" == *'Sensitive temporary workspace cleanup failed; setup is not complete.'* ]] \
  || fail "direct setup lacks cleanup-failure gate"
[[ "$secrets_source" != *'_ss_run_cleanup_action "${SETUP_SECRETS_CLEANUP_ACTIONS[$idx]}" || true'* ]] \
  || fail "direct setup still suppresses file cleanup failure"
[[ "$secrets_source" != *'_setup_secrets_remove_workdir || true'* ]] \
  || fail "direct setup still suppresses workspace cleanup failure"
[[ "$secrets_source" == *'printf -v quoted '\''%q'\'' "$target"'* ]] \
  || fail "direct setup lacks shell-safe manual cleanup command"
[[ "$secrets_source" == *'_setup_secrets_cleanup_all "$signal_status" || true'* ]] \
  || fail "direct setup signal cleanup does not preserve visible warnings"

# Exercise successful cleanup, injected file/workspace failures, original-status
# preservation, signal-compatible exits, continued cleanup, and confidential
# diagnostics without running the full setup workflow.
setup_cleanup_block="$(sed -n '/^SETUP_SENSITIVE_CLEANUP_ACTIVE=true$/,/^trap '\''_setup_on_signal 143'\'' TERM$/p' setup.sh)"
direct_cleanup_block="$(sed -n '/^# Secret cleanup lifecycle is script-scoped/,/^# End secret cleanup lifecycle\.$/p' utilities/setup-secrets.sh)"
[[ -n "$setup_cleanup_block" && -n "$direct_cleanup_block" ]] \
  || fail "cleanup lifecycle blocks could not be extracted"

SETUP_CLEANUP_BLOCK="$setup_cleanup_block" bash -s <<'TOP_SETUP_TEST' \
  || fail "top-level sensitive cleanup injected-failure tests failed"
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
TMPDIR="$fixture"
TMP_WORKDIR="$(mktemp -d "$TMPDIR/vw_setup.XXXXXXXX")"
eval "$SETUP_CLEANUP_BLOCK"
trap - EXIT INT HUP TERM

prepare_workspace() {
  TMP_WORKDIR="$(mktemp -d "$TMPDIR/vw_setup.XXXXXXXX")"
  VW_ADMIN_PLAIN_FILE="$TMP_WORKDIR/admin plain;touch PWNED"
  VW_ADMIN_HASH_FILE="$TMP_WORKDIR/admin-hash"
  CADDY_PLAIN_FILE="$TMP_WORKDIR/caddy-plain"
  CADDY_HASH_FILE="$TMP_WORKDIR/caddy-hash"
  printf '%s' 'TOP-SECRET-PLAINTEXT' > "$VW_ADMIN_PLAIN_FILE"
  printf '%s' 'TOP-SECRET-HASH' > "$VW_ADMIN_HASH_FILE"
  printf x > "$CADDY_PLAIN_FILE"
  printf x > "$CADDY_HASH_FILE"
  SETUP_SENSITIVE_CLEANUP_ACTIVE=true
  SETUP_SENSITIVE_CLEANUP_RUNNING=false
  SETUP_SENSITIVE_CLEANUP_FAILED=false
}

prepare_workspace
_setup_remove_sensitive_workspace 0
[[ ! -e "$TMP_WORKDIR" ]]

# Fail one file and the workspace: other individual cleanup actions must still run.
prepare_workspace
blocked_file="$VW_ADMIN_PLAIN_FILE"
blocked_workdir="$TMP_WORKDIR"
rm() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$blocked_file" || "$arg" == "$blocked_workdir" ]]; then
      return 1
    fi
  done
  command rm "$@"
}
set +e
output="$({ set -x; _setup_remove_sensitive_workspace 0; } 2>&1)"
rc=$?
set -e
unset -f rm
(( rc != 0 ))
[[ -e "$blocked_file" ]]
[[ ! -e "$VW_ADMIN_HASH_FILE" && ! -e "$CADDY_PLAIN_FILE" && ! -e "$CADDY_HASH_FILE" ]]
[[ "$output" == *"Residual sensitive path: $blocked_file"* ]]
[[ "$output" == *'Manual cleanup: sudo rm -f -- '* ]]
[[ "$output" != *'TOP-SECRET-PLAINTEXT'* && "$output" != *'TOP-SECRET-HASH'* ]]
[[ ! -e "$fixture/PWNED" ]]
/bin/rm -rf -- "$blocked_workdir"

# Existing operation failure wins even when cleanup also fails.
prepare_workspace
blocked_workdir="$TMP_WORKDIR"
rm() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "$blocked_workdir" ]] && return 1
  done
  command rm "$@"
}
set +e
_setup_remove_sensitive_workspace 37 >/dev/null 2>&1
rc=$?
set -e
unset -f rm
[[ "$rc" == 37 ]]
/bin/rm -rf -- "$blocked_workdir"

# Signal handlers preserve conventional statuses and keep residual warnings visible.
for signal_status in 129 130 143; do
  prepare_workspace
  blocked_workdir="$TMP_WORKDIR"
  rm() {
    local arg
    for arg in "$@"; do
      [[ "$arg" == "$blocked_workdir" ]] && return 1
    done
    command rm "$@"
  }
  set +e
  signal_output="$( ( _setup_on_signal "$signal_status" ) 2>&1)"
  rc=$?
  set -e
  unset -f rm
  [[ "$rc" == "$signal_status" ]]
  [[ "$signal_output" == *"Residual sensitive path: $blocked_workdir"* ]]
  /bin/rm -rf -- "$blocked_workdir"
done

/bin/rm -rf -- "$fixture"
trap - EXIT
TOP_SETUP_TEST

DIRECT_CLEANUP_BLOCK="$direct_cleanup_block" bash -s <<'DIRECT_SETUP_TEST' \
  || fail "direct setup sensitive cleanup injected-failure tests failed"
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
cleanup_secrets_environment() { return 0; }
PROJECT_ROOT="$(mktemp -d)"
trap '/bin/rm -rf -- "$PROJECT_ROOT"' EXIT
TMP_WORKDIR="$(mktemp -d "$PROJECT_ROOT/vw_tmp.XXXXXXXX")"
eval "$DIRECT_CLEANUP_BLOCK"
trap - EXIT INT HUP TERM

prepare_workspace() {
  TMP_WORKDIR="$(mktemp -d "$PROJECT_ROOT/vw_tmp.XXXXXXXX")"
  SETUP_SECRETS_TMP_WORKDIR="$TMP_WORKDIR"
  SETUP_SECRETS_CLEANUP_ACTIONS=()
  SETUP_SECRETS_COLLECTED_SECRETS=([admin_token]='DIRECT-SECRET-HASH')
  SETUP_SECRETS_CLEANUP_ACTIVE=true
  SETUP_SECRETS_CLEANUP_DONE=false
  SETUP_SECRETS_CLEANUP_RUNNING=false
  SETUP_SECRETS_CLEANUP_FAILED=false
}

prepare_workspace
first="$TMP_WORKDIR/first secret;touch PWNED"
second="$TMP_WORKDIR/second"
printf '%s' 'DIRECT-SECRET-PLAINTEXT' > "$first"
printf x > "$second"
_ss_register_cleanup "$first"
_ss_register_cleanup "$second"
_ss_perform_cleanup 0
[[ ! -e "$TMP_WORKDIR" ]]

# An out-of-custody path is refused and discarded without becoming a cleanup
# failure, reaching rm, or producing an unsafe manual deletion command.
prepare_workspace
owned="$TMP_WORKDIR/owned"
printf x > "$owned"
_ss_register_cleanup "$owned"
_ss_register_cleanup "/etc/passwd"
rm_log="$PROJECT_ROOT/refused-rm.log"
rm() {
  printf '%q ' "$@" >> "$rm_log"
  printf '\n' >> "$rm_log"
  command rm "$@"
}
refused_log="$PROJECT_ROOT/refused-output.log"
set +e
_ss_perform_cleanup 0 > "$refused_log" 2>&1
refused_rc=$?
set -e
unset -f rm
refused_output="$(cat "$refused_log")"
(( refused_rc == 0 ))
[[ ! -e "$owned" && ! -e "$TMP_WORKDIR" ]]
[[ ${#SETUP_SECRETS_CLEANUP_ACTIONS[@]} -eq 0 ]]
[[ "${SETUP_SECRETS_CLEANUP_ACTIVE:-true}" == "false" ]]
[[ "${SETUP_SECRETS_CLEANUP_DONE:-false}" == "true" ]]
[[ "$refused_output" == *"Refusing cleanup outside approved temporary or secrets paths: /etc/passwd"* ]]
[[ "$refused_output" != *"Manual cleanup:"* ]]
! grep -Fq '/etc/passwd' "$rm_log"
/bin/rm -f -- "$rm_log" "$refused_log"

# An unsafe workspace is a nonzero cleanup failure, but it is never passed to
# rm and never produces an unsafe recursive manual-deletion command.
prepare_workspace
orphaned_test_workdir="$TMP_WORKDIR"
SETUP_SECRETS_TMP_WORKDIR="/etc"
unsafe_workdir_log="$PROJECT_ROOT/unsafe-workdir-output.log"
set +e
_ss_perform_cleanup 0 > "$unsafe_workdir_log" 2>&1
unsafe_workdir_rc=$?
set -e
unsafe_workdir_output="$(cat "$unsafe_workdir_log")"
(( unsafe_workdir_rc != 0 ))
[[ "${SETUP_SECRETS_CLEANUP_ACTIVE:-false}" == "true" ]]
[[ "${SETUP_SECRETS_CLEANUP_DONE:-true}" == "false" ]]
[[ "${SETUP_SECRETS_CLEANUP_FAILED:-false}" == "true" ]]
[[ "${SETUP_SECRETS_TMP_WORKDIR:-}" == "/etc" ]]
[[ "$unsafe_workdir_output" == *"Refusing unsafe temporary workspace removal: /etc"* ]]
[[ "$unsafe_workdir_output" != *"Manual cleanup:"* ]]
/bin/rm -rf -- "$orphaned_test_workdir"
/bin/rm -f -- "$unsafe_workdir_log"

# Reverse-order cleanup continues after a failure and then attempts the workspace.
prepare_workspace
first="$TMP_WORKDIR/first secret;touch PWNED"
second="$TMP_WORKDIR/second"
printf '%s' 'DIRECT-SECRET-PLAINTEXT' > "$first"
printf x > "$second"
_ss_register_cleanup "$second"
_ss_register_cleanup "$first"
blocked_file="$first"
blocked_workdir="$TMP_WORKDIR"
rm() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$blocked_file" || "$arg" == "$blocked_workdir" ]]; then
      return 1
    fi
  done
  command rm "$@"
}
failure_log="$PROJECT_ROOT/approved-failure-output.log"
set +e
{ set -x; _ss_perform_cleanup 0; } > "$failure_log" 2>&1
rc=$?
set -e
unset -f rm
output="$(cat "$failure_log")"
(( rc != 0 ))
[[ -e "$blocked_file" && ! -e "$second" ]]
[[ ${#SETUP_SECRETS_CLEANUP_ACTIONS[@]} -eq 1 ]]
[[ "${SETUP_SECRETS_CLEANUP_ACTIONS[0]}" == "$blocked_file" ]]
[[ "$output" == *"Residual sensitive path: $blocked_file"* ]]
[[ "$output" == *'Manual cleanup: sudo rm -f -- '* ]]
[[ "$output" != *'DIRECT-SECRET-PLAINTEXT'* && "$output" != *'DIRECT-SECRET-HASH'* ]]
[[ ! -e "$PROJECT_ROOT/PWNED" ]]
/bin/rm -rf -- "$blocked_workdir"
/bin/rm -f -- "$failure_log"

# Existing failure and all conventional signal statuses remain authoritative.
prepare_workspace
blocked_workdir="$TMP_WORKDIR"
rm() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "$blocked_workdir" ]] && return 1
  done
  command rm "$@"
}
set +e
_ss_perform_cleanup 42 >/dev/null 2>&1
rc=$?
set -e
unset -f rm
[[ "$rc" == 42 ]]
/bin/rm -rf -- "$blocked_workdir"

for signal_status in 129 130 143; do
  prepare_workspace
  blocked_workdir="$TMP_WORKDIR"
  rm() {
    local arg
    for arg in "$@"; do
      [[ "$arg" == "$blocked_workdir" ]] && return 1
    done
    command rm "$@"
  }
  set +e
  signal_output="$( ( _setup_secrets_on_signal "$signal_status" ) 2>&1)"
  rc=$?
  set -e
  unset -f rm
  [[ "$rc" == "$signal_status" ]]
  [[ "$signal_output" == *"Residual sensitive path: $blocked_workdir"* ]]
  /bin/rm -rf -- "$blocked_workdir"
done

/bin/rm -rf -- "$PROJECT_ROOT"
trap - EXIT
DIRECT_SETUP_TEST

python3 - <<'PY_ORDER' || fail "success-summary ordering is unsafe"
from pathlib import Path
setup = Path('setup.sh').read_text()
secrets = Path('utilities/setup-secrets.sh').read_text()
start = setup.index('credential_file="$(publish_setup_credentials')
assert setup.index('_setup_remove_sensitive_workspace 0', start) < setup.index('│  SETUP CREDENTIALS SAVED', start)
start = secrets.index('_ss_publish_auto_handoff || return 1')
assert secrets.index('_ss_perform_cleanup 0', start) < secrets.index('Secrets Setup Complete!', start)
PY_ORDER

pass "recovery fallback and sensitive cleanup contracts"
