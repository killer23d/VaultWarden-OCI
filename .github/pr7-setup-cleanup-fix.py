from pathlib import Path

p = Path('utilities/setup-secrets.sh')
t = p.read_text()
old = '''    if declare -F cleanup_secrets_environment >/dev/null 2>&1; then
        if ! cleanup_secrets_environment; then
            _setup_secrets_cleanup_warn "Secret environment cleanup reported a failure"
            cleanup_status=1
        fi
    fi

    if [[ -n "$workspace" ]]; then
'''
new = '''    if declare -F cleanup_secrets_environment >/dev/null 2>&1; then
        if ! cleanup_secrets_environment; then
            _setup_secrets_cleanup_warn "Secret environment cleanup reported a failure"
            cleanup_status=1
        fi
    fi

    # Drain the shared cleanup stack as part of this script's custom signal/exit
    # path. This covers volatile workspaces registered by shared helpers such as
    # export_docker_secrets(), while retaining setup-secrets' own cleanup state.
    if declare -F perform_cleanup >/dev/null 2>&1; then
        if ! perform_cleanup; then
            _setup_secrets_cleanup_warn "Shared sensitive cleanup reported a failure"
            cleanup_status=1
        fi
    fi

    if [[ -n "$workspace" ]]; then
'''
if old not in t:
    raise SystemExit('setup-secrets cleanup insertion anchor not found')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''grep -Fq 'register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"' lib/secrets.sh || fail "runtime secret export workspace is not registered for caller signal cleanup"
'''
checks = '''grep -Fq 'if ! perform_cleanup; then' utilities/setup-secrets.sh || fail "setup-secrets custom signal cleanup does not drain shared sensitive cleanup actions"
grep -Fq 'Shared sensitive cleanup reported a failure' utilities/setup-secrets.sh || fail "setup-secrets does not surface shared cleanup failures"
'''
if anchor not in t:
    raise SystemExit('runtime workspace test anchor not found')
t = t.replace(anchor, anchor + checks, 1)
p.write_text(t)
