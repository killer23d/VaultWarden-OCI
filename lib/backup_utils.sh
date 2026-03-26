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
# PATCHED BUGS (2026-03-10):
#   P2-M3 [MEDIUM]  cleanup_old_backups(): orphaned .meta/.sha256 sidecars
#                   (no corresponding .age file) were never removed, causing
#                   indefinite accumulation. Added a second sweep that finds
#                   and removes all sidecar files whose base .age is absent.
# PATCHED BUGS (2026-03-11) - Audit remediation:
#   AUD-B1 [HIGH]   verify_backup_integrity(): sqlite3 PRAGMA integrity_check
#                   now operates on a private copy of the database in a
#                   restricted tmpdir rather than the live file. This prevents
#                   SQLite WAL-mode inconsistency when VaultWarden is running.
#   AUD-B2 [MEDIUM] get_backup_size(): was using du -sh which returns a
#                   human-readable string unsuitable for arithmetic. Now
#                   returns raw bytes via portable stat (GNU|BSD) so callers
#                   can safely compare values numerically.
#   AUD-B3 [LOW]    cleanup_old_backups(): -mtime reflects last content-
#                   modification time and can be fooled by rsync --times or
#                   touch. Replaced with a portable stat-based ctime age check
#                   so preserved-timestamp restores never bypass retention.
# PATCHED BUGS (2026-03-13):
#   LB-1  [CRITICAL] verify_backup_integrity(): three sequential cp calls
#                   could produce an inconsistent DB snapshot (VaultWarden can
#                   commit a transaction between the first and second cp).
#                   Replaced with sqlite3 .backup (SQLite Online Backup API)
#                   which holds the necessary read lock for a fully consistent
#                   copy regardless of WAL activity.
#   LB-2  [HIGH]    _backup_ctime_age_days() / cleanup_old_backups(): ctime is
#                   reset by cp, mv across filesystems, chmod, or chown, so
#                   backups restored to a fresh host appear 0 days old and are
#                   never cleaned up (unbounded retention).
#                   Fix: new _backup_filename_age_days() parses the immutable
#                   YYYYMMDD-HHMMSS timestamp embedded in the filename as the
#                   primary age source. Falls back to ctime only for files
#                   predating the naming convention (no timestamp in name).
# QOL (2026-03-26):
#   ITEM-10 [QOL]   list_backups(): added per-type size totals and a grand-
#                   total summary line. Operators using `make list-backups`
#                   (or backup.sh --list) on an OCI free-tier VM can now see
#                   total disk consumption at a glance without manual du(1).
#                   Uses the same portable _stat_file_size() helper already
#                   relied on by get_backup_statistics(). A new pure-bash
#                   _format_bytes_human() helper formats byte counts as MB
#                   (one decimal place) without requiring numfmt (GNU-only).

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_BACKUP_UTILS_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_BACKUP_UTILS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _format_bytes_human BYTES
#
# ITEM-10: Formats a raw byte count as a human-readable MB string with one
# decimal place, e.g. 1234567 → "1.2 MB". Pure bash integer arithmetic —
# no numfmt (GNU-only), no awk floating-point, no bc dependency.
#
# Outputs to stdout. Returns 0. Input must be a non-negative integer; any
# non-integer input is treated as 0.
# ---------------------------------------------------------------------------
_format_bytes_human() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    local kb=$(( bytes / 1024 ))
    local mb_int=$(( kb / 1024 ))
    # One decimal place: compute tenths from the remainder KB after removing
    # whole-MB portion, then scale to 0–9.
    local mb_rem_kb=$(( kb - mb_int * 1024 ))
    local mb_dec=$(( mb_rem_kb * 10 / 1024 ))

    printf '%d.%d MB' "$mb_int" "$mb_dec"
}

# --- Backup Validation Functions ---

