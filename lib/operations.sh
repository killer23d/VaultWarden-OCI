#!/usr/bin/env bash
# lib/operations.sh — Shared VaultWarden operator-operation guard.
# shellcheck disable=SC2317

[[ -n "${VW_OPERATIONS_LIB_LOADED:-}" ]] && return 0
readonly VW_OPERATIONS_LIB_LOADED=1

: "${VW_OPERATIONS_LOCK:=/run/lock/vaultwarden-operations.lock}"
: "${VW_OPERATIONS_STATE_DIR:=/run/vaultwarden-oci/operations}"
: "${VW_OPERATIONS_WAIT_INTERVAL:=10}"
: "${VW_OPERATIONS_WAIT_LIMIT:=120}"
: "${VW_PACKAGE_WAIT_INTERVAL:=10}"
: "${VW_PACKAGE_WAIT_ATTEMPTS:=12}"
: "${VW_OPERATIONS_STOP_GRACE:=10}"
: "${VW_OPERATIONS_FORCE_GRACE:=5}"
: "${VW_OPERATIONS_PROMPT_TIMEOUT:=300}"
: "${VW_OPERATIONS_HOLDER_READY_TIMEOUT:=5}"

OPERATION_ID=""
OPERATION_LABEL=""
OPERATION_STATE_FILE=""
OPERATION_SPECIFIC_LOCK=""
OPERATION_TOKEN=""
OPERATION_STARTED=""
OPERATION_STARTED_EPOCH=""
OPERATION_PHASE=""
OPERATION_PHASE_NAME=""
OPERATION_OWNER_PID=""
OPERATION_OWNER_PID_START=""
OPERATION_HOLDER_PID=""
OPERATION_HOLDER_PID_START=""
OPERATION_HOLDER_READ_FD=""
OPERATION_HOLDER_CONTROL_FD=""
OPERATION_HOLDER_GLOBAL_LOCK=""
OPERATION_HOLDER_SPECIFIC_LOCK=""
OPERATION_OWNS_GLOBAL=false
OPERATION_OWNS_STATE=false
OPERATION_RELEASED=false

_operation_log() {
    local level="$1"; shift || true
    if declare -f "log_${level}" >/dev/null 2>&1; then
        "log_${level}" "$*"
    else
        printf '[%s] %s\n' "${level^^}" "$*" >&2
    fi
}

_operation_now() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

_operation_epoch() {
    date '+%s'
}

