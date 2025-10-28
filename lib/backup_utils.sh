#!/usr/bin/env bash
# lib/backup_utils.sh - Backup listing functions for VaultWarden-OCI-NG
# Centralized logic previously duplicated in backup.sh and restore.sh

# Ensure this library is only loaded once (using a unique guard)
[[ -n "${VAULTWARDEN_BACKUP_UTILS_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_BACKUP_UTILS_LIB_LOADED=1

# --- Source Common Library (needed for logging) ---
# Assume common.sh is in the same directory or sourced by the calling script
# If not, adjust the path accordingly. Sourcing it here ensures logging works.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- List Backups Function ---
# Populates global associative array BACKUP_LIST_DETAILS[id]="filepath"
# Prints a formatted list to stdout
# Returns 0 on success, 1 if no backups found
list_backups() {
    log_info "Scanning for available local backups..."
    local backup_base_dir="${PROJECT_ROOT:-.}/backups" # Use PROJECT_ROOT if set, else current dir
    # Ensure the global array exists and is cleared
    declare -gA BACKUP_LIST_DETAILS
    BACKUP_LIST_DETAILS=()
    local counter=1
    local details_lines=() # Temp array for formatted lines

    # Use find with printf to get timestamp and path, sort numerically, read line by line
    local find_cmd
    find_cmd="find \"$backup_base_dir/db\" \"$backup_base_dir/full\" \"$backup_base_dir/emergency\" -maxdepth 1 -name '*.age' -type f -printf '%T@ %p\n' 2>/dev/null"

    local sorted_files
    sorted_files=$(eval "$find_cmd" | sort -nr)

    if [[ -z "$sorted_files" ]]; then
        log_warn "No local backups found in ${backup_base_dir}/{db,full,emergency}/"
        return 1
    fi

    local max_lines=0 # Count lines found
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue # Skip empty lines

        # Extract path (everything after the first space)
        local file="${line#* }"
        local filename type timestamp date_str time_str size
        filename=$(basename "$file")
        # Use stat for size to handle potential large files better
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        # Format size human-readably (requires numfmt)
        local human_size="N/A"
        if command -v numfmt >/dev/null 2>&1 && [[ "$size" -gt 0 ]]; then
            human_size=$(numfmt --to=iec --suffix=B --format="%6.1f" "$size")
        elif [[ "$size" -gt 0 ]]; then
             human_size=$(du -h "$file" | cut -f1) # Fallback
        fi


        # Regex to parse filename format
        if [[ $filename =~ ^vw-(db|full)-backup-([0-9]{8})-([0-9]{6})\.sqlite3\.gz\.age$ ]]; then
            type="${BASH_REMATCH[1]}"
            date_str="${BASH_REMATCH[2]}"
            time_str="${BASH_REMATCH[3]}"
        elif [[ $filename =~ ^emergency-kit-([0-9]{8})-([0-9]{6})\.tar\.gz\.age$ ]]; then
            type="emergency"
            date_str="${BASH_REMATCH[1]}"
            time_str="${BASH_REMATCH[2]}"
        else
            type="unknown"
            date_str="--------"
            time_str="------"
        fi

        local formatted_date="${date_str:0:4}-${date_str:4:2}-${date_str:6:2}"
        local formatted_time="${time_str:0:2}:${time_str:2:2}:${time_str:4:2}"
        local padded_type
        printf -v padded_type "%-11s" "$type"

        # Store formatted line and populate the global map
        details_lines+=("$(printf "%3d | %s | %s | %s | %7s | %s" "$counter" "$padded_type" "$formatted_date" "$formatted_time" "$human_size" "$filename")")
        BACKUP_LIST_DETAILS[$counter]="$file" # Use numeric index for associative array
        ((counter++))
        ((max_lines++))
    done <<< "$sorted_files"

    if [[ $max_lines -eq 0 ]]; then
      log_warn "No local backups found matching expected patterns."
      return 1
    fi

    echo ""
    echo "Available Backups (Newest First):"
    echo " ID | Type        | Date       | Time     | Size    | Filename"
    echo "----|-------------|------------|----------|---------|------------------------------------------"
    # Print stored lines
    printf '%s\n' "${details_lines[@]}"
    echo "----|-------------|------------|----------|---------|------------------------------------------"
    echo ""
    return 0
}

# Export the function so calling scripts can use it
export -f list_backups

log_debug "Backup Utils library loaded successfully" 2>/dev/null || true
