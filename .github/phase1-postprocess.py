from pathlib import Path

path = Path("tests/suites/security/case-secrets.bash")
text = path.read_text()
start = '''
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
TESTS_RUN=0
OP="age1op00000000000000000000000000000000000000000000000000000000"'''
end = "\nprintf '1..%s\\n' \"$TESTS_RUN\"\n\ncheck_key_rotate_live_generation_transaction() ("
call_anchor = '''        check_runtime_secret_reconciliation
        check_key_rotate_live_generation_transaction'''

if text.count(start) != 1 or text.count(end) != 1:
    raise SystemExit("generated secrets transaction block not found exactly once")
if text.count(call_anchor) != 2:
    raise SystemExit("generated secrets dispatcher anchors not found exactly twice")

text = text.replace(start, "\ncheck_setup_secrets_transaction() (" + start, 1)
text = text.replace(
    end,
    "\nprintf '1..%s\\n' \"$TESTS_RUN\"\n)\n\ncheck_key_rotate_live_generation_transaction() (",
    1,
)
text = text.replace(
    call_anchor,
    '''        check_runtime_secret_reconciliation
        check_setup_secrets_transaction
        check_key_rotate_live_generation_transaction''',
)
path.write_text(text)
