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

# Enumeration failure is visible, returns nonzero, and processes no partial list.
enum_fail="$RECOVERY_KIT_DIR/vaultwarden-recovery-kit-20260727T121300Z-a1b2cf.txt"
make_file "$enum_fail"
touch -d '120 seconds ago' "$enum_fail"
real_find="$(command -v find)"
find() {
  if [[ "$*" == *"vaultwarden-recovery-kit-*.txt"* ]]; then
    return 73
  fi
  "$real_find" "$@"
}
set +e
enum_output="$(cleanup_expired_recovery_kits false 2>&1)"
enum_rc=$?
set -e
unset -f find
(( enum_rc != 0 )) || exit 1
[[ -e "$enum_fail" ]] || exit 1
[[ "$enum_output" == *"failed to enumerate recovery-kit candidates"* ]] || exit 1
[[ "$enum_output" != *"Removed expired plaintext recovery kit"* ]] || exit 1
/bin/rm -f -- "$enum_fail"
# An absent test directory is an idempotent no-op and is not created.
absent="${RECOVERY_KIT_DIR}.absent"
RECOVERY_KIT_DIR="$absent" cleanup_expired_recovery_kits false
[[ ! -e "$absent" ]] || exit 1
ROOT_TEST
else
  printf 'SKIP root-owned recovery fixture: passwordless sudo unavailable\n'
fi

# Cleanup failures are explicit and signal-compatible in both setup files.
setup_source="$(cat setup.sh setup-main.sh)"
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
setup_cleanup_block="$(sed -n '/^# Establish setup-owned cleanup custody before any workspace is created\.$/,/^SETUP_BOOTSTRAP_CLEANUP_ACTIVE=false$/p' setup-main.sh)"
direct_cleanup_block="$(sed -n '/^# Secret cleanup lifecycle is script-scoped/,/^# End secret cleanup lifecycle\.$/p' utilities/setup-secrets.sh)"
[[ -n "$setup_cleanup_block" && -n "$direct_cleanup_block" ]] \
  || fail "cleanup lifecycle blocks could not be extracted"
# Workspace-only cleanup covers failures and signals before full custody exists.
bootstrap_fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$bootstrap_fixture"' EXIT
mkdir -p -- "$bootstrap_fixture/repository"
run_bootstrap_case() {
  local case_name="$1" expected_status="$2" expect_residual="${3:-false}"
  local case_root="$bootstrap_fixture/$case_name" case_tmp
  local case_output case_rc residual
  case_tmp="$case_root/temp root"
  mkdir -p -- "$case_tmp"
  set +e
  case_output="$(
    PROJECT_ROOT="$bootstrap_fixture/repository" \
    TMPDIR="$case_tmp" \
    BOOTSTRAP_CASE="$case_name" \
    SETUP_CLEANUP_BLOCK="$setup_cleanup_block" \
    bash -s 2>&1 <<'BOOTSTRAP_SETUP_TEST'
set -euo pipefail
real_realpath="$(command -v realpath)"
real_stat="$(command -v stat)"
real_rmdir="$(command -v rmdir)"
realpath() {
  if [[ "$*" == *'/vw_setup.'* ]]; then
    case "$BOOTSTRAP_CASE" in
      canonicalization|cleanup_failure) return 41 ;;
      early_signal)
        kill -TERM "$PPID"
        sleep 1
        return 99
        ;;
    esac
  fi
  "$real_realpath" "$@"
}
stat() {
  if [[ "$BOOTSTRAP_CASE" == "identity" && "$*" == *'/vw_setup.'* ]]; then
    return 42
  fi
  "$real_stat" "$@"
}
rmdir() {
  if [[ "$BOOTSTRAP_CASE" == "cleanup_failure" ]]; then
    return 73
  fi
  "$real_rmdir" "$@"
}
eval "$SETUP_CLEANUP_BLOCK"
BOOTSTRAP_SETUP_TEST
  )"
  case_rc=$?
  set -e
  [[ "$case_rc" == "$expected_status" ]] \
    || fail "$case_name returned $case_rc instead of $expected_status: $case_output"
  residual="$(find -P "$case_tmp" -mindepth 1 -maxdepth 1 -name 'vw_setup.*' -print -quit)"
  if [[ "$expect_residual" == "true" ]]; then
    [[ -n "$residual" ]] || fail "$case_name did not preserve the injected cleanup residual"
    [[ "$case_output" == *"Failed to remove the validated empty setup workspace"* ]] \
      || fail "$case_name did not report the bootstrap cleanup failure"
  else
    [[ -z "$residual" ]] || fail "$case_name left a temporary workspace behind"
  fi
  case "$case_name" in
    canonicalization|cleanup_failure)
      [[ "$case_output" == *"Failed to resolve secure temporary directory"* ]] \
        || fail "$case_name did not report the primary initialization failure"
      ;;
    identity)
      [[ "$case_output" == *"Failed to record secure temporary directory identity"* ]] \
        || fail "identity failure diagnostic is missing"
      ;;
  esac
  /bin/rm -rf -- "$case_root"
}
run_bootstrap_case canonicalization 41
run_bootstrap_case identity 42
run_bootstrap_case early_signal 143
run_bootstrap_case cleanup_failure 41 true
/bin/rm -rf -- "$bootstrap_fixture"
trap - EXIT
SETUP_CLEANUP_BLOCK="$setup_cleanup_block" bash -s <<'TOP_SETUP_TEST' \
  || fail "top-level sensitive cleanup custody tests failed"
