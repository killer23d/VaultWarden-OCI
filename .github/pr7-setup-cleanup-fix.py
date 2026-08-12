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
    # path when the caller initialized that stack. This covers volatile workspaces
    # registered by shared helpers such as export_docker_secrets().
    if declare -F perform_cleanup >/dev/null 2>&1 \\
            && declare -p CLEANUP_ACTIONS >/dev/null 2>&1; then
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
t = t.replace('''                                 Set to 0 to disable auto-expiry entirely.\n''', '', 1)
p.write_text(t)

p = Path('lib/secrets.sh')
t = p.read_text()
t = t.replace(
    "# and an archiver are available. Prefer upstream 7zz from Ubuntu's 7zip\n# package, with legacy 7z retained as a compatibility fallback.\n",
    "# and the required 7zz archiver from Ubuntu's 7zip package are available.\n",
    1,
)
t = t.replace(
    "# encountered. Supplying one line on stdin is portable across upstream 7zz\n# and the retained legacy 7z fallback.\n",
    "# encountered. Supplying one line on stdin is the supported 7zz transport.\n",
    1,
)
p.write_text(t)

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''grep -Fq 'register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"' lib/secrets.sh || fail "runtime secret export workspace is not registered for caller signal cleanup"\n'''
checks = '''grep -Fq 'declare -p CLEANUP_ACTIONS' utilities/setup-secrets.sh || fail "setup-secrets does not verify shared cleanup-stack initialization"\ngrep -Fq 'if ! perform_cleanup; then' utilities/setup-secrets.sh || fail "setup-secrets custom signal cleanup does not drain shared sensitive cleanup actions"\ngrep -Fq 'Shared sensitive cleanup reported a failure' utilities/setup-secrets.sh || fail "setup-secrets does not surface shared cleanup failures"\n! grep -Fq 'Set to 0 to disable auto-expiry entirely.' utilities/setup-secrets.sh || fail "break-glass help still claims mandatory expiry can be disabled"\n! grep -Fq 'legacy 7z' lib/secrets.sh || fail "recovery-kit comments still describe the retired legacy 7z fallback"\n'''
if anchor not in t:
    raise SystemExit('runtime workspace test anchor not found')
t = t.replace(anchor, anchor + checks, 1)
p.write_text(t)
