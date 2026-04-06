#!/usr/bin/env bash
# setup-systemd.sh - Install and manage VaultWarden-OCI systemd timers
#
# USAGE:
#   sudo ./setup-systemd.sh --install    # Install and enable all timers
#   sudo ./setup-systemd.sh --remove     # Disable and remove all units
#   sudo ./setup-systemd.sh --validate   # Verify installed state vs repo
#   sudo ./setup-systemd.sh --status     # Show timer/service status
#   sudo ./setup-systemd.sh --dry-run    # Print actions without executing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
init_common_lib "$0"

INSTALL=false
REMOVE=false
STATUS=false
VALIDATE=false
DRY_RUN=false

_ORIG_ARGS=("$@")

UNIT_SOURCE_DIR="$SCRIPT_DIR/systemd"
UNIT_DEST_DIR="/etc/systemd/system"
OPT_SCRIPTS_DIR="/opt/vaultwarden-scripts"
ENV_DIR="/etc/vaultwarden"
ENV_FILE="$ENV_DIR/vaultwarden.env"
# BUG-AK1 FIX: Age key must live under /etc/vaultwarden/ so systemd services
# running with ProtectHome=yes can reach it.  /home/ubuntu/ is invisible to
# those processes regardless of symlinks.
AGE_KEY_DEST="$ENV_DIR/age-key.txt"

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

