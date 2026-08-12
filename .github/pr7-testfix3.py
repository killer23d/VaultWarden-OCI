from pathlib import Path

p = Path('utilities/setup-secrets.sh')
t = p.read_text()
old = '''            if [[ -f "$sudoers_file" ]] && grep -q "^${BREAKGLASS_USER} " "$sudoers_file" 2>/dev/null; then
                echo "  Sudo access: ✅ Configured (targeted /etc/sudoers.d/vw-emergency)"
            elif groups "$BREAKGLASS_USER" 2>/dev/null | grep -q -w "sudo"; then
                echo "  Sudo access: ⚠️  Member of 'sudo' group (legacy full-root configuration)"
            else
                echo "  Sudo access: ❌ NOT configured"
            fi
'''
new = '''            if [[ -f "$sudoers_file" ]] && grep -q "^${BREAKGLASS_USER} " "$sudoers_file" 2>/dev/null; then
                echo "  Sudo access: ✅ Configured (targeted /etc/sudoers.d/vw-emergency)"
            else
                echo "  Sudo access: ❌ NOT configured"
            fi
'''
if old not in t:
    raise SystemExit('remaining legacy sudo-group status block not found')
p.write_text(t.replace(old, new, 1))
