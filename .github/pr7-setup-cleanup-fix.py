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
if 'Set to 0 to disable auto-expiry entirely.' in t:
    raise SystemExit('stale break-glass zero-expiry help remains')
p.write_text(t)

p = Path('lib/secrets.sh')
t = p.read_text()
t = t.replace(
    "Prefer upstream 7zz from Ubuntu's 7zip\n# package, with legacy 7z retained as a compatibility fallback.",
    "Require upstream 7zz from Ubuntu's 7zip package; no legacy executable fallback is supported.",
)
t = t.replace(
    "portable across upstream 7zz\n  # and the retained legacy 7z fallback.",
    "the supported 7zz transport.",
)
t = t.replace(
    "portable across upstream 7zz\n# and the retained legacy 7z fallback.",
    "the supported 7zz transport.",
)
if 'legacy 7z' in t:
    raise SystemExit('stale legacy 7z compatibility wording remains')
p.write_text(t)

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''grep -Fq 'register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"' lib/secrets.sh || fail "runtime secret export workspace is not registered for caller signal cleanup"\n'''
checks = '''grep -Fq 'declare -p CLEANUP_ACTIONS' utilities/setup-secrets.sh || fail "setup-secrets does not verify shared cleanup-stack initialization"\ngrep -Fq 'if ! perform_cleanup; then' utilities/setup-secrets.sh || fail "setup-secrets custom signal cleanup does not drain shared sensitive cleanup actions"\ngrep -Fq 'Shared sensitive cleanup reported a failure' utilities/setup-secrets.sh || fail "setup-secrets does not surface shared cleanup failures"\n! grep -Fq 'Set to 0 to disable auto-expiry entirely.' utilities/setup-secrets.sh || fail "break-glass help still claims mandatory expiry can be disabled"\n! grep -Fq 'legacy 7z' lib/secrets.sh || fail "recovery-kit comments still describe the retired legacy 7z fallback"\n'''
if anchor not in t:
    raise SystemExit('runtime workspace test anchor not found')
t = t.replace(anchor, anchor + checks, 1)

behavior_anchor = '''# Direct configure uses its installed TERM trap to clean the owned workspace.\n'''
behavior_checks = r'''# Known GUI editors must refuse unsafe forking invocations and accept only
# editor-specific blocking flags. Unknown foreground editors remain allowed.
editor_helper_source="$(sed -n '/^_check_editor_forks() {$/,/^}$/p' utilities/secrets-edit.sh)"
[[ -n "$editor_helper_source" ]] || fail "editor wait helper could not be extracted"
EDITOR_HELPER_SOURCE="$editor_helper_source" bash -s <<'EDITOR_WAIT_TEST' \
  || fail "editor blocking behavior regression failed"
set -euo pipefail
log_error() { :; }
eval "$EDITOR_HELPER_SOURCE"
EDITOR_CMD=(code)
! _check_editor_forks
EDITOR_CMD=(code -f)
! _check_editor_forks
EDITOR_CMD=(code --wait)
_check_editor_forks
EDITOR_CMD=(kate -f)
! _check_editor_forks
EDITOR_CMD=(kate --block)
_check_editor_forks
EDITOR_CMD=(gvim --nofork)
_check_editor_forks
EDITOR_CMD=(vim)
_check_editor_forks
EDITOR_WAIT_TEST

# Break-glass creation must roll the new account back non-interactively when
# expiry scheduling fails. This isolates the creation function and mocks all
# host mutations while retaining the production rollback branch.
breakglass_create_source="$(
  sed -n '/^    create_breakglass_user() {$/,/^    }$/p' utilities/setup-secrets.sh \
    | sed 's/^    //'
)"
[[ -n "$breakglass_create_source" ]] || fail "break-glass creation helper could not be extracted"
BREAKGLASS_CREATE_SOURCE="$breakglass_create_source" bash -s <<'BREAKGLASS_ROLLBACK_TEST' \
  || fail "break-glass scheduling-failure rollback regression failed"
set -euo pipefail
fixture="$(mktemp -d)"
trap '/bin/rm -rf -- "$fixture"' EXIT
rollback_marker="$fixture/rollback.arg"
DRY_RUN=false
FORCE=false
BREAKGLASS_USER=vw-test
BREAKGLASS_AUTO_EXPIRY_HOURS=2
PROJECT_ROOT=/tmp
COLOR_RED="" COLOR_RESET="" COLOR_YELLOW="" COLOR_GREEN=""
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }
check_user_exists() { return 1; }
generate_secure_random() { printf '%s' 'test-password-value'; }
useradd() { return 0; }
chpasswd() { cat >/dev/null; return 0; }
create_sudoers_config() { return 0; }
create_secure_file() { return 0; }
schedule_auto_cleanup() { return 1; }
remove_breakglass_user() { printf '%s' "${1:-}" > "$rollback_marker"; return 0; }
eval "$BREAKGLASS_CREATE_SOURCE"
set +e
create_breakglass_user >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 ))
[[ "$(cat "$rollback_marker")" == '--force' ]]
BREAKGLASS_ROLLBACK_TEST

'''
if behavior_anchor not in t:
    raise SystemExit('behavioral test insertion anchor not found')
