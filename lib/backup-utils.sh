#!/usr/bin/env bash
# lib/backup-utils.sh — Backup and restore helpers for VaultWarden-OCI.
# shellcheck disable=SC1091
#
# Provides:
#   Listing    : list_backups, get_backup_statistics, get_backup_size
#   Validation : check_backup_disk_space
#   Retention  : backup_retention_days_for_type, cleanup_old_backups,
#                _backup_filename_timestamp_epoch, _backup_filename_age_days,
#                _backup_ctime_age_days, _backup_newest_timestamped_archive
#   Metadata   : create_backup_metadata, _resolve_rclone_config,
#                validate_rclone_config_path
#
# Depends on / Load order:
#   lib/log.sh is auto-loaded if it has not already been sourced.
#   lib/crypto.sh, lib/common.sh, and lib/docker.sh should be sourced before
#   callers use helpers that rely on their exported functions.
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/crypto.sh"
#   source "${LIB_DIR}/docker.sh"
#   source "${LIB_DIR}/backup-utils.sh"

[[ -n "${VAULTWARDEN_BACKUP_UTILS_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_BACKUP_UTILS_LIB_LOADED=1

# Self-load log.sh if not already loaded — allows this lib to be sourced
# directly without going through common.sh or a caller that pre-loads log.sh.
_VW_BACKUP_UTILS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_VW_BACKUP_UTILS_LIB_DIR}/log.sh"
unset _VW_BACKUP_UTILS_LIB_DIR

_format_bytes_human() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    local kb=$(( bytes / 1024 ))
    local mb_int=$(( kb / 1024 ))

    if (( mb_int == 0 )); then
        printf '%d KB' "$kb"
        return
    fi

    local mb_rem_kb=$(( kb - mb_int * 1024 ))
    local mb_dec=$(( mb_rem_kb * 10 / 1024 ))

    printf '%d.%d MB' "$mb_int" "$mb_dec"
}


# ---------------------------------------------------------------------------
# _json_escape STR
#
# Emit STR with all characters that are forbidden or must be escaped inside a
# JSON string (RFC 8259 §7) replaced with their canonical escape sequences:
#
#   \     →  \\
#   "     →  \"
#   \b    →  \b   (0x08)
#   \t    →  \t   (0x09)
#   \n    →  \n   (0x0A)
#   \f    →  \f   (0x0C)
#   \r    →  \r   (0x0D)
#   other C0 control characters (0x00–0x1F) → \uXXXX
#
# Implementation: pure awk (POSIX), no external dependencies beyond what is
# available on every OCI base image.  Works on Bash 3.x and later.
#
# Usage:
#   escaped=$(_json_escape "$some_string")
#   printf '{"key":"%s"}\n' "$escaped"
# ---------------------------------------------------------------------------
_json_escape() {
    printf '%s' "$1" | awk '
    BEGIN {
        ORS = ""
        for (i = 0; i <= 127; i++) {
            ord_map[sprintf("%c", i)] = i
        }
    }
    {
        n = split($0, chars, "")
        if (NR > 1) printf "\\n"
        for (i = 1; i <= n; i++) {
            c = chars[i]
            o = (c in ord_map) ? ord_map[c] : -1
            if      (c == "\\")          printf "\\\\"
            else if (c == "\"")          printf "\\\""
            else if (o == 8)             printf "\\b"
            else if (o == 9)             printf "\\t"
            else if (o == 10)            printf "\\n"
            else if (o == 12)            printf "\\f"
            else if (o == 13)            printf "\\r"
            else if (o >= 0 && o <= 31)  printf "\\u%04x", o
            else                         printf "%s", c
        }
    }
    '
}

