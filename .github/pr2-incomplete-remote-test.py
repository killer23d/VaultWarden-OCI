from pathlib import Path

p = Path('tests/suites/data-protection/case-restore-recovery.bash')
text = p.read_text()
old = '''_REMOTE_FILES=(); _REMOTE_TYPES=()
get_config_value(){ printf '%s\\n' "${2:-}"; }
rclone(){
'''
new = '''_REMOTE_FILES=(); _REMOTE_TYPES=()
REQUIRE_AUTHENTICATED_INTEGRITY=true
get_config_value(){ printf '%s\\n' "${2:-}"; }
rclone(){
'''
if text.count(old) != 1:
    raise SystemExit(f'listing policy anchor count={text.count(old)}')
text = text.replace(old, new, 1)
old = '''    lsf)
      if [[ "${REMOTE_MODE:-empty}" == fail ]]; then
        printf 'authentication failed\\n' >&2
        return 17
      fi
      return 0
      ;;
'''
new = '''    lsf)
      case "${REMOTE_MODE:-empty}" in
        fail)
          printf 'authentication failed\\n' >&2
          return 17
          ;;
        incomplete)
          printf '%s\\n' \\
            'db_backup_20990101_000000.sqlite3.age' \\
            'db_backup_20990101_000000.sqlite3.age.sha256' \\
            'db_backup_20990101_000000.sqlite3.age.meta'
          return 0
          ;;
        *) return 0 ;;
      esac
      ;;
'''
if text.count(old) != 1:
    raise SystemExit(f'listing mock anchor count={text.count(old)}')
text = text.replace(old, new, 1)
old = '''grep -Fq 'No complete remote backup cohorts found' "$TMP/empty.out" || fail 'empty remote outcome was not reported clearly'
REMOTE_MODE=fail
'''
new = '''grep -Fq 'No complete remote backup cohorts found' "$TMP/empty.out" || fail 'empty remote outcome was not reported clearly'
REMOTE_MODE=incomplete
list_remote_backups >"$TMP/incomplete.out" 2>&1 || fail 'incomplete remote cohort should be skipped, not treated as a transport failure'
[[ ${#_REMOTE_FILES[@]} -eq 0 ]] || fail 'incomplete remote cohort was auto-selected as trusted'
grep -Fq 'Skipping incomplete remote' "$TMP/incomplete.out" \\
  || fail 'incomplete remote cohort was not diagnosed as incomplete'
grep -Fq '.sha256.hmac' "$TMP/incomplete.out" \\
  || fail 'incomplete strict remote cohort did not identify the missing HMAC sidecar'
REMOTE_MODE=fail
'''
if text.count(old) != 1:
    raise SystemExit(f'incomplete assertion anchor count={text.count(old)}')
p.write_text(text.replace(old, new, 1))
