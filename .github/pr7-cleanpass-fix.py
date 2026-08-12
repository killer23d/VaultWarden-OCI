from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "lib/secrets.sh",
    """#   1. SOPS decryption is written to a mktemp cache inside docker_dir (mode
#      700, not world-listable /tmp) to eliminate the TOCTOU window on
#      shared hosts.
""",
    """#   1. SOPS decryption is written only inside a verified volatile root-only
#      workspace; no persistent plaintext staging location is permitted.
""",
    "runtime export hardening comment",
)

p = Path("utilities/setup-secrets.sh")
t = p.read_text()

old = """        if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
            log_error "Failed to set user password"
            userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
            return 1
        fi

        if ! create_sudoers_config; then
            log_error "Failed to install sudoers configuration"
            userdel -r "$BREAKGLASS_USER" 2>/dev/null || true
            return 1
        fi
"""
new = """        if ! chpasswd <<< "${BREAKGLASS_USER}:${password}"; then
            log_error "Failed to set user password; rolling back the newly created account"
            if ! remove_breakglass_user --force >/dev/null 2>&1; then
                log_error "CRITICAL: password setup failed and automatic account rollback also failed."
            fi
            return 1
        fi

        if ! create_sudoers_config; then
            log_error "Failed to install sudoers configuration; rolling back the newly created account"
            if ! remove_breakglass_user --force >/dev/null 2>&1; then
                log_error "CRITICAL: sudoers setup failed and automatic account rollback also failed."
            fi
            return 1
        fi
"""
if t.count(old) != 1:
    raise SystemExit("post-useradd rollback block not found exactly once")
t = t.replace(old, new, 1)

old = """        if ! check_user_exists; then
            log_info "User does not exist: $BREAKGLASS_USER"
            return 0
        fi

        if [[ "$FORCE" != "true" && "$force_remove" != "true" ]]; then
"""
new = """        local user_present=true
        if ! check_user_exists; then
            user_present=false
            log_info "User does not exist: $BREAKGLASS_USER; cleaning any stale break-glass artifacts"
        fi

        if [[ "$user_present" == "true" && "$FORCE" != "true" && "$force_remove" != "true" ]]; then
"""
if t.count(old) != 1:
    raise SystemExit("break-glass early-return block not found exactly once")
t = t.replace(old, new, 1)

old = """        if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
            log_success "User removed: $BREAKGLASS_USER"
        else
            log_error "Failed to remove break-glass user: $BREAKGLASS_USER"
            removal_failed=true
        fi
"""
new = """        if [[ "$user_present" == "true" ]]; then
            if userdel -r "$BREAKGLASS_USER" 2>/dev/null; then
                log_success "User removed: $BREAKGLASS_USER"
            else
                log_error "Failed to remove break-glass user: $BREAKGLASS_USER"
                removal_failed=true
            fi
        fi
"""
if t.count(old) != 1:
    raise SystemExit("break-glass userdel block not found exactly once")
t = t.replace(old, new, 1)
p.write_text(t)

p = Path("tests/suites/security/case-secrets.bash")
t = p.read_text()

anchor = """[[ "$(cat "$rollback_marker")" == '--force' ]]
BREAKGLASS_ROLLBACK_TEST
"""
addition = """[[ "$(cat "$rollback_marker")" == '--force' ]]

/bin/rm -f -- "$rollback_marker"
chpasswd() { cat >/dev/null; return 71; }
schedule_auto_cleanup() { return 0; }
set +e
create_breakglass_user >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 ))
[[ "$(cat "$rollback_marker")" == '--force' ]]
BREAKGLASS_ROLLBACK_TEST
"""
if t.count(anchor) != 1:
    raise SystemExit("create rollback test anchor not found exactly once")
t = t.replace(anchor, addition, 1)

anchor = """(( rc != 0 ))
BREAKGLASS_REMOVE_FAILURE_TEST
"""
addition = """(( rc != 0 ))

absent_stop_marker="$(mktemp)"
/bin/rm -f -- "$absent_stop_marker"
check_user_exists() { return 1; }
systemctl() {
  case "${1:-}" in
    is-active) return 0 ;;
    stop) printf '%s' stopped > "$absent_stop_marker"; return 0 ;;
    *) return 1 ;;
  esac
}
userdel() { return 99; }
remove_breakglass_user --force >/dev/null 2>&1
[[ -s "$absent_stop_marker" ]]
/bin/rm -f -- "$absent_stop_marker"
BREAKGLASS_REMOVE_FAILURE_TEST
"""
if t.count(anchor) != 1:
    raise SystemExit("remove failure test anchor not found exactly once")
t = t.replace(anchor, addition, 1)

old_assert = """grep -Fq '[[ \"$FORCE\" != \"true\" && \"$force_remove\" != \"true\" ]]' utilities/setup-secrets.sh || fail \"break-glass internal rollback can still prompt\"
"""
new_assert = """grep -Fq '[[ \"$user_present\" == \"true\" && \"$FORCE\" != \"true\" && \"$force_remove\" != \"true\" ]]' utilities/setup-secrets.sh || fail \"break-glass internal rollback can still prompt\"
"""
if t.count(old_assert) != 1:
    raise SystemExit("break-glass prompt-guard assertion not found exactly once")
t = t.replace(old_assert, new_assert, 1)

source_anchor = """grep -Fq 'register_cleanup "remove_sensitive_workspace" "$_eds_tmpdir"' lib/secrets.sh || fail "runtime secret export workspace is not registered for caller signal cleanup"
"""
source_add = """! grep -Fq 'mktemp cache inside docker_dir' lib/secrets.sh || fail "runtime export comment still describes retired disk-side plaintext staging"
grep -Fq 'cleaning any stale break-glass artifacts' utilities/setup-secrets.sh || fail "break-glass removal still short-circuits when the account is absent"
"""
if t.count(source_anchor) != 1:
    raise SystemExit("source assertion anchor not found exactly once")
t = t.replace(source_anchor, source_anchor + source_add, 1)
p.write_text(t)
