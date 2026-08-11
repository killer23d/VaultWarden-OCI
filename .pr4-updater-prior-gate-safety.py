from pathlib import Path


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrences, found {count}: {old!r}")
    p.write_text(text.replace(old, new, expected))


updater = "utilities/maintenance-update-firewall.sh"

replace_exact(
    updater,
    '''    firewall_docker_backend_preflight || return $?\n\n    _ufw_status() {\n''',
    '''    firewall_docker_backend_preflight || return $?\n\n    # Prove whether rollback would return to a known-safe Docker ingress\n    # generation. A normal Cloudflare range change may make the gate non-exact\n    # for the newly fetched set while it is still exact for the valid cached\n    # generation. Only the latter is safe to restore without stopping Caddy.\n    local pre_update_docker_gate_exact=false\n    local -a pre_update_ipv4_cidrs=()\n    if firewall_load_cached_cloudflare_ipv4 pre_update_ipv4_cidrs >/dev/null 2>&1 && \\\n       firewall_docker_ingress_is_exact "${pre_update_ipv4_cidrs[@]}"; then\n        pre_update_docker_gate_exact=true\n    else\n        log_warn "Pre-update Docker ingress gate is not provably exact against a valid cached Cloudflare generation."\n        log_warn "If this transaction cannot commit safely, Caddy will be stopped after rollback."\n    fi\n\n    _update_firewall_fail_closed_after_unproven_prior_gate() {\n        if ! firewall_fail_closed_stop_caddy; then\n            log_error "CRITICAL: pre-update Docker ingress gate was not provably exact and Caddy shutdown could not be confirmed."\n        fi\n    }\n\n    _update_firewall_pretransaction_fail() {\n        local fail_rc="$1"\n        if [[ "$pre_update_docker_gate_exact" != "true" ]]; then\n            _update_firewall_fail_closed_after_unproven_prior_gate\n        fi\n        return "$fail_rc"\n    }\n\n    _ufw_status() {\n''',
)

replace_exact(
    updater,
    '''    _ufw_validate_safety || return $?\n\n    # UFW's managed rules live in these files. Snapshot them before the first\n''',
    '''    _ufw_validate_safety || {\n        local pretransaction_rc=$?\n        _update_firewall_pretransaction_fail "$pretransaction_rc"\n        return $?\n    }\n\n    # UFW's managed rules live in these files. Snapshot them before the first\n''',
)

replace_exact(
    updater,
    '''    pre_mutation_verbose="$(_ufw_status verbose)" || return $?\n    grep -q '^Status: active' <<< "$pre_mutation_verbose" && ufw_was_active=true\n    [[ -d "$ufw_config_dir" && -w "$ufw_config_dir" ]] || {\n        log_error "UFW configuration directory is not writable: ${ufw_config_dir}"\n        return 1\n    }\n    ufw_snapshot_dir="$(mktemp -d -t vaultwarden-ufw.XXXXXXXXXX)" || {\n        log_error "Could not allocate UFW rollback snapshot."\n        return 1\n    }\n''',
    '''    pre_mutation_verbose="$(_ufw_status verbose)" || {\n        local pretransaction_rc=$?\n        _update_firewall_pretransaction_fail "$pretransaction_rc"\n        return $?\n    }\n    grep -q '^Status: active' <<< "$pre_mutation_verbose" && ufw_was_active=true\n    [[ -d "$ufw_config_dir" && -w "$ufw_config_dir" ]] || {\n        log_error "UFW configuration directory is not writable: ${ufw_config_dir}"\n        _update_firewall_pretransaction_fail 1\n        return $?\n    }\n    ufw_snapshot_dir="$(mktemp -d -t vaultwarden-ufw.XXXXXXXXXX)" || {\n        log_error "Could not allocate UFW rollback snapshot."\n        _update_firewall_pretransaction_fail 1\n        return $?\n    }\n''',
)

replace_exact(
    updater,
    '''                log_error "Could not snapshot UFW managed rules: ${rules_file}"\n                rm -rf "$ufw_snapshot_dir"\n                return 1\n''',
    '''                log_error "Could not snapshot UFW managed rules: ${rules_file}"\n                rm -rf "$ufw_snapshot_dir"\n                _update_firewall_pretransaction_fail 1\n                return $?\n''',
)

