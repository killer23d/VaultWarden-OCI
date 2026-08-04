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


# Routine optimization is intentionally online. Deep backup, integrity,
# checkpoint-truncate, ANALYZE, VACUUM, and container lifecycle work belongs to
# utilities/maintenance-db-maint.sh.
optimize_database() {
    if [[ "${OPTIMIZE_DATABASE:-true}" != "true" ]]; then
        log_info "Skipping database optimization"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would run PRAGMA optimize and PRAGMA wal_checkpoint(PASSIVE)"
        return 0
    fi

    local state_dir db_file page_count freelist_count page_size
    state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
    db_file="$state_dir/data/db.sqlite3"
    if [[ ! -f "$db_file" ]]; then
        log_error "Database file not found: $db_file"
        return 1
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_error "sqlite3 is required for routine database optimization"
        return 1
    fi

    log_info "Running online SQLite routine maintenance..."
    page_count=$(sqlite3 "$db_file" "PRAGMA page_count;" 2>/dev/null || true)
    freelist_count=$(sqlite3 "$db_file" "PRAGMA freelist_count;" 2>/dev/null || true)
    page_size=$(sqlite3 "$db_file" "PRAGMA page_size;" 2>/dev/null || true)
    if [[ -n "$page_count" && -n "$freelist_count" && -n "$page_size" ]]; then
        log_info "SQLite pages: total=${page_count}, free=${freelist_count}, page_size=${page_size} bytes"
    fi

    if ! sqlite3 "$db_file" "PRAGMA optimize;" >/dev/null 2>&1; then
        log_error "PRAGMA optimize failed"
        return 1
    fi
    if ! sqlite3 "$db_file" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1; then
        log_error "PRAGMA wal_checkpoint(PASSIVE) failed"
        return 1
    fi
    log_success "Online SQLite routine maintenance completed"
}


validate_system_health() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would run quick post-maintenance health validation"
        return 0
    fi

    local health_rc=0
    log_info "Validating system health after maintenance..."
    log_info "Invoking: VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ${PROJECT_ROOT}/utilities/maintenance-health.sh --quiet --quick"
    VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" --quiet \
        --quick || health_rc=$?

    case "$health_rc" in
        0)  log_success "System health validation passed" ;;
        1)  log_warn "System health validation passed with advisory warnings" ;;
        75) log_warn "System health validation skipped because another health execution was active" ;;
        2|3|4) log_error "System health validation failed with status ${health_rc}" ;;
        *)  log_error "System health validation returned unexpected status ${health_rc}" ;;
    esac
    return "$health_rc"
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


_health_summary_line() {
    case "$1" in
        0)  printf '  ✅ Health validation: Passed' ;;
        1)  printf '  ⚠️  Health validation: Passed with advisory warnings' ;;
        75) printf '  ⏭️  Health validation: Skipped (another health execution was active)' ;;
        2|3|4) printf '  ❌ Health validation: Failed (status %s)' "$1" ;;
        *)  printf '  ❌ Health validation: Failed (unexpected status %s)' "$1" ;;
    esac
}


