#!/usr/bin/env bash
# uninstall-vaultwarden.sh
# Full idempotent uninstaller for killer23d/VaultWarden-OCI
# Run from the user's home directory: bash ~/uninstall-vaultwarden.sh
# Must be run as root (or via sudo).

set -uo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'
info()    { echo -e "${YELLOW}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ─── Locate project directory ─────────────────────────────────────────────────
# Support running from home dir regardless of which user owns the clone.
# Tries common paths; falls back gracefully.
REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$REAL_USER")
PROJECT_DIR="${REAL_HOME}/VaultWarden-OCI"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "   VaultWarden-OCI Full Uninstaller"
echo "   Project dir : ${PROJECT_DIR}"
echo "   Running as  : $(whoami)  (real user: ${REAL_USER})"
echo "════════════════════════════════════════════════════════════"
echo ""
warn "This will PERMANENTLY DELETE all data, secrets, containers,"
warn "volumes, and configuration created by VaultWarden-OCI."
echo ""
read -r -p "Type 'UNINSTALL' to confirm, or anything else to abort: " CONFIRM
[[ "$CONFIRM" == "UNINSTALL" ]] || { info "Aborted — nothing changed."; exit 0; }
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1 — Stop & remove Docker containers, volumes, networks
# ═══════════════════════════════════════════════════════════════
info "Step 1: Stopping Docker Compose stack..."

if command -v docker &>/dev/null; then
    # Try docker compose down from the project directory first
    if [[ -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" down \
            --volumes --remove-orphans --timeout 30 2>/dev/null \
            && success "Docker Compose stack stopped and volumes removed." \
            || warn "docker compose down had errors (containers may already be gone)."
    fi

    # Also clean up any stray containers whose names match known service names
    for svc in vaultwarden caddy fail2ban postfix; do
        CID=$(docker ps -aq --filter "name=${svc}" 2>/dev/null)
        if [[ -n "$CID" ]]; then
            docker stop "$CID" 2>/dev/null || true
            docker rm   "$CID" 2>/dev/null || true
            success "Removed container: ${svc}"
        fi
    done

    # Remove named volumes (project prefix is the directory basename)
    PROJECT_NAME=$(basename "${PROJECT_DIR}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    for vol in $(docker volume ls -q 2>/dev/null | grep -E "^(${PROJECT_NAME}_|vaultwarden)" || true); do
        # BUG-P4-9 FIX: Log a warning when docker volume rm fails rather than
        # silently swallowing the error. A volume that cannot be removed means
        # data is still in use or the uninstall is incomplete.
        if docker volume rm "$vol" 2>/dev/null; then
            success "Removed Docker volume: ${vol}"
        else
            warn "Could not remove volume '${vol}' (may still be in use). Run 'docker volume rm ${vol}' manually after all containers stop."
        fi
    done

    # Remove custom bridge networks created by this project
    for net in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E "vaultwarden|${PROJECT_NAME}" || true); do
        docker network rm "$net" 2>/dev/null && success "Removed Docker network: ${net}" || true
    done
else
    warn "docker not found — skipping container/volume cleanup."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 2 — Disable & remove systemd units
# ═══════════════════════════════════════════════════════════════
info "Step 2: Removing systemd timer/service units..."

TIMERS=(
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)
SERVICES=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure@.service
)

for unit in "${TIMERS[@]}"; do
    if systemctl is-enabled "$unit" &>/dev/null; then
        systemctl disable --now "$unit" 2>/dev/null \
            && success "Disabled timer: $unit" \
            || warn "Could not disable $unit (may already be inactive)."
    fi
done

for unit in "${TIMERS[@]}" "${SERVICES[@]}"; do
    DEST="/etc/systemd/system/${unit}"
    if [[ -f "$DEST" ]]; then
        rm -f "$DEST" && success "Removed unit file: $DEST"
    fi
done

if command -v systemctl &>/dev/null; then
    systemctl daemon-reload 2>/dev/null && success "systemd daemon reloaded."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Remove /opt/vaultwarden-scripts
# ═══════════════════════════════════════════════════════════════
info "Step 3: Removing /opt/vaultwarden-scripts..."
if [[ -d /opt/vaultwarden-scripts ]]; then
    rm -rf /opt/vaultwarden-scripts \
        && success "Removed /opt/vaultwarden-scripts"
else
    info "/opt/vaultwarden-scripts not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Remove /etc/vaultwarden (EnvironmentFile + dir)
# ═══════════════════════════════════════════════════════════════
info "Step 4: Removing /etc/vaultwarden..."
if [[ -d /etc/vaultwarden ]]; then
    rm -rf /etc/vaultwarden \
        && success "Removed /etc/vaultwarden (including vaultwarden.env)"
else
    info "/etc/vaultwarden not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Remove /var/lib/vaultwarden (database & all runtime data)
# ═══════════════════════════════════════════════════════════════
info "Step 5: Removing /var/lib/vaultwarden (database, logs, Caddy/Fail2ban state)..."
if [[ -d /var/lib/vaultwarden ]]; then
    rm -rf /var/lib/vaultwarden \
        && success "Removed /var/lib/vaultwarden"
else
    info "/var/lib/vaultwarden not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 6 — Remove the cloned project directory (secrets, keys, config)
# ═══════════════════════════════════════════════════════════════
info "Step 6: Removing project directory ${PROJECT_DIR}..."
if [[ -d "$PROJECT_DIR" ]]; then
    rm -rf "$PROJECT_DIR" \
        && success "Removed ${PROJECT_DIR}"
else
    info "${PROJECT_DIR} not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 7 — Remove setup lock file
# ═══════════════════════════════════════════════════════════════
info "Step 7: Removing setup lock file..."
rm -f /var/lock/vaultwarden-setup.lock && success "Removed /var/lock/vaultwarden-setup.lock" || true

# ═══════════════════════════════════════════════════════════════
# STEP 8 — Remove SOPS binary
# ═══════════════════════════════════════════════════════════════
info "Step 8: Removing SOPS binary..."
if [[ -f /usr/local/bin/sops ]]; then
    rm -f /usr/local/bin/sops && success "Removed /usr/local/bin/sops"
else
    info "/usr/local/bin/sops not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 9 — Remove Docker (packages, APT repo, GPG key)
# ═══════════════════════════════════════════════════════════════
info "Step 9: Removing Docker CE packages..."
if command -v docker &>/dev/null || dpkg -l docker-ce &>/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker-ce-rootless-extras 2>/dev/null \
        && success "Docker packages removed." \
        || warn "Some Docker packages were not installed (that's fine)."
else
    info "Docker packages not detected — skipping."
fi

info "Removing Docker APT repo and GPG key..."
rm -f /etc/apt/sources.list.d/docker.list \
    && success "Removed /etc/apt/sources.list.d/docker.list" || true
rm -f /etc/apt/keyrings/docker.gpg \
    && success "Removed /etc/apt/keyrings/docker.gpg" || true

info "Removing Docker runtime data at /var/lib/docker and /var/lib/containerd..."
rm -rf /var/lib/docker    && success "Removed /var/lib/docker"    || true
rm -rf /var/lib/containerd && success "Removed /var/lib/containerd" || true
rm -rf /etc/docker         && success "Removed /etc/docker"         || true

apt-get update -qq 2>/dev/null || true
apt-get autoremove -y 2>/dev/null && success "apt autoremove done." || true

# ═══════════════════════════════════════════════════════════════
# STEP 10 — Remove installed system packages added by setup.sh
# ═══════════════════════════════════════════════════════════════
info "Step 10: Removing packages installed by setup.sh..."
# Only remove packages not typically pre-installed on a base Ubuntu 24.04 image.
# 'age', 'haveged', 'rclone', 'python3-argon2', 'sysstat' are safe to remove.
# Common tools (curl, wget, git, jq, etc.) are intentionally LEFT in place
# as they are standard and may be relied upon by other things.
EXTRA_PKGS=(age haveged rclone python3-argon2)
for pkg in "${EXTRA_PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$pkg" 2>/dev/null \
            && success "Removed package: $pkg" \
            || warn "Could not remove $pkg"
    fi
done
apt-get autoremove -y 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# STEP 11 — Remove UFW rules added by setup.sh
# ═══════════════════════════════════════════════════════════════
info "Step 11: Removing UFW rules for ports 80 and 443..."
if command -v ufw &>/dev/null; then
    # Delete rules for ports 80 and 443 (both direct and Cloudflare-CIDR rules)
    # Run twice — ufw may have duplicate rules
    ufw delete allow 80/tcp  2>/dev/null || true
    ufw delete allow 443/tcp 2>/dev/null || true
    # Also remove any Cloudflare-CIDR specific rules for port 80/443
    # by re-running delete on numbered rules that match
    while ufw status numbered 2>/dev/null | grep -qE "(80|443)/tcp"; do
        RULE_NUM=$(ufw status numbered 2>/dev/null \
            | grep -E "(80|443)/tcp" \
            | awk -F'[][]' '{print $2}' | head -1)
        [[ -n "$RULE_NUM" ]] \
            && yes | ufw delete "$RULE_NUM" 2>/dev/null || break
    done
    success "UFW port 80/443 rules removed (SSH rules preserved)."
else
    info "ufw not found — skipping firewall cleanup."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 12 — Remove swapfile created by setup.sh
# ═══════════════════════════════════════════════════════════════
info "Step 12: Removing /swapfile..."
if swapon --show 2>/dev/null | grep -q /swapfile; then
    swapoff /swapfile 2>/dev/null && success "Deactivated /swapfile." || warn "swapoff failed."
fi
if [[ -f /swapfile ]]; then
    rm -f /swapfile && success "Removed /swapfile."
else
    info "/swapfile not found — skipping."
fi

# Remove fstab entry for swapfile
if grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
    sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab \
        && success "Removed /swapfile entry from /etc/fstab."
fi

# Remove vm.swappiness entry added by setup.sh
if grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
    sed -i '/^vm\.swappiness/d' /etc/sysctl.conf \
        && success "Removed vm.swappiness from /etc/sysctl.conf."
    sysctl -q vm.swappiness=60 2>/dev/null || true   # restore kernel default
fi

# ═══════════════════════════════════════════════════════════════
# STEP 13 — Remove ubuntu-universe.list if added by setup.sh
# ═══════════════════════════════════════════════════════════════
info "Step 13: Removing ubuntu-universe.list if created by setup.sh..."
if [[ -f /etc/apt/sources.list.d/ubuntu-universe.list ]]; then
    rm -f /etc/apt/sources.list.d/ubuntu-universe.list \
        && success "Removed /etc/apt/sources.list.d/ubuntu-universe.list"
fi
apt-get update -qq 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# STEP 14 — Remove docker group membership for real user
# ═══════════════════════════════════════════════════════════════
info "Step 14: Removing '${REAL_USER}' from docker group..."
if id "$REAL_USER" 2>/dev/null | grep -q '\bdocker\b'; then
    gpasswd -d "$REAL_USER" docker 2>/dev/null \
        && success "Removed ${REAL_USER} from docker group." \
        || warn "Could not remove ${REAL_USER} from docker group."
fi

# Optionally remove the docker group itself if empty
if getent group docker &>/dev/null; then
    DOCKER_GROUP_MEMBERS=$(getent group docker | cut -d: -f4)
    if [[ -z "$DOCKER_GROUP_MEMBERS" ]]; then
        groupdel docker 2>/dev/null && success "Removed empty docker group." || true
    fi
fi

# ═══════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════"
success "Uninstall complete."
echo ""
info "The following were intentionally left untouched:"
info "  • SSH UFW rules (your port)"
info "  • Common tools: curl, wget, git, jq, sqlite3, ufw, gpg, rsync, python3"
info "  • /etc/ssh/sshd_config — no changes made"
echo ""
info "You can now: git clone https://github.com/killer23d/VaultWarden-OCI.git"
echo "════════════════════════════════════════════════════════════"
echo ""