replace_exact(
    updater,
    '''    backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {\n        log_error "Could not allocate firewall rollback snapshot."\n        rm -rf "$ufw_snapshot_dir"\n        return 1\n    }\n''',
    '''    backup_v4="$(mktemp -t vaultwarden-firewall.XXXXXXXXXX)" || {\n        log_error "Could not allocate firewall rollback snapshot."\n        rm -rf "$ufw_snapshot_dir"\n        _update_firewall_pretransaction_fail 1\n        return $?\n    }\n''',
)

replace_exact(
    updater,
    '''        rm -rf "$ufw_snapshot_dir"\n        ufw_snapshot_dir=""\n        return "$snapshot_rc"\n    fi\n\n    _update_firewall_restore_ufw() {\n''',
    '''        rm -rf "$ufw_snapshot_dir"\n        ufw_snapshot_dir=""\n        _update_firewall_pretransaction_fail "$snapshot_rc"\n        return $?\n    fi\n\n    _update_firewall_restore_ufw() {\n''',
)

replace_exact(
    updater,
    '''        if (( rollback_rc != 0 )); then\n            _update_firewall_fail_closed_after_rollback_error\n        fi\n        _update_firewall_restore_outer_traps\n''',
    '''        if (( rollback_rc != 0 )); then\n            _update_firewall_fail_closed_after_rollback_error\n        elif [[ "$pre_update_docker_gate_exact" != "true" ]]; then\n            _update_firewall_fail_closed_after_unproven_prior_gate\n        fi\n        _update_firewall_restore_outer_traps\n''',
)

replace_exact(
    updater,
    '''            if (( rollback_rc != 0 )); then\n                _update_firewall_fail_closed_after_rollback_error\n            fi\n        fi\n        operation_release "$signal_rc"\n''',
    '''            if (( rollback_rc != 0 )); then\n                _update_firewall_fail_closed_after_rollback_error\n            elif [[ "$pre_update_docker_gate_exact" != "true" ]]; then\n                _update_firewall_fail_closed_after_unproven_prior_gate\n            fi\n        fi\n        operation_release "$signal_rc"\n''',
)


test = Path("tests/suites/operations/case-firewall-update.bash")
text = test.read_text()

old_stubs = '''firewall_docker_backend_preflight(){ printf 'preflight\\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }\nfirewall_docker_ingress_is_exact(){ return "${FW_EXACT_RC:-0}"; }\nfirewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }\n'''
new_stubs = '''firewall_docker_backend_preflight(){ printf 'preflight\\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }\nfirewall_load_cached_cloudflare_ipv4(){\n    local out_name="$1" cache_file="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache" line\n    local -n out_ref="$out_name"\n    out_ref=()\n    [[ -s "$cache_file" ]] || return 1\n    while IFS= read -r line || [[ -n "$line" ]]; do\n        [[ "$line" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && out_ref+=("$line")\n    done < "$cache_file"\n    (( ${#out_ref[@]} > 0 ))\n}\nfirewall_docker_ingress_is_exact(){\n    printf 'exact %s\\n' "$*" >> "${FW_CALL_LOG:?}"\n    if [[ -n "${FW_EXACT_SAFE_CIDR:-}" && "$*" == "$FW_EXACT_SAFE_CIDR" ]]; then\n        return 0\n    fi\n    return "${FW_EXACT_RC:-0}"\n}\nfirewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }\n'''
if old_stubs not in text:
    raise SystemExit("firewall updater probe stubs anchor missing")
text = text.replace(old_stubs, new_stubs, 1)

old_unset = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT\n'''
new_unset = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_EXACT_SAFE_CIDR FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT\n'''
if old_unset not in text:
    raise SystemExit("reset-case firewall unset anchor missing")
text = text.replace(old_unset, new_unset, 1)

