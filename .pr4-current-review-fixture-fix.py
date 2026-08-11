from pathlib import Path
import re

p = Path('tests/suites/foundation/case-systemd.bash')
t = p.read_text()
pattern = re.compile(
    r'    installed="\$unit_dir/docker\.service\.d/20-vaultwarden-runtime\.conf"\n.*?(?=    installed="\$unit_dir/vaultwarden-startup\.service"\n)',
    re.S,
)
replacement = '''    installed="$unit_dir/docker.service.d/20-vaultwarden-runtime.conf"
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
new_text, count = pattern.subn(replacement, t, count=1)
if count != 1:
    raise SystemExit(f'root-owned Docker stale fixture regex matched {count} blocks')
p.write_text(new_text)
