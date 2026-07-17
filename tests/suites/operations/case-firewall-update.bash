#!/usr/bin/env bash
# Behavioral regressions for Cloudflare UFW reconciliation and its systemd sandbox.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
UPDATER="$ROOT/utilities/maintenance-update-firewall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file="$1" expected="$2"
    grep -Fq -- "$expected" "$file" || fail "$(basename "$file") lacks: $expected"
}

assert_no_call() {
    local expected="$1"
    ! grep -Fq -- "$expected" "$UFW_CALL_LOG" || fail "unexpected UFW call: $expected"
}

assert_call() {
    local expected="$1"
    grep -Fq -- "$expected" "$UFW_CALL_LOG" || fail "missing UFW call: $expected"
}

extract_func() {
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
            print
            opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
            depth += opens - closes
            if (depth == 0) exit
        }' "$file"
}

mkdir -p "$TMP/bin"

cat > "$TMP/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while (( $# > 0 )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$out" && -n "$url" ]] || exit 2
case "$url" in
    *ips-v4) cat "${CF_IPV4_FILE:?}" > "$out" ;;
    *ips-v6) cat "${CF_IPV6_FILE:?}" > "$out" ;;
    *) exit 2 ;;
esac
EOF_CURL

cat > "$TMP/bin/ufw" <<'EOF_UFW'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${UFW_CALL_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
    if (( ${UFW_NUMBERED_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_NUMBERED_OUTPUT:-numbered status failed}" >&2
        exit "$UFW_NUMBERED_RC"
    fi
    cat "${UFW_NUMBERED_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && $# -eq 1 ]]; then
    if (( ${UFW_STATUS_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_STATUS_OUTPUT:-status failed}" >&2
        exit "$UFW_STATUS_RC"
    fi
    cat "${UFW_STATUS_FILE:?}"
    exit 0
fi

command_line=" $* "
if [[ "$command_line" == *" allow "* && "$command_line" == *" port 80 "* ]]; then
    if (( ${UFW_ALLOW80_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ALLOW80_OUTPUT:-port 80 failed}" >&2
        exit "$UFW_ALLOW80_RC"
    fi
    printf 'Rule added\n'
    exit 0
fi

if [[ "$command_line" == *" allow "* && "$command_line" == *" port 443 "* ]]; then
    if (( ${UFW_ALLOW443_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ALLOW443_OUTPUT:-port 443 failed}" >&2
        exit "$UFW_ALLOW443_RC"
    fi
    printf 'Rule added\n'
    exit 0
fi

if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
    rule="${3:-}"
    if [[ -n "${UFW_DELETE_FAIL_RULE:-}" && "$rule" == "$UFW_DELETE_FAIL_RULE" ]]; then
        printf '%s\n' "${UFW_DELETE_OUTPUT:-delete failed}" >&2
        exit "${UFW_DELETE_RC:-1}"
    fi
    printf 'Rule deleted\n'
    exit 0
fi

printf 'unexpected ufw invocation: %s\n' "$*" >&2
exit 2
EOF_UFW
chmod 0755 "$TMP/bin/curl" "$TMP/bin/ufw"

PROBE="$TMP/firewall-probe.bash"
cat > "$PROBE" <<'EOF_PROBE'
#!/usr/bin/env bash
set -euo pipefail
UPDATE_FIREWALL=true
DRY_RUN=false
CLOUDFLARE_PROXY_ENABLED=true
require_root(){ :; }
register_cleanup(){ :; }
retry_with_backoff(){ shift 2; "$@"; }
log_info(){ printf 'INFO: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_success(){ printf 'SUCCESS: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_debug(){ printf 'DEBUG: %s\n' "$*" >> "${LOG_FILE:?}"; }
EOF_PROBE
extract_func "$UPDATER" update_firewall_ranges >> "$PROBE"
cat >> "$PROBE" <<'EOF_PROBE'
set +e
update_firewall_ranges
rc=$?
set -e
exit "$rc"
EOF_PROBE
chmod 0755 "$PROBE"

reset_case() {
    local name="$1"
    CASE_DIR="$TMP/$name"
    mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/state"
    CF_IPV4_FILE="$CASE_DIR/ips-v4"
    CF_IPV6_FILE="$CASE_DIR/ips-v6"
    UFW_STATUS_FILE="$CASE_DIR/status"
    UFW_NUMBERED_FILE="$CASE_DIR/status-numbered"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
    LOG_FILE="$CASE_DIR/log"
    CASE_OUTPUT="$CASE_DIR/output"

    printf '203.0.113.0/24\n' > "$CF_IPV4_FILE"
    : > "$CF_IPV6_FILE"
    : > "$UFW_STATUS_FILE"
    : > "$UFW_NUMBERED_FILE"
    : > "$UFW_CALL_LOG"
    : > "$LOG_FILE"

    unset UFW_STATUS_RC UFW_STATUS_OUTPUT UFW_NUMBERED_RC UFW_NUMBERED_OUTPUT
    unset UFW_ALLOW80_RC UFW_ALLOW80_OUTPUT UFW_ALLOW443_RC UFW_ALLOW443_OUTPUT
    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_CALL_LOG LOG_FILE
}

run_case() {
    set +e
    PATH="$TMP/bin:$PATH" \
    TMPDIR="$CASE_DIR/tmp" \
    PROJECT_STATE_DIR="$CASE_DIR/state" \
    "$BASH" "$PROBE" > "$CASE_OUTPUT" 2>&1
    CASE_RC=$?
    set -e
}

write_ipv4_status() {
    local has_80="$1" has_443="$2"
    : > "$UFW_STATUS_FILE"
    if [[ "$has_80" == true ]]; then
        printf '80/tcp ALLOW IN 203.0.113.0/24\n' >> "$UFW_STATUS_FILE"
    fi
    if [[ "$has_443" == true ]]; then
        printf '443/tcp ALLOW IN 203.0.113.0/24\n' >> "$UFW_STATUS_FILE"
    fi
}

reset_case status-failure
export UFW_STATUS_RC=41 UFW_STATUS_OUTPUT='cannot open /run/ufw.lock: read-only file system'
run_case
[[ "$CASE_RC" -eq 41 ]] || fail "ufw status failure returned $CASE_RC instead of 41"
assert_file_contains "$LOG_FILE" 'cannot open /run/ufw.lock: read-only file system'

reset_case only-port-80
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
assert_no_call 'port 80 comment'
assert_call 'port 443 comment CF-IPv4'

reset_case only-port-443
write_ipv4_status false true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call 'port 443 comment'

reset_case both-ports
write_ipv4_status true true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing port rules failed with $CASE_RC"
assert_no_call ' allow '

reset_case port-80-failure
export UFW_ALLOW80_RC=42 UFW_ALLOW80_OUTPUT='simulated port 80 failure'
run_case
[[ "$CASE_RC" -eq 42 ]] || fail "port 80 failure returned $CASE_RC instead of 42"
assert_file_contains "$LOG_FILE" 'simulated port 80 failure'
assert_no_call 'port 443 comment'

reset_case port-443-failure
write_ipv4_status true false
export UFW_ALLOW443_RC=43 UFW_ALLOW443_OUTPUT='simulated port 443 failure'
run_case
[[ "$CASE_RC" -eq 43 ]] || fail "port 443 failure returned $CASE_RC instead of 43"
assert_file_contains "$LOG_FILE" 'simulated port 443 failure'

reset_case numbered-status-failure
write_ipv4_status true true
export UFW_NUMBERED_RC=44 UFW_NUMBERED_OUTPUT='cannot enumerate UFW rules'
run_case
[[ "$CASE_RC" -eq 44 ]] || fail "numbered status failure returned $CASE_RC instead of 44"
assert_file_contains "$LOG_FILE" 'cannot enumerate UFW rules'

reset_case delete-failure
write_ipv4_status true true
printf '[12] 80/tcp ALLOW IN 198.51.100.0/24 # CF-IPv4\n' > "$UFW_NUMBERED_FILE"
export UFW_DELETE_FAIL_RULE=12 UFW_DELETE_RC=45 UFW_DELETE_OUTPUT='simulated delete failure'
run_case
[[ "$CASE_RC" -eq 45 ]] || fail "delete failure returned $CASE_RC instead of 45"
assert_file_contains "$LOG_FILE" 'Failed to delete UFW rule 12'
assert_file_contains "$LOG_FILE" 'simulated delete failure'

reset_case descending-delete
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 2] 80/tcp ALLOW IN 198.51.100.2/32 # CF-IPv4
[10] 80/tcp ALLOW IN 198.51.100.10/32 # CF-IPv4
[ 7] 80/tcp ALLOW IN 198.51.100.7/32 # CF-IPv4
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "descending deletion failed with $CASE_RC"
delete_order="$(grep '^--force delete ' "$UFW_CALL_LOG" || true)"
expected_order=$'--force delete 10\n--force delete 7\n--force delete 2'
[[ "$delete_order" == "$expected_order" ]] || fail "obsolete rules deleted in wrong order: $delete_order"

reset_case partial-retry
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "first partial convergence failed with $CASE_RC"
write_ipv4_status true true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "partial convergence retry failed with $CASE_RC"
[[ "$(grep -Fc 'port 443 comment CF-IPv4' "$UFW_CALL_LOG")" -eq 1 ]] \
    || fail "partial retry did not add port 443 exactly once"
assert_no_call 'port 80 comment'

reset_case ipv6-existing
: > "$CF_IPV4_FILE"
printf '2001:db8::/32\n' > "$CF_IPV6_FILE"
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp (v6) ALLOW IN 2001:db8::/32
443/tcp (v6) ALLOW IN 2001:db8::/32
EOF_STATUS
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing IPv6 rules failed with $CASE_RC"
assert_no_call ' allow '

health_unit="$ROOT/systemd/vaultwarden-health.service"
maintenance_unit="$ROOT/systemd/vaultwarden-maintenance.service"
firewall_unit="$ROOT/systemd/vaultwarden-firewall-update.service"

for unit in "$health_unit" "$maintenance_unit" "$firewall_unit"; do
    assert_file_contains "$unit" 'ProtectSystem=strict'
    assert_file_contains "$unit" 'NoNewPrivileges=yes'
    assert_file_contains "$unit" 'PrivateTmp=yes'
    while IFS= read -r directive; do
        read -ra paths <<< "${directive#ReadWritePaths=}"
        for path in "${paths[@]}"; do
            path="${path#-}"
            case "$path" in
                /run|/etc|/var) fail "$(basename "$unit") grants broad write access to $path" ;;
            esac
        done
    done < <(grep '^ReadWritePaths=' "$unit")
done

for unit in "$health_unit" "$maintenance_unit"; do
    assert_file_contains "$unit" 'ReadWritePaths=-/var/lib/crowdsec'
    ! grep -Fxq 'ReadWritePaths=/var/lib/crowdsec' "$unit" \
        || fail "$(basename "$unit") uses an unconditional CrowdSec write path"
done

for unit in "$maintenance_unit" "$firewall_unit"; do
    assert_file_contains "$unit" 'ReadWritePaths=/etc/ufw /run/ufw.lock /run/xtables.lock'
    assert_file_contains "$unit" 'ExecStartPre=+/usr/bin/touch /run/ufw.lock /run/xtables.lock'
    assert_file_contains "$unit" 'ExecStartPre=+/usr/bin/chown root:root /run/ufw.lock /run/xtables.lock'
    assert_file_contains "$unit" 'ExecStartPre=+/usr/bin/chmod 0600 /run/ufw.lock /run/xtables.lock'
done

if command -v systemd-analyze >/dev/null 2>&1; then
    unit_dir="$TMP/systemd-units"
    mkdir -p "$unit_dir"
    cp "$health_unit" "$maintenance_unit" "$firewall_unit" "$unit_dir/"
    sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/true|' "$unit_dir"/*.service
    cat > "$unit_dir/docker.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    cat > "$unit_dir/vaultwarden-notify-failure@.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    verify_output="$TMP/systemd-analyze.out"
    if ! SYSTEMD_UNIT_PATH="$unit_dir:" systemd-analyze verify \
        vaultwarden-health.service \
        vaultwarden-maintenance.service \
        vaultwarden-firewall-update.service > "$verify_output" 2>&1; then
        cat "$verify_output" >&2
        fail "systemd-analyze rejected the modified units"
    fi
else
    printf 'SKIP: systemd-analyze unavailable; static systemd path assertions passed\n'
fi

printf 'PASS: firewall updater behavior and systemd sandbox contracts\n'
