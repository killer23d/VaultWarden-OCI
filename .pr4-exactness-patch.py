from pathlib import Path

SETUP_COLLECT = r'''_ufw_collect_conflicts() {
    local numbered_status="$1"
    shift
    local -a desired=("$@")
    local line rule_num cidr keep desired_cidr

    while IFS= read -r line; do
        [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|ALLOW[[:space:]]+IN)([[:space:]]|$) ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        cidr="$(_ufw_line_cidr "$line" || true)"
        keep=false
        if [[ -n "$cidr" ]]; then
            for desired_cidr in "${desired[@]}"; do
                if [[ "$desired_cidr" == "$cidr" ]]; then
                    keep=true
                    break
                fi
            done
        fi
        [[ "$keep" == "true" ]] || printf '%s\n' "$rule_num"
    done <<< "$numbered_status"
}
'''

UPDATER_HELPERS = r'''
    _ufw_line_cidr() {
        local line="$1" word
        local -a words=()
        read -ra words <<< "$line"
        for word in "${words[@]}"; do
            word="${word%\#*}"
            if [[ "$word" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
                printf '%s\n' "$word"
                return 0
            fi
        done
        return 1
    }

    _ufw_collect_conflicts() {
        local numbered_status="$1"
        shift
        local -a desired=("$@")
        local line rule_num cidr keep desired_cidr

        while IFS= read -r line; do
            [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|ALLOW[[:space:]]+IN)([[:space:]]|$) ]] || continue
            rule_num="${BASH_REMATCH[1]}"
            cidr="$(_ufw_line_cidr "$line" || true)"
            keep=false
            if [[ -n "$cidr" ]]; then
                for desired_cidr in "${desired[@]}"; do
                    if [[ "$desired_cidr" == "$cidr" ]]; then
                        keep=true
                        break
                    fi
                done
            fi
            [[ "$keep" == "true" ]] || printf '%s\n' "$rule_num"
        done <<< "$numbered_status"
    }
'''

p = Path('utilities/setup-firewall.sh')
text = p.read_text()
start = text.index('_ufw_collect_conflicts() {')
end = text.index('\n_ufw_delete_rules() {', start)
text = text[:start] + SETUP_COLLECT + text[end:]
p.write_text(text)

p = Path('utilities/maintenance-update-firewall.sh')
text = p.read_text()
insert_at = text.index('\n    _ufw_allow_range() {', text.index('    _ufw_has_range_port() {'))
if '_ufw_line_cidr()' in text:
    raise SystemExit('updater exact conflict helpers already present')
text = text[:insert_at] + UPDATER_HELPERS + text[insert_at:]
text = text.replace('    local -a cached_cidrs=()\n', '', 1)
cache_block = '''    if [[ -f "$cf_cidr_cache" ]]; then
        while IFS= read -r cidr; do
            [[ -n "$cidr" ]] && cached_cidrs+=("$cidr")
        done < "$cf_cidr_cache"
    fi

'''
if cache_block not in text:
    raise SystemExit('updater cached CIDR block not found')
text = text.replace(cache_block, '', 1)
scan_marker = '    log_info "Removing conflicting or outdated Cloudflare ingress rules..."'
scan_start = text.index('    while IFS= read -r line; do\n', text.index(scan_marker))
scan_end_marker = '    done <<< "$ufw_status"\n'
scan_end = text.index(scan_end_marker, scan_start) + len(scan_end_marker)
text = text[:scan_start] + '    mapfile -t old_rule_nums < <(_ufw_collect_conflicts "$ufw_status" "${current_cidrs[@]}")\n' + text[scan_end:]
old_final = '''    if grep -Eq '^\\[[[:space:]]*[0-9]+\\].*(80|443)(/tcp)?([[:space:]]+\\(v6\\))?[[:space:]]+(ALLOW|ALLOW[[:space:]]+IN)[[:space:]]+Anywhere([[:space:]]|$)' <<< "$final_numbered"; then
        log_error "Public UFW 80/443 allow rule remains after Cloudflare reconciliation."
        return 1
    fi
'''
new_final = '''    if [[ -n "$(_ufw_collect_conflicts "$final_numbered" "${current_cidrs[@]}")" ]]; then
        log_error "Non-Cloudflare UFW 80/443 allow rule remains after Cloudflare reconciliation."
        return 1
    fi
'''
if old_final not in text:
    raise SystemExit('updater final broad-rule verification block not found')
text = text.replace(old_final, new_final, 1)
p.write_text(text)

p = Path('tests/suites/operations/case-firewall-update.bash')
text = p.read_text()
public_anchor = '''assert_call '--force delete 5'
assert_call '--force delete 4'

'''
public_extra = '''reset_case restricted-ingress-conflict
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 80/tcp ALLOW IN 198.51.100.0/24
EOF_RULES
run_case
[[ "$CASE_RC" -eq 0 ]] || fail "restricted non-Cloudflare ingress reconciliation failed with $CASE_RC"
assert_call '--force delete 4'

reset_case restricted-final-verification
write_ipv4_status true true
cat > "$UFW_NUMBERED_FILE" <<'EOF_RULES'
[ 4] 443/tcp ALLOW IN 198.51.100.0/24
EOF_RULES
export UFW_NO_MUTATE=true
run_case
[[ "$CASE_RC" -ne 0 ]] || fail "final verification accepted restricted non-Cloudflare ingress"
assert_file_contains "$LOG_FILE" 'Non-Cloudflare UFW 80/443 allow rule remains'

'''
if public_anchor not in text:
    raise SystemExit('public ingress test anchor not found')
text = text.replace(public_anchor, public_anchor + public_extra, 1)
setup_anchor = '''assert_file_contains "$LOG_FILE" 'Conflicting public or stale managed UFW 80/443 rules remain'

reset_case setup-single-cidr-failure
'''
setup_extra = '''assert_file_contains "$LOG_FILE" 'Conflicting public or stale managed UFW 80/443 rules remain'

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
assert_file_contains "$LOG_FILE" 'Conflicting public or stale managed UFW 80/443 rules remain'

reset_case setup-single-cidr-failure
'''
if setup_anchor not in text:
    raise SystemExit('setup UFW test anchor not found')
text = text.replace(setup_anchor, setup_extra, 1)
p.write_text(text)
