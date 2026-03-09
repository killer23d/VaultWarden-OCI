#!/usr/bin/env bash
# systemd-setup.sh - Install and manage VaultWarden-OCI systemd timers
#
# Replaces cron-setup.sh for new deployments. Manages the 6 scheduled
# service+timer pairs in the systemd/ directory.
#
# USAGE:
#   sudo ./systemd-setup.sh --install    # Install and enable all timers
#   sudo ./systemd-setup.sh --remove     # Disable and remove all units
#   sudo ./systemd-setup.sh --validate   # Verify installed state vs repo
#   sudo ./systemd-setup.sh --status     # Show timer/service status
#   sudo ./systemd-setup.sh --dry-run    # Print actions without executing
#
# FIX-S06  (2026-03-09): --validate subcommand added. Checks scripts,
#          lib/, unit files, timer enablement, EnvironmentFile permissions,
#          and split-brain (installed-vs-repo staleness). Safe for CI/CD.
# FIX-S07  (2026-03-09): Script patching no longer uses $() command
#          substitution. bash $() strips trailing newlines silently.
#          Patched content is now written via sed directly into a mktemp
#          file; a line-count sanity check aborts on truncation.
# FIX-S08  (2026-03-09): --remove now emits a prominent warning that
#          /etc/vaultwarden/vaultwarden.env was intentionally left in
#          place and may contain credentials.
# FIX-S09  (2026-03-09): --validate now requires root. /etc/vaultwarden/
#          is chmod 700 (root-only); running as non-root caused stat() to
#          return "unknown" permissions (spurious WARN) and systemctl
#          is-enabled to give inaccurate results on some D-Bus configs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"

INSTALL=false
REMOVE=false
STATUS=false
VALIDATE=false
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
    --validate    Verify installed state matches repo; detect split-brain
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

WHAT --validate CHECKS:
    1. Scripts present and executable in /opt/vaultwarden-scripts/
    2. lib/ and simple_key_resilience.sh present
    3. All unit files present in /etc/systemd/system/
    4. All 6 timers enabled (systemctl is-enabled)
    5. EnvironmentFile /etc/vaultwarden/vaultwarden.env exists (mode 600)
    6. Installed scripts not older than repo source (split-brain detection)
       Re-run --install after any git pull to keep /opt/ in sync.

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
        --install)   INSTALL=true;   shift ;;
        --remove)    REMOVE=true;    shift ;;
        --validate)  VALIDATE=true;  shift ;;
        --status)    STATUS=true;    shift ;;
        --dry-run)   DRY_RUN=true;   shift ;;
        --help)      show_help; exit 0 ;;
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

        # FIX-S07: Do NOT use $() command substitution to capture patched content.
        # bash $() strips all trailing newlines — a script ending with one or more
        # blank lines (common for readability) will lose those lines silently,
        # causing the installed copy to quietly differ from the repo source.
        #
        # Fix: redirect sed output directly into a mktemp file, then run a
        # line-count sanity check before an atomic mv into place. This preserves
        # every byte of the source except the three intentional substitutions.
        local tmp_script
        tmp_script=$(mktemp "${TMPDIR:-/tmp}/vw-patch-XXXXXX")
        # Ensure tmp_script is cleaned up on any early return from this loop
        # iteration (set -e exit, explicit return, or abnormal signal).
        trap 'rm -f "${tmp_script:-}" 2>/dev/null; trap - RETURN' RETURN
        sed \
            -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$OPT_SCRIPTS_DIR\"|" \
            -e "s|^PROJECT_ROOT=\"\$SCRIPT_DIR\"|PROJECT_ROOT=\"$PROJECT_ROOT\"|" \
            -e 's|source "lib/|source "$SCRIPT_DIR/lib/|g' \
            "$src" > "$tmp_script"

        # Sanity check: installed line count must be >= source line count.
        # A mismatch means sed failed or output was truncated unexpectedly.
        local src_lines installed_lines
        src_lines=$(wc -l < "$src")
        installed_lines=$(wc -l < "$tmp_script")
        if (( installed_lines < src_lines - 1 )); then
            log_error "Line count mismatch after patching $script:"
            log_error "  source=${src_lines} lines  installed=${installed_lines} lines"
            log_error "Refusing to deploy a potentially truncated file."
            rm -f "$tmp_script"
            return 1
        fi

        mv "$tmp_script" "$OPT_SCRIPTS_DIR/$script"
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
    log_info "  Validate:  sudo ./systemd-setup.sh --validate"
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

    # FIX-S08: --remove intentionally does NOT delete $ENV_FILE because it may
    # contain API tokens and SMTP credentials that the operator has not yet
    # backed up elsewhere. Silently deleting a secrets file is a data-loss
    # risk; silently retaining it is a data-retention risk. We keep it and
    # emit a prominent warning so the operator makes a deliberate decision.
    if [[ -f "$ENV_FILE" ]]; then
        log_warn "────────────────────────────────────────────────────────────────"
        log_warn "NOTICE: EnvironmentFile was NOT removed automatically:"
        log_warn "  $ENV_FILE"
        log_warn "This file may contain API tokens and SMTP credentials."
        log_warn "Review its contents and remove it manually once you have"
        log_warn "confirmed the credentials are no longer needed or have been"
        log_warn "migrated elsewhere:"
        log_warn "  sudo rm -f $ENV_FILE"
        log_warn "  sudo rmdir --ignore-fail-on-non-empty $ENV_DIR"
        log_warn "────────────────────────────────────────────────────────────────"
    fi
}