_operation_elapsed() {
    local start="${1:-0}" elapsed
    [[ "$start" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    elapsed=$(( $(_operation_epoch) - start ))
    (( elapsed < 0 )) && elapsed=0
    printf '%dm %02ds' $(( elapsed / 60 )) $(( elapsed % 60 ))
}

_operation_safe_value() {
    local value="${1:-}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\t'/ }"
    printf '%s' "$value"
}

_operation_parse_proc_stat() {
    local line="$1" rest state ppid start
    local -a fields=()
    [[ "$line" == *") "* ]] || return 1
    rest="${line##*) }"
    [[ "$rest" != "$line" ]]
    read -r -a fields <<< "$rest"
    (( ${#fields[@]} >= 20 )) || return 1
    state="${fields[0]}"
    ppid="${fields[1]}"
    start="${fields[19]}"
    [[ "$state" =~ ^[A-Z]$ && "$state" != "Z" ]] || return 1
    [[ "$ppid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\n' "$state" "$ppid" "$start"
}

_operation_proc_identity() {
    local pid="$1" line
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]] || return 1
    IFS= read -r line < "/proc/${pid}/stat" || return 1
    _operation_parse_proc_stat "$line"
}

_operation_pid_start() {
    local pid="$1" identity state ppid start
    identity="$(_operation_proc_identity "$pid" 2>/dev/null)" || return 1
    IFS=$'\t' read -r state ppid start <<< "$identity"
    [[ -n "$state" && "$ppid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$start"
}

_operation_prepare_state_dir() {
    if [[ $EUID -eq 0 ]]; then
        install -d -m 0700 -o root -g root "$VW_OPERATIONS_STATE_DIR" 2>/dev/null || return 1
    else
        mkdir -p "$VW_OPERATIONS_STATE_DIR" 2>/dev/null || return 1
        chmod 0700 "$VW_OPERATIONS_STATE_DIR" 2>/dev/null || true
    fi
}

_operation_prepare_lock_file() {
    local lock_path="$1" lock_dir current_mode current_uid current_gid desired_gid old_umask

    lock_dir="$(dirname "$lock_path")"
    desired_gid="$(id -g 2>/dev/null)" || {
        _operation_log error "Cannot determine the effective group for operation lock preparation."
        return 1
    }

    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || {
            _operation_log error "Cannot create operation lock directory: ${lock_dir}"
            _operation_log error "Fix: sudo mkdir -p '${lock_dir}' && sudo chmod 1777 '${lock_dir}'"
            return 1
        }
    fi

    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || {
            _operation_log error "Operation lock path is not a regular file: ${lock_path}"
            _operation_log error "Inspect it before retrying: sudo ls -la '${lock_path}'"
            return 1
        }
    else
        old_umask="$(umask)"
        umask 0007
        if (set -o noclobber; : >"$lock_path") 2>/dev/null; then
            :
        elif [[ ! -f "$lock_path" || -L "$lock_path" ]]; then
            umask "$old_umask"
            _operation_log error "Cannot create operation lock file: ${lock_path}"
            _operation_log error "Check: sudo ls -la '${lock_dir}'"
            _operation_log error "Fix: sudo touch '${lock_path}' && sudo chmod 0660 '${lock_path}'"
            return 1
        fi
        umask "$old_umask"
    fi

    current_mode="$(stat -c '%a' "$lock_path" 2>/dev/null \
        || stat -f '%Lp' "$lock_path" 2>/dev/null || true)"
    if [[ "$current_mode" != 660 ]]; then
        if ! chmod 0660 "$lock_path" 2>/dev/null; then
            _operation_log error "Cannot set operation lock mode 0660: ${lock_path}"
            _operation_log error "Fix: sudo chmod 0660 '${lock_path}'"
            return 1
        fi
    fi

    current_uid="$(stat -c '%u' "$lock_path" 2>/dev/null \
        || stat -f '%u' "$lock_path" 2>/dev/null || true)"
    current_gid="$(stat -c '%g' "$lock_path" 2>/dev/null \
        || stat -f '%g' "$lock_path" 2>/dev/null || true)"
    if [[ "$current_uid" != "$EUID" || "$current_gid" != "$desired_gid" ]]; then
        if ! chown "${EUID}:${desired_gid}" "$lock_path" 2>/dev/null; then
            _operation_log error "Cannot set operation lock ownership to ${EUID}:${desired_gid}: ${lock_path}"
            _operation_log error "Fix: sudo chown ${EUID}:${desired_gid} '${lock_path}'"
            return 1
        fi
    fi

    current_mode="$(stat -c '%a' "$lock_path" 2>/dev/null \
        || stat -f '%Lp' "$lock_path" 2>/dev/null || true)"
    current_uid="$(stat -c '%u' "$lock_path" 2>/dev/null \
        || stat -f '%u' "$lock_path" 2>/dev/null || true)"
    current_gid="$(stat -c '%g' "$lock_path" 2>/dev/null \
        || stat -f '%g' "$lock_path" 2>/dev/null || true)"
    if [[ ! -f "$lock_path" || -L "$lock_path" || "$current_mode" != 660 \
        || "$current_uid" != "$EUID" || "$current_gid" != "$desired_gid" ]]; then
        _operation_log error "Operation lock metadata could not be established safely: ${lock_path}"
        return 1
    fi
}

_operation_state_get() {
    local file="$1" key="$2" line current value
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        current="${line%%=*}"
        value="${line#*=}"
        [[ "$current" == "$key" ]] || continue
        printf '%s\n' "$value"
        return 0
    done < "$file"
    return 1
}

_operation_state_file_is_trusted() {
    local file="$1" mode owner_uid
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mode="$(stat -c '%a' "$file" 2>/dev/null \
        || stat -f '%Lp' "$file" 2>/dev/null || true)"
    owner_uid="$(stat -c '%u' "$file" 2>/dev/null \
        || stat -f '%u' "$file" 2>/dev/null || true)"
    [[ "$mode" == "600" && "$owner_uid" == "$EUID" ]]
}

_operation_write_state() {
    local state="${1:-running}" result="${2:-}" completed="${3:-}"
    local tmp
    [[ -n "$OPERATION_STATE_FILE" ]] || return 0
    _operation_prepare_state_dir || return 1
    tmp="$(mktemp "${OPERATION_STATE_FILE}.tmp.XXXXXXXX")" || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    {
        printf 'owner=VaultWarden-OCI\n'
        printf 'operation=%s\n' "$(_operation_safe_value "$OPERATION_ID")"
        printf 'label=%s\n' "$(_operation_safe_value "$OPERATION_LABEL")"
        printf 'state=%s\n' "$(_operation_safe_value "$state")"
        printf 'pid=%s\n' "$(_operation_safe_value "$OPERATION_OWNER_PID")"
        printf 'pid_start=%s\n' "$(_operation_safe_value "$OPERATION_OWNER_PID_START")"
        printf 'holder_pid=%s\n' "$(_operation_safe_value "$OPERATION_HOLDER_PID")"
        printf 'holder_pid_start=%s\n' "$(_operation_safe_value "$OPERATION_HOLDER_PID_START")"
        printf 'script=%s\n' "$(_operation_safe_value "${0##*/}")"
        printf 'started=%s\n' "$(_operation_safe_value "$OPERATION_STARTED")"
        printf 'started_epoch=%s\n' "$(_operation_safe_value "$OPERATION_STARTED_EPOCH")"
        printf 'phase=%s\n' "$(_operation_safe_value "$OPERATION_PHASE")"
        printf 'phase_name=%s\n' "$(_operation_safe_value "$OPERATION_PHASE_NAME")"
        printf 'lock_path=%s\n' "$(_operation_safe_value "$VW_OPERATIONS_LOCK")"
        printf 'global_lock_owned=%s\n' "$(_operation_safe_value "$OPERATION_OWNS_GLOBAL")"
        printf 'specific_lock=%s\n' "$(_operation_safe_value "$OPERATION_SPECIFIC_LOCK")"
        printf 'token=%s\n' "$(_operation_safe_value "$OPERATION_TOKEN")"
        [[ -n "$completed" ]] && printf 'completed=%s\n' "$(_operation_safe_value "$completed")"
        [[ -n "$result" ]] && printf 'result=%s\n' "$(_operation_safe_value "$result")"
    } > "$tmp"
    mv -f "$tmp" "$OPERATION_STATE_FILE"
}

_operation_update_phase_fields() {
    local tmp line key wrote_phase=false wrote_phase_name=false
    [[ -r "$OPERATION_STATE_FILE" ]] || return 0
    tmp="$(mktemp "${OPERATION_STATE_FILE}.tmp.XXXXXXXX")" || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        case "$key" in
            phase)
                printf 'phase=%s\n' "$(_operation_safe_value "$OPERATION_PHASE")" >> "$tmp"
                wrote_phase=true
                ;;
            phase_name)
                printf 'phase_name=%s\n' "$(_operation_safe_value "$OPERATION_PHASE_NAME")" >> "$tmp"
                wrote_phase_name=true
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$OPERATION_STATE_FILE"
    [[ "$wrote_phase" == "true" ]] || printf 'phase=%s\n' "$(_operation_safe_value "$OPERATION_PHASE")" >> "$tmp"
    [[ "$wrote_phase_name" == "true" ]] || printf 'phase_name=%s\n' "$(_operation_safe_value "$OPERATION_PHASE_NAME")" >> "$tmp"
    mv -f "$tmp" "$OPERATION_STATE_FILE"
}

_operation_lock_is_held() {
    local lock_path="$1" fd
    [[ -e "$lock_path" ]] || return 1
    { exec {fd}>"$lock_path"; } 2>/dev/null || return 0
    if flock -n "$fd" 2>/dev/null; then
        flock -u "$fd" 2>/dev/null || true
        { eval "exec ${fd}>&-"; } 2>/dev/null || true
        return 1
    fi
    { eval "exec ${fd}>&-"; } 2>/dev/null || true
    return 0
}

_operation_path_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    stat -Lc '%d:%i' "$path" 2>/dev/null \
        || stat -f '%d:%i' "$path" 2>/dev/null
}

_operation_lock_path_is_valid() {
    local path="$1" mode owner_uid owner_gid expected_gid
    [[ -f "$path" && ! -L "$path" ]] || return 1
    expected_gid="$(id -g 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null \
        || stat -f '%Lp' "$path" 2>/dev/null || true)"
    owner_uid="$(stat -c '%u' "$path" 2>/dev/null \
        || stat -f '%u' "$path" 2>/dev/null || true)"
    owner_gid="$(stat -c '%g' "$path" 2>/dev/null \
        || stat -f '%g' "$path" 2>/dev/null || true)"
    [[ "$mode" == "660" && "$owner_uid" == "$EUID" && "$owner_gid" == "$expected_gid" ]]
}

_operation_open_file_identity() {
    local pid="$1" fd="$2"
    if [[ -e "/proc/${pid}/fd/${fd}" ]]; then
        stat -Lc '%d:%i' "/proc/${pid}/fd/${fd}" 2>/dev/null
    else
        stat -f '%d:%i' "/dev/fd/${fd}" 2>/dev/null
    fi
}

_operation_open_file_matches_path() {
    local path="$1" fd="$2" pid="${3:-${BASHPID}}"
    local path_identity fd_identity
    _operation_lock_path_is_valid "$path" || return 1
    path_identity="$(_operation_path_identity "$path")" || return 1
    fd_identity="$(_operation_open_file_identity "$pid" "$fd")" || return 1
    if [[ -e "/proc/${pid}/fd/${fd}" ]]; then
        [[ "$path_identity" == "$fd_identity" ]]
    else
        [[ "${path_identity#*:}" == "${fd_identity#*:}" ]]
    fi
}

_operation_lock_holder() {
    local global_path="$1" specific_path="$2"
    local global_fd="" specific_fd="" flock_rc

    trap 'exit 1' HUP INT TERM

    if [[ -n "$global_path" ]]; then
        if ! exec {global_fd}>"$global_path"; then
            printf 'global-open-failure\n'
            return 1
        fi
        if ! _operation_open_file_matches_path "$global_path" "$global_fd"; then
            printf 'global-validation-failure\n'
            return 1
        fi
        if flock -n -E 75 "$global_fd" 2>/dev/null; then
            flock_rc=0
        else
            flock_rc=$?
        fi
        case "$flock_rc" in
            0) ;;
            75)
                printf 'global-contention\n'
                return 0
                ;;
            *)
                printf 'global-flock-failure:%s\n' "$flock_rc"
                return 1
                ;;
        esac
        if ! _operation_open_file_matches_path "$global_path" "$global_fd"; then
            printf 'global-validation-failure\n'
            return 1
        fi
    fi

    if [[ -n "$specific_path" ]]; then
        if ! exec {specific_fd}>"$specific_path"; then
            printf 'specific-open-failure\n'
            return 1
        fi
        if ! _operation_open_file_matches_path "$specific_path" "$specific_fd"; then
            printf 'specific-validation-failure\n'
            return 1
        fi
        if flock -n -E 75 "$specific_fd" 2>/dev/null; then
            flock_rc=0
        else
            flock_rc=$?
        fi
        case "$flock_rc" in
            0) ;;
            75)
                printf 'specific-contention\n'
                return 0
                ;;
            *)
                printf 'specific-flock-failure:%s\n' "$flock_rc"
                return 1
                ;;
        esac
        if ! _operation_open_file_matches_path "$specific_path" "$specific_fd"; then
            printf 'specific-validation-failure\n'
            return 1
        fi
    fi

    printf 'ready\n'
    IFS= read -r _ || true
}

