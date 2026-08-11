from pathlib import Path
import re

p = Path('lib/firewall.sh')
t = p.read_text()
anchor = 'firewall_load_cached_cloudflare_ipv4() {\n'
helper = r'''firewall_fail_closed_stop_caddy() {
    local container="${VW_CADDY_CONTAINER_NAME:-vaultwarden_caddy}" running="" rc=0
    [[ "${DRY_RUN:-false}" != "true" ]] || return 0
    command -v docker >/dev/null 2>&1 || {
        log_error "CRITICAL: firewall reconciliation failed and Docker is unavailable; cannot confirm ${container} is stopped."
        return 1
    }

    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        # Missing container is safe; an unqueryable Docker daemon is not.
        if docker container inspect "$container" >/dev/null 2>&1; then
            log_error "CRITICAL: firewall reconciliation failed and ${container} running state could not be determined."
            return 1
        fi
        return 0
    fi
    [[ "$running" == "true" ]] || return 0

    log_warn "Firewall reconciliation failed; stopping ${container} to keep published web ingress fail-closed."
    if ! docker stop --time 30 "$container" >/dev/null; then
        log_error "CRITICAL: could not stop ${container} after firewall failure."
        return 1
    fi
    log_warn "${container} is stopped. Fix the firewall error, then start the stack normally."
    return 0
}

'''
if anchor not in t:
    raise SystemExit('firewall helper insertion anchor missing')
t = t.replace(anchor, helper + anchor, 1)
p.write_text(t)

p = Path('utilities/setup-firewall.sh')
t = p.read_text()
pattern = re.compile(r'(?ms)^main\(\) \{.*?^\}\n\nmain$')
new_main = r'''main() {
    require_root "${ORIGINAL_ARGS[@]}"
    if [[ "$DRY_RUN" != "true" ]]; then
        local ops_policy="fail"
        if [[ "$AUTO_MODE" == "true" || ! -t 0 || ! -t 1 ]]; then
            ops_policy="skip"
        fi
        operation_acquire --id setup --label "Setup" --non-interactive "$ops_policy" || exit $?
        _setup_firewall_cleanup() {
            local exit_rc=$?
            operation_release "$exit_rc"
            return "$exit_rc"
        }
        trap _setup_firewall_cleanup EXIT
        trap 'operation_release 130; exit 130' INT
        trap 'operation_release 143; exit 143' HUP TERM
        operation_set_phase "firewall" "Firewall setup"
    fi

    local rc=0 stop_rc=0
    case "$PHASE" in
        ufw)
            _phase_ufw || rc=$?
            ;;
        iptables)
            _phase_iptables || rc=$?
            ;;
        all)
            _phase_ufw || rc=$?
            if (( rc == 0 )); then
                _phase_iptables || rc=$?
            fi
            ;;
    esac

    if (( rc != 0 )) && [[ "$DRY_RUN" != "true" ]]; then
        firewall_fail_closed_stop_caddy || stop_rc=$?
        if (( stop_rc != 0 )); then
            log_error "CRITICAL: firewall setup failed and fail-closed Caddy shutdown could not be confirmed."
        fi
    fi
    return "$rc"
}

main'''
t, count = pattern.subn(new_main, t, count=1)
if count != 1:
    raise SystemExit(f'setup-firewall main replacement failed: {count}')
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''assert_file_contains "$FIREWALL_LIB" '-j DROP'
'''
replacement = '''assert_file_contains "$FIREWALL_LIB" '-j DROP'
assert_file_contains "$FIREWALL_LIB" 'firewall_fail_closed_stop_caddy()'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || stop_rc=$?'
'''
if anchor not in t:
    raise SystemExit('fail-closed static assertion anchor missing')
t = t.replace(anchor, replacement, 1)

# Isolated behavior probe: a running Caddy is stopped exactly on fail-closed call.
anchor = '''# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
probe = r'''FAIL_CLOSED_DOCKER="$TMP/fail-closed-docker"
cat > "$FAIL_CLOSED_DOCKER" <<'EOF_FAIL_CLOSED_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAIL_CLOSED_DOCKER_LOG:?}"
case "${1:-}" in
    inspect)
        printf 'true\n'
        exit 0
        ;;
    stop)
        exit "${FAIL_CLOSED_STOP_RC:-0}"
        ;;
    container)
        exit 0
        ;;
esac
exit 2
EOF_FAIL_CLOSED_DOCKER
chmod 0755 "$FAIL_CLOSED_DOCKER"
FAIL_CLOSED_PROBE="$TMP/fail-closed-caddy-probe.bash"
cat > "$FAIL_CLOSED_PROBE" <<'EOF_FAIL_CLOSED_PROBE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
log_warn(){ printf 'WARN: %s\n' "$*" >> "${FAIL_CLOSED_LOG:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${FAIL_CLOSED_LOG:?}"; }
docker(){ "${FAIL_CLOSED_DOCKER:?}" "$@"; }
EOF_FAIL_CLOSED_PROBE
extract_func "$FIREWALL_LIB" firewall_fail_closed_stop_caddy >> "$FAIL_CLOSED_PROBE"
cat >> "$FAIL_CLOSED_PROBE" <<'EOF_FAIL_CLOSED_PROBE'
firewall_fail_closed_stop_caddy
EOF_FAIL_CLOSED_PROBE
chmod 0755 "$FAIL_CLOSED_PROBE"
FAIL_CLOSED_DOCKER_LOG="$TMP/fail-closed-docker.log"
FAIL_CLOSED_LOG="$TMP/fail-closed.log"
: > "$FAIL_CLOSED_DOCKER_LOG"; : > "$FAIL_CLOSED_LOG"
export FAIL_CLOSED_DOCKER FAIL_CLOSED_DOCKER_LOG FAIL_CLOSED_LOG
"$BASH" "$FAIL_CLOSED_PROBE"
assert_file_contains "$FAIL_CLOSED_DOCKER_LOG" 'inspect --format {{.State.Running}} vaultwarden_caddy'
assert_file_contains "$FAIL_CLOSED_DOCKER_LOG" 'stop --time 30 vaultwarden_caddy'
assert_file_contains "$FAIL_CLOSED_LOG" 'Firewall reconciliation failed; stopping vaultwarden_caddy'

# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
if anchor not in t:
    raise SystemExit('fail-closed behavior probe anchor missing')
t = t.replace(anchor, probe, 1)
p.write_text(t)
