#!/usr/bin/env bash
# lib/backup_utils.sh - Backup utility functions for VaultWarden-OCI-NG
#
# PATCHED BUGS (2026-03-06):
#   BUG-B1 [HIGH]   check_backup_disk_space(): df --output=avail is GNU-only.
#                   BSD/macOS df does not support --output=. Replaced with a
#                   portable awk one-liner.
#   BUG-B2 [HIGH]   get_backup_statistics(): find -exec stat -c%s {} + is
#                   GNU-only. Replaced with find | while + _stat_file_size().
#   BUG-B3 [MEDIUM] create_backup_metadata(): stat -c%s GNU-only. Replaced
#                   with _stat_file_size() helper from lib/crypto.sh.
#   BUG-B4 [MEDIUM] cleanup_old_backups(): unquoted -mtime +$retention_days.
#                   Quoted to prevent set -u unbound-variable failure.
#   BUG-B5 [LOW]    create_backup_metadata(): $? anti-pattern after heredoc.
#                   Replaced with direct 'if ! cat > file <<EOF' test.

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_BACKUP_UTILS_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_BACKUP_UTILS_LIB_LOADED=1

# --- Backup Validation Functions ---

# List available backups in a directory - STANDARDIZED: Returns exit code
# FIX [ISSUE 13]: Use stat instead of date -r for cross-platform mtime display.
list_backups() {
    local backup_base_dir="${1:-backups}"

    if [[ ! -d "$backup_base_dir" ]]; then
        log_error "Backup directory not found: $backup_base_dir"
        return 1
    fi

    log_info "Available backups:"
    echo ""

    local backup_types=("db" "full" "emergency")
    local found_backups=false

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local backups
            if backups=$(find "$type_dir" -name "*.age" -type f 2>/dev/null | sort); then
                if [[ -n "$backups" ]]; then
                    echo "=== $backup_type backups ==="
                    while IFS= read -r backup_file; do
                        local basename_file size_info age_info
                        basename_file=$(basename "$backup_file")
                        size_info=$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")

                        # FIX [ISSUE 13]: stat -c '%y' is Linux (GNU coreutils);
                        # fall back to BSD stat -f '%Sm' for macOS compatibility.
                        # Both are far more portable than 'date -r FILE' which is
                        # macOS-only and silently fails on every Linux system.
                        age_info=$(stat -c '%y' "$backup_file" 2>/dev/null \
                            | cut -c1-16 \
                            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$backup_file" 2>/dev/null \
                            || echo "unknown")

                        printf "  %-40s %10s  %s\n" "$basename_file" "$size_info" "$age_info"

                        # Show metadata if available
                        if [[ -f "$backup_file.meta" ]]; then
                            local vw_version
                            vw_version=$(grep "vaultwarden_version=" "$backup_file.meta" 2>/dev/null | cut -d= -f2 || echo "unknown")
                            printf "    └─ VaultWarden: %s\n" "$vw_version"
                        fi

                        found_backups=true
                    done <<< "$backups"
                    echo ""
                fi
            fi
        fi
    done

    if [[ "$found_backups" == "false" ]]; then
        echo "No backups found in $backup_base_dir"
        return 1
    fi

    return 0
}

# Validate backup file integrity - STANDARDIZED: Returns exit code
# FIX [ISSUE 7]: Decryption test uses direct redirect; avoids pipeline
# PIPESTATUS trap under set -euo pipefail.
validate_backup_integrity() {
    local backup_file="$1"
    local age_key_file="${2:-secrets/keys/age-key.txt}"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    log_info "Validating backup integrity: $(basename "$backup_file")"

    # Check file size (basic corruption detection)
    # Use inline GNU||BSD fallback for portability.
    local file_size
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")

    if (( file_size < 1024 )); then
        log_error "Backup file suspiciously small (${file_size} bytes)"
        return 1
    fi

    # Check SHA256 if available
    if [[ -f "$backup_file.sha256" ]]; then
        local expected_checksum
        expected_checksum=$(cat "$backup_file.sha256" 2>/dev/null)

        if [[ -n "$expected_checksum" ]]; then
            if ! verify_sha256 "$backup_file" "$expected_checksum"; then
                log_error "Backup file checksum verification failed"
                return 1
            fi
            log_success "Checksum verification passed"
        fi
    fi

    # FIX [ISSUE 7]: Test decryption by redirecting age output directly to
    # /dev/null. This avoids the pipeline PIPESTATUS trap: age's own exit code
    # is captured directly, so any decryption failure (wrong key, corrupt file,
    # truncated header) correctly propagates as a non-zero return.
    if ! age -d -i "$age_key_file" "$backup_file" > /dev/null 2>&1; then
        log_error "Backup file decryption test failed (wrong key or corrupt file)"
        return 1
    fi

    log_success "Backup integrity validation passed"
    return 0
}

# Check available disk space for backup operations - STANDARDIZED: Returns exit code
#
# BUG-B1 FIX: df --output=avail is GNU coreutils-only. BSD/macOS df does not
# support the --output= long option and the function always reported
# 'Cannot determine available disk space' on macOS.
#
# Replaced with a portable awk approach that reads the last column of the
# last row of `df` output.  POSIX df guarantees the available-blocks value
# is in column 4 (1 KiB blocks on both GNU and BSD), so the awk expression
# is identical on Linux and macOS.
check_backup_disk_space() {
    local target_dir="$1"
    local required_space_mb="${2:-1000}"  # Default 1GB

    if [[ ! -d "$target_dir" ]]; then
        log_error "Target directory not found: $target_dir"
        return 1
    fi

    # BUG-B1 FIX: portable df — column 4 is Available (1 KiB blocks) on
    # both GNU df and BSD/macOS df.
    local available_space_kb
    # FIX [L-11]: Use awk 'END' (last line) instead of 'NR==2' to handle long
    # filesystem paths that cause df to wrap output across two lines.
    available_space_kb=$(df "$target_dir" 2>/dev/null | awk 'END {print $4}')

    if [[ -z "$available_space_kb" ]] || ! [[ "$available_space_kb" =~ ^[0-9]+$ ]]; then
        log_error "Cannot determine available disk space for: $target_dir"
        return 1
    fi

    local available_space_mb=$((available_space_kb / 1024))

    if (( available_space_mb < required_space_mb )); then
        log_error "Insufficient disk space: need ${required_space_mb}MB, have ${available_space_mb}MB"
        return 1
    fi

    log_debug "Disk space check passed: ${available_space_mb}MB available (need ${required_space_mb}MB)"
    return 0
}

# Clean up old backups based on retention policy - STANDARDIZED: Returns exit code
#
# BUG-B4 FIX: unquoted $retention_days in find -mtime argument. Under set -u
# an unset variable throws 'unbound variable'. Quoted the argument.
cleanup_old_backups() {
    local backup_dir="$1"
    local backup_type="$2"
    local retention_days="$3"

    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory not found: $backup_dir"
        return 1
    fi

    if [[ ! "$retention_days" =~ ^[0-9]+$ ]] || (( retention_days < 1 )); then
        log_error "Invalid retention days: $retention_days"
        return 1
    fi

    log_info "Cleaning up $backup_type backups older than $retention_days days"

    local deleted_count=0
    local old_backups

    # BUG-B4 FIX: quoted the +$retention_days argument
    if old_backups=$(find "$backup_dir" -name "*.age" -type f -mtime "+$retention_days" 2>/dev/null); then
        while IFS= read -r backup_file; do
            if [[ -n "$backup_file" ]]; then
                log_debug "Removing old backup: $(basename "$backup_file")"
                rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta" 2>/dev/null
                (( deleted_count++ )) || true
            fi
        done <<< "$old_backups"
    fi

    if (( deleted_count > 0 )); then
        log_success "Cleaned up $deleted_count old $backup_type backups"
    else
        log_debug "No old $backup_type backups to clean up"
    fi

    return 0
}

# Get backup statistics - STANDARDIZED: Returns exit code
#
# BUG-B2 FIX: find -exec stat -c%s {} + is GNU-only. On macOS stat -c%s
# errors and awk sums to 0, reporting all backup sizes as 0 MB.
#
# Replaced with a find | while loop using _stat_file_size() (exported by
# lib/crypto.sh) which selects the correct stat format per platform.
get_backup_statistics() {
    local backup_base_dir="${1:-backups}"

    if [[ ! -d "$backup_base_dir" ]]; then
        log_error "Backup directory not found: $backup_base_dir"
        return 1
    fi

    local backup_types=("db" "full" "emergency")
    local total_backups=0
    local total_size_bytes=0

    echo "Backup Statistics:"
    echo "=================="

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local count=0
            local size_bytes=0

            # BUG-B2 FIX: portable size accumulation via _stat_file_size()
            while IFS= read -r f; do
                local fsz
                fsz=$(_stat_file_size "$f" 2>/dev/null || echo 0)
                [[ -z "$fsz" || ! "$fsz" =~ ^[0-9]+$ ]] && fsz=0
                size_bytes=$(( size_bytes + fsz ))
                (( count++ )) || true
            done < <(find "$type_dir" -name "*.age" -type f 2>/dev/null)

            local size_mb=$(( size_bytes / 1024 / 1024 ))

            printf "%-10s: %3d backups, %6d MB\n" "$backup_type" "$count" "$size_mb"

            total_backups=$(( total_backups + count ))
            total_size_bytes=$(( total_size_bytes + size_bytes ))
        else
            printf "%-10s: %3d backups, %6d MB\n" "$backup_type" 0 0
        fi
    done

    local total_size_mb=$(( total_size_bytes / 1024 / 1024 ))
    echo "=================="
    printf "%-10s: %3d backups, %6d MB\n" "TOTAL" "$total_backups" "$total_size_mb"

    return 0
}

# Create backup metadata file - STANDARDIZED: Returns exit code
#
# BUG-B3 FIX: stat -c%s is GNU-only. Replaced with _stat_file_size() from
# lib/crypto.sh for consistent portable behaviour.
# BUG-B5 FIX: replaced '$? -eq 0' anti-pattern after heredoc with a direct
# 'if ! cat > file <<EOF' guard.
create_backup_metadata() {
    local backup_file="$1"
    local backup_type="$2"
    local additional_info="${3:-}"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found for metadata creation: $backup_file"
        return 1
    fi

    local metadata_file="$backup_file.meta"
    local timestamp file_size checksum hostname

    timestamp=$(date -Iseconds)
    # BUG-B3 FIX: use portable _stat_file_size() wrapper
    file_size=$(_stat_file_size "$backup_file" 2>/dev/null || echo "0")
    [[ -z "$file_size" || ! "$file_size" =~ ^[0-9]+$ ]] && file_size=0
    hostname=$(hostname -f 2>/dev/null || hostname)

    if ! checksum=$(calculate_sha256 "$backup_file"); then
        log_warn "Could not calculate checksum for metadata"
        checksum="unavailable"
    fi

    local vw_version="unknown"
    if require_docker >/dev/null 2>&1; then
        vw_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")
    fi

    # BUG-B5 FIX: test the cat heredoc directly instead of checking $?
    # after the fact, which is an anti-pattern ($? may be stale or from
    # a different command in complex pipelines).
    if ! cat > "$metadata_file" <<EOF
# VaultWarden Backup Metadata
backup_type=$backup_type
timestamp=$timestamp
hostname=$hostname
file_size=$file_size
sha256=$checksum
vaultwarden_version=$vw_version
creator=VaultWarden-OCI-NG
$additional_info
EOF
    then
        log_error "Failed to create metadata file: $metadata_file"
        return 1
    fi

    log_debug "Metadata created: $(basename "$metadata_file")"
    return 0
}

# Export functions for use by scripts
export -f list_backups validate_backup_integrity check_backup_disk_space
export -f cleanup_old_backups get_backup_statistics create_backup_metadata

log_debug "Backup utilities library loaded successfully - standardized error handling" 2>/dev/null || true