# ---------------------------------------------------------------------------
# validate_installation  (FIX-S06)
#
# Verifies that the installed state in /opt/ and /etc/systemd/system/ matches
# the repository source. Exits 0 only if every check passes; exits 1 on any
# error, making it safe to gate on in CI/CD or post-deploy pipelines.
#
# Checks performed:
#   1. Required scripts present and executable in $OPT_SCRIPTS_DIR
#   2. lib/ and simple_key_resilience.sh present in $OPT_SCRIPTS_DIR/lib/
#   3. All unit files present in $UNIT_DEST_DIR
#   4. All 6 timers enabled (systemctl is-enabled)
#   5. EnvironmentFile $ENV_FILE exists with mode 600
#   6. Split-brain: installed script mtime vs repo source mtime (-nt check)
#      warns when a git pull was done but --install was not re-run
#
# FIX-S09: Requires root. /etc/vaultwarden/ is chmod 700; non-root stat()
#   returns EACCES, triggering the "unknown" permissions fallback and a
#   spurious WARN. systemctl is-enabled may also return inaccurate results
#   without D-Bus access.
# ---------------------------------------------------------------------------
validate_installation() {
    # FIX-S09: /etc/vaultwarden/ is root-only (chmod 700) and systemctl
    # is-enabled requires D-Bus access. Require root like all other subcommands.
    _require_root
    log_header "VaultWarden-OCI Installation Validation"
    local errors=0
    local warnings=0

    # ── 1. Scripts in /opt/vaultwarden-scripts/ ─────────────────────────────
    log_info "[1/6] Checking installed scripts ..."
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

    # ── 2. lib/ directory ───────────────────────────────────────────────────
    log_info "[2/6] Checking installed lib/ ..."
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

    # ── 3. Unit files in /etc/systemd/system/ ───────────────────────────────
    log_info "[3/6] Checking installed unit files ..."
    for unit in "${SERVICES[@]}" "${TIMERS[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ ! -f "$dest" ]]; then
            log_error "  MISSING: $dest"
            (( errors++ )) || true
        else
            log_success "  OK: $dest"
        fi
    done

    # ── 4. Timers enabled ───────────────────────────────────────────────────
    log_info "[4/6] Checking timer enablement ..."
    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            log_success "  ENABLED:     $timer"
        else
            log_error   "  NOT ENABLED: $timer"
            (( errors++ )) || true
        fi
    done

    # ── 5. EnvironmentFile ──────────────────────────────────────────────────
    log_info "[5/6] Checking EnvironmentFile ..."
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "  MISSING: $ENV_FILE"
        log_error "  Run: sudo ./systemd-setup.sh --install  (or create it manually)"
        (( errors++ )) || true
    else
        # stat -c is GNU (Linux); stat -f is BSD (macOS) — handle both
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

    # ── 6. Split-brain detection ─────────────────────────────────────────────
    # If the repo source file is NEWER than the installed copy, the operator
    # did a git pull but forgot to re-run --install. The installed scripts are
    # stale and may be missing bug fixes or new features.
    log_info "[6/6] Checking for split-brain (repo newer than installed) ..."
    for script in "${scripts_to_check[@]}"; do
        local repo_src="$PROJECT_ROOT/$script"
        local installed="$OPT_SCRIPTS_DIR/$script"
        if [[ ! -f "$repo_src" || ! -f "$installed" ]]; then
            continue  # already flagged in check 1 above
        fi
        if [[ "$repo_src" -nt "$installed" ]]; then
            log_warn "  STALE: $installed is older than repo source $repo_src"
            log_warn "         Re-run: sudo ./systemd-setup.sh --install"
            (( warnings++ )) || true
        else
            log_success "  UP-TO-DATE: $script"
        fi
    done

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    if (( errors > 0 )); then
        log_error "Validation FAILED: ${errors} error(s), ${warnings} warning(s)."
        log_error "Run: sudo ./systemd-setup.sh --install to resolve errors."
        return 1
    elif (( warnings > 0 )); then
        log_warn  "Validation passed with ${warnings} warning(s) — review output above."
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
