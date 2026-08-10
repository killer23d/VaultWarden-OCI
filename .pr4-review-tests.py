from pathlib import Path

p = Path('tests/suites/operations/case-firewall-update.bash')
text = p.read_text()


def rep(old, new, label):
    global text
    if old not in text:
        raise SystemExit(f'anchor not found: {label}')
    text = text.replace(old, new, 1)

rep(
    'SETUP_FIREWALL="$ROOT/utilities/setup-firewall.sh"\n',
    'SETUP_FIREWALL="$ROOT/utilities/setup-firewall.sh"\nFIREWALL_LIB="$ROOT/lib/firewall.sh"\nSYSTEMD_SETUP="$ROOT/utilities/setup-systemd.sh"\n',
    'test paths',
)

rep(
    '''if [[ "${1:-}" == "status" && $# -eq 1 ]]; then
''',
    '''if [[ "${1:-}" == "status" && "${2:-}" == "verbose" ]]; then
    if (( ${UFW_VERBOSE_RC:-0} != 0 )); then
        printf '%s\\n' "${UFW_VERBOSE_OUTPUT:-verbose status failed}" >&2
        exit "$UFW_VERBOSE_RC"
    fi
    cat "${UFW_VERBOSE_FILE:?}"
    exit 0
fi

if [[ "${1:-}" == "status" && $# -eq 1 ]]; then
''',
    'ufw verbose mock',
)

rep(
    '''log_debug(){ printf 'DEBUG: %s\\n' "$*" >> "${LOG_FILE:?}"; }
''',
    '''log_debug(){ printf 'DEBUG: %s\\n' "$*" >> "${LOG_FILE:?}"; }
operation_release(){ :; }
perform_cleanup(){ :; }
firewall_docker_backend_preflight(){ printf 'preflight\\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }
firewall_docker_ingress_is_exact(){ return "${FW_EXACT_RC:-0}"; }
firewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }
''',
    'updater firewall stubs',
)

rep(
    '''    UFW_STATUS_FILE="$CASE_DIR/status"
    UFW_NUMBERED_FILE="$CASE_DIR/status-numbered"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
''',
    '''    UFW_STATUS_FILE="$CASE_DIR/status"
    UFW_NUMBERED_FILE="$CASE_DIR/status-numbered"
    UFW_VERBOSE_FILE="$CASE_DIR/status-verbose"
    UFW_DEFAULTS_FILE="$CASE_DIR/ufw-defaults"
    UFW_CALL_LOG="$CASE_DIR/ufw-calls"
    FW_CALL_LOG="$CASE_DIR/firewall-calls"
''',
    'case files',
)
rep(
    '''    : > "$UFW_STATUS_FILE"
    : > "$UFW_NUMBERED_FILE"
    : > "$UFW_CALL_LOG"
    : > "$LOG_FILE"
''',
    '''    : > "$UFW_STATUS_FILE"
    : > "$UFW_NUMBERED_FILE"
    printf 'Status: active\\nDefault: deny (incoming), allow (outgoing), disabled (routed)\\n' > "$UFW_VERBOSE_FILE"
    printf 'DEFAULT_INPUT_POLICY="DROP"\\n' > "$UFW_DEFAULTS_FILE"
    : > "$UFW_CALL_LOG"
    : > "$FW_CALL_LOG"
    : > "$LOG_FILE"
''',
    'case defaults',
)
rep(
    '''    unset UFW_STATUS_RC UFW_STATUS_OUTPUT UFW_NUMBERED_RC UFW_NUMBERED_OUTPUT
    unset UFW_ALLOW80_RC UFW_ALLOW80_OUTPUT UFW_ALLOW443_RC UFW_ALLOW443_OUTPUT
    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT UFW_NO_MUTATE

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_CALL_LOG LOG_FILE
''',
    '''    unset UFW_STATUS_RC UFW_STATUS_OUTPUT UFW_NUMBERED_RC UFW_NUMBERED_OUTPUT
    unset UFW_VERBOSE_RC UFW_VERBOSE_OUTPUT
    unset UFW_ALLOW80_RC UFW_ALLOW80_OUTPUT UFW_ALLOW443_RC UFW_ALLOW443_OUTPUT
    unset UFW_DELETE_FAIL_RULE UFW_DELETE_RC UFW_DELETE_OUTPUT UFW_NO_MUTATE
    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_CALL_LOG FW_CALL_LOG LOG_FILE
''',
    'case exports',
)

safety_cases = r'''
reset_case docker-preflight-failure
export FW_PREFLIGHT_RC=60
run_case
[[ "$CASE_RC" -eq 60 ]] || fail "Docker preflight failure returned $CASE_RC instead of 60"
assert_no_call ' allow '
assert_no_call '--force delete'

reset_case default-incoming-allow
write_ipv4_status true true
printf 'Status: active\nDefault: allow (incoming), allow (outgoing), disabled (routed)\n' > "$UFW_VERBOSE_FILE"
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "UFW default allow incoming was accepted"
assert_file_contains "$LOG_FILE" 'default incoming policy is not provably fail-closed'
assert_no_call ' allow '
assert_no_call '--force delete'

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

'''
rep('reset_case status-failure\n', safety_cases + 'reset_case status-failure\n', 'UFW safety cases')