# ---------------------------------------------------------------------------
# _backup_age_color MTIME_EPOCH — ux.md #36
#
# Maps a file's mtime epoch to a color string based on how old it is:
#   < 24 h  → green  (fresh, backup is current)
#   1 – 7 d → yellow (aging, backup getting old)
#   > 7 d   → red    (stale, backup overdue for rotation)
#
# Outputs the ANSI escape for the appropriate color, or empty string when
# stdout is not a TTY (so piped/logged output stays clean).
# ---------------------------------------------------------------------------
_backup_age_color() {
    local age_days="$1"

    if [[ ! -t 1 ]]; then
        printf ''
        return
    fi

    if [[ ! "${age_days}" =~ ^[0-9]+$ ]]; then
        printf '%s' "${COLOR_YELLOW}"
        return
    fi

    if (( age_days < 3 )); then
        printf '%s' "${COLOR_GREEN}"
    elif (( age_days < 14 )); then
        printf '%s' "${COLOR_YELLOW}"
    else
        printf '%s' "${COLOR_RED}"
    fi
}

list_backups() {
    local backup_base_dir="${1:-backups}"
    local json_output="${2:-false}"

    if [[ ! -d "$backup_base_dir" ]]; then
        if [[ "${json_output}" == "true" ]]; then
            printf '{"backups":[]}\n'
            return 0
        fi
        log_error "Backup directory not found: $backup_base_dir"
        return 1
    fi

    local backup_types=("db" "full" "emergency")

    if [[ "$json_output" == "true" ]]; then
        printf '{"backups":['
        local first=true
        local backup_type type_dir backup_file fname size_bytes age_days mtime
        for backup_type in "${backup_types[@]}"; do
            type_dir="$backup_base_dir/$backup_type"
            [[ -d "$type_dir" ]] || continue
            while IFS= read -r -d '' backup_file; do
                fname=$(basename "$backup_file")
                size_bytes=$(stat -c '%s' "$backup_file" 2>/dev/null || stat -f '%z' "$backup_file" 2>/dev/null || echo 0)
                age_days=$(_backup_filename_age_days "$backup_file" 2>/dev/null || echo "")
                [[ "$age_days" =~ ^[0-9]+$ ]] || age_days=-1
                mtime=$(stat -c '%Y' "$backup_file" 2>/dev/null || stat -f '%m' "$backup_file" 2>/dev/null || echo 0)
                [[ "$first" == "true" ]] && first=false || printf ','
                printf '{"type":"%s","file":"%s","path":"%s","size_bytes":%s,"age_days":%s,"mtime_epoch":%s}' \
                    "$backup_type" "$(_json_escape "$fname")" "$(_json_escape "$backup_file")" \
                    "$size_bytes" "$age_days" "$mtime"
            done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null | sort -z)
        done
        printf ']}\n'
        return 0
    fi

    log_info "Available backups:"
    echo ""

    local _nc
    [[ -t 1 ]] && _nc="${COLOR_RESET}" || _nc=""

    local found_backups=false

    local grand_total_files=0
    local grand_total_bytes=0
    local grand_total_types=0

    # Pre-scan: check whether any .age files exist across all types so we
    # can print the column header exactly once before the first data row.
    local _has_any_files=false
    local _pre_type
    for _pre_type in "${backup_types[@]}"; do
        if [[ -d "$backup_base_dir/$_pre_type" ]] && \
           [[ -n "$(find "$backup_base_dir/$_pre_type" -name '*.age' -type f -print -quit 2>/dev/null)" ]]; then
            _has_any_files=true
            break
        fi
    done

    if [[ "${_has_any_files}" == "true" ]]; then
        printf '%-11s  %-44s  %10s  %s\n' "TYPE" "FILE" "SIZE" "AGE"
        printf '%-11s  %-44s  %10s  %s\n' "-----------" "--------------------------------------------" "----------" "--------"
    fi

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local has_files=false
            local type_count=0
            local type_bytes=0

            while IFS= read -r backup_file; do
                has_files=true
                local basename_file size_info age_days age_display age_color
                basename_file=$(basename "$backup_file")
                size_info=$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")
                age_days=$(_backup_filename_age_days "$backup_file" 2>/dev/null || echo "")
                [[ -z "$age_days" ]] && age_days=$(_backup_ctime_age_days "$backup_file" 2>/dev/null || echo "")
                if [[ "$age_days" =~ ^[0-9]+$ ]]; then
                    age_display="${age_days}d"
                else
                    age_display="unknown"
                fi

                age_color="$(_backup_age_color "${age_days}")"

                printf "  %-11s  %-44s  %10s  ${age_color}%s${_nc}\n" \
                    "$backup_type" "$basename_file" "$size_info" "$age_display"

                if [[ -f "$backup_file.meta" ]]; then
                    local vw_version
                    vw_version=$(grep "vaultwarden_version=" "$backup_file.meta" 2>/dev/null | cut -d= -f2 || echo "unknown")
                    printf "    └─ VaultWarden: %s\n" "$vw_version"
                fi

                local raw_bytes=0
                if declare -f _stat_file_size &>/dev/null; then
                    raw_bytes=$(_stat_file_size "$backup_file" 2>/dev/null || echo 0)
                    [[ "$raw_bytes" =~ ^[0-9]+$ ]] || raw_bytes=0
                fi
                type_bytes=$(( type_bytes + raw_bytes ))
                (( type_count++ )) || true

                found_backups=true
            done < <(find "$type_dir" -name "*.age" -type f 2>/dev/null | sort)

            if [[ "$has_files" == false ]]; then continue; fi

            printf "[%s: %d file(s), %s]\n" \
                "$backup_type" "$type_count" "$(_format_bytes_human "$type_bytes")"
            echo ""

            grand_total_files=$(( grand_total_files + type_count ))
            grand_total_bytes=$(( grand_total_bytes + type_bytes ))
            (( grand_total_types++ )) || true
        fi
    done

    if [[ "$found_backups" == "false" ]]; then
        echo "No backups found in $backup_base_dir"
        return 1
    fi

    if (( grand_total_types > 1 )); then
        printf "Total: %d file(s), %s  (%d type(s) with backups)\n" \
            "$grand_total_files" \
            "$(_format_bytes_human "$grand_total_bytes")" \
            "$grand_total_types"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# verify_backup_integrity DB_PATH
