#!/usr/bin/env bash
# lib/maintenance-utils.sh — Shared maintenance helpers for VaultWarden-OCI.
#
# Provides:
#   Maintenance : cleanup_logs, cleanup_backups, cleanup_docker_system,
#                 optimize_database, validate_system_health,
#                 generate_maintenance_summary
#   Helpers     : _wait_wal_quiesce, verbose_log
#
# Depends on / Load order:
#   lib/log.sh, lib/config.sh, lib/common.sh, lib/docker.sh,
#   lib/backup-utils.sh, and lib/storage.sh must be sourced before this file.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/config.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/docker.sh"
#   source "${LIB_DIR}/backup-utils.sh"
#   source "${LIB_DIR}/storage.sh"
#   source "${LIB_DIR}/maintenance-utils.sh"

[[ "${_MAINTENANCE_UTILS_LOADED:-}" == "true" ]] && return 0
_MAINTENANCE_UTILS_LOADED=true

# Self-load log.sh if not already loaded — allows this lib to be sourced
# directly without going through common.sh or a caller that pre-loads log.sh.
_VW_MAINT_UTILS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_MAINT_UTILS_LIB_DIR}/log.sh"
unset _VW_MAINT_UTILS_LIB_DIR


_default_backup_dir()      { vw_default_backup_dir; }
_default_alert_state_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/.vw-health-alert' "$state_dir"
}
_default_report_dir() {
    local state_dir
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    printf '%s/reports' "$state_dir"
}

# Poll until SQLite's WAL busy_count reaches 0, indicating no writer holds
# a WAL frame lock and it is safe to run wal_checkpoint(TRUNCATE)/VACUUM.
# Falls back to a plain sleep if sqlite3 is unavailable.
_wait_wal_quiesce() {
    local db_file="$1"
    local max_seconds="${2:-30}"
    local waited=0
    local interval=1
    log_debug "Waiting for WAL to quiesce on $db_file (max ${max_seconds}s)..."
    while (( waited < max_seconds )); do
        local busy_count
        busy_count=$(sqlite3 "$db_file" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null | awk -F'|' 'NR==1{print $2}' || echo "0")
        if [[ "$busy_count" == "0" ]]; then
            log_debug "WAL quiesced after ${waited}s (busy_count=0)"
            return 0
        fi
        log_debug "WAL busy (busy_count=${busy_count}), waited ${waited}s…"
        sleep "$interval"
        (( waited += interval ))
    done
    log_warn "WAL did not fully quiesce within ${max_seconds}s (busy_count=${busy_count:-?}) — proceeding anyway"
    return 0
}


