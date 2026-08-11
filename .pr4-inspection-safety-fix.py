from pathlib import Path
import re

# ---------------------------------------------------------------------------
# UFW: inactive rulesets must not hide permissive configured rules.
# ---------------------------------------------------------------------------
p = Path('utilities/setup-firewall.sh')
t = p.read_text()
old = '''        true|numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
        verbose)       output="$(ufw status verbose 2>&1)" || rc=$? ;;
        false|normal)  output="$(ufw status 2>&1)" || rc=$? ;;
'''
new = '''        true|numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
        verbose)       output="$(ufw status verbose 2>&1)" || rc=$? ;;
        added)         output="$(ufw show added 2>&1)" || rc=$? ;;
        false|normal)  output="$(ufw status 2>&1)" || rc=$? ;;
'''
if old not in t:
    raise SystemExit('setup _ufw_status modes anchor missing')
t = t.replace(old, new, 1)

anchor = '''_ufw_validate_safety() {
    local verbose_status numbered_status
    verbose_status="$(_ufw_status verbose)" || return $?
    numbered_status="$(_ufw_status numbered)" || return $?
    _ufw_default_incoming_fail_closed "$verbose_status" || return $?
    _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
}
'''
replacement = r'''_ufw_reject_hidden_inactive_permissive_rules() {
    local verbose_status="$1" added line
    grep -Eq '^Status:[[:space:]]+inactive' <<< "$verbose_status" || return 0

    added="$(_ufw_status added)" || return $?
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*ufw[[:space:]]+ ]] || continue
        if [[ "$line" =~ (^|[[:space:]])(allow|limit)([[:space:]]|$) ]] || \
           [[ "$line" =~ (^|[[:space:]])route[[:space:]]+(allow|limit)([[:space:]]|$) ]]; then
            log_error "Inactive UFW has preconfigured permissive rules that cannot be safely proven before enablement: ${line}"
            log_error "Review 'sudo ufw show added'; enable/review UFW manually or reset the stale rules before retrying setup."
            return 1
        fi
    done <<< "$added"
    return 0
}

_ufw_validate_safety() {
    local verbose_status numbered_status
    verbose_status="$(_ufw_status verbose)" || return $?
    numbered_status="$(_ufw_status numbered)" || return $?
    _ufw_default_incoming_fail_closed "$verbose_status" || return $?
    _ufw_reject_hidden_inactive_permissive_rules "$verbose_status" || return $?
    _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
}
'''
if anchor not in t:
    raise SystemExit('setup _ufw_validate_safety anchor missing')
t = t.replace(anchor, replacement, 1)
p.write_text(t)

# Updater must never mutate an inactive UFW configuration. Maintenance owns
# refreshing an already-enforced host policy, not enabling a dormant firewall.
p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()
anchor = '''    _ufw_validate_safety() {
        local verbose_status numbered_status
        verbose_status="$(_ufw_status verbose)" || return $?
        numbered_status="$(_ufw_status numbered)" || return $?
        _ufw_default_incoming_fail_closed "$verbose_status" || return $?
        _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
    }
'''
replacement = r'''    _ufw_validate_safety() {
        local verbose_status numbered_status
        verbose_status="$(_ufw_status verbose)" || return $?
        if ! grep -q '^Status: active' <<< "$verbose_status"; then
            log_error "UFW is inactive; refusing periodic firewall mutation."
            log_error "Enable and verify UFW first, then rerun the Cloudflare firewall update."
            return 1
        fi
        numbered_status="$(_ufw_status numbered)" || return $?
        _ufw_default_incoming_fail_closed "$verbose_status" || return $?
        _ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
    }
'''
if anchor not in t:
    raise SystemExit('updater _ufw_validate_safety anchor missing')
t = t.replace(anchor, replacement, 1)
p.write_text(t)

