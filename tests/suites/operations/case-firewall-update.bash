#!/usr/bin/env bash
# Behavioral regressions for Cloudflare UFW reconciliation and its systemd sandbox.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
UPDATER="$ROOT/utilities/maintenance-update-firewall.sh"
SETUP_FIREWALL="$ROOT/utilities/setup-firewall.sh"
FIREWALL_LIB="$ROOT/lib/firewall.sh"
SYSTEMD_SETUP="$ROOT/utilities/setup-systemd.sh"
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

cat > "$TMP/bin/sshd" <<'EOF_SSHD_UPDATER'
#!/usr/bin/env bash
if [[ "${1:-}" == "-T" ]]; then
    printf 'port %s\n' "${SSHD_PORT:-22}"
    exit 0
fi
exit 2
EOF_SSHD_UPDATER
chmod 0755 "$TMP/bin/sshd"

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
    *ips-v4) [[ "${CURL_FAIL_V4:-false}" == "true" ]] && exit 22; cat "${CF_IPV4_FILE:?}" > "$out" ;;
    *ips-v6) [[ "${CURL_FAIL_V6:-false}" == "true" ]] && exit 22; cat "${CF_IPV6_FILE:?}" > "$out" ;;
    *) exit 2 ;;
esac
EOF_CURL

cat > "$TMP/bin/ufw" <<'EOF_UFW'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${UFW_CALL_LOG:?}"

if [[ "${1:-}" == "reload" ]]; then
    printf 'ufw-reload\n' >> "${TXN_CALL_LOG:?}"
    exit "${UFW_RELOAD_RC:-0}"
fi

