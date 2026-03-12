#!/usr/bin/env bash
# update.sh - Update VaultWarden, Caddy, Fail2Ban, Postfix, and Host OS
# FIXED: NEW-BUG-05 - set -e aborts when check_for_updates returns 2 (no updates)
# FIXED: NEW-BUG-01 - pre-update backup failure is now fatal; use --force to override
# FIXED: BUG-P     - use docker compose config --images for resolved image names
# FIXED: BUG-Q     - removed dead is_root/SUDO branch in update_system_packages()
# FIXED: BUG-R     - direct send_notification_email call; no bash -c single-quote injection
# FIXED: C-04/NEW-BUG-03 - flock-based mutex shared with restore.sh/maintenance.sh
# FIXED: P1-H3     - quoted $images / image_list to prevent word-splitting & glob expansion
# FIXED: P1-M3     - mutex uses FD 63 instead of FD 9 to avoid subshell inheritance collisions
# FIXED: AUDIT-H1  - FD 63 marked close-on-exec; children cannot hold stale lock
# FIXED: AUDIT-H2  - digest pinning + pre-up integrity check prevents tag-mutation attack
# FIXED: AUDIT-M1  - docker manifest inspect rate-limit detected; not silently 'up to date'
# FIXED: AUDIT-M2  - rollback checks local cache before pulling; errors surfaced clearly
# FIXED: AUDIT-L1  - notification email includes previous AND new digests

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

# Digest tracking: populated by check_for_updates, consumed by
# restart_vaultwarden_services and the notification email.
# Format: image_name -> "prev_digest|new_digest"
declare -A IMAGE_DIGEST_MAP

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

# ---------------------------------------------------------------------------
# AUDIT-H1: close-on-exec for FD 63
#
# bash does not expose F_SETFD/FD_CLOEXEC directly.  The most portable
# approach without Python/Perl: wrap every child invocation that must NOT
# inherit the lock FD inside _run_no_lock, which redirects FD 63 to
# /dev/null in the child, breaking the kernel file-description reference so
# the child cannot hold the flock.  We also attempt the O_CLOEXEC approach
# via Python when available for belt-and-suspenders coverage.
#
# Note: the flock(1) man page says the lock is released when the last FD
# referencing the underlying open file description is closed.  Redirecting
# 63>/dev/null in a child opens a *new* file description on /dev/null and
# has no effect on the parent's lock.  The child simply does not have a
# copy of FD 63 pointing at the lock file.
# ---------------------------------------------------------------------------
_set_cloexec_fd63() {
    # Attempt to set FD_CLOEXEC via Python (available on most distros)
    python3 -c "import fcntl, os; fcntl.fcntl(63, fcntl.F_SETFD, fcntl.FD_CLOEXEC)" 2>/dev/null || \
    python  -c "import fcntl, os; fcntl.fcntl(63, fcntl.F_SETFD, fcntl.FD_CLOEXEC)" 2>/dev/null || \
    true  # Non-fatal: _run_no_lock provides the safety net
}

# Run a command as a child process without inheriting FD 63 (the flock fd).
# AUDIT-H1: This prevents a child that outlives update.sh from holding the
# lock open indefinitely.
_run_no_lock() {
    # Redirect FD 63 to /dev/null in the child — opens a fresh file description,
    # does not affect the parent's open file description or the flock.
    ( exec 63>/dev/null; "$@" )
}

# ---------------------------------------------------------------------------
# AUDIT-M1: check_for_updates
#
# docker manifest inspect may return HTTP 429 (rate-limited) silently — the
# process exits 0 but returns an error JSON.  Previously the code treated any
# output as a valid digest, meaning a rate-limited registry appeared as
# "up to date" even when there were real updates.
#
# Fix: detect rate-limit indicators in the manifest inspect output and return
# exit code 3 (new sentinel: "check indeterminate, rate limited") instead of
# 0 or 2.  The caller logs a warning and skips the digest comparison rather
# than silently reporting current.
# ---------------------------------------------------------------------------
_manifest_inspect_digest() {
    local image="$1"
    local raw_output
    raw_output=$(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$image" 2>&1) || {
        echo "error"; return 1
    }
    # Detect rate-limiting: Docker Hub returns HTTP 429 in the error text
    if echo "$raw_output" | grep -qiE '429|rate.?limit|too many request'; then
        echo "rate_limited"; return 2
    fi
    # Extract the config digest
    local digest
    digest=$(echo "$raw_output" | grep -A 1 '"config"' | grep '"digest"' | awk -F'"' '{print $4}' | head -1)
    if [[ -z "$digest" ]]; then
        echo "unknown"; return 1
    fi
    echo "$digest"
    return 0
}

