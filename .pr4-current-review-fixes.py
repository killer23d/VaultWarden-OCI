from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1))


# 1. Preserve Caddy-initiated outbound flows before the NEW-flow source gate.
replace_once(
    "lib/firewall.sh",
    '''    local expected_count=$(( ${#cidrs[@]} * 2 + 2 )) actual_count cidr port\n    actual_count="$(_firewall_chain_rule_count "$VW_CF_DOCKER_CHAIN")"\n    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" -eq "$expected_count" ]] || return 1\n\n    for cidr in "${cidrs[@]}"; do\n''',
    '''    local expected_count=$(( ${#cidrs[@]} * 2 + 3 )) actual_count cidr port\n    actual_count="$(_firewall_chain_rule_count "$VW_CF_DOCKER_CHAIN")"\n    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" -eq "$expected_count" ]] || return 1\n\n    # Replies to connections initiated by Caddy must return to Docker's normal\n    # forwarding path instead of being mistaken for new public web ingress.\n    iptables -t filter -C "$VW_CF_DOCKER_CHAIN" \\\n        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \\\n        >/dev/null 2>&1 || return 1\n\n    for cidr in "${cidrs[@]}"; do\n''',
    "established-flow exact-state verification",
)
replace_once(
    "lib/firewall.sh",
    '''    local cidr port\n    # RETURN, never ACCEPT: permitted Cloudflare packets continue through\n    # Docker's own forwarding/isolation rules instead of bypassing them.\n    for cidr in "${cidrs[@]}"; do\n        for port in 80 443; do\n            iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \\\n                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\\n                || return $?\n        done\n    done\n\n    # Install a new first-rule jump before deleting older duplicate jumps, so\n''',
    '''    local cidr port\n    # RETURN, never ACCEPT: permitted Cloudflare packets continue through\n    # Docker's own forwarding/isolation rules instead of bypassing them.\n    for cidr in "${cidrs[@]}"; do\n        for port in 80 443; do\n            iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \\\n                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \\\n                || return $?\n        done\n    done\n\n    # This must remain ahead of the source DROP rules: Caddy-initiated HTTP,\n    # HTTPS, DNS, and related reply traffic is not new public ingress. RETURN\n    # keeps Docker authoritative for the eventual forwarding decision.\n    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \\\n        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \\\n        || return $?\n\n    # Install a new first-rule jump before deleting older duplicate jumps, so\n''',
    "established-flow reconciliation",
)

# 2. Preserve an existing explicit SSH ALLOW/LIMIT rule instead of widening it.
replace_once(
    "utilities/setup-firewall.sh",
    '''_ufw_has_broad_admin_port() {\n    local status="$1" port="$2"\n    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)" <<< "$status"\n}\n''',
    '''_ufw_has_admin_port() {\n    local status="$1" port="$2"\n    # Preserve any explicit single-port TCP administrator rule, including a\n    # source-restricted ALLOW/LIMIT. PR4 must not widen an operator's SSH ACL.\n    grep -qE "^${port}/tcp([[:space:]]+\\(v6\\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+[^[:space:]#]+([[:space:]]|$)" <<< "$status"\n}\n''',
    "SSH rule matcher",
)
replace_once(
    "utilities/setup-firewall.sh",
    '''    _ufw_has_broad_admin_port "$status" "$ssh_port" || {\n        log_error "Broad UFW SSH rule for ${ssh_port}/tcp is missing after reconciliation."\n        return 1\n    }\n''',
    '''    _ufw_has_admin_port "$status" "$ssh_port" || {\n        log_error "Explicit UFW SSH ALLOW/LIMIT rule for ${ssh_port}/tcp is missing after reconciliation."\n        return 1\n    }\n''',
    "SSH final-state verifier",
)
replace_once(
    "utilities/setup-firewall.sh",
    '''    ufw allow "${ssh_port}/tcp" >/dev/null\n\n    numbered_status="$(_ufw_status numbered)" || return $?\n''',
    '''    if ! _ufw_has_admin_port "$status" "$ssh_port"; then\n        local ssh_output ssh_rc=0\n        ssh_output="$(ufw allow "${ssh_port}/tcp" 2>&1)" || ssh_rc=$?\n        if (( ssh_rc != 0 )); then\n            log_error "Failed to add default UFW SSH rule for ${ssh_port}/tcp (exit ${ssh_rc}): ${ssh_output:-no output}"\n            return "$ssh_rc"\n        fi\n        log_info "Added default UFW SSH rule for ${ssh_port}/tcp because no explicit SSH rule existed."\n    else\n        log_info "Preserving existing explicit UFW SSH rule for ${ssh_port}/tcp."\n    fi\n\n    numbered_status="$(_ufw_status numbered)" || return $?\n''',
    "conditional SSH rule creation",
)

