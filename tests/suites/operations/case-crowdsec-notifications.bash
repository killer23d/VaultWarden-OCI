#!/usr/bin/env bash
# Focused regression coverage for the CrowdSec email control wrapper.

set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"
# shellcheck source=../../lib/assertions.bash
source "$VW_TEST_REPO_ROOT/tests/lib/assertions.bash"
# shellcheck source=../../lib/command-mocks.bash
source "$VW_TEST_REPO_ROOT/tests/lib/command-mocks.bash"

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_no_backups() {
    if compgen -G "${VW_CROWDSEC_EMAIL_ENV_FILE}.backup.*" >/dev/null; then
        test_fail 'temporary .env backup was not removed'
    fi
}
assert_lock_free() {
    flock -n "$VW_OPERATIONS_LOCK" true || test_fail 'VaultWarden operation lock remained held'
    flock -n "$VW_TEST_SPECIFIC_LOCK" true || test_fail 'CrowdSec setup lock remained held'
}

FIXTURE="$TMP/project"
BIN="$TMP/bin"
ETC="$TMP/crowdsec"
CALLS="$TMP/calls.log"
PLUGIN="$ETC/notifications/vaultwarden-email.yaml"
PROFILES="$ETC/profiles.yaml.local"
mkdir -p "$FIXTURE/utilities" "$FIXTURE/lib" "$BIN" "$ETC/notifications"
chmod 0755 "$TMP" "$FIXTURE" "$FIXTURE/utilities" "$FIXTURE/lib" "$ETC" "$ETC/notifications"
cp "$ROOT/utilities/crowdsec-email.sh" "$FIXTURE/utilities/"
cp "$ROOT/lib/log.sh" "$ROOT/lib/common.sh" "$ROOT/lib/operations.sh" "$FIXTURE/lib/"
chmod +x "$FIXTURE/utilities/crowdsec-email.sh"

setup_begin="$(sed -n 's/^_CS_EMAIL_PROFILE_BEGIN="\(.*\)"$/\1/p' "$ROOT/utilities/setup-crowdsec.sh")"
setup_end="$(sed -n 's/^_CS_EMAIL_PROFILE_END="\(.*\)"$/\1/p' "$ROOT/utilities/setup-crowdsec.sh")"
wrapper_begin="$(sed -n 's/^PROFILE_BEGIN="\(.*\)"$/\1/p' "$ROOT/utilities/crowdsec-email.sh")"
wrapper_end="$(sed -n 's/^PROFILE_END="\(.*\)"$/\1/p' "$ROOT/utilities/crowdsec-email.sh")"
[[ -n "$setup_begin" && -n "$setup_end" ]] || test_fail 'production profile markers were not found'
test_assert_equal "$wrapper_begin" "$setup_begin"
test_assert_equal "$wrapper_end" "$setup_end"

cat >"$FIXTURE/utilities/setup-crowdsec.sh" <<'EOF_SETUP'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/operations.sh"
mode=full
[[ "${1:-}" == --reconcile-email ]] && mode=direct
origin="$mode"
[[ "${VW_OPERATION_PARENT_ID:-}" == crowdsec-email-control ]] && origin=wrapper
read_flag(){ awk -F= '$1 == "CROWDSEC_EMAIL_NOTIFICATIONS" { value=$2 } END { print value }' "${VW_CROWDSEC_EMAIL_ENV_FILE:?}"; }
pre_flag="$(read_flag)"
if [[ "${VW_TEST_PRELOCK_PAUSE_ORIGIN:-}" == "$origin" ]]; then
    : >"${VW_TEST_PRELOCK_MARKER:?}"
    IFS= read -r _ <"${VW_TEST_PRELOCK_FIFO:?}"
fi
operation_acquire \
    --id crowdsec-setup \
    --label 'CrowdSec setup' \
    --specific-lock "${VW_TEST_SPECIFIC_LOCK:?}" \
    --non-interactive wait