set -euo pipefail
log_warn() { printf 'WARN %s\n' "$*" >&2; }
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
PROJECT_ROOT="$fixture/repository"
mkdir -p -- "$PROJECT_ROOT"
TMPDIR="$fixture/temp root;meta"
mkdir -p -- "$TMPDIR"
external="$fixture/external-sensitive"
printf '%s' 'EXTERNAL-SECRET-MUST-NOT-APPEAR' > "$external"
VW_ADMIN_PLAIN_FILE="$external"
VW_ADMIN_HASH_FILE="/etc/passwd"
CADDY_PLAIN_FILE="$external"
CADDY_HASH_FILE="$external"
TMP_WORKDIR="/etc"
eval "$SETUP_CLEANUP_BLOCK"
trap - EXIT INT HUP TERM
[[ -e "$external" ]]
[[ -z "${VW_ADMIN_PLAIN_FILE+x}" && -z "${VW_ADMIN_HASH_FILE+x}" ]]
first_workspace="$SETUP_OWNED_WORKDIR"
set +e
_setup_remove_sensitive_workspace 17 >/dev/null 2>&1
first_rc=$?
set -e
[[ "$first_rc" == 17 ]]
[[ ! -e "$first_workspace" ]]
prepare_workspace() {
  TMP_WORKDIR="$(mktemp -d "${SETUP_TEMP_ROOT}/vw_setup.XXXXXXXXXX")"
  SETUP_OWNED_WORKDIR="$(realpath -e -- "$TMP_WORKDIR")"
  SETUP_OWNED_WORKDIR_ID="$(stat -c '%d:%i' -- "$SETUP_OWNED_WORKDIR")"
  VW_ADMIN_PLAIN_FILE="$TMP_WORKDIR/vw_admin_plain"
  VW_ADMIN_HASH_FILE="$TMP_WORKDIR/vw_admin_hash"
  CADDY_PLAIN_FILE="$TMP_WORKDIR/caddy_plain"
  CADDY_HASH_FILE="$TMP_WORKDIR/caddy_hash"
  printf '%s' 'TOP-SECRET-PLAINTEXT' > "$VW_ADMIN_PLAIN_FILE"
  printf '%s' 'TOP-SECRET-HASH' > "$VW_ADMIN_HASH_FILE"
  printf x > "$CADDY_PLAIN_FILE"
  printf x > "$CADDY_HASH_FILE"
  SETUP_SENSITIVE_CLEANUP_ACTIVE=true
  SETUP_SENSITIVE_CLEANUP_RUNNING=false
  SETUP_SENSITIVE_CLEANUP_FAILED=false
}
prepare_workspace
owned_workspace="$TMP_WORKDIR"
_setup_remove_sensitive_workspace 0
[[ ! -e "$owned_workspace" ]]
# Out-of-custody inherited-style values are never passed to rm or used in commands.
prepare_workspace
owned_workspace="$TMP_WORKDIR"
VW_ADMIN_PLAIN_FILE="$external"
rm_log="$fixture/rm.log"
rm() {
  printf '%q ' "$@" >> "$rm_log"
  printf '\n' >> "$rm_log"
  command rm "$@"
}
set +e
refused_output="$(_setup_remove_sensitive_workspace 0 2>&1)"
refused_rc=$?
set -e
unset -f rm
(( refused_rc != 0 ))
[[ -e "$external" && -e "$owned_workspace" ]]
[[ "$refused_output" == *"out-of-custody or unsafe sensitive-file candidate"* ]]
[[ "$refused_output" != *"Manual cleanup:"* ]]
[[ "$refused_output" != *"EXTERNAL-SECRET-MUST-NOT-APPEAR"* ]]
! grep -Fq -- "$external" "$rm_log"
/bin/rm -rf -- "$owned_workspace"
/bin/rm -f -- "$rm_log"
# Protected and broad paths are rejected without destructive guidance.
for broad in /etc /tmp; do
  prepare_workspace
  owned_workspace="$SETUP_OWNED_WORKDIR"
  TMP_WORKDIR="$broad"
  VW_ADMIN_PLAIN_FILE="/etc/passwd"
  set +e
  broad_output="$(_setup_remove_sensitive_workspace 0 2>&1)"
  broad_rc=$?
  set -e
  (( broad_rc != 0 ))
  [[ -e /etc/passwd ]]
  [[ "$broad_output" != *"Manual cleanup:"* ]]
  [[ "$broad_output" != *"sudo rm -rf -- $broad"* ]]
  /bin/rm -rf -- "$owned_workspace"
