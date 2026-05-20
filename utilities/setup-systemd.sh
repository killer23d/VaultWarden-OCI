#!/usr/bin/env bash
# utilities/setup-systemd.sh — VaultWarden-OCI systemd timer management
#
# USAGE:
#   sudo utilities/setup-systemd.sh <action> [--dry-run]
#
# ACTIONS:
#   install   Install and enable all systemd timer units
#   remove    Disable and remove all systemd timer units
#   validate  Verify installed state matches repo
#   status    Show timer and service status
#
# FLAGS:
#   --dry-run     Preview actions without executing
#   --help, -h    Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

INSTALL=false
REMOVE=false
STATUS=false
VALIDATE=false
DRY_RUN=false

UNIT_SOURCE_DIR="${PROJECT_ROOT}/systemd"
UNIT_DEST_DIR="/etc/systemd/system"
OPT_SCRIPTS_DIR="/opt/vaultwarden-scripts"
ENV_DIR="/etc/vaultwarden"
ENV_FILE="${ENV_DIR}/vaultwarden.env"
AGE_KEY_DEST="${ENV_DIR}/age-key.txt"

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

_VW_DROPIN_UNITS=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure.service
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)

_sd_show_help() {
    cat << 'EOF'
VaultWarden-OCI systemd Timer Installer

USAGE:
    sudo utilities/setup-systemd.sh <action> [OPTIONS]
    sudo utilities/setup-systemd.sh install    # Install and enable all timers
    sudo utilities/setup-systemd.sh remove     # Disable and remove all timers
    sudo utilities/setup-systemd.sh validate   # Verify installed state vs repo
    sudo utilities/setup-systemd.sh status     # Show timer and service status

ACTIONS:
    install   Install and enable all systemd timer units
    remove    Disable and remove all systemd timer units
    validate  Verify installed state matches repo; detect split-brain
    status    Show timer and service status

OPTIONS:
    --dry-run     Print actions without executing
    --help, -h    Show this help

WHAT install DOES:
    1. Copies scripts to /opt/vaultwarden-scripts/ (root:root 700):
         maintenance.sh  backup.sh  restore.sh
         utilities/setup-firewall.sh
         utilities/maintenance-run.sh      utilities/maintenance-health.sh
         utilities/maintenance-update.sh   utilities/maintenance-db-maint.sh
         utilities/maintenance-email.sh    utilities/maintenance-update-dns.sh
         utilities/maintenance-update-firewall.sh
         utilities/backup-run.sh           utilities/restore-run.sh
       Scripts are self-locating via BASH_SOURCE[0]. The utilities/ subdirectory
       structure is preserved at the destination.
       NOTE: restore.sh is now installed to /opt/ (it was not installed previously).
    2. Copies lib/ -> /opt/vaultwarden-scripts/lib/ (root:root 644)
       lib files are 644 (world-readable) so a non-root service User= can
       still source lib/common.sh if the unit is ever changed from root.
    3. Copies .env -> /etc/vaultwarden/vaultwarden.env (root:root 600)
       (skipped if the EnvironmentFile already exists; warns if content differs)
    4. Copies secrets/keys/age-key.txt -> /etc/vaultwarden/age-key.txt (root:root 600)
       and sets SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in the EnvironmentFile.
       This is required because systemd units run with ProtectHome=yes, which makes
       /home/ubuntu/ (and any symlinks into it) inaccessible to the service process.
       If the source file is absent but the key already exists at the destination,
       SOPS_AGE_KEY_FILE is still corrected to the absolute path.
    5. Copies systemd/*.{service,timer} -> /etc/systemd/system/
    6. systemctl daemon-reload
    7. systemctl enable --now for all 6 timers
    8. Verifies all managed timers are active and have a next trigger
    9. systemctl reset-failed for all managed services (clears stale failed status)

WHAT validate CHECKS:
    1. Scripts present and executable in /opt/vaultwarden-scripts/
    2. lib/ present; lib/*.sh files are readable (mode 644 recommended)
    3. All unit files present in /etc/systemd/system/
    4. All 6 timers enabled (systemctl is-enabled)
    5. EnvironmentFile /etc/vaultwarden/vaultwarden.env exists (mode 600)
    6. Age key /etc/vaultwarden/age-key.txt exists (mode 600)
    7. SOPS_AGE_KEY_FILE is set in the EnvironmentFile
    8. Installed scripts match repo source checksum (sha256 split-brain detection)
       Re-run install after any git pull to keep /opt/ in sync.

VIEWING LOGS:
    journalctl -u vaultwarden-health.service -n 50
    journalctl -u vaultwarden-db-backup.service -n 100
    systemctl list-timers --all | grep vaultwarden

MIGRATING FROM CRON:
    cron-setup.sh has been removed. To migrate:
    1. sudo utilities/setup-systemd.sh install
    2. Remove old crontab entries: sudo crontab -e
    3. Verify timers: systemctl list-timers --all | grep vaultwarden
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        install)      INSTALL=true;   shift ;;
        remove)       REMOVE=true;    shift ;;
        validate)     VALIDATE=true;  shift ;;
        status)       STATUS=true;    shift ;;
        --dry-run)    DRY_RUN=true;   shift ;;
        help|--help|-h) _sd_show_help; exit 0 ;;
        *) log_error "Unknown sub-action: $1"; _sd_show_help; exit 1 ;;
    esac
done

_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# _timer_has_next_trigger TIMER
# Returns success when TIMER has a next scheduled trigger.
# ---------------------------------------------------------------------------
_timer_has_next_trigger() {
    local timer="$1"
    local next_elapse
    next_elapse="$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>/dev/null || true)"
    [[ -n "$next_elapse" && "$next_elapse" != "n/a" ]]
}

# ---------------------------------------------------------------------------
# _count_healthy_managed_timers
# Returns the number of managed timers that are active and have a next trigger.
# ---------------------------------------------------------------------------
_count_healthy_managed_timers() {
    local healthy_count=0
    local timer
    for timer in "${TIMERS[@]}"; do
        if systemctl is-active --quiet "$timer" && _timer_has_next_trigger "$timer"; then
            ((healthy_count++))
        fi
    done
    printf '%s\n' "$healthy_count"
}

# ---------------------------------------------------------------------------
# _sha256 FILE
# Portable sha256 hash of a single file; prints only the hex digest.
# ---------------------------------------------------------------------------
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# _install_rwpaths_dropin
# ---------------------------------------------------------------------------
# In separate-volume mode every managed unit needs a ReadWritePaths drop-in
# so that ProtectSystem=strict allows writes to DATA_VOLUME_MOUNT.  Without
# this drop-in, any write to DATA_VOLUME_MOUNT (backup files, health cooldown
# stamps, DB operations) is silently blocked by the kernel, causing runtime
# Permission denied errors that are hard to diagnose from the unit file alone.
#
# Boot-only mode (DATA_VOLUME_DEVICE empty): no-op.
# Dry-run mode: logs what would be written without touching the filesystem.
# ---------------------------------------------------------------------------
_install_rwpaths_dropin() {
    local data_device data_mount
    # Read from the installed EnvironmentFile when available so that
    # standalone 'setup-systemd.sh install' runs (without CLI flags) pick up
    # the correct value written by a previous full setup run.
    if [[ -f "$ENV_FILE" ]]; then
        data_device=$(_read_env_value "DATA_VOLUME_DEVICE" "$ENV_FILE")
        data_mount=$(_read_env_value "DATA_VOLUME_MOUNT"  "$ENV_FILE")
    fi
    # Fall back to environment variables
    [[ -z "${data_device:-}" ]] && data_device="${DATA_VOLUME_DEVICE:-}"
    [[ -z "${data_mount:-}"  ]] && data_mount="${DATA_VOLUME_MOUNT:-}"

    if [[ -z "$data_device" ]]; then
        log_info "Boot-only mode — skipping per-unit ReadWritePaths drop-ins."
        return 0
    fi

    if [[ -z "$data_mount" ]]; then
        log_warn "DATA_VOLUME_MOUNT is empty — cannot write ReadWritePaths drop-ins."
        return 1
    fi

    # Self-contained unit list — do NOT rely on SERVICES/TIMERS from the
    # enclosing scope. Dynamic-scope inheritance only works when called
    # through the exact call chain that defines those locals; any future
    # caller outside that chain would silently iterate zero units and install
    # no drop-ins.
    local -a _DROPIN_UNITS=("${_VW_DROPIN_UNITS[@]}")

    log_info "Installing per-unit ReadWritePaths drop-ins for DATA_VOLUME_MOUNT=${data_mount} ..."
    local unit dropin_dir dropin_file _mount_unit
    _mount_unit=$(systemd-escape --path --suffix=mount "$data_mount" 2>/dev/null) || {
        log_error "systemd-escape failed for DATA_VOLUME_MOUNT=$data_mount"
        return 1
    }
    for unit in "${_DROPIN_UNITS[@]}"; do
        dropin_dir="${UNIT_DEST_DIR}/${unit}.d"
        dropin_file="${dropin_dir}/10-state-dir.conf"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write ReadWritePaths drop-in: $dropin_file"
            continue
        fi
        mkdir -p "$dropin_dir" || { log_error "Cannot create drop-in dir: $dropin_dir"; return 1; }
        cat > "$dropin_file" << DROPIN
# Written by setup-systemd.sh install — do not edit by hand.
# Regenerate: sudo utilities/setup-systemd.sh install
#
# [Unit]  After=  — this unit waits for the data volume to be mounted before
#                   starting, even when triggered by a timer or dependency chain.
# [Service] ReadWritePaths= — grants write access to DATA_VOLUME_MOUNT under
#                             ProtectSystem=strict (without this, all writes to
#                             the data volume are silently denied by the kernel).
[Unit]
After=${_mount_unit}

[Service]
ReadWritePaths=${data_mount}
DROPIN
        chmod 644 "$dropin_file"
        log_success "Installed ReadWritePaths drop-in: $dropin_file"
    done
}

# ---------------------------------------------------------------------------
# install_units
# ---------------------------------------------------------------------------
install_units() {
    if [[ $EUID -ne 0 ]]; then log_error "This script must be run as root."; exit 1; fi
    log_header "VaultWarden-OCI systemd Timer Installation"

    if [[ ! -d "$UNIT_SOURCE_DIR" ]]; then
        log_error "systemd unit directory not found: $UNIT_SOURCE_DIR"
        log_error "Run from the VaultWarden-OCI repository root."
        return 1
    fi

    # 1. Install scripts to /opt/vaultwarden-scripts/
    log_info "Installing scripts to $OPT_SCRIPTS_DIR ..."
    _run mkdir -p "$OPT_SCRIPTS_DIR"

    if [[ "$DRY_RUN" == "false" ]]; then
        cp -rP "$PROJECT_ROOT/lib" "$OPT_SCRIPTS_DIR/"

        # lib files are installed 644 root:root (not 640).
        #
        # Rationale: these files are used by maintenance.sh and backup.sh
        # at runtime. If the systemd unit's User= directive is
        # ever changed from root to a service account, a 640 root:root mode
        # causes every "source lib/common.sh" call to fail silently (bash
        # reports the permission error to stderr but continues, leaving all
        # lib functions undefined). 644 keeps the files non-writable by
        # everyone except root while still allowing any user to read them --
        # the same policy used for system libraries in /usr/lib.
        #
        # If your threat model requires stricter access (e.g. lib files
        # contain inline credentials), set User= to a dedicated group,
        # change these lines to chmod 640 and chown root:<service-group>,
        # and add the service account to that group. Document the choice.
        find "$OPT_SCRIPTS_DIR/lib" -type f -name '*.sh' -exec chmod 644 {} +
        find "$OPT_SCRIPTS_DIR/lib" -type f ! -name '*.sh' -exec chmod 640 {} +  2>/dev/null || true
        find "$OPT_SCRIPTS_DIR/lib" -type d -exec chmod 755 {} +
        chown -R root:root "$OPT_SCRIPTS_DIR/lib"
        log_success "Installed lib/ to $OPT_SCRIPTS_DIR/lib/ (*.sh: 644, other files: 640)"
    else
        log_info "[DRY RUN] Would copy lib/ -> $OPT_SCRIPTS_DIR/lib/ (*.sh: 644 root:root)"
    fi

    if [[ "$DRY_RUN" == "false" ]] && [[ ! -f "$OPT_SCRIPTS_DIR/lib/crypto.sh" ]]; then
        log_error "CRITICAL: lib/crypto.sh missing from repo -- installation aborted."
        log_error "Ensure lib/crypto.sh exists in: $PROJECT_ROOT/lib/"
        return 1
    fi

    # ---------------------------------------------------------------------------
    # Flat-installed scripts (installed as basename only, NOT inside utilities/)
    # These have pre-existing callers (e.g. systemd units) that reference the
    # flat /opt/vaultwarden-scripts/<name> path.  Do NOT change their dest path.
    # ---------------------------------------------------------------------------
    local flat_scripts_to_install=(
        maintenance.sh
        backup.sh
        restore.sh
    )
    for script in "${flat_scripts_to_install[@]}"; do
        local src="$PROJECT_ROOT/$script"
        local dest
        dest="$OPT_SCRIPTS_DIR/$(basename "$script")"
        if [[ ! -f "$src" ]]; then
            log_warn "Script not found, skipping: $src"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $dest (700 root:root)"
            continue
        fi
        install -m 700 -o root -g root "$src" "$dest"
        log_success "Installed: $dest"
    done

    # ---------------------------------------------------------------------------
    # Structured-installed scripts (installed preserving utilities/ subdir path).
    # setup-firewall.sh keeps its pre-existing flat path because
    # systemd/vaultwarden-iptables.service calls /opt/vaultwarden-scripts/setup-firewall.sh.
    # ---------------------------------------------------------------------------
    local structured_scripts_to_install=(
        utilities/setup-firewall.sh   # ← flat-installed (basename only) for iptables.service compatibility
        utilities/maintenance-run.sh
        utilities/maintenance-health.sh
        utilities/maintenance-update.sh
        utilities/maintenance-db-maint.sh
        utilities/maintenance-email.sh
        utilities/maintenance-update-dns.sh
        utilities/maintenance-update-firewall.sh
        utilities/backup-run.sh
        utilities/restore-run.sh
    )
    for script in "${structured_scripts_to_install[@]}"; do
        local src="$PROJECT_ROOT/$script"
        local dest
        # setup-firewall.sh must remain at the flat path for iptables.service
        if [[ "$script" == "utilities/setup-firewall.sh" ]]; then
            dest="$OPT_SCRIPTS_DIR/$(basename "$script")"
        else
            dest="$OPT_SCRIPTS_DIR/$script"
        fi
        if [[ ! -f "$src" ]]; then
            log_warn "Script not found, skipping: $src"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $dest (700 root:root)"
            continue
        fi
        mkdir -p "$(dirname "$dest")"
        install -m 700 -o root -g root "$src" "$dest"
        log_success "Installed: $dest"
    done
    if [[ "$DRY_RUN" == "false" ]]; then chown root:root "$OPT_SCRIPTS_DIR"; fi

    # 2. Create EnvironmentFile at /etc/vaultwarden/vaultwarden.env
    log_info "Setting up EnvironmentFile at $ENV_FILE ..."
    if [[ "$DRY_RUN" == "false" ]]; then
        # Use install -d to create the directory with the correct
        # mode atomically. The previous mkdir -p + chmod 700 two-step had a
        # TOCTOU race window between mkdir and chmod where a concurrent
        # non-root process could list $ENV_DIR before permissions were
        # restricted. install(1) creates the directory with the correct mode
        # and ownership in a single syscall, eliminating the window.
        install -d -m 700 -o root -g root "$ENV_DIR"
        if [[ ! -f "$ENV_FILE" ]]; then
            if [[ -f "$PROJECT_ROOT/.env" ]]; then
                cp "$PROJECT_ROOT/.env" "$ENV_FILE"
                chmod 600 "$ENV_FILE"
                chown root:root "$ENV_FILE"
                log_success "Copied .env -> $ENV_FILE"
            else
                log_warn ".env not found -- creating empty $ENV_FILE"
                log_warn "Populate $ENV_FILE with ADMIN_EMAIL, EMAIL_PROVIDER credentials, etc."
                touch "$ENV_FILE"
                chmod 600 "$ENV_FILE"
                chown root:root "$ENV_FILE"
            fi
        else
            # On re-install, perform a safe additive merge instead of a full
            # overwrite.
            #
            # Strategy:
            #   - Lines already present in the installed file are NEVER touched
            #     (live credentials, tokens, and operator overrides are preserved).
            #   - Keys present in repo .env but ABSENT from the installed file
            #     are APPENDED as a clearly-marked block.
            #   - If every key is already present (files may still differ in
            #     value), a checksum comparison is shown so the operator can
            #     review value drift intentionally.
            #
            # This eliminates the persistent DRIFT DETECTED warning on every
            # --install while keeping the installed file safe from blind overwrites.
            log_info "$ENV_FILE already exists -- checking for drift ..."
            if [[ -f "$PROJECT_ROOT/.env" ]]; then
                local repo_sum installed_sum
                repo_sum=$(_sha256 "$PROJECT_ROOT/.env")
                installed_sum=$(_sha256 "$ENV_FILE")
                if [[ "$repo_sum" == "$installed_sum" ]]; then
                    log_success "$ENV_FILE is identical to repo .env (checksums match)"
                else
                    # Collect keys from repo .env that are absent in the installed file.
                    local missing_keys=()
                    while IFS= read -r line; do
                        # Skip blanks and comments
                        [[ -z "$line" || "$line" == '#'* ]] && continue
                        local key="${line%%=*}"
                        [[ -z "$key" ]] && continue
                        if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
                            missing_keys+=("$line")
                        fi
                    done < "$PROJECT_ROOT/.env"
                    if [[ "${#missing_keys[@]}" -gt 0 ]]; then
                        log_info "Merging ${#missing_keys[@]} new variable(s) from repo .env into $ENV_FILE ..."
                        {
                            printf '\n# --- Merged by setup-systemd.sh install on %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                            for entry in "${missing_keys[@]}"; do
                                printf '%s\n' "$entry"
                            done
                        } >> "$ENV_FILE"
                        log_success "Merged new keys into $ENV_FILE -- review and set their values:"
                        for entry in "${missing_keys[@]}"; do
                            log_info "  + ${entry%%=*}"
                        done
                        log_info "Edit: sudo nano $ENV_FILE"
                    else
                        # Files differ in VALUE only (not in which keys are present).
                        # This is expected if the operator has customised values.
                        # Inform without alarming; show a diff command for review.
                        log_info "────────────────────────────────────────────────────────────────"
                        log_info "NOTE: $ENV_FILE has the same keys as repo .env but values differ."
                        log_info "  repo .env  sha256: $repo_sum"
                        log_info "  installed  sha256: $installed_sum"
                        log_info "This is normal if you have set live credentials or custom values."
                        log_info "To review:  diff $PROJECT_ROOT/.env $ENV_FILE"
                        log_info "────────────────────────────────────────────────────────────────"
                    fi
                fi
            else
                log_info "No repo .env found -- skipping drift check"
            fi
        fi
    else
        log_info "[DRY RUN] Would create/check $ENV_FILE from .env"
    fi

    # ------------------------------------------------------------------
    # 3. Install age key to /etc/vaultwarden/age-key.txt
    #    (ProtectHome=yes makes /home/ubuntu/ inaccessible to service processes)
    log_info "Installing age key to $AGE_KEY_DEST ..."
    local age_key_src="$PROJECT_ROOT/secrets/keys/age-key.txt"
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ -f "$age_key_src" ]]; then
            log_info "[DRY RUN] Would copy $age_key_src -> $AGE_KEY_DEST (600 root:root)"
            log_info "[DRY RUN] Would set SOPS_AGE_KEY_FILE=$AGE_KEY_DEST in $ENV_FILE"
        else
            log_warn "[DRY RUN] Age key source not found: $age_key_src"
            if [[ -f "$AGE_KEY_DEST" ]]; then
                log_info "[DRY RUN] Key already at $AGE_KEY_DEST -- would correct SOPS_AGE_KEY_FILE"
            else
                log_warn "[DRY RUN] Set SOPS_AGE_KEY_FILE manually in $ENV_FILE after install."
            fi
        fi
    else
        if [[ -f "$age_key_src" ]]; then
            install -m 600 -o root -g root "$age_key_src" "$AGE_KEY_DEST"
            log_success "Installed age key: $AGE_KEY_DEST"
            # Ensure SOPS_AGE_KEY_FILE is set correctly in the EnvironmentFile
            _set_env_var "SOPS_AGE_KEY_FILE" "$AGE_KEY_DEST" "$ENV_FILE"
            log_success "SOPS_AGE_KEY_FILE=$AGE_KEY_DEST set in $ENV_FILE"
        else
            log_warn "Age key source not found: $age_key_src"
            # If the key already exists at the destination, correct SOPS_AGE_KEY_FILE to
            # the canonical absolute path. A stale relative
            # SOPS_AGE_KEY_FILE=secrets/keys/age-key.txt in the env file would otherwise
            # persist across subsequent install runs, causing backup.sh to fail with
            # "Age key file not found: /opt/vaultwarden-scripts/secrets/keys/age-key.txt".
            if [[ -f "$AGE_KEY_DEST" ]]; then
                _set_env_var "SOPS_AGE_KEY_FILE" "$AGE_KEY_DEST" "$ENV_FILE"
                log_success "SOPS_AGE_KEY_FILE=$AGE_KEY_DEST corrected in $ENV_FILE"
                log_info "  Key already present at $AGE_KEY_DEST -- no copy needed."
            else
                log_warn "Backup and health services require SOPS_AGE_KEY_FILE to be set."
                log_warn "After placing your age-key.txt, run:"
                log_warn "  sudo install -m 600 -o root -g root /path/to/age-key.txt $AGE_KEY_DEST"
                log_warn "  sudo utilities/setup-systemd.sh install"
            fi
        fi
    fi

    # 3b. Copy rclone config to /etc/vaultwarden/rclone.conf
    local rclone_dest="$ENV_DIR/rclone.conf"
    log_info "Setting up rclone config at $rclone_dest ..."

    # Check if RCLONE_CONFIG is already correctly set in the env file
    local existing_rclone_cfg=""
    if [[ -f "$ENV_FILE" ]]; then
        existing_rclone_cfg=$(grep "^RCLONE_CONFIG=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)
    fi

    if [[ -n "$existing_rclone_cfg" && "$existing_rclone_cfg" == "$rclone_dest" && -f "$rclone_dest" ]]; then
        log_success "rclone config already at $rclone_dest (RCLONE_CONFIG in env is correct)"
    else
        # Resolve source: repo-local → sudo user → root → heuristic
        local rclone_src=""
        if [[ -f "$PROJECT_ROOT/rclone.conf" ]]; then
            rclone_src="$PROJECT_ROOT/rclone.conf"
        elif [[ -n "${SUDO_USER:-}" ]]; then
            local sudo_home
            sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
            [[ -n "$sudo_home" && -f "$sudo_home/.config/rclone/rclone.conf" ]] \
                && rclone_src="$sudo_home/.config/rclone/rclone.conf"
        fi
        if [[ -z "$rclone_src" && -f "/root/.config/rclone/rclone.conf" ]]; then
            rclone_src="/root/.config/rclone/rclone.conf"
        fi
        if [[ -z "$rclone_src" ]]; then
            local found_cfg
            for found_cfg in /home/*/.config/rclone/rclone.conf; do
                [[ -f "$found_cfg" ]] && rclone_src="$found_cfg" && break
            done
        fi

        if [[ -n "$rclone_src" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would copy $rclone_src -> $rclone_dest (600 root:root)"
                log_info "[DRY RUN] Would set RCLONE_CONFIG=$rclone_dest in $ENV_FILE"
            else
                install -m 600 -o root -g root "$rclone_src" "$rclone_dest"
                _set_env_var "RCLONE_CONFIG" "$rclone_dest" "$ENV_FILE"
                log_success "Installed rclone config: $rclone_dest (source: $rclone_src)"
                log_success "RCLONE_CONFIG=$rclone_dest set in $ENV_FILE"
                if [[ "$rclone_src" != "$rclone_dest" ]]; then
                    log_info "ADMIN NOTE: if you re-run 'rclone config' interactively as a non-root"
                    log_info "  user, re-run install to sync the updated token to $rclone_dest."
                fi
            fi
        else
            log_warn "No rclone.conf found — offsite backup (--rclone) will not work until"
            log_warn "rclone is configured. Steps:"
            log_warn "  1. Run: rclone config   (configure your remote)"
            log_warn "  2. Run: sudo utilities/setup-systemd.sh install  (copies conf to $rclone_dest)"
            log_warn "  Or manually:"
            log_warn "    sudo install -m 600 -o root -g root ~/.config/rclone/rclone.conf $rclone_dest"
            log_warn "    echo RCLONE_CONFIG=$rclone_dest | sudo tee -a $ENV_FILE"
        fi
    fi

    # 4. Install systemd unit files
    log_info "Installing systemd unit files to $UNIT_DEST_DIR ..."
    local unit_ok=true
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local src="$UNIT_SOURCE_DIR/$unit"
        if [[ ! -f "$src" ]]; then
            log_warn "Unit file not found, skipping: $src"
            unit_ok=false
            continue
        fi
        _run cp "$src" "$UNIT_DEST_DIR/$unit"
        _run chmod 644 "$UNIT_DEST_DIR/$unit"
        log_success "Installed unit: $unit"
    done
    if [[ "$unit_ok" == "false" ]]; then
        log_warn "Some unit files were missing -- check the systemd/ directory."
    fi

    # 4b. Write per-unit ReadWritePaths drop-ins (separate-volume mode)
    _install_rwpaths_dropin

    log_info "Reloading systemd daemon ..."
    _run systemctl daemon-reload

    # Validate OnCalendar expressions before enabling timers.
    # An invalid expression causes systemctl enable --now to fail with a
    # cryptic 'Failed to start' error; surfacing it here with a clear
    # warning gives operators actionable information before activation.
    #
    # '^OnCalendar=' anchors the grep pattern so only directive lines are
    # matched (not comment lines), preventing systemd-analyze from
    # validating comment text and emitting false-positive warnings.
    if command -v systemd-analyze >/dev/null 2>&1; then
        for unit in "${UNIT_DEST_DIR}"/vaultwarden-*.timer; do
            [[ -f "$unit" ]] || continue
            # '^OnCalendar=' anchors to directive lines only.
            local cal_expr; cal_expr=$(grep -m1 '^OnCalendar=' "$unit" | cut -d= -f2-)
            if [[ -n "$cal_expr" ]]; then
                if ! systemd-analyze calendar "$cal_expr" >/dev/null 2>&1; then
                    log_warn "Timer $(basename "$unit") has an invalid OnCalendar expression '$cal_expr' — check the unit file"
                fi
            fi
        done
    fi

    log_info "Enabling and starting timers ..."
    for timer in "${TIMERS[@]}"; do
        _run systemctl enable --now "$timer"
        log_success "Enabled: $timer"
    done

    # Verify managed timers are healthy after enablement.
    # list-timers output can lag briefly right after daemon-reload/enable.
    # Check each managed timer state directly and allow a short settle period.
    # Healthy = timer unit is active AND has a next trigger scheduled.
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Verifying timers are scheduled ..."
        local expected_count="${#TIMERS[@]}"
        local healthy_count=0
        local attempts=10
        local delay_seconds=1
        local i
        for (( i=1; i<=attempts; i++ )); do
            healthy_count=$(_count_healthy_managed_timers)
            if [[ "$healthy_count" -eq "$expected_count" ]]; then
                break
            fi
            sleep "$delay_seconds"
        done

        if [[ "$healthy_count" -eq "$expected_count" ]]; then
            log_success "All managed timers are healthy ($healthy_count/$expected_count)."
        else
            log_warn "────────────────────────────────────────────────────────────────"
            log_warn "WARNING: Not all managed timers are healthy after enablement"
            log_warn "         (healthy: $healthy_count/$expected_count)."
            log_warn "Possible causes:"
            log_warn "  - A timer unit has an invalid setting (e.g. bad OnCalendar)"
            log_warn "  - A timer is being stopped by a conflicting unit relationship"
            log_warn "  - A timer is active but has no next trigger (NEXT='-')"
            log_warn "  - systemd daemon has stale unit state (retry daemon-reload)"
            log_warn "Investigate with:"
            log_warn "  systemctl list-timers --all | grep vaultwarden"
            log_warn "  systemctl status ${TIMERS[0]}"
            log_warn "  journalctl -xe --unit vaultwarden-health.timer"
            log_warn "────────────────────────────────────────────────────────────────"
        fi
    else
        log_info "[DRY RUN] Would check: systemctl is-active + NextElapseUSecRealtime for all managed timers"
    fi

    # ------------------------------------------------------------------
    # 5. Clear stale failed status from previous runs
    # ------------------------------------------------------------------
    log_info "Clearing stale failed status from all managed services ..."
    for svc in "${SERVICES[@]}"; do
        [[ "$svc" == *"@"* ]] && continue  # skip template unit
        _run systemctl reset-failed "$svc" 2>/dev/null || true
    done
    log_success "Stale failed states cleared."

    log_success "Installation complete."
    log_info "Next steps:"
    log_info "  Verify:    systemctl list-timers --all | grep vaultwarden"
    log_info "  Validate:  sudo utilities/setup-systemd.sh validate"
    log_info "  Test run:  sudo systemctl start vaultwarden-health.service"
    log_info "  View logs: journalctl -u vaultwarden-health.service -n 50"
    log_info "  Env file:  $ENV_FILE  (add EMAIL_PROVIDER credentials here)"
    log_info "  Age key:   $AGE_KEY_DEST  (copied from secrets/keys/age-key.txt)"
}

# ---------------------------------------------------------------------------
# remove_units
# ---------------------------------------------------------------------------
remove_units() {
    if [[ $EUID -ne 0 ]]; then log_error "This script must be run as root."; exit 1; fi
    log_header "VaultWarden-OCI systemd Timer Removal"

    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            if _run systemctl disable --now "$timer"; then
                log_success "Disabled: $timer"
            else
                log_warn "Failed to disable $timer -- it may already be inactive or masked."
                log_warn "  Check: systemctl status $timer"
            fi
        fi
    done

    for unit in "${TIMERS[@]}" "${SERVICES[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ -f "$dest" ]]; then
            _run rm -f "$dest"
            log_success "Removed: $dest"
        fi
    done

    # Clean up per-unit ReadWritePaths drop-in directories written by
    # _install_rwpaths_dropin (separate-volume mode). Leaving stale .d/
    # directories behind causes spurious ReadWritePaths entries on
    # reinstall and makes 'systemctl cat <unit>' output misleading.
    # Safe in boot-only mode: the directories simply won't exist.
    local -a _DROPIN_UNITS=("${_VW_DROPIN_UNITS[@]}")
    for unit in "${_DROPIN_UNITS[@]}"; do
        local dropin_dir="$UNIT_DEST_DIR/${unit}.d"
        local dropin_file="$dropin_dir/10-state-dir.conf"
        if [[ -f "$dropin_file" ]]; then
            _run rm -f "$dropin_file"
            log_success "Removed ReadWritePaths drop-in: $dropin_file"
        fi
        # Remove the .d/ dir only if it is now empty (preserve any
        # drop-ins installed by other tools, e.g. Docker or the OS).
        if [[ -d "$dropin_dir" ]] && [[ -z "$(ls -A "$dropin_dir" 2>/dev/null)" ]]; then
            _run rmdir "$dropin_dir"
            log_success "Removed empty drop-in dir: $dropin_dir"
        fi
    done

    _run systemctl daemon-reload
    log_success "All timer units removed and daemon reloaded."
    log_info "Scripts remain in $OPT_SCRIPTS_DIR -- remove manually if desired."

    if [[ -f "$ENV_FILE" ]]; then
        log_warn "────────────────────────────────────────────────────────────────"
        log_warn "NOTICE: EnvironmentFile was NOT removed automatically:"
        log_warn "  $ENV_FILE"
        log_warn "This file may contain API tokens and SMTP credentials."
        log_warn "Review its contents and remove it manually once you have"
        log_warn "confirmed the credentials are no longer needed or have been"
        log_warn "migrated elsewhere:"
        log_warn "  sudo rm -f $ENV_FILE $AGE_KEY_DEST"
        log_warn "  sudo rmdir --ignore-fail-on-non-empty $ENV_DIR"
        log_warn "────────────────────────────────────────────────────────────────"
    fi
}

# ---------------------------------------------------------------------------
# validate_installation
# ---------------------------------------------------------------------------
validate_installation() {
    if [[ $EUID -ne 0 ]]; then log_error "This script must be run as root."; exit 1; fi
    log_header "VaultWarden-OCI Installation Validation"
    local errors=0
    local warnings=0

    log_info "[1/8] Checking installed scripts ..."
    local scripts_to_check=(
        maintenance.sh
        backup.sh
        restore.sh
        utilities/maintenance-run.sh
        utilities/maintenance-health.sh
        utilities/maintenance-update.sh
        utilities/maintenance-db-maint.sh
        utilities/maintenance-email.sh
        utilities/maintenance-update-dns.sh
        utilities/maintenance-update-firewall.sh
        utilities/backup-run.sh
        utilities/restore-run.sh
    )
    for script in "${scripts_to_check[@]}"; do
        local installed="$OPT_SCRIPTS_DIR/$script"
        if [[ ! -f "$installed" ]]; then
            log_error "  MISSING:        $installed"
            (( errors++ )) || true
        elif [[ ! -x "$installed" ]]; then
            log_error "  NOT EXECUTABLE: $installed"
            (( errors++ )) || true
        else
            log_success "  OK:             $installed"
        fi
    done

    # Check lib/ presence AND file permissions.
    # lib/*.sh files must be at least world-readable (644) so that a
    # non-root service user (User= in the unit) can source them. Warn on
    # 600 or 640 modes.
    log_info "[2/8] Checking installed lib/ and file permissions ..."
    if [[ ! -d "$OPT_SCRIPTS_DIR/lib" ]]; then
        log_error "  MISSING: $OPT_SCRIPTS_DIR/lib/"
        (( errors++ )) || true
    else
        log_success "  OK: $OPT_SCRIPTS_DIR/lib/"
        # Check that every *.sh lib file is readable by others (mode ends in 4 or higher)
        local bad_perm_files=()
        while IFS= read -r -d '' libfile; do
            local fmode
            fmode=$(stat -c '%a' "$libfile" 2>/dev/null || stat -f '%Lp' "$libfile" 2>/dev/null || echo "000")
            # Extract the 'other' permission digit (last character of octal mode)
            local other_bit="${fmode: -1}"
            if (( other_bit < 4 )); then
                bad_perm_files+=("$libfile ($fmode)")
            fi
        done < <(find "$OPT_SCRIPTS_DIR/lib" -type f -name '*.sh' -print0 2>/dev/null)

        if [[ ${#bad_perm_files[@]} -gt 0 ]]; then
            log_warn "  PERM WARNING: The following lib/*.sh files are not world-readable."
            log_warn "  A non-root service User= will fail to source them silently:"
            for f in "${bad_perm_files[@]}"; do
                log_warn "    $f"
            done
            log_warn "  Fix: sudo find $OPT_SCRIPTS_DIR/lib -name '*.sh' -exec chmod 644 {} +"
            log_warn "  Or re-run: sudo utilities/setup-systemd.sh install"
            (( warnings++ )) || true
        else
            log_success "  OK: all lib/*.sh files are world-readable (mode >= 644)"
        fi
    fi
    local critical_lib="$OPT_SCRIPTS_DIR/lib/crypto.sh"
    if [[ ! -f "$critical_lib" ]]; then
        log_error "  MISSING: $critical_lib"
        (( errors++ )) || true
    else
        log_success "  OK: $critical_lib"
    fi

    log_info "[3/8] Checking installed unit files ..."
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ ! -f "$dest" ]]; then
            log_error "  MISSING: $dest"
            (( errors++ )) || true
        else
            log_success "  OK: $dest"
        fi
    done

    log_info "[4/8] Checking timer enablement ..."
    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            log_success "  ENABLED:     $timer"
        else
            log_error   "  NOT ENABLED: $timer"
            (( errors++ )) || true
        fi
    done

    log_info "[5/8] Checking EnvironmentFile ..."
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "  MISSING: $ENV_FILE"
        log_error "  Run: sudo utilities/setup-systemd.sh install  (or create it manually)"
        (( errors++ )) || true
    else
        local env_perms
        env_perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "unknown")
        if [[ "$env_perms" != "600" ]]; then
            log_warn "  PERMISSIONS: $ENV_FILE is mode $env_perms (expected 600)"
            log_warn "  Fix: sudo chmod 600 $ENV_FILE"
            (( warnings++ )) || true
        else
            log_success "  OK: $ENV_FILE (mode 600)"
        fi
    fi

    log_info "[6/8] Checking age key installation ..."
    if [[ ! -f "$AGE_KEY_DEST" ]]; then
        log_error "  MISSING: $AGE_KEY_DEST"
        log_error "  Backup/health services cannot encrypt/decrypt without this key."
        log_error "  Fix: sudo utilities/setup-systemd.sh install  (requires secrets/keys/age-key.txt)"
        (( errors++ )) || true
    else
        local key_perms
        key_perms=$(stat -c '%a' "$AGE_KEY_DEST" 2>/dev/null || stat -f '%Lp' "$AGE_KEY_DEST" 2>/dev/null || echo "unknown")
        if [[ "$key_perms" != "600" ]]; then
            log_warn "  PERMISSIONS: $AGE_KEY_DEST is mode $key_perms (expected 600)"
            log_warn "  Fix: sudo chmod 600 $AGE_KEY_DEST"
            (( warnings++ )) || true
        else
            log_success "  OK: $AGE_KEY_DEST (mode 600)"
        fi
    fi
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^SOPS_AGE_KEY_FILE=" "$ENV_FILE" 2>/dev/null; then
            local configured_path
            configured_path=$(grep "^SOPS_AGE_KEY_FILE=" "$ENV_FILE" | head -1 | cut -d= -f2-)
            if [[ "$configured_path" == "$AGE_KEY_DEST" ]]; then
                log_success "  SOPS_AGE_KEY_FILE=$AGE_KEY_DEST (correct)"
            else
                log_warn "  SOPS_AGE_KEY_FILE is set to '$configured_path' (expected $AGE_KEY_DEST)"
                log_warn "  Fix: sudo utilities/setup-systemd.sh install"
                (( warnings++ )) || true
            fi
        else
            log_error "  SOPS_AGE_KEY_FILE not set in $ENV_FILE"
            log_error "  Fix: sudo utilities/setup-systemd.sh install"
            (( errors++ )) || true
        fi
    fi

    log_info "[7/8] Checking for split-brain (sha256 repo vs installed) ..."
    for script in "${scripts_to_check[@]}"; do
        local repo_src="$PROJECT_ROOT/$script"
        local installed="$OPT_SCRIPTS_DIR/$script"
        if [[ ! -f "$repo_src" || ! -f "$installed" ]]; then
            continue
        fi

        local expected_sum actual_sum
        expected_sum=$(_sha256 "$repo_src")
        actual_sum=$(_sha256 "$installed")
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            log_warn "  STALE: $installed does not match repo source"
            log_warn "         repo      sha256: $expected_sum"
            log_warn "         installed sha256: $actual_sum"
            log_warn "         Re-run: sudo utilities/setup-systemd.sh install"
            (( warnings++ )) || true
        else
            log_success "  UP-TO-DATE: $script (sha256 match)"
        fi
    done

    # Verify timers are healthy.
    # 'systemctl is-enabled' only checks the symlink; it does NOT confirm
    # the timer unit is currently active in systemd nor that it has a future
    # trigger time.
    log_info "[8/8] Checking timers are scheduled (systemctl list-timers) ..."
    local expected_count="${#TIMERS[@]}"
    local healthy_count
    healthy_count=$(_count_healthy_managed_timers)
    if [[ "$healthy_count" -eq "$expected_count" ]]; then
        log_success "  All managed timers are healthy ($healthy_count/$expected_count)."
    else
        log_warn "  WARNING: Managed timers healthy: $healthy_count/$expected_count."
        log_warn "  One or more timers are enabled but unhealthy (inactive or NEXT='-') — check:"
        log_warn "    systemctl list-timers --all | grep vaultwarden"
        log_warn "    systemctl status vaultwarden-db-backup.timer"
        log_warn "    journalctl -xe --unit vaultwarden-health.timer"
        log_warn "  Try: sudo systemctl restart vaultwarden-db-backup.timer vaultwarden-health.timer"
        (( warnings++ )) || true
    fi

    echo ""
    if (( errors > 0 )); then
        log_error "Validation FAILED: ${errors} error(s), ${warnings} warning(s)."
        log_error "Run: sudo utilities/setup-systemd.sh install to resolve errors."
        return 1
    elif (( warnings > 0 )); then
        log_warn  "Validation passed with ${warnings} warning(s) -- review output above."
        return 0
    else
        log_success "Validation PASSED: installation is consistent with repository."
        return 0
    fi
}

# ---------------------------------------------------------------------------
# show_status
# ---------------------------------------------------------------------------
show_status() {
    log_header "VaultWarden-OCI systemd Timer Status"
    echo ""
    systemctl list-timers --all 2>/dev/null | grep vaultwarden || log_info "No vaultwarden timers active."
    echo ""
    for svc in "${SERVICES[@]}"; do
        # Skip the template unit -- it has no standalone status
        [[ "$svc" == *"@"* ]] && continue
        log_info "--- $svc ---"
        { systemctl status "$svc" --no-pager -l 2>/dev/null | head -20; } || true
        echo ""
    done
}

main() {
    (( EUID == 0 )) || { log_error "Must run as root."; exit 1; }

    if [[ "$STATUS" == "true" ]]; then
        show_status
        exit 0
    fi

    if [[ "$VALIDATE" == "true" ]]; then
        validate_installation
        exit $?
    fi

    if [[ "$REMOVE" == "true" ]]; then
        remove_units
        exit 0
    fi

    if [[ "$INSTALL" == "true" ]]; then
        install_units
        exit 0
    fi

    log_error "No action specified. Use --help for options."
    _sd_show_help
    exit 1
}

main "$@"