if [[ "${1:-}" == "show" && "${2:-}" == "added" ]]; then
    if (( ${UFW_ADDED_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ADDED_OUTPUT:-show added failed}" >&2
        exit "$UFW_ADDED_RC"
    fi
    cat "${UFW_ADDED_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
    if (( ${UFW_NUMBERED_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_NUMBERED_OUTPUT:-numbered status failed}" >&2
        exit "$UFW_NUMBERED_RC"
    fi
    cat "${UFW_NUMBERED_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && "${2:-}" == "verbose" ]]; then
    if (( ${UFW_VERBOSE_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_VERBOSE_OUTPUT:-verbose status failed}" >&2
        exit "$UFW_VERBOSE_RC"
    fi
    cat "${UFW_VERBOSE_FILE:?}"
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
    if [[ "${UFW_NO_MUTATE:-false}" != "true" ]]; then
        range=""
        while (( $# > 0 )); do
            if [[ "$1" == "from" ]]; then range="$2"; break; fi
            shift
        done
        if [[ "$range" == *:* ]]; then
            printf '80/tcp (v6) ALLOW IN %s\n' "$range" >> "$UFW_STATUS_FILE"
        else
            printf '80/tcp ALLOW IN %s\n' "$range" >> "$UFW_STATUS_FILE"
        fi
    fi
    printf 'mutation\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'ufw-mutation\n' >> "${TXN_CALL_LOG:?}"
    printf 'Rule added\n'
    exit 0
fi

if [[ "$command_line" == *" allow "* && "$command_line" == *" port 443 "* ]]; then
    if (( ${UFW_ALLOW443_RC:-0} != 0 )); then
        printf '%s\n' "${UFW_ALLOW443_OUTPUT:-port 443 failed}" >&2
        exit "$UFW_ALLOW443_RC"
    fi
    if [[ "${UFW_NO_MUTATE:-false}" != "true" ]]; then
        range=""
        while (( $# > 0 )); do
            if [[ "$1" == "from" ]]; then range="$2"; break; fi
            shift
        done
        if [[ "$range" == *:* ]]; then
            printf '443/tcp (v6) ALLOW IN %s\n' "$range" >> "$UFW_STATUS_FILE"
        else
            printf '443/tcp ALLOW IN %s\n' "$range" >> "$UFW_STATUS_FILE"
        fi
    fi
    printf 'mutation\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'ufw-mutation\n' >> "${TXN_CALL_LOG:?}"
    printf 'Rule added\n'
    exit 0
fi

if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
    rule="${3:-}"
    if [[ -n "${UFW_DELETE_FAIL_RULE:-}" && "$rule" == "$UFW_DELETE_FAIL_RULE" ]]; then
        printf '%s\n' "${UFW_DELETE_OUTPUT:-delete failed}" >&2
        exit "${UFW_DELETE_RC:-1}"
    fi
    if [[ "${UFW_NO_MUTATE:-false}" != "true" ]]; then
        awk -v n="$rule" '
            $0 ~ "^\\[[[:space:]]*" n "\\]" {next}
            {print}
        ' "$UFW_NUMBERED_FILE" > "${UFW_NUMBERED_FILE}.tmp"
        mv "${UFW_NUMBERED_FILE}.tmp" "$UFW_NUMBERED_FILE"
    fi
    printf 'mutation\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'ufw-mutation\n' >> "${TXN_CALL_LOG:?}"
    printf 'Rule deleted\n'
    exit 0
fi

printf 'unexpected ufw invocation: %s\n' "$*" >&2
exit 2
EOF_UFW
chmod 0755 "$TMP/bin/curl" "$TMP/bin/ufw"
cat > "$TMP/bin/iptables-save" <<'EOF_UPDATER_IPTABLES_SAVE'
#!/usr/bin/env bash
set -euo pipefail
printf 'save\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-save\n' >> "${TXN_CALL_LOG:?}"
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
printf '*filter\nCOMMIT\n'
EOF_UPDATER_IPTABLES_SAVE
cat > "$TMP/bin/iptables-restore" <<'EOF_UPDATER_IPTABLES_RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-restore\n' >> "${TXN_CALL_LOG:?}"
cat >/dev/null
exit "${IPT_RESTORE_RC:-0}"
EOF_UPDATER_IPTABLES_RESTORE
chmod 0755 "$TMP/bin/iptables-save" "$TMP/bin/iptables-restore"

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
operation_release(){ :; }
perform_cleanup(){ :; }
firewall_docker_backend_preflight(){ printf 'preflight\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }
firewall_load_cached_cloudflare_ipv4(){
    local out_name="$1" cache_file="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache" line
    local -n out_ref="$out_name"
    out_ref=()
    [[ -s "$cache_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && out_ref+=("$line")
    done < "$cache_file"
    (( ${#out_ref[@]} > 0 ))
}
firewall_docker_ingress_is_exact(){
    printf 'exact %s\n' "$*" >> "${FW_CALL_LOG:?}"
    if [[ -n "${FW_EXACT_SAFE_CIDR:-}" && "$*" == "$FW_EXACT_SAFE_CIDR" ]]; then
        return 0
    fi
    return "${FW_EXACT_RC:-0}"
}
firewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }
firewall_fail_closed_stop_caddy(){ printf 'stop-caddy\n' >> "${FW_CALL_LOG:?}"; return "${FW_STOP_CADDY_RC:-0}"; }
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
    UFW_VERBOSE_FILE="$CASE_DIR/status-verbose"
    UFW_DEFAULTS_FILE="$CASE_DIR/ufw-defaults"
    UFW_ADDED_FILE="$CASE_DIR/ufw-added"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
    FW_CALL_LOG="$CASE_DIR/firewall-calls"
    IPT_CALL_LOG="$CASE_DIR/ipt-calls"
    TXN_CALL_LOG="$CASE_DIR/transaction-calls"
    LOG_FILE="$CASE_DIR/log"
    CASE_OUTPUT="$CASE_DIR/output"
    UFW_CONFIG_DIR="$CASE_DIR/ufw-config"
    mkdir -p "$UFW_CONFIG_DIR"

    printf '203.0.113.0/24\n' > "$CF_IPV4_FILE"
    : > "$CF_IPV6_FILE"
    : > "$UFW_STATUS_FILE"
    : > "$UFW_NUMBERED_FILE"
    printf 'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n' > "$UFW_VERBOSE_FILE"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "$UFW_DEFAULTS_FILE"
    : > "$UFW_ADDED_FILE"
    printf 'baseline-v4\n' > "$UFW_CONFIG_DIR/user.rules"
    printf 'baseline-v6\n' > "$UFW_CONFIG_DIR/user6.rules"
    : > "$UFW_CALL_LOG"
    : > "$FW_CALL_LOG"
    : > "$IPT_CALL_LOG"
    : > "$TXN_CALL_LOG"
    : > "$LOG_FILE"

    unset UFW_STATUS_RC UFW_STATUS_OUTPUT UFW_NUMBERED_RC UFW_NUMBERED_OUTPUT
    unset UFW_VERBOSE_RC UFW_VERBOSE_OUTPUT UFW_ADDED_RC UFW_ADDED_OUTPUT
    unset UFW_ALLOW80_RC UFW_ALLOW80_OUTPUT UFW_ALLOW443_RC UFW_ALLOW443_OUTPUT
    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT UFW_NO_MUTATE UFW_RELOAD_RC
    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_EXACT_SAFE_CIDR FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT
    unset CURL_FAIL_V4 CURL_FAIL_V6
    unset IPT_SAVE_RC IPT_RESTORE_RC

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_ADDED_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG IPT_CALL_LOG TXN_CALL_LOG LOG_FILE
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


reset_case updater-ssh-port-80-collision
export SSHD_PORT=80
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted SSH on port 80"
assert_file_contains "$LOG_FILE" 'SSH port 80/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "periodic updater mutated UFW before rejecting SSH port 80"
[[ ! -s "$FW_CALL_LOG" ]] || fail "periodic updater touched Docker firewall before rejecting SSH port 80"

reset_case updater-ssh-port-443-collision
export SSHD_PORT=443
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted SSH on port 443"
assert_file_contains "$LOG_FILE" 'SSH port 443/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "periodic updater mutated UFW before rejecting SSH port 443"
[[ ! -s "$FW_CALL_LOG" ]] || fail "periodic updater touched Docker firewall before rejecting SSH port 443"

reset_case docker-preflight-failure
export FW_PREFLIGHT_RC=60
run_case
[[ "$CASE_RC" -eq 60 ]] || fail "Docker preflight failure returned $CASE_RC instead of 60"
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
assert_no_call ' allow '
assert_no_call '--force delete'

reset_case unsafe-prior-gate-fetch-failure
export CURL_FAIL_V4=true
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "Cloudflare fetch failure with unproven prior gate returned success"
assert_file_contains "$LOG_FILE" 'Failed to fetch Cloudflare IP ranges'
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
assert_no_call ' allow '

reset_case safe-prior-gate-fetch-failure
printf '198.51.100.0/24\n' > "$CASE_DIR/state/cf-cidrs.cache"
export FW_EXACT_SAFE_CIDR=198.51.100.0/24 CURL_FAIL_V4=true
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "safe-prior Cloudflare fetch failure returned success"
assert_file_contains "$FW_CALL_LOG" 'exact 198.51.100.0/24'
! grep -Fq 'stop-caddy' "$FW_CALL_LOG" || fail "proven-safe prior gate was stopped on fetch failure"
assert_no_call ' allow '

reset_case updater-inactive-ufw
write_ipv4_status true true
printf 'Status: inactive\n' > "$UFW_VERBOSE_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "periodic updater accepted inactive UFW"
assert_file_contains "$LOG_FILE" 'UFW is inactive; refusing periodic firewall mutation'
assert_no_call ' allow '
assert_no_call '--force delete'
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
! grep -Fq 'reconcile ' "$FW_CALL_LOG" || fail "inactive UFW caused Docker firewall reconciliation"

reset_case default-incoming-allow
write_ipv4_status true true
printf 'Status: active\nDefault: allow (incoming), allow (outgoing), disabled (routed)\n' > "$UFW_VERBOSE_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "UFW default allow incoming was accepted"
assert_file_contains "$LOG_FILE" 'default incoming policy is not provably fail-closed'
assert_no_call ' allow '
assert_no_call '--force delete'

reset_case unsafe-prior-gate-pretransaction-failure
write_ipv4_status true true
printf 'Status: active\nDefault: allow (incoming), allow (outgoing), disabled (routed)\n' > "$UFW_VERBOSE_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "unsafe prior gate survived a pre-transaction UFW failure"
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'

reset_case ambiguous-application-profile
write_ipv4_status true true
printf '[ 1] Nginx Full ALLOW IN Anywhere\n' > "$UFW_NUMBERED_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "ambiguous UFW application profile was accepted"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 1'
assert_no_call ' allow '
assert_no_call '--force delete'

reset_case ambiguous-port-range
write_ipv4_status true true
printf '[ 2] 80:90/tcp ALLOW IN Anywhere\n' > "$UFW_NUMBERED_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "ambiguous UFW port range was accepted"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 2'
assert_no_call ' allow '
assert_no_call '--force delete'

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
save_line="$(grep -n '^iptables-save$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
ufw_mutation_line="$(grep -n '^ufw-mutation$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$save_line" && -n "$ufw_mutation_line" && "$save_line" -lt "$ufw_mutation_line" ]] \
    || fail "full iptables rollback snapshot was not captured before first UFW mutation"

reset_case updater-pre-mutation-snapshot-failure
export IPT_SAVE_RC=47
run_case
[[ "$CASE_RC" -eq 47 ]] || fail "pre-mutation iptables snapshot failure returned $CASE_RC instead of 47"
assert_file_contains "$LOG_FILE" 'Could not snapshot pre-update iptables state'
assert_no_call ' allow '
assert_no_call '--force delete'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]] \
    || fail "snapshot failure changed UFW managed rules"

reset_case only-port-443
write_ipv4_status false true
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call 'port 443 comment'

reset_case implicit-inbound-status
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 9] 80/tcp ALLOW 203.0.113.0/24
[10] 443/tcp ALLOW 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "implicit inbound UFW status failed convergence with $CASE_RC"
assert_no_call 'port 80 comment'
assert_no_call 'port 443 comment'
assert_no_call '--force delete 9'
assert_no_call '--force delete 10'

reset_case outbound-web-not-ingress
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW OUT 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 9] 80/tcp ALLOW OUT 203.0.113.0/24
[10] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "outbound-only web rule convergence failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_no_call '--force delete 9'

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
assert_call 'reload'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]]     || fail "UFW delete failure left managed rules partially updated"

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

reset_case public-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80/tcp ALLOW IN Anywhere
[ 5] 443/tcp ALLOW IN Anywhere
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "public ingress conflict reconciliation failed with $CASE_RC"
assert_call '--force delete 5'
assert_call '--force delete 4'

reset_case public-ingress-comment-cannot-spoof-direction
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "commented public ingress conflict reconciliation failed with $CASE_RC"
assert_call '--force delete 4'

reset_case comment-cidr-false-positive
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW IN Anywhere # 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80/tcp ALLOW IN Anywhere # 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "comment-CIDR conflict reconciliation failed with $CASE_RC"
assert_call 'port 80 comment CF-IPv4'
assert_call '--force delete 4'

reset_case restricted-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80/tcp ALLOW IN 198.51.100.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "restricted non-Cloudflare ingress reconciliation failed with $CASE_RC"
assert_call '--force delete 4'

reset_case non-tcp-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80 ALLOW IN 203.0.113.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "ambiguous non-TCP ingress rule was auto-mutated instead of failing closed"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
assert_no_call '--force delete'

reset_case ambiguous-profile-comment-cannot-spoof-direction
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "comment text hid ambiguous inbound UFW application rule"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'
assert_no_call '--force delete'

reset_case restricted-final-verification
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 443/tcp ALLOW IN 198.51.100.0/24
EOF_RULES
export UFW_NO_MUTATE=true
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "final verification accepted restricted non-Cloudflare ingress"
assert_file_contains "$LOG_FILE" 'Non-Cloudflare UFW 80/443 rule remains'

reset_case final-verification
export UFW_NO_MUTATE=true
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "final verification accepted UFW mutations that did not take effect"
assert_file_contains "$LOG_FILE" 'Final UFW verification missing'

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
printf '203.0.113.0/24\n' > "$CF_IPV4_FILE"
printf '2001:db8::/32\n' > "$CF_IPV6_FILE"
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
80/tcp (v6) ALLOW IN 2001:db8::/32
443/tcp (v6) ALLOW IN 2001:db8::/32
EOF_STATUS
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "existing IPv4+IPv6 rules failed with $CASE_RC"
assert_no_call ' allow '

# Pre-transaction signals must fail closed when the prior gate is unproven,
# but preserve a previously proven-safe generation.
PRETX_SIGNAL_PROBE="$TMP/updater-pretransaction-signal-probe.bash"
cat > "$PRETX_SIGNAL_PROBE" <<'EOF_PRETX_SIGNAL'
#!/usr/bin/env bash
set -euo pipefail
pre_update_docker_gate_exact="${PRETX_GATE_EXACT:-false}"
firewall_fail_closed_stop_caddy(){ printf 'stop-caddy\n' >> "${PRETX_SIGNAL_LOG:?}"; return "${PRETX_STOP_RC:-0}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${PRETX_SIGNAL_LOG:?}"; }
operation_release(){ printf 'release %s\n' "$1" >> "${PRETX_SIGNAL_LOG:?}"; }
perform_cleanup(){ printf 'cleanup\n' >> "${PRETX_SIGNAL_LOG:?}"; }
EOF_PRETX_SIGNAL
awk '
    /^[[:space:]]*_update_firewall_pretransaction_signal\(\)[[:space:]]*\{/ {p=1}
    p {
        print
        opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
        depth += opens - closes
        if (depth == 0) exit
    }' "$UPDATER" >> "$PRETX_SIGNAL_PROBE"
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

# Initial setup cache publication must fail explicitly and preserve the old
# cache generation when a pre-rename step fails. This protects --phase all
# from feeding stale CIDRs into the Docker gate after UFW changed.
CACHE_PUBLISH_PROBE="$TMP/setup-cache-publish-probe.bash"
cat > "$CACHE_PUBLISH_PROBE" <<'EOF_CACHE_PUBLISH'
#!/usr/bin/env bash
set -euo pipefail
log_error(){ printf 'ERROR: %s\n' "$*" >> "${CACHE_PUBLISH_LOG:?}"; }
EOF_CACHE_PUBLISH
extract_func "$SETUP_FIREWALL" _ufw_publish_cidr_cache >> "$CACHE_PUBLISH_PROBE"
cat >> "$CACHE_PUBLISH_PROBE" <<'EOF_CACHE_PUBLISH'
case "${CACHE_PUBLISH_CASE:?}" in
    success)
        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 203.0.113.0/24 2001:db8::/32
        ;;
    chmod-fail)
        chmod(){ return 73; }
        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 198.51.100.0/24
        ;;
    bad-parent)
        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 198.51.100.0/24
        ;;
    *) exit 2 ;;
esac
EOF_CACHE_PUBLISH
chmod 0755 "$CACHE_PUBLISH_PROBE"
CACHE_PUBLISH_LOG="$TMP/cache-publish.log"
CACHE_PUBLISH_DIR="$TMP/cache-publish"
mkdir -p "$CACHE_PUBLISH_DIR"
CACHE_PUBLISH_FILE="$CACHE_PUBLISH_DIR/cf-cidrs.cache"
export CACHE_PUBLISH_LOG CACHE_PUBLISH_FILE
: > "$CACHE_PUBLISH_LOG"
CACHE_PUBLISH_CASE=success "$BASH" "$CACHE_PUBLISH_PROBE"
[[ "$(cat "$CACHE_PUBLISH_FILE")" == $'203.0.113.0/24\n2001:db8::/32' ]] || fail "atomic setup cache publisher wrote the wrong CIDR generation"
[[ "$(stat -c '%a' "$CACHE_PUBLISH_FILE")" == 640 ]] || fail "atomic setup cache publisher used the wrong mode"

printf 'old-generation\n' > "$CACHE_PUBLISH_FILE"
set +e
CACHE_PUBLISH_CASE=chmod-fail "$BASH" "$CACHE_PUBLISH_PROBE"
CACHE_PUBLISH_RC=$?
set -e
[[ "$CACHE_PUBLISH_RC" -ne 0 ]] || fail "setup cache publisher hid chmod failure"
[[ "$(cat "$CACHE_PUBLISH_FILE")" == 'old-generation' ]] || fail "failed setup cache publish replaced the prior generation"
assert_file_contains "$CACHE_PUBLISH_LOG" 'Could not set Cloudflare CIDR cache permissions'

BAD_PARENT="$TMP/cache-parent-file"
printf 'not-a-directory\n' > "$BAD_PARENT"
CACHE_PUBLISH_FILE="$BAD_PARENT/cf-cidrs.cache"
export CACHE_PUBLISH_FILE
set +e
CACHE_PUBLISH_CASE=bad-parent "$BASH" "$CACHE_PUBLISH_PROBE"
CACHE_PUBLISH_RC=$?
set -e
[[ "$CACHE_PUBLISH_RC" -ne 0 ]] || fail "setup cache publisher hid directory creation failure"
assert_file_contains "$CACHE_PUBLISH_LOG" 'Could not create Cloudflare CIDR cache directory'

# Initial setup UFW acceptance checks use the same stateful UFW mock.
SETUP_UFW_PROBE="$TMP/setup-ufw-probe.bash"
cat > "$SETUP_UFW_PROBE" <<'EOF_SETUP_UFW'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
log_error(){ printf 'ERROR: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_dry_run(){ :; }
EOF_SETUP_UFW
extract_func "$SETUP_FIREWALL" _ufw_status >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_has_range_port >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_has_admin_port >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_line_cidr >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_collect_conflicts >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_default_incoming_fail_closed >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_hidden_inactive_permissive_rules >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_ambiguous_inbound_allows >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_validate_safety >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_delete_rules >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_ensure_range >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_verify_exact >> "$SETUP_UFW_PROBE"
cat >> "$SETUP_UFW_PROBE" <<'EOF_SETUP_UFW'
case "${SETUP_UFW_CASE:?}" in
    verify)
        _ufw_verify_exact 22 203.0.113.0/24
        ;;
    ensure)
        _ufw_ensure_range 203.0.113.0/24 CF-IPv4
        ;;
    safety)
        _ufw_validate_safety
        ;;
    *) exit 2 ;;
esac
EOF_SETUP_UFW
chmod 0755 "$SETUP_UFW_PROBE"

reset_case setup-ambiguous-profile-comment-cannot-spoof-direction
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
[ 4] Nginx Full ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=safety "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup comment text hid ambiguous inbound UFW application rule"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'

reset_case setup-inactive-hidden-permissive-rule
printf 'Status: inactive\n' > "$UFW_VERBOSE_FILE"
printf 'Status: inactive\n' > "$UFW_NUMBERED_FILE"
printf 'ufw allow Nginx Full\n' > "$UFW_ADDED_FILE"
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=safety "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "inactive UFW hid a preconfigured permissive application rule"
assert_file_contains "$LOG_FILE" 'Inactive UFW has preconfigured permissive rules'
[[ ! -s "$UFW_CALL_LOG" || "$(cat "$UFW_CALL_LOG")" == $'status verbose\nstatus numbered\nshow added' ]]     || fail "inactive setup safety proof mutated UFW"

reset_case setup-public-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
[ 4] 80/tcp ALLOW IN Anywhere
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted broad public port 80 ingress"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

reset_case setup-public-comment-cannot-spoof-direction
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
[ 4] 80/tcp ALLOW Anywhere # operator note: ALLOW OUT is unrelated
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "comment text hid broad inbound web exposure"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

reset_case setup-comment-cidr-false-positive
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN Anywhere # 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN Anywhere # 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup verifier trusted desired CIDR found only in a UFW comment"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

reset_case setup-restricted-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
[ 4] 443/tcp ALLOW IN 198.51.100.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted restricted non-Cloudflare ingress"
assert_file_contains "$LOG_FILE" 'Conflicting UFW 80/443 rules remain'

reset_case setup-restricted-ssh-final-proof
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN 198.51.100.10/32
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN 198.51.100.10/32
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -eq 0 ]] || fail "setup final verification rejected an existing source-restricted SSH rule"
! grep -Fq 'Broad UFW SSH rule' "$LOG_FILE" || fail "restricted SSH was still treated as invalid administrator access"

