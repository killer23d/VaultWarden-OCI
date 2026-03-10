#!/usr/bin/env bash
# update.sh - Update VaultWarden, Caddy, Fail2Ban, Postfix, and Host OS
# FIXED: NEW-BUG-05 - set -e aborts when check_for_updates returns 2 (no updates)
# FIXED: NEW-BUG-01 - pre-update backup failure is now fatal; use --force to override
# FIXED: BUG-P     - use docker compose config --images for resolved image names
# FIXED: BUG-Q     - removed dead is_root/SUDO branch in update_system_packages()
# FIXED: BUG-R     - direct send_notification_email call; no bash -c single-quote injection
# FIXED: C-04/NEW-BUG-03 - flock-based mutex shared with restore.sh/maintenance.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# Configuration
UPDATE_SYSTEM=false
UPDATE_IMAGES=true
NO_RESTART=false
NO_CLEANUP=false
EMAIL_NOTIFY=false
DRY_RUN=false
RESTART_SERVICES=true
CLEANUP_OLD=true
QUIET=false
FORCE_UPDATE=false   # bypass fatal backup-failure guard (--force)

# Shared operations lock — must match the name used in restore.sh and maintenance.sh
VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Update Script

USAGE:
    ./update.sh [OPTIONS]

OPTIONS:
    --system            Update system packages (apt) in addition to containers
    --no-images     Skip pulling new Docker images
    --no-restart    Do not restart services after update
    --no-cleanup    Do not remove old Docker images after update
    --dry-run           Show what would be done without executing
    --email             Send email notification on completion
    --force             Proceed even if pre-update backup fails
    --quiet             Reduce output
    --help              Show this help

EXAMPLES:
    ./update.sh                   # Update containers and restart
    ./update.sh --system          # Update host OS and containers
    ./update.sh --dry-run         # See what images have updates available
    ./update.sh --force           # Update even if pre-update backup fails
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --system)       UPDATE_SYSTEM=true; shift ;;
        --no-images)    UPDATE_IMAGES=false; shift ;;
        --no-restart)   RESTART_SERVICES=false; shift ;;
        --no-cleanup)   CLEANUP_OLD=false; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --email)        EMAIL_NOTIFY=true; shift ;;
        --force)        FORCE_UPDATE=true; shift ;;
        --quiet)        QUIET=true; shift ;;
        --help)         show_help; exit 0 ;;
        *)              log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

u_log_info() { [[ "$QUIET" == "true" ]] || log_info "$1"; }
u_log_success() { [[ "$QUIET" == "true" ]] || log_success "$1"; }

