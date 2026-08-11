from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'utilities/maintenance-update-firewall.sh',
    '''    _update_firewall_fail() {\n        local fail_rc="$1"\n        _update_firewall_rollback_all || true\n        _update_firewall_restore_outer_traps\n        return "$fail_rc"\n    }\n\n    _update_firewall_signal_rollback() {\n        local signal_rc="$1"\n        # The atomic cache rename is the transaction commit point. Bash defers\n        # traps until a foreground command returns, so a signal delivered while\n        # mv succeeds sees the temp path gone and must not roll back the already\n        # committed firewall generation.\n        if [[ "$cache_commit_started" != "true" || -z "$cache_tmp" || -e "$cache_tmp" ]]; then\n            _update_firewall_rollback_all || true\n        fi\n        operation_release "$signal_rc"\n''',
    '''    _update_firewall_fail_closed_after_rollback_error() {\n        if ! firewall_fail_closed_stop_caddy; then\n            log_error "CRITICAL: firewall rollback failed and Caddy shutdown could not be confirmed."\n        fi\n    }\n\n    _update_firewall_fail() {\n        local fail_rc="$1" rollback_rc=0\n        _update_firewall_rollback_all || rollback_rc=$?\n        if (( rollback_rc != 0 )); then\n            _update_firewall_fail_closed_after_rollback_error\n        fi\n        _update_firewall_restore_outer_traps\n        return "$fail_rc"\n    }\n\n    _update_firewall_signal_rollback() {\n        local signal_rc="$1" rollback_rc=0\n        # The atomic cache rename is the transaction commit point. Bash defers\n        # traps until a foreground command returns, so a signal delivered while\n        # mv succeeds sees the temp path gone and must not roll back the already\n        # committed firewall generation.\n        if [[ "$cache_commit_started" != "true" || -z "$cache_tmp" || -e "$cache_tmp" ]]; then\n            _update_firewall_rollback_all || rollback_rc=$?\n            if (( rollback_rc != 0 )); then\n                _update_firewall_fail_closed_after_rollback_error\n            fi\n        fi\n        operation_release "$signal_rc"\n''',
    'updater rollback failure handling',
)

replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''firewall_docker_backend_preflight(){ printf 'preflight\\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }\nfirewall_docker_ingress_is_exact(){ return "${FW_EXACT_RC:-0}"; }\nfirewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }\n''',
    '''firewall_docker_backend_preflight(){ printf 'preflight\\n' >> "${FW_CALL_LOG:?}"; return "${FW_PREFLIGHT_RC:-0}"; }\nfirewall_docker_ingress_is_exact(){ return "${FW_EXACT_RC:-0}"; }\nfirewall_reconcile_cloudflare_docker_ingress(){ printf 'reconcile %s\\n' "$*" >> "${FW_CALL_LOG:?}"; return "${FW_RECONCILE_RC:-0}"; }\nfirewall_fail_closed_stop_caddy(){ printf 'stop-caddy\\n' >> "${FW_CALL_LOG:?}"; return "${FW_STOP_CADDY_RC:-0}"; }\n''',
    'updater probe fail-closed stub',
)
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC SSHD_PORT\n''',
    '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT\n''',
    'updater probe reset',
)
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"\n\nhealth_unit="$ROOT/systemd/vaultwarden-health.service"\n''',
    '''[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "failed Docker ingress refresh published a new CIDR cache"\n\nreset_case updater-rollback-restore-failure-stops-caddy\nwrite_ipv4_status true false\nIPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG\nexport FW_EXACT_RC=1 FW_RECONCILE_RC=55 IPT_RESTORE_RC=66\nrun_case\n[[ "$CASE_RC" -eq 55 ]] || fail "rollback-restore failure changed original updater error: $CASE_RC"\nassert_file_contains "$IPT_CALL_LOG" 'restore'\nassert_file_contains "$FW_CALL_LOG" 'stop-caddy'\nassert_file_contains "$LOG_FILE" 'CRITICAL: iptables rollback restore failed (exit 66)'\n[[ ! -e "$CASE_DIR/state/cf-cidrs.cache" ]] || fail "rollback-restore failure published a new CIDR cache"\n\nreset_case updater-rollback-and-caddy-stop-failure\nwrite_ipv4_status true false\nIPT_CALL_LOG="$CASE_DIR/ipt-calls"; : > "$IPT_CALL_LOG"; export IPT_CALL_LOG\nexport FW_EXACT_RC=1 FW_RECONCILE_RC=55 IPT_RESTORE_RC=66 FW_STOP_CADDY_RC=67\nrun_case\n[[ "$CASE_RC" -eq 55 ]] || fail "double fail-closed failure changed original updater error: $CASE_RC"\nassert_file_contains "$FW_CALL_LOG" 'stop-caddy'\nassert_file_contains "$LOG_FILE" 'CRITICAL: firewall rollback failed and Caddy shutdown could not be confirmed.'\n\nhealth_unit="$ROOT/systemd/vaultwarden-health.service"\n''',
    'updater rollback failure regressions',
)