reset_case setup-implicit-inbound-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW 198.51.100.10/32
80/tcp ALLOW 203.0.113.0/24
443/tcp ALLOW 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW 198.51.100.10/32
[ 2] 80/tcp ALLOW 203.0.113.0/24
[ 3] 443/tcp ALLOW 203.0.113.0/24
EOF_RULES
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1     || fail "setup rejected normal implicit-inbound UFW status output"

reset_case setup-outbound-ssh-not-admin
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW OUT Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW OUT Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound SSH allow satisfied inbound administrator proof"
assert_file_contains "$LOG_FILE" 'Explicit UFW SSH ALLOW/LIMIT rule for 22/tcp is missing'

reset_case setup-outbound-web-not-ingress
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN 198.51.100.10/32
80/tcp ALLOW OUT 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN 198.51.100.10/32
[ 2] 80/tcp ALLOW OUT 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound port-80 allow satisfied Cloudflare ingress proof"
assert_file_contains "$LOG_FILE" 'Missing Cloudflare UFW rule: 203.0.113.0/24 -> 80/tcp'

reset_case setup-non-tcp-readiness
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
Status: active
22/tcp ALLOW IN Anywhere
80/tcp ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 1] 22/tcp ALLOW IN Anywhere
[ 2] 80/tcp ALLOW IN 203.0.113.0/24
[ 3] 443/tcp ALLOW IN 203.0.113.0/24
[ 4] 443 ALLOW IN 203.0.113.0/24
EOF_RULES
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "initial UFW readiness accepted non-TCP port 443 ingress"
assert_file_contains "$LOG_FILE" 'Ambiguous inbound UFW allow rule 4'

reset_case setup-bare-port-needs-tcp
cat > "$UFW_STATUS_FILE" <<'EOF_STATUS'
80 ALLOW IN 203.0.113.0/24
443/tcp ALLOW IN 203.0.113.0/24
EOF_STATUS
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=ensure "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -eq 0 ]] || fail "initial UFW TCP convergence returned $SETUP_UFW_RC"
assert_call 'port 80 comment CF-IPv4'

reset_case setup-single-cidr-failure
export UFW_ALLOW80_RC=46 UFW_ALLOW80_OUTPUT='simulated initial setup CIDR failure'
set +e
PATH="$TMP/bin:$PATH" SETUP_UFW_CASE=ensure "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -eq 46 ]] || fail "initial UFW CIDR mutation returned $SETUP_UFW_RC instead of 46"
assert_file_contains "$LOG_FILE" 'simulated initial setup CIDR failure'


cat > "$TMP/bin/sshd" <<'EOF_SSHD'
#!/usr/bin/env bash
if [[ "${1:-}" == "-T" ]]; then
    printf 'port %s\n' "${SSHD_PORT:-22}"
    exit 0
fi
exit 2
EOF_SSHD
chmod 0755 "$TMP/bin/sshd"

