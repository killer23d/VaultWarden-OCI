#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/lib/common.sh"
KEY_ROTATE="$ROOT/utilities/key-rotate.sh"
BACKUP="$ROOT/utilities/backup-run.sh"
CROWDSEC="$ROOT/utilities/setup-crowdsec.sh"
SETUP_SECRETS="$ROOT/utilities/setup-secrets.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1" text="$2" label="$3"
    grep -Fq -- "$text" "$file" || fail "$label"
}

# shellcheck source=../lib/log.sh
source "$ROOT/lib/log.sh"
# shellcheck source=../lib/common.sh
source "$COMMON"
init_common_lib "$0"

prompt_output="$(operator_confirm_yes_no "Proceed with operator test?" "no" 0 <<< "no" 2>&1 >/dev/null || true)"
[[ "$prompt_output" == *"Proceed with operator test? [yes/no] (default: no): "* ]] \
    || fail "yes/no helper prompt does not display the default"

if ! operator_confirm_yes_no "Use default yes?" "yes" 0 <<< "" 2>/dev/null; then
    fail "yes/no helper did not accept an explicit default yes on empty input"
fi

if operator_confirm_yes_no "Use default no?" "no" 0 <<< "" 2>/dev/null; then
    fail "yes/no helper accepted default no as yes"
fi

if operator_confirm_yes_no "Timeout must fail closed?" "yes" 1 < <(sleep 2) 2>/dev/null; then
    fail "yes/no helper timeout did not fail closed"
fi

assert_contains "$COMMON" 'operator_attention()' "operator_attention helper missing"
assert_contains "$COMMON" 'operator_confirm_yes_no()' "operator_confirm_yes_no helper missing"
assert_contains "$COMMON" 'operator_next_steps()' "operator_next_steps helper missing"

assert_contains "$KEY_ROTATE" 'operator_confirm_yes_no "Continue with Age key rotation?" "no" 30' \
    "key rotation does not use explicit default-no confirmation"
assert_contains "$KEY_ROTATE" 'while [[ "$saved" != "SAVED" ]]' \
    "key rotation final SAVED acknowledgement was not preserved"

assert_contains "$BACKUP" "This passphrase protects only the emergency backup capsule." \
    "emergency backup passphrase role wording missing"
assert_contains "$BACKUP" '_print_backup_run_summary "$actual_type" "$backup_file" "$verification_status" "$offsite_status"' \
    "backup final summary call missing"
assert_contains "$BACKUP" '[[ "$QUIET" == "true" ]] && return 0' \
    "backup summary is not quiet-aware"
assert_contains "$BACKUP" 'Offsite sync: ${offsite_status}' \
    "backup summary does not report offsite sync"
assert_contains "$BACKUP" 'if [[ "$RCLONE_SYNC" == "true" ]]; then' \
    "backup verification failure must only mark offsite skipped when rclone was requested"
assert_contains "$BACKUP" 'offsite_status="skipped because verification failed"' \
    "backup summary missing verification-failure offsite skip state"
assert_contains "$BACKUP" "Backup archive was created, but quick verification failed; do not treat it as verified." \
    "backup verification partial-success warning missing"
assert_contains "$BACKUP" 'backup_log_success "Backup completed successfully"' \
    "backup success completion message missing"

list_block="$(awk '/if \[\[ "\$LIST_ONLY" == "true" \]\]/,/exit 0/' "$BACKUP")"
if grep -Fq 'operator_next_steps' <<< "$list_block"; then
    fail "backup list or JSON path should not emit operator summary"
fi

verify_failure_block="$(awk '/if ! verify_backup_quick/,/else/' "$BACKUP")"
if ! grep -Fq 'if [[ "$RCLONE_SYNC" == "true" ]]; then' <<< "$verify_failure_block"; then
    fail "backup verification failure should not change offsite status when rclone was not requested"
fi
success_tail="$(awk '/_print_backup_run_summary "\$actual_type"/,/exit 0/' "$BACKUP")"
if ! grep -Fq 'if [[ "$verify_failed" == "true" ]]; then' <<< "$success_tail"; then
    fail "backup completion must branch on verification failure"
fi
if ! grep -Fq 'else' <<< "$success_tail" || ! grep -Fq 'backup_log_success "Backup completed successfully"' <<< "$success_tail"; then
    fail "backup success message should remain only on the verified success branch"
fi

assert_contains "$SETUP_SECRETS" "If you skip it, disaster recovery depends on the operational Age key or an exported recovery kit." \
    "offline recovery skip consequence wording missing"
assert_contains "$SETUP_SECRETS" "Offline recovery Age public key skipped; encrypted secrets will not have a separate offline recovery recipient." \
    "offline recovery skip warning missing"

assert_contains "$CROWDSEC" "Manual Cloudflare action required" \
    "CrowdSec final manual action block missing"
assert_contains "$CROWDSEC" "Failure mode: Fail open" \
    "CrowdSec fail-open manual action wording missing"

# Verify F-01: Deep db maintenance success output must be inside wait_for_service_ready success branch.
wait_block="$(awk '/if wait_for_service_ready/,/fi/' "$ROOT/utilities/maintenance-db-maint.sh")"
then_part="$(awk '/if wait_for_service_ready/,/else/' <<< "$wait_block")"
else_part="$(awk '/else/,/fi/' <<< "$wait_block")"

if ! grep -q 'log_success "VaultWarden is back online"' <<< "$then_part"; then
    fail "db-maint success message 'VaultWarden is back online' is not inside the wait_for_service_ready then-block"
fi
if ! grep -q 'log_success "Deep database maintenance complete!"' <<< "$then_part"; then
    fail "db-maint success message 'Deep database maintenance complete!' is not inside the wait_for_service_ready then-block"
fi
if ! grep -q 'log_warn "VaultWarden was restarted but did not pass the health check."' <<< "$else_part"; then
    fail "db-maint warning message is not inside the wait_for_service_ready else-block"
fi

printf 'Operator UI tests passed.\n'