cleanup(){
    local rc=$?
    trap - EXIT INT HUP TERM
    operation_release "$rc"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
post_flag="$(read_flag)"
printf 'enter origin=%s pre=%s post=%s\n' "$origin" "$pre_flag" "$post_flag" >>"${VW_TEST_CALLS:?}"
operation_run_without_guard_fds bash -c '
    for fd in /proc/$$/fd/*; do
        target=$(readlink "$fd" 2>/dev/null || true)
        case "$target" in
            "${VW_OPERATIONS_LOCK:?}"|"${VW_TEST_SPECIFIC_LOCK:?}") exit 98 ;;
        esac
    done
' || { printf 'descriptor-leak origin=%s\n' "$origin" >>"${VW_TEST_CALLS:?}"; exit 98; }
if [[ "${VW_TEST_PAUSE_ORIGIN:-}" == "$origin" && ! -e "${VW_TEST_PAUSE_MARKER:?}" ]]; then
    : >"$VW_TEST_PAUSE_MARKER"
    IFS= read -r _ <"${VW_TEST_PAUSE_FIFO:?}"
fi
plugin="${VW_CROWDSEC_ETC_DIR:?}/notifications/vaultwarden-email.yaml"
profiles="${VW_CROWDSEC_ETC_DIR:?}/profiles.yaml.local"
if [[ "$post_flag" == true ]]; then
    mkdir -p "$(dirname "$plugin")"
    printf '# Managed by VaultWarden-OCI: CrowdSec email notification\n' >"$plugin"
    printf '%s\n%s\n' "${VW_TEST_PROFILE_BEGIN:?}" "${VW_TEST_PROFILE_END:?}" >"$profiles"
else
    rm -f "$plugin" "$profiles"
fi
printf 'exit origin=%s post=%s\n' "$origin" "$post_flag" >>"${VW_TEST_CALLS:?}"
if [[ -n "${VW_CROWDSEC_EMAIL_COMMIT_MARKER:-}" ]]; then
    marker_stage="$(mktemp "${VW_CROWDSEC_EMAIL_COMMIT_MARKER}.tmp.XXXXXXXX")"
    printf '%s\n' "${VW_CROWDSEC_EMAIL_COMMIT_TOKEN:?}" >"$marker_stage"
    chmod 0600 "$marker_stage"
    mv -fT -- "$marker_stage" "$VW_CROWDSEC_EMAIL_COMMIT_MARKER"
fi
if [[ -n "${VW_TEST_FAKE_EXIT_AFTER_COMMIT:-}" ]]; then
    exit "$VW_TEST_FAKE_EXIT_AFTER_COMMIT"
fi
EOF_SETUP
chmod +x "$FIXTURE/utilities/setup-crowdsec.sh"

cat >"$BIN/cscli" <<'EOF_CSCLI'
#!/usr/bin/env bash
printf 'cscli %s\n' "$*" >>"${VW_TEST_CALLS:?}"
EOF_CSCLI
chmod +x "$BIN/cscli"

cat >"$BIN/crowdsec" <<'EOF_CROWDSEC'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -t ]] || exit 2
for fd in /proc/$$/fd/*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
        "${VW_OPERATIONS_LOCK:?}"|"${VW_TEST_SPECIFIC_LOCK:?}") exit 98 ;;
    esac
done
printf 'crowdsec -t\n' >>"${VW_TEST_CALLS:?}"
EOF_CROWDSEC
chmod +x "$BIN/crowdsec"

cat >"$BIN/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == restart && "${2:-}" == crowdsec ]] || exit 0
for fd in /proc/$$/fd/*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
        "${VW_OPERATIONS_LOCK:?}"|"${VW_TEST_SPECIFIC_LOCK:?}") exit 98 ;;
    esac
done
printf 'systemctl restart crowdsec\n' >>"${VW_TEST_CALLS:?}"
EOF_SYSTEMCTL
chmod +x "$BIN/systemctl"

PRODUCTION_SETUP="$TMP/production-email-setup.sh"
cat >"$PRODUCTION_SETUP" <<'EOF_PROD_HEADER'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="${VW_TEST_PROJECT_ROOT:?}"
_CS_LAPI_COHORT_ROOT="${VW_CROWDSEC_ETC_DIR:?}"
log_info(){ printf 'INFO: %s\n' "$*" >>"${VW_TEST_CALLS:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >>"${VW_TEST_CALLS:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >>"${VW_TEST_CALLS:?}"; }
log_success(){ printf 'SUCCESS: %s\n' "$*" >>"${VW_TEST_CALLS:?}"; }
install(){
    local -a args=()
    while (( $# )); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
chown(){ return 0; }
EOF_PROD_HEADER
sed -n '/^_CS_EMAIL_PLUGIN_MARKER=/,/^# CLI flags/p' "$ROOT/utilities/setup-crowdsec.sh" | sed '$d' >>"$PRODUCTION_SETUP"
cat >>"$PRODUCTION_SETUP" <<'EOF_PROD_FOOTER'
DRY_RUN=false
# shellcheck source=/dev/null
source "${VW_CROWDSEC_OPERATIONS_LIB:?}"
operation_acquire \
    --id crowdsec-setup \
    --label 'CrowdSec setup' \
    --specific-lock "${VW_TEST_SPECIFIC_LOCK:?}" \
    --non-interactive wait
cleanup(){
    local rc=$?
    trap - EXIT INT HUP TERM
    operation_release "$rc"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
_cs_reload_email_environment
if _cs_reconcile_email_notifications; then
    exit 0
else
    exit $?
fi
EOF_PROD_FOOTER
chmod +x "$PRODUCTION_SETUP"

export PATH="$BIN:$PATH"
export VW_TEST_MODE=1
export VAULTWARDEN_TEST_ALLOW_NON_ROOT=1
export VW_CROWDSEC_EMAIL_ENV_FILE="$FIXTURE/.env"
export VW_CROWDSEC_SETUP_SCRIPT="$FIXTURE/utilities/setup-crowdsec.sh"
export VW_CROWDSEC_OPERATIONS_LIB="$FIXTURE/lib/operations.sh"
export VW_CROWDSEC_ETC_DIR="$ETC"
export VW_OPERATIONS_LOCK="$TMP/operations.lock"
export VW_OPERATIONS_STATE_DIR="$TMP/operation-state"
export VW_OPERATIONS_WAIT_INTERVAL=1
export VW_OPERATIONS_WAIT_LIMIT=20
export VW_TEST_SPECIFIC_LOCK="$TMP/crowdsec-setup.lock"
export VW_TEST_CALLS="$CALLS"
export VW_TEST_PROFILE_BEGIN="$setup_begin"
export VW_TEST_PROFILE_END="$setup_end"
export VW_TEST_PROJECT_ROOT="$ROOT"

cat >"$VW_CROWDSEC_EMAIL_ENV_FILE" <<'EOF_ENV'
CROWDSEC_EMAIL_NOTIFICATIONS=false
ADMIN_EMAIL=admin@example.com
SMTP_FROM=vaultwarden@example.com
ALLOWED_SENDER_DOMAINS=example.com
EOF_ENV
chmod 0600 "$VW_CROWDSEC_EMAIL_ENV_FILE"

run_control() { bash "$FIXTURE/utilities/crowdsec-email.sh" "$@"; }
run_setup() { bash "$FIXTURE/utilities/setup-crowdsec.sh" "$@"; }
set_flag() { printf 'CROWDSEC_EMAIL_NOTIFICATIONS=%s\nADMIN_EMAIL=admin@example.com\nSMTP_FROM=vaultwarden@example.com\nALLOWED_SENDER_DOMAINS=example.com\n' "$1" >"$VW_CROWDSEC_EMAIL_ENV_FILE"; chmod 0600 "$VW_CROWDSEC_EMAIL_ENV_FILE"; }
write_plugin() { printf '# Managed by VaultWarden-OCI: CrowdSec email notification\n' >"$PLUGIN"; }
write_profile() { printf '%s\n%s\n' "$setup_begin" "$setup_end" >"$PROFILES"; }
clear_managed() { rm -f "$PLUGIN" "$PROFILES"; }
snapshot_path() {
    local path="$1" prefix="$2"
    if [[ -e "$path" ]]; then
        printf 'true\n' >"${prefix}.exists"
        cp -p "$path" "${prefix}.content"
        stat -c '%a %u %g' "$path" >"${prefix}.meta"
    else
        printf 'false\n' >"${prefix}.exists"
        rm -f "${prefix}.content" "${prefix}.meta"
    fi
}
assert_snapshot() {
    local path="$1" prefix="$2" existed
    existed="$(cat "${prefix}.exists")"
    if [[ "$existed" == true ]]; then
        [[ -f "$path" ]] || test_fail "restored path is missing: $path"
        cmp -s "${prefix}.content" "$path" || test_fail "restored content differs: $path"
        test_assert_equal "$(stat -c '%a %u %g' "$path")" "$(cat "${prefix}.meta")"
    else
        [[ ! -e "$path" ]] || test_fail "path should have remained absent: $path"
    fi
}
assert_no_email_temps() {
    if find "$ETC" -name '.vw-email-*' -print -quit | grep -q .; then
        find "$ETC" -name '.vw-email-*' -print >&2
        test_fail 'CrowdSec email transaction left temporary files behind'
    fi
}
assert_partial() {
    local flag="$1" shape="$2" output
    output="$TMP/partial-${flag}-${shape}.out"
    set_flag "$flag"
    clear_managed
    case "$shape" in
        plugin) write_plugin ;;
        profile) write_profile ;;
        *) test_fail "unknown partial shape: $shape" ;;
    esac
    if run_control status >"$output" 2>&1; then
        test_fail "partial state was reported consistent: flag=$flag shape=$shape"
    fi
    test_assert_file_contains "$output" 'Installed:  partial'
    test_assert_file_contains "$output" 'Consistent: false'
}
run_unprivileged_control() {
    local output="$1" test_mode="$2" allow_non_root="$3"
    shift 3
    local -a env_args=(
        "PATH=$PATH"
        "VW_CROWDSEC_EMAIL_ENV_FILE=$VW_CROWDSEC_EMAIL_ENV_FILE"
        "VW_CROWDSEC_SETUP_SCRIPT=$VW_CROWDSEC_SETUP_SCRIPT"
        "VW_CROWDSEC_OPERATIONS_LIB=$VW_CROWDSEC_OPERATIONS_LIB"
        "VW_CROWDSEC_ETC_DIR=$VW_CROWDSEC_ETC_DIR"
        "VW_OPERATIONS_LOCK=$VW_OPERATIONS_LOCK"
        "VW_OPERATIONS_STATE_DIR=$VW_OPERATIONS_STATE_DIR"
        "VW_TEST_SPECIFIC_LOCK=$VW_TEST_SPECIFIC_LOCK"
        "VW_TEST_CALLS=$VW_TEST_CALLS"
    )
    [[ -z "$test_mode" ]] || env_args+=("VW_TEST_MODE=$test_mode")
    [[ -z "$allow_non_root" ]] || env_args+=("VAULTWARDEN_TEST_ALLOW_NON_ROOT=$allow_non_root")

    if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1; then
        runuser -u nobody -- env \
            -u VW_TEST_MODE -u VAULTWARDEN_TEST_ALLOW_NON_ROOT \
            "${env_args[@]}" \
            bash "$FIXTURE/utilities/crowdsec-email.sh" "$@" >"$output" 2>&1
    else
        env -u VW_TEST_MODE -u VAULTWARDEN_TEST_ALLOW_NON_ROOT \
            "${env_args[@]}" \
            bash "$FIXTURE/utilities/crowdsec-email.sh" "$@" >"$output" 2>&1
    fi
}

bash -n "$ROOT/utilities/crowdsec-email.sh"
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" '--reconcile-email'
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" 'operation_acquire'
test_assert_file_not_contains "$ROOT/utilities/crowdsec-email.sh" 'vaultwarden-crowdsec-email-control.lock'
! grep -Eq '^[[:space:]]*(function[[:space:]]+)?(_crowdsec_email_)?require_root[[:space:]]*\(\)' \
    "$ROOT/utilities/crowdsec-email.sh" \
    || test_fail 'CrowdSec email control still defines a local root helper'
test_assert_file_not_contains "$ROOT/utilities/crowdsec-email.sh" '$EUID'
test_assert_file_not_contains "$ROOT/utilities/crowdsec-email.sh" 'is_root'
log_source_line="$(grep -nF 'source "${PROJECT_ROOT}/lib/log.sh"' "$ROOT/utilities/crowdsec-email.sh" | cut -d: -f1)"
common_source_line="$(grep -nF 'source "${PROJECT_ROOT}/lib/common.sh"' "$ROOT/utilities/crowdsec-email.sh" | cut -d: -f1)"
[[ -n "$log_source_line" && -n "$common_source_line" ]] \
    || test_fail 'canonical CrowdSec email library sources are missing'
(( log_source_line < common_source_line )) \
    || test_fail 'CrowdSec email control must source log.sh before common.sh'
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" 'init_common_lib "$0"'
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" 'require_root "$command"'
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" '${VW_TEST_MODE:-0}'
test_assert_file_contains "$ROOT/utilities/crowdsec-email.sh" '${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}'
write_flag_body="$(sed -n '/^write_flag()/,/^}/p' "$ROOT/utilities/crowdsec-email.sh")"
grep -Fq "awk -v value" <<< "$write_flag_body" \
    || test_fail 'CrowdSec email write_flag no longer owns its specialized renderer'
! grep -Fq '_set_env_var' <<< "$write_flag_body" \
    || test_fail 'CrowdSec email write_flag was incorrectly consolidated into the generic helper'

cp "$VW_CROWDSEC_EMAIL_ENV_FILE" "$TMP/informational-env.before"
: > "$CALLS"
for help_arg in --help -h help; do
    run_unprivileged_control "$TMP/help-${help_arg#-}.out" '' '' "$help_arg" \
        || test_fail "$help_arg should succeed without root"
    test_assert_file_contains "$TMP/help-${help_arg#-}.out" 'CrowdSec Email Notifications'
done
cmp -s "$TMP/informational-env.before" "$VW_CROWDSEC_EMAIL_ENV_FILE" \
    || test_fail 'help changed the CrowdSec email environment setting'
[[ ! -s "$CALLS" ]] || test_fail 'help invoked CrowdSec setup or runtime commands'
assert_lock_free

set +e
run_unprivileged_control "$TMP/unknown.out" '' '' unknown-command
unknown_rc=$?
set -e
[[ "$unknown_rc" -eq 2 ]] || test_fail "unknown command returned $unknown_rc instead of 2"
test_assert_file_contains "$TMP/unknown.out" 'Unknown command: unknown-command'
test_assert_file_not_contains "$TMP/unknown.out" 'This script must be run as root.'
test_assert_file_not_contains "$TMP/unknown.out" 'Re-run with: sudo'
cmp -s "$TMP/informational-env.before" "$VW_CROWDSEC_EMAIL_ENV_FILE" \
    || test_fail 'unknown command changed the CrowdSec email environment setting'
[[ ! -s "$CALLS" ]] || test_fail 'unknown command invoked CrowdSec setup or runtime commands'
assert_lock_free

set_flag false
clear_managed
for privileged_command in enable disable status test; do
    cp "$VW_CROWDSEC_EMAIL_ENV_FILE" "$TMP/${privileged_command}-nonroot.before"
    : > "$CALLS"
    if run_unprivileged_control "$TMP/${privileged_command}-nonroot.out" '' '' "$privileged_command"; then
        test_fail "non-root $privileged_command unexpectedly succeeded"
    fi
    test_assert_file_contains "$TMP/${privileged_command}-nonroot.out" 'This script must be run as root.'
    test_assert_file_contains "$TMP/${privileged_command}-nonroot.out" 'Re-run with: sudo'
    cmp -s "$TMP/${privileged_command}-nonroot.before" "$VW_CROWDSEC_EMAIL_ENV_FILE" \
        || test_fail "non-root $privileged_command changed the CrowdSec email environment setting"
    [[ ! -s "$CALLS" ]] || test_fail "non-root $privileged_command invoked setup or runtime commands"
    [[ ! -e "$PLUGIN" && ! -e "$PROFILES" ]] \
        || test_fail "non-root $privileged_command modified CrowdSec notification configuration"
    assert_no_backups
    assert_lock_free
done

for bypass_case in allow-only test-mode-only; do
    case "$bypass_case" in
        allow-only) test_mode='' allow_non_root=1 ;;
        test-mode-only) test_mode=1 allow_non_root='' ;;
    esac
    if run_unprivileged_control "$TMP/${bypass_case}.out" "$test_mode" "$allow_non_root" status; then
        test_fail "$bypass_case unexpectedly bypassed the root requirement"
    fi
    test_assert_file_contains "$TMP/${bypass_case}.out" 'Re-run with: sudo'
done
chmod 0644 "$VW_CROWDSEC_EMAIL_ENV_FILE"
run_unprivileged_control "$TMP/both-bypass.out" 1 1 status \
    || test_fail 'the narrowly gated fixture mode did not reach status'
test_assert_file_contains "$TMP/both-bypass.out" 'Configured: false'
test_assert_file_contains "$TMP/both-bypass.out" 'Installed:  false'
chmod 0600 "$VW_CROWDSEC_EMAIL_ENV_FILE"

# Ordinary enable/status/test/disable behavior and metadata preservation.
env_mode="$(stat -c '%a' "$VW_CROWDSEC_EMAIL_ENV_FILE")"
env_uid="$(stat -c '%u' "$VW_CROWDSEC_EMAIL_ENV_FILE")"
env_gid="$(stat -c '%g' "$VW_CROWDSEC_EMAIL_ENV_FILE")"
run_control enable >"$TMP/enable.out" 2>&1
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=true'
test_assert_file_contains "$CALLS" 'enter origin=wrapper pre=true post=true'
test_assert_file_contains "$PLUGIN" '# Managed by VaultWarden-OCI: CrowdSec email notification'
test_assert_file_contains "$PROFILES" "$setup_begin"
test_assert_file_contains "$PROFILES" "$setup_end"
test_assert_equal "$(stat -c '%a' "$VW_CROWDSEC_EMAIL_ENV_FILE")" "$env_mode"
test_assert_equal "$(stat -c '%u' "$VW_CROWDSEC_EMAIL_ENV_FILE")" "$env_uid"
test_assert_equal "$(stat -c '%g' "$VW_CROWDSEC_EMAIL_ENV_FILE")" "$env_gid"
run_control status >"$TMP/status.out"
test_assert_file_contains "$TMP/status.out" 'Configured: true'
test_assert_file_contains "$TMP/status.out" 'Installed:  true'
test_assert_file_contains "$TMP/status.out" 'Consistent: true'
test_assert_equal "$(command -v cscli)" "$BIN/cscli"
run_control test >"$TMP/test.out"
test_assert_file_contains "$CALLS" 'cscli notifications test vaultwarden_email'
test_assert_file_contains "$TMP/test.out" 'confirm mailbox receipt'
run_control disable >"$TMP/disable.out" 2>&1
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
test_assert_not_exists "$PLUGIN"
test_assert_not_exists "$PROFILES"
run_control status >"$TMP/status-disabled.out"
test_assert_file_contains "$TMP/status-disabled.out" 'Configured: false'
test_assert_file_contains "$TMP/status-disabled.out" 'Installed:  false'
test_assert_file_contains "$TMP/status-disabled.out" 'Consistent: true'
assert_no_backups
assert_lock_free
test_assert_file_not_contains "$CALLS" 'descriptor-leak'

assert_partial false plugin
assert_partial false profile
assert_partial true plugin
assert_partial true profile

# Invalid managed shapes and malformed configuration must never be consistent.
set_flag false
clear_managed
printf 'type: email\nname: operator_owned\n' >"$PLUGIN"
if run_control status >"$TMP/operator-plugin.out" 2>&1; then test_fail 'operator plugin was reported consistent'; fi
test_assert_file_contains "$TMP/operator-plugin.out" 'Installed:  invalid'
test_assert_file_contains "$TMP/operator-plugin.out" 'Consistent: false'
clear_managed
printf '%s\n%s\n%s\n' "$setup_begin" "$setup_begin" "$setup_end" >"$PROFILES"
if run_control status >"$TMP/malformed-profile.out" 2>&1; then test_fail 'duplicate profile markers were reported consistent'; fi
test_assert_file_contains "$TMP/malformed-profile.out" 'Installed:  invalid'
clear_managed
printf 'CROWDSEC_EMAIL_NOTIFICATIONS=true\nCROWDSEC_EMAIL_NOTIFICATIONS=false\n' >"$VW_CROWDSEC_EMAIL_ENV_FILE"
if run_control status >"$TMP/duplicate-flag.out" 2>&1; then test_fail 'duplicate flag was reported consistent'; fi
test_assert_file_contains "$TMP/duplicate-flag.out" 'Configured: invalid'
printf 'CROWDSEC_EMAIL_NOTIFICATIONS=true\n CROWDSEC_EMAIL_NOTIFICATIONS = false\n' >"$VW_CROWDSEC_EMAIL_ENV_FILE"
if run_control status >"$TMP/whitespace-flag.out" 2>&1; then test_fail 'whitespace-malformed duplicate flag was reported consistent'; fi
test_assert_file_contains "$TMP/whitespace-flag.out" 'Configured: invalid'
set_flag false

# Fixture-mode status still reports permission failures as unknown, never healthy.
run_unprivileged_status() {
    run_unprivileged_control "$1" 1 1 status
}
set_flag false
clear_managed
chmod 000 "$VW_CROWDSEC_EMAIL_ENV_FILE"
if run_unprivileged_status "$TMP/unreadable-env.out"; then test_fail 'unreadable .env status succeeded'; fi
test_assert_file_contains "$TMP/unreadable-env.out" 'Configured: unknown'
test_assert_file_contains "$TMP/unreadable-env.out" 'Consistent: false'
chmod 0600 "$VW_CROWDSEC_EMAIL_ENV_FILE"
set_flag true
write_plugin
write_profile
chmod 0644 "$VW_CROWDSEC_EMAIL_ENV_FILE" "$PROFILES"
chmod 000 "$PLUGIN"
if run_unprivileged_status "$TMP/unreadable-plugin.out"; then test_fail 'unreadable plugin status succeeded'; fi
test_assert_file_contains "$TMP/unreadable-plugin.out" 'Installed:  unknown'
test_assert_file_contains "$TMP/unreadable-plugin.out" 'Consistent: false'
chmod 0644 "$PLUGIN"
chmod 000 "$PROFILES"
if run_unprivileged_status "$TMP/unreadable-profile.out"; then test_fail 'unreadable profile status succeeded'; fi
test_assert_file_contains "$TMP/unreadable-profile.out" 'Installed:  unknown'
test_assert_file_contains "$TMP/unreadable-profile.out" 'Consistent: false'
chmod 0600 "$VW_CROWDSEC_EMAIL_ENV_FILE" "$PLUGIN" "$PROFILES"

# Two wrapper mutations serialize; the second command owns the final state.
clear_managed
rm -f "$CALLS"
set_flag false
pause_marker="$TMP/wrapper-pause"
pause_fifo="$TMP/wrapper-fifo"
mkfifo "$pause_fifo"
export VW_TEST_PAUSE_ORIGIN=wrapper VW_TEST_PAUSE_MARKER="$pause_marker" VW_TEST_PAUSE_FIFO="$pause_fifo"
run_control enable >"$TMP/concurrent-enable.out" 2>&1 & first_pid=$!
test_wait_for_file "$pause_marker"
run_control disable >"$TMP/concurrent-disable.out" 2>&1 & second_pid=$!
sleep 0.2
[[ "$(grep -c '^enter origin=wrapper' "$CALLS")" == 1 ]] || test_fail 'second wrapper entered setup before the first completed'
printf 'continue\n' >"$pause_fifo"
wait "$first_pid" || test_fail 'first concurrent command failed'
wait "$second_pid" || test_fail 'second concurrent command failed'
test_assert_equal "$(grep '^enter origin=wrapper' "$CALLS" | sed -n '1p')" 'enter origin=wrapper pre=true post=true'
test_assert_equal "$(grep '^enter origin=wrapper' "$CALLS" | sed -n '2p')" 'enter origin=wrapper pre=false post=false'
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
[[ ! -e "$PLUGIN" && ! -e "$PROFILES" ]] || test_fail 'second wrapper did not determine final state'
unset VW_TEST_PAUSE_ORIGIN VW_TEST_PAUSE_MARKER VW_TEST_PAUSE_FIFO
assert_no_backups
assert_lock_free

# A direct reconcile that pre-read false must reload true after the wrapper commits.
rm -f "$CALLS"
clear_managed
set_flag false
pre_marker="$TMP/direct-pre"
pre_fifo="$TMP/direct-pre-fifo"
wrapper_marker="$TMP/direct-wrapper"
wrapper_fifo="$TMP/direct-wrapper-fifo"
mkfifo "$pre_fifo" "$wrapper_fifo"
export VW_TEST_PRELOCK_PAUSE_ORIGIN=direct VW_TEST_PRELOCK_MARKER="$pre_marker" VW_TEST_PRELOCK_FIFO="$pre_fifo"
run_setup --reconcile-email >"$TMP/direct.out" 2>&1 & direct_pid=$!
test_wait_for_file "$pre_marker"
export VW_TEST_PAUSE_ORIGIN=wrapper VW_TEST_PAUSE_MARKER="$wrapper_marker" VW_TEST_PAUSE_FIFO="$wrapper_fifo"
run_control enable >"$TMP/direct-wrapper.out" 2>&1 & wrapper_pid=$!
test_wait_for_file "$wrapper_marker"
printf 'continue\n' >"$pre_fifo"
sleep 0.2
test_assert_file_not_contains "$CALLS" 'enter origin=direct'
printf 'continue\n' >"$wrapper_fifo"
wait "$wrapper_pid" || test_fail 'wrapper enable failed in direct race'
wait "$direct_pid" || test_fail 'direct reconcile failed after waiting'
test_assert_file_contains "$CALLS" 'enter origin=direct pre=false post=true'
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=true'
[[ -e "$PLUGIN" && -e "$PROFILES" ]] || test_fail 'direct reconcile used its stale pre-lock value'
unset VW_TEST_PRELOCK_PAUSE_ORIGIN VW_TEST_PRELOCK_MARKER VW_TEST_PRELOCK_FIFO
unset VW_TEST_PAUSE_ORIGIN VW_TEST_PAUSE_MARKER VW_TEST_PAUSE_FIFO
assert_lock_free

# A full setup entry that pre-read true must reload false after wrapper disable.
rm -f "$CALLS"
set_flag true
write_plugin
write_profile
pre_marker="$TMP/full-pre"
pre_fifo="$TMP/full-pre-fifo"
wrapper_marker="$TMP/full-wrapper"
wrapper_fifo="$TMP/full-wrapper-fifo"
mkfifo "$pre_fifo" "$wrapper_fifo"
export VW_TEST_PRELOCK_PAUSE_ORIGIN=full VW_TEST_PRELOCK_MARKER="$pre_marker" VW_TEST_PRELOCK_FIFO="$pre_fifo"
run_setup >"$TMP/full.out" 2>&1 & full_pid=$!
test_wait_for_file "$pre_marker"
export VW_TEST_PAUSE_ORIGIN=wrapper VW_TEST_PAUSE_MARKER="$wrapper_marker" VW_TEST_PAUSE_FIFO="$wrapper_fifo"
run_control disable >"$TMP/full-wrapper.out" 2>&1 & wrapper_pid=$!
test_wait_for_file "$wrapper_marker"
printf 'continue\n' >"$pre_fifo"
sleep 0.2
test_assert_file_not_contains "$CALLS" 'enter origin=full'
printf 'continue\n' >"$wrapper_fifo"
wait "$wrapper_pid" || test_fail 'wrapper disable failed in full-setup race'
wait "$full_pid" || test_fail 'full setup reconcile failed after waiting'
test_assert_file_contains "$CALLS" 'enter origin=full pre=true post=false'
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
[[ ! -e "$PLUGIN" && ! -e "$PROFILES" ]] || test_fail 'full setup used its stale pre-lock value'
unset VW_TEST_PRELOCK_PAUSE_ORIGIN VW_TEST_PRELOCK_MARKER VW_TEST_PRELOCK_FIFO
unset VW_TEST_PAUSE_ORIGIN VW_TEST_PAUSE_MARKER VW_TEST_PAUSE_FIFO
assert_lock_free

# TERM restores .env, releases both locks, removes backup, and permits a retry.
rm -f "$CALLS"
clear_managed
set_flag false
signal_marker="$TMP/signal-marker"
signal_fifo="$TMP/signal-fifo"
mkfifo "$signal_fifo"
export VW_TEST_PAUSE_ORIGIN=wrapper VW_TEST_PAUSE_MARKER="$signal_marker" VW_TEST_PAUSE_FIFO="$signal_fifo"
bash "$FIXTURE/utilities/crowdsec-email.sh" enable >"$TMP/signal.out" 2>&1 & signal_pid=$!
test_wait_for_file "$signal_marker"
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=true'
kill -TERM "$signal_pid"
kill -TERM "$signal_pid" 2>/dev/null || true
if wait "$signal_pid"; then test_fail 'TERM-interrupted command exited successfully'; fi
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
test_assert_file_contains "$TMP/signal.out" 'Interrupted CrowdSec email transaction; restored the previous .env.'
test_assert_file_not_contains "$TMP/signal.out" 'CrowdSec email notifications enabled.'
assert_no_backups
assert_lock_free
unset VW_TEST_PAUSE_ORIGIN VW_TEST_PAUSE_MARKER VW_TEST_PAUSE_FIFO
run_control disable >"$TMP/post-signal.out" 2>&1
test_assert_file_contains "$TMP/post-signal.out" 'CrowdSec email notifications disabled.'

# Production transaction hooks exercise every dangerous mutation boundary through the wrapper.
FAKE_SETUP="$VW_CROWDSEC_SETUP_SCRIPT"
VW_CROWDSEC_SETUP_SCRIPT="$PRODUCTION_SETUP"
export VW_CROWDSEC_SETUP_SCRIPT
interrupt_points=(after-plugin after-profile before-validate after-validate before-restart after-restart)

# Exact restoration also covers the state where neither managed path existed.
set_flag false
clear_managed
snapshot_path "$PLUGIN" "$TMP/absent-enable-plugin"
snapshot_path "$PROFILES" "$TMP/absent-enable-profiles"
export VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT=after-plugin
set +e
run_control enable >"$TMP/absent-enable.out" 2>&1
signal_rc=$?
set -e
[[ "$signal_rc" -eq 143 ]] || test_fail "absent-path interrupted enable returned $signal_rc instead of 143"
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
assert_snapshot "$PLUGIN" "$TMP/absent-enable-plugin"
assert_snapshot "$PROFILES" "$TMP/absent-enable-profiles"
assert_no_email_temps
assert_no_backups
assert_lock_free
unset VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT

for point in "${interrupt_points[@]}"; do
    # disabled -> interrupted enable: operator profile content and metadata survive.
    set_flag false
    clear_managed
    printf 'name: operator_profile\nfilters:\n  - true\non_success: continue\n# operator tail\n' >"$PROFILES"
    chmod 0644 "$PROFILES"
    snapshot_path "$PLUGIN" "$TMP/${point}-enable-plugin"
    snapshot_path "$PROFILES" "$TMP/${point}-enable-profiles"
    export VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT="$point"
    set +e
    run_control enable >"$TMP/${point}-enable.out" 2>&1
    signal_rc=$?
    set -e
    if [[ "$signal_rc" -ne 143 ]]; then
        cat "$TMP/${point}-enable.out" >&2
        cat "$CALLS" >&2
        test_fail "$point interrupted enable returned $signal_rc instead of 143"
    fi
    test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=false'
    assert_snapshot "$PLUGIN" "$TMP/${point}-enable-plugin"
    assert_snapshot "$PROFILES" "$TMP/${point}-enable-profiles"
    test_assert_file_contains "$TMP/${point}-enable.out" 'Interrupted CrowdSec email transaction; restored the previous .env.'
    test_assert_file_not_contains "$TMP/${point}-enable.out" 'CrowdSec email notifications enabled.'
    assert_no_email_temps
    assert_no_backups
    assert_lock_free
    unset VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT
    run_control disable >"$TMP/${point}-enable-retry.out" 2>&1 \
        || test_fail "$point interrupted enable prevented a subsequent command"

    # enabled -> interrupted disable: managed files and surrounding operator content survive.
    set_flag false
    clear_managed
    run_control enable >"$TMP/${point}-seed-enabled.out" 2>&1 \
        || test_fail "could not seed enabled state for $point"
    profile_with_operator_content="$TMP/${point}-profile-with-operator-content"
    {
        printf '# operator header\nname: operator_profile_before\n'
        cat "$PROFILES"
        printf '# operator tail\nname: operator_profile_after\n'
    } >"$profile_with_operator_content"
    mv -fT -- "$profile_with_operator_content" "$PROFILES"
    chmod 0600 "$PLUGIN"
    chmod 0644 "$PROFILES"
    snapshot_path "$PLUGIN" "$TMP/${point}-disable-plugin"
    snapshot_path "$PROFILES" "$TMP/${point}-disable-profiles"
    export VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT="$point"
    set +e
    run_control disable >"$TMP/${point}-disable.out" 2>&1
    signal_rc=$?
    set -e
    if [[ "$signal_rc" -ne 143 ]]; then
        cat "$TMP/${point}-disable.out" >&2
        cat "$CALLS" >&2
        test_fail "$point interrupted disable returned $signal_rc instead of 143"
    fi
    test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=true'
    assert_snapshot "$PLUGIN" "$TMP/${point}-disable-plugin"
    assert_snapshot "$PROFILES" "$TMP/${point}-disable-profiles"
    test_assert_file_contains "$TMP/${point}-disable.out" 'Interrupted CrowdSec email transaction; restored the previous .env.'
    test_assert_file_not_contains "$TMP/${point}-disable.out" 'CrowdSec email notifications disabled.'
    assert_no_email_temps
    assert_no_backups
    assert_lock_free
    unset VW_TEST_CROWDSEC_EMAIL_SIGNAL_POINT
    run_control enable >"$TMP/${point}-disable-retry.out" 2>&1 \
        || test_fail "$point interrupted disable prevented a subsequent command"
done
VW_CROWDSEC_SETUP_SCRIPT="$FAKE_SETUP"
export VW_CROWDSEC_SETUP_SCRIPT

# If setup committed the managed state before its parent observed a signal-like
# exit, the wrapper must keep the matching .env instead of rolling it back.
set_flag false
clear_managed
export VW_TEST_FAKE_EXIT_AFTER_COMMIT=143
set +e
run_control enable >"$TMP/committed-before-exit.out" 2>&1
committed_rc=$?
set -e
unset VW_TEST_FAKE_EXIT_AFTER_COMMIT
[[ "$committed_rc" -eq 143 ]] || test_fail "committed child exit returned $committed_rc instead of 143"
test_assert_file_contains "$VW_CROWDSEC_EMAIL_ENV_FILE" 'CROWDSEC_EMAIL_NOTIFICATIONS=true'
[[ -e "$PLUGIN" && -e "$PROFILES" ]] || test_fail 'committed child state was lost after signal-like exit'
test_assert_file_contains "$TMP/committed-before-exit.out" 'committed before interruption; keeping the reconciled .env state'
assert_no_backups
assert_lock_free

# Focused realistic wrapper failures remain explicit and do not claim success.
mv "$BIN/cscli" "$BIN/cscli.off"
set_flag true
write_plugin
write_profile
missing_cscli_path="$(test_build_isolated_path \
    "$TMP/missing-cscli-bin" bash dirname basename tr awk grep)"
if PATH="$missing_cscli_path" command -v cscli >/dev/null 2>&1; then
    test_fail 'isolated missing-cscli fixture exposed a host cscli command'
fi
if PATH="$missing_cscli_path" run_control test >"$TMP/missing-cscli.out" 2>&1; then
    test_fail 'missing cscli was ignored'
fi
test_assert_file_contains "$TMP/missing-cscli.out" 'Required command is unavailable: cscli'
mv "$BIN/cscli.off" "$BIN/cscli"
chmod -x "$VW_CROWDSEC_SETUP_SCRIPT"
set_flag false
if run_control enable >"$TMP/missing-setup.out" 2>&1; then test_fail 'non-executable setup was ignored'; fi
test_assert_file_contains "$TMP/missing-setup.out" 'missing or not executable'
chmod +x "$VW_CROWDSEC_SETUP_SCRIPT"
printf 'CROWDSEC_EMAIL_NOTIFICATIONS=true\nCROWDSEC_EMAIL_NOTIFICATIONS=false\n' >"$VW_CROWDSEC_EMAIL_ENV_FILE"
if run_control enable >"$TMP/duplicate-enable.out" 2>&1; then test_fail 'duplicate flag was silently rewritten'; fi
test_assert_file_contains "$TMP/duplicate-enable.out" 'malformed or duplicated'
test_assert_file_not_contains "$TMP/duplicate-enable.out" 'CrowdSec email notifications enabled.'
printf 'CROWDSEC_EMAIL_NOTIFICATIONS=true\n CROWDSEC_EMAIL_NOTIFICATIONS = false\n' >"$VW_CROWDSEC_EMAIL_ENV_FILE"
if run_control enable >"$TMP/whitespace-enable.out" 2>&1; then test_fail 'whitespace-malformed duplicate flag was silently rewritten'; fi
test_assert_file_contains "$TMP/whitespace-enable.out" 'malformed or duplicated'
test_assert_file_not_contains "$TMP/whitespace-enable.out" 'CrowdSec email notifications enabled.'
assert_no_backups
assert_lock_free

printf 'CrowdSec email control tests passed.\n'