SETUP_PHASE_PROBE="$TMP/setup-ufw-phase-probe.bash"
cat > "$SETUP_PHASE_PROBE" <<'EOF_SETUP_PHASE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
_VW_DEFAULT_STATE_DIR=/var/lib/vaultwarden
log_info(){ printf 'INFO: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${LOG_FILE:?}"; }
log_dry_run(){ :; }
EOF_SETUP_PHASE
extract_func "$SETUP_FIREWALL" _phase_ufw >> "$SETUP_PHASE_PROBE"
cat >> "$SETUP_PHASE_PROBE" <<'EOF_SETUP_PHASE'
_phase_ufw
EOF_SETUP_PHASE
chmod 0755 "$SETUP_PHASE_PROBE"

reset_case ssh-port-80-collision
set +e
PATH="$TMP/bin:$PATH" SSHD_PORT=80 "$BASH" "$SETUP_PHASE_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "SSH port 80 collision did not fail before firewall mutation"
assert_file_contains "$LOG_FILE" 'SSH port 80/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "SSH collision mutated UFW before failing"

reset_case ssh-port-443-collision
set +e
PATH="$TMP/bin:$PATH" SSHD_PORT=443 "$BASH" "$SETUP_PHASE_PROBE" >"$CASE_OUTPUT" 2>&1
SETUP_UFW_RC=$?
set -e
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "SSH port 443 collision did not fail before firewall mutation"
assert_file_contains "$LOG_FILE" 'SSH port 443/tcp conflicts with managed Cloudflare web ingress'
[[ ! -s "$UFW_CALL_LOG" ]] || fail "SSH collision mutated UFW before failing"

# PR4 iptables acceptance checks: Cloudflare web admission is enforced in
# DOCKER-USER with RETURN/DROP rules, while Docker still owns ACCEPT/isolation/NAT.
! grep -Eq 'iptables .*-[AI][[:space:]]+DOCKER-USER.*-j[[:space:]]+ACCEPT' "$SETUP_FIREWALL" "$FIREWALL_LIB" \
    || fail "firewall code adds a source-only DOCKER-USER ACCEPT"
! grep -Eq 'iptables .*-[AI][[:space:]]+POSTROUTING.*-j[[:space:]]+MASQUERADE' "$SETUP_FIREWALL" "$FIREWALL_LIB" \
    || fail "firewall code adds project MASQUERADE rules"
! grep -Fq 'netfilter-persistent save' "$SETUP_FIREWALL" \
    || fail "runtime firewall reconciliation still persists iptables rules"
! grep -Eq 'apt(-get)? .*install.*iptables-persistent|apt(-get)? .*install.*netfilter-persistent' "$SETUP_FIREWALL" \
    || fail "runtime firewall reconciliation installs persistence packages"
assert_file_contains "$FIREWALL_LIB" 'VW_CF_DOCKER_CHAIN="VW-CF-INGRESS"'
assert_file_contains "$FIREWALL_LIB" 'VW_CADDY_EXTERNAL_CIDR="172.22.0.0/28"'
assert_file_contains "$FIREWALL_LIB" '--ctorigdstport'
assert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN'
! grep -Fq -- '--ctstate ESTABLISHED,RELATED -j RETURN' "$FIREWALL_LIB" \
    || fail "Docker gate still has a directionless established-state ingress bypass"
assert_file_contains "$FIREWALL_LIB" '_firewall_managed_chain_order_is_safe || return 1'
assert_file_contains "$SETUP_FIREWALL" 'if ! _ufw_has_admin_port "$status" "$ssh_port"; then'
! grep -Fq '_ufw_has_broad_admin_port' "$SETUP_FIREWALL" || fail "setup still requires broad SSH exposure"
assert_file_contains "$FIREWALL_LIB" '-j RETURN'
assert_file_contains "$FIREWALL_LIB" '-j DROP'
assert_file_contains "$FIREWALL_LIB" 'firewall_fail_closed_stop_caddy()'
assert_file_contains "$FIREWALL_LIB" 'firewall_normalize_caddy_runtime_contract()'
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || stop_rc=$?'
assert_file_contains "$SETUP_FIREWALL" 'firewall_normalize_caddy_runtime_contract || rc=$?'
assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 130' INT"
assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 129' HUP"
assert_file_contains "$SETUP_FIREWALL" "trap '_setup_firewall_signal_fail_closed 143' TERM"
assert_file_contains "$SETUP_FIREWALL" 'firewall_fail_closed_stop_caddy || log_error "CRITICAL: signal rollback'
! grep -Fq "trap 'operation_release 130; exit 130' INT" "$SETUP_FIREWALL"     || fail "post-iptables signal handling can bypass fail-closed Caddy shutdown"
assert_file_contains "$SETUP_FIREWALL" "trap '_iptables_signal_rollback 130' INT"
assert_file_contains "$SETUP_FIREWALL" "trap '_iptables_signal_rollback 143' TERM"
assert_file_contains "$UPDATER" 'firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}"'
assert_file_contains "$UPDATER" 'cache_commit_started=true'
assert_file_contains "$UPDATER" 'cache_commit_started" != "true"'
assert_file_contains "$UPDATER" 'pre_update_docker_gate_exact=false'
assert_file_contains "$UPDATER" '_update_firewall_pretransaction_fail()'
assert_file_contains "$UPDATER" 'firewall_docker_backend_preflight || docker_preflight_rc=$?'
preflight_line="$(grep -n 'firewall_docker_backend_preflight || docker_preflight_rc=' "$UPDATER" | cut -d: -f1 | head -1)"
fetch_line="$(grep -n 'Successfully fetched current Cloudflare IP ranges' "$UPDATER" | cut -d: -f1 | head -1)"
[[ -n "$preflight_line" && -n "$fetch_line" && "$preflight_line" -lt "$fetch_line" ]] \
    || fail "Docker/prior-gate safety proof does not run before Cloudflare network refresh"
assert_file_contains "$UPDATER" "trap '_update_firewall_pretransaction_signal 130' INT"
assert_file_contains "$UPDATER" "trap '_update_firewall_pretransaction_signal 143' HUP TERM"
pre_signal_line="$(grep -n "trap '_update_firewall_pretransaction_signal 143' HUP TERM" "$UPDATER" | cut -d: -f1 | head -1)"
[[ -n "$pre_signal_line" && -n "$fetch_line" && "$pre_signal_line" -lt "$fetch_line" ]] \
    || fail "pre-transaction fail-closed signal trap is not installed before network refresh"
[[ "$(grep -Fc 'pre_update_docker_gate_exact" != "true"' "$UPDATER")" -ge 3 ]] \
    || fail "pre-transaction, normal rollback, and signal rollback paths do not all fail closed for an unproven prior Docker gate"

compose_file="$ROOT/docker-compose.yml.example"
assert_file_contains "$compose_file" '"0.0.0.0:80:80"'
assert_file_contains "$compose_file" '"0.0.0.0:443:443"'
assert_file_contains "$compose_file" 'subnet: 172.22.0.0/28'
caddy_block="$TMP/caddy-compose-block.txt"
awk '/^  caddy:/{p=1} p{print} /^  postfix:/{exit}' "$compose_file" > "$caddy_block"
assert_file_contains "$caddy_block" 'restart: on-failure'
! grep -Eq 'restart:[[:space:]]+(always|unless-stopped)' "$caddy_block"     || fail "Caddy can auto-start on dockerd restart before firewall reconciliation"
for cidr in 172.21.0.0/28 172.22.0.0/28 172.23.0.0/28; do
    assert_file_contains "$compose_file" "subnet: $cidr"
done

setup_phase="$TMP/setup-firewall-phase.txt"
awk '/--phase iptables/{p=1} p{print} /Required Docker\/OCI firewall reconciliation failed/{seen=1} seen && /fi/{exit}' \
    "$ROOT/setup.sh" > "$setup_phase"
assert_file_contains "$setup_phase" '_phase_failed 5 "Required Docker/OCI firewall reconciliation failed"'
! grep -Fq 'best-effort' "$ROOT/setup.sh" \
    || fail "setup still describes iptables remediation as best-effort"

cat > "$TMP/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
exit 0
EOF_DOCKER

cat > "$TMP/bin/iptables" <<'EOF_IPTABLES'
#!/usr/bin/env bash
set -euo pipefail
printf 'iptables %s\n' "$*" >> "${IPT_CALL_LOG:?}"

if [[ "$*" == '-m conntrack -h' ]]; then
    exit 0
fi

table=filter
if [[ "${1:-}" == "-t" ]]; then
    table="$2"
    shift 2
fi
op="${1:-}"
shift || true

chain_file() {
    case "$1" in
        DOCKER-USER) printf '%s\n' "${IPT_DU_FILE:?}" ;;
        VW-CF-INGRESS) printf '%s\n' "${IPT_CF_FILE:?}" ;;
        *) return 1 ;;
    esac
}

case "$op" in
    -S)
        chain="${1:-}"
        file="$(chain_file "$chain" 2>/dev/null || true)"
        [[ -n "$file" && -e "$file" ]] || exit 1
        printf -- '-N %s\n' "$chain"
        cat "$file"
        exit 0
        ;;
    -N)
        chain="${1:-}"
        [[ "$chain" == 'VW-CF-INGRESS' ]] || exit 2
        [[ ! -e "${IPT_CF_FILE:?}" ]] || exit 1
        : > "$IPT_CF_FILE"
        exit 0
        ;;
    -C)
        chain="${1:-}"
        shift || true
        if [[ "$table" == filter && "$chain" == FORWARD && " $* " == *' -j REJECT --reject-with icmp-host-prohibited '* ]]; then
            [[ -e "${IPT_REJECT_MARKER:?}" ]] && exit 0
            exit 1
        fi
        file="$(chain_file "$chain" 2>/dev/null || true)"
        [[ -n "$file" && -e "$file" ]] || exit 1
        grep -Fxq -- "-A $chain $*" "$file"
        exit $?
        ;;
    -I)
        chain="${1:-}" pos="${2:-}"
        shift 2 || true
        full="-I $chain $pos $*"
        if [[ -n "${IPT_FAIL_MATCH:-}" && "$full" == *"$IPT_FAIL_MATCH"* ]]; then
            exit "${IPT_MUTATE_RC:-49}"
        fi
        file="$(chain_file "$chain")" || exit 2
        [[ -e "$file" ]] || exit 1
        rule="-A $chain $*"
        awk -v pos="$pos" -v rule="$rule" '
            NR == pos {print rule}
            {print}
            END {if (NR < pos) print rule}
        ' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        exit 0
        ;;
    -D)
        chain="${1:-}"
        shift || true
        if [[ "$table" == filter && "$chain" == FORWARD && " $* " == *' -j REJECT --reject-with icmp-host-prohibited '* ]]; then
            if (( ${IPT_DELETE_RC:-0} != 0 )); then exit "$IPT_DELETE_RC"; fi
            [[ -e "${IPT_REJECT_MARKER:?}" ]] || exit 1
            rm -f "$IPT_REJECT_MARKER"
            exit 0
        fi
        file="$(chain_file "$chain" 2>/dev/null || true)"
        [[ -n "$file" && -e "$file" ]] || exit 1
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            pos="$1"
            awk -v pos="$pos" 'NR != pos {print}' "$file" > "${file}.tmp"
            [[ "$(wc -l < "$file")" -gt "$(wc -l < "${file}.tmp")" ]] || { rm -f "${file}.tmp"; exit 1; }
            mv "${file}.tmp" "$file"
            exit 0
        fi
        target="-A $chain $*"
        awk -v target="$target" '
            !removed && $0 == target {removed=1; next}
            {print}
            END {if (!removed) exit 3}
        ' "$file" > "${file}.tmp" || { rc=$?; rm -f "${file}.tmp"; exit "$rc"; }
        mv "${file}.tmp" "$file"
        exit 0
        ;;
