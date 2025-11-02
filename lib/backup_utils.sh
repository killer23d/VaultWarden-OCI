#!/usr/bin/env bash
# lib/backup_utils.sh - Backup utility functions for VaultWarden-OCI-NG
# ENHANCED: Standardized error handling patterns - functions return, callers decide
# Common backup operations with consistent error handling

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_BACKUP_UTILS_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_BACKUP_UTILS_LIB_LOADED=1

# --- Backup Validation Functions ---

# List available backups in a directory - STANDARDIZED: Returns exit code
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
                        age_info=$(date -r "$backup_file" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
                        
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

    # Test decryption (minimal - just first few bytes)
    if ! age -d -i "$age_key_file" "$backup_file" | head -c 1 > /dev/null 2>&1; then
        log_error "Backup file decryption test failed"
        return 1
    fi

    log_success "Backup integrity validation passed"
    return 0
}

# Check available disk space for backup operations - STANDARDIZED: Returns exit code
check_backup_disk_space() {
    local target_dir="$1"
    local required_space_mb="${2:-1000}"  # Default 1GB

    if [[ ! -d "$target_dir" ]]; then
        log_error "Target directory not found: $target_dir"
        return 1
    fi

    local available_space_kb
    available_space_kb=$(df --output=avail "$target_dir" 2>/dev/null | tail -1)
    
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
    
    # Find backups older than retention period
    if old_backups=$(find "$backup_dir" -name "*.age" -type f -mtime +$retention_days 2>/dev/null); then
        while IFS= read -r backup_file; do
            if [[ -n "$backup_file" ]]; then
                log_debug "Removing old backup: $(basename "$backup_file")"
                
                # Remove backup file and associated metadata
                rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta" 2>/dev/null
                ((deleted_count++))
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
            local count size_bytes
            count=$(find "$type_dir" -name "*.age" -type f 2>/dev/null | wc -l)
            size_bytes=$(find "$type_dir" -name "*.age" -type f -exec stat -c%s {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
            
            local size_mb=$((size_bytes / 1024 / 1024))
            
            printf "%-10s: %3d backups, %6d MB\n" "$backup_type" "$count" "$size_mb"
            
            total_backups=$((total_backups + count))
            total_size_bytes=$((total_size_bytes + size_bytes))
        else
            printf "%-10s: %3d backups, %6d MB\n" "$backup_type" 0 0
        fi
    done

    local total_size_mb=$((total_size_bytes / 1024 / 1024))
    echo "=================="
    printf "%-10s: %3d backups, %6d MB\n" "TOTAL" "$total_backups" "$total_size_mb"

    return 0
}

# Create backup metadata file - STANDARDIZED: Returns exit code
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
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    hostname=$(hostname -f 2>/dev/null || hostname)
    
    # Calculate checksum
    if ! checksum=$(calculate_sha256 "$backup_file"); then
        log_warn "Could not calculate checksum for metadata"
        checksum="unavailable"
    fi

    # Get VaultWarden version if possible
    local vw_version="unknown"
    if require_docker >/dev/null 2>&1; then
        vw_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")
    fi

    # Create metadata file
    cat > "$metadata_file" <<EOF
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

    if [[ $? -eq 0 ]]; then
        log_debug "Metadata created: $(basename "$metadata_file")"
        return 0
    else
        log_error "Failed to create metadata file: $metadata_file"
        return 1
    fi
}

# Export functions for use by scripts
export -f list_backups validate_backup_integrity check_backup_disk_space
export -f cleanup_old_backups get_backup_statistics create_backup_metadata

log_debug "Backup utilities library loaded successfully - standardized error handling" 2>/dev/null || true
