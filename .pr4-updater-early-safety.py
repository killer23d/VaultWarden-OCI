from pathlib import Path

updater = Path("utilities/maintenance-update-firewall.sh")
text = updater.read_text()

start_marker = "    # Refuse all mutations if the running Docker daemon is using an unsupported\n"
end_marker = "    _ufw_status() {\n"
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("could not locate Docker prior-gate block")
block = text[start:end]
text = text[:start] + text[end:]

old_preflight = "    firewall_docker_backend_preflight || return $?\n\n"
new_preflight = '''    local docker_preflight_rc=0\n    firewall_docker_backend_preflight || docker_preflight_rc=$?\n    if (( docker_preflight_rc != 0 )); then\n        if ! firewall_fail_closed_stop_caddy; then\n            log_error "CRITICAL: Docker firewall backend preflight failed and Caddy shutdown could not be confirmed."\n        fi\n        return "$docker_preflight_rc"\n    fi\n\n'''
if block.count(old_preflight) != 1:
    raise SystemExit("unexpected Docker preflight anchor count")
block = block.replace(old_preflight, new_preflight, 1)

insert_marker = '    log_info "Safely updating Cloudflare IP ranges in UFW and Docker ingress filtering..."\n'
if text.count(insert_marker) != 1:
    raise SystemExit("updater fetch start anchor missing")
text = text.replace(insert_marker, block + insert_marker, 1)

old_alloc = '''    local cf_ipv4_file cf_ipv6_file\n    cf_ipv4_file=$(mktemp -t cf_ipv4.XXXXXXXXXX)\n    cf_ipv6_file=$(mktemp -t cf_ipv6.XXXXXXXXXX)\n    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"\n'''
new_alloc = '''    local cf_ipv4_file="" cf_ipv6_file="" allocation_rc=0\n    cf_ipv4_file="$(mktemp -t cf_ipv4.XXXXXXXXXX)" || allocation_rc=$?\n    if (( allocation_rc != 0 )); then\n        log_error "Could not allocate Cloudflare IPv4 range download file."\n        _update_firewall_pretransaction_fail "$allocation_rc"\n        return $?\n    fi\n    allocation_rc=0\n    cf_ipv6_file="$(mktemp -t cf_ipv6.XXXXXXXXXX)" || allocation_rc=$?\n    if (( allocation_rc != 0 )); then\n        log_error "Could not allocate Cloudflare IPv6 range download file."\n        rm -f "$cf_ipv4_file"\n        _update_firewall_pretransaction_fail "$allocation_rc"\n        return $?\n    fi\n    register_cleanup rm -f "$cf_ipv4_file" "$cf_ipv6_file"\n'''
if text.count(old_alloc) != 1:
    raise SystemExit("Cloudflare temp allocation anchor missing")
text = text.replace(old_alloc, new_alloc, 1)

old_fetch_fail = '''    else\n        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"\n        return 1\n    fi\n'''
new_fetch_fail = '''    else\n        log_error "Failed to fetch Cloudflare IP ranges - aborting firewall update"\n        _update_firewall_pretransaction_fail 1\n        return $?\n    fi\n'''
if text.count(old_fetch_fail) != 1:
    raise SystemExit("Cloudflare fetch failure anchor missing")
text = text.replace(old_fetch_fail, new_fetch_fail, 1)

for old, new, label in [
    ('            log_error "Invalid Cloudflare IPv4 CIDR: ${range}"\n            return 1\n',
     '            log_error "Invalid Cloudflare IPv4 CIDR: ${range}"\n            _update_firewall_pretransaction_fail 1\n            return $?\n', "IPv4 parse"),
    ('            log_error "Invalid Cloudflare IPv6 CIDR: ${range}"\n            return 1\n',
     '            log_error "Invalid Cloudflare IPv6 CIDR: ${range}"\n            _update_firewall_pretransaction_fail 1\n            return $?\n', "IPv6 parse"),
    ('        log_error "No valid Cloudflare CIDRs were fetched; refusing firewall changes."\n        return 1\n',
     '        log_error "No valid Cloudflare CIDRs were fetched; refusing firewall changes."\n        _update_firewall_pretransaction_fail 1\n        return $?\n', "empty CIDR"),
]:
    if text.count(old) != 1:
        raise SystemExit(f"{label} anchor missing")
    text = text.replace(old, new, 1)

updater.write_text(text)


test = Path("tests/suites/operations/case-firewall-update.bash")
t = test.read_text()