esac

# The tests do not model project-owned nat rules; absence is the normal state.
exit 1
EOF_IPTABLES

cat > "$TMP/bin/iptables-save" <<'EOF_IPTABLES_SAVE'
#!/usr/bin/env bash
set -euo pipefail
printf 'save\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-save\n' >> "${TXN_CALL_LOG:-/dev/null}"
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
printf '*filter\nCOMMIT\n'
EOF_IPTABLES_SAVE
cat > "$TMP/bin/iptables-restore" <<'EOF_IPTABLES_RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-restore\n' >> "${TXN_CALL_LOG:-/dev/null}"
cat >/dev/null
exit "${IPT_RESTORE_RC:-0}"
EOF_IPTABLES_RESTORE
chmod 0755 "$TMP/bin/docker" "$TMP/bin/iptables" "$TMP/bin/iptables-save" "$TMP/bin/iptables-restore"

FAIL_CLOSED_DOCKER="$TMP/fail-closed-docker"
cat > "$FAIL_CLOSED_DOCKER" <<'EOF_FAIL_CLOSED_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAIL_CLOSED_DOCKER_LOG:?}"
case "${1:-}" in
    inspect)
        if (( ${FAIL_CLOSED_INSPECT_RC:-0} != 0 )); then exit "$FAIL_CLOSED_INSPECT_RC"; fi
        printf '%s\n' "${FAIL_CLOSED_RUNNING:-true}"
        exit 0
        ;;
    ps)
        if (( ${FAIL_CLOSED_PS_RC:-0} != 0 )); then exit "$FAIL_CLOSED_PS_RC"; fi
        [[ "${FAIL_CLOSED_EXISTS:-true}" == "true" ]] && printf 'vaultwarden_caddy\n'
        exit 0
        ;;
    stop)
        exit "${FAIL_CLOSED_STOP_RC:-0}"
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