# A pre-transaction UFW failure must stop Caddy when the prior Docker gate is
# not provably exact; this covers migration/drift before any firewall mutation.
preflight_anchor = '''reset_case default-incoming-allow\nwrite_ipv4_status true true\nprintf 'Status: active\\nDefault: allow (incoming), allow (outgoing), disabled (routed)\\n' > "$UFW_VERBOSE_FILE"\nrun_case\n[[ "$CASE_RC" -ne 0 ]] || fail "UFW default allow incoming was accepted"\nassert_file_contains "$LOG_FILE" 'default incoming policy is not provably fail-closed'\nassert_no_call ' allow '\nassert_no_call '--force delete'\n\n'''
preflight_replacement = preflight_anchor + '''reset_case unsafe-prior-gate-pretransaction-failure\nwrite_ipv4_status true true\nprintf 'Status: active\\nDefault: allow (incoming), allow (outgoing), disabled (routed)\\n' > "$UFW_VERBOSE_FILE"\nrun_case\n[[ "$CASE_RC" -ne 0 ]] || fail "unsafe prior gate survived a pre-transaction UFW failure"\nassert_file_contains "$FW_CALL_LOG" 'stop-caddy'\n\n'''
if preflight_anchor not in text:
    raise SystemExit("pretransaction UFW failure test anchor missing")
text = text.replace(preflight_anchor, preflight_replacement, 1)

old_rollback = '''reset_case updater-docker-rollback\nwrite_ipv4_status true false\nIPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG\nexport FW_EXACT_RC=1 FW_RECONCILE_RC=55\nrun_case\n[[ "$CASE_RC" -eq 55 ]] || fail "periodic Docker ingress failure returned $CASE_RC instead of 55"\nassert_file_contains "$IPT_CALL_LOG" 'restore'\nassert_call 'reload'\nufw_restore_line="$(grep -n '^ufw-reload$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"\niptables_restore_line="$(grep -n '^iptables-restore$' "$TXN_CALL_LOG" | cut -d: -f1 | head -1)"\n[[ -n "$ufw_restore_line" && -n "$iptables_restore_line" && "$ufw_restore_line" -lt "$iptables_restore_line" ]] \\\n    || fail "rollback did not make iptables-restore the final firewall write"\n[[ "$(cat "$UFW_CONFIG_DIR/user.rules")" == 'baseline-v4' ]]     || fail "Docker ingress failure left UFW managed rules partially updated"\n[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"\n\n'''
new_rollback = old_rollback.replace(
    "assert_file_contains \"$IPT_CALL_LOG\" 'restore'\n",
    "assert_file_contains \"$IPT_CALL_LOG\" 'restore'\nassert_file_contains \"$FW_CALL_LOG\" 'stop-caddy'\n",
) + '''reset_case updater-safe-prior-generation-rollback\nwrite_ipv4_status true false\nprintf '198.51.100.0/24\\n' > "$CASE_DIR/state/cf-cidrs.cache"\nIPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG\nexport FW_EXACT_SAFE_CIDR=198.51.100.0/24 FW_EXACT_RC=1 FW_RECONCILE_RC=55\nrun_case\n[[ "$CASE_RC" -eq 55 ]] || fail "safe-prior rollback returned $CASE_RC instead of 55"\nassert_file_contains "$IPT_CALL_LOG" 'restore'\n! grep -Fq 'stop-caddy' "$FW_CALL_LOG" || fail "proven-safe prior Docker generation was stopped after successful rollback"\n[[ "$(cat "$CASE_DIR/state/cf-cidrs.cache")" == '198.51.100.0/24' ]] \\\n    || fail "safe-prior rollback replaced the previous CIDR cache"\n\n'''
if old_rollback not in text:
    raise SystemExit("updater docker rollback test anchor missing")
text = text.replace(old_rollback, new_rollback, 1)

static_anchor = '''assert_file_contains "$UPDATER" 'cache_commit_started=true'\nassert_file_contains "$UPDATER" 'cache_commit_started" != "true"'\n'''
static_replacement = '''assert_file_contains "$UPDATER" 'cache_commit_started=true'\nassert_file_contains "$UPDATER" 'cache_commit_started" != "true"'\nassert_file_contains "$UPDATER" 'pre_update_docker_gate_exact=false'\nassert_file_contains "$UPDATER" '_update_firewall_pretransaction_fail()'\n[[ "$(grep -Fc 'pre_update_docker_gate_exact" != "true"' "$UPDATER")" -ge 3 ]] \\\n    || fail "pre-transaction, normal rollback, and signal rollback paths do not all fail closed for an unproven prior Docker gate"\n'''
if static_anchor not in text:
    raise SystemExit("updater static assertions anchor missing")
text = text.replace(static_anchor, static_replacement, 1)

test.write_text(text)