# The setup verifier now depends on the conservative UFW safety helpers.
rep(
    '''extract_func "$SETUP_FIREWALL" _ufw_collect_conflicts >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_delete_rules >> "$SETUP_UFW_PROBE"
''',
    '''extract_func "$SETUP_FIREWALL" _ufw_collect_conflicts >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_default_incoming_fail_closed >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_reject_ambiguous_inbound_allows >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_validate_safety >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_delete_rules >> "$SETUP_UFW_PROBE"
''',
    'setup UFW helper extraction',
)

ssh_collision = r'''
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

'''
rep('# PR4 iptables acceptance checks:', ssh_collision + '# PR4 iptables acceptance checks:', 'SSH collision coverage')

start = text.index('# PR4 iptables acceptance checks:')
end = text.index('health_unit="$ROOT/systemd/vaultwarden-health.service"', start)
iptables_block = r'''# PR4 iptables acceptance checks: Cloudflare web admission is enforced in
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
assert_file_contains "$FIREWALL_LIB" '--ctorigdstport'
assert_file_contains "$FIREWALL_LIB" '-j RETURN'
assert_file_contains "$FIREWALL_LIB" '-j DROP'
assert_file_contains "$SETUP_FIREWALL" "trap '_iptables_signal_rollback 130' INT"
assert_file_contains "$SETUP_FIREWALL" "trap '_iptables_signal_rollback 143' TERM"
assert_file_contains "$UPDATER" 'firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}"'

compose_file="$ROOT/docker-compose.yml.example"
assert_file_contains "$compose_file" '"0.0.0.0:80:80"'
assert_file_contains "$compose_file" '"0.0.0.0:443:443"'
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
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
printf '*filter\nCOMMIT\n'
EOF_IPTABLES_SAVE
cat > "$TMP/bin/iptables-restore" <<'EOF_IPTABLES_RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore\n' >> "${IPT_CALL_LOG:?}"
cat >/dev/null
exit "${IPT_RESTORE_RC:-0}"
EOF_IPTABLES_RESTORE
chmod 0755 "$TMP/bin/docker" "$TMP/bin/iptables" "$TMP/bin/iptables-save" "$TMP/bin/iptables-restore"

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
save_line="$(grep -n '^save$' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
mutation_line="$(grep -nE 'iptables -t filter -(N|I|D) ' "$IPT_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$save_line" && -n "$mutation_line" && "$save_line" -lt "$mutation_line" ]] \
    || fail "Docker ingress mutation occurred before rollback snapshot"
[[ "$(head -n1 "$IPT_DU_FILE")" == '-A DOCKER-USER -j VW-CF-INGRESS' ]] \
    || fail "Cloudflare gate is not the first DOCKER-USER rule"
assert_file_contains "$IPT_CF_FILE" '-s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'
assert_file_contains "$IPT_CF_FILE" '-s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'
assert_file_contains "$IPT_CF_FILE" '-p tcp -m conntrack --ctorigdstport 80 -j DROP'
assert_file_contains "$IPT_CF_FILE" '-p tcp -m conntrack --ctorigdstport 443 -j DROP'
! grep -Fq -- '-j ACCEPT' "$IPT_CF_FILE" || fail "Cloudflare gate bypasses Docker isolation with ACCEPT"

: > "$IPT_CALL_LOG"
run_iptables_probe
[[ "$IPT_RC" -eq 0 ]] || fail "already-reconciled Docker gate returned $IPT_RC"
! grep -Fq '^save$' "$IPT_CALL_LOG" || fail "already-reconciled firewall took an unnecessary rollback snapshot"
! grep -Eq 'iptables -t filter -(N|I|D) ' "$IPT_CALL_LOG" || fail "already-reconciled firewall mutated iptables"
assert_file_contains "$IPT_LOG_FILE" 'skipping mutation'

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
export IPT_FAIL_MATCH='VW-CF-INGRESS 1 -p tcp -m conntrack --ctorigdstport 443 -j DROP'
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
write_ipv4_status true true
IPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG
export FW_EXACT_RC=1 FW_RECONCILE_RC=55
run_case
[[ "$CASE_RC" -eq 55 ]] || fail "periodic Docker ingress failure returned $CASE_RC instead of 55"
assert_file_contains "$IPT_CALL_LOG" 'restore'
[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"

'''
text = text[:start] + iptables_block + text[end:]

# Systemd assertions for running Docker dependency, env/cache location, and read-only mount ordering.
rep(
    '''assert_file_contains "$iptables_unit" 'Environment=TMPDIR=/run/vaultwarden-iptables'
''',
    '''assert_file_contains "$iptables_unit" 'Environment=TMPDIR=/run/vaultwarden-iptables'
assert_file_contains "$iptables_unit" 'EnvironmentFile=-/etc/vaultwarden/vaultwarden.env'
''',
    'iptables env file assertion',
)
rep(
    '''assert_file_contains "$firewall_unit" 'ReadWritePaths=/etc/ufw /run/ufw.lock /run/xtables.lock'
''',
    '''assert_file_contains "$firewall_unit" 'ReadWritePaths=/etc/ufw /run/ufw.lock /run/xtables.lock'
assert_file_contains "$firewall_unit" 'After=network-online.target docker.service'
assert_file_contains "$firewall_unit" 'Wants=network-online.target docker.service'
''',
    'updater docker ordering assertions',
)

mount_probe = r'''
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

'''
rep('if command -v systemd-analyze >/dev/null 2>&1; then\n', mount_probe + 'if command -v systemd-analyze >/dev/null 2>&1; then\n', 'mount ordering probe')

p.write_text(text)