_operation_close_holder_read_fd() {
    if [[ "$OPERATION_HOLDER_READ_FD" =~ ^[0-9]+$ ]]; then
        { exec {OPERATION_HOLDER_READ_FD}<&-; } 2>/dev/null || true
    fi
    OPERATION_HOLDER_READ_FD=""
}

_operation_close_holder_control_fd() {
    if [[ "$OPERATION_HOLDER_CONTROL_FD" =~ ^[0-9]+$ ]]; then
        { exec {OPERATION_HOLDER_CONTROL_FD}>&-; } 2>/dev/null || true
    fi
    OPERATION_HOLDER_CONTROL_FD=""
}

_operation_clear_holder() {
    OPERATION_HOLDER_PID=""
    OPERATION_HOLDER_PID_START=""
    OPERATION_HOLDER_READ_FD=""
    OPERATION_HOLDER_CONTROL_FD=""
    OPERATION_HOLDER_GLOBAL_LOCK=""
    OPERATION_HOLDER_SPECIFIC_LOCK=""
}

_operation_discard_holder() {
    local pid="$OPERATION_HOLDER_PID"
    _operation_close_holder_read_fd
    _operation_close_holder_control_fd
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    _operation_clear_holder
}

_operation_pid_has_open_lock() {
    local pid="$1" lock_path="$2" expected fd actual
    [[ "$pid" =~ ^[0-9]+$ && -d "/proc/${pid}/fd" ]] || return 1
    expected="$(_operation_path_identity "$lock_path")" || return 1
    for fd in "/proc/${pid}/fd/"*; do
        [[ -e "$fd" ]] || continue
        actual="$(stat -Lc '%d:%i' "$fd" 2>/dev/null || true)"
        [[ "$actual" == "$expected" ]] && return 0
    done
    return 1
}

_operation_holder_identity_is_live() {
    local pid="$1" expected_start="$2" global_path="${3:-}" specific_path="${4:-}"
    local current_start
    [[ "$pid" =~ ^[0-9]+$ && "$expected_start" =~ ^[0-9]+$ ]] || return 1
    current_start="$(_operation_pid_start "$pid" 2>/dev/null || true)"
    [[ "$current_start" == "$expected_start" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -z "$global_path" ]] || _operation_pid_has_open_lock "$pid" "$global_path" || return 1
    [[ -z "$specific_path" ]] || _operation_pid_has_open_lock "$pid" "$specific_path" || return 1
}

_operation_local_holder_is_live() {
    [[ -n "$OPERATION_HOLDER_PID" ]] || return 0
    if [[ ! -d "/proc/${OPERATION_HOLDER_PID}/fd" ]]; then
        kill -0 "$OPERATION_HOLDER_PID" 2>/dev/null
        return
    fi
    _operation_holder_identity_is_live \
        "$OPERATION_HOLDER_PID" \
        "$OPERATION_HOLDER_PID_START" \
        "$OPERATION_HOLDER_GLOBAL_LOCK" \
        "$OPERATION_HOLDER_SPECIFIC_LOCK"
}

_operation_start_holder() {
    local global_path="$1" specific_path="$2" response="" read_rc=0
    local holder_pid holder_start

    [[ -n "$global_path$specific_path" ]] || return 0
    [[ -z "$OPERATION_HOLDER_PID" ]] || {
        _operation_log error "Operation lock holder is already active in this shell."
        return 1
    }

    coproc VW_OPERATION_LOCK_HOLDER {
        _operation_lock_holder "$global_path" "$specific_path"
    }
    holder_pid="${VW_OPERATION_LOCK_HOLDER_PID:-}"
    OPERATION_HOLDER_READ_FD="${VW_OPERATION_LOCK_HOLDER[0]:-}"
    OPERATION_HOLDER_CONTROL_FD="${VW_OPERATION_LOCK_HOLDER[1]:-}"
    OPERATION_HOLDER_PID="$holder_pid"
    OPERATION_HOLDER_GLOBAL_LOCK="$global_path"
    OPERATION_HOLDER_SPECIFIC_LOCK="$specific_path"

    holder_start="$(_operation_pid_start "$holder_pid" 2>/dev/null || true)"
    if [[ "$(uname -s)" == "Linux" && ! "$holder_start" =~ ^[0-9]+$ ]]; then
        _operation_log error "Cannot verify the operation lock holder process identity."
        _operation_discard_holder
        return 1
    fi
    OPERATION_HOLDER_PID_START="$holder_start"

    if IFS= read -r -t "$VW_OPERATIONS_HOLDER_READY_TIMEOUT" response \
        <&"$OPERATION_HOLDER_READ_FD"; then
        read_rc=0
    else
        read_rc=$?
    fi
    _operation_close_holder_read_fd
    if (( read_rc != 0 )); then
        _operation_log error "Operation lock holder did not report readiness within ${VW_OPERATIONS_HOLDER_READY_TIMEOUT}s."
        _operation_discard_holder
        return 1
    fi

    case "$response" in
        ready)
            if [[ "$(uname -s)" == "Linux" ]] && ! _operation_local_holder_is_live; then
                _operation_log error "Operation lock holder lost its verified lock files during startup."
                _operation_discard_holder
                return 1
            fi
            return 0
            ;;
        global-contention)
            _operation_discard_holder
            return 75
            ;;
        specific-contention)
            _operation_discard_holder
            return 76
            ;;
        global-open-failure)
            _operation_log error "Operation lock holder could not open the global lock: ${global_path}"
            ;;
        specific-open-failure)
            _operation_log error "Operation lock holder could not open the specific lock: ${specific_path}"
            ;;
        global-validation-failure)
            _operation_log error "Global operation lock identity changed during holder startup: ${global_path}"
            ;;
        specific-validation-failure)
            _operation_log error "Specific operation lock identity changed during holder startup: ${specific_path}"
            ;;
        global-flock-failure:*)
            _operation_log error "Global operation flock failed unexpectedly with status ${response##*:}."
            ;;
        specific-flock-failure:*)
            _operation_log error "Specific operation flock failed unexpectedly with status ${response##*:}."
            ;;
        *)
            _operation_log error "Operation lock holder returned a malformed readiness response."
            ;;
    esac
    _operation_discard_holder
    return 1
}

_operation_release_holder() {
    local pid="$OPERATION_HOLDER_PID" wait_rc=0
    [[ -n "$pid" ]] || return 0
    _operation_close_holder_read_fd
    _operation_close_holder_control_fd
    if wait "$pid" 2>/dev/null; then
        wait_rc=0
    else
        wait_rc=$?
    fi
    _operation_clear_holder
    (( wait_rc == 0 ))
}

