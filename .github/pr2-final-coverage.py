from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor count={count}")
    return text.replace(old, new, 1)


backup = Path('tests/suites/data-protection/case-backup.bash')
text = backup.read_text()
old = '''archive="$TMP/db-test.age"
printf 'encrypted-payload' > "$archive"
FILE_INTEGRITY_HMAC_KEY='cohort-test-key'
REQUIRE_AUTHENTICATED_INTEGRITY=true
export FILE_INTEGRITY_HMAC_KEY REQUIRE_AUTHENTICATED_INTEGRITY
write_file_integrity "$archive" || fail 'strict integrity sidecars were not produced'
printf 'backup_type=db\\narchive_format=relative\\nversion=2\\nencryption_mode=age-recipient\\n' > "${archive}.meta"
chmod 600 "$archive" "${archive}.sha256" "${archive}.sha256.hmac" "${archive}.meta"
mapfile -t suffixes < <(backup_required_cohort_suffixes)
[[ "${suffixes[*]}" == ' .sha256 .sha256.hmac .meta' ]] || fail 'strict cohort definition drifted'
verify_file_integrity "$archive" || fail 'valid authenticated cohort did not verify'
'''
new = '''FILE_INTEGRITY_HMAC_KEY='cohort-test-key'
REQUIRE_AUTHENTICATED_INTEGRITY=true
export FILE_INTEGRITY_HMAC_KEY REQUIRE_AUTHENTICATED_INTEGRITY
mapfile -t suffixes < <(backup_required_cohort_suffixes)
[[ "${suffixes[*]}" == ' .sha256 .sha256.hmac .meta' ]] || fail 'strict cohort definition drifted'
for backup_type in db full; do
    archive="$TMP/${backup_type}-test.age"
    printf 'encrypted-payload-%s' "$backup_type" > "$archive"
    write_file_integrity "$archive" || fail "strict ${backup_type} integrity sidecars were not produced"
    printf 'backup_type=%s\\narchive_format=relative\\nversion=2\\nencryption_mode=age-recipient\\n' "$backup_type" > "${archive}.meta"
    chmod 600 "$archive" "${archive}.sha256" "${archive}.sha256.hmac" "${archive}.meta"
    verify_file_integrity "$archive" || fail "valid authenticated ${backup_type} cohort did not verify"
done
archive="$TMP/db-test.age"
'''
text = replace_once(text, old, new, 'valid DB/full cohort coverage')
backup.write_text(text)

restore = Path('tests/suites/data-protection/case-restore-recovery.bash')
text = restore.read_text()
old = '''[[ -n "$verify_line" && -n "$stop_line" ]] && (( verify_line < stop_line )) || fail 'authenticated verification must happen before destructive service stop'
printf 'PASS: restore authenticates required cohort before destructive work and can stage recovery-kit integrity key\\n'
'''
new = '''[[ -n "$verify_line" && -n "$stop_line" ]] && (( verify_line < stop_line )) || fail 'authenticated verification must happen before destructive service stop'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
has_command(){ command -v "$1" >/dev/null 2>&1; }
source "$ROOT/lib/log.sh"
source "$ROOT/lib/crypto.sh"
archive="$TMP/restore-guard.age"
printf 'encrypted-restore-payload' > "$archive"
FILE_INTEGRITY_HMAC_KEY='restore-guard-key'
REQUIRE_AUTHENTICATED_INTEGRITY=true
write_file_integrity "$archive" || fail 'could not create restore-guard integrity sidecars'
run_destructive_guard(){
    verify_file_integrity "$archive" || return 1
    : > "$TMP/destructive-work-reached"
}
printf tampered > "${archive}.sha256.hmac"
if run_destructive_guard >/dev/null 2>&1; then fail 'tampered HMAC reached destructive restore work'; fi
[[ ! -e "$TMP/destructive-work-reached" ]] || fail 'tampered HMAC reached destructive restore marker'
write_file_integrity "$archive" || fail 'could not recreate restore-guard integrity sidecars'
rm -f "${archive}.sha256.hmac"
if run_destructive_guard >/dev/null 2>&1; then fail 'missing HMAC reached destructive restore work'; fi
[[ ! -e "$TMP/destructive-work-reached" ]] || fail 'missing HMAC reached destructive restore marker'
printf 'PASS: restore rejects tampered/missing authenticated HMAC before destructive work\\n'
'''
text = replace_once(text, old, new, 'destructive restore HMAC behavior coverage')
restore.write_text(text)