done
# A symlink candidate and a replaced workspace are left untouched.
prepare_workspace
owned_workspace="$SETUP_OWNED_WORKDIR"
/bin/rm -f -- "$VW_ADMIN_PLAIN_FILE"
ln -s -- "$external" "$VW_ADMIN_PLAIN_FILE"
set +e
symlink_output="$(_setup_remove_sensitive_workspace 0 2>&1)"
symlink_rc=$?
set -e
(( symlink_rc != 0 ))
[[ -L "$VW_ADMIN_PLAIN_FILE" && -e "$external" && -d "$owned_workspace" ]]
[[ "$symlink_output" != *"Manual cleanup:"* ]]
/bin/rm -rf -- "$owned_workspace"
prepare_workspace
owned_workspace="$SETUP_OWNED_WORKDIR"
moved_workspace="${owned_workspace}.moved"
mv -- "$owned_workspace" "$moved_workspace"
ln -s -- "$moved_workspace" "$owned_workspace"
set +e
workspace_output="$(_setup_remove_sensitive_workspace 0 2>&1)"
workspace_rc=$?
set -e
(( workspace_rc != 0 ))
[[ -L "$owned_workspace" && -d "$moved_workspace" ]]
[[ "$workspace_output" != *"Manual cleanup:"* ]]
/bin/rm -f -- "$owned_workspace"
/bin/rm -rf -- "$moved_workspace"
# Failed removal of a validated path may emit a shell-quoted manual command.
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
failure_output="$({ set -x; _setup_remove_sensitive_workspace 0; } 2>&1)"
failure_rc=$?
set -e
unset -f rm
(( failure_rc != 0 ))
[[ -e "$blocked_file" ]]
[[ "$failure_output" == *"Residual validated setup-owned sensitive path: $blocked_file"* ]]
[[ "$failure_output" == *"Manual cleanup: sudo rm -f -- "* ]]
[[ "$failure_output" != *"TOP-SECRET-PLAINTEXT"* && "$failure_output" != *"TOP-SECRET-HASH"* ]]
/bin/rm -rf -- "$blocked_workdir"
# Existing operation and conventional signal statuses remain authoritative.
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
status_rc=$?
set -e
unset -f rm
[[ "$status_rc" == 37 ]]
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
  signal_output="$( ( _setup_on_signal "$signal_status" ) 2>&1)"
  signal_rc=$?
  set -e
  unset -f rm
  [[ "$signal_rc" == "$signal_status" ]]
  [[ "$signal_output" == *"Residual validated setup-owned sensitive path: $blocked_workdir"* ]]
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

# Ubuntu 7zip package and executable-selection contracts.
# Exact apt dependency-array tokenization contract.
python3 - <<'PY_PACKAGES' \
  || fail "dependency package array tokenization contract failed"
from pathlib import Path
import re
import shlex

expected = [
    "age", "make", "nano", "rclone", "sqlite3", "jq", "ufw", "curl",
    "wget", "unzip", "7zip", "git", "gpg", "coreutils", "util-linux",
    "haveged", "dnsutils", "rsync", "python3", "python3-argon2",
    "python3-bcrypt", "python3-yaml", "apache2-utils", "cron", "openssl",
    "tar", "zstd",
]
text = Path("utilities/setup-system.sh").read_text(encoding="utf-8")
matches = re.findall(
    r"(?m)^[ \t]*local basic_packages=\((.*)\)[ \t]*$",
    text,
)
if len(matches) != 1:
    raise SystemExit(
        f"expected one basic_packages declaration, found {len(matches)}"
    )