# List available backups in a directory - STANDARDIZED: Returns exit code
# FIX [ISSUE 13]: Use stat instead of date -r for cross-platform mtime display.
# ITEM-10: Print per-type file count + total size after each type block, plus
#          a grand-total line at the end of all output.
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

    # Grand-total accumulators
    local grand_total_files=0
    local grand_total_bytes=0
    local grand_total_types=0

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local backups
            if backups=$(find "$type_dir" -name "*.age" -type f 2>/dev/null | sort); then
                if [[ -n "$backups" ]]; then
                    echo "=== $backup_type backups ==="

                    # Per-type accumulators
                    local type_count=0
                    local type_bytes=0

                    while IFS= read -r backup_file; do
                        local basename_file size_info age_info
                        basename_file=$(basename "$backup_file")
                        size_info=$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")

                        # FIX [ISSUE 13]: stat -c '%y' is Linux (GNU coreutils);
                        # fall back to BSD stat -f '%Sm' for macOS compatibility.
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

                        # ITEM-10: accumulate raw bytes for the summary line.
                        # _stat_file_size() is exported by lib/crypto.sh and
                        # chooses GNU (-c%s) or BSD (-f%z) stat automatically.
                        local raw_bytes=0
                        if declare -f _stat_file_size &>/dev/null; then
                            raw_bytes=$(_stat_file_size "$backup_file" 2>/dev/null || echo 0)
                            [[ "$raw_bytes" =~ ^[0-9]+$ ]] || raw_bytes=0
                        fi
                        type_bytes=$(( type_bytes + raw_bytes ))
                        (( type_count++ )) || true

                        found_backups=true
                    done <<< "$backups"

                    # ITEM-10: per-type summary line
                    printf "[%s: %d file(s), %s]\n" \
                        "$backup_type" "$type_count" "$(_format_bytes_human "$type_bytes")"
                    echo ""

                    grand_total_files=$(( grand_total_files + type_count ))
                    grand_total_bytes=$(( grand_total_bytes + type_bytes ))
                    (( grand_total_types++ )) || true
                fi
            fi
        fi
    done

    if [[ "$found_backups" == "false" ]]; then
        echo "No backups found in $backup_base_dir"
        return 1
    fi

    # ITEM-10: grand-total line — only shown when there is more than one
    # active type, so a single-type install doesn't get a redundant line.
    if (( grand_total_types > 1 )); then
        printf "Total: %d file(s), %s  (%d type(s) with backups)\n" \
            "$grand_total_files" \
            "$(_format_bytes_human "$grand_total_bytes")" \
            "$grand_total_types"
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

# ---------------------------------------------------------------------------
# verify_backup_integrity DB_PATH [AGE_KEY_FILE]
#
# LB-1 FIX [CRITICAL]: The previous implementation copied the live .db,
# -wal, and -shm files with three sequential cp calls. VaultWarden can commit
# a transaction between the first and second cp, producing an inconsistent
# snapshot. SQLite's PRAGMA integrity_check on such a pair can return a false
# "ok".
#
# Fix: use sqlite3 "$db_path" ".backup '$db_copy'" (SQLite Online Backup API)
# which holds the necessary shared read lock across the entire copy, producing
# a fully consistent snapshot regardless of concurrent WAL activity.
# The WAL and SHM sidecars are NOT manually copied — the Online Backup API
# handles log integration internally.
#
# The tmpdir is mode 700 and cleaned up unconditionally via a local RETURN trap.
# ---------------------------------------------------------------------------
verify_backup_integrity() {
    local db_path="$1"
    local age_key_file="${2:-secrets/keys/age-key.txt}"

    if [[ ! -f "$db_path" ]]; then
        log_error "Database file not found: $db_path"
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_error "verify_backup_integrity: sqlite3 not available"
        return 1
    fi

    # Create a private, restricted working directory for the DB copy.
    local work_dir
    if ! work_dir=$(mktemp -d); then
        log_error "verify_backup_integrity: failed to create temporary directory"
        return 1
    fi
    chmod 700 "$work_dir"

    # Ensure cleanup on every exit path from this function.
    # shellcheck disable=SC2064  # intentional: expand $work_dir now
    trap "rm -rf '$work_dir'" RETURN

    local db_base
    db_base=$(basename "$db_path")
    local db_copy="$work_dir/$db_base"

    # LB-1 FIX: use SQLite Online Backup API via the sqlite3 .backup dot-command.
    # This acquires the correct shared read lock and integrates any pending WAL
    # frames before writing the copy, guaranteeing a consistent snapshot even
    # while VaultWarden is running in WAL mode.
    log_info "Creating consistent DB snapshot via SQLite Online Backup API: $db_base"
    if ! sqlite3 "$db_path" ".backup '${db_copy}'" 2>/dev/null; then
        log_error "verify_backup_integrity: sqlite3 .backup failed for: $db_path"
        return 1
    fi

    log_info "Running SQLite integrity check on snapshot of: $db_base"

    local integrity_result
    if ! integrity_result=$(sqlite3 "$db_copy" "PRAGMA integrity_check;" 2>&1); then
        log_error "sqlite3 failed to open database snapshot: $integrity_result"
        return 1
    fi

    if [[ "$integrity_result" != "ok" ]]; then
        log_error "Database integrity check failed: $integrity_result"
        return 1
    fi

    log_success "Database integrity check passed (Online Backup API snapshot, WAL-safe)"
    return 0
}

