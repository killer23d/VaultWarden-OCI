from pathlib import Path

workflow = Path('.github/workflows/pr7-apply-validate.yml').read_text().splitlines()
start = next(i for i, line in enumerate(workflow) if "python3 <<'PY'" in line) + 1
end = next(i for i in range(start, len(workflow)) if workflow[i] == '          PY')
lines = [(line[10:] if line.startswith('          ') else line) + '\n' for line in workflow[start:end]]

# Current delta secrets-view uses mktemp without --suffix, while export uses it.
for i, line in enumerate(lines):
    if "local (temp_plain|temp_file)" in line and "pat=re.compile" in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = indent + "pat=re.compile(r'(?ms)^(\\s*)local (temp_plain|temp_file)\\n\\1\\2=\\$\\(mktemp -p /dev/shm(?: --suffix=\\.yaml)? 2>/dev/null \\|\\| mktemp(?: --suffix=\\.yaml)?\\)\\n.*?\\1register_cleanup \"_remove_sensitive_file\" \"\\$\\2\"\\n')\n"
        break
else:
    raise SystemExit('plaintext matcher line not found')

# Current delta rotate creates its two plaintext files in separate blocks.
rotate_start = next(i for i, line in enumerate(lines) if "p=Path('utilities/secrets-rotate.sh')" in line)
rotate_end = next(i for i in range(rotate_start, len(lines)) if "p.write_text(t[:m.start()]+new+t[m.end():])" in lines[i])
indent = lines[rotate_start][:len(lines[rotate_start]) - len(lines[rotate_start].lstrip())]
replacement = '''p=Path('utilities/secrets-rotate.sh'); t=p.read_text()
old_plain=''' + repr('''    local temp_plain\n    temp_plain=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)\n    if ! install -m 600 /dev/null "$temp_plain" 2>/dev/null; then\n        rm -f "$temp_plain"\n        log_error "Failed to secure temp file: $temp_plain"\n        return 1\n    fi\n    if [[ -n "$temp_plain" && "$temp_plain" != /dev/shm/* ]]; then\n        log_warn "rotate: /dev/shm unavailable — plaintext temp file is disk-backed: $temp_plain"\n        log_warn "        Ensure full-disk encryption is active on this host."\n    fi\n    register_cleanup "_remove_sensitive_file" "$temp_plain"\n''') + '''
new_plain=''' + repr('''    local temp_plain sensitive_workspace\n    sensitive_workspace="$(create_sensitive_workspace secrets-rotate)" || return 1\n    register_cleanup "remove_sensitive_workspace" "$sensitive_workspace"\n    temp_plain="${sensitive_workspace}/secrets.yaml"\n    install -m 600 /dev/null "$temp_plain" || return 1\n''') + '''
if old_plain not in t: raise SystemExit('rotate plaintext block missing')
t=t.replace(old_plain,new_plain,1)
old_patched=''' + repr('''    local temp_patched\n    temp_patched=$(mktemp -p /dev/shm --suffix=.yaml 2>/dev/null || mktemp --suffix=.yaml)\n    if ! install -m 600 /dev/null "$temp_patched" 2>/dev/null; then\n        rm -f "$temp_patched"\n        log_error "Failed to secure temp file: $temp_patched"\n        return 1\n    fi\n    if [[ -n "$temp_patched" && "$temp_patched" != /dev/shm/* ]]; then\n        log_warn "rotate: /dev/shm unavailable — patched temp file is disk-backed: $temp_patched"\n        log_warn "        Ensure full-disk encryption is active on this host."\n    fi\n    register_cleanup "_remove_sensitive_file" "$temp_patched"\n''') + '''
new_patched=''' + repr('''    local temp_patched\n    temp_patched="${sensitive_workspace}/secrets-patched.yaml"\n    install -m 600 /dev/null "$temp_patched" || return 1\n''') + '''
if old_patched not in t: raise SystemExit('rotate patched block missing')
t=t.replace(old_patched,new_patched,1)
p.write_text(t)
'''
lines[rotate_start:rotate_end + 1] = [indent + line if line.strip() else line for line in replacement.splitlines(True)]

Path('/tmp/pr7_patch.py').write_text(''.join(lines))
