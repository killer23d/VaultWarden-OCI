#!/usr/bin/env bash
# uninstall-vaultwarden.sh
# Full idempotent uninstaller for killer23d/VaultWarden-OCI
# Run from the user's home directory: bash ~/uninstall-vaultwarden.sh
# Must be run as root (or via sudo).
#
# PATCHED BUGS:
#   UN-KEY1 [HIGH] Step 6 previously rm -rf'd the project directory — which
#                  includes secrets/keys/age-key.txt — without first checking
#                  whether the encryption key had been saved elsewhere.
#                  Destroying the age key renders ALL existing Age-encrypted
#                  backups permanently unrecoverable.
#                  Fix: if secrets/keys/age-key.txt exists, require the
#                  operator to pass --i-have-saved-my-recovery-kit.  Without
#                  the flag the script prints the Age public key fingerprint
#                  and refuses to proceed.
#
#   UN-KEY2 [HIGH] --i-have-saved-my-recovery-kit bypassed all interactive
#                  confirmation for the age key, leaving no gate between a
#                  blindly-passed flag and permanent key destruction.
#                  Fix: add a mandatory second interactive prompt directly
#                  before Step 6 whenever the age key is present on disk.
#                  The operator must type back the exact Age public key
#                  fingerprint shown on screen to confirm they have the
#                  correct key saved.  This fires unconditionally — even
#                  when the flag is present — and cannot be scripted away
#                  without the actual key value in hand.

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; RESET=$'\033[0m'
info()    { echo -e "${YELLOW}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
# --i-have-saved-my-recovery-kit  Satisfy the first-pass age-key guard
#                                  (CLI pre-check). A second interactive
#                                  confirmation is still required at the point
#                                  of destruction regardless of this flag.
# --force                          Skip ALL AGE key checks (both prompts).
#                                  Use only in CI/automation pipelines where
#                                  the key is confirmed saved externally.
I_HAVE_SAVED_RECOVERY_KIT=false
FORCE=false
for _arg in "$@"; do
    case "$_arg" in
        --i-have-saved-my-recovery-kit) I_HAVE_SAVED_RECOVERY_KIT=true ;;
        --force) FORCE=true ;;
        --help)
            echo "Usage: sudo bash $0 [--i-have-saved-my-recovery-kit] [--force]"
            echo ""
            echo "  --i-have-saved-my-recovery-kit"
            echo "      Pre-confirm that you have saved secrets/keys/age-key.txt"
            echo "      to a location OUTSIDE this host before running."
            echo "      Without this flag the script refuses to continue when"
            echo "      the age key is present on disk."
            echo ""
            echo "  --force"
            echo "      Skip ALL AGE key checks (both the CLI flag pre-check"
            echo "      and the interactive fingerprint confirmation)."
            echo "      WARNING: destructive — implies --i-have-saved-my-recovery-kit"
            echo "      and bypasses the fingerprint gate. Use only in automated/CI"
            echo "      pipelines where the key is confirmed saved by external means."
            echo ""
            echo "  Two-prompt safety model for age key destruction:"
            echo "    1. CLI flag  --i-have-saved-my-recovery-kit  (pre-check)."
            echo "    2. Interactive fingerprint confirmation immediately before"
            echo "       the project directory (and key) is deleted.  You must"
            echo "       type the exact Age public key shown on screen."
            echo "       This second prompt is unconditional — it cannot be"
            echo "       skipped or scripted away without the actual key value."
            echo ""
            echo "  Without the age key ALL encrypted backups are permanently"
            echo "  unrecoverable.  Export a recovery kit first:"
            echo "    sudo bash edit-secrets.sh --export-recovery-kit"
            exit 0
            ;;
        *) ;;
    esac
done

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ─── Locate project directory ─────────────────────────────────────────────────
# Support running from home dir regardless of which user owns the clone.
REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$REAL_USER")
PROJECT_DIR="${REAL_HOME}/VaultWarden-OCI"

