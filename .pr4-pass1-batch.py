from pathlib import Path
import re

# --- setup-firewall: comment-aware UFW source parsing + broad SSH proof ---
p = Path('utilities/setup-firewall.sh')
t = p.read_text()

old = '''        for (( ; i<${#fields[@]}; i++ )); do
            token="${fields[$i]}"
            token="${token%#*}"
            [[ "$token" == "$cidr" ]] && return 0
        done
'''
new = '''        for (( ; i<${#fields[@]}; i++ )); do
            token="${fields[$i]}"
            [[ "$token" == \\#* ]] && break
            token="${token%#*}"
            [[ "$token" == "$cidr" ]] && return 0
        done
'''
if old not in t:
    raise SystemExit('setup exact-port token loop anchor missing')
t = t.replace(old, new, 1)

old = '''    for word in "${words[@]}"; do
        word="${word%\\#*}"
        if [[ "$word" =~ ^[0-9]+(\\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
'''
new = '''    for word in "${words[@]}"; do
        [[ "$word" == \\#* ]] && break
        word="${word%\\#*}"
        if [[ "$word" =~ ^[0-9]+(\\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
'''
if old not in t:
    raise SystemExit('setup CIDR token loop anchor missing')
t = t.replace(old, new, 1)

insert = '''_ufw_has_broad_admin_port() {
    local status="$1" port="$2"
    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)" <<< "$status"
}

'''
anchor = '_ufw_line_cidr() {\n'
if anchor not in t:
    raise SystemExit('setup broad-admin helper insertion anchor missing')
t = t.replace(anchor, insert + anchor, 1)

old = '''    grep -qE "^${ssh_port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?" <<< "$status" || {
        log_error "UFW SSH rule for ${ssh_port}/tcp is missing after reconciliation."
        return 1
    }
'''
new = '''    _ufw_has_broad_admin_port "$status" "$ssh_port" || {
        log_error "Broad UFW SSH rule for ${ssh_port}/tcp is missing after reconciliation."
        return 1
    }
'''
if old not in t:
    raise SystemExit('setup SSH final verification anchor missing')
t = t.replace(old, new, 1)
p.write_text(t)

# --- updater: same comment delimiter handling + snapshot full iptables state before UFW mutation ---
p = Path('utilities/maintenance-update-firewall.sh')
t = p.read_text()

old = '''            for (( ; i<${#fields[@]}; i++ )); do
                token="${fields[$i]}"
                token="${token%#*}"
                [[ "$token" == "$cidr" ]] && return 0
            done
'''
new = '''            for (( ; i<${#fields[@]}; i++ )); do
                token="${fields[$i]}"
                [[ "$token" == \\#* ]] && break
                token="${token%#*}"
                [[ "$token" == "$cidr" ]] && return 0
            done
'''
if old not in t:
    raise SystemExit('updater exact-port token loop anchor missing')
t = t.replace(old, new, 1)

old = '''        for word in "${words[@]}"; do
            word="${word%\\#*}"
            if [[ "$word" =~ ^[0-9]+(\\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
'''
new = '''        for word in "${words[@]}"; do
            [[ "$word" == \\#* ]] && break
            word="${word%\\#*}"
            if [[ "$word" =~ ^[0-9]+(\\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
'''
if old not in t:
    raise SystemExit('updater CIDR token loop anchor missing')
t = t.replace(old, new, 1)

old = '    local backup_v4="" mutation_rc=0 cache_tmp="" cache_commit_started=false\n'
new = '    local backup_v4="" mutation_rc=0 snapshot_rc=0 cache_tmp="" cache_commit_started=false\n'
if old not in t:
    raise SystemExit('updater transaction locals anchor missing')
t = t.replace(old, new, 1)

# Full pre-mutation snapshot is part of the transaction, not only Docker gate rebuild.
anchor = '''    _update_firewall_restore_ufw() {
'''
snapshot = '''    backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {
        log_error "Could not allocate firewall rollback snapshot."
        rm -rf "$ufw_snapshot_dir"
        return 1
    }
    register_cleanup rm -f "$backup_v4"
    iptables-save > "$backup_v4" || snapshot_rc=$?
    if (( snapshot_rc != 0 )); then
        log_error "Could not snapshot pre-update iptables state; refusing all firewall mutation."
        rm -f "$backup_v4"
        backup_v4=""
        rm -rf "$ufw_snapshot_dir"
        ufw_snapshot_dir=""
        return "$snapshot_rc"
    fi

'''
if anchor not in t:
    raise SystemExit('updater pre-mutation snapshot insertion anchor missing')
t = t.replace(anchor, snapshot + anchor, 1)

