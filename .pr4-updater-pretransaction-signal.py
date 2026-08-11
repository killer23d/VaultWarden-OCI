from pathlib import Path

updater = Path("utilities/maintenance-update-firewall.sh")
text = updater.read_text()

old = '''    # Refuse all mutations if the running Docker daemon is using an unsupported
    # backend. A stale DOCKER-USER chain alone is not proof of the active mode.
    local docker_preflight_rc=0
    firewall_docker_backend_preflight || docker_preflight_rc=$?
'''
new = '''    # Until the current Docker backend and cached generation are proven safe,
    # an interrupt must not leave Caddy serving behind an unverified gate.
    local pre_update_docker_gate_exact=false
    _update_firewall_pretransaction_signal() {
        local signal_rc="$1"
        if [[ "$pre_update_docker_gate_exact" != "true" ]]; then
            if ! firewall_fail_closed_stop_caddy; then
                log_error "CRITICAL: firewall validation was interrupted and Caddy shutdown could not be confirmed."
            fi
        fi
        operation_release "$signal_rc"
        perform_cleanup
        exit "$signal_rc"
    }
    trap '_update_firewall_pretransaction_signal 130' INT
    trap '_update_firewall_pretransaction_signal 143' HUP TERM

    # Refuse all mutations if the running Docker daemon is using an unsupported
    # backend. A stale DOCKER-USER chain alone is not proof of the active mode.
    local docker_preflight_rc=0
    firewall_docker_backend_preflight || docker_preflight_rc=$?
'''
if text.count(old) != 1:
    raise SystemExit("preflight insertion anchor missing")
text = text.replace(old, new, 1)

old_decl = '''    local pre_update_docker_gate_exact=false
    local -a pre_update_ipv4_cidrs=()
'''
new_decl = '''    local -a pre_update_ipv4_cidrs=()
'''
if text.count(old_decl) != 1:
    raise SystemExit("prior-gate declaration anchor missing")
text = text.replace(old_decl, new_decl, 1)
updater.write_text(text)


test = Path("tests/suites/operations/case-firewall-update.bash")
t = test.read_text()

static_anchor = '''assert_file_contains "$UPDATER" 'firewall_docker_backend_preflight || docker_preflight_rc=$?'
preflight_line="$(grep -n 'firewall_docker_backend_preflight || docker_preflight_rc=' "$UPDATER" | cut -d: -f1 | head -1)"
fetch_line="$(grep -n 'Successfully fetched current Cloudflare IP ranges' "$UPDATER" | cut -d: -f1 | head -1)"
[[ -n "$preflight_line" && -n "$fetch_line" && "$preflight_line" -lt "$fetch_line" ]] \\
    || fail "Docker/prior-gate safety proof does not run before Cloudflare network refresh"
'''
static_new = static_anchor + '''assert_file_contains "$UPDATER" "trap '_update_firewall_pretransaction_signal 130' INT"
assert_file_contains "$UPDATER" "trap '_update_firewall_pretransaction_signal 143' HUP TERM"
pre_signal_line="$(grep -n "trap '_update_firewall_pretransaction_signal 143' HUP TERM" "$UPDATER" | cut -d: -f1 | head -1)"
[[ -n "$pre_signal_line" && -n "$fetch_line" && "$pre_signal_line" -lt "$fetch_line" ]] \\
    || fail "pre-transaction fail-closed signal trap is not installed before network refresh"
'''
if t.count(static_anchor) != 1:
    raise SystemExit("static preflight assertion anchor missing")
t = t.replace(static_anchor, static_new, 1)

insert_anchor = '''# Initial setup cache publication must fail explicitly and preserve the old
'''
signal_tests = '''# Pre-transaction signals must fail closed when the prior gate is unproven,
# but preserve a previously proven-safe generation.
PRETX_SIGNAL_PROBE="$TMP/updater-pretransaction-signal-probe.bash"
cat > "$PRETX_SIGNAL_PROBE" <<'EOF_PRETX_SIGNAL'
#!/usr/bin/env bash
set -euo pipefail
pre_update_docker_gate_exact="${PRETX_GATE_EXACT:-false}"
firewall_fail_closed_stop_caddy(){ printf 'stop-caddy\\n' >> "${PRETX_SIGNAL_LOG:?}"; return "${PRETX_STOP_RC:-0}"; }
log_error(){ printf 'ERROR: %s\\n' "$*" >> "${PRETX_SIGNAL_LOG:?}"; }
operation_release(){ printf 'release %s\\n' "$1" >> "${PRETX_SIGNAL_LOG:?}"; }
perform_cleanup(){ printf 'cleanup\\n' >> "${PRETX_SIGNAL_LOG:?}"; }
EOF_PRETX_SIGNAL
extract_func "$UPDATER" _update_firewall_pretransaction_signal >> "$PRETX_SIGNAL_PROBE"
cat >> "$PRETX_SIGNAL_PROBE" <<'EOF_PRETX_SIGNAL'
_update_firewall_pretransaction_signal 143
EOF_PRETX_SIGNAL
chmod 0755 "$PRETX_SIGNAL_PROBE"
PRETX_SIGNAL_LOG="$TMP/pretransaction-signal.log"
export PRETX_SIGNAL_LOG
: > "$PRETX_SIGNAL_LOG"
set +e
PRETX_GATE_EXACT=false "$BASH" "$PRETX_SIGNAL_PROBE"
PRETX_RC=$?
set -e
[[ "$PRETX_RC" -eq 143 ]] || fail "unproven pre-transaction signal returned $PRETX_RC instead of 143"
assert_file_contains "$PRETX_SIGNAL_LOG" 'stop-caddy'
assert_file_contains "$PRETX_SIGNAL_LOG" 'release 143'
assert_file_contains "$PRETX_SIGNAL_LOG" 'cleanup'

: > "$PRETX_SIGNAL_LOG"
set +e
PRETX_GATE_EXACT=true "$BASH" "$PRETX_SIGNAL_PROBE"
PRETX_RC=$?
set -e
[[ "$PRETX_RC" -eq 143 ]] || fail "safe-prior pre-transaction signal returned $PRETX_RC instead of 143"
! grep -Fq 'stop-caddy' "$PRETX_SIGNAL_LOG" || fail "proven-safe prior gate was stopped by pre-transaction signal handler"
assert_file_contains "$PRETX_SIGNAL_LOG" 'release 143'

'''
if t.count(insert_anchor) != 1:
    raise SystemExit("signal test insertion anchor missing")
t = t.replace(insert_anchor, signal_tests + insert_anchor, 1)
test.write_text(t)