# 3. Remove positively owned Docker lifecycle and packet-filter artifacts on uninstall.
replace_once(
    "utilities/uninstall-vaultwarden.sh",
    '''MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"\nCS_DIR="${VW_UNINSTALL_CROWDSEC_DIR:-/etc/crowdsec}"\n''',
    '''MOUNT_GUARD="$SYSTEMD/docker.service.d/10-vaultwarden-data-volume.conf"\nDOCKER_RUNTIME_DROPIN="$SYSTEMD/docker.service.d/20-vaultwarden-runtime.conf"\nVW_CF_DOCKER_CHAIN="VW-CF-INGRESS"\nCS_DIR="${VW_UNINSTALL_CROWDSEC_DIR:-/etc/crowdsec}"\n''',
    "uninstall owned-artifact constants",
)
replace_once(
    "utilities/uninstall-vaultwarden.sh",
    '''guard_managed(){ [[ -f "$MOUNT_GUARD" && ! -L "$MOUNT_GUARD" ]] && grep -Fq 'Managed by VaultWarden-OCI setup.sh' "$MOUNT_GUARD"; }\nremove_guard(){ if [[ -e "$MOUNT_GUARD" || -L "$MOUNT_GUARD" ]]; then guard_managed || { warn "Preserving unmarked Docker mount guard: $MOUNT_GUARD"; return 1; }; rm -f "$MOUNT_GUARD"; rmdir "$(dirname "$MOUNT_GUARD")" 2>/dev/null || true; fi; has systemctl && systemctl daemon-reload 2>/dev/null || true; }\n\nstorage_ambiguous(){\n''',
    '''guard_managed(){ [[ -f "$MOUNT_GUARD" && ! -L "$MOUNT_GUARD" ]] && grep -Fq 'Managed by VaultWarden-OCI setup.sh' "$MOUNT_GUARD"; }\nremove_guard(){ if [[ -e "$MOUNT_GUARD" || -L "$MOUNT_GUARD" ]]; then guard_managed || { warn "Preserving unmarked Docker mount guard: $MOUNT_GUARD"; return 1; }; rm -f "$MOUNT_GUARD"; rmdir "$(dirname "$MOUNT_GUARD")" 2>/dev/null || true; fi; has systemctl && systemctl daemon-reload 2>/dev/null || true; }\n\ndocker_runtime_dropin_managed(){\n  [[ -f "$DOCKER_RUNTIME_DROPIN" && ! -L "$DOCKER_RUNTIME_DROPIN" ]] || return 1\n  local expected\n  expected="$(cat <<'DROPIN'\n# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.\n# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.\n[Unit]\nWants=vaultwarden-iptables.service vaultwarden-startup.service\nDROPIN\n)"\n  [[ "$(cat "$DOCKER_RUNTIME_DROPIN")" == "$expected" ]]\n}\n\nremove_docker_runtime_dropin(){\n  [[ -e "$DOCKER_RUNTIME_DROPIN" || -L "$DOCKER_RUNTIME_DROPIN" ]] || return 0\n  if ! docker_runtime_dropin_managed; then\n    warn "Preserving unrecognized Docker runtime drop-in: $DOCKER_RUNTIME_DROPIN"\n    return 0\n  fi\n  rm -f -- "$DOCKER_RUNTIME_DROPIN" || return 1\n  rmdir "$(dirname "$DOCKER_RUNTIME_DROPIN")" 2>/dev/null || true\n  ok "Removed managed Docker runtime owner drop-in."\n}\n\nstorage_ambiguous(){\n''',
    "runtime drop-in ownership helpers",
)
replace_once(
    "utilities/uninstall-vaultwarden.sh",
    '''  for u in "${TIMERS[@]}" "${SERVICES[@]}"; do rm -f "$SYSTEMD/$u"; d="$SYSTEMD/$u.d"; rm -f "$d"/{10-state-dir.conf,20-identity.conf,30-run-as-root.conf} 2>/dev/null || true; rmdir "$d" 2>/dev/null || true; done\n  if has systemctl; then\n''',
    '''  for u in "${TIMERS[@]}" "${SERVICES[@]}"; do rm -f "$SYSTEMD/$u"; d="$SYSTEMD/$u.d"; rm -f "$d"/{10-state-dir.conf,20-identity.conf,30-run-as-root.conf} 2>/dev/null || true; rmdir "$d" 2>/dev/null || true; done\n  remove_docker_runtime_dropin || die "Could not remove the managed Docker runtime owner drop-in."\n  if has systemctl; then\n''',
    "runtime drop-in uninstall call",
)
replace_once(
    "utilities/uninstall-vaultwarden.sh",
    '''ufw_numbers(){ has ufw || return 0; ufw status numbered 2>/dev/null | awk '$0~/#[[:space:]]*CF-IPv[46]([[:space:]-]|$)/{x=$0;sub(/^\\[[[:space:]]*/,"",x);sub(/\\].*/,"",x);gsub(/[[:space:]]/,"",x);if(x~/^[0-9]+$/)print x}' | sort -rn; }\nfirewall_cleanup(){ local n; if has ufw; then while read -r n; do [[ -n "$n" ]] && ufw --force delete "$n" >/dev/null 2>&1 || true; done < <(ufw_numbers); fi; warn "Preserving unmarked UFW and raw iptables/ip6tables rules."; }\n''',
    '''ufw_numbers(){ has ufw || return 0; ufw status numbered 2>/dev/null | awk '$0~/#[[:space:]]*CF-IPv[46]([[:space:]-]|$)/{x=$0;sub(/^\\[[[:space:]]*/,"",x);sub(/\\].*/,"",x);gsub(/[[:space:]]/,"",x);if(x~/^[0-9]+$/)print x}' | sort -rn; }\n\nvaultwarden_docker_gate_present(){\n  has iptables || return 1\n  iptables -t filter -S "$VW_CF_DOCKER_CHAIN" >/dev/null 2>&1 && return 0\n  iptables -t filter -S DOCKER-USER 2>/dev/null | grep -Fxq -- "-A DOCKER-USER -j $VW_CF_DOCKER_CHAIN"\n}\n\nremove_vaultwarden_docker_gate(){\n  has iptables || return 0\n  while iptables -t filter -C DOCKER-USER -j "$VW_CF_DOCKER_CHAIN" >/dev/null 2>&1; do\n    iptables -t filter -D DOCKER-USER -j "$VW_CF_DOCKER_CHAIN" || return $?\n  done\n  if iptables -t filter -S "$VW_CF_DOCKER_CHAIN" >/dev/null 2>&1; then\n    iptables -t filter -F "$VW_CF_DOCKER_CHAIN" || return $?\n    iptables -t filter -X "$VW_CF_DOCKER_CHAIN" || return $?\n    ok "Removed managed Docker Cloudflare ingress chain."\n  fi\n  return 0\n}\n\nfirewall_cleanup(){\n  local n\n  remove_vaultwarden_docker_gate || die "Could not remove the managed Docker Cloudflare ingress gate."\n  if has ufw; then while read -r n; do [[ -n "$n" ]] && ufw --force delete "$n" >/dev/null 2>&1 || true; done < <(ufw_numbers); fi\n  warn "Preserving unmarked UFW and non-VaultWarden raw iptables/ip6tables rules."\n}\n''',
    "project Docker gate uninstall cleanup",
)
replace_once(
    "utilities/uninstall-vaultwarden.sh",
    '''  guard_managed && { warn "RESIDUAL: managed Docker mount guard $MOUNT_GUARD"; bad=$((bad+1)); } || true\n  for u in "$OPT_DIR" "$ETC_DIR" "$RUNTIME"; do [[ ! -e "$u" && ! -L "$u" ]] || { warn "RESIDUAL: $u"; bad=$((bad+1)); }; done\n''',
    '''  guard_managed && { warn "RESIDUAL: managed Docker mount guard $MOUNT_GUARD"; bad=$((bad+1)); } || true\n  docker_runtime_dropin_managed && { warn "RESIDUAL: managed Docker runtime owner drop-in $DOCKER_RUNTIME_DROPIN"; bad=$((bad+1)); } || true\n  vaultwarden_docker_gate_present && { warn "RESIDUAL: managed Docker Cloudflare ingress gate $VW_CF_DOCKER_CHAIN"; bad=$((bad+1)); } || true\n  for u in "$OPT_DIR" "$ETC_DIR" "$RUNTIME"; do [[ ! -e "$u" && ! -L "$u" ]] || { warn "RESIDUAL: $u"; bad=$((bad+1)); }; done\n''',
    "owned firewall residual verification",
)