RUNTIME_DOCKER="$TMP/runtime-contract-docker"
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
PRE_PROBE="$TMP/docker-preflight-probe.bash"
cat > "$PRE_PROBE" <<'EOF_PRE_PROBE'
#!/usr/bin/env bash
set -euo pipefail
log_error(){ printf 'ERROR: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
log_success(){ :; }
source "${FIREWALL_LIB_PATH:?}"
firewall_docker_backend_preflight
EOF_PRE_PROBE
chmod 0755 "$PRE_PROBE"

run_preflight_case() {
    local name="$1"; shift
    PRE_DIR="$TMP/preflight-$name"
    mkdir -p "$PRE_DIR/proc/123"
    IPT_CALL_LOG="$PRE_DIR/iptables-calls"
    IPT_LOG_FILE="$PRE_DIR/log"
    IPT_DU_FILE="$PRE_DIR/docker-user"
    IPT_CF_FILE="$PRE_DIR/cf-chain"
    IPT_REJECT_MARKER="$PRE_DIR/reject"
    : > "$IPT_CALL_LOG"
    : > "$IPT_LOG_FILE"
    printf '%s\n' '-A DOCKER-USER -j RETURN' > "$IPT_DU_FILE"
    printf 'dockerd\n' > "$PRE_DIR/proc/123/comm"
    : > "$PRE_DIR/proc/123/cmdline"
    printf '%s\0' "$@" > "$PRE_DIR/proc/123/cmdline"
    export IPT_CALL_LOG IPT_LOG_FILE IPT_DU_FILE IPT_CF_FILE IPT_REJECT_MARKER
    set +e
    PATH="$TMP/bin:$PATH" FIREWALL_LIB_PATH="$FIREWALL_LIB" DOCKER_PROC_ROOT="$PRE_DIR/proc" \
        DOCKER_DAEMON_CONFIG="$PRE_DIR/no-daemon.json" "$BASH" "$PRE_PROBE" >"$PRE_DIR/output" 2>&1
    PRE_RC=$?
    set -e
}

run_preflight_case supported dockerd
[[ "$PRE_RC" -eq 0 ]] || fail "supported running Docker backend failed preflight with $PRE_RC"

run_preflight_case cli-nftables dockerd --firewall-backend=nftables
[[ "$PRE_RC" -ne 0 ]] || fail "running dockerd --firewall-backend=nftables was accepted because a stale DOCKER-USER chain existed"
assert_file_contains "$IPT_LOG_FILE" 'backend=nftables'

run_preflight_case cli-iptables-off dockerd --iptables=false
[[ "$PRE_RC" -ne 0 ]] || fail "running dockerd --iptables=false was accepted"
assert_file_contains "$IPT_LOG_FILE" 'iptables=false'

CUSTOM_PRE_DIR="$TMP/preflight-custom-config"
mkdir -p "$CUSTOM_PRE_DIR/proc/123"
printf 'dockerd\n' > "$CUSTOM_PRE_DIR/proc/123/comm"
printf '{"firewall-backend":"nftables"}\n' > "$CUSTOM_PRE_DIR/custom-daemon.json"
printf '%s\0' dockerd --config-file "$CUSTOM_PRE_DIR/custom-daemon.json" > "$CUSTOM_PRE_DIR/proc/123/cmdline"
IPT_CALL_LOG="$CUSTOM_PRE_DIR/iptables-calls" IPT_LOG_FILE="$CUSTOM_PRE_DIR/log" \
IPT_DU_FILE="$CUSTOM_PRE_DIR/docker-user" IPT_CF_FILE="$CUSTOM_PRE_DIR/cf-chain" IPT_REJECT_MARKER="$CUSTOM_PRE_DIR/reject"
printf '%s\n' '-A DOCKER-USER -j RETURN' > "$CUSTOM_PRE_DIR/docker-user"
: > "$CUSTOM_PRE_DIR/iptables-calls"; : > "$CUSTOM_PRE_DIR/log"
export IPT_CALL_LOG IPT_LOG_FILE IPT_DU_FILE IPT_CF_FILE IPT_REJECT_MARKER
set +e
PATH="$TMP/bin:$PATH" FIREWALL_LIB_PATH="$FIREWALL_LIB" DOCKER_PROC_ROOT="$CUSTOM_PRE_DIR/proc" \
    DOCKER_DAEMON_CONFIG="$CUSTOM_PRE_DIR/ignored.json" "$BASH" "$PRE_PROBE" >/dev/null 2>&1
PRE_RC=$?
set -e
[[ "$PRE_RC" -ne 0 ]] || fail "running dockerd custom nftables config file was ignored"
assert_file_contains "$CUSTOM_PRE_DIR/log" 'backend=nftables'

IPT_PROBE="$TMP/iptables-probe.bash"
cat > "$IPT_PROBE" <<'EOF_IPT_PROBE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
FORCE=false
log_info(){ printf 'INFO: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
log_warn(){ printf 'WARN: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
log_error(){ printf 'ERROR: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
log_success(){ printf 'SUCCESS: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
log_rollback(){ printf 'ROLLBACK: %s\n' "$*" >> "${IPT_LOG_FILE:?}"; }
operation_release(){ :; }
source "${FIREWALL_LIB_PATH:?}"
_docker_iptables_preflight(){ :; }
EOF_IPT_PROBE
extract_func "$SETUP_FIREWALL" _iptables_rule_state >> "$IPT_PROBE"
extract_func "$SETUP_FIREWALL" _iptables_delete_all_exact >> "$IPT_PROBE"
extract_func "$SETUP_FIREWALL" _iptables_needs_reconciliation >> "$IPT_PROBE"
extract_func "$SETUP_FIREWALL" _phase_iptables >> "$IPT_PROBE"
cat >> "$IPT_PROBE" <<'EOF_IPT_PROBE'
_phase_iptables
EOF_IPT_PROBE
chmod 0755 "$IPT_PROBE"

run_iptables_case() {
    local name="$1"
    IPT_CASE_DIR="$TMP/iptables-$name"
    mkdir -p "$IPT_CASE_DIR/tmp" "$IPT_CASE_DIR/state"
    IPT_CALL_LOG="$IPT_CASE_DIR/calls"
    IPT_LOG_FILE="$IPT_CASE_DIR/log"
    IPT_REJECT_MARKER="$IPT_CASE_DIR/reject-present"
    IPT_DU_FILE="$IPT_CASE_DIR/docker-user"
    IPT_CF_FILE="$IPT_CASE_DIR/cf-chain"
    : > "$IPT_CALL_LOG"; : > "$IPT_LOG_FILE"
    printf '%s\n' '-A DOCKER-USER -j RETURN' > "$IPT_DU_FILE"
    rm -f "$IPT_CF_FILE" "$IPT_REJECT_MARKER"
    printf '203.0.113.0/24\n2001:db8::/32\n' > "$IPT_CASE_DIR/state/cf-cidrs.cache"
    unset IPT_SAVE_RC IPT_DELETE_RC IPT_RESTORE_RC IPT_FAIL_MATCH IPT_MUTATE_RC
    export IPT_CALL_LOG IPT_LOG_FILE IPT_REJECT_MARKER IPT_DU_FILE IPT_CF_FILE
}

run_iptables_probe() {
    set +e
    PATH="$TMP/bin:$PATH" FIREWALL_LIB_PATH="$FIREWALL_LIB" TMPDIR="$IPT_CASE_DIR/tmp" \
        PROJECT_STATE_DIR="$IPT_CASE_DIR/state" "$BASH" "$IPT_PROBE" >"$IPT_CASE_DIR/output" 2>&1
    IPT_RC=$?
    set -e
}

run_iptables_case initial-gate
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "initial Docker Cloudflare gate reconciliation returned $IPT_RC"
sentinel80_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
sentinel443_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
established_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
jump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
allow_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 2 -d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$sentinel80_line" && -n "$sentinel443_line" && -n "$established_line" && -n "$jump_line" && -n "$allow_line" ]]     || fail "initial Docker gate mutation-order probe missed sentinel/established/jump/allow calls"
[[ "$sentinel80_line" -lt "$established_line" && "$sentinel443_line" -lt "$established_line" && "$established_line" -lt "$jump_line" && "$jump_line" -lt "$allow_line" ]]     || fail "initial Docker gate did not preserve established replies and attach fail-closed before Cloudflare RETURN rules"
save_line="$(grep -n '^save$' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
mutation_line="$(grep -nE 'iptables -t filter -(N|I|D) ' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$save_line" && -n "$mutation_line" && "$save_line" -lt "$mutation_line" ]] \
    || fail "Docker ingress mutation occurred before rollback snapshot"
[[ "$(head -n1 "$IPT_DU_FILE")" == '-A DOCKER-USER -j VW-CF-INGRESS' ]] \
    || fail "Cloudflare gate is not the first DOCKER-USER rule"
assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'
assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'
assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN'
[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' ]] \
    || fail "established/related Caddy return traffic is not ahead of ingress DROP rules"
assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP'
assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'

run_iptables_case orphan-stale-chain
printf '%s
' '-A VW-CF-INGRESS -j ACCEPT' > "$IPT_CF_FILE"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "orphan stale Docker gate reconciliation returned $IPT_RC"
stale_delete_line="$(grep -n 'iptables -t filter -D VW-CF-INGRESS 3' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
established_line="$(grep -n 'iptables -t filter -I VW-CF-INGRESS 1 -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
jump_line="$(grep -n 'iptables -t filter -I DOCKER-USER 1 -j VW-CF-INGRESS' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$stale_delete_line" && -n "$established_line" && -n "$jump_line" && "$stale_delete_line" -lt "$established_line" && "$established_line" -lt "$jump_line" ]]     || fail "orphan stale project-chain rules were activated before cleanup"
! grep -Fq -- '-A VW-CF-INGRESS -j ACCEPT' "$IPT_CF_FILE" || fail "orphan stale ACCEPT survived reconciliation"
! grep -Fq -- '-j ACCEPT' "$IPT_CF_FILE" || fail "Cloudflare gate bypasses Docker isolation with ACCEPT"
while IFS= read -r managed_rule; do
    [[ "$managed_rule" == *'--ctorigdstport '* ]] || continue
    [[ "$managed_rule" == *'-d 172.22.0.0/28 '* ]]         || fail "managed Docker web rule is not scoped to caddy_external: $managed_rule"
done < "$IPT_CF_FILE"

: > "$IPT_CALL_LOG"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "already-reconciled Docker gate returned $IPT_RC"
! grep -Fq '^save$' "$IPT_CALL_LOG" || fail "already-reconciled firewall took an unnecessary rollback snapshot"
! grep -Eq 'iptables -t filter -(N|I|D) ' "$IPT_CALL_LOG" || fail "already-reconciled firewall mutated iptables"
assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'

# A directionless ESTABLISHED/RELATED RETURN is not exact: ORIGINAL-direction
# packets from a direct connection established before cutover could otherwise
# continue toward Caddy. Reconciliation must replace it with REPLY-only state.
sed '1s/ --ctdir REPLY//' "$IPT_CF_FILE" > "$IPT_CF_FILE.tmp"
mv "$IPT_CF_FILE.tmp" "$IPT_CF_FILE"
[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' ]] \
    || fail "directionless established-state fixture was not created"
: > "$IPT_CALL_LOG"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "directionless established-state reconciliation returned $IPT_RC"
grep -qx 'save' "$IPT_CALL_LOG" || fail "directionless established-state rule was incorrectly treated as exact"
[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' ]] \
    || fail "reconciliation did not restore reply-direction-only established handling"
! grep -Fxq -- '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' "$IPT_CF_FILE" \
    || fail "directionless established-state bypass survived reconciliation"

# Exact-state verification must reject a chain whose DROP precedes any RETURN.
# Otherwise a manually reordered chain can be misclassified as safe and break
# Cloudflare ingress or Caddy-initiated outbound replies.
drop_rule="$(grep -F -- '-p tcp -m conntrack --ctorigdstport 80 -j DROP' "$IPT_CF_FILE" | head -1)"
[[ -n "$drop_rule" ]] || fail "could not locate managed port-80 DROP for order-drift test"
{
    printf '%s\n' "$drop_rule"
    grep -Fvx -- "$drop_rule" "$IPT_CF_FILE"
} > "$IPT_CF_FILE.tmp"
mv "$IPT_CF_FILE.tmp" "$IPT_CF_FILE"
[[ "$(head -n1 "$IPT_CF_FILE")" == *'-j DROP' ]] || fail "order-drift fixture did not move a DROP ahead of RETURN rules"
: > "$IPT_CALL_LOG"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "misordered Docker gate reconciliation returned $IPT_RC"
grep -qx 'save' "$IPT_CALL_LOG" || fail "misordered Docker gate was incorrectly treated as exact"
[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN' ]] \
    || fail "misordered Docker gate did not restore RETURN-before-DROP ordering"

: > "$IPT_REJECT_MARKER"
: > "$IPT_CALL_LOG"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "OCI reject reconciliation returned $IPT_RC"
[[ ! -e "$IPT_REJECT_MARKER" ]] || fail "OCI reject was not removed"
save_line="$(grep -n '^save$' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
delete_line="$(grep -n ' -D FORWARD ' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$save_line" && -n "$delete_line" && "$save_line" -lt "$delete_line" ]] \
    || fail "OCI mutation occurred before rollback snapshot"

run_iptables_case snapshot-failure
export IPT_SAVE_RC=48
run_iptables_probe
[[ "$IPT_RC" -ne 0 ]] || fail "iptables snapshot failure did not fail reconciliation"
! grep -Eq 'iptables -t filter -(N|I|D) ' "$IPT_CALL_LOG" || fail "iptables mutated after snapshot failure"

run_iptables_case mutation-failure
export IPT_FAIL_MATCH='VW-CF-INGRESS 1 -d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 443 -j DROP'
export IPT_MUTATE_RC=49
run_iptables_probe
[[ "$IPT_RC" -eq 49 ]] || fail "Docker gate mutation failure returned $IPT_RC instead of 49"
assert_file_contains "$IPT_CALL_LOG" 'restore'

# The periodic updater must refresh the Docker source set after UFW convergence.
reset_case updater-docker-refresh
write_ipv4_status true true
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "periodic Docker ingress refresh returned $CASE_RC"
assert_file_contains "$FW_CALL_LOG" 'reconcile 203.0.113.0/24'
assert_file_contains "$CASE_DIR/state/cf-cidrs.cache" '203.0.113.0/24'

reset_case updater-docker-rollback
write_ipv4_status true false
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "periodic Docker ingress failure returned $CASE_RC instead of 55"
assert_file_contains "$IPT_CALL_LOG" 'restore'
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
assert_call 'reload'
ufw_restore_line="$(grep -n '^ufw-reload$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
iptables_restore_line="$(grep -n '^iptables-restore$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$ufw_restore_line" && -n "$iptables_restore_line" && "$ufw_restore_line" -lt "$iptables_restore_line" ]] \
    || fail "rollback did not make iptables-restore the final firewall write"
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]]     || fail "Docker ingress failure left UFW managed rules partially updated"
[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"

reset_case updater-safe-prior-generation-rollback
write_ipv4_status true false
printf '198.51.100.0/24\n' > "$CASE_DIR/state/cf-cidrs.cache"
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_SAFE_CIDR=198.51.100.0/24 FW_EXACT_RC=1 FW_RECONCILE_RC=55
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "safe-prior rollback returned $CASE_RC instead of 55"
assert_file_contains "$IPT_CALL_LOG" 'restore'
! grep -Fq 'stop-caddy' "$FW_CALL_LOG" || fail "proven-safe prior Docker generation was stopped after successful rollback"
[[ "$(cat "$CASE_DIR/state/cf-cidrs.cache")" == '198.51.100.0/24' ]] \
    || fail "safe-prior rollback replaced the previous CIDR cache"

reset_case updater-rollback-restore-failure-stops-caddy
write_ipv4_status true false
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55 IPT_RESTORE_RC=66
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "rollback-restore failure changed original updater error: $CASE_RC"
assert_file_contains "$IPT_CALL_LOG" 'restore'
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
assert_file_contains "$LOG_FILE" 'CRITICAL: iptables rollback restore failed (exit 66)'
[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "rollback-restore failure published a new CIDR cache"

reset_case updater-rollback-and-caddy-stop-failure
write_ipv4_status true false
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55 IPT_RESTORE_RC=66 FW_STOP_CADDY_RC=67
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "double fail-closed failure changed original updater error: $CASE_RC"
assert_file_contains "$FW_CALL_LOG" 'stop-caddy'
assert_file_contains "$LOG_FILE" 'CRITICAL: firewall rollback failed and Caddy shutdown could not be confirmed.'

health_unit="$ROOT/systemd/vaultwarden-health.service"
maintenance_unit="$ROOT/systemd/vaultwarden-maintenance.service"
firewall_unit="$ROOT/systemd/vaultwarden-firewall-update.service"
iptables_unit="$ROOT/systemd/vaultwarden-iptables.service"
startup_unit="$ROOT/systemd/vaultwarden-startup.service"
dns_timer="$ROOT/systemd/vaultwarden-dns-update.timer"
firewall_timer="$ROOT/systemd/vaultwarden-firewall-update.timer"

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

! grep -Fq '/var/lib/crowdsec' "$health_unit" \
    || fail "vaultwarden-health.service grants stale CrowdSec write access"
! grep -Fq '/var/lib/crowdsec' "$maintenance_unit" \
    || fail "routine maintenance grants unused CrowdSec write access"
! grep -Eq '^ReadWritePaths=.*(/etc/ufw|/run/ufw\.lock|/run/xtables\.lock)' "$maintenance_unit" \
    || fail "routine maintenance grants firewall-only write access"
! grep -Fq 'ExecStartPre=+/usr/bin/touch /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance prepares firewall-only locks"
! grep -Fq 'ExecStartPre=+/usr/bin/chown root:root /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance changes firewall-only lock ownership"
! grep -Fq 'ExecStartPre=+/usr/bin/chmod 0600 /run/ufw.lock /run/xtables.lock' "$maintenance_unit" \
    || fail "routine maintenance changes firewall-only lock modes"
assert_file_contains "$maintenance_unit" 'ExecStart=/opt/vaultwarden-scripts/maintenance.sh run --email'
! grep -Fq -- '--comprehensive' "$maintenance_unit" \
    || fail "routine maintenance still invokes comprehensive mode"

assert_file_contains "$firewall_unit" 'ReadWritePaths=/etc/ufw /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'After=network-online.target docker.service'
assert_file_contains "$firewall_unit" 'Wants=network-online.target docker.service'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/touch /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/chown root:root /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'ExecStartPre=+/usr/bin/chmod 0600 /run/ufw.lock /run/xtables.lock'
assert_file_contains "$iptables_unit" 'ProtectSystem=strict'
assert_file_contains "$iptables_unit" 'NoNewPrivileges=yes'
assert_file_contains "$iptables_unit" 'Environment=TMPDIR=/run/vaultwarden-iptables'
assert_file_contains "$iptables_unit" 'EnvironmentFile=-/etc/vaultwarden/vaultwarden.env'
assert_file_contains "$iptables_unit" 'BindsTo=docker.service'
assert_file_contains "$iptables_unit" 'PartOf=docker.service'
assert_file_contains "$iptables_unit" 'ReadWritePaths=/run/xtables.lock /run/lock /run/vaultwarden-oci /run/vaultwarden-iptables'
assert_file_contains "$iptables_unit" 'ExecStartPre=+/usr/bin/touch /run/xtables.lock'
assert_file_contains "$iptables_unit" 'ExecStartPre=+/usr/bin/chown root:root /run/xtables.lock'
assert_file_contains "$iptables_unit" 'ExecStartPre=+/usr/bin/chmod 0600 /run/xtables.lock'
! grep -Eq 'netfilter-persistent|apt(-get)?|/etc/iptables|/etc/ufw' "$iptables_unit" \
    || fail "vaultwarden-iptables.service retains persistence/package ownership"
assert_file_contains "$startup_unit" 'Requires=vaultwarden-iptables.service'
assert_file_contains "$startup_unit" 'BindsTo=docker.service'
assert_file_contains "$startup_unit" 'PartOf=docker.service'
assert_file_contains "$startup_unit" 'After=local-fs.target docker.service network-online.target vaultwarden-iptables.service'
assert_file_contains "$dns_timer" 'OnCalendar=*-*-* *:00:00'
assert_file_contains "$firewall_timer" 'OnCalendar=Sat *-*-* 04:00:00'


DOCKER_DROPIN_PROBE="$TMP/docker-runtime-dropin-probe.bash"
cat > "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
UNIT_DEST_DIR="${DROPIN_ROOT:?}/units"
DOCKER_RUNTIME_DROPIN="${UNIT_DEST_DIR}/docker.service.d/20-vaultwarden-runtime.conf"
_run(){ "$@"; }
log_info(){ :; }
log_success(){ :; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
# The real installer is root-only. This isolated probe runs unprivileged, so
# model the root ownership that setup-systemd.sh establishes in production.
chown(){ :; }
stat(){
    if [[ "${1:-}" == "-c" && "${3:-}" == "$DOCKER_RUNTIME_DROPIN" ]]; then
        case "${2:-}" in
            %U) printf 'root\n' ;;
            %G) printf 'root\n' ;;
            %a) printf '644\n' ;;
            *) command stat "$@" ;;
        esac
    else
        command stat "$@"
    fi
}
EOF_DOCKER_DROPIN
extract_func "$SYSTEMD_SETUP" _render_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
extract_func "$SYSTEMD_SETUP" _install_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
extract_func "$SYSTEMD_SETUP" _validate_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
cat >> "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
_install_docker_runtime_dropin
_validate_docker_runtime_dropin
EOF_DOCKER_DROPIN
chmod 0755 "$DOCKER_DROPIN_PROBE"
DROPIN_ROOT="$TMP/docker-dropin-root" "$BASH" "$DOCKER_DROPIN_PROBE"
docker_runtime_dropin="$TMP/docker-dropin-root/units/docker.service.d/20-vaultwarden-runtime.conf"
assert_file_contains "$docker_runtime_dropin" 'Wants=vaultwarden-iptables.service vaultwarden-startup.service'
assert_file_contains "$SYSTEMD_SETUP" '_validate_docker_runtime_dropin'
assert_file_contains "$SYSTEMD_SETUP" 'Docker restarts would not re-run firewall reconciliation/startup.'