_operation_state_global_owned() {
    local file="$1" owned
    owned="$(_operation_state_get "$file" global_lock_owned 2>/dev/null || true)"
    [[ "$owned" == "true" ]]
}

_operation_find_state_for_lock() {
    local lock_path="$1" file state stored_lock
    [[ -d "$VW_OPERATIONS_STATE_DIR" ]] || return 1
    for file in "$VW_OPERATIONS_STATE_DIR"/*.state; do
        _operation_state_file_is_trusted "$file" || continue
        state="$(_operation_state_get "$file" state 2>/dev/null || true)"
        stored_lock="$(_operation_state_get "$file" lock_path 2>/dev/null || true)"
        [[ "$state" == "running" && "$stored_lock" == "$lock_path" ]] || continue
        _operation_state_global_owned "$file" || continue
        _operation_verify_owner "$file" || continue
        printf '%s\n' "$file"
        return 0
    done
    return 1
}

_operation_verify_holder() {
    local file="$1" holder_pid holder_start global_owned global_path specific_path
    holder_pid="$(_operation_state_get "$file" holder_pid 2>/dev/null || true)"
    holder_start="$(_operation_state_get "$file" holder_pid_start 2>/dev/null || true)"
    global_owned="$(_operation_state_get "$file" global_lock_owned 2>/dev/null || true)"
    global_path="$(_operation_state_get "$file" lock_path 2>/dev/null || true)"
    specific_path="$(_operation_state_get "$file" specific_lock 2>/dev/null || true)"
    [[ "$global_owned" == "true" ]] || global_path=""
    [[ -n "$global_path$specific_path" ]] || return 1
    _operation_holder_identity_is_live \
        "$holder_pid" \
        "$holder_start" \
        "$global_path" \
        "$specific_path"
}

_operation_verify_owner() {
    local file="$1" pid saved_start current_start owner token state
    _operation_state_file_is_trusted "$file" || return 1
    owner="$(_operation_state_get "$file" owner 2>/dev/null || true)"
    token="$(_operation_state_get "$file" token 2>/dev/null || true)"
    state="$(_operation_state_get "$file" state 2>/dev/null || true)"
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    saved_start="$(_operation_state_get "$file" pid_start 2>/dev/null || true)"
    [[ "$owner" == "VaultWarden-OCI" && "$state" == "running" \
        && -n "$token" && "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    current_start="$(_operation_pid_start "$pid" 2>/dev/null || true)"
    [[ -n "$saved_start" && "$current_start" == "$saved_start" ]] || return 1
    _operation_verify_holder "$file"
}

_operation_pid_is_self_or_descendant() {
    local current="$1" ancestor="$2" identity state parent start depth=0
    [[ "$current" =~ ^[0-9]+$ && "$ancestor" =~ ^[0-9]+$ ]] || return 1
    [[ "$current" == "$ancestor" ]] && return 0
    while (( current > 1 && depth < 256 )); do
        identity="$(_operation_proc_identity "$current" 2>/dev/null)" || return 1
        IFS=$'\t' read -r state parent start <<< "$identity"
        [[ -n "$state" && "$parent" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 1
        current="$parent"
        [[ "$current" == "$ancestor" ]] && return 0
        depth=$(( depth + 1 ))
    done
    return 1
}

_operation_related_rows() {
    local root_pid="$1"
    [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0
    ps -eo pid=,ppid=,etime=,stat=,comm= 2>/dev/null | awk -v root="$root_pid" '
        {
            pid=$1; ppid=$2; line=$0; parent[pid]=ppid; row[pid]=line
        }
        END {
            want[root]=1
            changed=1
            while (changed) {
                changed=0
                for (pid in parent) {
                    if (want[parent[pid]] && !want[pid]) {
                        want[pid]=1
                        changed=1
                    }
                }
            }
            for (pid in want) {
                if (row[pid] != "") print row[pid]
            }
        }' | sort -n
}

_operation_descendant_pids() {
    local root_pid="$1"
    [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0
    ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root_pid" '
        {
            pid=$1; ppid=$2; parent[pid]=ppid
        }
        END {
            depth[root]=0
            changed=1
            while (changed) {
                changed=0
                for (pid in parent) {
                    if (pid == root) continue
                    if ((parent[pid] == root || depth[parent[pid]] != "") && depth[pid] == "") {
                        depth[pid]=depth[parent[pid]] + 1
                        changed=1
                    }
                }
            }
            for (pid in depth) {
                if (pid != root) print depth[pid], pid
            }
        }' | sort -rn | awk '{print $2}'
}

_operation_pid_identity() {
    local pid="$1" start
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    (( pid > 1 )) || return 1
    (( pid == $$ )) && return 1
    [[ -d "/proc/${pid}" ]] || return 1
    start="$(_operation_pid_start "$pid" 2>/dev/null || true)"
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s\n' "$pid" "$start"
}

_operation_capture_descendant_identities() {
    local root_pid="$1" pid identity
    while IFS= read -r pid; do
        identity="$(_operation_pid_identity "$pid" 2>/dev/null || true)"
        [[ -n "$identity" ]] || continue
        printf '%s\n' "$identity"
    done < <(_operation_descendant_pids "$root_pid")
}

_operation_identity_is_live() {
    local identity="$1" pid expected_start current_start
    pid="${identity%%:*}"
    expected_start="${identity#*:}"
    [[ "$pid" != "$identity" && "$pid" =~ ^[0-9]+$ && "$expected_start" =~ ^[0-9]+$ ]] || return 1
    (( pid > 1 )) || return 1
    (( pid == $$ )) && return 1
    [[ -d "/proc/${pid}" ]] || return 1
    current_start="$(_operation_pid_start "$pid" 2>/dev/null || true)"
    [[ -n "$current_start" && "$current_start" == "$expected_start" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

_operation_live_identity_pids() {
    local identity pid
    for identity in "$@"; do
        _operation_identity_is_live "$identity" || continue
        pid="${identity%%:*}"
        printf '%s\n' "$pid"
    done
}

_operation_signal_identities() {
    local signal="$1" identity pid
    shift || true
    for identity in "$@"; do
        _operation_identity_is_live "$identity" || continue
        pid="${identity%%:*}"
        kill "-${signal}" "$pid" 2>/dev/null || true
    done
}

_operation_wait_for_identities_exit() {
    local timeout="$1"
    shift || true
    local start now live
    start="$(_operation_epoch)"
    while true; do
        live="$(_operation_live_identity_pids "$@" | paste -sd' ' -)"
        [[ -z "$live" ]] && return 0
        now="$(_operation_epoch)"
        (( now - start >= timeout )) && {
            printf '%s\n' "$live"
            return 1
        }
        sleep 1
    done
}

_operation_live_pids() {
    local pid
    for pid in "$@"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        (( pid > 1 )) || continue
        (( pid == $$ )) && continue
        kill -0 "$pid" 2>/dev/null || continue
        printf '%s\n' "$pid"
    done
}

_operation_signal_pids() {
    local signal="$1" pid
    shift || true
    for pid in "$@"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        (( pid > 1 )) || continue
        (( pid == $$ )) && continue
        kill "-${signal}" "$pid" 2>/dev/null || true
    done
}

_operation_wait_for_pids_exit() {
    local timeout="$1"
    shift || true
    local start now live
    start="$(_operation_epoch)"
    while true; do
        live="$(_operation_live_pids "$@" | paste -sd' ' -)"
        [[ -z "$live" ]] && return 0
        now="$(_operation_epoch)"
        (( now - start >= timeout )) && {
            printf '%s\n' "$live"
            return 1
        }
        sleep 1
    done
}

_operation_wait_for_lock_clear() {
    local lock_path="$1" timeout="$2" start now
    [[ -n "$lock_path" ]] || return 0
    start="$(_operation_epoch)"
    while _operation_lock_is_held "$lock_path"; do
        now="$(_operation_epoch)"
        (( now - start >= timeout )) && return 1
        sleep 1
    done
    return 0
}

_operation_pid_cmdline() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null
}

_operation_has_package_manager_child() {
    local file="$1" pid _pid _ppid _etime _stat comm cmdline
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    while read -r _pid _ppid _etime _stat comm; do
        case "$comm" in
            apt|apt-get|dpkg|unattended-upgrade|unattended-upgr|add-apt-repository|apt-add-repository)
                return 0
                ;;
        esac
        cmdline="$(_operation_pid_cmdline "$_pid" 2>/dev/null || true)"
        case "$cmdline" in
            *add-apt-repository*|*apt-add-repository*)
                return 0
                ;;
        esac
    done < <(_operation_related_rows "$pid")
    return 1
}

_operation_print_related() {
    local file="$1" pid row any=false
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    while IFS= read -r row; do
        if [[ "$any" == "false" ]]; then
            printf '\nRelated processes:\n'
            printf '  PID      PPID     ELAPSED  STAT  COMMAND\n'
            any=true
        fi
        printf '  %s\n' "$row"
    done < <(_operation_related_rows "$pid")
}

_operation_describe_state() {
    local file="$1" label operation started started_epoch pid phase phase_name elapsed
    [[ -r "$file" ]] || {
        printf 'The VaultWarden operations lock is active, but the owning operation metadata could not be verified.\n'
        return 0
    }
    if ! _operation_verify_owner "$file"; then
        printf 'The VaultWarden operations lock is active, but the owning operation metadata could not be verified.\n'
        return 0
    fi
    operation="$(_operation_state_get "$file" operation 2>/dev/null || true)"
    label="$(_operation_state_get "$file" label 2>/dev/null || true)"
    started="$(_operation_state_get "$file" started 2>/dev/null || true)"
    started_epoch="$(_operation_state_get "$file" started_epoch 2>/dev/null || true)"
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    phase="$(_operation_state_get "$file" phase 2>/dev/null || true)"
    phase_name="$(_operation_state_get "$file" phase_name 2>/dev/null || true)"
    elapsed="$(_operation_elapsed "$started_epoch")"

    printf 'Another VaultWarden operation is currently active.\n\n'
    printf 'Operation : %s\n' "${label:-${operation:-unknown}}"
    [[ -n "$started" ]] && printf 'Started   : %s\n' "$started"
    printf 'Elapsed   : %s\n' "$elapsed"
    [[ -n "$pid" ]] && printf 'PID       : %s\n' "$pid"
    if [[ -n "$phase" || -n "$phase_name" ]]; then
        printf 'Phase     : %s%s%s\n' "${phase:-?}" "${phase_name:+ - }" "$phase_name"
    fi
    _operation_print_related "$file"
}

_operation_wait_for_release() {
    local lock_path="$1" state_file="$2" label="$3"
    local elapsed=0
    while _operation_lock_is_held "$lock_path"; do
        if (( elapsed >= VW_OPERATIONS_WAIT_LIMIT )); then
            _operation_log warn "Wait window expired; the active operation is still running."
            return 1
        fi
        if [[ -n "$state_file" && -r "$state_file" ]]; then
            local phase phase_name started_epoch
            phase="$(_operation_state_get "$state_file" phase 2>/dev/null || true)"
            phase_name="$(_operation_state_get "$state_file" phase_name 2>/dev/null || true)"
            started_epoch="$(_operation_state_get "$state_file" started_epoch 2>/dev/null || true)"
            _operation_log info "Waiting for ${label:-active operation}..."
            [[ -n "$phase$phase_name" ]] && _operation_log info "  Phase   : ${phase:-?}${phase_name:+ - }${phase_name}"
            _operation_log info "  Elapsed : $(_operation_elapsed "$started_epoch")"
        else
            _operation_log info "Waiting for the active VaultWarden operation..."
        fi
        _operation_log info "Next check in ${VW_OPERATIONS_WAIT_INTERVAL}s..."
        sleep "$VW_OPERATIONS_WAIT_INTERVAL"
        elapsed=$(( elapsed + VW_OPERATIONS_WAIT_INTERVAL ))
    done
    _operation_log info "Previous operation finished. Acquiring operation guard..."
    return 0
}

_operation_stop_scope() {
    local file="$1" mode="${2:-graceful}"
    local pid pid_start root_identity lock_path specific_lock global_owned
    local holder_pid holder_start holder_identity child_pids remaining identity
    local -a captured_identities=() child_identities=()
    _operation_verify_owner "$file" || {
        _operation_log error "Cannot verify the active VaultWarden operation owner; refusing to signal."
        return 1
    }
    if _operation_has_package_manager_child "$file"; then
        _operation_log error "Package manager activity is still active; refusing automated stop."
        return 1
    fi
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    pid_start="$(_operation_state_get "$file" pid_start 2>/dev/null || true)"
    root_identity="${pid}:${pid_start}"
    lock_path="$(_operation_state_get "$file" lock_path 2>/dev/null || true)"
    specific_lock="$(_operation_state_get "$file" specific_lock 2>/dev/null || true)"
    global_owned="$(_operation_state_get "$file" global_lock_owned 2>/dev/null || true)"
    holder_pid="$(_operation_state_get "$file" holder_pid 2>/dev/null || true)"
    holder_start="$(_operation_state_get "$file" holder_pid_start 2>/dev/null || true)"
    holder_identity="${holder_pid}:${holder_start}"

    mapfile -t captured_identities < <(_operation_capture_descendant_identities "$pid")
    for identity in "${captured_identities[@]}"; do
        [[ "$identity" == "$holder_identity" ]] && continue
        child_identities+=("$identity")
    done
    if (( ${#child_identities[@]} > 0 )); then
        child_pids="$(_operation_live_identity_pids "${child_identities[@]}" | paste -sd' ' -)"
        _operation_log warn "Requesting graceful stop for VaultWarden operation child process(es): ${child_pids}"
        _operation_signal_identities TERM "${child_identities[@]}"
        remaining="$(_operation_wait_for_identities_exit "$VW_OPERATIONS_STOP_GRACE" "${child_identities[@]}" || true)"
        if [[ -n "$remaining" && "$mode" != "force" ]]; then
            _operation_log error "Operation child process(es) still running after TERM: ${remaining}"
            _operation_log error "Leaving the operation wrapper running so the shared lock is not released prematurely."
            return 1
        fi
        if [[ -n "$remaining" ]]; then
            _operation_log warn "Force terminating verified operation child process(es): ${remaining}"
            _operation_signal_identities KILL "${child_identities[@]}"
            remaining="$(_operation_wait_for_identities_exit "$VW_OPERATIONS_FORCE_GRACE" "${child_identities[@]}" || true)"
            if [[ -n "$remaining" ]]; then
                _operation_log error "Operation child process(es) still running after KILL: ${remaining}"
                return 1
            fi
        fi
    fi

    if _operation_identity_is_live "$root_identity"; then
        _operation_verify_owner "$file" || {
            _operation_log error "Cannot re-verify the active VaultWarden operation owner; refusing to signal wrapper."
            return 1
        }
        _operation_log warn "Requesting graceful stop for VaultWarden operation PID ${pid}."
        kill -TERM "$pid" 2>/dev/null || return 1
    fi

    if ! _operation_wait_for_identities_exit "$VW_OPERATIONS_STOP_GRACE" "$root_identity" >/dev/null; then
        if [[ "$mode" != "force" ]]; then
            _operation_log error "Operation wrapper is still running after TERM: ${pid}"
            return 1
        fi
        _operation_verify_owner "$file" || {
            _operation_log error "Cannot re-verify the active VaultWarden operation owner before force termination."
            return 1
        }
        _operation_log warn "Force terminating verified operation wrapper: ${pid}"
        kill -KILL "$pid" 2>/dev/null || true
        remaining="$(_operation_wait_for_identities_exit "$VW_OPERATIONS_FORCE_GRACE" "$root_identity" || true)"
        if [[ -n "$remaining" ]]; then
            _operation_log error "Operation wrapper is still running after KILL: ${remaining}"
            return 1
        fi
    fi

    remaining="$(_operation_live_identity_pids "${child_identities[@]}" | paste -sd' ' -)"
    if [[ -n "$remaining" ]]; then
        _operation_log error "Operation-owned child process(es) still running: ${remaining}"
        return 1
    fi
    if _operation_identity_is_live "$root_identity"; then
        _operation_log error "Operation wrapper is still running: ${pid}"
        return 1
    fi

    remaining="$(_operation_wait_for_identities_exit "$VW_OPERATIONS_STOP_GRACE" "$holder_identity" || true)"
    if [[ -n "$remaining" ]]; then
        [[ "$global_owned" == "true" ]] || lock_path=""
        if ! _operation_holder_identity_is_live \
            "$holder_pid" "$holder_start" "$lock_path" "$specific_lock"; then
            _operation_log error "Cannot verify the operation lock holder after wrapper exit."
            return 1
        fi
        _operation_log warn "Stopping verified operation lock infrastructure after wrapper exit: ${holder_pid}"
        kill -TERM "$holder_pid" 2>/dev/null || true
        remaining="$(_operation_wait_for_identities_exit "$VW_OPERATIONS_FORCE_GRACE" "$holder_identity" || true)"
        if [[ -n "$remaining" ]]; then
            _operation_log error "Operation lock infrastructure is still running: ${remaining}"
            return 1
        fi
    fi

    if [[ "$global_owned" != "true" ]]; then
        lock_path="$specific_lock"
    fi
    _operation_wait_for_lock_clear "$lock_path" "$VW_OPERATIONS_STOP_GRACE" || {
        _operation_log error "Operation lock is still held after stop request; inspect with: sudo make operations"
        return 1
    }
}

_operation_request_stop() {
    _operation_stop_scope "$1" graceful
}

_operation_force_stop() {
    local file="$1" reply
    _operation_verify_owner "$file" || {
        _operation_log error "Cannot verify the active VaultWarden operation owner; refusing to signal."
        return 1
    }
    printf 'Type KILL to force terminate this VaultWarden operation: ' >&2
    if ! IFS= read -r -t "$VW_OPERATIONS_PROMPT_TIMEOUT" reply; then
        _operation_log warn "Force termination cancelled because no confirmation was received."
        _operation_log info "Inspect the host before retrying. Check later with: sudo make operations"
        return 1
    fi
    [[ "$reply" == "KILL" ]] || {
        _operation_log warn "Force termination cancelled."
        return 1
    }
    _operation_stop_scope "$file" force
}

operation_conflict_prompt() {
    local lock_path="$1" policy="${2:-fail}" skip_code="${3:-75}"
    local state_file label choice
    state_file="$(_operation_find_state_for_lock "$lock_path" 2>/dev/null || true)"
    label="$(_operation_state_get "$state_file" label 2>/dev/null || true)"

    if [[ "$policy" == "wait" ]]; then
        _operation_describe_state "$state_file" >&2
        _operation_wait_for_release "$lock_path" "$state_file" "$label"
        return $?
    fi

    if [[ ! -t 0 || ! -t 1 ]]; then
        _operation_describe_state "$state_file" >&2
        if [[ "$policy" == "skip" ]]; then
            _operation_log warn "Non-interactive run skipped because another VaultWarden operation is active."
            return "$skip_code"
        fi
        _operation_log error "Non-interactive run cannot prompt while another operation is active."
        return 1
    fi

    while true; do
        _operation_describe_state "$state_file"
        if [[ -z "$state_file" || ! -r "$state_file" ]] || ! _operation_verify_owner "$state_file"; then
            printf '\nChoose an action:\n\n'
            printf '  [1] Wait for the active operation\n'
            printf '  [2] Exit and inspect manually\n\n'
            printf 'Selection [1-2] (default: 2): '
            if ! IFS= read -r -t "$VW_OPERATIONS_PROMPT_TIMEOUT" choice; then
                _operation_log warn "No selection received; leaving the active operation untouched."
                _operation_log info "Inspect the host before retrying. Check later with: sudo make operations"
                return 1
            fi
            [[ -z "$choice" ]] && choice=2
            case "$choice" in
                1) _operation_wait_for_release "$lock_path" "" "" && return 0 ;;
                2) _operation_log info "Inspect the host before retrying. Check later with: sudo make operations"; return 1 ;;
                *) _operation_log warn "Invalid selection." ;;
            esac
            continue
        fi

        if _operation_has_package_manager_child "$state_file"; then
            printf '\nPackage manager activity is still active.\n'
            printf 'VaultWarden-OCI will not automatically terminate apt/dpkg because doing so may leave package configuration incomplete.\n'
            printf '\nChoose an action:\n\n'
            printf '  [1] Wait for the active operation\n'
            printf '  [2] Exit and leave it running\n\n'
            printf 'Selection [1-2] (default: 2): '
            if ! IFS= read -r -t "$VW_OPERATIONS_PROMPT_TIMEOUT" choice; then
                _operation_log warn "No selection received; leaving package manager activity untouched."
                _operation_log info "Inspect the host before retrying. Check later with: sudo make operations"
                return 1
            fi
            [[ -z "$choice" ]] && choice=2
            case "$choice" in
                1) _operation_wait_for_release "$lock_path" "$state_file" "$label" && return 0 ;;
                2) _operation_log info "Leaving the active operation running. Check later with: sudo make operations"; return 1 ;;
                *) _operation_log warn "Invalid selection." ;;
            esac
            continue
        fi

        printf '\nChoose an action:\n\n'
        printf '  [1] Wait for the active operation\n'
        printf '  [2] Exit and leave it running\n'
        printf '  [3] Request the VaultWarden operation to stop\n'
        printf '  [4] Force terminate the VaultWarden operation\n\n'
        printf 'Selection [1-4] (default: 2): '
        if ! IFS= read -r -t "$VW_OPERATIONS_PROMPT_TIMEOUT" choice; then
            _operation_log warn "No selection received; leaving the active operation untouched."
            _operation_log info "Inspect the host before retrying. Check later with: sudo make operations"
            return 1
        fi
        [[ -z "$choice" ]] && choice=2
        case "$choice" in
            1) _operation_wait_for_release "$lock_path" "$state_file" "$label" && return 0 ;;
            2) _operation_log info "Leaving the active operation running. Check later with: sudo make operations"; return 1 ;;
            3)
                _operation_request_stop "$state_file" || return 1
                _operation_wait_for_release "$lock_path" "$state_file" "$label" && return 0
                ;;
            4)
                _operation_force_stop "$state_file" || return 1
                _operation_wait_for_release "$lock_path" "$state_file" "$label" && return 0
                ;;
            *) _operation_log warn "Invalid selection." ;;
        esac
    done
}

_operation_validate_inherited_global() {
    local state_file="${VW_OPERATION_PARENT_STATE:-}"
    local token="${VW_OPERATION_PARENT_TOKEN:-}" id="${VW_OPERATION_PARENT_ID:-}"
    local expected_state state_token state_operation state_state owner_pid
    [[ "$id" =~ ^[a-z0-9._-]+$ && -n "$token" ]] || return 1
    expected_state="${VW_OPERATIONS_STATE_DIR}/${id}.state"
    [[ "$state_file" == "$expected_state" ]] || return 1
    _operation_state_file_is_trusted "$state_file" || return 1
    state_token="$(_operation_state_get "$state_file" token 2>/dev/null || true)"
    state_operation="$(_operation_state_get "$state_file" operation 2>/dev/null || true)"
    state_state="$(_operation_state_get "$state_file" state 2>/dev/null || true)"
    owner_pid="$(_operation_state_get "$state_file" pid 2>/dev/null || true)"
    [[ "$state_token" == "$token" && "$state_operation" == "$id" \
        && "$state_state" == "running" ]] || return 1
    _operation_verify_owner "$state_file" || return 1
    _operation_pid_is_self_or_descendant "$BASHPID" "$owner_pid"
}

_operation_current_guard_is_valid() {
    if [[ "$OPERATION_OWNS_STATE" == "true" ]]; then
        if [[ -d "/proc/${OPERATION_OWNER_PID}/fd" ]]; then
            _operation_verify_owner "$OPERATION_STATE_FILE" || return 1
            _operation_pid_is_self_or_descendant "$BASHPID" "$OPERATION_OWNER_PID" || return 1
        fi
        _operation_local_holder_is_live
        return
    fi
    _operation_validate_inherited_global || return 1
    _operation_local_holder_is_live
}

operation_acquire() {
    local id="" label="" specific_lock="" no_global=false policy="fail" skip_code=75
    local arg rc should_claim_state=false inherited_global=false global_path=""
    local inherited_metadata=false
    while [[ $# -gt 0 ]]; do
        arg="$1"; shift
        case "$arg" in
            --id) id="${1:-}"; shift ;;
            --label) label="${1:-}"; shift ;;
            --specific-lock) specific_lock="${1:-}"; shift ;;
            --no-global) no_global=true ;;
            --non-interactive) policy="${1:-fail}"; shift ;;
            --skip-exit-code) skip_code="${1:-75}"; shift ;;
            *)
                _operation_log error "operation_acquire: unknown option: ${arg}"
                return 2
                ;;
        esac
    done

    [[ "$id" =~ ^[a-z0-9._-]+$ ]] || {
        _operation_log error "operation_acquire: invalid operation id: ${id}"
        return 2
    }
    [[ -n "$label" ]] || label="$id"

    OPERATION_ID="$id"
    OPERATION_LABEL="$label"
    OPERATION_SPECIFIC_LOCK="$specific_lock"
    OPERATION_STARTED="$(_operation_now)"
    OPERATION_STARTED_EPOCH="$(_operation_epoch)"
    OPERATION_OWNER_PID="$BASHPID"
    OPERATION_OWNER_PID_START="$(_operation_pid_start "$OPERATION_OWNER_PID" 2>/dev/null || true)"
    OPERATION_TOKEN="${id}.${OPERATION_OWNER_PID}.$RANDOM.$RANDOM.${OPERATION_STARTED_EPOCH}"
    OPERATION_STATE_FILE="${VW_OPERATIONS_STATE_DIR}/${id}.state"
    _operation_clear_holder
    OPERATION_OWNS_GLOBAL=false
    OPERATION_OWNS_STATE=false
    OPERATION_RELEASED=false

    _operation_prepare_state_dir || {
        _operation_log error "Cannot prepare operation state directory: ${VW_OPERATIONS_STATE_DIR}"
        return 1
    }

    if [[ "$no_global" != "true" ]]; then
        if [[ -n "${VW_OPERATION_PARENT_STATE:-}${VW_OPERATION_PARENT_TOKEN:-}${VW_OPERATION_PARENT_ID:-}" ]]; then
            inherited_metadata=true
        fi
        if [[ "$inherited_metadata" == "true" ]]; then
            if ! _operation_validate_inherited_global; then
                _operation_log error "Inherited operation ownership metadata could not be verified."
                return 1
            fi
            OPERATION_STATE_FILE="${VW_OPERATION_PARENT_STATE}"
            OPERATION_TOKEN="${VW_OPERATION_PARENT_TOKEN}"
            inherited_global=true
            OPERATION_OWNS_GLOBAL=false
            OPERATION_OWNS_STATE=false
        else
            _operation_prepare_lock_file "$VW_OPERATIONS_LOCK" || {
                _operation_log error "Cannot prepare operations lock: ${VW_OPERATIONS_LOCK}"
                return 1
            }
            global_path="$VW_OPERATIONS_LOCK"
            OPERATION_OWNS_GLOBAL=true
            should_claim_state=true
        fi
    else
        should_claim_state=true
    fi

    if [[ -n "$specific_lock" ]]; then
        _operation_prepare_lock_file "$specific_lock" || {
            _operation_log error "Cannot prepare operation-specific lock: ${specific_lock}"
            return 1
        }
    fi

    while [[ -n "$global_path$specific_lock" ]]; do
        if _operation_start_holder "$global_path" "$specific_lock"; then
            break
        else
            rc=$?
        fi
        case "$rc" in
            75)
                operation_conflict_prompt "$VW_OPERATIONS_LOCK" "$policy" "$skip_code"
                rc=$?
                (( rc == 0 )) && continue
                OPERATION_OWNS_GLOBAL=false
                return "$rc"
                ;;
            76)
                _operation_log error "Another ${label} operation is already running."
                OPERATION_OWNS_GLOBAL=false
                return 1
                ;;
            *)
                OPERATION_OWNS_GLOBAL=false
                return 1
                ;;
        esac
    done

    if [[ "$should_claim_state" == "true" ]]; then
        if [[ -z "$global_path$specific_lock" ]]; then
            _operation_log error "Operation acquisition requested no global or specific lock."
            return 1
        fi
        OPERATION_OWNS_STATE=true
        OPERATION_PHASE="start"
        OPERATION_PHASE_NAME="Starting"
        if ! _operation_write_state running; then
            OPERATION_OWNS_STATE=false
            _operation_log error "Cannot write operation state: ${OPERATION_STATE_FILE}"
            _operation_discard_holder
            OPERATION_OWNS_GLOBAL=false
            return 1
        fi
        if [[ "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
            export VW_OPERATION_PARENT_STATE="$OPERATION_STATE_FILE"
            export VW_OPERATION_PARENT_TOKEN="$OPERATION_TOKEN"
            export VW_OPERATION_PARENT_ID="$OPERATION_ID"
        fi
        if [[ -d "/proc/${OPERATION_OWNER_PID}/fd" ]] \
            && ! _operation_current_guard_is_valid; then
            _operation_log error "Operation lock infrastructure failed verification after state startup."
            _operation_write_state failed 1 "$(_operation_now)" 2>/dev/null || true
            OPERATION_OWNS_STATE=false
            _operation_discard_holder
            OPERATION_OWNS_GLOBAL=false
            return 1
        fi
    elif [[ "$inherited_global" == "true" ]] && [[ -n "$specific_lock" ]] \
        && ! _operation_local_holder_is_live; then
        _operation_log error "Nested operation-specific lock holder failed verification."
        _operation_discard_holder
        return 1
    fi
    return 0
}

operation_set_phase() {
    OPERATION_PHASE="${1:-}"
    OPERATION_PHASE_NAME="${2:-}"
    [[ -n "$OPERATION_STATE_FILE" ]] || return 0
    if ! _operation_current_guard_is_valid; then
        _operation_log error "Operation lock ownership could not be verified before phase update."
        return 1
    fi
    if [[ "$OPERATION_OWNS_STATE" != "true" ]]; then
        _operation_update_phase_fields
        return $?
    fi
    _operation_write_state running
}

operation_release() {
    local result="${1:-0}" state="complete" completed release_rc=0
    [[ "$OPERATION_RELEASED" == "true" ]] && return 0
    OPERATION_RELEASED=true
    completed="$(_operation_now)"
    [[ "$result" == "0" ]] || state="failed"
    if [[ -n "$OPERATION_HOLDER_PID" ]] && ! _operation_local_holder_is_live; then
        _operation_log error "Operation lock infrastructure was lost before release."
        state="failed"
        [[ "$result" == "0" ]] && result=1
        release_rc=1
    fi
    if [[ "$OPERATION_OWNS_STATE" == "true" ]]; then
        if ! _operation_write_state "$state" "$result" "$completed" 2>/dev/null; then
            _operation_log error "Cannot write final operation state: ${OPERATION_STATE_FILE}"
            release_rc=1
        fi
    fi
    if ! _operation_release_holder; then
        _operation_log error "Operation lock holder exited unexpectedly during release."
        release_rc=1
    fi
    unset VW_OPERATION_PARENT_STATE VW_OPERATION_PARENT_TOKEN VW_OPERATION_PARENT_ID
    return "$release_rc"
}

_operation_known_label() {
    case "$1" in
        backup) printf 'Backup' ;;
        crowdsec-setup) printf 'CrowdSec setup' ;;
        dns-update) printf 'DNS update' ;;
        env-sync) printf 'Environment sync' ;;
        firewall-update) printf 'Firewall update' ;;
        health-check) printf 'Health check' ;;
        key-rotate) printf 'Age key rotation' ;;
        maintenance) printf 'Maintenance' ;;
        maintenance-db) printf 'Database maintenance' ;;
        permission-repair) printf 'Permission repair' ;;
        recovery) printf 'Recovery' ;;
        setup) printf 'Setup' ;;
        secrets) printf 'Secrets' ;;
        startup) printf 'Startup' ;;
        storage-migration) printf 'Storage migration' ;;
        storage-setup) printf 'Storage setup' ;;
        systemd-install) printf 'Systemd install' ;;
        restore) printf 'Restore' ;;
        uninstall) printf 'Uninstall' ;;
        update) printf 'Update' ;;
        health-repair) printf 'Health repair' ;;
        *) printf '%s' "$1" ;;
    esac
}

_operation_list_one() {
    local id="$1" label="$2"
    local file="${VW_OPERATIONS_STATE_DIR}/${id}.state"
    local state pid started_epoch phase phase_name lock_path specific_lock global_owned status
    printf '\n%s\n' "$label"
    if [[ ! -r "$file" ]]; then
        printf '  State   : idle\n'
        return 0
    fi
    state="$(_operation_state_get "$file" state 2>/dev/null || true)"
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    started_epoch="$(_operation_state_get "$file" started_epoch 2>/dev/null || true)"
    phase="$(_operation_state_get "$file" phase 2>/dev/null || true)"
    phase_name="$(_operation_state_get "$file" phase_name 2>/dev/null || true)"
    lock_path="$(_operation_state_get "$file" lock_path 2>/dev/null || true)"
    specific_lock="$(_operation_state_get "$file" specific_lock 2>/dev/null || true)"
    global_owned="$(_operation_state_get "$file" global_lock_owned 2>/dev/null || true)"
    status="$state"
    if [[ "$state" == "running" ]]; then
        if [[ "$global_owned" == "true" && -n "$lock_path" ]] && \
           _operation_lock_is_held "$lock_path" && _operation_verify_owner "$file"; then
            status="running"
        elif [[ "$global_owned" != "true" && -n "$specific_lock" ]] && \
             _operation_lock_is_held "$specific_lock" && _operation_verify_owner "$file"; then
            status="running"
        else
            status="interrupted"
        fi
    elif [[ "$state" == "complete" ]]; then
        status="idle"
    fi
    printf '  State   : %s\n' "${status:-unknown}"
    [[ -n "$pid" ]] && printf '  PID     : %s\n' "$pid"
    [[ -n "$started_epoch" ]] && printf '  Elapsed : %s\n' "$(_operation_elapsed "$started_epoch")"
    [[ -n "$phase$phase_name" ]] && printf '  Phase   : %s%s%s\n' "${phase:-?}" "${phase_name:+ - }" "$phase_name"
    if [[ "$status" == "running" ]]; then
        _operation_print_related "$file" | sed 's/^/  /'
    fi
}

operation_list() {
    local ids=(crowdsec-setup maintenance maintenance-db backup restore recovery setup startup secrets env-sync systemd-install storage-migration storage-setup update key-rotate uninstall health-check health-repair dns-update firewall-update permission-repair)
    local seen="" id file label
    printf 'VaultWarden-OCI Operations\n'
    for id in "${ids[@]}"; do
        seen="${seen} ${id} "
        _operation_list_one "$id" "$(_operation_known_label "$id")"
    done
    if [[ -d "$VW_OPERATIONS_STATE_DIR" ]]; then
        for file in "$VW_OPERATIONS_STATE_DIR"/*.state; do
            [[ -f "$file" ]] || continue
            id="${file##*/}"
            id="${id%.state}"
            [[ "$seen" == *" ${id} "* ]] && continue
            label="$(_operation_state_get "$file" label 2>/dev/null || true)"
            _operation_list_one "$id" "${label:-$id}"
        done
    fi
}