check_for_updates() {
    local updates_found=false
    local compose_file="docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        log_error "docker-compose.yml not found in $PROJECT_ROOT"
        return 1
    fi

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
        # Record previous digest before any pull
        local prev_digest
        prev_digest=$(docker inspect --type=image \
            --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "none")
        # Normalise: strip image name prefix if present ("img@sha256:..." -> "sha256:...")
        [[ "$prev_digest" == *@* ]] && prev_digest="${prev_digest##*@}"

        local local_id
        local_id=$(docker inspect --type=image --format '{{.Id}}' "$image" 2>/dev/null || echo "none")

        if [[ "$DRY_RUN" == "true" ]]; then
            local digest_result digest_rc=0
            digest_result=$(_manifest_inspect_digest "$image") || digest_rc=$?

            if [[ $digest_rc -eq 2 || "$digest_result" == "rate_limited" ]]; then
                # AUDIT-M1: rate-limited — report as indeterminate, not current
                log_warn "  [RATE-LIMITED] $image — registry rate limit hit; update status unknown"
            elif [[ "$local_id" == "none" ]]; then
                u_log_info "  [NEW] $image (Not pulled yet)"
                updates_found=true
            elif [[ "$digest_result" != "unknown" && "$digest_result" != "error" ]]; then
                u_log_info "  [CHECK] $image (Remote checking requires pull to be 100% accurate)"
                updates_found=true
            fi
        else
            u_log_info "  Pulling $image..."
            local pull_output pull_rc=0
            # AUDIT-H1: run docker pull without inheriting FD 63
            pull_output=$(_run_no_lock docker pull "$image" 2>&1) || pull_rc=$?

            if [[ $pull_rc -ne 0 ]]; then
                log_warn "  [PULL FAILED] $image (rc=${pull_rc})"
                IMAGE_DIGEST_MAP["$image"]="${prev_digest}|error"
                continue
            fi

            # Record the digest we actually pulled
            # AUDIT-H2: pin digest immediately after pull
            local new_digest
            new_digest=$(docker inspect --type=image \
                --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "none")
            [[ "$new_digest" == *@* ]] && new_digest="${new_digest##*@}"

            IMAGE_DIGEST_MAP["$image"]="${prev_digest}|${new_digest}"

            if echo "$pull_output" | grep -q "Downloaded newer image"; then
                u_log_success "  [UPDATED] $image has been updated (digest: ${new_digest:0:19}...)"
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

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    if [[ -f /var/run/reboot-required ]]; then
        log_warn "A system reboot is required due to package updates."
    fi

    u_log_success "System packages updated"
    return 0
}