old = '''    if ! firewall_docker_ingress_is_exact "${current_ipv4_cidrs[@]}"; then
        backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {
            log_error "Could not allocate Docker firewall rollback snapshot."
            _update_firewall_fail 1
            return $?
        }
        register_cleanup rm -f "$backup_v4"
        if ! iptables-save > "$backup_v4"; then
            log_error "Could not snapshot iptables state; refusing Docker ingress mutation."
            rm -f "$backup_v4"
            backup_v4=""
            _update_firewall_fail 1
            return $?
        fi

        firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}" || mutation_rc=$?
'''
new = '''    if ! firewall_docker_ingress_is_exact "${current_ipv4_cidrs[@]}"; then
        firewall_reconcile_cloudflare_docker_ingress "${current_ipv4_cidrs[@]}" || mutation_rc=$?
'''
if old not in t:
    raise SystemExit('updater late iptables snapshot block missing')
t = t.replace(old, new, 1)
p.write_text(t)

# Unit comment must describe the actual runtime owner.
p = Path('systemd/vaultwarden-iptables.service')
t = p.read_text()
t = t.replace(
    '# Docker owns bridge forwarding, isolation, and container NAT. This unit only\n# removes the OCI FORWARD reject and obsolete VaultWarden exceptions.\n',
    '# Docker owns bridge forwarding, isolation, and container NAT. This unit\n# enforces the project-scoped Cloudflare web gate, removes the OCI FORWARD reject,\n# and removes obsolete VaultWarden forwarding/NAT exceptions.\n',
    1,
)
p.write_text(t)

# --- regression coverage ---
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()

# UFW mock logs first mutation into transaction log.
t = t.replace(
    '''    printf 'mutation\\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'Rule added\\n'
''',
    '''    printf 'mutation\\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'ufw-mutation\\n' >> "${TXN_CALL_LOG:?}"
    printf 'Rule added\\n'
''',
    2,
)
old = '''    printf 'mutation\\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'Rule deleted\\n'
'''
new = '''    printf 'mutation\\n' >> "${UFW_CONFIG_DIR:?}/user.rules"
    printf 'ufw-mutation\\n' >> "${TXN_CALL_LOG:?}"
    printf 'Rule deleted\\n'
'''
if old not in t:
    raise SystemExit('delete UFW mutation log anchor missing')
t = t.replace(old, new, 1)

# Updater needs iptables snapshot mocks before updater tests execute; later iptables tests may overwrite them.
anchor = '''chmod 0755 "$TMP/bin/curl" "$TMP/bin/ufw"

PROBE="$TMP/firewall-probe.bash"
'''
mock = '''chmod 0755 "$TMP/bin/curl" "$TMP/bin/ufw"
cat > "$TMP/bin/iptables-save" <<'EOF_UPDATER_IPTABLES_SAVE'
#!/usr/bin/env bash
set -euo pipefail
printf 'save\\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-save\\n' >> "${TXN_CALL_LOG:?}"
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
printf '*filter\\nCOMMIT\\n'
EOF_UPDATER_IPTABLES_SAVE
cat > "$TMP/bin/iptables-restore" <<'EOF_UPDATER_IPTABLES_RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore\\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-restore\\n' >> "${TXN_CALL_LOG:?}"
cat >/dev/null
exit "${IPT_RESTORE_RC:-0}"
EOF_UPDATER_IPTABLES_RESTORE
chmod 0755 "$TMP/bin/iptables-save" "$TMP/bin/iptables-restore"

PROBE="$TMP/firewall-probe.bash"
'''
if anchor not in t:
    raise SystemExit('updater iptables mock insertion anchor missing')
t = t.replace(anchor, mock, 1)

old = '''    FW_CALL_LOG="$CASE_DIR/firewall-calls"
    TXN_CALL_LOG="$CASE_DIR/transaction-calls"
'''
new = '''    FW_CALL_LOG="$CASE_DIR/firewall-calls"
    IPT_CALL_LOG="$CASE_DIR/ipt-calls"
    TXN_CALL_LOG="$CASE_DIR/transaction-calls"
'''
if old not in t:
    raise SystemExit('updater IPT call log path anchor missing')
t = t.replace(old, new, 1)

old = '''    : > "$FW_CALL_LOG"
    : > "$TXN_CALL_LOG"
'''
new = '''    : > "$FW_CALL_LOG"
    : > "$IPT_CALL_LOG"
    : > "$TXN_CALL_LOG"
'''
if old not in t:
    raise SystemExit('updater IPT call log reset anchor missing')
t = t.replace(old, new, 1)

old = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_ADDED_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG TXN_CALL_LOG LOG_FILE
'''
new = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT
    unset IPT_SAVE_RC IPT_RESTORE_RC

    export CASE_DIR CF_IPV4_FILE CF_IPV6_FILE UFW_STATUS_FILE UFW_NUMBERED_FILE
    export UFW_VERBOSE_FILE UFW_DEFAULTS_FILE UFW_ADDED_FILE UFW_CONFIG_DIR UFW_CALL_LOG FW_CALL_LOG IPT_CALL_LOG TXN_CALL_LOG LOG_FILE
'''
if old not in t:
    raise SystemExit('updater IPT export anchor missing')
t = t.replace(old, new, 1)

# Snapshot must precede first UFW mutation.
old = '''reset_case only-port-80
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
assert_no_call 'port 80 comment'
assert_call 'port 443 comment CF-IPv4'
'''
new = '''reset_case only-port-80
write_ipv4_status true false
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "port 80-only convergence failed with $CASE_RC"
assert_no_call 'port 80 comment'
assert_call 'port 443 comment CF-IPv4'
save_line="$(grep -n '^iptables-save$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
ufw_mutation_line="$(grep -n '^ufw-mutation$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"
[[ -n "$save_line" && -n "$ufw_mutation_line" && "$save_line" -lt "$ufw_mutation_line" ]] \\
    || fail "full iptables rollback snapshot was not captured before first UFW mutation"
'''
if old not in t:
    raise SystemExit('only-port-80 snapshot ordering anchor missing')
t = t.replace(old, new, 1)

# Snapshot failure is authoritative before any UFW mutation.
anchor = '''reset_case only-port-443
'''
case = '''reset_case updater-pre-mutation-snapshot-failure
export IPT_SAVE_RC=47
run_case
[[ "$CASE_RC" -eq 47 ]] || fail "pre-mutation iptables snapshot failure returned $CASE_RC instead of 47"
assert_file_contains "$LOG_FILE" 'Could not snapshot pre-update iptables state'
assert_no_call ' allow '
assert_no_call '--force delete'
[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]] \\
    || fail "snapshot failure changed UFW managed rules"

reset_case only-port-443
'''
if anchor not in t:
    raise SystemExit('snapshot failure case insertion anchor missing')
t = t.replace(anchor, case, 1)

# Comment text must never be parsed as the rule source.
anchor = '''reset_case restricted-ingress-conflict
'''
case = '''reset_case comment-cidr-false-positive
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
'''
if anchor not in t:
    raise SystemExit('comment CIDR updater case anchor missing')
t = t.replace(anchor, case, 1)

# Setup probe extracts broad-admin helper.
old = '''extract_func "$SETUP_FIREWALL" _ufw_has_range_port >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_line_cidr >> "$SETUP_UFW_PROBE"
'''
new = '''extract_func "$SETUP_FIREWALL" _ufw_has_range_port >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_has_broad_admin_port >> "$SETUP_UFW_PROBE"
extract_func "$SETUP_FIREWALL" _ufw_line_cidr >> "$SETUP_UFW_PROBE"
'''
if old not in t:
    raise SystemExit('setup broad-admin helper extraction anchor missing')
t = t.replace(old, new, 1)

# Setup verifier rejects a broad rule whose comment merely contains desired CIDR.
anchor = '''reset_case setup-restricted-readiness
'''
case = '''reset_case setup-comment-cidr-false-positive
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
'''
if anchor not in t:
    raise SystemExit('setup comment CIDR case anchor missing')
t = t.replace(anchor, case, 1)

# Setup final SSH proof must require broad admin access, not a source-restricted line.
anchor = '''reset_case setup-non-tcp-readiness
'''
case = '''reset_case setup-restricted-ssh-final-proof
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
[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup final verification accepted source-restricted SSH as broad administrator access"
assert_file_contains "$LOG_FILE" 'Broad UFW SSH rule for 22/tcp is missing'

reset_case setup-non-tcp-readiness
'''
if anchor not in t:
    raise SystemExit('setup restricted SSH test anchor missing')
t = t.replace(anchor, case, 1)

# Later, richer iptables-save mock should keep transaction ordering output too.
old = '''printf 'save\\n' >> "${IPT_CALL_LOG:?}"
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
'''
new = '''printf 'save\\n' >> "${IPT_CALL_LOG:?}"
printf 'iptables-save\\n' >> "${TXN_CALL_LOG:-/dev/null}"
if (( ${IPT_SAVE_RC:-0} != 0 )); then exit "$IPT_SAVE_RC"; fi
'''
# Replace the later mock only if one occurrence remains without transaction log.
if old in t:
    t = t.replace(old, new, 1)

p.write_text(t)
