from pathlib import Path
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
old = "log_info(){ :; }\nlog_warn(){ printf 'WARN: %s\\n' \"$*\" >&2; }\n"
new = "log_info(){ :; }\nlog_success(){ :; }\nlog_warn(){ printf 'WARN: %s\\n' \"$*\" >&2; }\n"
if old not in t:
    raise SystemExit('systemd drop-in probe logging anchor not found')
p.write_text(t.replace(old, new, 1))
