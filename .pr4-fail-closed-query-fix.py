from pathlib import Path

p = Path('lib/firewall.sh')
t = p.read_text()
old = '''    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        # Missing container is safe; an unqueryable Docker daemon is not.
        if docker container inspect "$container" >/dev/null 2>&1; then
            log_error "CRITICAL: firewall reconciliation failed and ${container} running state could not be determined."
            return 1
        fi
        return 0
    fi
'''
new = '''    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        local listed=""
        if ! listed="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>/dev/null)"; then
            log_error "CRITICAL: firewall reconciliation failed and Docker could not confirm whether ${container} exists."
            return 1
        fi
        [[ "$listed" != "$container" ]] && return 0
        log_error "CRITICAL: firewall reconciliation failed and ${container} running state could not be determined."
        return 1
    fi
'''
if old not in t:
    raise SystemExit('fail-closed Docker query anchor missing')
p.write_text(t.replace(old, new, 1))

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
old = '''case "${1:-}" in
    inspect)
        printf 'true\\n'
        exit 0
        ;;
    stop)
        exit "${FAIL_CLOSED_STOP_RC:-0}"
        ;;
    container)
        exit 0
        ;;
esac
'''
new = '''case "${1:-}" in
    inspect)
        if (( ${FAIL_CLOSED_INSPECT_RC:-0} != 0 )); then exit "$FAIL_CLOSED_INSPECT_RC"; fi
        printf '%s\\n' "${FAIL_CLOSED_RUNNING:-true}"
        exit 0
        ;;
    ps)
        if (( ${FAIL_CLOSED_PS_RC:-0} != 0 )); then exit "$FAIL_CLOSED_PS_RC"; fi
        [[ "${FAIL_CLOSED_EXISTS:-true}" == "true" ]] && printf 'vaultwarden_caddy\\n'
        exit 0
        ;;
    stop)
        exit "${FAIL_CLOSED_STOP_RC:-0}"
        ;;
esac
'''
if old not in t:
    raise SystemExit('fail-closed Docker mock anchor missing')
t = t.replace(old, new, 1)

anchor = '''assert_file_contains "$FAIL_CLOSED_LOG" 'Firewall reconciliation failed; stopping vaultwarden_caddy'

# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
extra = '''assert_file_contains "$FAIL_CLOSED_LOG" 'Firewall reconciliation failed; stopping vaultwarden_caddy'

: > "$FAIL_CLOSED_DOCKER_LOG"; : > "$FAIL_CLOSED_LOG"
export FAIL_CLOSED_INSPECT_RC=1 FAIL_CLOSED_PS_RC=1
set +e
"$BASH" "$FAIL_CLOSED_PROBE"
FAIL_CLOSED_RC=$?
set -e
[[ "$FAIL_CLOSED_RC" -ne 0 ]] || fail "unqueryable Docker daemon was mistaken for an absent Caddy container"
assert_file_contains "$FAIL_CLOSED_LOG" 'Docker could not confirm whether vaultwarden_caddy exists'
unset FAIL_CLOSED_INSPECT_RC FAIL_CLOSED_PS_RC

: > "$FAIL_CLOSED_DOCKER_LOG"; : > "$FAIL_CLOSED_LOG"
export FAIL_CLOSED_INSPECT_RC=1 FAIL_CLOSED_EXISTS=false
"$BASH" "$FAIL_CLOSED_PROBE"
! grep -Fq 'stop --time' "$FAIL_CLOSED_DOCKER_LOG" || fail "missing Caddy container triggered an unnecessary stop"
unset FAIL_CLOSED_INSPECT_RC FAIL_CLOSED_EXISTS

# Behavioral backend detection: active dockerd argv/config wins over stale chain existence.
'''
if anchor not in t:
    raise SystemExit('fail-closed query test insertion anchor missing')
t = t.replace(anchor, extra, 1)
p.write_text(t)