# ---------------------------------------------------------------------------
# systemd: render/install/validate one exact Docker runtime drop-in contract.
# ---------------------------------------------------------------------------
p = Path('utilities/setup-systemd.sh')
t = p.read_text()
old = r'''_install_docker_runtime_dropin() {
    local dropin_dir
    dropin_dir="$(dirname "$DOCKER_RUNTIME_DROPIN")"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
        return 0
    fi
    mkdir -p "$dropin_dir" || {
        log_error "Cannot create Docker systemd drop-in directory: $dropin_dir"
        return 1
    }
    cat > "$DOCKER_RUNTIME_DROPIN" <<'DROPIN'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy has restart: "no" so dockerd cannot publish it before this sequence.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
DROPIN
    chmod 0644 "$DOCKER_RUNTIME_DROPIN"
    log_success "Installed Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
}
'''
new = r'''_render_docker_runtime_dropin() {
    cat <<'DROPIN'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy has restart: "no" so dockerd cannot publish it before this sequence.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
DROPIN
}

_install_docker_runtime_dropin() {
    local dropin_dir tmp
    dropin_dir="$(dirname "$DOCKER_RUNTIME_DROPIN")"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
        return 0
    fi
    mkdir -p "$dropin_dir" || {
        log_error "Cannot create Docker systemd drop-in directory: $dropin_dir"
        return 1
    }
    tmp="$(mktemp -p "$dropin_dir" .20-vaultwarden-runtime.XXXXXXXXXX)" || return 1
    _render_docker_runtime_dropin > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$DOCKER_RUNTIME_DROPIN" || { rm -f "$tmp"; return 1; }
    log_success "Installed Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
}

_validate_docker_runtime_dropin() {
    local expected owner group mode rc=0
    if [[ ! -f "$DOCKER_RUNTIME_DROPIN" ]]; then
        log_error "  MISSING: $DOCKER_RUNTIME_DROPIN"
        log_error "  Docker restarts would not re-run firewall reconciliation/startup."
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        return 1
    fi

    expected="$(mktemp)" || return 1
    _render_docker_runtime_dropin > "$expected" || { rm -f "$expected"; return 1; }
    if ! cmp -s "$expected" "$DOCKER_RUNTIME_DROPIN"; then
        log_error "  DRIFT: $DOCKER_RUNTIME_DROPIN does not match the managed Docker lifecycle contract"
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        rc=1
    fi
    rm -f "$expected"

    owner="$(stat -c '%U' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    group="$(stat -c '%G' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    mode="$(stat -c '%a' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    if [[ "$owner" != root || "$group" != root || "$mode" != 644 ]]; then
        log_error "  PERMISSIONS: $DOCKER_RUNTIME_DROPIN is ${owner}:${group} mode ${mode} (expected root:root 644)"
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        rc=1
    fi
    [[ "$rc" -eq 0 ]] && log_success "  OK: $DOCKER_RUNTIME_DROPIN"
    return "$rc"
}
'''
if old not in t:
    raise SystemExit('docker runtime dropin install helper anchor missing')
t = t.replace(old, new, 1)

anchor = '''    log_info "[4/9] Checking systemd drop-in files ..."
'''
replacement = '''    log_info "[4/9] Checking systemd drop-in files ..."
    if ! _validate_docker_runtime_dropin; then
        (( errors++ )) || true
    fi
'''
if anchor not in t:
    raise SystemExit('validate dropin section anchor missing')
t = t.replace(anchor, replacement, 1)
p.write_text(t)

# ---------------------------------------------------------------------------
# Regression coverage.
# ---------------------------------------------------------------------------
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()