#
# Uses sqlite3 "$db_path" ".backup '$db_copy'" (SQLite Online Backup API)
# which holds the necessary shared read lock across the entire copy, producing
# a fully consistent snapshot regardless of concurrent WAL activity.
# The WAL and SHM sidecars are NOT manually copied — the Online Backup API
# handles log integration internally.
#
# The tmpdir is mode 700 and cleaned up unconditionally via a local RETURN trap.
# ---------------------------------------------------------------------------
verify_backup_integrity() {
    local db_path="$1"

    if [[ ! -f "$db_path" ]]; then
        log_error "Database file not found: $db_path"
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_error "verify_backup_integrity: sqlite3 not available"
        return 1
    fi

    local work_dir
    if ! work_dir=$(mktemp -d); then
        log_error "verify_backup_integrity: failed to create temporary directory"
        return 1
    fi
    chmod 700 "$work_dir"

    # shellcheck disable=SC2064  # intentional: expand $work_dir now
    trap "rm -rf '$work_dir'" RETURN

    local db_base
    db_base=$(basename "$db_path")
    local db_copy="$work_dir/$db_base"

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

# Uses a portable awk approach because POSIX df guarantees available blocks
# in column 4 on both GNU and BSD implementations.
check_backup_disk_space() {
    local target_dir="$1"
    local required_space_mb="${2:-1000}"
    local label="${3:-backup}"

    if [[ ! -d "$target_dir" ]]; then
        log_warn "check_backup_disk_space: target directory does not exist yet — disk space check skipped: $target_dir"
        return 0
    fi

    local available_space_kb
    available_space_kb="$(df -Pk "$target_dir" 2>/dev/null | awk 'END {print $4}')"
    if [[ -z "$available_space_kb" || ! "$available_space_kb" =~ ^[0-9]+$ ]]; then
        log_error "Cannot determine available disk space for ${label}: $target_dir"
        return 1
    fi

    local available_space_mb=$((available_space_kb / 1024))
    if (( available_space_mb < required_space_mb )); then
        log_error "Insufficient space for ${label}: need ${required_space_mb}MB, have ${available_space_mb}MB at $target_dir"
        log_error "Free space or choose a larger configured BACKUP_DIR, then retry. Check: df -h '$target_dir'"
        return 1
    fi

    log_debug "Disk space check passed for ${label}: ${available_space_mb}MB available (need ${required_space_mb}MB)"
}

# ---------------------------------------------------------------------------
# backup_retention_days_for_type TYPE [EXPLICIT_OVERRIDE]
#
# Resolves the retention policy in one place. A non-empty explicit override
# (the runner's --keep value) wins, followed by the type-specific setting, the
# shared BACKUP_RETENTION_DAYS setting, and finally the historical per-tier
# defaults: 14 days for db, 30 days for full, and 90 days for emergency.
# ---------------------------------------------------------------------------
backup_retention_days_for_type() {
    local backup_type="${1:-}"
    local explicit_override="${2:-}"
    local specific_key retention="" safe_default

    case "$backup_type" in
        db)
            specific_key="BACKUP_RETENTION_DB_DAYS"
            safe_default=14
            ;;
        full)
            specific_key="BACKUP_RETENTION_FULL_DAYS"
            safe_default=30
            ;;
        emergency)
            specific_key="BACKUP_RETENTION_EMERGENCY_DAYS"
            safe_default=90
            ;;
        *)
            log_error "Unknown backup type for retention: ${backup_type:-<empty>}"
            return 1
            ;;
    esac

    if [[ -n "$explicit_override" ]]; then
        retention="$explicit_override"
    else
        retention="$(get_config_value "$specific_key" "")"
        [[ -n "$retention" ]] || retention="$(get_config_value "BACKUP_RETENTION_DAYS" "")"
        [[ -n "$retention" ]] || retention="$safe_default"
    fi

    if [[ ! "$retention" =~ ^[0-9]+$ ]] || (( 10#$retention < 1 )); then
        log_error "Invalid retention value for ${backup_type}: '${retention}' — expected a positive integer"
        return 1
    fi

    printf '%d\n' "$((10#$retention))"
}

# ---------------------------------------------------------------------------
# _backup_filename_timestamp_epoch FILE
#
# Extracts the YYYYMMDD-HHMMSS timestamp embedded in a backup filename and
# returns its epoch. If no parseable timestamp is found, returns empty output.
# ---------------------------------------------------------------------------
_backup_filename_timestamp_epoch() {
    local file="$1"
    local basename_file
    basename_file=$(basename "$file")

    local ts_date ts_time
    if [[ "$basename_file" =~ ([0-9]{8})[_-]([0-9]{6}) ]]; then
        ts_date="${BASH_REMATCH[1]}"   # e.g. 20240315
        ts_time="${BASH_REMATCH[2]}"   # e.g. 143022
    else
        echo ""
        return
    fi

    local ts_str
    ts_str="${ts_date:0:4}-${ts_date:4:2}-${ts_date:6:2} ${ts_time:0:2}:${ts_time:2:2}:${ts_time:4:2}"

    local ts_epoch
    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || \
    ts_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts_str" +%s 2>/dev/null) || true

    if [[ -z "$ts_epoch" || ! "$ts_epoch" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi

    echo "$ts_epoch"
}

# ---------------------------------------------------------------------------
# _backup_filename_age_days FILE
#
# Primary age source for retention. Extracts the YYYYMMDD-HHMMSS
# timestamp embedded in the backup filename (e.g.
#   db-20240315-143022.age  → 20240315-143022)
# and converts it to whole days elapsed since that timestamp.
#
# Returns the age in days on stdout. If no recognisable timestamp is found in
# the filename, returns empty string so the caller can skip deletion.
# ---------------------------------------------------------------------------
_backup_filename_age_days() {
    local file="$1"
    local ts_epoch
    ts_epoch=$(_backup_filename_timestamp_epoch "$file")
    if [[ -z "$ts_epoch" ]]; then
        echo ""
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - ts_epoch) / 86400 ))
}

