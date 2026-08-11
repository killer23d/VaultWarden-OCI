from pathlib import Path
import re

p = Path('lib/firewall.sh')
t = p.read_text()
anchor = 'firewall_load_cached_cloudflare_ipv4() {\n'
helper = r'''firewall_normalize_caddy_runtime_contract() {
    local container="${VW_CADDY_CONTAINER_NAME:-vaultwarden_caddy}"
    local listed="" policy="" bindings="" binding_ok=false
    [[ "${DRY_RUN:-false}" != "true" ]] || return 0

    command -v docker >/dev/null 2>&1 || {
        log_error "Docker is unavailable; cannot verify the existing Caddy runtime contract."
        return 1
    }
    listed="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>/dev/null)" || {
        log_error "Docker could not query the existing Caddy container."
        return 1
    }
    [[ "$listed" == "$container" ]] || return 0

    policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)" || {
        log_error "Could not inspect ${container} restart policy."
        return 1
    }
    bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$container" 2>/dev/null)" || {
        log_error "Could not inspect ${container} published-port bindings."
        return 1
    }

    if python3 - "$bindings" <<'PY'
import json
import sys
try:
    bindings = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
for port in ("80/tcp", "443/tcp"):
    entries = bindings.get(port)
    if not isinstance(entries, list) or len(entries) != 1:
        raise SystemExit(1)
    entry = entries[0]
    if entry.get("HostIp") != "0.0.0.0" or entry.get("HostPort") != port.split("/", 1)[0]:
        raise SystemExit(1)
raise SystemExit(0)
PY
    then
        binding_ok=true
    fi

    if [[ "$binding_ok" != "true" ]]; then
        log_warn "Existing ${container} has legacy/non-IPv4-only published web bindings; removing the ephemeral container after firewall reconciliation."
        log_warn "Run the normal startup workflow to recreate Caddy from the current Compose contract."
        docker stop --time 30 "$container" >/dev/null 2>&1 || true
        if ! docker rm -f "$container" >/dev/null; then
            log_error "Could not remove unsafe legacy ${container} runtime."
            return 1
        fi
        return 0
    fi

    if [[ "$policy" != "on-failure" ]]; then
        log_info "Updating ${container} restart policy to on-failure for Docker lifecycle safety."
        if ! docker update --restart on-failure "$container" >/dev/null; then
            log_error "Could not update ${container} restart policy."
            return 1
        fi
    fi
    return 0
}

'''
if anchor not in t:
    raise SystemExit('runtime normalization insertion anchor missing')
t = t.replace(anchor, helper + anchor, 1)
p.write_text(t)

p = Path('utilities/setup-firewall.sh')
t = p.read_text()
old = '''    _iptables_signal_rollback() {
        local signal_rc="$1"
        _restore_snapshot
        exit "$signal_rc"
    }
'''
new = '''    _iptables_signal_rollback() {
        local signal_rc="$1"
        _restore_snapshot
        firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback could not confirm fail-closed Caddy shutdown."
        exit "$signal_rc"
    }
'''
if old not in t:
    raise SystemExit('iptables signal rollback anchor missing')
t = t.replace(old, new, 1)

anchor = 'main() {\n'
signal_helper = r'''_setup_firewall_signal_fail_closed() {
    local signal_rc="$1"
    firewall_fail_closed_stop_caddy || log_error "CRITICAL: interrupted firewall setup could not confirm fail-closed Caddy shutdown."
    operation_release "$signal_rc"
    exit "$signal_rc"
}

'''
if anchor not in t:
    raise SystemExit('main insertion anchor missing')
t = t.replace(anchor, signal_helper + anchor, 1)

t = t.replace(
    "        trap 'operation_release 130; exit 130' INT\n        trap 'operation_release 143; exit 143' HUP TERM\n",
    "        trap '_setup_firewall_signal_fail_closed 130' INT\n        trap '_setup_firewall_signal_fail_closed 143' HUP TERM\n",
    1,
)

