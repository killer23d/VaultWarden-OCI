from pathlib import Path
p = Path('.pr4-update-transaction.py')
t = p.read_text()
old_anchor = '''anchor = '''"'''"'''[[ \"$CASE_RC\" -eq 44 ]] || fail \"delete failure returned $CASE_RC instead of 44\"\nassert_file_contains \"$LOG_FILE\" 'simulated delete failure'\n'''"'''"'''\nreplacement = '''"'''"'''[[ \"$CASE_RC\" -eq 44 ]] || fail \"delete failure returned $CASE_RC instead of 44\"\nassert_file_contains \"$LOG_FILE\" 'simulated delete failure'\nassert_call 'reload'\n[[ \"$(cat \"$UFW_CONFIG_DIR/user.rules\")\" == 'baseline-v4' ]] \\\n    || fail \"UFW delete failure left managed rules partially updated\"\n'''"'''"'''\n'''
new_anchor = '''anchor = '''"'''"'''[[ \"$CASE_RC\" -eq 45 ]] || fail \"delete failure returned $CASE_RC instead of 45\"\nassert_file_contains \"$LOG_FILE\" 'Failed to delete UFW rule 12'\nassert_file_contains \"$LOG_FILE\" 'simulated delete failure'\n'''"'''"'''\nreplacement = '''"'''"'''[[ \"$CASE_RC\" -eq 45 ]] || fail \"delete failure returned $CASE_RC instead of 45\"\nassert_file_contains \"$LOG_FILE\" 'Failed to delete UFW rule 12'\nassert_file_contains \"$LOG_FILE\" 'simulated delete failure'\nassert_call 'reload'\n[[ \"$(cat \"$UFW_CONFIG_DIR/user.rules\")\" == 'baseline-v4' ]] \\\n    || fail \"UFW delete failure left managed rules partially updated\"\n'''"'''"'''\n'''
if old_anchor not in t:
    raise SystemExit('stale delete-failure block not found in transaction helper')
p.write_text(t.replace(old_anchor, new_anchor, 1))
