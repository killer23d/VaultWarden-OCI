from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor count={count}")
    return text.replace(old, new, 1)


backup = Path("utilities/backup-run.sh")
text = backup.read_text()
text = replace_once(
    text,
    'log_error "[backup] Emergency restore metadata upload FAILED: $(basename "$local_member") (exit ${upload_rc}) — remote recovery point is incomplete." >&2',
    'log_error "[backup] Emergency restore metadata upload FAILED: $(basename "$local_member") (exit ${upload_rc}) — remote emergency recovery point is incomplete." >&2',
    "emergency upload message",
)
text = replace_once(
    text,
    'log_error "[backup] Emergency offsite delivery is incomplete: restore-critical metadata is missing or unusable." >&2',
    'log_error "[backup] Emergency offsite delivery is incomplete: restore-critical metadata is missing, unusable, or not delivered." >&2',
    "emergency metadata message",
)
old = '''        local retained_archive suffix
        while IFS= read -r -d '' retained_archive; do
            while IFS= read -r suffix; do
                [[ -f "${retained_archive}${suffix}" && ! -L "${retained_archive}${suffix}" && -s "${retained_archive}${suffix}" ]] || {
                    log_error "[backup] Retained ${t} backup has an incomplete required cohort: $(basename "${retained_archive}${suffix}")"
                    return 1
                }
            done < <(backup_required_cohort_suffixes)
            if [[ "$t" == "emergency" ]] && ! _validate_emergency_restore_metadata "$retained_archive"; then
                log_error "[backup] Retained emergency backup is not restore-usable: $(basename "$retained_archive")"
                log_error "[backup] This emergency recovery point is not safe to report as offsite complete."
                return 1
            fi
        done < <(find "$local_dir" -maxdepth 1 -name '*.age' -type f -print0)
'''
new = '''        local retained_archive suffix
        while IFS= read -r -d '' retained_archive; do
            if [[ "$t" == "emergency" ]] && ! _validate_emergency_restore_metadata "$retained_archive"; then
                log_error "[backup] Retained emergency backup is not restore-usable: $(basename "$retained_archive")"
                log_error "[backup] This emergency recovery point is not safe to report as offsite complete."
                return 1
            fi
            while IFS= read -r suffix; do
                [[ -f "${retained_archive}${suffix}" && ! -L "${retained_archive}${suffix}" && -s "${retained_archive}${suffix}" ]] || {
                    log_error "[backup] Retained ${t} backup has an incomplete required cohort: $(basename "${retained_archive}${suffix}")"
                    return 1
                }
            done < <(backup_required_cohort_suffixes)
        done < <(find "$local_dir" -maxdepth 1 -name '*.age' -type f -print0)
'''
text = replace_once(text, old, new, "retained emergency ordering")
backup.write_text(text)