old = '''    if (( rc != 0 )) && [[ "$DRY_RUN" != "true" ]]; then
        firewall_fail_closed_stop_caddy || stop_rc=$?
'''
new = '''    if (( rc == 0 )) && [[ "$DRY_RUN" != "true" ]] && [[ "$PHASE" != "ufw" ]]; then
        firewall_normalize_caddy_runtime_contract || rc=$?
    fi

    if (( rc != 0 )) && [[ "$DRY_RUN" != "true" ]]; then
        firewall_fail_closed_stop_caddy || stop_rc=$?
'''
if old not in t:
    raise SystemExit('main fail-closed result anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''assert_file_contains "$FIREWALL_LIB" 'firewall_fail_closed_stop_caddy()'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || stop_rc=$?'
'''
replacement = '''assert_file_contains "$FIREWALL_LIB" 'firewall_fail_closed_stop_caddy()'
assert_file_contains "$FIREWALL_LIB" 'firewall_normalize_caddy_runtime_contract()'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || stop_rc=$?'
assert_file_contains "$SETUP_FIREWALL" 'firewall_normalize_caddy_runtime_contract || rc=$?'
assert_file_contains "$SETUP_FIREWALL" '_setup_firewall_signal_fail_closed 130'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback'
'''
if anchor not in t:
    raise SystemExit('runtime migration static assertion anchor missing')
t = t.replace(anchor, replacement, 1)

# Reuse an isolated docker-function probe for runtime normalization behavior.
anchor = '''# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
probe = r'''RUNTIME_DOCKER="$TMP/runtime-contract-docker"
cat > "$RUNTIME_DOCKER" <<'EOF_RUNTIME_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUNTIME_DOCKER_LOG:?}"
case "${1:-}" in
    ps)
        printf 'vaultwarden_caddy\n'
        exit 0
        ;;
    inspect)
        if [[ "$*" == *'RestartPolicy.Name'* ]]; then
            printf '%s\n' "${RUNTIME_POLICY:-unless-stopped}"
        elif [[ "$*" == *'PortBindings'* ]]; then
            printf '%s\n' "${RUNTIME_BINDINGS:?}"
        else
            exit 2
        fi
        exit 0
        ;;
    update|stop|rm)
        exit 0
        ;;
esac
exit 2
EOF_RUNTIME_DOCKER
chmod 0755 "$RUNTIME_DOCKER"
RUNTIME_PROBE="$TMP/runtime-contract-probe.bash"
cat > "$RUNTIME_PROBE" <<'EOF_RUNTIME_PROBE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
log_info(){ printf 'INFO: %s\n' "$*" >> "${RUNTIME_LOG:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >> "${RUNTIME_LOG:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${RUNTIME_LOG:?}"; }
docker(){ "${RUNTIME_DOCKER:?}" "$@"; }
EOF_RUNTIME_PROBE
extract_func "$FIREWALL_LIB" firewall_normalize_caddy_runtime_contract >> "$RUNTIME_PROBE"
cat >> "$RUNTIME_PROBE" <<'EOF_RUNTIME_PROBE'
firewall_normalize_caddy_runtime_contract
EOF_RUNTIME_PROBE
chmod 0755 "$RUNTIME_PROBE"
RUNTIME_DOCKER_LOG="$TMP/runtime-contract-docker.log"
RUNTIME_LOG="$TMP/runtime-contract.log"
export RUNTIME_DOCKER RUNTIME_DOCKER_LOG RUNTIME_LOG

: > "$RUNTIME_DOCKER_LOG"; : > "$RUNTIME_LOG"
export RUNTIME_BINDINGS='{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"80"}],"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"443"}]}'
export RUNTIME_POLICY=unless-stopped
"$BASH" "$RUNTIME_PROBE"
assert_file_contains "$RUNTIME_DOCKER_LOG" 'update --restart on-failure vaultwarden_caddy'
! grep -Fq 'rm -f vaultwarden_caddy' "$RUNTIME_DOCKER_LOG" || fail "safe IPv4 Caddy binding was unnecessarily removed"

: > "$RUNTIME_DOCKER_LOG"; : > "$RUNTIME_LOG"
export RUNTIME_BINDINGS='{"80/tcp":[{"HostIp":"","HostPort":"80"}],"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"443"}]}'
export RUNTIME_POLICY=unless-stopped
"$BASH" "$RUNTIME_PROBE"
assert_file_contains "$RUNTIME_DOCKER_LOG" 'stop --time 30 vaultwarden_caddy'
assert_file_contains "$RUNTIME_DOCKER_LOG" 'rm -f vaultwarden_caddy'
assert_file_contains "$RUNTIME_LOG" 'legacy/non-IPv4-only published web bindings'
unset RUNTIME_BINDINGS RUNTIME_POLICY

# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
if anchor not in t:
    raise SystemExit('runtime migration behavior probe anchor missing')
t = t.replace(anchor, probe, 1)
p.write_text(t)
