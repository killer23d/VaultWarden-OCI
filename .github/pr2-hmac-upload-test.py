from pathlib import Path

p = Path('tests/suites/data-protection/case-backup.bash')
text = p.read_text()
old = '''FAIL_SUFFIX="\\${FAIL_SUFFIX:-}"
META_CASE="\\${META_CASE:-age-passphrase}"
backup_log_info(){ printf 'INFO %s\\\\n' "\\$*"; }
'''
new = '''FAIL_SUFFIX="\\${FAIL_SUFFIX:-}"
META_CASE="\\${META_CASE:-age-passphrase}"
REQUIRE_AUTHENTICATED_INTEGRITY="\\${REQUIRE_AUTHENTICATED_INTEGRITY:-false}"
backup_log_info(){ printf 'INFO %s\\\\n' "\\$*"; }
'''
if text.count(old) != 1:
    raise SystemExit(f'policy fixture anchor count={text.count(old)}')
text = text.replace(old, new, 1)
old = '''printf checksum > "\\${archive}.sha256"
rc=0
sync_to_rclone "\\$archive" emergency || rc=\\$?
'''
new = '''printf checksum > "\\${archive}.sha256"
if [[ "\\$REQUIRE_AUTHENTICATED_INTEGRITY" == true ]]; then
  printf hmac > "\\${archive}.sha256.hmac"
fi
rc=0
sync_to_rclone "\\$archive" emergency || rc=\\$?
'''
if text.count(old) != 1:
    raise SystemExit(f'HMAC fixture anchor count={text.count(old)}')
text = text.replace(old, new, 1)
old = ''': > "$TMP/rclone-copy.calls"
FAIL_SUFFIX=.sha256 bash "$TMP/sync-probe.sh" >"$TMP/sha-fail.out" 2>&1 || fail 'checksum sidecar upload probe crashed'
grep -q '^RC=1$' "$TMP/sha-fail.out" || { cat "$TMP/sha-fail.out" >&2; fail '.sha256 upload failure must make offsite delivery incomplete'; }
! grep -q 'Offsite sync complete' "$TMP/sha-fail.out" \\
  || fail '.sha256 upload failure must not report a complete remote recovery point'

'''
new = old + ''': > "$TMP/rclone-copy.calls"
REQUIRE_AUTHENTICATED_INTEGRITY=true FAIL_SUFFIX=.sha256.hmac \\
  bash "$TMP/sync-probe.sh" >"$TMP/hmac-fail.out" 2>&1 || fail 'HMAC sidecar upload probe crashed'
grep -q '^RC=1$' "$TMP/hmac-fail.out" \\
  || { cat "$TMP/hmac-fail.out" >&2; fail '.sha256.hmac upload failure must make offsite delivery incomplete'; }
! grep -q 'Offsite sync complete' "$TMP/hmac-fail.out" \\
  || fail '.sha256.hmac upload failure must not report a complete remote recovery point'
grep -Fq "$TMP/emergency.tar.zst.age.sha256.hmac" "$TMP/rclone-copy.calls" \\
  || fail 'strict offsite sync did not attempt required HMAC upload'

'''
if text.count(old) != 1:
    raise SystemExit(f'HMAC failure assertion anchor count={text.count(old)}')
p.write_text(text.replace(old, new, 1))