actual = shlex.split(matches[0], posix=True)
if actual != expected:
    raise SystemExit(
        "basic_packages tokenization mismatch:\n"
        f"expected={expected!r}\nactual={actual!r}"
    )
PY_PACKAGES
grep -Fq '"unzip" "7zip" "git"' utilities/setup-system.sh \
  || fail "normal dependency list does not install Ubuntu 7zip"
grep -Fq '"dnsutils" "rsync" "python3" "python3-argon2"' utilities/setup-system.sh \
  || fail "dependency list must keep rsync and python3 as separate package entries"
! grep -Fq '"rsync""python3"' utilities/setup-system.sh \
  || fail "dependency list contains a concatenated rsync/python3 package token"
! grep -Eq '^[[:space:]]*\[7zip\]=' utilities/setup-system.sh \
  || fail "generic dependency map must not claim one guaranteed 7-Zip executable"
grep -Fq 'for candidate in 7zz 7z; do' utilities/setup-system.sh \
  || fail "setup dependency resolver does not prefer 7zz with 7z fallback"
grep -Fq '_require_7zip_command || return 1' utilities/setup-system.sh \
  || fail "--skip-deps verification does not require a usable 7-Zip executable"
grep -Fq 'Install hint: sudo apt-get install -y 7zip' utilities/setup-system.sh \
  || fail "setup-system 7zip installation guidance is incorrect"
cat setup.sh setup-main.sh | grep -Fq 'sudo apt-get install -y docker.io age sops 7zip python3-argon2 python3-bcrypt' \
  || fail "top-level setup phase guidance omits 7zip"
grep -Fq 'for candidate in 7zz 7z; do' lib/secrets.sh \
  || fail "recovery ZIP helper does not prefer 7zz with 7z fallback"
grep -Fq 'a -tzip -mem=AES256' lib/secrets.sh \
  || fail "recovery artifact is no longer an AES-256 encrypted ZIP"
resolver_block="$(sed -n '/^_resolve_7zip_command() {/,/^# Install the required system packages/p' utilities/setup-system.sh | sed '$d')"
[[ -n "$resolver_block" ]] || fail "7zip resolver block could not be extracted"
RESOLVER_BLOCK="$resolver_block" bash -s <<'SEVENZIP_TEST' \
  || fail "7zip executable resolution tests failed"
set -euo pipefail
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_debug() { :; }
eval "$RESOLVER_BLOCK"
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
make_cmd() {
  local dir="$1" name="$2"
  mkdir -p -- "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$name"
  chmod 0755 "$dir/$name"
}
preferred="$fixture/preferred"
make_cmd "$preferred" 7zz
[[ "$(PATH="$preferred" _resolve_7zip_command)" == 7zz ]]
PATH="$preferred" _require_7zip_command
both="$fixture/both"
make_cmd "$both" 7zz
make_cmd "$both" 7z
[[ "$(PATH="$both" _resolve_7zip_command)" == 7zz ]]
PATH="$both" _require_7zip_command
fallback="$fixture/fallback"
make_cmd "$fallback" 7z
[[ "$(PATH="$fallback" _resolve_7zip_command)" == 7z ]]
PATH="$fallback" _require_7zip_command
empty="$fixture/empty"
mkdir -p -- "$empty"
set +e
missing_output="$(PATH="$empty" _require_7zip_command 2>&1)"
missing_rc=$?
set -e
(( missing_rc != 0 ))
[[ "$missing_output" == *"expected 7zz (preferred) or 7z"* ]]
[[ "$missing_output" == *"sudo apt-get install -y 7zip"* ]]
/bin/rm -rf -- "$fixture"
trap - EXIT
SEVENZIP_TEST
python3 - <<'PY_ORDER' || fail "success-summary ordering is unsafe"
from pathlib import Path
setup = Path('setup.sh').read_text() + Path('setup-main.sh').read_text()
secrets = Path('utilities/setup-secrets.sh').read_text()
start = setup.index('credential_file="$(publish_setup_credentials')
assert setup.index('_setup_remove_sensitive_workspace 0', start) < setup.index('│  SETUP CREDENTIALS SAVED', start)
start = secrets.index('_ss_publish_auto_handoff || return 1')
assert secrets.index('_ss_perform_cleanup 0', start) < secrets.index('Secrets Setup Complete!', start)
PY_ORDER

pass "recovery fallback and sensitive cleanup contracts"