_backup_newest_timestamped_archive() {
    local item newest_item="" epoch newest_epoch=""

    for item in "$@"; do
        epoch=$(_backup_filename_timestamp_epoch "$item")
        [[ -z "$epoch" ]] && continue
        if [[ -z "$newest_epoch" || "$epoch" -gt "$newest_epoch" ]]; then
            newest_epoch="$epoch"
            newest_item="$item"
        fi
    done

    [[ -n "$newest_item" ]] || return 1
    printf '%s\n' "$newest_item"
}

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

# Removes .age backup files older than $retention_days while always preserving
# the newest parseable timestamped primary archive. A second sweep removes
# orphaned .meta and .sha256 sidecar files whose corresponding .age primary no
# longer exists (e.g. after a partial cleanup or manual deletion).
#
# Age is determined by the embedded YYYYMMDD-HHMMSS timestamp in the filename
# when available. Legacy filenames without a parseable timestamp are preserved.
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

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would clean up $backup_type backups older than $retention_days days"
    else
        log_info "Cleaning up $backup_type backups older than $retention_days days"
    fi

    local -a _age_files=()
    local backup_file
    while IFS= read -r -d '' backup_file; do
        _age_files+=("$backup_file")
    done < <(find "$backup_dir" -name "*.age" -type f -print0 2>/dev/null)

    if (( ${#_age_files[@]} == 0 )); then
        log_debug "No $backup_type backup archives found in $backup_dir"
    fi

    local newest_backup=""
    if (( ${#_age_files[@]} > 0 )); then
        if newest_backup=$(_backup_newest_timestamped_archive "${_age_files[@]}"); then
            log_debug "Preserving newest $backup_type backup: $(basename "$newest_backup")"
        else
            log_warn "Retention: no $backup_type backup filename contains a parseable YYYYMMDD-HHMMSS timestamp —" \
                     "skipping primary archive deletion to preserve recovery points."
        fi
    fi

    local deleted_count=0
    if [[ -n "$newest_backup" ]]; then
        for backup_file in "${_age_files[@]}"; do
            if [[ -n "$backup_file" ]]; then
                local age_days
                age_days=$(_backup_filename_age_days "$backup_file")
                if [[ -z "$age_days" ]]; then
                    log_warn "Retention: $(basename "$backup_file") has no filename timestamp — skipping deletion." \
                             " Rename the file to include YYYYMMDD-HHMMSS to enable automatic cleanup."
                    continue
                fi
                if [[ "$backup_file" == "$newest_backup" ]]; then
                    if (( age_days > retention_days )); then
                        log_info "Preserving newest $backup_type backup despite age (${age_days}d > ${retention_days}d): $(basename "$backup_file")"
                    fi
                    continue
                fi
                if (( age_days > retention_days )); then
                    if [[ "${DRY_RUN:-false}" == "true" ]]; then
                        log_info "[DRY RUN] Would remove: $(basename "$backup_file") (and sidecars)"
                    else
                        log_debug "Removing old backup (${age_days}d > ${retention_days}d): $(basename "$backup_file")"
                        rm -f "$backup_file" "$backup_file.sha256" "$backup_file.sha256.hmac" "$backup_file.meta" 2>/dev/null
                    fi
                    (( deleted_count++ )) || true
                fi
            fi
        done
    fi

    local orphan_count=0
    while IFS= read -r sidecar; do
        if [[ -n "$sidecar" ]]; then
            local primary
            case "$sidecar" in
                *.sha256.hmac) primary="${sidecar%.sha256.hmac}" ;;
                *.sha256)      primary="${sidecar%.sha256}" ;;
                *.meta)        primary="${sidecar%.meta}" ;;
                *)             continue ;;
            esac
            if [[ ! -f "$primary" ]]; then
                if [[ "${DRY_RUN:-false}" == "true" ]]; then
                    log_info "[DRY RUN] Would remove orphaned sidecar: $(basename "$sidecar")"
                else
                    log_debug "Removing orphaned sidecar: $(basename "$sidecar")"
                    rm -f "$sidecar" 2>/dev/null
                fi
                (( orphan_count++ )) || true
            fi
        fi
    done < <(find "$backup_dir" \( -name "*.meta" -o -name "*.sha256" -o -name "*.sha256.hmac" \) -type f 2>/dev/null)

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        if (( deleted_count > 0 )); then
            log_info "[DRY RUN] Would clean up $deleted_count old $backup_type backups"
        else
            log_debug "[DRY RUN] No old $backup_type backups to clean up"
        fi
    elif (( deleted_count > 0 )); then
        log_success "Cleaned up $deleted_count old $backup_type backups"
    else
        log_debug "No old $backup_type backups to clean up"
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        if (( orphan_count > 0 )); then
            log_info "[DRY RUN] Would remove $orphan_count orphaned sidecar file(s) from $backup_type backups"
        else
            log_debug "[DRY RUN] No orphaned sidecar files found in $backup_type backups"
        fi
    elif (( orphan_count > 0 )); then
        log_success "Removed $orphan_count orphaned sidecar file(s) from $backup_type backups"
    else
        log_debug "No orphaned sidecar files found in $backup_type backups"
    fi

    return 0
}

# find -exec stat -c%s {} + is GNU-only. On macOS stat -c%s
# errors and awk sums to 0, reporting all backup sizes as 0 MB.
#
# Replaced with a find | while loop using _stat_file_size() (exported by
# lib/crypto.sh) which selects the correct stat format per platform.
#
# get_backup_statistics BACKUP_BASE_DIR [JSON_OUTPUT]
#
# $1 backup_base_dir  — root directory containing db/, full/, emergency/ subdirs.
#                       Defaults to "backups" when omitted.
# $2 json_output      — pass "true" to emit a JSON object instead of log lines.
#                       Mirrors the $2 parameter of list_backups so callers can
#                       use either function interchangeably for --json output
#                       (ux.md #50).
get_backup_statistics() {
    local backup_base_dir="${1:-backups}"
    local json_output="${2:-false}"

    if [[ ! -d "$backup_base_dir" ]]; then
        if [[ "${json_output}" == "true" ]]; then
            printf '{"backup_types":{},"total":{"count":0,"size_bytes":0}}\n'
            return 0
        fi
        log_error "Backup directory not found: $backup_base_dir"
        return 1
    fi

    local backup_types=("db" "full" "emergency")
    local total_backups=0
    local total_size_bytes=0
    local json_rows=""
    local json_sep=""

    if [[ "${json_output}" != "true" ]]; then
        log_info "Backup Statistics:"
        log_info "=================="
    fi

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"
        local count=0
        local size_bytes=0

        if [[ -d "$type_dir" ]]; then
            while IFS= read -r f; do
                local fsz=0
                if declare -f _stat_file_size &>/dev/null; then
                    fsz=$(_stat_file_size "$f" 2>/dev/null || echo 0)
                else
                    fsz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
                fi
                [[ -z "$fsz" || ! "$fsz" =~ ^[0-9]+$ ]] && fsz=0
                size_bytes=$(( size_bytes + fsz ))
                (( count++ )) || true
            done < <(find "$type_dir" -name "*.age" -type f 2>/dev/null)
        fi

        if [[ "${json_output}" == "true" ]]; then
            json_rows+="${json_sep}\"${backup_type}\":{\"count\":${count},\"size_bytes\":${size_bytes}}"
            json_sep=","
        else
            log_info "$(printf '%-10s: %3d backups, %6d MB' "$backup_type" "$count" $(( size_bytes / 1024 / 1024 )))"
        fi

        total_backups=$(( total_backups + count ))
        total_size_bytes=$(( total_size_bytes + size_bytes ))
    done

    if [[ "${json_output}" == "true" ]]; then
        printf '{"backup_types":{%s},"total":{"count":%d,"size_bytes":%d}}\n' \
            "$json_rows" "$total_backups" "$total_size_bytes"
        return 0
    fi

    log_info "=================="
    log_info "$(printf '%-10s: %3d backups, %6d MB' "TOTAL" "$total_backups" $(( total_size_bytes / 1024 / 1024 )))"

    return 0
}

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
    file_size=$(_stat_file_size "$backup_file" 2>/dev/null || echo "0")
    [[ -z "$file_size" || ! "$file_size" =~ ^[0-9]+$ ]] && file_size=0
    hostname=$(hostname -f 2>/dev/null || hostname)

    if ! checksum=$(calculate_sha256 "$backup_file"); then
        log_warn "Could not calculate checksum for metadata"
        checksum="unavailable"
    fi

    local vw_version="unknown"
    if require_docker >/dev/null 2>&1; then
        vw_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | awk 'NF {print; exit}' || true)
    fi
    vw_version="${vw_version//$'\r'/ }"
    vw_version="${vw_version//$'\n'/ }"
    [[ -n "$vw_version" ]] || vw_version="unknown"
    additional_info="$(printf '%s\n' "$additional_info" | awk -F= 'NF == 0 {next} /^#/ {print; next} /^[A-Za-z_][A-Za-z0-9_]*=/ {gsub(/\r/,""); print}')"

    install -m 600 /dev/null "$metadata_file" || {
        log_error "Failed to secure metadata file: $metadata_file"
        return 1
    }

    if ! {
        printf '# VaultWarden Backup Metadata\n'
        printf 'backup_type=%s\n' "$backup_type"
        printf 'timestamp=%s\n' "$timestamp"
        printf 'hostname=%s\n' "${hostname//$'\n'/ }"
        printf 'file_size=%s\n' "$file_size"
        printf 'sha256=%s\n' "$checksum"
        printf 'vaultwarden_version=%s\n' "$vw_version"
        printf 'creator=VaultWarden-OCI-NG\n'
        [[ -n "$additional_info" ]] && printf '%s\n' "$additional_info"
    } > "$metadata_file"; then
        log_error "Failed to create metadata file: $metadata_file"
        return 1
    fi

    log_debug "Metadata created: $(basename "$metadata_file")"
    return 0
}