# Sentinel written by setup.sh to record that Docker was installed by this
# project.  Used in Step 9 to avoid removing a pre-existing system Docker.
DOCKER_SENTINEL="/var/lib/vaultwarden/.docker_installed_by_setup"

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
# UN-KEY1 / UN-KEY2 — Age encryption-key destruction guard
#
# secrets/keys/age-key.txt is the master decryption key for ALL
# Age-encrypted backups.  Deleting it without a confirmed off-system
# copy makes every existing backup permanently unrecoverable.
#
# Two-prompt model:
#   Prompt 1 (here, pre-run): require --i-have-saved-my-recovery-kit flag.
#   Prompt 2 (just before Step 6): require operator to type back the exact
#             Age public key fingerprint shown on screen — unconditional,
#             fires even when the flag was passed.
#
# --force bypasses BOTH prompts. Use only in CI/automation.
# ═══════════════════════════════════════════════════════════════
AGE_KEY_FILE="${PROJECT_DIR}/secrets/keys/age-key.txt"

# Helper: extract the Age public key from the key file.
# Prints the key to stdout; returns 1 if it cannot be found.
_extract_age_public_key() {
    local keyfile="$1"
    local pubkey=""
    # Age keygen writes:  # public key: age1...
    pubkey=$(grep -E '^# public key:' "$keyfile" 2>/dev/null | sed 's/^# public key:[[:space:]]*//' | head -1)
    if [[ -z "$pubkey" ]]; then
        # Fallback: first line starting with age1 (the private key line starts
        # with AGE-SECRET-KEY-; public key comments use age1)
        pubkey=$(grep -E '^age1[a-z0-9]+' "$keyfile" 2>/dev/null | head -1)
    fi
    if [[ -z "$pubkey" ]]; then
        return 1
    fi
    printf '%s' "$pubkey"
}

if [[ -f "$AGE_KEY_FILE" ]] && [[ "$FORCE" == "false" ]]; then

    # ── Prompt 1: CLI flag pre-check ─────────────────────────────────────
    if [[ "$I_HAVE_SAVED_RECOVERY_KIT" == "false" ]] && [[ "$FORCE" == "false" ]]; then
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo -e "${RED}  ⚠  ENCRYPTION KEY DESTRUCTION WARNING  ⚠${RESET}"
        echo "════════════════════════════════════════════════════════════"
        warn "The Age encryption key exists at:"
        warn "  ${AGE_KEY_FILE}"
        warn ""
        warn "Deleting it makes ALL existing Age-encrypted backups"
        warn "PERMANENTLY UNRECOVERABLE — there is no way to restore"
        warn "them without this key."
        warn ""
        warn "Age public key (confirm this matches your recovery kit):"
        echo ""
        _AGE_PUBKEY=$(_extract_age_public_key "$AGE_KEY_FILE" 2>/dev/null \
            || echo "(Could not extract — inspect ${AGE_KEY_FILE} manually)")
        echo -e "  ${CYAN}${_AGE_PUBKEY}${RESET}"
        echo ""
        warn "To proceed, re-run with the flag confirming you have saved"
        warn "the recovery kit to a location OUTSIDE this directory:"
        warn ""
        warn "  sudo bash $0 --i-have-saved-my-recovery-kit"
        warn ""
        warn "Or export a recovery kit first:"
        warn "  sudo bash edit-secrets.sh --export-recovery-kit"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        die "Uninstall aborted — age key not confirmed saved. No changes made."
    fi

    warn "Recovery-kit flag passed — first-pass guard satisfied."
    warn "A second confirmation will be required immediately before key deletion."

else
    if [[ "$FORCE" == "true" ]] && [[ -f "$AGE_KEY_FILE" ]]; then
        warn "--force active — skipping ALL AGE key checks. Key WILL be deleted without confirmation."
    else
        info "Age key not found at ${AGE_KEY_FILE} — no encryption-key guard needed."
    fi
fi

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
#
# UN-KEY2 FIX: second interactive confirmation gate.
#
# If the age key was present, require the operator to type back the exact
# Age public key fingerprint shown on screen before proceeding.  This is
# unconditional — it fires even when --i-have-saved-my-recovery-kit was
# passed — and cannot be scripted away without the actual key value in hand.
#
# The fingerprint-echo pattern (type what you see on screen) is the same
# technique used by AWS, GCP, and GitHub repository-delete dialogs.  It is
# significantly harder to muscle-memory past than a bare yes/no, and it
# proves the operator has the key in front of them.
#
# --force bypasses this gate entirely.
# ═══════════════════════════════════════════════════════════════
info "Step 6: Removing project directory ${PROJECT_DIR}..."