check_for_updates() {
    local updates_found=false
    local compose_file="docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        log_error "docker-compose.yml not found in $PROJECT_ROOT"
        return 1
    fi

    # FIX (BUG-P): Use `docker compose config --images` to get fully-resolved
    # image names. Grepping raw YAML returned unexpanded variable references
    # such as "vaultwarden/server:${VAULTWARDEN_VERSION:-latest}" which
    # docker pull treats as a literal tag name and fails to fetch.
    # Fall back to parsing `docker compose config` output for Compose versions
    # older than v2.5 that do not support the --images subcommand.
    local images
    if images=$(docker compose config --images 2>/dev/null) && [[ -n "$images" ]]; then
        : # resolved list obtained
    else
        images=$(docker compose config 2>/dev/null \
            | grep -E '^[[:space:]]+image:' \
            | awk '{print $2}' \
            | tr -d '"'"'")
    fi

    if [[ -z "$images" ]]; then
        log_error "Could not extract image list from docker compose configuration"
        return 1
    fi

    u_log_info "Checking for image updates..."

    local image_list
    mapfile -t image_list <<< "$images"
    for image in "${image_list[@]}"; do
        # Get local image ID
        local local_id
        local_id=$(docker inspect --type=image --format '{{.Id}}' "$image" 2>/dev/null || echo "none")

        if [[ "$DRY_RUN" == "true" ]]; then
            local remote_digest
            # DOCKER_CLI_EXPERIMENTAL is a no-op on Docker >= 20.10 but required for
            # older clients; scope it to this single call to avoid process-level bleed.
            remote_digest=$(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$image" 2>/dev/null \
                | grep -A 1 "config" | grep "digest" | awk -F'"' '{print $4}' \
                || echo "unknown")

            if [[ "$local_id" == "none" ]]; then
                u_log_info "  [NEW] $image (Not pulled yet)"
                updates_found=true
            elif [[ "$remote_digest" != "unknown" ]]; then
                u_log_info "  [CHECK] $image (Remote checking requires pull to be 100% accurate)"
                updates_found=true
            fi
        else
            u_log_info "  Pulling $image..."
            local pull_output
            pull_output=$(docker pull "$image" 2>&1)

            if echo "$pull_output" | grep -q "Downloaded newer image"; then
                u_log_success "  [UPDATED] $image has been updated"
                updates_found=true
            elif echo "$pull_output" | grep -q "Image is up to date"; then
                u_log_info "  [CURRENT] $image is up to date"
            else
                log_warn "  [UNKNOWN] Could not determine status for $image"
            fi
        fi
    done

    if [[ "$updates_found" == "true" ]]; then
        return 0
    else
        return 2  # sentinel: all images current; not an error
    fi
}

update_system_packages() {
    if [[ "$UPDATE_SYSTEM" != "true" ]]; then
        log_info "Skipping system package updates (use --system to enable)"
        return 0
    fi

    require_root "$@"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt-get update && apt-get upgrade -y"
        return 0
    fi

    log_info "Updating system packages..."

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found. Skipping system update."
        return 0
    fi

    # FIX (BUG-Q): Removed dead is_root / SUDO variable. require_root() above
    # exits the script if the caller is not root, so this function is only
    # reachable as root. The previous `if ! is_root; then SUDO="sudo"` branch
    # was always false and SUDO was always the empty string.
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
    fi

    u_log_success "System packages updated"
    return 0
}

restart_vaultwarden_services() {
    if [[ "$RESTART_SERVICES" != "true" ]]; then
        log_info "Skipping service restart (--no-restart specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restart services via docker compose up -d"
        return 0
    fi

    log_info "Applying updates and restarting services..."

    # Recreate containers with new images
    if docker compose up -d; then
        u_log_success "Services restarted with updated images"

        # Verify health
        log_info "Waiting for services to become healthy..."
        sleep 5

        if [[ -x "./health.sh" ]]; then
            if ./health.sh --quiet; then
                u_log_success "All services are healthy after update"
            else
                log_warn "Some services may not be healthy after update. Check logs."
            fi
        fi
        return 0
    else
        log_error "Failed to restart services"
        return 1
    fi
}

perform_cleanup() {
    if [[ "$CLEANUP_OLD" != "true" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove dangling Docker images"
        return 0
    fi

    log_info "Cleaning up old Docker images..."
    if docker image prune -f >/dev/null 2>&1; then
        u_log_success "Cleanup completed"
    else
        log_warn "Image cleanup had issues, but update was successful"
    fi
    return 0
}

main() {
    # FIX (C-04/NEW-BUG-03): Acquire a shared operations mutex before doing any
    # work. update.sh, restore.sh, and maintenance.sh all use the same lock file
    # so they cannot run concurrently. This prevents races such as update.sh
    # replacing images while restore.sh is replaying volumes, or maintenance.sh
    # vacuuming the database while an update is mid-flight.
    ensure_dir "$VW_LOCK_DIR" 700 "$(get_real_user)" || {
        log_error "Failed to initialize lock directory: $VW_LOCK_DIR"
        exit 1
    }

    exec 9>"$VW_OPERATIONS_LOCK"
    if ! flock -n 9; then
        log_error "Another update/restore/maintenance operation is already running."
        log_error "Lock file: $VW_OPERATIONS_LOCK"
        exit 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_header "VaultWarden-OCI Update [DRY RUN]"
    else
        log_header "VaultWarden-OCI Update"
    fi

    if ! load_env_file; then
        log_error "Failed to load environment configuration"
        exit 1
    fi

    if ! require_docker; then
        log_error "Docker is not available"
        exit 1
    fi

    # Phase 1: Create safety backup
    if [[ "$DRY_RUN" == "false" && "$UPDATE_IMAGES" == "true" ]]; then
        log_info "Creating pre-update safety backup..."
        if [[ -x "./backup.sh" ]]; then
            if ./backup.sh --type db --quiet; then
                u_log_success "Pre-update safety backup created"
            else
                # FIX (NEW-BUG-01): Backup failure is now fatal by default.
                # The previous behaviour logged a warning and continued, which
                # meant the live stack was mutated with no rollback point.
                # Use --force to explicitly accept this risk.
                if [[ "$FORCE_UPDATE" == "true" ]]; then
                    log_warn "Pre-update backup FAILED. Proceeding because --force was specified."
                else
                    log_error "CRITICAL: Pre-update safety backup failed. Aborting update."
                    log_error "Resolve the backup failure first, or re-run with --force to override."
                    exit 1
                fi
            fi
        else
            log_warn "backup.sh not found or not executable — skipping safety backup"
        fi
    fi

    # Phase 2: Host OS Updates
    update_system_packages

    # Phase 3: Docker Image Updates
    # FIX (NEW-BUG-05): With set -e active, `check_for_updates` returning 2
    # (all images current, not an error) triggered set -e and aborted the
    # script before `local update_status=$?` could capture the value.
    # The corrected pattern initialises update_status first and uses `||` to
    # capture any non-zero exit code without triggering set -e.
    local images_updated=false
    if [[ "$UPDATE_IMAGES" == "true" ]]; then
        local update_status=0
        check_for_updates || update_status=$?

        if [[ $update_status -eq 0 ]]; then
            images_updated=true
            log_info "Updates pulled successfully"
        elif [[ $update_status -eq 2 ]]; then
            log_info "All Docker images are up to date"
        else
            log_error "Failed to check for or pull image updates"
            exit 1
        fi
    fi

    # Phase 4: Apply Updates & Restart
    if [[ "$images_updated" == "true" || "$UPDATE_SYSTEM" == "true" ]]; then
        restart_vaultwarden_services
    else
        log_info "No updates required service restarts"
    fi

    # Phase 5: Cleanup
    if [[ "$images_updated" == "true" ]]; then
        perform_cleanup
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        u_log_success "Dry run completed successfully"
    else
        u_log_success "Update process completed successfully"

        # Email notification (opt-in via --email)
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email
            admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                local subject="VaultWarden Update Complete"
                local body="Update completed on: $(hostname)\n\nSee logs for details."
                send_notification_email "$subject" "$body" >/dev/null 2>&1 || true
            fi
        fi
    fi

    exit 0
}

main "$@"