# Stateful UFW mock: `show added` has a dedicated fixture.
anchor = '''if [[ "${1:-}" == "reload" ]]; then
    printf 'ufw-reload\\n' >> "${TXN_CALL_LOG:?}"
    exit "${UFW_RELOAD_RC:-0}"
fi

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
'''
replacement = '''if [[ "${1:-}" == "reload" ]]; then
    printf 'ufw-reload\\n' >> "${TXN_CALL_LOG:?}"
    exit "${UFW_RELOAD_RC:-0}"
fi

if [[ "${1:-}" == "show" && "${2:-}" == "added" ]]; then
    if (( ${UFW_ADDED_RC:-0} != 0 )); then
        printf '%s\\n' "${UFW_ADDED_OUTPUT:-show added failed}" >&2
        exit "$UFW_ADDED_RC"
    fi
    cat "${UFW_ADDED_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
'''
if anchor not in t:
    raise SystemExit('UFW show-added mock anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    UFW_DEFAULTS_FILE="$CASE_DIR/ufw-defaults"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
'''
replacement = '''    UFW_DEFAULTS_FILE="$CASE_DIR/ufw-defaults"
    UFW_ADDED_FILE="$CASE_DIR/ufw-added"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
'''
if anchor not in t:
    raise SystemExit('UFW added fixture path anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    printf 'DEFAULT_INPUT_POLICY="DROP"\\n' > "$UFW_DEFAULTS_FILE"
    printf 'baseline-v4\\n' > "$UFW_CONFIG_DIR/user.rules"
'''
replacement = '''    printf 'DEFAULT_INPUT_POLICY="DROP"\\n' > "$UFW_DEFAULTS_FILE"
    : > "$UFW_ADDED_FILE"
    printf 'baseline-v4\\n' > "$UFW_CONFIG_DIR/user.rules"
'''
if anchor not in t:
    raise SystemExit('UFW added fixture reset anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    unset UFW_VERBOSE_RC UFW_VERBOSE_OUTPUT
'''
replacement = '''    unset UFW_VERBOSE_RC UFW_VERBOSE_OUTPUT UFW_ADDED_RC UFW_ADDED_OUTPUT
'''
if anchor not in t:
    raise SystemExit('UFW added unset anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG TXN_CALL_LOG LOG_FILE
'''
replacement = '''    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_ADDED_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG TXN_CALL_LOG LOG_FILE
'''
if anchor not in t:
    raise SystemExit('UFW added export anchor missing')
t = t.replace(anchor, replacement, 1)

# Periodic updater inactive behavior: fail before UFW/Docker mutation.
anchor = '''reset_case default-incoming-allow
'''
case = '''reset_case updater-inactive-ufw
write_ipv4_status true true
printf 'Status: inactive\\n' > "$UFW_VERBOSE_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted inactive UFW"
assert_file_contains "$LOG_FILE" 'UFW is inactive; refusing periodic firewall mutation'
assert_no_call ' allow '
assert_no_call '--force delete'
[[ ! -s "$FW_CALL_LOG" || "$(cat "$FW_CALL_LOG")" == 'preflight' ]] \
    || fail "inactive UFW caused Docker firewall mutation"

reset_case default-incoming-allow
'''
if anchor not in t:
    raise SystemExit('inactive updater case anchor missing')
t = t.replace(anchor, case, 1)

# Setup probe needs the new hidden-rule helper.
anchor = '''extract_func "$SETUP_FIREWALL" _ufw_default_incoming_fail_closed >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_ambiguous_inbound_allows >> "$SETUP_UFW_PROBE"
'''
replacement = '''extract_func "$SETUP_FIREWALL" _ufw_default_incoming_fail_closed >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_hidden_inactive_permissive_rules >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_ambiguous_inbound_allows >> "$SETUP_UFW_PROBE"
'''
if anchor not in t:
    raise SystemExit('setup UFW helper extraction anchor missing')
t = t.replace(anchor, replacement, 1)

# Standalone setup safety probe calls _ufw_validate_safety directly.
anchor = '''    ensure)
        _ufw_ensure_range 203.0.113.0/24 CF-IPv4
        ;;
    *) exit 2 ;;
esac
'''
replacement = '''    ensure)
        _ufw_ensure_range 203.0.113.0/24 CF-IPv4
        ;;
    safety)
        _ufw_validate_safety
        ;;
    *) exit 2 ;;
esac
'''
if anchor not in t:
    raise SystemExit('setup UFW probe case anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''reset_case setup-public-readiness
'''
case = '''reset_case setup-inactive-hidden-permissive-rule
printf 'Status: inactive\\n' > "$UFW_VERBOSE_FILE"
printf 'Status: inactive\\n' > "$UFW_NUMBERED_FILE"
printf 'ufw allow Nginx Full\\n' > "$UFW_ADDED_FILE"
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=safety "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "inactive UFW hid a preconfigured permissive application rule"
assert_file_contains "$LOG_FILE" 'Inactive UFW has preconfigured permissive rules'
[[ ! -s "$UFW_CALL_LOG" || "$(cat "$UFW_CALL_LOG")" == $'status verbose\\nstatus numbered\\nshow added' ]] \
    || fail "inactive setup safety proof mutated UFW"

reset_case setup-public-readiness
'''
if anchor not in t:
    raise SystemExit('inactive setup case insertion anchor missing')
t = t.replace(anchor, case, 1)

# Extend Docker drop-in probe to validate success, drift, and missing states.
anchor = '''extract_func "$SYSTEMD_SETUP" _install_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
cat >> "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
_install_docker_runtime_dropin
EOF_DOCKER_DROPIN
'''
replacement = '''extract_func "$SYSTEMD_SETUP" _render_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
extract_func "$SYSTEMD_SETUP" _install_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
extract_func "$SYSTEMD_SETUP" _validate_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
cat >> "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
_install_docker_runtime_dropin
_validate_docker_runtime_dropin
EOF_DOCKER_DROPIN
'''
if anchor not in t:
    raise SystemExit('Docker dropin probe extraction anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''assert_file_contains "$docker_runtime_dropin" 'Wants=vaultwarden-iptables.service vaultwarden-startup.service'

# Separate-volume installs must order the boot firewall owner after the mount,
'''
replacement = '''assert_file_contains "$docker_runtime_dropin" 'Wants=vaultwarden-iptables.service vaultwarden-startup.service'
assert_file_contains "$SYSTEMD_SETUP" '_validate_docker_runtime_dropin'
assert_file_contains "$SYSTEMD_SETUP" 'Docker restarts would not re-run firewall reconciliation/startup.'

# Separate-volume installs must order the boot firewall owner after the mount,
'''
if anchor not in t:
    raise SystemExit('Docker dropin validation assertion anchor missing')
t = t.replace(anchor, replacement, 1)

p.write_text(t)
