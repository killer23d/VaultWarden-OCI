#!/usr/bin/env bash
# lib/backup-utils.sh — Backup and restore helpers for VaultWarden-OCI.
#
# Provides:
#   Listing    : list_backups, get_backup_statistics, get_backup_size
#   Validation : validate_backup_integrity, verify_backup_integrity,
#                check_backup_disk_space
#   Retention  : cleanup_old_backups, _backup_filename_age_days,
#                _backup_ctime_age_days
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


_json_escape() {
    local str="$1"
    str=${str//\\/\\\\}
    str=${str//\"/\\\"}
    str=${str//$'\n'/\\n}
    str=${str//$'\r'/}
    printf '%s' "$str"
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
    local mtime_epoch="$1"

    # Resolve color variables: respect a pre-existing TTY check from the
    # calling context (dashboard.sh sets GRN/YLW/RED/NC to "" for non-TTY);
    # otherwise fall back to safe defaults.
    local _c_grn _c_ylw _c_red _c_nc
    if [[ -t 1 ]]; then
        _c_grn="\033[1;32m"
        _c_ylw="\033[1;33m"
        _c_red="\033[1;31m"
        _c_nc="\033[0m"
    else
        _c_grn="" _c_ylw="" _c_red="" _c_nc=""
    fi

    if [[ ! "${mtime_epoch}" =~ ^[0-9]+$ || "${mtime_epoch}" -eq 0 ]]; then
        printf '%s' "${_c_ylw}"
        return
    fi

    local now_epoch age_seconds
    now_epoch=$(date +%s)
    age_seconds=$(( now_epoch - mtime_epoch ))
    (( age_seconds < 0 )) && age_seconds=0

    if (( age_seconds < 86400 )); then
        printf '%s' "${_c_grn}"
    elif (( age_seconds < 604800 )); then
        printf '%s' "${_c_ylw}"
    else
        printf '%s' "${_c_red}"
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

    # Resolve reset sequence once — empty string when not a TTY.
    local _nc
    [[ -t 1 ]] && _nc="\033[0m" || _nc=""

    local found_backups=false

    local grand_total_files=0
    local grand_total_bytes=0
    local grand_total_types=0

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local has_files=false
            local type_count=0
            local type_bytes=0

            while IFS= read -r backup_file; do
                if [[ "$has_files" == false ]]; then
                    printf '%-11s  %-44s  %10s  %s\n' "TYPE" "FILE" "SIZE" "MODIFIED"
                    printf '%-11s  %-44s  %10s  %s\n' "-----------" "--------------------------------------------" "----------" "----------------"
                fi
                has_files=true
                local basename_file size_info age_info
                basename_file=$(basename "$backup_file")
                size_info=$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")

                # Retrieve the mtime epoch for color-coding (ux.md #36) and
                # the human-readable timestamp for display.
                local mtime_epoch stat_raw
                mtime_epoch=$(stat -c '%Y' "$backup_file" 2>/dev/null \
                    || stat -f '%m'       "$backup_file" 2>/dev/null \
                    || echo 0)

                # stat -c '%y' is Linux (GNU coreutils);
                # fall back to BSD stat -f '%Sm' for macOS compatibility.
                # Separate the stat from the cut so that cut receiving
                # empty stdin (from a failing stat on BSD) does not mask
                # the stat failure via a zero-exit from cut.
                stat_raw=$(stat -c '%y' "$backup_file" 2>/dev/null \
                    || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$backup_file" 2>/dev/null \
                    || echo "")
                age_info="${stat_raw:0:16}"
                [[ -z "$age_info" ]] && age_info="unknown"

                # Color-code the MODIFIED column by age (ux.md #36).
                local age_color
                age_color="$(_backup_age_color "${mtime_epoch}")"

                printf "  %-11s  %-44s  %10s  ${age_color}%s${_nc}\n" \
                    "$backup_type" "$basename_file" "$size_info" "$age_info"

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
# validate_backup_integrity BACKUP_FILE [AGE_KEY_FILE]
#
# Validates a .age backup archive end-to-end:
#   1. File exists and is large enough to be plausible.
#   2. SHA-256 checksum matches the paired .sha256 sidecar (if present).
#   3. age decryption succeeds (correct key, intact envelope).
#   4. Inner gzip/tar stream is structurally valid.
#      Step 3 alone cannot catch a backup where age encryption succeeded
#      but the tar payload was truncated or silently corrupted; such a
#      backup passes step 3 and is unusable at restore time. Step 4 pipes
#      the decryption output directly into `tar -tz` (list only, no
#      extraction, no state change) to exercise the full path.
#
# PIPESTATUS usage: the pipe `age -d ... | tar -tz` is run in a subshell
# that captures both exit codes via "${PIPESTATUS[@]}". This is safe under
# set -euo pipefail because the subshell itself is the last command before
# the status capture; the outer script's errexit is not triggered by the
# inner pipe failure.
#
# Decryption test uses direct redirect; avoids pipeline
# PIPESTATUS trap under set -euo pipefail.
# ---------------------------------------------------------------------------
validate_backup_integrity() {
    local backup_file="$1"
    local age_key_file="${2:-${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}}"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        log_error "validate_backup_integrity: 'tar' not found — cannot validate inner archive stream"
        return 1
    fi

    log_info "Validating backup integrity: $(basename "$backup_file")"

    local file_size
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")

    if (( file_size < 1024 )); then
        log_error "Backup file suspiciously small (${file_size} bytes)"
        return 1
    fi

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

    # Decrypt once to a temp file, then use it for both checks.
    # The previous two-pass approach (decrypt to /dev/null + decrypt|tar)
    # creates a TOCTOU window: the file on disk could change between the passes,
    # making pass 2 fail even though pass 1 succeeded. A single decrypt also
    # halves the CPU/IO cost for large backups.
    local _bku_tmpdir _dec_payload
    _bku_tmpdir=$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)
    _dec_payload="$_bku_tmpdir/decrypted_payload"

    local _age_rc=0
    if ! age -d -i "$age_key_file" -o "$_dec_payload" "$backup_file" 2>/dev/null; then
        _age_rc=$?
        rm -rf "$_bku_tmpdir"
        log_error "Backup file decryption failed (wrong key or corrupt age envelope, exit ${_age_rc})"
        return 1
    fi

    log_success "Decryption succeeded (age envelope intact)"

    if ! tar -tz -f "$_dec_payload" >/dev/null 2>&1; then
        rm -rf "$_bku_tmpdir"
        log_error "Backup tar-stream check failed: inner tar payload is corrupt or truncated"
        log_error "  age decryption: OK  |  tar -tz: FAILED"
        log_error "  The .age envelope is valid but the archive will not restore correctly."
        return 1
    fi

    rm -rf "$_bku_tmpdir"

    log_success "Backup integrity validation passed (age envelope OK, tar stream OK)"
    return 0
}

# ---------------------------------------------------------------------------
# verify_backup_integrity DB_PATH [AGE_KEY_FILE]
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
    local age_key_file="${2:-${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}}"

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

    # Use SQLite Online Backup API via the sqlite3 .backup dot-command.
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

    if [[ ! -d "$target_dir" ]]; then
        # Warn when directory does not yet exist — this may indicate a
        # misconfigured BACKUP_DIR rather than a first-run situation.
        log_warn "check_backup_disk_space: target directory does not exist yet — disk space check skipped: $target_dir"
        return 0
    fi

    local available_space_kb
    # Use awk 'END' (last line) instead of 'NR==2' to handle long
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
# Primary age source for retention. Extracts the YYYYMMDD-HHMMSS
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

    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - ts_epoch) / 86400 ))
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

# Removes .age backup files older than $retention_days. A second sweep removes
# orphaned .meta and .sha256 sidecar files whose corresponding .age primary no
# longer exists (e.g. after a partial cleanup or manual deletion).
#
# Age is determined by the embedded YYYYMMDD-HHMMSS timestamp in the filename
# when available; falls back to the file's ctime for legacy filenames.
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

    # Before deleting any backups, count total .age files in the
    # directory. If there is only one (or zero), abort deletion — otherwise the
    # last good backup could be removed, leaving no recovery point.
    local _total_age_files
    _total_age_files=$(find "$backup_dir" -name "*.age" -type f 2>/dev/null | wc -l)
    if (( _total_age_files <= 1 )); then
        log_warn "cleanup_old_backups: only ${_total_age_files} backup file(s) found in $backup_dir —" \
                 "skipping deletion to preserve the last available backup."
        return 0
    fi

    local deleted_count=0

    while IFS= read -r backup_file; do
        if [[ -n "$backup_file" ]]; then
            local age_days
            age_days=$(_backup_filename_age_days "$backup_file")
            if [[ -z "$age_days" ]]; then
                # No timestamp in filename — skip deletion to avoid relying on
                # unreliable ctime semantics (ctime resets on chmod/chown).
                # Operator must rename the file to include YYYYMMDD-HHMMSS.
                log_warn "Retention: $(basename "$backup_file") has no filename timestamp — skipping deletion." \
                         " Rename the file to include YYYYMMDD-HHMMSS to enable automatic cleanup."
                continue
            fi
            if (( age_days > retention_days )); then
                log_debug "Removing old backup (${age_days}d > ${retention_days}d): $(basename "$backup_file")"
                rm -f "$backup_file" "$backup_file.sha256" "$backup_file.sha256.hmac" "$backup_file.meta" 2>/dev/null
                (( deleted_count++ )) || true
            fi
        fi
    done < <(find "$backup_dir" -name "*.age" -type f 2>/dev/null)

    local orphan_count=0
    while IFS= read -r sidecar; do
        if [[ -n "$sidecar" ]]; then
            local primary="${sidecar%.meta}"
            primary="${primary%.sha256}"
            if [[ ! -f "$primary" ]]; then
                log_debug "Removing orphaned sidecar: $(basename "$sidecar")"
                rm -f "$sidecar" 2>/dev/null
                (( orphan_count++ )) || true
            fi
        fi
    done < <(find "$backup_dir" \( -name "*.meta" -o -name "*.sha256" -o -name "*.sha256.hmac" \) -type f 2>/dev/null)

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
            printf '{"backups":[]}\n'
            return 0
        fi
        log_error "Backup directory not found: $backup_base_dir"
        return 1
    fi

    local backup_types=("db" "full" "emergency")
    local total_backups=0
    local total_size_bytes=0

    log_info "Backup Statistics:"
    log_info "=================="

    for backup_type in "${backup_types[@]}"; do
        local type_dir="$backup_base_dir/$backup_type"

        if [[ -d "$type_dir" ]]; then
            local count=0
            local size_bytes=0

            while IFS= read -r f; do
                local fsz=0
                # Guard: _stat_file_size is exported by lib/crypto.sh;
                # fall back to inline stat when crypto.sh was not sourced.
                if declare -f _stat_file_size &>/dev/null; then
                    fsz=$(_stat_file_size "$f" 2>/dev/null || echo 0)
                else
                    fsz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
                fi
                [[ -z "$fsz" || ! "$fsz" =~ ^[0-9]+$ ]] && fsz=0
                size_bytes=$(( size_bytes + fsz ))
                (( count++ )) || true
            done < <(find "$type_dir" -name "*.age" -type f 2>/dev/null)

            local size_mb=$(( size_bytes / 1024 / 1024 ))

            log_info "$(printf '%-10s: %3d backups, %6d MB' "$backup_type" "$count" "$size_mb")"

            total_backups=$(( total_backups + count ))
            total_size_bytes=$(( total_size_bytes + size_bytes ))
        else
            log_info "$(printf '%-10s: %3d backups, %6d MB' "$backup_type" 0 0)"
        fi
    done

    local total_size_mb=$(( total_size_bytes / 1024 / 1024 ))
    log_info "=================="
    log_info "$(printf '%-10s: %3d backups, %6d MB' "TOTAL" "$total_backups" "$total_size_mb")"

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
        vw_version=$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo "unknown")
    fi

    # Create the metadata file with secure permissions before writing so
    # that the file is never briefly world-readable at umask 022 (mode 644).
    install -m 600 /dev/null "$metadata_file" || {
        log_error "Failed to secure metadata file: $metadata_file"
        return 1
    }

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

_resolve_rclone_config() {
    local cfg_from_env
    cfg_from_env="$(get_config_value "RCLONE_CONFIG" "")"

    if [[ -n "$cfg_from_env" ]]; then
        echo "$cfg_from_env"
        return 0
    fi

    if [[ -f "/etc/rclone/rclone.conf" ]]; then
        echo "/etc/rclone/rclone.conf"
        return 0
    fi

    if [[ -f "/root/.config/rclone/rclone.conf" ]]; then
        echo "/root/.config/rclone/rclone.conf"
        return 0
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_user_home
        sudo_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
        if [[ -n "$sudo_user_home" && -f "$sudo_user_home/.config/rclone/rclone.conf" ]]; then
            echo "$sudo_user_home/.config/rclone/rclone.conf"
            return 0
        fi
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

    local -a sensitive_prefixes=(
        "/etc/passwd"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/ssh"
        "/root"
        "/proc"
        "/sys"
    )
    for prefix in "${sensitive_prefixes[@]}"; do
        if [[ "$canonical" == "$prefix" || "$canonical" == "$prefix/"* ]]; then
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

    return 0
}

export -f list_backups validate_backup_integrity check_backup_disk_space
export -f cleanup_old_backups get_backup_statistics
# NOTE: create_backup_metadata uses a heredoc; exporting this function can
# produce malformed imported function definitions in child bash processes.
# Keep it local to the current shell to avoid "error importing function
# definition for create_backup_metadata" during apt/dpkg subprocess execution.
export -f verify_backup_integrity get_backup_size _backup_ctime_age_days
export -f _backup_filename_age_days _format_bytes_human _json_escape _resolve_rclone_config validate_rclone_config_path
export -f _backup_age_color

log_debug "Backup utilities library loaded successfully - standardized error handling" 2>/dev/null || true