_operation_output_is_package_lock_error() {
    local file="$1"
    grep -Eiq 'Could not get lock|Unable to acquire.*lock|Unable to lock|waiting for cache lock|dpkg frontend lock|/var/lib/dpkg/lock|/var/cache/apt/archives/lock|is another process using it|Resource temporarily unavailable' "$file"
}

operation_package_run() {
    local tmp rc attempt had_errexit=false
    tmp="$(mktemp -t vw-package.XXXXXXXXXX)" || return 1
    [[ $- == *e* ]] && had_errexit=true
    for ((attempt=1; attempt<=VW_PACKAGE_WAIT_ATTEMPTS; attempt++)); do
        : > "$tmp"
        set +e
        LC_ALL=C "$@" 2>&1 | tee "$tmp"
        rc=${PIPESTATUS[0]}
        if [[ "$had_errexit" == "true" ]]; then
            set -e
        else
            set +e
        fi
        if (( rc == 0 )); then
            rm -f "$tmp"
            return 0
        fi
        if ! _operation_output_is_package_lock_error "$tmp"; then
            rm -f "$tmp"
            return "$rc"
        fi
        if (( attempt == VW_PACKAGE_WAIT_ATTEMPTS )); then
            _operation_log error "Package manager lock contention did not clear after ${VW_PACKAGE_WAIT_ATTEMPTS} attempts."
            rm -f "$tmp"
            return "$rc"
        fi
        _operation_log warn "Package manager lock contention detected; retrying after ${VW_PACKAGE_WAIT_INTERVAL}s."
        _operation_log warn "The active apt/dpkg process was not terminated and no lock files were removed."
        sleep "$VW_PACKAGE_WAIT_INTERVAL"
    done
    rm -f "$tmp"
    return 1
}