old_curl = '''case "$url" in\n    *ips-v4) cat "${CF_IPV4_FILE:?}" > "$out" ;;\n    *ips-v6) cat "${CF_IPV6_FILE:?}" > "$out" ;;\n    *) exit 2 ;;\nesac\n'''
new_curl = '''case "$url" in\n    *ips-v4) [[ "${CURL_FAIL_V4:-false}" == "true" ]] && exit 22; cat "${CF_IPV4_FILE:?}" > "$out" ;;\n    *ips-v6) [[ "${CURL_FAIL_V6:-false}" == "true" ]] && exit 22; cat "${CF_IPV6_FILE:?}" > "$out" ;;\n    *) exit 2 ;;\nesac\n'''
if t.count(old_curl) != 1:
    raise SystemExit("curl mock anchor missing")
t = t.replace(old_curl, new_curl, 1)

old_unset = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_EXACT_SAFE_CIDR FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT\n    unset IPT_SAVE_RC IPT_RESTORE_RC\n'''
new_unset = '''    unset FW_PREFLIGHT_RC FW_EXACT_RC FW_EXACT_SAFE_CIDR FW_RECONCILE_RC FW_STOP_CADDY_RC SSHD_PORT\n    unset CURL_FAIL_V4 CURL_FAIL_V6\n    unset IPT_SAVE_RC IPT_RESTORE_RC\n'''
if t.count(old_unset) != 1:
    raise SystemExit("reset curl env anchor missing")
t = t.replace(old_unset, new_unset, 1)

old_preflight_case = '''reset_case docker-preflight-failure\nexport FW_PREFLIGHT_RC=60\nrun_case\n[[ "$CASE_RC" -eq 60 ]] || fail "Docker preflight failure returned $CASE_RC instead of 60"\nassert_no_call ' allow '\nassert_no_call '--force delete'\n\n'''
new_preflight_case = '''reset_case docker-preflight-failure\nexport FW_PREFLIGHT_RC=60\nrun_case\n[[ "$CASE_RC" -eq 60 ]] || fail "Docker preflight failure returned $CASE_RC instead of 60"\nassert_file_contains "$FW_CALL_LOG" 'stop-caddy'\nassert_no_call ' allow '\nassert_no_call '--force delete'\n\nreset_case unsafe-prior-gate-fetch-failure\nexport CURL_FAIL_V4=true\nrun_case\n[[ "$CASE_RC" -ne 0 ]] || fail "Cloudflare fetch failure with unproven prior gate returned success"\nassert_file_contains "$LOG_FILE" 'Failed to fetch Cloudflare IP ranges'\nassert_file_contains "$FW_CALL_LOG" 'stop-caddy'\nassert_no_call ' allow '\n\nreset_case safe-prior-gate-fetch-failure\nprintf '198.51.100.0/24\\n' > "$CASE_DIR/state/cf-cidrs.cache"\nexport FW_EXACT_SAFE_CIDR=198.51.100.0/24 CURL_FAIL_V4=true\nrun_case\n[[ "$CASE_RC" -ne 0 ]] || fail "safe-prior Cloudflare fetch failure returned success"\nassert_file_contains "$FW_CALL_LOG" 'exact 198.51.100.0/24'\n! grep -Fq 'stop-caddy' "$FW_CALL_LOG" || fail "proven-safe prior gate was stopped on fetch failure"\nassert_no_call ' allow '\n\n'''
if t.count(old_preflight_case) != 1:
    raise SystemExit("Docker preflight test anchor missing")
t = t.replace(old_preflight_case, new_preflight_case, 1)

static_anchor = '''assert_file_contains "$UPDATER" '_update_firewall_pretransaction_fail()'\n'''
static_replacement = '''assert_file_contains "$UPDATER" '_update_firewall_pretransaction_fail()'\nassert_file_contains "$UPDATER" 'firewall_docker_backend_preflight || docker_preflight_rc=$?'\npreflight_line="$(grep -n 'firewall_docker_backend_preflight || docker_preflight_rc=' "$UPDATER" | cut -d: -f1 | head -1)"\nfetch_line="$(grep -n 'Successfully fetched current Cloudflare IP ranges' "$UPDATER" | cut -d: -f1 | head -1)"\n[[ -n "$preflight_line" && -n "$fetch_line" && "$preflight_line" -lt "$fetch_line" ]] \\\n    || fail "Docker/prior-gate safety proof does not run before Cloudflare network refresh"\n'''
if t.count(static_anchor) != 1:
    raise SystemExit("updater static pretransaction anchor missing")
t = t.replace(static_anchor, static_replacement, 1)

test.write_text(t)
