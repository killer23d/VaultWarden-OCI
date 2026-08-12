#!/usr/bin/env bash
# utilities/setup-systemd.sh — Installs and validates VaultWarden-OCI systemd timers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
# shellcheck source=../lib/operations.sh
source "${PROJECT_ROOT}/lib/operations.sh"

trap 'log_error "${BASH_SOURCE[0]}: failed at line ${LINENO} (exit $?)"; exit 1' ERR

INSTALL=false
REMOVE=false
STATUS=false
VALIDATE=false
DRY_RUN=false
START_POLICY=""

UNIT_SOURCE_DIR="${PROJECT_ROOT}/systemd"
UNIT_DEST_DIR="${VW_SYSTEMD_UNIT_DEST_DIR:-/etc/systemd/system}"
OPT_SCRIPTS_DIR="${VW_SYSTEMD_OPT_SCRIPTS_DIR:-/opt/vaultwarden-scripts}"
ENV_DIR="${VW_SYSTEMD_ENV_DIR:-/etc/vaultwarden}"
ENV_FILE="${ENV_DIR}/vaultwarden.env"
AGE_KEY_DEST="${ENV_DIR}/age-key.txt"
STARTUP_SERVICE="vaultwarden-startup.service"
NOTIFY_FAILURE_TEMPLATE="vaultwarden-notify-failure@.service"
DOCKER_RUNTIME_DROPIN="${UNIT_DEST_DIR}/docker.service.d/20-vaultwarden-runtime.conf"
SETUP_SYSTEMD_GUARD_HELD=false

TIMERS=(
    vaultwarden-maintenance.timer
    vaultwarden-db-backup.timer
    vaultwarden-full-backup.timer
    vaultwarden-health.timer
    vaultwarden-dns-update.timer
    vaultwarden-firewall-update.timer
)

COPIED_SERVICES=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
    vaultwarden-health.service
    vaultwarden-dns-update.service
    vaultwarden-firewall-update.service
    vaultwarden-notify-failure.service
    "$NOTIFY_FAILURE_TEMPLATE"
    vaultwarden-iptables.service
)

BACKGROUND_PRIORITY_SERVICES=(
    vaultwarden-maintenance.service
    vaultwarden-db-backup.service
    vaultwarden-full-backup.service
)

MANAGED_UNITS=("${COPIED_SERVICES[@]}" "${TIMERS[@]}")

INSTALLED_SCRIPT_PATHS=(
    startup.sh
    maintenance.sh
    backup.sh
    restore.sh
    utilities/setup-firewall.sh
    utilities/maintenance-run.sh
    utilities/maintenance-health.sh
    utilities/maintenance-update.sh
    utilities/maintenance-db-maint.sh
    utilities/maintenance-email.sh
    utilities/maintenance-update-dns.sh
    utilities/notify-failure.sh
    utilities/maintenance-update-firewall.sh
    utilities/backup-run.sh
    utilities/restore-run.sh
)

# Public, non-secret files required by startup and the Compose/Caddy runtime.
# docker-compose.yml is the currently approved live model; the .example copy is
# also needed by lib/schema.sh for schema target validation.
STARTUP_RUNTIME_FILE_PATHS=(
    docker-compose.yml
    docker-compose.yml.example
    secrets-schema.yaml
    VERSION
    caddy/Caddyfile
    caddy/Caddyfile.degraded
    caddy/Dockerfile
)

STARTUP_RUNTIME_EXECUTABLE_PATHS=(
    caddy/entrypoint.sh
)

# Timers skip identity checks. All managed units receive data-volume mount
# ordering; vaultwarden-iptables.service is read-only and is special-cased below
# so it does not receive a state-directory write grant.
_ROOT_REQUIRED_UNITS=("${COPIED_SERVICES[@]}" "$STARTUP_SERVICE")
_VW_DROPIN_UNITS=("${COPIED_SERVICES[@]}" "${TIMERS[@]}")

_setup_systemd_acquire_guard() {
    local label="$1" phase="$2"
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ "$SETUP_SYSTEMD_GUARD_HELD" == "true" ]] && return 0

    local policy="fail"
    if [[ ! -t 0 || ! -t 1 ]]; then
        policy="skip"
    fi
    operation_acquire \
        --id systemd-install \
        --label "$label" \
        --specific-lock /run/lock/vaultwarden-systemd.lock \
        --non-interactive "$policy" || return $?
    SETUP_SYSTEMD_GUARD_HELD=true
    _setup_systemd_cleanup() {
        local rc=$?
        operation_release "$rc"
        return "$rc"
    }
    trap _setup_systemd_cleanup EXIT
    trap 'operation_release 130; exit 130' INT
    trap 'operation_release 143; exit 143' HUP TERM
    operation_set_phase "$phase" "$label"
}