cleanup_logs() {
    if [[ "${CLEAN_LOGS:-true}" != "true" ]]; then log_info "Skipping log cleanup"; return 0; fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would clean up logs older than ${LOG_RETENTION_DAYS:-30} days"
        return 0
    fi
    log_info "Cleaning up logs older than ${LOG_RETENTION_DAYS:-30} days..."
    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local logs_cleaned=0
    local log_dirs=(
        "$state_dir/logs/vaultwarden"
        "$state_dir/logs/caddy"
        "${PROJECT_ROOT}/logs"
    )
    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            local -a old_log_files=()
            mapfile -d '' old_log_files < <(
                find "$log_dir" -name "*.log*" -type f -mtime +"${LOG_RETENTION_DAYS:-30}" -print0 2>/dev/null
            )
            for log_file in "${old_log_files[@]}"; do
                rm -f "$log_file" && ((logs_cleaned++)) && log_debug "Removed old log: $(basename "$log_file")"
            done
        fi
    done
    local existing_log_dirs=()
    for log_dir in "${log_dirs[@]}"; do
        [[ -d "$log_dir" ]] && existing_log_dirs+=("$log_dir")
    done
    if [[ ${#existing_log_dirs[@]} -gt 0 ]]; then
        local -a large_log_files=()
        mapfile -d '' large_log_files < <(
            find "${existing_log_dirs[@]}" -name "*.log" -type f -size +100M -print0 2>/dev/null
        )
        for log_file in "${large_log_files[@]}"; do
            if [[ "$log_file" == */logs/caddy/access.log ]]; then
                log_debug "Skipping rotation for Caddy log (handled internally): $log_file"
                continue
            fi
            local rotated_name
            rotated_name="${log_file}.$(date +%Y%m%d)"
            if mv "$log_file" "$rotated_name"; then
                if gzip "$rotated_name"; then
                    log_debug "Rotated large log: $(basename "$log_file")"
                    ((logs_cleaned++)) || true
                else
                    log_warn "gzip failed for $(basename "$rotated_name") — restoring original log file"
                    mv "$rotated_name" "$log_file" || \
                        log_error "CRITICAL: cannot restore log after gzip failure: $rotated_name"
                fi
            fi
        done
    fi
    if (( logs_cleaned > 0 )); then
        log_success "Cleaned up $logs_cleaned log files"
    else
        log_info "No old logs found to clean up"
    fi
    return 0
}


cleanup_backups() {
    if [[ "${CLEAN_BACKUPS:-true}" != "true" ]]; then log_info "Skipping backup cleanup"; return 0; fi
    log_info "Managing backup retention..."
    local backup_base_dir; backup_base_dir="$(get_config_value "BACKUP_DIR" "$(_default_backup_dir)")"
    local had_real_error=false
    local backup_types=(
        "db:${DB_BACKUP_RETENTION_DAYS:-14}"
        "full:${FULL_BACKUP_RETENTION_DAYS:-30}"
        "emergency:${EMERGENCY_BACKUP_RETENTION_DAYS:-90}"
    )
    for backup_type_info in "${backup_types[@]}"; do
        local backup_type="${backup_type_info%%:*}"
        local retention_days="${backup_type_info##*:}"
        local backup_dir="$backup_base_dir/$backup_type"
        if [[ ! -d "$backup_dir" ]]; then
            log_info "No $backup_type backup directory yet (skipping cleanup)"
            continue
        fi
        if cleanup_old_backups "$backup_dir" "$backup_type" "$retention_days"; then
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                log_success "$backup_type backup retention preview completed (${retention_days}d retention)"
            else
                log_success "$backup_type backups cleaned (${retention_days}d retention)"
            fi
        else
            log_error "$backup_type backup cleanup failed"
            had_real_error=true
        fi
    done
    log_success "Backup retention management completed"
    [[ "$had_real_error" == "true" ]] && return 1 || return 0
}


cleanup_docker_system() {
    if [[ "${CLEAN_DOCKER:-true}" != "true" ]]; then log_info "Skipping Docker cleanup"; return 0; fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log_info "[DRY RUN] Would clean up Docker system resources"; return 0; fi
    log_info "Cleaning up Docker system resources..."
    if ! require_docker; then log_error "Docker not available for cleanup"; return 2; fi
    local cleanup_success=true
    cleanup_containers || { log_warn "Container cleanup had issues"; cleanup_success=false; }
    cleanup_images     || { log_warn "Image cleanup had issues";     cleanup_success=false; }
    log_info "Cleaning up Docker images and build cache..."
    docker image prune -f >/dev/null 2>&1 || { log_warn "Image prune had issues"; cleanup_success=false; }
    docker builder prune -f --filter until=24h >/dev/null 2>&1 || { log_warn "Builder cache prune had issues"; cleanup_success=false; }
    cleanup_networks   || { log_warn "Network cleanup had issues";   cleanup_success=false; }
    local space_reclaimed
    space_reclaimed=$(docker system df --format "table {{.Reclaimed}}" 2>/dev/null | tail -1 || echo "unknown")
    if [[ "$cleanup_success" == "true" ]]; then
        log_success "Docker cleanup completed successfully (reclaimed: ${space_reclaimed})"; return 0
    else
        log_warn "Docker cleanup completed with some issues (reclaimed: ${space_reclaimed})"; return 1
    fi
}


optimize_database() {
    if [[ "${OPTIMIZE_DATABASE:-true}" != "true" ]]; then log_info "Skipping database optimization"; return 0; fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log_info "[DRY RUN] Would safely optimize VaultWarden database"; return 0; fi
    log_info "Starting SAFE database optimization (will stop VaultWarden temporarily)..."
    local state_dir; state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local host_db_path="$state_dir/data/db.sqlite3"
    if [[ ! -f "$host_db_path" ]]; then log_error "Database file not found: $host_db_path"; return 1; fi
    local was_running=false
    if is_service_running "vaultwarden"; then
        was_running=true
    else
        log_warn "VaultWarden not running, will optimize offline database"
    fi
    _db_opt_cleanup() {
        if [[ "$was_running" == "true" ]]; then
            if ! is_service_running "vaultwarden" 2>/dev/null; then
                log_warn "optimize_database: safety net restarting VaultWarden..."
                docker compose up -d vaultwarden 2>&1 || log_error "Safety net restart failed — manual intervention required"
            fi
        fi
    }
    trap '_db_opt_cleanup' RETURN
    local size_bytes_before
    size_bytes_before=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_before=$(( size_bytes_before / 1024 ))
    log_info "Database size before optimization: ${size_kb_before} KB"
    if [[ "$was_running" == "true" ]]; then
        log_info "Stopping VaultWarden service..."
        docker compose stop vaultwarden || { log_error "Failed to stop VaultWarden"; return 1; }
        log_success "VaultWarden stopped"
        _wait_wal_quiesce "$host_db_path" 30
    fi
    log_info "Creating encrypted pre-optimization backup via backup-run.sh..."
    # Call utilities/backup-run.sh directly (not the backup.sh dispatcher) so
    # this lib function does not depend on the caller's working directory and
    # cannot create a circular dispatcher loop.
    if ! "${PROJECT_ROOT}/utilities/backup-run.sh" run db; then
        log_error "Pre-optimization backup FAILED — aborting to avoid an unsafe rollback point"
        [[ "$was_running" == "true" ]] && docker compose up -d vaultwarden
        return 1
    fi
    log_success "Encrypted pre-optimization backup created in backup directory"
    log_info "Verifying integrity before optimization..."
    if ! sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "Integrity check failed - aborting"
        [[ "$was_running" == "true" ]] && docker compose up -d vaultwarden
        return 1
    fi
    log_success "Integrity check passed"
    local optimization_success=true
    for cmd in "PRAGMA wal_checkpoint(TRUNCATE);" "PRAGMA optimize;" "ANALYZE;" "VACUUM;"; do
        log_debug "Running: $cmd"
        sqlite3 "$host_db_path" "$cmd" >/dev/null 2>&1 || { log_warn "Command failed: $cmd"; optimization_success=false; }
    done
    log_info "Verifying integrity after optimization..."
    if ! sqlite3 "$host_db_path" "PRAGMA integrity_check;" | grep -qx "ok"; then
        log_error "CRITICAL: Post-optimization integrity check failed! Manual restore from backup directory required."
        optimization_success=false
    else
        log_success "Post-optimization integrity check passed"
    fi
    if [[ "$was_running" == "true" ]]; then
        if docker compose up -d vaultwarden; then
            log_success "VaultWarden restarted"
        else
            log_error "Failed to restart VaultWarden"
            optimization_success=false
        fi
        sleep 5
        if is_service_running "vaultwarden"; then
            log_success "VaultWarden healthy"
        else
            log_error "VaultWarden not healthy after optimization"
            optimization_success=false
        fi
    fi
    local size_bytes_after
    size_bytes_after=$(stat -c%s "$host_db_path" 2>/dev/null || echo "0")
    local size_kb_after=$(( size_bytes_after / 1024 ))
    if [[ "$optimization_success" == "true" ]]; then
        log_success "Database optimization completed. ${size_kb_before} KB → ${size_kb_after} KB"
    else
        log_warn "Optimization completed with issues. Safety backup retained in backup directory."
    fi
    [[ "$optimization_success" == "true" ]]
}


validate_system_health() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log_info "[DRY RUN] Would validate system health"; return 0; fi
    log_info "Validating system health after maintenance..."
    log_info "Invoking: VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ${PROJECT_ROOT}/utilities/maintenance-health.sh --quiet"
    if VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" --quiet; then
        log_success "System health validation passed"
        return 0
    else
        log_warn "System health validation detected issues"
        return 1
    fi
}


_format_duration() {
    local total_seconds="${1:-0}"
    [[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0
    local minutes=$(( total_seconds / 60 ))
    local seconds=$(( total_seconds % 60 ))
    if (( minutes > 0 )); then
        printf '%dm %ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}


# generate_maintenance_summary LOG_RC BACKUP_RC DOCKER_RC DB_RC FW_RC DNS_RC HEALTH_RC [DURATION_SECONDS]
#
# Renders the post-run maintenance summary to stdout and optionally sends an
# email notification.  The optional 8th argument (DURATION_SECONDS) appends a
# human-readable "Duration: Xm Ys" line to the footer so every automated or
# manual run is self-documenting.
generate_maintenance_summary() {
    local log_cleanup="$1"   backup_cleanup="$2" docker_cleanup="$3"
    local db_optimization="$4" firewall_update="$5" dns_update="$6" health_validation="$7"
    local duration_seconds="${8:-}"

    local summary
    summary="VaultWarden Maintenance Summary - $(date)\n\nMaintenance Results:\n"

    if [[ "${CLEAN_LOGS:-true}" == "true" ]]; then
        [[ "$log_cleanup" == "0" ]] && summary+="  ✅ Log cleanup: OK\n" || summary+="  ❌ Log cleanup: Failed\n"
    else
        summary+="  ⏭️  Log cleanup: Skipped\n"
    fi
    if [[ "${CLEAN_BACKUPS:-true}" == "true" ]]; then
        [[ "$backup_cleanup" == "0" ]] && summary+="  ✅ Backup cleanup: OK\n" || summary+="  ❌ Backup cleanup: Failed\n"
    else
        summary+="  ⏭️  Backup cleanup: Skipped\n"
    fi
    if [[ "${CLEAN_DOCKER:-true}" == "true" ]]; then
        if [[ "$docker_cleanup" == "0" ]]; then
            summary+="  ✅ Docker cleanup: OK\n"
        elif [[ "$docker_cleanup" == "1" ]]; then
            summary+="  ⚠️  Docker cleanup: Issues\n"
        else
            summary+="  ❌ Docker cleanup: Failed\n"
        fi
    else
        summary+="  ⏭️  Docker cleanup: Skipped\n"
    fi
    if [[ "${OPTIMIZE_DATABASE:-true}" == "true" ]]; then
        [[ "$db_optimization" == "0" ]] && summary+="  ✅ DB optimization: OK\n" || summary+="  ⚠️  DB optimization: Issues\n"
    else
        summary+="  ⏭️  DB optimization: Skipped\n"
    fi
    if [[ "${UPDATE_FIREWALL:-false}" == "true" ]]; then
        if [[ "$firewall_update" == "0" ]]; then
            summary+="  ✅ Firewall update: OK\n"
        elif [[ "$firewall_update" == "75" ]]; then
            summary+="  ⏭️  Firewall update: Skipped (active operation)\n"
        else
            summary+="  ❌ Firewall update: Failed\n"
        fi
    else
        summary+="  ⏭️  Firewall update: Skipped\n"
    fi
    if [[ "${UPDATE_DNS:-false}" == "true" ]]; then
        if [[ "$dns_update" == "0" ]]; then
            summary+="  ✅ DNS update: OK\n"
        elif [[ "$dns_update" == "75" ]]; then
            summary+="  ⏭️  DNS update: Skipped (active operation)\n"
        else
            summary+="  ❌ DNS update: Failed\n"
        fi
    else
        summary+="  ⏭️  DNS update: Skipped\n"
    fi
    if [[ "${TARGETED_MODE:-false}" == "false" ]]; then
        [[ "$health_validation" == "0" ]] && summary+="  ✅ Health validation: Passed\n" || summary+="  ⚠️  Health validation: Issues\n"
    fi

    local critical_failures=0
    [[ "${CLEAN_LOGS:-true}"        == "true"  && "$log_cleanup"      != "0" ]] && ((++critical_failures))
    [[ "${CLEAN_BACKUPS:-true}"     == "true"  && "$backup_cleanup"   != "0" ]] && ((++critical_failures))
    [[ "${CLEAN_DOCKER:-true}"      == "true"  && "$docker_cleanup"   == "2" ]] && ((++critical_failures))
    [[ "${OPTIMIZE_DATABASE:-true}" == "true"  && "$db_optimization"  != "0" ]] && ((++critical_failures))
    [[ "${UPDATE_FIREWALL:-false}"  == "true"  && "$firewall_update"  != "0" && "$firewall_update" != "75" ]] && ((++critical_failures))
    [[ "${UPDATE_DNS:-false}"       == "true"  && "$dns_update"       != "0" && "$dns_update"      != "75" ]] && ((++critical_failures))
    [[ "${TARGETED_MODE:-false}"    == "false" && "$health_validation" != "0" ]] && ((++critical_failures))

    local operation_skips=0
    [[ "${UPDATE_FIREWALL:-false}" == "true" && "$firewall_update" == "75" ]] && ((++operation_skips))
    [[ "${UPDATE_DNS:-false}"      == "true" && "$dns_update"      == "75" ]] && ((++operation_skips))

    if [[ -n "$duration_seconds" && "$duration_seconds" =~ ^[0-9]+$ ]]; then
        summary+="\nDuration: $(_format_duration "$duration_seconds")\n"
    fi

    if [[ $critical_failures -eq 0 && $operation_skips -eq 0 ]]; then
        summary+="🎉 Overall Status: SUCCESS\n"
    elif [[ $critical_failures -eq 0 ]]; then
        summary+="⏭️  Overall Status: COMPLETED WITH SKIPS\n"
    else
        summary+="⚠️  Overall Status: COMPLETED WITH ISSUES\n"
    fi

    printf '%b' "$summary"

    if [[ "${EMAIL_NOTIFY:-false}" == "true" ]]; then
        local subj
        if [[ $critical_failures -eq 0 && $operation_skips -eq 0 ]]; then
            subj="VaultWarden Maintenance: SUCCESS"
        elif [[ $critical_failures -eq 0 ]]; then
            subj="VaultWarden Maintenance: COMPLETED WITH SKIPS"
        else
            subj="VaultWarden Maintenance: ISSUES DETECTED"
        fi
        local email_body; email_body=$(printf '%b' "$summary")
        if send_notification_email "$subj" "$email_body"; then
            log_info "Summary emailed"
        else
            log_warn "Failed to send summary email"
        fi
    fi
    return 0
}


verbose_log() {
    [[ "${VERBOSE:-false}" == "true" ]] && log_info "$1"
}