_repair_sudo_user_rclone_config_permissions() {
    local cfg_path="$1"
    local sudo_user="$2"
    local sudo_user_home="$3"

    [[ $EUID -eq 0 ]] || return 0
    [[ -n "$sudo_user" && "$sudo_user" != "root" ]] || return 0
    [[ -n "$sudo_user_home" ]] || return 0
    [[ "$cfg_path" == "$sudo_user_home/.config/rclone/rclone.conf" ]] || return 0
    [[ -f "$cfg_path" && ! -L "$cfg_path" ]] || return 0

    local sudo_group cfg_dir actual_uid actual_gid actual_mode expected_uid expected_gid
    sudo_group="$(id -gn "$sudo_user" 2>/dev/null || true)"
    [[ -n "$sudo_group" ]] || return 0

    expected_uid="$(id -u "$sudo_user" 2>/dev/null || true)"
    expected_gid="$(id -g "$sudo_user" 2>/dev/null || true)"
    actual_uid="$(stat -c '%u' "$cfg_path" 2>/dev/null || echo "")"
    actual_gid="$(stat -c '%g' "$cfg_path" 2>/dev/null || echo "")"
    actual_mode="$(stat -c '%a' "$cfg_path" 2>/dev/null || echo "")"

    if [[ "$actual_uid" != "$expected_uid" || "$actual_gid" != "$expected_gid" || "$actual_mode" != "600" ]]; then
        log_warn "Correcting rclone config permissions for $cfg_path: expected ${sudo_user}:${sudo_group} 0600"
        chown "$sudo_user:$sudo_group" "$cfg_path" || {
            log_warn "Could not chown rclone config: $cfg_path"
            return 0
        }
        chmod 0600 "$cfg_path" || log_warn "Could not chmod 0600 rclone config: $cfg_path"
    fi

    cfg_dir="$(dirname "$cfg_path")"
    if [[ -d "$cfg_dir" && ! -L "$cfg_dir" ]]; then
        chown "$sudo_user:$sudo_group" "$cfg_dir" 2>/dev/null || true
        chmod 0700 "$cfg_dir" 2>/dev/null || true
    fi
}