# generate_maintenance_summary LOG_RC BACKUP_RC DOCKER_RC DB_RC FW_RC DNS_RC
#                              HEALTH_RC [DURATION_SECONDS] [RECOVERY_RC]
#
# Renders and optionally emails the summary. The owning runner reads
# MAINTENANCE_SUMMARY_RESULT and MAINTENANCE_SUMMARY_STATE, which are derived by
# the same classification that selects the rendered overall state and subject.
generate_maintenance_summary() {
    local log_cleanup="$1" backup_cleanup="$2" docker_cleanup="$3"
    local db_optimization="$4" firewall_update="$5" dns_update="$6" health_validation="$7"
    local duration_seconds="${8:-}" recovery_cleanup="${9:-}"
    local critical_failures=0 advisory_warnings=0 operation_skips=0
    local summary subject

    MAINTENANCE_SUMMARY_RESULT=0
    MAINTENANCE_SUMMARY_STATE=success

    summary="VaultWarden Maintenance Summary - $(date)\n\nMaintenance Results:\n"

    if [[ "${CLEAN_LOGS:-true}" == "true" ]]; then
        if [[ "$log_cleanup" == "0" ]]; then
            summary+="  ✅ Log cleanup: OK\n"
        else
            summary+="  ❌ Log cleanup: Failed\n"
            ((++critical_failures))
        fi
    else
        summary+="  ⏭️  Log cleanup: Skipped\n"
    fi

    if [[ "${CLEAN_BACKUPS:-true}" == "true" ]]; then
        if [[ "$backup_cleanup" == "0" ]]; then
            summary+="  ✅ Backup cleanup: OK\n"
        else
            summary+="  ❌ Backup cleanup: Failed\n"
            ((++critical_failures))
        fi
    else
        summary+="  ⏭️  Backup cleanup: Skipped\n"
    fi

    if [[ -n "$recovery_cleanup" ]]; then
        if [[ "$recovery_cleanup" == "0" ]]; then
            summary+="  ✅ Recovery-kit fallback cleanup: OK\n"
        else
            summary+="  ❌ Recovery-kit fallback cleanup: Failed\n"
            ((++critical_failures))
        fi
    fi

    if [[ "${CLEAN_DOCKER:-true}" == "true" ]]; then
        case "$docker_cleanup" in
            0) summary+="  ✅ Docker cleanup: OK\n" ;;
            1)
                summary+="  ⚠️  Docker cleanup: Issues\n"
                ((++advisory_warnings))
                ;;
            *)
                summary+="  ❌ Docker cleanup: Failed\n"
                ((++critical_failures))
                ;;
        esac
    else
        summary+="  ⏭️  Docker cleanup: Skipped\n"
    fi

    if [[ "${OPTIMIZE_DATABASE:-true}" == "true" ]]; then
        if [[ "$db_optimization" == "0" ]]; then
            summary+="  ✅ DB optimization: OK\n"
        else
            summary+="  ❌ DB optimization: Failed\n"
            ((++critical_failures))
        fi
    else
        summary+="  ⏭️  DB optimization: Skipped\n"
    fi

    if [[ "${UPDATE_FIREWALL:-false}" == "true" ]]; then
        case "$firewall_update" in
            0) summary+="  ✅ Firewall update: OK\n" ;;
            75)
                summary+="  ⏭️  Firewall update: Skipped (active operation)\n"
                ((++operation_skips))
                ;;
            *)
                summary+="  ❌ Firewall update: Failed\n"
                ((++critical_failures))
                ;;
        esac
    else
        summary+="  ⏭️  Firewall update: Skipped\n"
    fi

    if [[ "${UPDATE_DNS:-false}" == "true" ]]; then
        case "$dns_update" in
            0) summary+="  ✅ DNS update: OK\n" ;;
            75)
                summary+="  ⏭️  DNS update: Skipped (active operation)\n"
                ((++operation_skips))
                ;;
            *)
                summary+="  ❌ DNS update: Failed\n"
                ((++critical_failures))
                ;;
        esac
    else
        summary+="  ⏭️  DNS update: Skipped\n"
    fi

    if [[ "${TARGETED_MODE:-false}" == "false" ]]; then
        summary+="$(_health_summary_line "$health_validation")\n"
        case "$health_validation" in
            0) ;;
            1) ((++advisory_warnings)) ;;
            75) ((++operation_skips)) ;;
            *) ((++critical_failures)) ;;
        esac
    fi

    if [[ -n "$duration_seconds" && "$duration_seconds" =~ ^[0-9]+$ ]]; then
        summary+="\nDuration: $(_format_duration "$duration_seconds")\n"
    fi

    if (( critical_failures > 0 )); then
        MAINTENANCE_SUMMARY_STATE=issues
        summary+="⚠️  Overall Status: COMPLETED WITH ISSUES\n"
        subject="VaultWarden Maintenance: ISSUES DETECTED"
    elif (( advisory_warnings > 0 && operation_skips > 0 )); then
        MAINTENANCE_SUMMARY_STATE=warnings_and_skips
        summary+="⚠️  Overall Status: COMPLETED WITH WARNINGS AND SKIPS\n"
        subject="VaultWarden Maintenance: WARNINGS AND SKIPS"
    elif (( advisory_warnings > 0 )); then
        MAINTENANCE_SUMMARY_STATE=warnings
        summary+="⚠️  Overall Status: SUCCESS WITH WARNINGS\n"
        subject="VaultWarden Maintenance: SUCCESS WITH WARNINGS"
    elif (( operation_skips > 0 )); then
        MAINTENANCE_SUMMARY_STATE=skips
        summary+="⏭️  Overall Status: COMPLETED WITH SKIPS\n"
        subject="VaultWarden Maintenance: COMPLETED WITH SKIPS"
    else
        summary+="🎉 Overall Status: SUCCESS\n"
        subject="VaultWarden Maintenance: SUCCESS"
    fi

    if (( critical_failures == 1 )); then
        MAINTENANCE_SUMMARY_RESULT=1
    elif (( critical_failures > 1 )); then
        MAINTENANCE_SUMMARY_RESULT=2
    fi

    printf '%b' "$summary"

    if [[ "${EMAIL_NOTIFY:-false}" == "true" ]]; then
        local email_body
        email_body=$(printf '%b' "$summary")
        if send_notification_email "$subject" "$email_body"; then
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
