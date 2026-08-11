from pathlib import Path

p = Path('tests/suites/foundation/case-systemd.bash')
t = p.read_text()
old = '''    installed="$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"
    printf '\n# stale Docker lifecycle fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-docker-runtime.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale Docker runtime owner drop-in"
    grep -Fq "DRIFT: $installed does not match the managed Docker lifecycle contract" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale Docker runtime owner drop-in was not named"; }
    cat > "$installed" <<'EOF_DOCKER_RUNTIME'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
EOF_DOCKER_RUNTIME
    chmod 644 "$installed"
'''
new = '''    installed="$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"
    if (( EUID == 0 )); then
        printf '\n# stale Docker lifecycle fixture\n' >> "$installed"
    else
        printf '\n# stale Docker lifecycle fixture\n' | sudo -n tee -a "$installed" >/dev/null
    fi
    stale_out="$TMP/validate-stale-docker-runtime.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale Docker runtime owner drop-in"
    grep -Fq "DRIFT: $installed does not match the managed Docker lifecycle contract" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale Docker runtime owner drop-in was not named"; }
    if (( EUID == 0 )); then
        cat > "$installed" <<'EOF_DOCKER_RUNTIME'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
EOF_DOCKER_RUNTIME
    else
        sudo -n tee "$installed" >/dev/null <<'EOF_DOCKER_RUNTIME'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
EOF_DOCKER_RUNTIME
    fi
    chmod 644 "$installed" 2>/dev/null || sudo -n chmod 644 "$installed"
'''
if old not in t:
    raise SystemExit('root-owned Docker stale fixture anchor missing')
p.write_text(t.replace(old, new, 1))
