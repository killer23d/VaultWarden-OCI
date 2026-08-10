from pathlib import Path

# Caddy must not auto-restart before the runtime firewall gate is rebuilt.
p = Path('docker-compose.yml.example')
t = p.read_text()
anchor = '''  caddy:
    container_name: vaultwarden_caddy
    build:
'''
if anchor not in t:
    raise SystemExit('caddy service anchor missing')
start = t.index(anchor)
end = t.index('\n  # -------------------- Optional sidecar:', start)
block = t[start:end]
if '    restart: unless-stopped\n' not in block:
    raise SystemExit('caddy restart policy anchor missing')
block = block.replace(
    '    restart: unless-stopped\n',
    '    # Caddy is started by vaultwarden-startup.service only after the\n'
    '    # Docker packet-path firewall gate has reconciled. Do not let dockerd\n'
    '    # auto-restart this public listener before that gate exists.\n'
    '    restart: "no"\n',
    1,
)
t = t[:start] + block + t[end:]
p.write_text(t)

# Firewall oneshot follows the Docker daemon lifecycle so a restart invalidates
# its RemainAfterExit state and queues a fresh reconciliation after Docker.
p = Path('systemd/vaultwarden-iptables.service')
t = p.read_text()
t = t.replace(
    'After=network-online.target docker.service\nWants=docker.service\nWants=network-online.target\n',
    'After=network-online.target docker.service\nBindsTo=docker.service\nPartOf=docker.service\nWants=network-online.target\n',
    1,
)
p.write_text(t)

# Startup is also reset with Docker and still waits for successful firewall
# reconciliation before it may start Caddy.
p = Path('systemd/vaultwarden-startup.service')
t = p.read_text()
t = t.replace(
    'Requires=docker.service vaultwarden-iptables.service\nAfter=local-fs.target docker.service network-online.target vaultwarden-iptables.service\n',
    'Requires=vaultwarden-iptables.service\nBindsTo=docker.service\nPartOf=docker.service\nAfter=local-fs.target docker.service network-online.target vaultwarden-iptables.service\n',
    1,
)
p.write_text(t)

# Install one small Docker Unit drop-in. Wants pulls the now-inactive PartOf
# units back into every Docker start transaction; their After=docker.service
# ordering then serializes firewall -> startup.
p = Path('utilities/setup-systemd.sh')
t = p.read_text()
anchor = 'NOTIFY_FAILURE_TEMPLATE="vaultwarden-notify-failure@.service"\n'
if anchor not in t:
    raise SystemExit('setup-systemd constants anchor missing')
t = t.replace(
    anchor,
    anchor + 'DOCKER_RUNTIME_DROPIN="${UNIT_DEST_DIR}/docker.service.d/20-vaultwarden-runtime.conf"\n',
    1,
)

insert_before = '_sync_runtime_environment_files() {\n'
if insert_before not in t:
    raise SystemExit('setup-systemd helper insertion anchor missing')
helper = r'''_install_docker_runtime_dropin() {
    local dropin_dir
    dropin_dir="$(dirname "$DOCKER_RUNTIME_DROPIN")"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
        return 0
    fi
    mkdir -p "$dropin_dir" || {
        log_error "Cannot create Docker systemd drop-in directory: $dropin_dir"
        return 1
    }
    cat > "$DOCKER_RUNTIME_DROPIN" <<'DROPIN'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy has restart: "no" so dockerd cannot publish it before this sequence.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
DROPIN
    chmod 0644 "$DOCKER_RUNTIME_DROPIN"
    log_success "Installed Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
}

_remove_docker_runtime_dropin() {
    local dropin_dir
    dropin_dir="$(dirname "$DOCKER_RUNTIME_DROPIN")"
    if [[ -f "$DOCKER_RUNTIME_DROPIN" ]]; then
        _run rm -f "$DOCKER_RUNTIME_DROPIN"
        log_success "Removed Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove Docker runtime owner drop-in if present: $DOCKER_RUNTIME_DROPIN"
    fi
    if [[ -d "$dropin_dir" ]] && [[ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        _run rmdir "$dropin_dir"
        log_success "Removed empty Docker drop-in directory: $dropin_dir"
    fi
}

'''
t = t.replace(insert_before, helper + insert_before, 1)