# Separate-volume installs must order the boot firewall owner after the mount,
# but the runtime-only iptables unit must not receive state-directory write access.
DROPIN_PROBE="$TMP/systemd-dropin-probe.bash"
cat > "$DROPIN_PROBE" <<'EOF_DROPIN'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
ENV_FILE="${DROPIN_ROOT:?}/missing.env"
UNIT_DEST_DIR="$DROPIN_ROOT/units"
DATA_VOLUME_DEVICE=/dev/fake-vaultwarden
DATA_VOLUME_MOUNT=/mnt/vw-data
_VW_DROPIN_UNITS=(vaultwarden-iptables.service vaultwarden-firewall-update.service)
mkdir -p "$UNIT_DEST_DIR"
_run(){ "$@"; }
_read_env_value(){ :; }
log_info(){ :; }
log_success(){ :; }
log_warn(){ printf 'WARN: %s\n' "$*" >&2; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
EOF_DROPIN
extract_func "$SYSTEMD_SETUP" _install_rwpaths_dropin >> "$DROPIN_PROBE"
cat >> "$DROPIN_PROBE" <<'EOF_DROPIN'
_install_rwpaths_dropin
EOF_DROPIN
chmod 0755 "$DROPIN_PROBE"
DROPIN_ROOT="$TMP/dropin-root" "$BASH" "$DROPIN_PROBE"
iptables_dropin="$TMP/dropin-root/units/vaultwarden-iptables.service.d/10-state-dir.conf"
updater_dropin="$TMP/dropin-root/units/vaultwarden-firewall-update.service.d/10-state-dir.conf"
assert_file_contains "$iptables_dropin" 'After=mnt-vw\x2ddata.mount'
! grep -Fq 'ReadWritePaths=' "$iptables_dropin" || fail "iptables boot unit received unnecessary state-directory write access"
assert_file_contains "$updater_dropin" 'After=mnt-vw\x2ddata.mount'
assert_file_contains "$updater_dropin" 'ReadWritePaths=/mnt/vw-data'

if command -v systemd-analyze >/dev/null 2>&1; then
    unit_dir="$TMP/systemd-units"
    mkdir -p "$unit_dir"
    cp "$health_unit" "$maintenance_unit" "$firewall_unit" "$iptables_unit" "$unit_dir/"
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
        vaultwarden-firewall-update.service \
        vaultwarden-iptables.service > "$verify_output" 2>&1; then
        cat "$verify_output" >&2
        fail "systemd-analyze rejected the modified units"
    fi
else
    printf 'SKIP: systemd-analyze unavailable; static systemd path assertions passed\n'
fi

maintenance_runner="$ROOT/utilities/maintenance-run.sh"
maintenance_utils="$ROOT/lib/maintenance-utils.sh"
deep_db_maintenance="$ROOT/utilities/maintenance-db-maint.sh"

for function_name in optimize_database validate_system_health generate_maintenance_summary; do
    grep -Eq "^${function_name}\\(\\)" "$maintenance_utils" \
        || fail "maintenance library does not own ${function_name}"
    ! grep -Eq "^${function_name}\\(\\)" "$maintenance_runner" \
        || fail "maintenance runner duplicates canonical ${function_name}"
done
! grep -Eq '_SAVE_SCRIPT_DIR|_MAINT_SCRIPT_DIR' "$maintenance_runner" \
    || fail "maintenance runner retains stale SCRIPT_DIR save/restore state"
assert_file_contains "$maintenance_runner" 'source "$PROJECT_ROOT/lib/maintenance-utils.sh"'
assert_file_contains "$maintenance_runner" 'MAINTENANCE_SUMMARY_RESULT'
assert_file_contains "$maintenance_runner" 'MAINTENANCE_SUMMARY_STATE'
assert_file_contains "$maintenance_runner" 'exit "$maintenance_result"'
! grep -Fq 'local critical_failures=' "$maintenance_runner" \
    || fail "maintenance runner duplicates canonical result classification"

routine_function="$TMP/optimize-database.function"
extract_func "$maintenance_utils" optimize_database > "$routine_function"
for forbidden in 'backup-run.sh' 'docker compose' 'VACUUM' 'ANALYZE' 'wal_checkpoint(TRUNCATE)' 'integrity_check' 'trap '; do
    ! grep -Fq "$forbidden" "$routine_function" \
        || fail "routine database optimization contains deep-maintenance behavior: $forbidden"
done

routine_dir="$TMP/routine-db"
mkdir -p "$routine_dir/state/data" "$routine_dir/bin"
: > "$routine_dir/state/data/db.sqlite3"
cat > "$routine_dir/bin/sqlite3" <<'EOF_SQLITE'
#!/usr/bin/env bash
set -euo pipefail
sql="${*: -1}"
printf '%s\n' "$sql" >> "${SQLITE_CALL_LOG:?}"
case "$sql" in
    'PRAGMA page_count;') printf '120\n' ;;
    'PRAGMA freelist_count;') printf '7\n' ;;
    'PRAGMA page_size;') printf '4096\n' ;;
