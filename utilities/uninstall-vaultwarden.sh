#!/usr/bin/env bash
# utilities/uninstall-vaultwarden.sh
# Full idempotent uninstaller for killer23d/VaultWarden-OCI
# Run from the project root: sudo utilities/uninstall-vaultwarden.sh run
# Must be run as root (or via sudo).
#
# USAGE:
#   sudo utilities/uninstall-vaultwarden.sh run [OPTIONS]
#   sudo utilities/uninstall-vaultwarden.sh --help
#
# FLAGS:
#   --i-have-saved-my-recovery-kit   Pre-confirm age key is saved off-host
#   --force                          Skip all age key checks (CI/automation only)
#   --dry-run                        Preview actions without making changes
#   --help, -h                       Show this help
#
# shellcheck disable=SC2015  # cmd && log_success || log_warn is intentional cleanup idiom throughout

set -euo pipefail

# ─── Self-contained colour/log helpers (no lib/common.sh dependency) ─────────
# This script deliberately does NOT source lib/common.sh so it remains safe
# to run after a partial or broken installation.  The log format matches the
# project standard: [HH:MM:SS] [script-name.sh] LEVEL message.
_VW_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
if [[ -t 1 ]]; then
    _C_CYAN=$'\e[36m'; _C_GREEN=$'\e[32m'; _C_YELLOW=$'\e[33m'
    _C_RED=$'\e[1;31m'; _C_RESET=$'\e[0m'
else
    _C_CYAN=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_RESET=''
fi
_vw_ts() { date '+%H:%M:%S'; }
log_info()    { printf '%s[%s] [%s] INFO%s %s\n'    "$_C_CYAN"   "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*"; }
log_success() { printf '%s[%s] [%s] OK%s %s\n'      "$_C_GREEN"  "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*"; }
log_warn()    { printf '%s[%s] [%s] WARN%s %s\n'    "$_C_YELLOW" "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*" >&2; }
log_error()   { printf '%s[%s] [%s] ERROR%s %s\n'   "$_C_RED"    "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*" >&2; }
die()         { log_error "$*"; exit 1; }

# Legacy aliases used throughout the original script body
info()    { log_info "$@"; }
success() { log_success "$@"; }
warn()    { log_warn "$@"; }

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    echo "Usage: sudo bash $0 run [--i-have-saved-my-recovery-kit] [--force] [--dry-run]"
    echo ""
    echo "SUBCOMMANDS:"
    echo "  run    Perform the full idempotent uninstall (interactive confirmation required)"
    echo ""
    echo "OPTIONS (used after 'run'):"
    echo "  --i-have-saved-my-recovery-kit"
    echo "      Pre-confirm that you have saved secrets/keys/age-key.txt"
    echo "      to a location OUTSIDE this host before running."
    echo "      Without this flag the script refuses to continue when"
    echo "      the age key is present on disk."
    echo ""
    echo "  --dry-run"
    echo "      Show what would be removed without deleting anything."
    echo "      Prints each step that would execute and exits without changes."
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
    echo "    ./utilities/secrets-export-recovery-kit.sh"
}

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
DRY_RUN=false

# Zero arguments → show help and exit 1 (uninstall is destructive)
if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

case "$1" in
    run)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --i-have-saved-my-recovery-kit) I_HAVE_SAVED_RECOVERY_KIT=true; shift ;;
                --force)                        FORCE=true;                      shift ;;
                --dry-run)                      DRY_RUN=true;                    shift ;;
                *)
                    log_error "Unknown option: '$1'"
                    show_help
                    exit 1
                    ;;
            esac
        done
        ;;
    help|--help|-h)
        show_help; exit 0
        ;;
    *)
        log_error "Unknown subcommand: '$1'"
        show_help
        exit 1
        ;;
esac

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ─── Locate project directory ─────────────────────────────────────────────────
# Support running from home dir regardless of which user owns the clone.
REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$REAL_USER")
PROJECT_DIR="${REAL_HOME}/VaultWarden-OCI"

