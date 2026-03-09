#!/usr/bin/env bash
# systemd-setup.sh - Install and manage VaultWarden-OCI systemd timers
#
# Replaces cron-setup.sh for new deployments. Manages the 6 scheduled
# service+timer pairs in the systemd/ directory.
#
# USAGE:
#   sudo ./systemd-setup.sh --install    # Install and enable all timers
#   sudo ./systemd-setup.sh --remove     # Disable and remove all units
#   sudo ./systemd-setup.sh --status     # Show timer/service status
#   sudo ./systemd-setup.sh --dry-run    # Print actions without executing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

INSTALL=false
REMOVE=false
STATUS=false
DRY_RUN=false

# FIX-S03: Capture original script arguments before the option-parsing loop
# consumes them via `shift`. _require_root() previously used bare `$*` which
# refers to the function's own (empty) positional parameters, so the re-run
# hint always printed without a subcommand. ${_ORIG_ARGS[*]} preserves exactly
# what the operator typed (e.g. --install --dry-run).
_ORIG_ARGS=("$@")

UNIT_SOURCE_DIR="$PROJECT_ROOT/systemd"
UNIT_DEST_DIR="/etc/systemd/system"
OPT_SCRIPTS_DIR="/opt/vaultwarden-scripts"
ENV_DIR="/etc/vaultwarden"
ENV_FILE="$ENV_DIR/vaultwarden.env"

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
    sudo ./systemd-setup.sh [OPTIONS]

OPTIONS:
    --install     Install and enable all systemd timer units
    --remove      Disable and remove all systemd timer units
    --status      Show timer and service status
    --dry-run     Print actions without executing
    --help        Show this help

WHAT --install DOES:
    1. Copies maintenance.sh, backup.sh, health.sh -> /opt/vaultwarden-scripts/
       (root:root 700, with SCRIPT_DIR + lib/ source paths patched)
    2. Copies lib/ -> /opt/vaultwarden-scripts/lib/ (root:root 640)
    3. Copies .env -> /etc/vaultwarden/vaultwarden.env (root:root 600)
       (skipped if the EnvironmentFile already exists)
    4. Copies systemd/*.{service,timer} -> /etc/systemd/system/
    5. systemctl daemon-reload
    6. systemctl enable --now for all 6 timers

VIEWING LOGS:
    journalctl -u vaultwarden-health.service -n 50
    journalctl -u vaultwarden-db-backup.service -n 100
    systemctl list-timers --all | grep vaultwarden

MIGRATING FROM CRON:
    cron-setup.sh has been removed. To migrate:
    1. sudo ./systemd-setup.sh --install
    2. Remove old crontab entries: sudo crontab -e
    3. Verify timers: systemctl list-timers --all | grep vaultwarden
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --install)  INSTALL=true;  shift ;;
        --remove)   REMOVE=true;   shift ;;
        --status)   STATUS=true;   shift ;;
        --dry-run)  DRY_RUN=true;  shift ;;
        --help)     show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# FIX-S03: Use ${_ORIG_ARGS[*]} (captured before option parsing) so the hint
# reflects the exact subcommand the operator ran, e.g.:
#   Use: sudo ./systemd-setup.sh --install
_require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        log_info  "Use: sudo $0 ${_ORIG_ARGS[*]}"
        exit 1
    fi
}

_run() {
    # Execute or print-only depending on DRY_RUN.
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
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

    # Copy lib/ with -rP (no symlink-follow, same as cron-setup.sh BUG-C03 fix)
    if [[ "$DRY_RUN" == "false" ]]; then
        cp -rP "$PROJECT_ROOT/lib" "$OPT_SCRIPTS_DIR/"
        find "$OPT_SCRIPTS_DIR/lib" -type f -exec chmod 640 {} \; 2>/dev/null || true
        find "$OPT_SCRIPTS_DIR/lib" -type d -exec chmod 750 {} \; 2>/dev/null || true
        chown -R root:root "$OPT_SCRIPTS_DIR/lib"
        log_success "Installed lib/ to $OPT_SCRIPTS_DIR/lib/"
    else
        log_info "[DRY RUN] Would copy lib/ -> $OPT_SCRIPTS_DIR/lib/"
    fi

    # Verify simple_key_resilience.sh is present (mirrors cron-setup.sh ISSUE 15 check)
    if [[ "$DRY_RUN" == "false" ]] && [[ ! -f "$OPT_SCRIPTS_DIR/lib/simple_key_resilience.sh" ]]; then
        log_error "CRITICAL: lib/simple_key_resilience.sh missing from repo -- key health checks disabled."
        log_error "Ensure lib/simple_key_resilience.sh exists in: $PROJECT_ROOT/lib/"
        return 1
    fi

    local scripts_to_install=(maintenance.sh backup.sh health.sh)
    for script in "${scripts_to_install[@]}"; do
        local src="$PROJECT_ROOT/$script"
        if [[ ! -f "$src" ]]; then
            log_warn "Script not found, skipping: $src"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $OPT_SCRIPTS_DIR/$script"
            continue
        fi
        # Patch SCRIPT_DIR, PROJECT_ROOT, and lib source paths for /opt/ tree
        local patched_content
        patched_content=$(
            sed \
                -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$OPT_SCRIPTS_DIR\"|" \
                -e "s|^PROJECT_ROOT=\"\$SCRIPT_DIR\"|PROJECT_ROOT=\"$PROJECT_ROOT\"|" \
                -e 's|source "lib/|source "$SCRIPT_DIR/lib/|g' \
                "$src"
        )
        printf '%s\n' "$patched_content" > "$OPT_SCRIPTS_DIR/$script"
        chmod 700 "$OPT_SCRIPTS_DIR/$script"
        chown root:root "$OPT_SCRIPTS_DIR/$script"
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
            log_info "$ENV_FILE already exists -- skipping (not overwritten)"
        fi
    else
        log_info "[DRY RUN] Would create $ENV_FILE from .env"
    fi

    # ------------------------------------------------------------------
    # 3. Copy unit files to /etc/systemd/system/
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

    # ------------------------------------------------------------------
    # 4. Reload daemon + enable timers
    # ------------------------------------------------------------------
    log_info "Reloading systemd daemon ..."
    _run systemctl daemon-reload

    log_info "Enabling and starting timers ..."
    for timer in "${TIMERS[@]}"; do
        _run systemctl enable --now "$timer"
        log_success "Enabled: $timer"
    done

    log_success "Installation complete."
    log_info "Next steps:"
    log_info "  Verify:    systemctl list-timers --all | grep vaultwarden"
    log_info "  Test run:  sudo systemctl start vaultwarden-health.service"
    log_info "  View logs: journalctl -u vaultwarden-health.service -n 50"
    log_info "  Env file:  $ENV_FILE  (add EMAIL_PROVIDER credentials here)"
}

# ---------------------------------------------------------------------------
# remove_units
# ---------------------------------------------------------------------------
remove_units() {
    _require_root
    log_header "VaultWarden-OCI systemd Timer Removal"

    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" 2>/dev/null; then
            _run systemctl disable --now "$timer" 2>/dev/null || true
            log_success "Disabled: $timer"
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
        # Skip template unit in status loop
        [[ "$svc" == *"@"* ]] && continue
        log_info "--- $svc ---"
        systemctl status "$svc" --no-pager -l 2>/dev/null | head -12 || true
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