anchor = '''    _render_startup_service || return 1

    _install_rwpaths_dropin
'''
replacement = '''    _render_startup_service || return 1

    _install_docker_runtime_dropin || return 1
    _install_rwpaths_dropin
'''
if anchor not in t:
    raise SystemExit('systemd install dropin call anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''    # Clean up per-unit ReadWritePaths drop-in directories written by
'''
replacement = '''    _remove_docker_runtime_dropin

    # Clean up per-unit ReadWritePaths drop-in directories written by
'''
if anchor not in t:
    raise SystemExit('systemd remove dropin anchor missing')
t = t.replace(anchor, replacement, 1)

# Help text records the lifecycle contract so generated docs expose it.
t = t.replace(
    '    8. Enables vaultwarden-startup.service and enables timers; starts timers only according to start policy\n'
    '    9. If timers were started now, verifies all managed timers are active and have a next trigger\n',
    '    8. Installs a Docker lifecycle drop-in so firewall reconciliation and startup rerun after dockerd restarts\n'
    '    9. Enables vaultwarden-startup.service and enables timers; starts timers only according to start policy\n'
    '   10. If timers were started now, verifies all managed timers are active and have a next trigger\n',
    1,
)
p.write_text(t)

# Permanent regression coverage.
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''assert_file_contains "$compose_file" '"0.0.0.0:443:443"'
assert_file_contains "$compose_file" 'subnet: 172.22.0.0/28'
'''
replacement = '''assert_file_contains "$compose_file" '"0.0.0.0:443:443"'
assert_file_contains "$compose_file" 'subnet: 172.22.0.0/28'
caddy_block="$TMP/caddy-compose-block.txt"
awk '/^  caddy:/{p=1} p{print} /^  postfix:/{exit}' "$compose_file" > "$caddy_block"
assert_file_contains "$caddy_block" 'restart: "no"'
! grep -Fq 'restart: unless-stopped' "$caddy_block" \
    || fail "Caddy can auto-restart before Docker firewall reconciliation"
'''
if anchor not in t:
    raise SystemExit('compose lifecycle test anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''assert_file_contains "$iptables_unit" 'EnvironmentFile=-/etc/vaultwarden/vaultwarden.env'
'''
replacement = '''assert_file_contains "$iptables_unit" 'EnvironmentFile=-/etc/vaultwarden/vaultwarden.env'
assert_file_contains "$iptables_unit" 'BindsTo=docker.service'
assert_file_contains "$iptables_unit" 'PartOf=docker.service'
'''
if anchor not in t:
    raise SystemExit('iptables lifecycle assertion anchor missing')
t = t.replace(anchor, replacement, 1)

anchor = '''assert_file_contains "$startup_unit" 'Requires=docker.service vaultwarden-iptables.service'
assert_file_contains "$startup_unit" 'After=local-fs.target docker.service network-online.target vaultwarden-iptables.service'
'''
replacement = '''assert_file_contains "$startup_unit" 'Requires=vaultwarden-iptables.service'
assert_file_contains "$startup_unit" 'BindsTo=docker.service'
assert_file_contains "$startup_unit" 'PartOf=docker.service'
assert_file_contains "$startup_unit" 'After=local-fs.target docker.service network-online.target vaultwarden-iptables.service'
'''
if anchor not in t:
    raise SystemExit('startup lifecycle assertion anchor missing')
t = t.replace(anchor, replacement, 1)

# Probe the installer helper using its testable UNIT_DEST_DIR override.
anchor = '''# Separate-volume installs must order the boot firewall owner after the mount,
'''
probe = r'''DOCKER_DROPIN_PROBE="$TMP/docker-runtime-dropin-probe.bash"
cat > "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
UNIT_DEST_DIR="${DROPIN_ROOT:?}/units"
DOCKER_RUNTIME_DROPIN="${UNIT_DEST_DIR}/docker.service.d/20-vaultwarden-runtime.conf"
_run(){ "$@"; }
log_info(){ :; }
log_success(){ :; }
log_error(){ printf 'ERROR: %s\n' "$*" >&2; }
EOF_DOCKER_DROPIN
extract_func "$SYSTEMD_SETUP" _install_docker_runtime_dropin >> "$DOCKER_DROPIN_PROBE"
cat >> "$DOCKER_DROPIN_PROBE" <<'EOF_DOCKER_DROPIN'
_install_docker_runtime_dropin
EOF_DOCKER_DROPIN
chmod 0755 "$DOCKER_DROPIN_PROBE"
DROPIN_ROOT="$TMP/docker-dropin-root" "$BASH" "$DOCKER_DROPIN_PROBE"
docker_runtime_dropin="$TMP/docker-dropin-root/units/docker.service.d/20-vaultwarden-runtime.conf"
assert_file_contains "$docker_runtime_dropin" 'Wants=vaultwarden-iptables.service vaultwarden-startup.service'

# Separate-volume installs must order the boot firewall owner after the mount,
'''
if anchor not in t:
    raise SystemExit('docker dropin probe insertion anchor missing')
t = t.replace(anchor, probe, 1)
p.write_text(t)