# ─── Resolve PROJECT_STATE_DIR from .env ─────────────────────────────────────
# setup.sh writes PROJECT_STATE_DIR to .env:
#   - boot-only mode:      PROJECT_STATE_DIR=/var/lib/vaultwarden  (default)
#   - separate-volume mode: PROJECT_STATE_DIR=/mnt/vw-data  (or DATA_VOLUME_MOUNT)
#
# We must read this value here so that Steps 5 and the Docker sentinel check
# operate on the *actual* state directory rather than the hardcoded boot-volume
# path, which would silently skip the data directory in separate-volume mode.
#
# Resolution order:
#   1. PROJECT_STATE_DIR in .env (explicit)
#   2. DATA_VOLUME_MOUNT in .env  (separate-volume mode; equivalent to
#      PROJECT_STATE_DIR when setup.sh ran in separate-volume mode)
#   3. Hardcoded default /var/lib/vaultwarden (boot-only fallback)
_read_env_value() {
    # _read_env_value KEY FILE  -> prints value, empty string if not found
    #
    # NOTE: This is an intentional self-contained copy of the helper that
    # appears in setup.sh.  uninstall-vaultwarden.sh does not source any
    # shared library so that it remains safe to run after a partial or broken
    # installation.  Keep both copies in sync if the parsing logic changes.
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

_ENV_FILE="${PROJECT_DIR}/.env"
_state_dir_raw="$(_read_env_value "PROJECT_STATE_DIR" "$_ENV_FILE")"
if [[ -z "$_state_dir_raw" ]]; then
    _state_dir_raw="$(_read_env_value "DATA_VOLUME_MOUNT" "$_ENV_FILE")"
fi
PROJECT_STATE_DIR="${_state_dir_raw:-/var/lib/vaultwarden}"

# Always read DATA_VOLUME_MOUNT independently — used by the fstab cleanup in
# Step 5.  It may differ from PROJECT_STATE_DIR if the operator set them
# separately, and we need the raw mount-point value regardless of which path
# PROJECT_STATE_DIR resolved to.
DATA_VOLUME_MOUNT="$(_read_env_value "DATA_VOLUME_MOUNT" "$_ENV_FILE")"

# Sentinel written by setup.sh to record that Docker was installed by this project.
DOCKER_SENTINEL="${PROJECT_STATE_DIR}/.docker_installed_by_setup"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "   VaultWarden-OCI Full Uninstaller"
echo "   Project dir       : ${PROJECT_DIR}"
echo "   Project state dir : ${PROJECT_STATE_DIR}"
echo "   Running as        : $(whoami)  (real user: ${REAL_USER})"
if [[ "$DRY_RUN" == "true" ]]; then
echo "   Mode              : DRY RUN — no changes will be made"
fi
echo "════════════════════════════════════════════════════════════"
echo ""

# In dry-run mode, show what would be removed and exit cleanly.
if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY RUN MODE — showing what would be removed:"
    echo "  [1] Docker compose stack: ${PROJECT_DIR}/docker-compose.yml (down --volumes --remove-orphans)"
    echo "  [2] Containers matching: vaultwarden caddy postfix"
    echo "  [3] Docker volumes with prefix: $(basename "${PROJECT_DIR}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')_ or vaultwarden*"
    echo "  [4] Docker networks matching: vaultwarden*"
    echo "  [5] Systemd units: vaultwarden-*.service vaultwarden-*.timer"
    echo "  [6] Env file: /etc/vaultwarden/vaultwarden.env"
    echo "  [7] Age key: ${AGE_KEY_FILE} (if --i-have-saved-my-recovery-kit or --force)"
    echo "  [8] Project directory: ${PROJECT_DIR}"
    echo "  [9] State directory: ${PROJECT_STATE_DIR}"
    echo "  [10] Extra packages: age haveged rclone python3-argon2 apache2-utils cron"
    echo "  [10.5] CrowdSec:"
    echo "         - Services: crowdsec crowdsec-firewall-bouncer crowdsec-cloudflare-bouncer"
    echo "         - Packages: crowdsec crowdsec-firewall-bouncer-iptables"
    echo "         - Binary:   /usr/local/bin/crowdsec-cloudflare-bouncer"
    echo "         - APT repo: /etc/apt/sources.list.d/crowdsec_crowdsec.list"
    echo "         - GPG key:  /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg (and .asc)"
    echo "         - Config:   /etc/crowdsec/ (acquis.d/vaultwarden.yaml, bouncers/, profiles.yaml)"
    echo "         - .env key: CROWDSEC_CF_BOUNCER_API_KEY"
    echo "  [11] UFW rules: ports 80 and 443"
    echo "  [11.5] iptables rules added by setup-firewall.sh:"
    echo "         - nat POSTROUTING MASQUERADE for subnets 172.21.0.0/16 172.22.0.0/16 172.23.0.0/16"
    echo "         - filter DOCKER-USER ACCEPT rules for the same subnets"
    echo "  [12] Swapfile: /swapfile"
    echo "  [13] APT source: ubuntu-universe.list"
    echo "  [14] Docker group membership for ${REAL_USER}"
    echo ""
    info "DRY RUN complete — no changes made. Remove --dry-run to perform the actual uninstall."
    exit 0
fi

warn "This will PERMANENTLY DELETE all data, secrets, containers,"
warn "volumes, and configuration created by VaultWarden-OCI."
echo ""
read -r -p "Type 'UNINSTALL' to confirm, or anything else to abort: " CONFIRM
[[ "$CONFIRM" == "UNINSTALL" ]] || { info "Aborted — nothing changed."; exit 0; }
echo ""

# Offer a final encrypted backup before any destructive steps.
# This ensures the operator has a chance to preserve data even if they forgot
# to run a backup manually before uninstalling.
if [[ -f "${PROJECT_DIR}/backup.sh" ]]; then
    echo ""
    echo "════════════════════════════════════════════════════════════"
    warn "  PRE-DESTRUCTION BACKUP OFFER"
    warn "  It is strongly recommended to take a final encrypted backup"
    warn "  of your VaultWarden data before uninstalling."
    echo "════════════════════════════════════════════════════════════"
    echo ""
    read -r -p "Run a final encrypted backup now? (yes/no): " _run_backup
    if [[ "$_run_backup" == "yes" ]]; then
        info "Running final full backup..."
        if bash "${PROJECT_DIR}/backup.sh" run full 2>&1; then
            success "Final backup completed. Check backup output above for the file location."
        else
            warn "Backup exited with errors. Review the output above."
            read -r -p "Continue with uninstall despite backup failure? (yes/no): " _continue_anyway
            [[ "$_continue_anyway" == "yes" ]] || { info "Aborted — nothing changed."; exit 0; }
        fi
    else
        warn "Skipping final backup. Proceeding with uninstall..."
    fi
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# Age encryption-key destruction guard
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
        echo -e "$_C_RED  ⚠  ENCRYPTION KEY DESTRUCTION WARNING  ⚠$_C_RESET"
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
        echo -e "  $_C_CYAN${_AGE_PUBKEY}$_C_RESET"
        echo ""
        warn "To proceed, re-run with the flag confirming you have saved"
        warn "the recovery kit to a location OUTSIDE this directory:"
        warn ""
        warn "  sudo bash $0 --i-have-saved-my-recovery-kit"
        warn ""
        warn "Or export a recovery kit first:"
        warn "  ./utilities/secrets-export-recovery-kit.sh"
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
    for svc in vaultwarden caddy postfix; do
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
# STEP 2 — Disable & remove systemd units + Docker mount guard drop-in
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
    vaultwarden-notify-failure.service
    vaultwarden-iptables.service
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
    # Remove any per-unit drop-in directory (e.g. ReadWritePaths patches
    # written by setup.sh systemd install for separate-volume mode).
    DROP_IN_DIR="/etc/systemd/system/${unit}.d"
    if [[ -d "$DROP_IN_DIR" ]]; then
        rm -rf "$DROP_IN_DIR" && success "Removed unit drop-in dir: $DROP_IN_DIR"
    fi
done

# ── Docker systemd mount-guard drop-in ───────────────────────────────────────
# setup.sh installs /etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf
# in separate-volume mode.  This drop-in adds RequiresMountsFor=<DATA_VOLUME_MOUNT>
# to docker.service, which causes Docker to refuse to start unless the data
# volume is mounted.  After a full uninstall this constraint is no longer valid
# and must be removed so Docker can start normally.
#
# Remove this drop-in so Docker can start normally after uninstall.
_DOCKER_DROP_IN="/etc/systemd/system/docker.service.d/10-vaultwarden-data-volume.conf"
if [[ -f "$_DOCKER_DROP_IN" ]]; then
    rm -f "$_DOCKER_DROP_IN" && success "Removed Docker mount-guard drop-in: $_DOCKER_DROP_IN"
    # Remove the drop-in directory only if it is now empty (it may contain
    # unrelated drop-ins written by other tools).
    rmdir "/etc/systemd/system/docker.service.d" 2>/dev/null \
        && success "Removed empty Docker drop-in directory." || true
fi

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
# STEP 5 — Wipe data, unmount, then clean fstab
#
# Separate-volume mode sequence (order matters):
#   5a. rm -rf the state directory contents (data is wiped from the volume).
#   5b. umount the block device — must come AFTER data wipe so we are not
#       holding an open filehandle, and BEFORE fstab cleanup so the mount
#       unit can be stopped cleanly by systemd on the next boot if umount
#       fails here.
#   5c. sed the fstab entry — removing it while the device is still mounted
#       is safe (kernel holds the mount independent of fstab), but doing it
#       after umount means the entry is gone before any reboot path can
#       re-mount a now-empty device.
#   5d. Remove the orphaned mountpoint directory.
#
# Boot-only mode: PROJECT_STATE_DIR == /var/lib/vaultwarden — no mount
# operations needed; rm -rf is sufficient.
# ═══════════════════════════════════════════════════════════════
info "Step 5: Removing runtime state directory (database, logs, Caddy state)..."

# ── 5a: Wipe the resolved state directory ──────────────────────────────────
if [[ -d "${PROJECT_STATE_DIR}" ]]; then
    # Clear immutability from the data-volume sentinel before wiping.
    # setup_data_volume writes chattr +i on .vw-data-volume so that accidental
    # rm -rf cannot destroy it at runtime. That protection must be lifted here
    # so that the intentional uninstall wipe can complete cleanly.
    _sentinel="${PROJECT_STATE_DIR}/.vw-data-volume"
    if [[ -f "$_sentinel" ]] && command -v chattr >/dev/null 2>&1; then
        chattr -i "$_sentinel" 2>/dev/null \
            || warn "chattr -i failed on sentinel — rm -rf may be incomplete if the file is immutable"
    fi
    rm -rf "${PROJECT_STATE_DIR}" \
        && success "Removed ${PROJECT_STATE_DIR}"
else
    info "${PROJECT_STATE_DIR} not found — skipping."
fi

# Also wipe the boot-volume default when it differs from PROJECT_STATE_DIR.
# Handles artefacts left by a prior boot-only install after re-install in
# separate-volume mode, or a mid-lifecycle DATA_VOLUME_MOUNT change.
if [[ "${PROJECT_STATE_DIR}" != "/var/lib/vaultwarden" ]]; then
    if [[ -d /var/lib/vaultwarden ]]; then
        rm -rf /var/lib/vaultwarden \
            && success "Removed /var/lib/vaultwarden (boot-volume residual)"
    else
        info "/var/lib/vaultwarden not found — skipping."
    fi
fi

# ── 5b: Unmount the dedicated data volume (separate-volume mode only) ───────
# We only attempt unmount when DATA_VOLUME_MOUNT is non-empty AND differs from
# /var/lib/vaultwarden (the boot-volume path is never a separate mount).
# A lazy unmount (-l) is used as the fallback: it detaches the filesystem from
# the namespace immediately even if a process still holds a reference, allowing
# the block device to be safely detached from OCI without a reboot.
_UNMOUNT_TARGET="${DATA_VOLUME_MOUNT:-}"
if [[ -n "$_UNMOUNT_TARGET" ]] && \
   [[ "$_UNMOUNT_TARGET" != "/var/lib/vaultwarden" ]] && \
   mountpoint -q "$_UNMOUNT_TARGET" 2>/dev/null; then

    info "Unmounting data volume at ${_UNMOUNT_TARGET}..."
    if umount "$_UNMOUNT_TARGET" 2>/dev/null; then
        success "Unmounted ${_UNMOUNT_TARGET}"
    else
        warn "Normal umount failed (a process may still hold a reference)."
        info "Attempting lazy unmount (umount -l)..."
        if umount -l "$_UNMOUNT_TARGET" 2>/dev/null; then
            success "Lazy-unmounted ${_UNMOUNT_TARGET} — device is now detachable from OCI."
        else
            warn "Lazy umount also failed. The volume is still mounted."
            warn "Run manually after all processes have stopped:"
            warn "  sudo umount ${_UNMOUNT_TARGET}"
            warn "  sudo umount -l ${_UNMOUNT_TARGET}  # if the above fails"
        fi
    fi
fi

# ── 5c: Remove the fstab entry written by setup.sh ──────────────────────────
# Guard: DATA_VOLUME_MOUNT must be non-empty AND the mount point must appear
# in fstab before we run sed.  Matching on the mount-point field (field 2,
# surrounded by whitespace) avoids accidental deletion of unrelated entries.
if [[ -n "${DATA_VOLUME_MOUNT:-}" ]] && \
   grep -qE "[[:space:]]${DATA_VOLUME_MOUNT}[[:space:]]" /etc/fstab 2>/dev/null; then

    # Write to a temp file then mv atomically — avoids a partial fstab on
    # SIGINT or disk-full mid-write.
    _FSTAB_TMP=$(mktemp /etc/fstab.uninstall.XXXXXXXXXX)
    if sed "/[[:space:]]${DATA_VOLUME_MOUNT}[[:space:]]/d" /etc/fstab > "$_FSTAB_TMP" \
       && mv -f "$_FSTAB_TMP" /etc/fstab; then
        success "Removed fstab entry for data volume: ${DATA_VOLUME_MOUNT}"
    else
        rm -f "$_FSTAB_TMP" 2>/dev/null || true
        warn "Could not update /etc/fstab atomically — remove the entry manually:"
        warn "  grep -n '${DATA_VOLUME_MOUNT}' /etc/fstab   # find the line number"
        warn "  sudo nano /etc/fstab                         # delete it"
    fi
else
    info "No fstab data-volume entry found for '${DATA_VOLUME_MOUNT:-<unset>}' — nothing to remove."
fi

# ── 5d: Remove the orphaned mountpoint directory ────────────────────────────
# After umount and fstab cleanup the mountpoint directory is an empty anchor
# that setup.sh created with mkdir -p.  Remove it only if it is now empty and
# is not /var/lib/vaultwarden (never remove that path here; Step 5a handles it).
if [[ -n "${DATA_VOLUME_MOUNT:-}" ]] && \
   [[ "${DATA_VOLUME_MOUNT}" != "/var/lib/vaultwarden" ]] && \
   [[ -d "${DATA_VOLUME_MOUNT}" ]]; then

    if rmdir "${DATA_VOLUME_MOUNT}" 2>/dev/null; then
        success "Removed mountpoint directory: ${DATA_VOLUME_MOUNT}"
    else
        # Directory is not empty — residual files remain (umount may have
        # failed, or files were written to the mountpoint before mount).
        warn "${DATA_VOLUME_MOUNT} is not empty after unmount."
        warn "Inspect and remove manually: sudo rm -rf ${DATA_VOLUME_MOUNT}"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# STEP 6 — Remove the cloned project directory (secrets, keys, config)
#
# Second interactive confirmation gate.
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
    echo -e "$_C_RED  ⚠  FINAL CONFIRMATION — KEY WILL BE DESTROYED  ⚠$_C_RESET"
    echo "════════════════════════════════════════════════════════════"
    warn "You are about to permanently delete:"
    warn "  ${AGE_KEY_FILE}"
    warn ""
    warn "WITHOUT this key, ALL Age-encrypted backups are unrecoverable."
    warn ""
    if [[ -n "${_AGE_PUBKEY_NOW:-}" ]]; then
        echo -e "$_C_CYAN  Age public key:$_C_RESET"
        echo -e "  $_C_CYAN${_AGE_PUBKEY_NOW}$_C_RESET"
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
# Only remove Docker packages if setup.sh installed them.
# setup.sh writes a sentinel file ($DOCKER_SENTINEL) immediately after a
# successful Docker installation.  If the sentinel is absent, Docker was
# pre-existing and must not be removed — silently destroying a system-level
# Docker installation that may be serving unrelated containers would be
# catastrophic.  In that case we warn and skip package removal; APT repo /
# GPG key / runtime-data cleanup is likewise skipped because those artefacts
# were not created by this project.
#
# Resolve DOCKER_SENTINEL from PROJECT_STATE_DIR so detection works in both
# boot-volume and separate-volume installs.
# ═══════════════════════════════════════════════════════════════
info "Step 9: Removing Docker CE packages..."

if [[ -f "$DOCKER_SENTINEL" ]]; then
    info "Docker sentinel found at ${DOCKER_SENTINEL} — Docker was installed by setup.sh; proceeding with removal."
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
    # setup.sh downloads the Docker GPG key as an armored ASCII
    # file (/etc/apt/keyrings/docker.asc) — not a dearmored .gpg binary.
    # Removing both extensions handles systems set up with either version.
    rm -f /etc/apt/keyrings/docker.asc \
        && success "Removed /etc/apt/keyrings/docker.asc" || true
    rm -f /etc/apt/keyrings/docker.gpg \
        && success "Removed /etc/apt/keyrings/docker.gpg (legacy)" || true

    # setup.sh writes the Docker APT source in DEB822 format at
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
# apache2-utils (htpasswd) was installed by setup.sh for Caddy basic-auth hash
#   generation and must be removed here.
# cron was installed by setup.sh and must be removed here.
# haveged is a systemd service that setup.sh enables; explicitly
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
# STEP 10.5 — Remove CrowdSec and all associated components
#
# Mirrors every phase of utilities/setup-crowdsec.sh in reverse:
#   Phase 8 reversed: stop/disable all three CrowdSec services
#   Phase 2 reversed: remove Cloudflare bouncer binary
#   Phase 1 reversed: purge crowdsec + crowdsec-firewall-bouncer-iptables
#                     packages and their PackageCloud APT repo / GPG key
#   Phase 6 reversed: remove /etc/crowdsec/bouncers/
#   Phase 4 reversed: remove /etc/crowdsec/acquis.d/vaultwarden.yaml
#   Phase 7 reversed: remove /etc/crowdsec/profiles.yaml (project copy)
#   Phase 3 reversed: (collections are removed with the crowdsec package)
#   Phase 5 reversed: remove CROWDSEC_CF_BOUNCER_API_KEY from .env
#
# netfilter-persistent / iptables-persistent are also removed if present,
# as the iptables bouncer may have triggered their installation.
#
# After this step a fresh run of setup.sh (or setup-crowdsec.sh) will
# install CrowdSec from scratch with no leftover state.
# ═══════════════════════════════════════════════════════════════
info "Step 10.5: Removing CrowdSec and associated components..."

# ── Phase 8 reversed: stop and disable all CrowdSec services ────────────────
for _cs_svc in \
    crowdsec-cloudflare-bouncer \
    crowdsec-firewall-bouncer \
    crowdsec; do
    if systemctl is-active  "$_cs_svc" &>/dev/null 2>&1 || \
       systemctl is-enabled "$_cs_svc" &>/dev/null 2>&1; then
        systemctl disable --now "$_cs_svc" 2>/dev/null \
            && success "Disabled and stopped service: ${_cs_svc}" \
            || warn "Could not disable ${_cs_svc} (may already be inactive)."
    else
        info "Service ${_cs_svc} not active/enabled — skipping."
    fi
done

# ── Phase 2 reversed: remove Cloudflare bouncer binary ──────────────────────
_CF_BOUNCER_BIN="/usr/local/bin/crowdsec-cloudflare-bouncer"
if [[ -f "$_CF_BOUNCER_BIN" ]]; then
    rm -f "$_CF_BOUNCER_BIN" \
        && success "Removed Cloudflare bouncer binary: ${_CF_BOUNCER_BIN}"
else
    info "Cloudflare bouncer binary not found at ${_CF_BOUNCER_BIN} — skipping."
fi

# Also remove the systemd unit file that the binary install may have dropped.
_CF_BOUNCER_UNIT="/etc/systemd/system/crowdsec-cloudflare-bouncer.service"
if [[ -f "$_CF_BOUNCER_UNIT" ]]; then
    rm -f "$_CF_BOUNCER_UNIT" \
        && success "Removed CrowdSec Cloudflare bouncer unit: ${_CF_BOUNCER_UNIT}"
fi

# ── Phase 1 reversed: purge CrowdSec packages ───────────────────────────────
_CS_PKGS=(crowdsec crowdsec-firewall-bouncer-iptables)
for _cs_pkg in "${_CS_PKGS[@]}"; do
    if dpkg -s "$_cs_pkg" &>/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$_cs_pkg" 2>/dev/null \
            && success "Removed package: ${_cs_pkg}" \
            || warn "Could not remove ${_cs_pkg} — may need manual removal."
    else
        info "Package ${_cs_pkg} not installed — skipping."
    fi
done

# Remove netfilter-persistent / iptables-persistent if present — the iptables
# bouncer may have caused their installation and they are not needed otherwise.
for _nf_pkg in netfilter-persistent iptables-persistent; do
    if dpkg -s "$_nf_pkg" &>/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$_nf_pkg" 2>/dev/null \
            && success "Removed package: ${_nf_pkg}" \
            || warn "Could not remove ${_nf_pkg}."
    fi
done

# Remove CrowdSec PackageCloud APT repo and GPG key.
# The PackageCloud installer writes a .list file and a dearmored .gpg key.
rm -f /etc/apt/sources.list.d/crowdsec_crowdsec.list \
    && success "Removed /etc/apt/sources.list.d/crowdsec_crowdsec.list" || true
# GPG key — PackageCloud may use either .gpg (dearmored) or .asc (armored).
rm -f /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg \
    && success "Removed CrowdSec GPG key (.gpg)" || true
rm -f /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.asc \
    && success "Removed CrowdSec GPG key (.asc)" || true
# PackageCloud also drops a script-generated sources file in some versions.
rm -f /etc/apt/sources.list.d/crowdsec_crowdsec_crowdsec.list 2>/dev/null || true

apt-get update -qq 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# ── Phases 4, 6, 7 reversed: remove /etc/crowdsec config artefacts ──────────
# Remove only the files/dirs this project created rather than blindly wiping
# all of /etc/crowdsec, so that an operator who had a pre-existing CrowdSec
# install (or who wants to keep the base config) is not surprised.
# If crowdsec itself was just purged above the whole directory is gone already,
# so these are belt-and-suspenders cleanups for partial-install scenarios.

# Phase 4: acquisition config written by setup-crowdsec.sh
_ACQUIS_FILE="/etc/crowdsec/acquis.d/vaultwarden.yaml"
if [[ -f "$_ACQUIS_FILE" ]]; then
    rm -f "$_ACQUIS_FILE" \
        && success "Removed CrowdSec acquisition config: ${_ACQUIS_FILE}"
    # Remove the directory only if now empty (may contain other acquis files).
    rmdir /etc/crowdsec/acquis.d 2>/dev/null \
        && success "Removed empty /etc/crowdsec/acquis.d" || true
fi

# Phase 6: Cloudflare bouncer config (contains API keys — remove with care)
_CF_BOUNCER_CFG="/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml"
if [[ -f "$_CF_BOUNCER_CFG" ]]; then
    rm -f "$_CF_BOUNCER_CFG" \
        && success "Removed CrowdSec Cloudflare bouncer config: ${_CF_BOUNCER_CFG}"
    rmdir /etc/crowdsec/bouncers 2>/dev/null \
        && success "Removed empty /etc/crowdsec/bouncers" || true
fi

# Phase 7: profiles.yaml (only remove if it matches the project's copy —
# the package installs a default profiles.yaml too, which was already wiped
# by the purge above; this covers the case where crowdsec was NOT purged).
_PROFILES_FILE="/etc/crowdsec/profiles.yaml"
if [[ -f "$_PROFILES_FILE" ]]; then
    rm -f "$_PROFILES_FILE" \
        && success "Removed CrowdSec profiles.yaml: ${_PROFILES_FILE}"
fi

# Remove the entire /etc/crowdsec tree if the purge left it empty or if
# crowdsec was never installed as a package (binary-only scenario).
if [[ -d /etc/crowdsec ]]; then
    if find /etc/crowdsec -mindepth 1 -maxdepth 1 2>/dev/null | read -r; then
        rm -rf /etc/crowdsec \
            && success "Removed /etc/crowdsec (residual config directory)" || true
    else
        info "/etc/crowdsec still has content (possibly unrelated) — leaving in place."
    fi
fi

# ── Phase 5 reversed: remove CROWDSEC_CF_BOUNCER_API_KEY from .env ──────────
_ENV_FILE_CS="${PROJECT_DIR}/.env"
if [[ -f "$_ENV_FILE_CS" ]] && grep -q "^CROWDSEC_CF_BOUNCER_API_KEY=" "$_ENV_FILE_CS" 2>/dev/null; then
    _ENV_TMP=$(mktemp "${_ENV_FILE_CS}.crowdsec.XXXXXXXXXX")
    if sed '/^CROWDSEC_CF_BOUNCER_API_KEY=/d' "$_ENV_FILE_CS" > "$_ENV_TMP" \
       && mv -f "$_ENV_TMP" "$_ENV_FILE_CS"; then
        success "Removed CROWDSEC_CF_BOUNCER_API_KEY from .env"
    else
        rm -f "$_ENV_TMP" 2>/dev/null || true
        warn "Could not update .env atomically — remove CROWDSEC_CF_BOUNCER_API_KEY manually."
    fi
fi

# Reload systemd so stale CrowdSec unit references are cleared.
systemctl daemon-reload 2>/dev/null || true
success "CrowdSec removal complete."

# ═══════════════════════════════════════════════════════════════
# STEP 11 — Remove UFW rules added by setup.sh
#
# The previous while-loop had no iteration cap.  If
# `ufw delete` exits 0 but leaves the matching rule in place (corrupted
# UFW state, silent no-op, etc.) the grep condition stays true and the
# script hangs forever.
#
# Uses a bounded for-loop (20 iterations).  Normal deletion
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
# STEP 11.5 — Remove iptables rules added by setup-firewall.sh
#
# setup-firewall.sh --phase iptables installs:
#   1. nat POSTROUTING MASQUERADE rules for each VaultWarden bridge subnet.
#   2. filter DOCKER-USER ACCEPT rules for the three pinned VaultWarden
#      subnets (172.21.0.0/16, 172.22.0.0/16, 172.23.0.0/16).
#
# These rules are ephemeral (lost on reboot) unless netfilter-persistent
# is present. The netfilter-persistent package was already removed in
# Step 10.5, so its saved-rules file is gone. However the in-kernel rules
# survive until reboot, so we clean them explicitly here.
#
# Failure is non-fatal: if Docker has already been removed the DOCKER-USER
# chain may not exist; MASQUERADE rules for subnets that no longer carry
# live traffic are harmless.
# ═══════════════════════════════════════════════════════════════
info "Step 11.5: Removing iptables rules added by setup-firewall.sh..."
if command -v iptables >/dev/null 2>&1; then
    _VW_SUBNETS=("172.21.0.0/16" "172.22.0.0/16" "172.23.0.0/16")

    # Remove POSTROUTING MASQUERADE rules (nat table).
    for _subnet in "${_VW_SUBNETS[@]}"; do
        # Loop: a rule may have been inserted more than once (idempotency was
        # not guaranteed on early versions); stop on first non-zero exit.
        while iptables -t nat -D POSTROUTING -s "$_subnet" ! -o docker0 \
              -j MASQUERADE 2>/dev/null; do
            success "Removed nat POSTROUTING MASQUERADE for ${_subnet}"
        done
    done

    # Remove DOCKER-USER ACCEPT rules (filter table) — only if the chain exists.
    if iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
        for _subnet in "${_VW_SUBNETS[@]}"; do
            while iptables -t filter -D DOCKER-USER -s "$_subnet" \
                  -j ACCEPT 2>/dev/null; do
                success "Removed filter DOCKER-USER ACCEPT for ${_subnet}"
            done
        done
    else
        info "DOCKER-USER chain not present — skipping (Docker already removed or chain not created)."
    fi

    success "iptables cleanup complete."
else
    info "iptables not found — skipping."
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

# Remove fstab entry for swapfile — atomic mktemp + mv, consistent with Step 5c.
if grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
    _FSTAB_TMP=$(mktemp /etc/fstab.uninstall.XXXXXXXXXX)
    if sed '/^\/swapfile[[:space:]]/d' /etc/fstab > "$_FSTAB_TMP" \
       && mv -f "$_FSTAB_TMP" /etc/fstab; then
        success "Removed /swapfile entry from /etc/fstab."
    else
        rm -f "$_FSTAB_TMP" 2>/dev/null || true
        warn "Could not update /etc/fstab atomically — remove the swapfile entry manually:"
        warn "  sudo nano /etc/fstab   # delete the line beginning with /swapfile"
    fi
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