t = t.replace(behavior_anchor, behavior_checks + behavior_anchor, 1)

t = t.replace(
'''direct_signal_marker="$direct_signal_fixture/workspace.path"\ndirect_runtime_tmp="$direct_signal_fixture/runtime-tmp"\n''',
'''direct_signal_marker="$direct_signal_fixture/workspace.path"\ndirect_shared_marker="$direct_signal_fixture/shared-workspace.path"\ndirect_runtime_tmp="$direct_signal_fixture/runtime-tmp"\n''',
1,
)
t = t.replace(
'''DIRECT_SIGNAL_MARKER="$direct_signal_marker" \\\nVW_SETUP_SECRETS_TMP_DIR="$direct_runtime_tmp" \\\n''',
'''DIRECT_SIGNAL_MARKER="$direct_signal_marker" \\\nDIRECT_SHARED_MARKER="$direct_shared_marker" \\\nVW_SETUP_SECRETS_TMP_DIR="$direct_runtime_tmp" \\\n''',
1,
)
t = t.replace(
'''cleanup_secrets_environment() { return 0; }\noperation_release() { return 0; }\n_ss_plain_tmp_dir() { printf '%s' "$VW_SETUP_SECRETS_TMP_DIR"; }\n''',
'''cleanup_secrets_environment() { return 0; }\noperation_release() { return 0; }\nremove_sensitive_workspace() { /bin/rm -rf -- "$1"; }\n_CLEANUP_SEP=$'\\x1f'\ndeclare -a CLEANUP_ACTIONS=()\nperform_cleanup() {\n  local entry fn target\n  for entry in "${CLEANUP_ACTIONS[@]}"; do\n    IFS="$_CLEANUP_SEP" read -r fn target <<< "$entry"\n    "$fn" "$target"\n  done\n  CLEANUP_ACTIONS=()\n}\n_ss_plain_tmp_dir() { printf '%s' "$VW_SETUP_SECRETS_TMP_DIR"; }\n''',
1,
)
t = t.replace(
'''printf '%s' 'DIRECT-SIGNAL-SECRET' > "$SETUP_SECRETS_OWNED_WORKDIR/capture"\nkill -TERM "$BASHPID"\n''',
'''printf '%s' 'DIRECT-SIGNAL-SECRET' > "$SETUP_SECRETS_OWNED_WORKDIR/capture"\nshared_workspace="$VW_SETUP_SECRETS_TMP_DIR/shared-runtime"\nmkdir -p "$shared_workspace"\nchmod 0700 "$shared_workspace"\nprintf '%s' 'DIRECT-SHARED-RUNTIME-SECRET' > "$shared_workspace/secrets.yaml"\nprintf '%s' "$shared_workspace" > "$DIRECT_SHARED_MARKER"\nCLEANUP_ACTIONS+=("remove_sensitive_workspace${_CLEANUP_SEP}${shared_workspace}")\nkill -TERM "$BASHPID"\n''',
1,
)
t = t.replace(
'''direct_signal_workspace="$(cat "$direct_signal_marker")"\n[[ "$direct_signal_rc" == 143 ]] \\\n  || fail "direct TERM path returned $direct_signal_rc instead of 143"\n[[ ! -e "$direct_signal_workspace" ]] \\\n  || fail "direct TERM path left the sensitive workspace behind"\n''',
'''direct_signal_workspace="$(cat "$direct_signal_marker")"\ndirect_shared_workspace="$(cat "$direct_shared_marker")"\n[[ "$direct_signal_rc" == 143 ]] \\\n  || fail "direct TERM path returned $direct_signal_rc instead of 143"\n[[ ! -e "$direct_signal_workspace" ]] \\\n  || fail "direct TERM path left the sensitive workspace behind"\n[[ ! -e "$direct_shared_workspace" ]] \\\n  || fail "direct TERM path left a shared runtime-secret workspace behind"\n''',
1,
)
if 'direct_shared_workspace=' not in t:
    raise SystemExit('direct TERM shared cleanup regression was not inserted')
p.write_text(t)