show_help() {
    cat << 'EOF'
VaultWarden-OCI systemd Timer Installer

USAGE:
    sudo ./setup-systemd.sh [OPTIONS]

OPTIONS:
    --install     Install and enable all systemd timer units
    --remove      Disable and remove all systemd timer units
    --validate    Verify installed state matches repo; detect split-brain
    --status      Show timer and service status
    --dry-run     Print actions without executing
    --help        Show this help

WHAT --install DOES:
    1. Copies maintenance.sh, backup.sh, health.sh -> /opt/vaultwarden-scripts/
       (root:root 700; scripts are self-locating via BASH_SOURCE[0])
    2. Copies lib/ -> /opt/vaultwarden-scripts/lib/ (root:root 640)
    3. Copies .env -> /etc/vaultwarden/vaultwarden.env (root:root 600)
       (skipped if the EnvironmentFile already exists; warns if content differs)
    4. Copies secrets/keys/age-key.txt -> /etc/vaultwarden/age-key.txt (root:root 600)
       and sets SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in the EnvironmentFile.
       This is required because systemd units run with ProtectHome=yes, which makes
       /home/ubuntu/ (and any symlinks into it) inaccessible to the service process.
       If the source file is absent but the key already exists at the destination,
       SOPS_AGE_KEY_FILE is still corrected to the absolute path (BUG-AK5).
    5. Copies systemd/*.{service,timer} -> /etc/systemd/system/
    6. systemctl daemon-reload
    7. systemctl enable --now for all 6 timers
    8. systemctl reset-failed for all managed services (clears stale failed status)

WHAT --validate CHECKS:
    1. Scripts present and executable in /opt/vaultwarden-scripts/
    2. lib/ and simple_key_resilience.sh present
    3. All unit files present in /etc/systemd/system/
    4. All 6 timers enabled (systemctl is-enabled)
    5. EnvironmentFile /etc/vaultwarden/vaultwarden.env exists (mode 600)
    6. Age key /etc/vaultwarden/age-key.txt exists (mode 600)
    7. SOPS_AGE_KEY_FILE is set in the EnvironmentFile
    8. Installed scripts match repo source checksum (sha256 split-brain detection)
       Re-run --install after any git pull to keep /opt/ in sync.

VIEWING LOGS:
    journalctl -u vaultwarden-health.service -n 50
    journalctl -u vaultwarden-db-backup.service -n 100
    systemctl list-timers --all | grep vaultwarden

MIGRATING FROM CRON:
    cron-setup.sh has been removed. To migrate:
    1. sudo ./setup-systemd.sh --install
    2. Remove old crontab entries: sudo crontab -e
    3. Verify timers: systemctl list-timers --all | grep vaultwarden
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --install)   INSTALL=true;   shift ;;
        --remove)    REMOVE=true;    shift ;;
        --validate)  VALIDATE=true;  shift ;;
        --status)    STATUS=true;    shift ;;
        --dry-run)   DRY_RUN=true;   shift ;;
        --help)      show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

_require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        log_info  "Use: sudo $0 ${_ORIG_ARGS[*]}"
        exit 1
    fi
}

_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
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
# _set_env_var KEY VALUE FILE
# Add or replace a KEY=VALUE line in an env file.
# If the key already exists (with any value), it is replaced in-place.
# If it does not exist, it is appended.
# ---------------------------------------------------------------------------
_set_env_var() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Replace existing line (sed -i is portable on GNU/Linux)
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# ---------------------------------------------------------------------------
# install_units
# ---------------------------------------------------------------------------
install_units() {
    _require_root
    log_header "VaultWarden-OCI systemd Timer Installation"

    if [[ ! -d "$UNIT_SOURCE_DIR" ]]; then
        log_error "systemd unit directory not found: $UNIT_SOURCE_DIR"
        log_error "Run from the VaultWarden-OCI repository root."
        return 1
    fi

    # ------------------------------------------------------------------
    # 1. Install scripts to /opt/vaultwarden-scripts/
    # ------------------------------------------------------------------
    log_info "Installing scripts to $OPT_SCRIPTS_DIR ..."
    _run mkdir -p "$OPT_SCRIPTS_DIR"

    if [[ "$DRY_RUN" == "false" ]]; then
        cp -rP "$SCRIPT_DIR/lib" "$OPT_SCRIPTS_DIR/"
        find "$OPT_SCRIPTS_DIR/lib" -type f -exec chmod 640 {} +  2>/dev/null || true
        find "$OPT_SCRIPTS_DIR/lib" -type d -exec chmod 750 {} +  2>/dev/null || true
        chown -R root:root "$OPT_SCRIPTS_DIR/lib"
        log_success "Installed lib/ to $OPT_SCRIPTS_DIR/lib/"
    else
        log_info "[DRY RUN] Would copy lib/ -> $OPT_SCRIPTS_DIR/lib/"
    fi

    if [[ "$DRY_RUN" == "false" ]] && [[ ! -f "$OPT_SCRIPTS_DIR/lib/simple_key_resilience.sh" ]]; then
        log_error "CRITICAL: lib/simple_key_resilience.sh missing from repo -- key health checks disabled."
        log_error "Ensure lib/simple_key_resilience.sh exists in: $SCRIPT_DIR/lib/"
        return 1
    fi

    local scripts_to_install=(maintenance.sh backup.sh health.sh)
    for script in "${scripts_to_install[@]}"; do
        local src="$SCRIPT_DIR/$script"
        if [[ ! -f "$src" ]]; then
            log_warn "Script not found, skipping: $src"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $OPT_SCRIPTS_DIR/$script"
            continue
        fi
        install -m 700 -o root -g root "$src" "$OPT_SCRIPTS_DIR/$script"
        log_success "Installed: $OPT_SCRIPTS_DIR/$script"
    done
    [[ "$DRY_RUN" == "false" ]] && chown root:root "$OPT_SCRIPTS_DIR" || true

    # ------------------------------------------------------------------
    # 2. Create EnvironmentFile at /etc/vaultwarden/vaultwarden.env
    # ------------------------------------------------------------------
    log_info "Setting up EnvironmentFile at $ENV_FILE ..."
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "$ENV_DIR"
        chmod 700 "$ENV_DIR"
        chown root:root "$ENV_DIR"
        if [[ ! -f "$ENV_FILE" ]]; then
            if [[ -f "$SCRIPT_DIR/.env" ]]; then
                cp "$SCRIPT_DIR/.env" "$ENV_FILE"
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
            # FIX-S11: Compare checksums and warn on drift after initial install.
            log_info "$ENV_FILE already exists -- checking for drift ..."
            if [[ -f "$SCRIPT_DIR/.env" ]]; then
                local repo_sum installed_sum
                repo_sum=$(_sha256 "$SCRIPT_DIR/.env")
                installed_sum=$(_sha256 "$ENV_FILE")
                if [[ "$repo_sum" != "$installed_sum" ]]; then
                    log_warn "────────────────────────────────────────────────────────────────"
                    log_warn "DRIFT DETECTED: .env and $ENV_FILE differ."
                    log_warn "  repo .env  sha256: $repo_sum"
                    log_warn "  installed  sha256: $installed_sum"
                    log_warn "New variables added to .env after initial setup will NOT be"
                    log_warn "visible to systemd units until $ENV_FILE is updated."
                    log_warn "Review differences and merge manually:"
                    log_warn "  diff $SCRIPT_DIR/.env $ENV_FILE"
                    log_warn "Then run: sudo ./setup-systemd.sh --install to re-copy."
                    log_warn "  (Back up $ENV_FILE first -- it may contain live credentials)"
                    log_warn "────────────────────────────────────────────────────────────────"
                else
                    log_success "$ENV_FILE is identical to repo .env (checksums match)"
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
    #    (BUG-AK1 FIX: ProtectHome=yes makes /home/ubuntu/ inaccessible)
    # ------------------------------------------------------------------
    log_info "Installing age key to $AGE_KEY_DEST ..."
    local age_key_src="$SCRIPT_DIR/secrets/keys/age-key.txt"
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
            # BUG-AK5 FIX: even when the source file is absent (already deployed
            # from a prior --install), always correct SOPS_AGE_KEY_FILE to the
            # canonical absolute path if the key exists at $AGE_KEY_DEST.
            # A stale relative SOPS_AGE_KEY_FILE=secrets/keys/age-key.txt in the
            # env file (written before BUG-AK1 was fixed) would otherwise persist
            # across subsequent --install runs, causing backup.sh and health.sh to
            # look for the key in the wrong location and fail with "Age key file
            # not found: /opt/vaultwarden-scripts/secrets/keys/age-key.txt".
            if [[ -f "$AGE_KEY_DEST" ]]; then
                _set_env_var "SOPS_AGE_KEY_FILE" "$AGE_KEY_DEST" "$ENV_FILE"
                log_success "SOPS_AGE_KEY_FILE=$AGE_KEY_DEST corrected in $ENV_FILE (BUG-AK5)"
                log_info "  Key already present at $AGE_KEY_DEST -- no copy needed."
            else
                log_warn "Backup and health services require SOPS_AGE_KEY_FILE to be set."
                log_warn "After placing your age-key.txt, run:"
                log_warn "  sudo install -m 600 -o root -g root /path/to/age-key.txt $AGE_KEY_DEST"
                log_warn "  sudo ./setup-systemd.sh --install"
            fi
        fi
    fi

    # ------------------------------------------------------------------
    # 4. Install systemd unit files
    # ------------------------------------------------------------------
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

    log_info "Reloading systemd daemon ..."
    _run systemctl daemon-reload

    # ------------------------------------------------------------------
    # P5-SD1 FIX: Validate OnCalendar expressions before enabling timers.
    # An invalid expression causes systemctl enable --now to fail with a
    # cryptic 'Failed to start' error; surfacing it here with a clear
    # warning gives operators actionable information before activation.
    #
    # TIMER-1 FIX: Anchor the grep pattern with ^ so only lines where
    # OnCalendar= is the very first character are matched. Without the
    # anchor, grep -m1 'OnCalendar=' matched comment lines containing
    # the string (e.g. the BUG-TM1 comment in vaultwarden-maintenance.timer)
    # before reaching the real directive, causing systemd-analyze to
    # validate the comment text and emit a false-positive WARN.
    # ------------------------------------------------------------------
    if command -v systemd-analyze >/dev/null 2>&1; then
        for unit in "${UNIT_DEST_DIR}"/vaultwarden-*.timer; do
            [[ -f "$unit" ]] || continue
            # TIMER-1 FIX: '^OnCalendar=' anchors to directive lines only.
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
    log_info "  Validate:  sudo ./setup-systemd.sh --validate"
    log_info "  Test run:  sudo systemctl start vaultwarden-health.service"
    log_info "  View logs: journalctl -u vaultwarden-health.service -n 50"
    log_info "  Env file:  $ENV_FILE  (add EMAIL_PROVIDER credentials here)"
    log_info "  Age key:   $AGE_KEY_DEST  (copied from secrets/keys/age-key.txt)"
}

# ---------------------------------------------------------------------------
# remove_units
# ---------------------------------------------------------------------------
remove_units() {
    _require_root
    log_header "VaultWarden-OCI systemd Timer Removal"

    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            # FIX-S15: log failures instead of hiding them
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
    _require_root
    log_header "VaultWarden-OCI Installation Validation"
    local errors=0
    local warnings=0

    log_info "[1/7] Checking installed scripts ..."
    local scripts_to_check=(maintenance.sh backup.sh health.sh)
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

    log_info "[2/7] Checking installed lib/ ..."
    if [[ ! -d "$OPT_SCRIPTS_DIR/lib" ]]; then
        log_error "  MISSING: $OPT_SCRIPTS_DIR/lib/"
        (( errors++ )) || true
    else
        log_success "  OK: $OPT_SCRIPTS_DIR/lib/"
    fi
    local critical_lib="$OPT_SCRIPTS_DIR/lib/simple_key_resilience.sh"
    if [[ ! -f "$critical_lib" ]]; then
        log_error "  MISSING: $critical_lib"
        (( errors++ )) || true
    else
        log_success "  OK: $critical_lib"
    fi

    log_info "[3/7] Checking installed unit files ..."
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ ! -f "$dest" ]]; then
            log_error "  MISSING: $dest"
            (( errors++ )) || true
        else
            log_success "  OK: $dest"
        fi
    done

    log_info "[4/7] Checking timer enablement ..."
    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            log_success "  ENABLED:     $timer"
        else
            log_error   "  NOT ENABLED: $timer"
            (( errors++ )) || true
        fi
    done

    log_info "[5/7] Checking EnvironmentFile ..."
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "  MISSING: $ENV_FILE"
        log_error "  Run: sudo ./setup-systemd.sh --install  (or create it manually)"
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

    log_info "[6/7] Checking age key installation (BUG-AK1) ..."
    if [[ ! -f "$AGE_KEY_DEST" ]]; then
        log_error "  MISSING: $AGE_KEY_DEST"
        log_error "  Backup/health services cannot encrypt/decrypt without this key."
        log_error "  Fix: sudo ./setup-systemd.sh --install  (requires secrets/keys/age-key.txt)"
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
                log_warn "  Fix: sudo ./setup-systemd.sh --install"
                (( warnings++ )) || true
            fi
        else
            log_error "  SOPS_AGE_KEY_FILE not set in $ENV_FILE"
            log_error "  Fix: sudo ./setup-systemd.sh --install"
            (( errors++ )) || true
        fi
    fi

    log_info "[7/7] Checking for split-brain (sha256 repo vs installed) ..."
    for script in "${scripts_to_check[@]}"; do
        local repo_src="$SCRIPT_DIR/$script"
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
            log_warn "         Re-run: sudo ./setup-systemd.sh --install"
            (( warnings++ )) || true
        else
            log_success "  UP-TO-DATE: $script (sha256 match)"
        fi
    done

    echo ""
    if (( errors > 0 )); then
        log_error "Validation FAILED: ${errors} error(s), ${warnings} warning(s)."
        log_error "Run: sudo ./setup-systemd.sh --install to resolve errors."
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

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
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

    log_info "No operation specified. Use --help for options."
    show_help
    exit 1
}

main "$@"