_resolve_rclone_config() {
    local cfg_from_env
    cfg_from_env="$(get_config_value "RCLONE_CONFIG" "")"

    if [[ -n "$cfg_from_env" ]]; then
        echo "$cfg_from_env"
        return 0
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local sudo_user_home sudo_user_cfg
        sudo_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
        sudo_user_cfg="$sudo_user_home/.config/rclone/rclone.conf"

        if [[ -n "$sudo_user_home" && -f "$sudo_user_cfg" ]]; then
            _repair_sudo_user_rclone_config_permissions "$sudo_user_cfg" "$SUDO_USER" "$sudo_user_home"
            echo "$sudo_user_cfg"
            return 0
        fi
    fi

    if [[ -f "/etc/rclone/rclone.conf" ]]; then
        echo "/etc/rclone/rclone.conf"
        return 0
    fi

    if [[ -f "/root/.config/rclone/rclone.conf" ]]; then
        echo "/root/.config/rclone/rclone.conf"
        return 0
    fi

    local found_cfg
    for found_cfg in /home/*/.config/rclone/rclone.conf; do
        if [[ -f "$found_cfg" ]]; then
            log_warn "Auto-discovered rclone config via glob: $found_cfg"
            log_warn "On multi-user hosts, set RCLONE_CONFIG=$found_cfg in .env to avoid credential mix-ups."
            echo "$found_cfg"
            return 0
        fi
    done

    return 1
}

validate_rclone_config_path() {
    local cfg_path="$1"

    if [[ -z "$cfg_path" ]]; then
        log_error "RCLONE_CONFIG is empty" >&2
        return 1
    fi

    local canonical
    canonical=$(realpath -e "$cfg_path" 2>/dev/null) || {
        log_error "RCLONE_CONFIG path does not exist or cannot be resolved: $cfg_path" >&2
        return 1
    }

    local root_rclone_config="/root/.config/rclone/rclone.conf"
    local is_root_rclone_config=false
    [[ "$canonical" == "$root_rclone_config" ]] && is_root_rclone_config=true

    local -a sensitive_prefixes=(
        "/etc/passwd"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/ssh"
        "/private/etc/passwd"
        "/private/etc/shadow"
        "/private/etc/sudoers"
        "/private/etc/ssh"
        "/root"
        "/proc"
        "/sys"
    )
    for prefix in "${sensitive_prefixes[@]}"; do
        if [[ "$canonical" == "$prefix" || "$canonical" == "$prefix/"* ]]; then
            if [[ "$is_root_rclone_config" == "true" && "$prefix" == "/root" ]]; then
                continue
            fi
            log_error "RCLONE_CONFIG resolves to sensitive path: $canonical" >&2
            return 1
        fi
    done

    if [[ ! -f "$canonical" ]]; then
        log_error "RCLONE_CONFIG is not a regular file: $canonical" >&2
        return 1
    fi
    local file_perms
    file_perms=$(stat -c "%a" "$canonical" 2>/dev/null || stat -f "%Lp" "$canonical" 2>/dev/null || echo "777")
    if (( (8#$file_perms & 8#002) != 0 )); then
        log_error "RCLONE_CONFIG is world-writable — refusing to use: $canonical" >&2
        return 1
    fi

    if [[ "$is_root_rclone_config" == "true" ]]; then
        local file_uid
        file_uid=$(stat -c "%u" "$canonical" 2>/dev/null || stat -f "%u" "$canonical" 2>/dev/null || echo "")
        if [[ "$file_uid" != "0" ]]; then
            log_error "RCLONE_CONFIG root fallback must be owned by root: $canonical" >&2
            return 1
        fi
    fi

    return 0
}

export -f list_backups check_backup_disk_space
export -f backup_retention_days_for_type cleanup_old_backups get_backup_statistics
# NOTE: keep create_backup_metadata local to this shell; older exported
# versions caused noisy imported-function errors during apt/dpkg subprocesses.
export -f verify_backup_integrity get_backup_size _backup_ctime_age_days
export -f _backup_filename_timestamp_epoch _backup_filename_age_days _backup_newest_timestamped_archive
export -f _format_bytes_human _json_escape _resolve_rclone_config validate_rclone_config_path
export -f _repair_sudo_user_rclone_config_permissions _backup_age_color

log_debug "Backup utilities library loaded successfully - standardized error handling" 2>/dev/null || true
