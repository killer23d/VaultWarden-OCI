from pathlib import Path

p = Path('lib/secrets.sh')
t = p.read_text()
old = '''    _eds_tmpdir="$(create_sensitive_workspace runtime-secrets)" || {
        log_error "export_docker_secrets: no verified volatile plaintext staging directory is available"
        return 1
    }
    _eds_cache="${_eds_tmpdir}/secrets.yaml"
'''
new = '''    _eds_tmpdir="$(create_sensitive_workspace runtime-secrets)" || {
        log_error "export_docker_secrets: no verified volatile plaintext staging directory is available"
        return 1
    }
    if declare -F register_cleanup >/dev/null 2>&1 \
            && declare -p CLEANUP_ACTIONS >/dev/null 2>&1; then
        if ! register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"; then
            remove_sensitive_workspace "$_eds_tmpdir" 2>/dev/null || true
            log_error "export_docker_secrets: failed to register volatile workspace cleanup"
            return 1
        fi
    fi
    _eds_cache="${_eds_tmpdir}/secrets.yaml"
'''
if old not in t:
    raise SystemExit('runtime secrets workspace allocation block not found')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''grep -Fq 'create_sensitive_workspace runtime-secrets' lib/secrets.sh || fail "runtime secret export staging is not volatile"
'''
checks = '''grep -Fq 'declare -p CLEANUP_ACTIONS' lib/secrets.sh || fail "runtime secret export does not verify caller cleanup-stack initialization"
grep -Fq 'register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"' lib/secrets.sh || fail "runtime secret export workspace is not registered for caller signal cleanup"
grep -Fq 'failed to register volatile workspace cleanup' lib/secrets.sh || fail "runtime secret export does not fail closed when cleanup registration fails"
'''
if anchor not in t:
    raise SystemExit('runtime workspace test anchor not found')
t = t.replace(anchor, anchor + checks, 1)
p.write_text(t)