# 4. Firewall regression coverage for established flows and restricted SSH.
replace_once(
    "tests/suites/operations/case-firewall-update.bash",
    '''extract_func "$SETUP_FIREWALL" _ufw_has_broad_admin_port >> "$SETUP_UFW_PROBE"\n''',
    '''extract_func "$SETUP_FIREWALL" _ufw_has_admin_port >> "$SETUP_UFW_PROBE"\n''',
    "test SSH helper extraction",
)
replace_once(
    "tests/suites/operations/case-firewall-update.bash",
    '''[[ "$SETUP_UFW_RC" -ne 0 ]] || fail "setup final verification accepted source-restricted SSH as broad administrator access"\nassert_file_contains "$LOG_FILE" 'Broad UFW SSH rule for 22/tcp is missing'\n''',
    '''[[ "$SETUP_UFW_RC" -eq 0 ]] || fail "setup final verification rejected an existing source-restricted SSH rule"\n! grep -Fq 'Broad UFW SSH rule' "$LOG_FILE" || fail "restricted SSH was still treated as invalid administrator access"\n''',
    "restricted SSH verifier expectation",
)
replace_once(
    "tests/suites/operations/case-firewall-update.bash",
    '''assert_file_contains "$FIREWALL_LIB" '--ctorigdstport'\nassert_file_contains "$FIREWALL_LIB" '-j RETURN'\n''',
    '''assert_file_contains "$FIREWALL_LIB" '--ctorigdstport'\nassert_file_contains "$FIREWALL_LIB" '--ctstate ESTABLISHED,RELATED -j RETURN'\nassert_file_contains "$SETUP_FIREWALL" 'if ! _ufw_has_admin_port "$status" "$ssh_port"; then'\n! grep -Fq '_ufw_has_broad_admin_port' "$SETUP_FIREWALL" || fail "setup still requires broad SSH exposure"\nassert_file_contains "$FIREWALL_LIB" '-j RETURN'\n''',
    "firewall acceptance assertions",
)
replace_once(
    "tests/suites/operations/case-firewall-update.bash",
    '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'\nassert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'\nassert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP'\n''',
    '''assert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 80 -j RETURN'\nassert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -s 203.0.113.0/24 -p tcp -m conntrack --ctorigdstport 443 -j RETURN'\nassert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN'\n[[ "$(head -n1 "$IPT_CF_FILE")" == '-A VW-CF-INGRESS -d 172.22.0.0/28 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' ]] \\\n    || fail "established/related Caddy return traffic is not ahead of ingress DROP rules"\nassert_file_contains "$IPT_CF_FILE" '-d 172.22.0.0/28 -p tcp -m conntrack --ctorigdstport 80 -j DROP'\n''',
    "established-flow behavioral assertion",
)