# ---------------------------------------------------------------------------
# get_backup_size BACKUP_FILE
#
# AUD-B2 FIX [MEDIUM]: The previous implementation used 'du -sh' which returns
# a human-readable string (e.g. "4.2M"). Any caller attempting arithmetic on
# that value would silently get 0 (in (( )) context) or an error. Changed to
# return the raw byte count via portable stat (GNU: -c%s, BSD/macOS: -f%z) so
# callers can safely perform numeric comparisons. Outputs bytes as a plain
# integer on stdout. Returns 1 if the file does not exist or size cannot be
# determined.
# ---------------------------------------------------------------------------
get_backup_size() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "get_backup_size: file not found: $backup_file"
        return 1
    fi

    local size_bytes
    size_bytes=$(stat -c%s "$backup_file" 2>/dev/null \
        || stat -f%z "$backup_file" 2>/dev/null \
        || echo "")

    if [[ -z "$size_bytes" || ! "$size_bytes" =~ ^[0-9]+$ ]]; then
        log_error "get_backup_size: could not determine size of: $backup_file"
        return 1
    fi

    printf '%s\n' "$size_bytes"
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

# ---------------------------------------------------------------------------
# _backup_filename_age_days FILE
#
# LB-2 FIX: Primary age source for retention. Extracts the YYYYMMDD-HHMMSS
# timestamp embedded in the backup filename (e.g.
#   db-20240315-143022.age  → 20240315-143022)
# and converts it to whole days elapsed since that timestamp.
#
# Returns the age in days on stdout. If no recognisable timestamp is found in
# the filename, returns empty string so the caller can fall back to ctime.
# ---------------------------------------------------------------------------
_backup_filename_age_days() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")

    # Match YYYYMMDD-HHMMSS anywhere in the filename.
    local ts_date ts_time
    if [[ "$basename_file" =~ ([0-9]{8})-([0-9]{6}) ]]; then
        ts_date="${BASH_REMATCH[1]}"   # e.g. 20240315
        ts_time="${BASH_REMATCH[2]}"   # e.g. 143022
    else
        # No timestamp in filename — signal fallback needed.
        echo ""
        return
    fi

    # Reformat for date(1): YYYY-MM-DD HH:MM:SS
    local ts_str
    ts_str="${ts_date:0:4}-${ts_date:4:2}-${ts_date:6:2} ${ts_time:0:2}:${ts_time:2:2}:${ts_time:4:2}"

    local ts_epoch
    # GNU date
    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || \
    # BSD/macOS date
    ts_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts_str" +%s 2>/dev/null) || true

    if [[ -z "$ts_epoch" || ! "$ts_epoch" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - ts_epoch) / 86400 ))
}

# ---------------------------------------------------------------------------
# _backup_ctime_age_days FILE
#
# Returns the age of FILE in whole days based on ctime (inode change time),
# using portable stat (GNU|BSD). Kept as a fallback for files that predate
# the YYYYMMDD-HHMMSS naming convention.
# ---------------------------------------------------------------------------
_backup_ctime_age_days() {
    local file="$1"
    local ctime_epoch now_epoch
    ctime_epoch=$(stat -c%Z "$file" 2>/dev/null || stat -f%c "$file" 2>/dev/null || echo "")
    if [[ -z "$ctime_epoch" || ! "$ctime_epoch" =~ ^[0-9]+$ ]]; then
        # Cannot determine ctime; treat as 0 days old (do not delete).
        echo "0"
        return
    fi
    now_epoch=$(date +%s)
    echo $(( (now_epoch - ctime_epoch) / 86400 ))
}