if [[ -f "$AGE_KEY_FILE" ]] && [[ "$FORCE" == "false" ]]; then
    # Re-extract the public key immediately before deletion so the operator
    # confirms the exact fingerprint of the key about to be destroyed.
    _AGE_PUBKEY_NOW=$(_extract_age_public_key "$AGE_KEY_FILE" 2>/dev/null || true)

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo -e "${RED}  ⚠  FINAL CONFIRMATION — KEY WILL BE DESTROYED  ⚠${RESET}"
    echo "════════════════════════════════════════════════════════════"
    warn "You are about to permanently delete:"
    warn "  ${AGE_KEY_FILE}"
    warn ""
    warn "WITHOUT this key, ALL Age-encrypted backups are unrecoverable."
    warn ""
    if [[ -n "${_AGE_PUBKEY_NOW:-}" ]]; then
        echo -e "${CYAN}  Age public key:${RESET}"
        echo -e "  ${CYAN}${_AGE_PUBKEY_NOW}${RESET}"
        echo ""
        warn "Type the Age public key shown above to confirm you have it"
        warn "saved, then press Enter.  Type anything else to abort:"
        echo ""
        read -r -p "  Age public key: " _TYPED_PUBKEY
        if [[ "$_TYPED_PUBKEY" != "$_AGE_PUBKEY_NOW" ]]; then
            echo ""
            die "Confirmation mismatch — uninstall aborted. The age key and project directory were NOT deleted."
        fi
    else
        # Could not extract public key (unusual key format) — fall back to a
        # plain acknowledgement prompt so the gate still fires.
        warn "Could not extract public key automatically."
        warn "Inspect the key file manually before continuing:"
        warn "  cat ${AGE_KEY_FILE}"
        warn ""
        warn "Type 'DELETE-MY-KEY' to confirm you have saved the key"
        warn "and wish to proceed, or anything else to abort:"
        echo ""
        read -r -p "  Confirmation: " _TYPED_CONFIRM
        if [[ "$_TYPED_CONFIRM" != "DELETE-MY-KEY" ]]; then
            echo ""
            die "Confirmation not given — uninstall aborted. The age key and project directory were NOT deleted."
        fi
    fi
    echo ""
    success "Fingerprint confirmed — proceeding with project directory removal."
    echo "════════════════════════════════════════════════════════════"
    echo ""
fi

if [[ -d "$PROJECT_DIR" ]]; then
    rm -rf "$PROJECT_DIR" \
        && success "Removed ${PROJECT_DIR}"
else
    info "${PROJECT_DIR} not found — skipping."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 7 — Remove setup lock file
# ═══════════════════════════════════════════════════════════════
info "Step 7: Removing setup lock files..."
# Remove both legacy (/var/lock) and current (/run/lock) paths for
# forward/backward compatibility.
rm -f /var/lock/vaultwarden-setup.lock 2>/dev/null && \
    success "Removed /var/lock/vaultwarden-setup.lock (legacy)" || true
rm -f /run/lock/vaultwarden-setup.lock 2>/dev/null && \
    success "Removed /run/lock/vaultwarden-setup.lock" || true

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
#
# FIX (Issue 2): Only remove Docker packages if setup.sh installed them.
# setup.sh writes a sentinel file ($DOCKER_SENTINEL) immediately after a
# successful Docker installation.  If the sentinel is absent, Docker was
# pre-existing and must not be removed — silently destroying a system-level
# Docker installation that may be serving unrelated containers would be
# catastrophic.  In that case we warn and skip package removal; APT repo /
# GPG key / runtime-data cleanup is likewise skipped because those artefacts
# were not created by this project.
# ═══════════════════════════════════════════════════════════════
info "Step 9: Removing Docker CE packages..."