# 5. Uninstall regression coverage for new positively owned artifacts.
replace_once(
    "tests/suites/operations/case-uninstall.bash",
    '''! grep -Eq 'apt-get (remove|autoremove).*purge|apt-get autoremove' "$U" || fail "shared package purge returned"\n\nset -- run --dry-run\n''',
    '''! grep -Eq 'apt-get (remove|autoremove).*purge|apt-get autoremove' "$U" || fail "shared package purge returned"\ngrep -Fq '20-vaultwarden-runtime.conf' "$U" || fail "uninstaller does not own the Docker runtime drop-in"\ngrep -Fq 'VW-CF-INGRESS' "$U" || fail "uninstaller does not own the project Docker ingress chain"\n\nset -- run --dry-run\n''',
    "uninstall static ownership assertions",
)
replace_once(
    "tests/suites/operations/case-uninstall.bash",
    '''storage_ambiguous || fail "managed mount guard did not expose partial storage config"\n\n# A mounted custom state root is separate-volume evidence even when persisted\n''',
    '''storage_ambiguous || fail "managed mount guard did not expose partial storage config"\n\n# The Docker lifecycle drop-in is positively owned only when it matches the\n# exact setup-systemd managed contract. Foreign content is preserved.\nDOCKER_RUNTIME_DROPIN="$SYSTEMD/docker.service.d/20-vaultwarden-runtime.conf"\ncat > "$DOCKER_RUNTIME_DROPIN" <<'EOF_RUNTIME_DROPIN'\n# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.\n# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.\n[Unit]\nWants=vaultwarden-iptables.service vaultwarden-startup.service\nEOF_RUNTIME_DROPIN\ndocker_runtime_dropin_managed || fail "exact managed Docker runtime drop-in was not recognized"\nremove_docker_runtime_dropin || fail "managed Docker runtime drop-in could not be removed"\n[[ ! -e "$DOCKER_RUNTIME_DROPIN" ]] || fail "managed Docker runtime drop-in remained"\nmkdir -p "$(dirname "$DOCKER_RUNTIME_DROPIN")"\nprintf '%s\\n' '# operator-owned Docker drop-in' '[Unit]' 'Wants=example.service' > "$DOCKER_RUNTIME_DROPIN"\nif docker_runtime_dropin_managed; then fail "foreign Docker runtime drop-in was classified as managed"; fi\nremove_docker_runtime_dropin || fail "foreign Docker runtime drop-in preservation returned failure"\n[[ -f "$DOCKER_RUNTIME_DROPIN" ]] || fail "foreign Docker runtime drop-in was removed"\nrm -f "$DOCKER_RUNTIME_DROPIN"\n\n# The uniquely named project chain and its exact DOCKER-USER jump are removed\n# without touching unrelated raw iptables state.\nIPT_GATE_DIR="$T/iptables-gate"; mkdir -p "$IPT_GATE_DIR"\nIPT_GATE_JUMP="$IPT_GATE_DIR/jump"; IPT_GATE_CHAIN="$IPT_GATE_DIR/chain"; IPT_GATE_CALLS="$IPT_GATE_DIR/calls"\nprintf 'present\\n' > "$IPT_GATE_JUMP"; printf 'present\\n' > "$IPT_GATE_CHAIN"; : > "$IPT_GATE_CALLS"\niptables(){\n  printf '%s\\n' "$*" >> "$IPT_GATE_CALLS"\n  case "$*" in\n    '-t filter -C DOCKER-USER -j VW-CF-INGRESS') [[ -e "$IPT_GATE_JUMP" ]] ;;\n    '-t filter -D DOCKER-USER -j VW-CF-INGRESS') rm -f "$IPT_GATE_JUMP" ;;\n    '-t filter -S VW-CF-INGRESS') [[ -e "$IPT_GATE_CHAIN" ]] && printf '%s\\n' '-N VW-CF-INGRESS' ;;\n    '-t filter -F VW-CF-INGRESS') [[ -e "$IPT_GATE_CHAIN" ]] ;;\n    '-t filter -X VW-CF-INGRESS') rm -f "$IPT_GATE_CHAIN" ;;\n    '-t filter -S DOCKER-USER') [[ -e "$IPT_GATE_JUMP" ]] && printf '%s\\n' '-A DOCKER-USER -j VW-CF-INGRESS' ;;\n    *) return 1 ;;\n  esac\n}\nremove_vaultwarden_docker_gate || fail "managed Docker ingress gate cleanup failed"\n[[ ! -e "$IPT_GATE_JUMP" && ! -e "$IPT_GATE_CHAIN" ]] || fail "managed Docker ingress gate remained"\ngrep -Fq -- '-D DOCKER-USER -j VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed DOCKER-USER jump was not removed"\ngrep -Fq -- '-F VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed ingress chain was not flushed"\ngrep -Fq -- '-X VW-CF-INGRESS' "$IPT_GATE_CALLS" || fail "managed ingress chain was not deleted"\nunset -f iptables\n\n# A mounted custom state root is separate-volume evidence even when persisted\n''',
    "uninstall owned-artifact behavior tests",
)