# Clean up old backups based on retention policy - STANDARDIZED: Returns exit code
#
# BUG-B4 FIX: unquoted $retention_days in find -mtime argument. Under set -u
# an unset variable throws 'unbound variable'. Quoted the argument.
#
# P2-M3 FIX: orphaned sidecar sweep.
# The original code only searched for *.age files and deleted their paired
# sidecars when an .age file crossed the retention threshold. This left
# orphaned .meta and .sha256 files behind whenever an .age file had already
# been removed by an earlier run, a manual deletion, or an interrupted
# cleanup, causing them to accumulate indefinitely.
# The fix adds a second sweep after the .age pass: for every .meta and
# .sha256 file found in the directory, if the corresponding .age file does
# not exist, the sidecar is removed immediately (no age-based threshold
# needed — if the primary is gone the sidecar is always orphaned).
#
# LB-2 FIX: Replaced ctime-only age check with _backup_filename_age_days().
# The filename timestamp is immutable across cp/mv/chmod/chown and reliably
# reflects when the backup was created. Falls back to _backup_ctime_age_days()
# only when the filename contains no recognisable YYYYMMDD-HHMMSS stamp
# (i.e. files predating the current naming convention).
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

    # LB-2 FIX: prefer filename-embedded timestamp for age calculation;
    # fall back to ctime only for files without a recognisable timestamp.
    while IFS= read -r backup_file; do
        if [[ -n "$backup_file" ]]; then
            local age_days
            age_days=$(_backup_filename_age_days "$backup_file")
            if [[ -z "$age_days" ]]; then
                # No timestamp in filename — fall back to ctime.
                age_days=$(_backup_ctime_age_days "$backup_file")
                log_debug "Retention: no filename timestamp for $(basename "$backup_file") — using ctime (${age_days}d)"
            fi
            if (( age_days > retention_days )); then
                log_debug "Removing old backup (${age_days}d > ${retention_days}d): $(basename "$backup_file")"
                rm -f "$backup_file" "$backup_file.sha256" "$backup_file.meta" 2>/dev/null
                (( deleted_count++ )) || true
            fi
        fi
    done < <(find "$backup_dir" -name "*.age" -type f 2>/dev/null)

    # P2-M3 FIX: sweep for orphaned sidecars (.meta and .sha256) whose
    # corresponding .age primary file no longer exists. These are left behind
    # when the .age file was removed by a previous (possibly partial) cleanup
    # run, a manual deletion, or any other out-of-band removal. Because the
    # primary is gone there is no meaningful retention check — every orphan
    # is removed unconditionally.
    local orphan_count=0
    while IFS= read -r sidecar; do
        if [[ -n "$sidecar" ]]; then
            # Derive the expected .age path: strip the trailing .meta or .sha256
            local primary="${sidecar%.meta}"
            primary="${primary%.sha256}"
            if [[ ! -f "$primary" ]]; then
                log_debug "Removing orphaned sidecar: $(basename "$sidecar")"
                rm -f "$sidecar" 2>/dev/null
                (( orphan_count++ )) || true
            fi
        fi
    done < <(find "$backup_dir" \( -name "*.meta" -o -name "*.sha256" \) -type f 2>/dev/null)

    if (( deleted_count > 0 )); then
        log_success "Cleaned up $deleted_count old $backup_type backups"
    else
        log_debug "No old $backup_type backups to clean up"
    fi

    if (( orphan_count > 0 )); then
        log_success "Removed $orphan_count orphaned sidecar file(s) from $backup_type backups"
    else
        log_debug "No orphaned sidecar files found in $backup_type backups"
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
export -f verify_backup_integrity get_backup_size _backup_ctime_age_days
export -f _backup_filename_age_days _format_bytes_human

log_debug "Backup utilities library loaded successfully - standardized error handling" 2>/dev/null || true