esac
EOF_SQLITE
chmod 0755 "$routine_dir/bin/sqlite3"
cat > "$routine_dir/probe.bash" <<'EOF_ROUTINE_PROBE'
#!/usr/bin/env bash
set -euo pipefail
OPTIMIZE_DATABASE=true
DRY_RUN=false
get_config_value(){ printf '%s\n' "${VW_TEST_STATE_DIR:?}"; }
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_success(){ :; }
EOF_ROUTINE_PROBE
cat "$routine_function" >> "$routine_dir/probe.bash"
printf '\noptimize_database\n' >> "$routine_dir/probe.bash"
SQLITE_CALL_LOG="$routine_dir/sqlite.log" \
VW_TEST_STATE_DIR="$routine_dir/state" \
PATH="$routine_dir/bin:$PATH" \
    "$BASH" "$routine_dir/probe.bash" \
    || fail "routine online database maintenance failed"
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA optimize;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA wal_checkpoint(PASSIVE);'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA page_count;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA freelist_count;'
assert_file_contains "$routine_dir/sqlite.log" 'PRAGMA page_size;'

for required in \
    'utilities/backup-run.sh" run db' \
    'docker compose stop vaultwarden' \
    'PRAGMA wal_checkpoint(TRUNCATE);' \
    'PRAGMA optimize;' \
    'VACUUM;'; do
    assert_file_contains "$deep_db_maintenance" "$required"
done

health_root="$TMP/health-root"
mkdir -p "$health_root/utilities"
cat > "$health_root/utilities/maintenance-health.sh" <<'EOF_HEALTH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${HEALTH_ARGS_LOG:?}"
printf '%s\n' "${VAULTWARDEN_INTERNAL_HEALTH_CHECK:-}" > "${HEALTH_ENV_LOG:?}"
exit "${VW_TEST_HEALTH_RC:?}"
EOF_HEALTH
chmod 0755 "$health_root/utilities/maintenance-health.sh"
cat > "$TMP/health-probe.bash" <<'EOF_HEALTH_PROBE'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
log_info(){ printf 'INFO: %s\n' "$*"; }
log_warn(){ printf 'WARN: %s\n' "$*"; }
log_error(){ printf 'ERROR: %s\n' "$*"; }
log_success(){ printf 'SUCCESS: %s\n' "$*"; }
EOF_HEALTH_PROBE
extract_func "$maintenance_utils" validate_system_health >> "$TMP/health-probe.bash"
printf '\nvalidate_system_health\n' >> "$TMP/health-probe.bash"

for health_rc in 0 1 75 2 3 4 9; do
    set +e
    PROJECT_ROOT="$health_root" \
    VW_TEST_HEALTH_RC="$health_rc" \
    HEALTH_ARGS_LOG="$TMP/health-${health_rc}.args" \
    HEALTH_ENV_LOG="$TMP/health-${health_rc}.env" \
        "$BASH" "$TMP/health-probe.bash" > "$TMP/health-${health_rc}.out" 2>&1
    actual_rc=$?
    set -e
    [[ "$actual_rc" -eq "$health_rc" ]] \
        || fail "quick health status $health_rc was changed to $actual_rc"
    [[ "$(cat "$TMP/health-${health_rc}.args")" == '--quiet --quick' ]] \
        || fail "maintenance health did not invoke quick quiet profile"
    [[ "$(cat "$TMP/health-${health_rc}.env")" == true ]] \
        || fail "maintenance health omitted internal health marker"
done
assert_file_contains "$TMP/health-1.out" 'passed with advisory warnings'
assert_file_contains "$TMP/health-75.out" 'skipped because another health execution was active'
for health_rc in 2 3 4; do
    assert_file_contains "$TMP/health-${health_rc}.out" "failed with status ${health_rc}"
done
assert_file_contains "$TMP/health-9.out" 'unexpected status 9'

cat > "$TMP/summary-probe.bash" <<'EOF_SUMMARY_PROBE'
#!/usr/bin/env bash
set -euo pipefail
CLEAN_LOGS=true
CLEAN_BACKUPS=true
CLEAN_DOCKER=true
OPTIMIZE_DATABASE=true
UPDATE_FIREWALL=false
UPDATE_DNS=false
TARGETED_MODE=false
EMAIL_NOTIFY=true
log_info(){ :; }
log_warn(){ :; }
send_notification_email(){
    printf '%s\n' "$1" > "${SUMMARY_SUBJECT_LOG:?}"
    printf '%s' "$2" > "${SUMMARY_BODY_LOG:?}"
}
EOF_SUMMARY_PROBE
extract_func "$maintenance_utils" _format_duration >> "$TMP/summary-probe.bash"
extract_func "$maintenance_utils" _health_summary_line >> "$TMP/summary-probe.bash"
extract_func "$maintenance_utils" generate_maintenance_summary >> "$TMP/summary-probe.bash"
cat >> "$TMP/summary-probe.bash" <<'EOF_SUMMARY_PROBE'
generate_maintenance_summary 0 0 0 0 1 1 "${VW_TEST_HEALTH_RC:?}" 5 "${VW_TEST_RECOVERY_RC:?}"
printf '%s\n' "${MAINTENANCE_SUMMARY_STATE:?}" > "${SUMMARY_STATE_LOG:?}"
exit "${MAINTENANCE_SUMMARY_RESULT:?}"
EOF_SUMMARY_PROBE

run_summary_case() {
    local name="$1" health_rc="$2" recovery_rc="$3" expected_rc="$4"
    set +e
    VW_TEST_HEALTH_RC="$health_rc" \
    VW_TEST_RECOVERY_RC="$recovery_rc" \
    SUMMARY_SUBJECT_LOG="$TMP/${name}.subject" \
    SUMMARY_BODY_LOG="$TMP/${name}.body" \
    SUMMARY_STATE_LOG="$TMP/${name}.state" \
        "$BASH" "$TMP/summary-probe.bash" > "$TMP/${name}.out" 2>&1
    actual_rc=$?
    set -e
    [[ "$actual_rc" -eq "$expected_rc" ]] \
        || fail "summary case $name returned $actual_rc instead of $expected_rc"
}

run_summary_case warning 1 0 0
assert_file_contains "$TMP/warning.out" 'Health validation: Passed with advisory warnings'
assert_file_contains "$TMP/warning.out" 'Overall Status: SUCCESS WITH WARNINGS'
assert_file_contains "$TMP/warning.subject" 'VaultWarden Maintenance: SUCCESS WITH WARNINGS'
assert_file_contains "$TMP/warning.body" 'Health validation: Passed with advisory warnings'
assert_file_contains "$TMP/warning.state" 'warnings'

run_summary_case skipped 75 0 0
assert_file_contains "$TMP/skipped.out" 'Health validation: Skipped (another health execution was active)'
assert_file_contains "$TMP/skipped.out" 'Overall Status: COMPLETED WITH SKIPS'
assert_file_contains "$TMP/skipped.subject" 'VaultWarden Maintenance: COMPLETED WITH SKIPS'
assert_file_contains "$TMP/skipped.state" 'skips'

for health_rc in 2 3 4 9; do
    run_summary_case "failed-${health_rc}" "$health_rc" 0 1
    assert_file_contains "$TMP/failed-${health_rc}.out" 'Health validation: Failed'
    assert_file_contains "$TMP/failed-${health_rc}.out" 'Overall Status: COMPLETED WITH ISSUES'
    assert_file_contains "$TMP/failed-${health_rc}.subject" 'VaultWarden Maintenance: ISSUES DETECTED'
    assert_file_contains "$TMP/failed-${health_rc}.state" 'issues'
done

run_summary_case recovery-failed 0 1 1
assert_file_contains "$TMP/recovery-failed.out" 'Recovery-kit fallback cleanup: Failed'
assert_file_contains "$TMP/recovery-failed.out" 'Overall Status: COMPLETED WITH ISSUES'
assert_file_contains "$TMP/recovery-failed.subject" 'VaultWarden Maintenance: ISSUES DETECTED'
assert_file_contains "$TMP/recovery-failed.body" 'Recovery-kit fallback cleanup: Failed'
assert_file_contains "$TMP/recovery-failed.state" 'issues'

run_summary_case multiple-failures 2 1 2

printf 'PASS: firewall updater, Docker firewall reconciliation, routine maintenance ownership, and systemd sandbox contracts\n'