restore_tests = Path("tests/suites/data-protection/case-restore-recovery.bash")
text = restore_tests.read_text()
text = replace_once(
    text,
    'source "$ROOT/lib/backup-utils.sh"\nCONTROL_WORKSPACE="$TMP"\nRCLONE_CONFIG_ARG=()\n_SESSION_RCLONE_REMOTE_NAME=mock\n',
    'source "$ROOT/lib/backup-utils.sh"\n_SESSION_RCLONE_REMOTE_NAME=mock\n',
    "remote listing shellcheck fixture",
)
text = replace_once(
    text,
    "DRY_RUN=false\nRAW_KEY='AGE-SECRET-KEY-1PRIVATEKEYMATERIAL'\n",
    "DRY_RUN=false\nREQUIRE_AUTHENTICATED_INTEGRITY=false\nRAW_KEY='AGE-SECRET-KEY-1PRIVATEKEYMATERIAL'\n",
    "raw-key legacy policy fixture",
)
strict_test = r'''
check_recovery_kit_authenticated_behavior() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for cmd in age age-keygen python3 sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'SKIP recovery-kit authenticated behavior: %s unavailable\n' "$cmd"
        exit 0
    }
done

_extract_func(){
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
            print
            opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
            depth += opens - closes
            if (depth == 0) exit
        }' "$file"
}

has_command(){ command -v "$1" >/dev/null 2>&1; }
source "$ROOT/lib/log.sh"
source "$ROOT/lib/crypto.sh"
eval "$(_extract_func "$RESTORE" _stage_restore_age_key_line)"
eval "$(_extract_func "$RESTORE" _load_recovery_kit)"
eval "$(_extract_func "$RESTORE" _load_restore_integrity_hmac_key)"
eval "$(_extract_func "$RESTORE" _age_decrypt_restore_backup)"

CONTROL_WORKSPACE="$TMP/control"
mkdir -m 700 "$CONTROL_WORKSPACE"
RECOVERY_KIT_FILE="$TMP/recovery-kit.txt"
RESTORE_RECOVERY_KIT_FILE=""
KEY_FILE_ARG=""
RECOVERY_KIT_INTEGRITY_HMAC_KEY=""
REQUIRE_AUTHENTICATED_INTEGRITY=true
DRY_RUN=false
RESTORE_TYPE=full
EMERGENCY_BACKUP_AGE_IDENTITY_FILE=""
SECRETS_FILE="$TMP/missing-secrets.yaml"
STATE_DIR="$TMP/state"
PROJECT_ROOT="$ROOT"
mkdir -p "$STATE_DIR"

historical_age_key="$TMP/historical-age-key.txt"
age-keygen -o "$historical_age_key" >/dev/null 2>&1 || fail 'could not generate historical Age identity'
private_key="$(grep -m1 '^AGE-SECRET-KEY-1' "$historical_age_key")"
recipient="$(age-keygen -y "$historical_age_key" 2>/dev/null)"
[[ -n "$private_key" && "$recipient" == age1* ]] || fail 'historical Age identity fixture is invalid'

age_only_kit="$TMP/age-only-recovery-kit.txt"
printf '%s\n' "$private_key" > "$age_only_kit"
chmod 600 "$age_only_kit"
RECOVERY_KIT_FILE="$age_only_kit"
if _load_recovery_kit >"$TMP/age-only.out" 2>&1; then
    fail 'strict recovery accepted an Age-only recovery kit without historical HMAC key'
fi
grep -Fq 'missing the historical backup integrity HMAC key' "$TMP/age-only.out" \
    || fail 'strict Age-only recovery-kit refusal was not actionable'

historical_hmac_key='historical-cohort-hmac-key'
{
    printf '%s\n' "$private_key"
    printf '%s\n' '[Backup integrity HMAC key (auto-generated)]'
    printf '%s\n' "$historical_hmac_key"
} > "$RECOVERY_KIT_FILE"
chmod 600 "$RECOVERY_KIT_FILE"
KEY_FILE_ARG=""
RECOVERY_KIT_INTEGRITY_HMAC_KEY=""
_load_recovery_kit || fail 'recovery kit with historical Age and HMAC credentials was rejected'
_load_restore_integrity_hmac_key "$TMP/missing-operational-key.txt" \
    || fail 'historical recovery-kit HMAC key was not selected'
[[ "$FILE_INTEGRITY_HMAC_KEY" == "$historical_hmac_key" ]] \
    || fail 'recovery-kit HMAC key did not become the canonical verification key'
[[ "$KEY_FILE_ARG" == "$CONTROL_WORKSPACE/kit_stage/recovery-kit-age-key.txt" ]] \
    || fail 'recovery-kit Age identity was not staged in the control workspace'

archive="$TMP/historical-backup.age"
printf 'historical-recovery-payload' | age -r "$recipient" -o "$archive" \
    || fail 'could not create historical encrypted backup fixture'
write_file_integrity "$archive" || fail 'could not create authenticated historical backup sidecars'
verify_file_integrity "$archive" || fail 'historical backup failed recovery-kit HMAC verification'

decrypted="$TMP/decrypted-payload"
age_err="$TMP/age-decrypt.err"
_age_decrypt_restore_backup "$archive" "$KEY_FILE_ARG" "$decrypted" "$age_err" age-recipient \
    || fail 'recovery-kit Age identity could not decrypt authenticated historical backup'
[[ "$(cat "$decrypted")" == 'historical-recovery-payload' ]] \
    || fail 'recovery-kit-assisted decrypt returned unexpected payload'

printf tamper >> "$archive"
if verify_file_integrity "$archive" >/dev/null 2>&1; then
    fail 'tampered historical backup verified with recovery-kit HMAC key'
fi
printf 'PASS: recovery kit supplies historical Age identity and HMAC key for authenticated restore\n'
)
check_recovery_kit_authenticated_behavior

'''
anchor = 'check_authenticated_restore_cohort_contract\n\ncheck_remote_restore_listing_truthfulness() (\n'
text = replace_once(
    text,
    anchor,
    'check_authenticated_restore_cohort_contract\n\n' + strict_test + 'check_remote_restore_listing_truthfulness() (\n',
    "strict recovery-kit behavior insertion",
)
restore_tests.write_text(text)

backup_tests = Path("tests/suites/data-protection/case-backup.bash")
text = backup_tests.read_text()
text = replace_once(
    text,
    'cat > "$TMP/batch-sync-probe.sh" <<EOF_PROBE\nset -uo pipefail\nBASE_DIR="$TMP/retained"\n',
    'cat > "$TMP/batch-sync-probe.sh" <<EOF_PROBE\nset -uo pipefail\nCONTROL_WORKSPACE="$TMP/batch-work"\nmkdir -p "\\$CONTROL_WORKSPACE"\nBASE_DIR="$TMP/retained"\n',
    "batch retained-sync workspace fixture",
)
text = replace_once(
    text,
    'eval "$(_extract_shell_function "$UTILS" check_backup_disk_space)"\n\nproject="$TMP/project"\n',
    'eval "$(_extract_shell_function "$UTILS" check_backup_disk_space)"\neval "$(_extract_shell_function "$UTILS" backup_required_cohort_suffixes)"\n\nproject="$TMP/project"\n',
    "payload cohort helper fixture",
)
text = replace_once(
    text,
    'source "$ROOT/lib/backup-utils.sh"\narchive="$TMP/db-test.age"\n',
    'source "$ROOT/lib/backup-utils.sh"\nhas_command(){ command -v "$1" >/dev/null 2>&1; }\narchive="$TMP/db-test.age"\n',
    "authenticated backup helper fixture",
)
backup_tests.write_text(text)
