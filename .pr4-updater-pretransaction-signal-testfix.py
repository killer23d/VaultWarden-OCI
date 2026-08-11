from pathlib import Path

p = Path("tests/suites/operations/case-firewall-update.bash")
text = p.read_text()
old = '''extract_func "$UPDATER" _update_firewall_pretransaction_signal >> "$PRETX_SIGNAL_PROBE"\n'''
new = '''awk '\n    /^[[:space:]]*_update_firewall_pretransaction_signal\\(\\)[[:space:]]*\\{/ {p=1}\n    p {\n        print\n        opens=gsub(/\\{/,"{"); closes=gsub(/\\}/,"}")\n        depth += opens - closes\n        if (depth == 0) exit\n    }' "$UPDATER" >> "$PRETX_SIGNAL_PROBE"\n'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"nested signal extractor anchor: expected 1, found {count}")
p.write_text(text.replace(old, new, 1))
