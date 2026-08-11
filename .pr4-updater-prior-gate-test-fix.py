from pathlib import Path

p = Path("tests/suites/operations/case-firewall-update.bash")
text = p.read_text()
old = '''[[ ! -s "$FW_CALL_LOG" || "$(cat "$FW_CALL_LOG")" == 'preflight' ]]     || fail "inactive UFW caused Docker firewall mutation"\n'''
new = '''assert_file_contains "$FW_CALL_LOG" 'stop-caddy'\n! grep -Fq 'reconcile ' "$FW_CALL_LOG" || fail "inactive UFW caused Docker firewall reconciliation"\n'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"inactive-UFW assertion: expected 1 occurrence, found {count}")
p.write_text(text.replace(old, new, 1))
