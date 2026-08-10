from pathlib import Path

restore = Path('utilities/restore-run.sh')
text = restore.read_text()
old = '        local listing="" list_rc=0 err_file="${CONTROL_WORKSPACE:-/tmp}/vw-rclone-list-${t}.$$.err"\n'
new = '''        local listing="" list_rc=0 err_file=""
        err_file=$(mktemp "${CONTROL_WORKSPACE:-/tmp}/vw-rclone-list-${t}.XXXXXX") || {
            log_error "Could not create temporary rclone listing diagnostic file."
            return 1
        }
'''
if text.count(old) != 1:
    raise SystemExit(f'remote listing temp-file anchor count={text.count(old)}')
restore.write_text(text.replace(old, new, 1))

tests = Path('tests/suites/data-protection/case-restore-recovery.bash')
text = tests.read_text()
anchor = '''check_remote_restore_listing_truthfulness() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
RESTORE="$ROOT/utilities/restore-run.sh"
'''
replacement = anchor + '''grep -Fq 'mktemp "${CONTROL_WORKSPACE:-/tmp}/vw-rclone-list-${t}.XXXXXX"' "$RESTORE" \\
    || fail 'remote listing diagnostics must use a collision-safe temporary file'\n'''
if text.count(anchor) != 1:
    raise SystemExit(f'remote listing test anchor count={text.count(anchor)}')
tests.write_text(text.replace(anchor, replacement, 1))