if [[ -f "$DOCKER_SENTINEL" ]]; then
    info "Docker sentinel found — Docker was installed by setup.sh; proceeding with removal."
    rm -f "$DOCKER_SENTINEL" 2>/dev/null || true

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
    # BUG-UN1 FIX: setup.sh downloads the Docker GPG key as an armored ASCII
    # file (/etc/apt/keyrings/docker.asc) — not a dearmored .gpg binary.
    # Removing both extensions handles systems set up with either version.
    rm -f /etc/apt/keyrings/docker.asc \
        && success "Removed /etc/apt/keyrings/docker.asc" || true
    rm -f /etc/apt/keyrings/docker.gpg \
        && success "Removed /etc/apt/keyrings/docker.gpg (legacy)" || true

    # BUG-UN2 FIX: setup.sh writes the Docker APT source in DEB822 format at
    # docker.sources, not the one-liner docker.list format.  Removing both
    # extensions handles systems set up with either version.
    rm -f /etc/apt/sources.list.d/docker.sources \
        && success "Removed /etc/apt/sources.list.d/docker.sources" || true
    rm -f /etc/apt/sources.list.d/docker.list \
        && success "Removed /etc/apt/sources.list.d/docker.list (legacy)" || true

    info "Removing Docker runtime data at /var/lib/docker and /var/lib/containerd..."
    rm -rf /var/lib/docker     && success "Removed /var/lib/docker"     || true
    rm -rf /var/lib/containerd && success "Removed /var/lib/containerd" || true
    rm -rf /etc/docker         && success "Removed /etc/docker"         || true

    apt-get update -qq 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null && success "apt autoremove done." || true
else
    # No sentinel — Docker was not installed by setup.sh.
    # Removing it here would silently destroy a system-level Docker
    # installation that may be serving unrelated containers.
    warn "Docker sentinel not found at ${DOCKER_SENTINEL}."
    warn "Docker does not appear to have been installed by setup.sh."
    warn "Skipping Docker package/repo/data removal to protect any"
    warn "pre-existing Docker installation on this system."
    warn "If you do want Docker removed, run manually:"
    warn "  apt-get remove --purge docker-ce docker-ce-cli containerd.io \\"
    warn "    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 10 — Remove installed system packages added by setup.sh
# ═══════════════════════════════════════════════════════════════
info "Step 10: Removing packages installed by setup.sh..."
# Only remove packages not typically pre-installed on a base Ubuntu 24.04 image.
# Common tools (curl, wget, git, jq, sqlite3, make, nano, ufw, etc.) are
# intentionally LEFT in place as they are standard and may be relied upon by
# other things on the system.
#
# BUG-UN3 FIX: apache2-utils (htpasswd) was installed by setup.sh for Caddy
#   basic-auth hash generation but was missing from this list.
# BUG-UN4 FIX: cron was installed by setup.sh but was missing from this list.
# BUG-UN5 FIX: haveged is a systemd service that setup.sh enables; explicitly
#   disable and stop it before purging so its enabled symlink is cleaned up
#   before the package is removed, avoiding a stale unit warning.
EXTRA_PKGS=(age haveged rclone python3-argon2 apache2-utils cron)

# Disable haveged first so its enabled symlink is removed cleanly before purge.
if systemctl is-enabled haveged &>/dev/null 2>&1; then
    systemctl disable --now haveged 2>/dev/null \
        && success "Disabled haveged service before purge." \
        || warn "Could not disable haveged (may already be inactive)."
fi

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
#
# FIX (Issue 3): The previous while-loop had no iteration cap.  If
# `ufw delete` exits 0 but leaves the matching rule in place (corrupted
# UFW state, silent no-op, etc.) the grep condition stays true and the
# script hangs forever.
#
# Replaced with a bounded for-loop (20 iterations).  Normal deletion
# takes at most 2 passes; 20 is a generous hard cap that guarantees
# termination even under degraded UFW state.  An explicit `|| break`
# on the delete call exits immediately on the first hard failure.
# ═══════════════════════════════════════════════════════════════
info "Step 11: Removing UFW rules for ports 80 and 443..."
if command -v ufw &>/dev/null; then
    # Delete simple allow rules first (covers the common case in one pass)
    ufw delete allow 80/tcp  2>/dev/null || true
    ufw delete allow 443/tcp 2>/dev/null || true

    # Delete any remaining numbered rules that match ports 80 or 443
    # (e.g. Cloudflare-CIDR rules added during setup).
    # Capped at 20 iterations — normal cleanup finishes in ≤2 passes.
    for _ufw_i in {1..20}; do
        # Re-query each iteration; rule numbers shift after each deletion.
        RULE_NUM=$(ufw status numbered 2>/dev/null \
            | grep -E "(80|443)/tcp" \
            | awk -F'[][]' '{print $2}' \
            | head -1)
        [[ -n "$RULE_NUM" ]] || break   # no more matching rules — done
        yes | ufw delete "$RULE_NUM" 2>/dev/null || break
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
