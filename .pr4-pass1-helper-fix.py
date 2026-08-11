from pathlib import Path
p = Path('.pr4-pass1-batch.py')
s = p.read_text()
marker = "    raise SystemExit('setup SSH final verification anchor missing')"
pos = s.index(marker)
start = s.rfind("old = '''", 0, pos)
end_marker = 't = t.replace(old, new, 1)\n'
end = s.index(end_marker, pos) + len(end_marker)
replacement = '''verify_start = t.index('    grep -qE "^${ssh_port}/tcp', t.index('_ufw_verify_exact() {'))
verify_end = t.index('\\n\\n    if [[ -n "$(_ufw_collect_conflicts', verify_start)
new_verify = '''"'''"'''    _ufw_has_broad_admin_port "$status" "$ssh_port" || {
        log_error "Broad UFW SSH rule for ${ssh_port}/tcp is missing after reconciliation."
        return 1
    }'''"'''"'''
t = t[:verify_start] + new_verify + t[verify_end:]
'''
p.write_text(s[:start] + replacement + s[end:])