show_help() {
    cat <<'EOF'
VaultWarden-OCI systemd Timer Installer

USAGE:
    sudo utilities/setup-systemd.sh <action> [OPTIONS]
    sudo utilities/setup-systemd.sh install    # Install/enable timers; non-interactive default does not start them
    sudo utilities/setup-systemd.sh remove     # Disable and remove all timers
    sudo utilities/setup-systemd.sh validate   # Verify installed state vs repo
    sudo utilities/setup-systemd.sh status     # Show timer and service status

DESCRIPTION:
    Installs, removes, validates, or shows the status of VaultWarden-OCI
    systemd automation and its root-owned runtime. Re-run install, then validate,
    after managed scripts, libraries, units, or startup runtime assets change.

ACTIONS:
    install   Install and enable all systemd timer units; start only by policy
    remove    Disable and remove all systemd timer units
    validate  Verify installed state matches repo; detect split-brain
    status    Show timer and service status

OPTIONS:
    --dry-run     Print actions without executing
    --start-policy MODE  Timer activation policy: auto | ask | manual
                          manual: install and enable timer units, but do not start them now
                          auto:   enable and start timers now with systemctl enable --now
                          ask:    interactive TTY prompt before immediate timer start
    --enable-now         Alias for --start-policy auto (enable/start timers now)
    --no-enable-now      Alias for --start-policy manual (install-only/manual: enable timers without immediate execution)
    --no-start           Alias for --start-policy manual (install-only/manual: enable timers without immediate execution)

START POLICY SAFETY:
    Non-interactive installs default to manual/install-only: units are installed
    and timers are enabled for future boots, but backup/maintenance jobs are not
    started immediately. Interactive TTY installs ask before starting timers.
    Use --enable-now or --start-policy auto only when you are ready to run jobs.

    Disaster-recovery/new-VM restores should avoid starting backup/maintenance
    jobs until the operator verifies mounted data, secrets, rclone config, DNS,
    firewall state, and VaultWarden service readiness. This prevents a restored
    host from immediately running scheduled jobs against incomplete state.
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

WHAT install DOES:
    1. Copies executable scripts to /opt/vaultwarden-scripts/ (root:root 700):
         startup.sh  maintenance.sh  backup.sh  restore.sh
         utilities/setup-firewall.sh
         utilities/maintenance-run.sh      utilities/maintenance-health.sh
         utilities/maintenance-update.sh   utilities/maintenance-db-maint.sh
         utilities/maintenance-email.sh    utilities/maintenance-update-dns.sh
         utilities/notify-failure.sh       utilities/maintenance-update-firewall.sh
         utilities/backup-run.sh           utilities/restore-run.sh
       Scripts are self-locating via BASH_SOURCE[0]. The utilities/ subdirectory
       structure is preserved at the destination.
    2. Copies lib/ -> /opt/vaultwarden-scripts/lib/ (root:root 644)
    3. Copies public startup runtime assets under /opt/vaultwarden-scripts/:
         docker-compose.yml  docker-compose.yml.example  secrets-schema.yaml  VERSION
         caddy/Caddyfile  caddy/Caddyfile.degraded  caddy/Dockerfile       (root:root 644)
         caddy/entrypoint.sh                                                    (root:root 755)
       Private secrets are not copied into this code bundle.
    4. Installs the authoritative environment file to /etc/vaultwarden/vaultwarden.env (root:root 600)
       using ${PROJECT_STATE_DIR}/config/install.env or the installed runtime authority.
    5. Requires the operational Age key at /etc/vaultwarden/age-key.txt
    6. Copies systemd/*.{service,timer} and renders vaultwarden-startup.service -> /etc/systemd/system/
    7. systemctl daemon-reload
    8. Installs a Docker lifecycle drop-in so firewall reconciliation and startup rerun after dockerd restarts
    9. Enables vaultwarden-startup.service and enables timers; starts timers only according to start policy
   10. If timers were started now, verifies all managed timers are active and have a next trigger

EXAMPLES:
    sudo utilities/setup-systemd.sh install
    sudo utilities/setup-systemd.sh install --no-enable-now   # install-only/manual; enable timers without immediate execution
    sudo utilities/setup-systemd.sh install --enable-now      # enable/start timers now
    sudo utilities/setup-systemd.sh install --dry-run
    sudo utilities/setup-systemd.sh validate
    sudo utilities/setup-systemd.sh status
EOF
}

_require_cli_value() {
    local opt="$1" value="${2-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$opt requires a value."
        show_help
        exit 2
    fi
}

ORIGINAL_ARGS=("$@")
_ACTION=""
_START_POLICY_EXPLICIT=false
while [[ $# -gt 0 ]]; do
    case $1 in
        install|remove|validate|status)
            if [[ -n "$_ACTION" ]]; then
                log_error "Exactly one action is required: install | remove | validate | status"
                log_error "Received both '${_ACTION}' and '$1'."
                show_help
                exit 2
            fi
            _ACTION="$1"
            case "$1" in
                install)  INSTALL=true ;;
                remove)   REMOVE=true ;;
                validate) VALIDATE=true ;;
                status)   STATUS=true ;;
            esac
            shift ;;
        --dry-run)    DRY_RUN=true;   shift ;;
        --start-policy)
            _require_cli_value "$1" "${2-}"
            START_POLICY="$2"; _START_POLICY_EXPLICIT=true; shift 2 ;;
        --enable-now) START_POLICY="auto"; _START_POLICY_EXPLICIT=true; shift ;;
        --no-enable-now|--no-start) START_POLICY="manual"; _START_POLICY_EXPLICIT=true; shift ;;
        help|--help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
        *) log_error "Unknown argument: $1"; show_help; exit 1 ;;
    esac
done

if [[ "$_START_POLICY_EXPLICIT" == "true" && "$INSTALL" != "true" ]]; then
    log_error "Timer start-policy options are only valid for 'install'."
    log_error "Usage: sudo utilities/setup-systemd.sh install [--start-policy auto|ask|manual]"
    exit 2
fi

if [[ "$DRY_RUN" == "true" && "$INSTALL" != "true" && "$REMOVE" != "true" ]]; then
    log_error "--dry-run is only valid for 'install' or 'remove'."
    log_error "Usage: sudo utilities/setup-systemd.sh install --dry-run"
    exit 2
fi

case "${START_POLICY}" in
    "" ) if [[ "$INSTALL" == "true" ]]; then
             if [[ -t 0 ]]; then START_POLICY="ask"; else START_POLICY="manual"; fi
         fi ;;
    auto|ask|manual) ;;
    *) log_error "Invalid --start-policy: ${START_POLICY}"; exit 1 ;;
esac

_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# Return success when a timer has a next scheduled trigger.
_timer_has_next_trigger() {
    local timer="$1"
    local next_elapse
    next_elapse="$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>/dev/null || true)"
    [[ -n "$next_elapse" && "$next_elapse" != "n/a" ]]
}

# Return success when a managed timer is active and has a next trigger.
_timer_is_healthy() {
    local timer="$1"
    systemctl is-active --quiet "$timer" && _timer_has_next_trigger "$timer"
}

# Print unhealthy managed timer names, one per line.
_list_unhealthy_managed_timers() {
    local timer
    for timer in "${TIMERS[@]}"; do
        if ! _timer_is_healthy "$timer"; then
            printf '%s\n' "$timer"
        fi
    done
}

# Return the number of managed timers that are active and scheduled.
_count_healthy_managed_timers() {
    local unhealthy_count
    unhealthy_count="$(_list_unhealthy_managed_timers | wc -l | awk '{print $1}')"
    printf '%s\n' "$((${#TIMERS[@]} - unhealthy_count))"
}

# Shared install/validate timer diagnostics. Prints each unhealthy timer and the
# exact systemctl probes operators need for root-cause analysis.
_report_unhealthy_managed_timers() {
    local context="${1:-timer health check}"
    local -a unhealthy_timers=()
    local timer active_state next_elapse
    mapfile -t unhealthy_timers < <(_list_unhealthy_managed_timers)

    if [[ "${#unhealthy_timers[@]}" -eq 0 ]]; then
        log_success "${context}: all managed timers are active and scheduled (${#TIMERS[@]}/${#TIMERS[@]})."
        return 0
    fi

    log_warn "${context}: unhealthy managed timers detected (${#unhealthy_timers[@]} of ${#TIMERS[@]}):"
    for timer in "${unhealthy_timers[@]}"; do
        log_warn "  UNHEALTHY TIMER: ${timer}"

        log_warn "    systemctl is-active ${timer}"
        active_state="$(systemctl is-active "$timer" 2>&1 || true)"
        log_warn "      ${active_state:-<no output>}"

        log_warn "    systemctl show ${timer} --property=NextElapseUSecRealtime --value"
        next_elapse="$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>&1 || true)"
        log_warn "      ${next_elapse:-<empty>}"

        log_warn "    systemctl status ${timer} --no-pager -l"
        systemctl status "$timer" --no-pager -l 2>&1 | sed 's/^/      /' >&2 || true
    done
    return 1
}

# Print the sha256 digest of a file.
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

_cleanup_stale_identity_dropins() {
    local unit dropin_dir dropin_file

    local -a stale_files=(
        "vaultwarden-db-backup.service.d/30-run-as-root.conf"
        "vaultwarden-full-backup.service.d/30-run-as-root.conf"
    )
    local stale_rel
    for stale_rel in "${stale_files[@]}"; do
        dropin_file="${UNIT_DEST_DIR}/${stale_rel}"
        dropin_dir="$(dirname "$dropin_file")"
        if [[ -f "$dropin_file" ]]; then
            _run rm -f "$dropin_file"
            log_success "Removed stale root identity drop-in: $dropin_file"
        fi
        if [[ -d "$dropin_dir" ]] && [[ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            _run rmdir "$dropin_dir"
            log_success "Removed empty drop-in dir: $dropin_dir"
        fi
    done

    for unit in "${_ROOT_REQUIRED_UNITS[@]}"; do
        dropin_dir="${UNIT_DEST_DIR}/${unit}.d"
        dropin_file="${dropin_dir}/20-identity.conf"
        if [[ -f "$dropin_file" ]]; then
            _run rm -f "$dropin_file"
            log_success "Removed stale identity drop-in from root-required unit: $dropin_file"
        fi
        if [[ -d "$dropin_dir" ]] && [[ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            _run rmdir "$dropin_dir"
            log_success "Removed empty drop-in dir: $dropin_dir"
        fi
    done
}

# so that ProtectSystem=strict allows writes to DATA_VOLUME_MOUNT. Without
# this drop-in, any write to DATA_VOLUME_MOUNT (backup files, health cooldown
# stamps, DB operations) is silently blocked by the kernel, causing runtime
# Permission denied errors that are hard to diagnose from the unit file alone.
#
# Boot-only mode (DATA_VOLUME_DEVICE empty): no-op.
# Dry-run mode: logs what would be written without touching the filesystem.
_install_rwpaths_dropin() {
    local data_device data_mount
    # Read from the installed EnvironmentFile when available so that
    # standalone 'setup-systemd.sh install' runs (without CLI flags) pick up
    # the correct value written by a previous full setup run.
    if [[ -f "$ENV_FILE" ]]; then
        data_device=$(_read_env_value "DATA_VOLUME_DEVICE" "$ENV_FILE")
        data_mount=$(_read_env_value "DATA_VOLUME_MOUNT"  "$ENV_FILE")
    fi
    # Fall back to environment variables.
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

    local -a _DROPIN_UNITS=("${_VW_DROPIN_UNITS[@]}")

    log_info "Installing per-unit state-dir drop-ins for DATA_VOLUME_MOUNT=${data_mount} ..."
    local unit dropin_dir dropin_file _mount_unit
    _mount_unit=$(systemd-escape --path --suffix=mount "$data_mount" 2>/dev/null) || {
        log_error "systemd-escape failed for DATA_VOLUME_MOUNT=$data_mount"
        return 1
    }
    for unit in "${_DROPIN_UNITS[@]}"; do
        dropin_dir="${UNIT_DEST_DIR}/${unit}.d"
        dropin_file="${dropin_dir}/10-state-dir.conf"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would write state-dir drop-in: $dropin_file"
            continue
        fi
        mkdir -p "$dropin_dir" || { log_error "Cannot create drop-in dir: $dropin_dir"; return 1; }
        cat > "$dropin_file" << DROPIN
# Written by setup-systemd.sh install — do not edit by hand.
# Regenerate: sudo utilities/setup-systemd.sh install
#
# [Unit]  After=  — this unit waits for the data volume to be mounted before
#                   starting, even when triggered by a timer or dependency chain.
[Unit]
After=${_mount_unit}
DROPIN

        if [[ "$unit" == *.service && "$unit" != "vaultwarden-iptables.service" ]]; then
            cat >> "$dropin_file" << DROPIN
# [Service] ReadWritePaths= — grants write access to DATA_VOLUME_MOUNT under
#                             ProtectSystem=strict (without this, all writes to
#                             the data volume are silently denied by the kernel).
[Service]
ReadWritePaths=${data_mount}
DROPIN
        fi
        chmod 644 "$dropin_file"
        log_success "Installed state-dir drop-in: $dropin_file"
    done
}

_render_docker_runtime_dropin() {
    cat <<'DROPIN'
# Managed by VaultWarden-OCI setup-systemd.sh — do not edit by hand.
# Caddy uses restart: on-failure, which does not auto-start on dockerd restart.
[Unit]
Wants=vaultwarden-iptables.service vaultwarden-startup.service
DROPIN
}

_install_docker_runtime_dropin() {
    local dropin_dir tmp
    dropin_dir="$(dirname "$DOCKER_RUNTIME_DROPIN")"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
        return 0
    fi
    mkdir -p "$dropin_dir" || {
        log_error "Cannot create Docker systemd drop-in directory: $dropin_dir"
        return 1
    }
    tmp="$(mktemp -p "$dropin_dir" .20-vaultwarden-runtime.XXXXXXXXXX)" || return 1
    _render_docker_runtime_dropin > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$DOCKER_RUNTIME_DROPIN" || { rm -f "$tmp"; return 1; }
    log_success "Installed Docker runtime owner drop-in: $DOCKER_RUNTIME_DROPIN"
}

_validate_docker_runtime_dropin() {
    local expected owner group mode rc=0
    if [[ ! -f "$DOCKER_RUNTIME_DROPIN" ]]; then
        log_error "  MISSING: $DOCKER_RUNTIME_DROPIN"
        log_error "  Docker restarts would not re-run firewall reconciliation/startup."
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        return 1
    fi

    expected="$(mktemp)" || return 1
    _render_docker_runtime_dropin > "$expected" || { rm -f "$expected"; return 1; }
    if ! cmp -s "$expected" "$DOCKER_RUNTIME_DROPIN"; then
        log_error "  DRIFT: $DOCKER_RUNTIME_DROPIN does not match the managed Docker lifecycle contract"
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        rc=1
    fi
    rm -f "$expected"

    owner="$(stat -c '%U' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    group="$(stat -c '%G' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    mode="$(stat -c '%a' "$DOCKER_RUNTIME_DROPIN" 2>/dev/null || echo unknown)"
    if [[ "$owner" != root || "$group" != root || "$mode" != 644 ]]; then
        log_error "  PERMISSIONS: $DOCKER_RUNTIME_DROPIN is ${owner}:${group} mode ${mode} (expected root:root 644)"
        log_error "  Fix: sudo utilities/setup-systemd.sh install"
        rc=1
    fi
    [[ "$rc" -eq 0 ]] && log_success "  OK: $DOCKER_RUNTIME_DROPIN"
    return "$rc"
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

_sync_runtime_environment_files() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run utilities/env-edit.sh sync to regenerate install.env and $ENV_FILE"
        return 0
    fi

    log_info "Regenerating runtime environment files via env-edit sync..."
    "${PROJECT_ROOT}/utilities/env-edit.sh" sync || return 1
    log_success "Runtime environment files regenerated by env-edit sync"
}

_render_startup_expected() {
    local dest="$1"
    local template="$UNIT_SOURCE_DIR/$STARTUP_SERVICE"
    sed -e "s|@STARTUP_RUNTIME_DIR@|$OPT_SCRIPTS_DIR|g" \
        -e "s|@PROJECT_STATE_DIR@|${PROJECT_STATE_DIR:-/var/lib/vaultwarden}|g" \
        "$template" > "$dest"
}

_render_startup_service() {
    local template="$UNIT_SOURCE_DIR/$STARTUP_SERVICE"
    local dest="$UNIT_DEST_DIR/$STARTUP_SERVICE"
    [[ -f "$template" ]] || { log_error "Missing startup service template: $template"; return 1; }
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would render $STARTUP_SERVICE with STARTUP_RUNTIME_DIR=$OPT_SCRIPTS_DIR PROJECT_STATE_DIR=${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
        return 0
    fi
    local tmp
    tmp=$(mktemp -p "$UNIT_DEST_DIR" "${STARTUP_SERVICE}.XXXXXXXXXX") || return 1
    _render_startup_expected "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    log_success "Installed unit: $STARTUP_SERVICE"
}

install_units() {
    _setup_systemd_acquire_guard "Systemd install" "install" || exit $?
    log_header "VaultWarden-OCI systemd Timer Installation"

    if [[ ! -d "$UNIT_SOURCE_DIR" ]]; then
        log_error "systemd unit directory not found: $UNIT_SOURCE_DIR"
        log_error "Run from the VaultWarden-OCI repository root."
        return 1
    fi

    local script asset unit
    for script in "${INSTALLED_SCRIPT_PATHS[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$script" ]]; then
            log_error "Required repository script not found: $PROJECT_ROOT/$script"
            return 1
        fi
    done
    for asset in "${STARTUP_RUNTIME_FILE_PATHS[@]}" "${STARTUP_RUNTIME_EXECUTABLE_PATHS[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$asset" ]]; then
            log_error "Required startup runtime asset not found: $PROJECT_ROOT/$asset"
            return 1
        fi
    done
    for unit in "${MANAGED_UNITS[@]}" "$STARTUP_SERVICE"; do
        if [[ ! -f "$UNIT_SOURCE_DIR/$unit" ]]; then
            log_error "Required unit file not found: $UNIT_SOURCE_DIR/$unit"
            return 1
        fi
    done

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

    for script in "${INSTALLED_SCRIPT_PATHS[@]}"; do
        local src="$PROJECT_ROOT/$script"
        local dest="$OPT_SCRIPTS_DIR/$script"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install: $dest (700 root:root)"
            continue
        fi
        install -d -m 755 -o root -g root "$(dirname "$dest")"
        install -m 700 -o root -g root "$src" "$dest"
        log_success "Installed: $dest"
    done

    log_info "Installing startup runtime assets to $OPT_SCRIPTS_DIR ..."
    for asset in "${STARTUP_RUNTIME_FILE_PATHS[@]}"; do
        local src="$PROJECT_ROOT/$asset"
        local dest="$OPT_SCRIPTS_DIR/$asset"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install startup runtime asset: $dest (644 root:root)"
            continue
        fi
        install -d -m 755 -o root -g root "$(dirname "$dest")"
        install -m 644 -o root -g root "$src" "$dest"
        log_success "Installed startup runtime asset: $dest"
    done
    for asset in "${STARTUP_RUNTIME_EXECUTABLE_PATHS[@]}"; do
        local src="$PROJECT_ROOT/$asset"
        local dest="$OPT_SCRIPTS_DIR/$asset"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would install startup runtime asset: $dest (755 root:root)"
            continue
        fi
        install -d -m 755 -o root -g root "$(dirname "$dest")"
        install -m 755 -o root -g root "$src" "$dest"
        log_success "Installed startup runtime asset: $dest"
    done
    if [[ "$DRY_RUN" == "false" ]]; then
        chown root:root "$OPT_SCRIPTS_DIR"
        chmod 755 "$OPT_SCRIPTS_DIR"
    fi

    # The operational Age key is provisioned directly at its canonical path.
    log_info "Checking canonical age key at $AGE_KEY_DEST ..."
    if [[ -f "$AGE_KEY_DEST" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would validate root:root 600 on $AGE_KEY_DEST"
        else
            fix_known_path_permissions "$AGE_KEY_DEST"
            log_success "Canonical age key present: $AGE_KEY_DEST"
        fi
    else
        log_warn "Canonical Age key is missing: $AGE_KEY_DEST"
        log_warn "Install the correct operational key there, then rerun this command."
    fi

    local rclone_dest="$ENV_DIR/rclone.conf"
    log_info "Setting up rclone config at $rclone_dest ..."

    if [[ -f "$rclone_dest" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            fix_known_path_permissions "$rclone_dest"
        fi
        log_success "rclone config already at $rclone_dest"
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
                log_info "[DRY RUN] sync-env would set RCLONE_CONFIG=$rclone_dest in generated runtime env files"
            else
                install -m 600 -o root -g root "$rclone_src" "$rclone_dest"
                log_success "Installed rclone config: $rclone_dest (source: $rclone_src)"
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
            log_warn "    sudo make sync-env"
        fi
    fi

    _sync_runtime_environment_files || return 1

    log_info "Installing systemd unit files to $UNIT_DEST_DIR ..."
    for unit in "${MANAGED_UNITS[@]}"; do
        local src="$UNIT_SOURCE_DIR/$unit"
        _run cp "$src" "$UNIT_DEST_DIR/$unit"
        _run chmod 644 "$UNIT_DEST_DIR/$unit"
        log_success "Installed unit: $unit"
    done

    _render_startup_service || return 1

    _install_docker_runtime_dropin || return 1
    _install_rwpaths_dropin
    _cleanup_stale_identity_dropins

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
            local cal_expr; cal_expr=$(grep -m1 '^OnCalendar=' "$unit" | cut -d= -f2-)
            if [[ -n "$cal_expr" ]]; then
                if ! systemd-analyze calendar "$cal_expr" >/dev/null 2>&1; then
                    log_warn "Timer $(basename "$unit") has an invalid OnCalendar expression '$cal_expr' — check the unit file"
                fi
            fi
        done
    fi

    _run systemctl enable "$STARTUP_SERVICE"
    log_success "Enabled: $STARTUP_SERVICE"

    local _enable_now=false
    case "$START_POLICY" in
        auto) _enable_now=true ;;
        ask)
            local _answer
            read -r -t 300 -p "Enable and start backup/maintenance timers now? [yes/no] (default: no): " _answer || _answer="no"
            case "$_answer" in y|Y|yes|YES) _enable_now=true ;; esac
            ;;
        manual) _enable_now=false ;;
    esac
    if [[ "$_enable_now" == "true" ]]; then
        log_info "Enabling and starting timers ..."
        for timer in "${TIMERS[@]}"; do
            _run systemctl enable --now "$timer"
            log_success "Enabled and started: $timer"
        done
    else
        log_warn "Timers installed but not started by operator start policy."
        log_warn "Install-only/manual state is not production-ready until timers are activated and validation passes."
        log_info "Start later with: sudo utilities/setup-systemd.sh install --enable-now"
        log_info "Or run: sudo systemctl enable --now ${TIMERS[*]}"
        for timer in "${TIMERS[@]}"; do
            _run systemctl enable "$timer"
            log_success "Enabled: $timer"
        done
    fi

    # Verify managed timers are healthy after enablement.
    # list-timers output can lag briefly right after daemon-reload/enable.
    # Check each managed timer state directly and allow a short settle period.
    # Healthy = timer unit is active AND has a next trigger scheduled.
    if [[ "$DRY_RUN" == "false" && "$_enable_now" == "true" ]]; then
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
            _report_unhealthy_managed_timers "Post-install timer health"
        else
            log_warn "────────────────────────────────────────────────────────────────"
            log_warn "WARNING: Not all managed timers are healthy after enablement"
            log_warn "Possible causes:"
            log_warn "  - A timer unit has an invalid setting (e.g. bad OnCalendar)"
            log_warn "  - A timer is being stopped by a conflicting unit relationship"
            log_warn "  - A timer is active but has no next trigger (NEXT='-')"
            log_warn "  - systemd daemon has stale unit state (retry daemon-reload)"
            _report_unhealthy_managed_timers "Post-install timer health" || true
            log_warn "────────────────────────────────────────────────────────────────"
            return 1
        fi
    else
        log_info "[DRY RUN] Would check: systemctl is-active + NextElapseUSecRealtime for all managed timers"
    fi

    log_info "Clearing stale failed status from all managed services ..."
    for svc in "${COPIED_SERVICES[@]}" "$STARTUP_SERVICE"; do
        [[ "$svc" == "$NOTIFY_FAILURE_TEMPLATE" ]] && continue
        _run systemctl reset-failed "$svc" 2>/dev/null || true
    done
    _run systemctl reset-failed 'vaultwarden-notify-failure@*.service' 2>/dev/null || true
    log_success "Stale failed states cleared."

    log_success "Installation complete."
    log_info "Next steps:"
    log_info "  Verify:    systemctl list-timers --all | grep vaultwarden"
    log_info "  Validate:  sudo utilities/setup-systemd.sh validate"
    log_info "  Test run:  sudo systemctl start vaultwarden-health.service"
    log_info "  View logs: journalctl -u vaultwarden-health.service -n 50"
    log_info "  Env file:  $ENV_FILE  (add EMAIL_PROVIDER credentials here)"
    log_info "  Age key:   $AGE_KEY_DEST  (canonical operational key)"
}

remove_units() {
    _setup_systemd_acquire_guard "Systemd remove" "remove" || exit $?
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

    if systemctl is-enabled "$STARTUP_SERVICE" &>/dev/null || systemctl is-active "$STARTUP_SERVICE" &>/dev/null; then
        if _run systemctl disable --now "$STARTUP_SERVICE"; then
            log_success "Disabled: $STARTUP_SERVICE"
        else
            log_warn "Failed to disable $STARTUP_SERVICE -- it may already be inactive or masked."
            log_warn "  Check: systemctl status $STARTUP_SERVICE"
        fi
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check and disable $STARTUP_SERVICE if enabled or active"
    fi

    for unit in "${MANAGED_UNITS[@]}" "$STARTUP_SERVICE"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ -f "$dest" ]]; then
            _run rm -f "$dest"
            log_success "Removed: $dest"
        fi
    done

    _remove_docker_runtime_dropin

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

    # Clean up service identity drop-ins written by historical setup versions.
    # Remove only the managed 20-identity.conf file and leave OS accounts and
    # group memberships untouched.
    for unit in "${_ROOT_REQUIRED_UNITS[@]}"; do
        local dropin_dir="$UNIT_DEST_DIR/${unit}.d"
        local dropin_file="$dropin_dir/20-identity.conf"
        if [[ -f "$dropin_file" ]]; then
            _run rm -f "$dropin_file"
            log_success "Removed identity drop-in: $dropin_file"
        fi
        if [[ -d "$dropin_dir" ]] && [[ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
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

validate_installation() {
    log_header "VaultWarden-OCI Installation Validation"
    local errors=0
    local warnings=0

    _validate_root_owned_path() {
        local path="$1" expected_mode="$2" type_label="$3"
        local owner group mode
        owner=$(stat -c '%U' "$path" 2>/dev/null || echo "unknown")
        group=$(stat -c '%G' "$path" 2>/dev/null || echo "unknown")
        mode=$(stat -c '%a' "$path" 2>/dev/null || echo "unknown")
        if [[ "$owner" != "root" || "$group" != "root" || "$mode" != "$expected_mode" ]]; then
            log_error "  PERMISSIONS: $type_label $path is ${owner}:${group} mode $mode (expected root:root $expected_mode)"
            log_error "  Fix: sudo chown root:root $path && sudo chmod $expected_mode $path"
            (( errors++ )) || true
        else
            log_success "  OK: $path (root:root $expected_mode)"
        fi
    }

    _report_stale_artifact() {
        local installed="$1" repo_src="$2" expected_sum="$3" actual_sum="$4"
        log_error "  STALE: $installed does not match repo source"
        log_error "         repo source: $repo_src"
        log_error "         repo      sha256: $expected_sum"
        log_error "         installed sha256: $actual_sum"
        log_error "         Re-run: sudo utilities/setup-systemd.sh install"
        (( errors++ )) || true
    }

    _compare_repo_artifact() {
        local repo_src="$1" installed="$2"
        if [[ ! -f "$repo_src" ]]; then
            log_error "  MISSING REPO SOURCE: $repo_src"
            (( errors++ )) || true
            return 0
        fi
        if [[ ! -f "$installed" ]]; then
            log_error "  MISSING: $installed"
            log_error "         Re-run: sudo utilities/setup-systemd.sh install"
            (( errors++ )) || true
            return 0
        fi

        local expected_sum actual_sum
        expected_sum=$(_sha256 "$repo_src")
        actual_sum=$(_sha256 "$installed")
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            _report_stale_artifact "$installed" "$repo_src" "$expected_sum" "$actual_sum"
        else
            log_success "  UP-TO-DATE: $installed"
        fi
    }

    log_info "[1/9] Checking installed scripts and startup runtime assets ..."
    for script in "${INSTALLED_SCRIPT_PATHS[@]}"; do
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
    for asset in "${STARTUP_RUNTIME_FILE_PATHS[@]}"; do
        local installed="$OPT_SCRIPTS_DIR/$asset"
        if [[ ! -f "$installed" ]]; then
            log_error "  MISSING:        $installed"
            (( errors++ )) || true
        else
            log_success "  OK:             $installed"
        fi
    done
    for asset in "${STARTUP_RUNTIME_EXECUTABLE_PATHS[@]}"; do
        local installed="$OPT_SCRIPTS_DIR/$asset"
        if [[ ! -x "$installed" ]]; then
            log_error "  MISSING/NOT EXECUTABLE: $installed"
            (( errors++ )) || true
        else
            log_success "  OK:             $installed"
        fi
    done

    # Check lib/ presence AND file permissions.
    # lib/*.sh files must be at least world-readable (644) so that a
    # non-root service user (User= in the unit) can source them. Warn on
    # 600 or 640 modes.
    log_info "[2/9] Checking installed lib/ and file permissions ..."
    if [[ ! -d "$OPT_SCRIPTS_DIR/lib" ]]; then
        log_error "  MISSING: $OPT_SCRIPTS_DIR/lib/"
        (( errors++ )) || true
    else
        log_success "  OK: $OPT_SCRIPTS_DIR/lib/"
        local bad_perm_files=()
        while IFS= read -r -d '' libfile; do
            local fmode
            fmode=$(stat -c '%a' "$libfile" 2>/dev/null || stat -f '%Lp' "$libfile" 2>/dev/null || echo "000")
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

    log_info "[3/9] Checking installed unit files ..."
    for unit in "${MANAGED_UNITS[@]}"; do
        local dest="$UNIT_DEST_DIR/$unit"
        if [[ ! -f "$dest" ]]; then
            log_error "  MISSING: $dest"
            (( errors++ )) || true
        else
            log_success "  OK: $dest"
        fi
    done

    local background_service expected_directive
    for background_service in "${BACKGROUND_PRIORITY_SERVICES[@]}"; do
        local background_path="$UNIT_DEST_DIR/$background_service"
        [[ -f "$background_path" ]] || continue
        for expected_directive in \
            'Nice=10' \
            'IOSchedulingClass=best-effort' \
            'IOSchedulingPriority=7'; do
            if grep -Fxq "$expected_directive" "$background_path"; then
                log_success "  OK: $background_service has $expected_directive"
            else
                log_error "  PRIORITY DRIFT: $background_service is missing $expected_directive"
                log_error "  Fix: sudo utilities/setup-systemd.sh install"
                (( errors++ )) || true
            fi
        done
    done

    local startup_dest="$UNIT_DEST_DIR/$STARTUP_SERVICE"
    if [[ ! -f "$startup_dest" ]]; then
        log_error "  MISSING: $startup_dest"
        (( errors++ )) || true
    elif grep -qE '@STARTUP_RUNTIME_DIR@|@PROJECT_STATE_DIR@' "$startup_dest"; then
        log_error "  UNRENDERED PLACEHOLDER: $startup_dest"
        (( errors++ )) || true
    else
        local expected
        expected=$(mktemp) || return 1
        _render_startup_expected "$expected"
        if cmp -s "$expected" "$startup_dest"; then
            log_success "  OK: $startup_dest"
        else
            log_error "  DRIFT: $startup_dest does not match freshly rendered template"
            (( errors++ )) || true
        fi
        rm -f "$expected"
    fi

    log_info "[4/9] Checking systemd drop-in files ..."
    if ! _validate_docker_runtime_dropin; then
        (( errors++ )) || true
    fi
    for unit in "${_ROOT_REQUIRED_UNITS[@]}"; do
        local dropin_dir="$UNIT_DEST_DIR/${unit}.d"
        [[ -d "$dropin_dir" ]] || continue
        local dropin
        while IFS= read -r -d '' dropin; do
            local user_values group_values value
            user_values=$(awk -F= '/^[[:space:]]*User[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$dropin")
            group_values=$(awk -F= '/^[[:space:]]*Group[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$dropin")
            while IFS= read -r value; do
                [[ -n "$value" ]] || continue
                if [[ "$value" != "root" ]]; then
                    log_error "  CONFLICT: $unit has User=$value in $dropin but this unit currently requires root."
                    log_error "  Fix: sudo utilities/setup-systemd.sh install"
                    (( errors++ )) || true
                else
                    log_warn "  REDUNDANT: $dropin sets User=root; preferred state is no identity drop-in."
                    (( warnings++ )) || true
                fi
            done <<< "$user_values"
            while IFS= read -r value; do
                [[ -n "$value" ]] || continue
                if [[ "$value" != "root" ]]; then
                    log_error "  CONFLICT: $unit has Group=$value in $dropin but this unit currently requires root."
                    log_error "  Fix: sudo utilities/setup-systemd.sh install"
                    (( errors++ )) || true
                else
                    log_warn "  REDUNDANT: $dropin sets Group=root; preferred state is no identity drop-in."
                    (( warnings++ )) || true
                fi
            done <<< "$group_values"
        done < <(find "$dropin_dir" -mindepth 1 -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
    done

    local notify_helper="$OPT_SCRIPTS_DIR/utilities/notify-failure.sh"
    if [[ ! -x "$notify_helper" ]]; then
        log_error "  MISSING/NOT EXECUTABLE: $notify_helper"
        (( errors++ )) || true
    else
        log_success "  OK: $notify_helper is installed and executable"
    fi
    local notify_unit="$UNIT_DEST_DIR/$NOTIFY_FAILURE_TEMPLATE"
    if [[ -f "$notify_unit" ]]; then
        if grep -q '^ExecStart=/opt/vaultwarden-scripts/utilities/notify-failure.sh %i' "$notify_unit" \
           && ! grep -q 'ExecStart=/bin/bash -c' "$notify_unit"; then
            log_success "  OK: notifier template uses notify-failure.sh helper"
        else
            log_error "  NOTIFIER DRIFT: $notify_unit must ExecStart the notify-failure.sh helper, not inline bash"
            (( errors++ )) || true
        fi
    else
        log_error "  MISSING: $notify_unit"
        (( errors++ )) || true
    fi

    # Validate ReadWritePaths drop-ins only if a separate data volume is in use.
    # Mirrors the guard in _install_rwpaths_dropin so boot-only installs are not
    # incorrectly flagged as broken.
    local _val_data_device=""
    if [[ -f "$ENV_FILE" ]]; then
        _val_data_device=$(_read_env_value "DATA_VOLUME_DEVICE" "$ENV_FILE" 2>/dev/null || true)
    fi
    [[ -z "$_val_data_device" ]] && _val_data_device="${DATA_VOLUME_DEVICE:-}"

    if [[ -n "$_val_data_device" ]]; then
        for unit in "${_VW_DROPIN_UNITS[@]}"; do
            local dropin="$UNIT_DEST_DIR/${unit}.d/10-state-dir.conf"
            if [[ ! -f "$dropin" ]]; then
                log_warn "  MISSING: $dropin"
                log_warn "  Writes to the data volume will be blocked by ProtectSystem=strict."
                log_warn "  Fix: sudo utilities/setup-systemd.sh install"
                (( warnings++ )) || true
            else
                log_success "  OK: $dropin"
            fi
        done
    fi

    log_info "[5/9] Checking EnvironmentFile ..."
    if [[ ! -d "$ENV_DIR" ]]; then
        log_error "  MISSING: $ENV_DIR"
        (( errors++ )) || true
    else
        _validate_root_owned_path "$ENV_DIR" "700" "directory"
    fi
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "  MISSING: $ENV_FILE"
        log_error "  Run: sudo utilities/setup-systemd.sh install  (or create it manually)"
        (( errors++ )) || true
    else
        _validate_root_owned_path "$ENV_FILE" "600" "file"
    fi

    log_info "[6/9] Checking age key installation ..."
    if [[ ! -f "$AGE_KEY_DEST" ]]; then
        log_error "  MISSING: $AGE_KEY_DEST"
        log_error "  Backup/health services cannot encrypt/decrypt without this key."
        log_error "  Fix: restore the operational key at $AGE_KEY_DEST, then rerun install"
        (( errors++ )) || true
    else
        _validate_root_owned_path "$AGE_KEY_DEST" "600" "file"
    fi
    local rclone_dest="$ENV_DIR/rclone.conf"
    if [[ -f "$rclone_dest" ]]; then
        _validate_root_owned_path "$rclone_dest" "600" "file"
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

    log_info "[7/9] Checking timer enablement ..."
    for timer in "${TIMERS[@]}"; do
        if systemctl is-enabled "$timer" &>/dev/null; then
            log_success "  ENABLED:     $timer"
        else
            log_error   "  NOT ENABLED: $timer"
            (( errors++ )) || true
        fi
    done
    if systemctl is-enabled "$STARTUP_SERVICE" &>/dev/null; then
        log_success "  ENABLED:     $STARTUP_SERVICE"
    else
        log_error   "  NOT ENABLED: $STARTUP_SERVICE"
        (( errors++ )) || true
    fi

    log_info "[8/9] Checking for split-brain (sha256 repo vs installed) ..."
    for script in "${INSTALLED_SCRIPT_PATHS[@]}"; do
        local repo_src="$PROJECT_ROOT/$script"
        local installed="$OPT_SCRIPTS_DIR/$script"
        _compare_repo_artifact "$repo_src" "$installed"
    done

    while IFS= read -r -d '' repo_lib; do
        local rel_path installed_lib
        rel_path="${repo_lib#$PROJECT_ROOT/}"
        installed_lib="$OPT_SCRIPTS_DIR/$rel_path"
        _compare_repo_artifact "$repo_lib" "$installed_lib"
    done < <(find "$PROJECT_ROOT/lib" -type f -print0 2>/dev/null)

    for asset in "${STARTUP_RUNTIME_FILE_PATHS[@]}" "${STARTUP_RUNTIME_EXECUTABLE_PATHS[@]}"; do
        _compare_repo_artifact "$PROJECT_ROOT/$asset" "$OPT_SCRIPTS_DIR/$asset"
    done

    for unit in "${MANAGED_UNITS[@]}"; do
        _compare_repo_artifact "$UNIT_SOURCE_DIR/$unit" "$UNIT_DEST_DIR/$unit"
    done

    # Verify timers are healthy.
    # 'systemctl is-enabled' only checks the symlink; it does NOT confirm
    # the timer unit is currently active in systemd nor that it has a future
    # trigger time.
    log_info "[9/9] Checking timers are scheduled (systemctl list-timers) ..."
    if ! _report_unhealthy_managed_timers "Validation timer health"; then
        log_warn "  Try: sudo systemctl restart ${TIMERS[*]}"
        (( errors++ )) || true
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

show_status() {
    log_header "VaultWarden-OCI systemd Timer Status"
    echo ""
    systemctl list-timers --all 2>/dev/null | grep vaultwarden || log_info "No vaultwarden timers active."
    echo ""
    for svc in "${COPIED_SERVICES[@]}" "$STARTUP_SERVICE"; do
        [[ "$svc" == "$NOTIFY_FAILURE_TEMPLATE" ]] && continue
        log_info "--- $svc ---"
        { systemctl status "$svc" --no-pager -l 2>/dev/null | head -20; } || true
        echo ""
    done
}

main() {
    case "${1:-}" in
        help|--help|-h) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
    esac
    load_project_environment || exit 1
    require_root "${ORIGINAL_ARGS[@]}"

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
    show_help
    exit 1
}

main "$@"