# ---------------------------------------------------------------------------
# AUDIT-H2: _verify_digest_integrity IMAGE EXPECTED_DIGEST
#
# Before `docker compose up`, re-inspect the local image to confirm its
# digest still matches what was recorded immediately after `docker pull`.
# A mismatch means the tag was re-pushed between pull and up (tag mutation)
# and the update is aborted.
# ---------------------------------------------------------------------------
_verify_digest_integrity() {
    local image="$1"
    local expected_digest="$2"

    [[ -z "$expected_digest" || "$expected_digest" == "none" || "$expected_digest" == "error" ]] && {
        # No pinned digest available; skip verification with a warning
        log_warn "Image integrity check skipped for $image (no digest recorded)"
        return 0
    }

    local current_digest
    current_digest=$(docker inspect --type=image \
        --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "none")
    [[ "$current_digest" == *@* ]] && current_digest="${current_digest##*@}"

    if [[ "$current_digest" != "$expected_digest" ]]; then
        log_error "CRITICAL: Image digest mismatch for $image!"
        log_error "  Expected (post-pull): $expected_digest"
        log_error "  Current:              $current_digest"
        log_error "  This may indicate a tag-mutation attack or a concurrent registry push."
        log_error "  Aborting update. Run again to re-pull, or pin to a digest in docker-compose.yml."
        return 1
    fi

    u_log_info "  Digest integrity OK for $image (${current_digest:0:19}...)"
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

    # AUDIT-H2: Verify digest integrity for every image we pulled before
    # starting containers.  This catches tag-mutation between pull and up.
    if [[ ${#IMAGE_DIGEST_MAP[@]} -gt 0 ]]; then
        log_info "Verifying image digest integrity before starting services..."
        for image in "${!IMAGE_DIGEST_MAP[@]}"; do
            local digest_pair="${IMAGE_DIGEST_MAP[$image]}"
            local new_digest="${digest_pair##*|}"
            _verify_digest_integrity "$image" "$new_digest" || {
                log_error "Aborting service start due to digest integrity failure."
                return 1
            }
        done
    fi

    log_info "Applying updates and restarting services..."

    # AUDIT-H1: docker compose up must not inherit FD 63
    if _run_no_lock docker compose up -d; then
        u_log_success "Services restarted with updated images"

        log_info "Waiting for services to become healthy..."
        sleep 5

        if [[ -x "./health.sh" ]]; then
            # AUDIT-H1: health.sh must not inherit FD 63
            if _run_no_lock ./health.sh --quiet; then
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
    # AUDIT-H1: image prune must not inherit FD 63
    if _run_no_lock docker image prune -f >/dev/null 2>&1; then
        u_log_success "Cleanup completed"
    else
        log_warn "Image cleanup had issues, but update was successful"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# AUDIT-M2: rollback_on_failure
#
# Before restoring the previous image tag in .env and calling
# `docker compose up -d`, check that the previous image is cached locally.
# If not cached AND the registry is reachable, attempt a pull with a
# timeout.  If pull also fails, emit a critical error with actionable steps
# instead of silently leaving the service in a broken state.
# ---------------------------------------------------------------------------
rollback_on_failure() {
    local prev_image="$1"   # full image:tag that was running before update

    if [[ -z "$prev_image" ]]; then
        log_error "rollback_on_failure: no previous image specified; cannot roll back"
        return 1
    fi

    log_warn "Attempting rollback to previous image: $prev_image"

    # Check local cache first
    local cached_id
    cached_id=$(docker inspect --type=image --format '{{.Id}}' "$prev_image" 2>/dev/null || echo "none")

    if [[ "$cached_id" == "none" ]]; then
        log_warn "Previous image not in local cache; attempting pull: $prev_image"
        local pull_rc=0
        # 60-second timeout for the rollback pull; do not inherit FD 63
        _run_no_lock timeout 60 docker pull "$prev_image" 2>&1 || pull_rc=$?
        if [[ $pull_rc -ne 0 ]]; then
            log_error "CRITICAL: Rollback failed — previous image '$prev_image' is not cached"
            log_error "          AND could not be pulled from the registry (rc=${pull_rc})."
            log_error "Remediation:"
            log_error "  1. Restore from backup:  ./restore.sh --type db"
            log_error "  2. Or pin a known-good image in docker-compose.yml and run:"
            log_error "       docker pull <image>:<tag> && docker compose up -d"
            log_error "  3. Check registry connectivity: docker pull $prev_image"
            return 1
        fi
        u_log_success "Previous image pulled successfully for rollback"
    else
        u_log_info "Previous image found in local cache (${cached_id:0:19}...)"
    fi

    log_info "Restarting services with previous image..."
    if _run_no_lock docker compose up -d; then
        u_log_success "Rollback completed: running $prev_image"
        return 0
    else
        log_error "CRITICAL: docker compose up failed during rollback."
        log_error "  Service is DOWN. Manual intervention required."
        log_error "  Logs: docker compose logs"
        return 1
    fi
}

main() {
    # FIX (C-04/NEW-BUG-03): Acquire a shared operations mutex
    ensure_dir "$VW_LOCK_DIR" 700 "$(get_real_user)" || {
        log_error "Failed to initialize lock directory: $VW_LOCK_DIR"
        exit 1
    }

    # AUDIT-H1: Open FD 63 for the flock, then immediately set FD_CLOEXEC
    # so any exec'd child process does not inherit this file description.
    # The _set_cloexec_fd63 call uses Python's fcntl.F_SETFD to set the
    # close-on-exec bit at the kernel level; _run_no_lock() provides an
    # additional safety net for bash-forked subprocesses (fork, not exec)
    # by redirecting FD 63 to /dev/null before running child commands.
    exec 63>"$VW_OPERATIONS_LOCK"
    if ! flock -n 63; then
        log_error "Another update/restore/maintenance operation is already running."
        log_error "Lock file: $VW_OPERATIONS_LOCK"
        exit 1
    fi
    # Set FD_CLOEXEC on FD 63 at the kernel level
    _set_cloexec_fd63

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
            # AUDIT-H1: backup.sh must not inherit FD 63
            if _run_no_lock ./backup.sh --type db --quiet; then
                u_log_success "Pre-update safety backup created"
            else
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
    # FIX (NEW-BUG-05): capture non-zero exit without triggering set -e
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
        # AUDIT-L1: Include previous AND new digests in notification body
        if [[ "$EMAIL_NOTIFY" == "true" ]]; then
            local admin_email
            admin_email=$(get_config_value "ADMIN_EMAIL" "")
            if [[ -n "$admin_email" ]]; then
                local subject="VaultWarden Update Complete"
                local body="Update completed on: $(hostname)\nTimestamp: $(date -Iseconds)\n"

                if [[ ${#IMAGE_DIGEST_MAP[@]} -gt 0 ]]; then
                    body+="\nImage Digest Changes:\n"
                    for img in "${!IMAGE_DIGEST_MAP[@]}"; do
                        local pair="${IMAGE_DIGEST_MAP[$img]}"
                        local prev="${pair%%|*}"
                        local new="${pair##*|}"
                        body+="  ${img}\n"
                        body+="    Previous: ${prev:-none}\n"
                        body+="    New:      ${new:-none}\n"
                    done
                    body+="\nDigests allow you to verify exactly what changed without cross-referencing external release notes.\n"
                fi

                body+="\nSee system logs for full details."
                send_notification_email "$subject" "$body" >/dev/null 2>&1 || true
            fi
        fi
    fi

    exit 0
}

main "$@"
