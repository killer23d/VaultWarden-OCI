from pathlib import Path


def replace_all(path, old, new, expected, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} anchors in {path}, found {count}")
    p.write_text(text.replace(old, new))


def replace_once(path, old, new, label):
    replace_all(path, old, new, 1, label)


# Exact admission proof must never confuse UFW ALLOW OUT with inbound access.
for path in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    replace_once(
        path,
        '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue\n        i=$((i + 1))\n        if [[ "${fields[$i]:-}" == "IN" ]]; then\n            i=$((i + 1))\n        fi\n\n        for (( ; i<${#fields[@]}; i++ )); do\n''',
        '''        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue\n        i=$((i + 1))\n        [[ "${fields[$i]:-}" == "IN" ]] || continue\n        i=$((i + 1))\n\n        for (( ; i<${#fields[@]}; i++ )); do\n''',
        f'{path} range direction',
    )
    replace_once(
        path,
        '''(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$)''',
        '''(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$)''',
        f'{path} conflict direction',
    )

replace_once(
    'utilities/setup-firewall.sh',
    '''grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"''',
    '''grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"''',
    'SSH ingress direction',
)

# Updater: an outbound web allow for the current CIDR is not an inbound CF rule.
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''reset_case only-port-443\nwrite_ipv4_status false true\nrun_case\n[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"\nassert_call 'port 80 comment CF-IPv4'\nassert_no_call 'port 443 comment'\n\n''',
    '''reset_case only-port-443\nwrite_ipv4_status false true\nrun_case\n[[ "$CASE_RC" -eq 0 ]] || fail "port 443-only convergence failed with $CASE_RC"\nassert_call 'port 80 comment CF-IPv4'\nassert_no_call 'port 443 comment'\n\nreset_case outbound-web-not-ingress\ncat > "$UFW_STATUS_FILE" <<'EOF_STATUS'\n80/tcp ALLOW OUT 203.0.113.0/24\n443/tcp ALLOW IN 203.0.113.0/24\nEOF_STATUS\ncat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'\n[ 9] 80/tcp ALLOW OUT 203.0.113.0/24\n[10] 443/tcp ALLOW IN 203.0.113.0/24\nEOF_RULES\nrun_case\n[[ "$CASE_RC" -eq 0 ]] || fail "outbound-only web rule convergence failed with $CASE_RC"\nassert_call 'port 80 comment CF-IPv4'\nassert_no_call '--force delete 9'\n\n''',
    'updater outbound web regression',
)

# Setup verifier: outbound SSH/web rules cannot satisfy inbound readiness proof.
replace_once(
    'tests/suites/operations/case-firewall-update.bash',
    '''reset_case setup-non-tcp-readiness\n''',
    '''reset_case setup-outbound-ssh-not-admin\ncat > "$UFW_STATUS_FILE" <<'EOF_STATUS'\nStatus: active\n22/tcp ALLOW OUT Anywhere\n80/tcp ALLOW IN 203.0.113.0/24\n443/tcp ALLOW IN 203.0.113.0/24\nEOF_STATUS\ncat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'\n[ 1] 22/tcp ALLOW OUT Anywhere\n[ 2] 80/tcp ALLOW IN 203.0.113.0/24\n[ 3] 443/tcp ALLOW IN 203.0.113.0/24\nEOF_RULES\nset +e\nPATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1\nSETUP_UFW_RC=$?\nset -e\n[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound SSH allow satisfied inbound administrator proof"\nassert_file_contains "$LOG_FILE" 'Explicit UFW SSH ALLOW/LIMIT rule for 22/tcp is missing'\n\nreset_case setup-outbound-web-not-ingress\ncat > "$UFW_STATUS_FILE" <<'EOF_STATUS'\nStatus: active\n22/tcp ALLOW IN 198.51.100.10/32\n80/tcp ALLOW OUT 203.0.113.0/24\n443/tcp ALLOW IN 203.0.113.0/24\nEOF_STATUS\ncat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'\n[ 1] 22/tcp ALLOW IN 198.51.100.10/32\n[ 2] 80/tcp ALLOW OUT 203.0.113.0/24\n[ 3] 443/tcp ALLOW IN 203.0.113.0/24\nEOF_RULES\nset +e\nPATH="$TMP/bin:$PATH" SETUP_UFW_CASE=verify "$BASH" "$SETUP_UFW_PROBE" >"$CASE_OUTPUT" 2>&1\nSETUP_UFW_RC=$?\nset -e\n[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "outbound port-80 allow satisfied Cloudflare ingress proof"\nassert_file_contains "$LOG_FILE" 'Missing Cloudflare UFW rule: 203.0.113.0/24 -> 80/tcp'\n\nreset_case setup-non-tcp-readiness\n''',
    'setup outbound direction regressions',
)