# 6. Foundation clean-install fixture must include the managed Docker drop-in.
replace_once(
    "tests/suites/foundation/case-systemd.bash",
    '''    chmod 644 "$unit_dir/vaultwarden-startup.service"\n\n    cat > "$env_dir/vaultwarden.env" <<EOF_ENV\n''',
    '''    chmod 644 "$unit_dir/vaultwarden-startup.service"\n\n    mkdir -p "$unit_dir/docker.service.d"\n    cat > "$unit_dir/docker.service.d/20-vaultwarden-runtime.conf" <<'EOF_DOCKER_RUNTIME'\n# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.\n# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.\n[Unit]\nWants=vaultwarden-iptables.service vaultwarden-startup.service\nEOF_DOCKER_RUNTIME\n    chmod 644 "$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"\n    if (( EUID == 0 )); then\n        chown root:root "$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"\n    else\n        sudo -n chown root:root "$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"\n    fi\n\n    cat > "$env_dir/vaultwarden.env" <<EOF_ENV\n''',
    "foundation Docker runtime fixture",
)
replace_once(
    "tests/suites/foundation/case-systemd.bash",
    '''    cp "$ROOT/systemd/vaultwarden-db-backup.service" "$installed"\n    chmod 644 "$installed"\n\n    installed="$unit_dir/vaultwarden-startup.service"\n''',
    '''    cp "$ROOT/systemd/vaultwarden-db-backup.service" "$installed"\n    chmod 644 "$installed"\n\n    installed="$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"\n    printf '\\n# stale Docker lifecycle fixture\\n' >> "$installed"\n    stale_out="$TMP/validate-stale-docker-runtime.out"\n    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \\\n        || fail "validate succeeded with stale Docker runtime owner drop-in"\n    grep -Fq "DRIFT: $installed does not match the managed Docker lifecycle contract" "$stale_out" \\\n        || { cat "$stale_out" >&2; fail "stale Docker runtime owner drop-in was not named"; }\n    cat > "$installed" <<'EOF_DOCKER_RUNTIME'\n# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.\n# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.\n[Unit]\nWants=vaultwarden-iptables.service vaultwarden-startup.service\nEOF_DOCKER_RUNTIME\n    chmod 644 "$installed"\n\n    installed="$unit_dir/vaultwarden-startup.service"\n''',
    "foundation stale Docker runtime test",
)
