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

OPERATION_ID=""
OPERATION_LABEL=""
OPERATION_STATE_FILE=""
OPERATION_LOCK_FD=""
OPERATION_SPECIFIC_LOCK_FD=""
OPERATION_SPECIFIC_LOCK=""
OPERATION_TOKEN=""
OPERATION_STARTED=""
OPERATION_STARTED_EPOCH=""
OPERATION_PHASE=""
OPERATION_PHASE_NAME=""
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

_operation_pid_start() {
    local pid="$1"
    [[ -r "/proc/${pid}/stat" ]] || return 1
    awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null
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
    local lock_path="$1" lock_dir desired_group=root created=false old_umask
    local desired_owner current_mode current_owner ownership_applied=false

    lock_dir="$(dirname "$lock_path")"
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || {
            _operation_log error "Cannot create operation lock directory: ${lock_dir}"
            _operation_log error "Fix: sudo mkdir -p '${lock_dir}' && sudo chmod 1777 '${lock_dir}'"
            return 1
        }
    fi

    if command -v getent >/dev/null 2>&1 \
        && getent group vaultwarden >/dev/null 2>&1; then
        desired_group=vaultwarden
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
            created=true
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

    desired_owner="root:${desired_group}"
    current_owner="$(stat -c '%U:%G' "$lock_path" 2>/dev/null \
        || stat -f '%Su:%Sg' "$lock_path" 2>/dev/null || true)"
    if [[ "$current_owner" == "$desired_owner" ]]; then
        ownership_applied=true
    elif chown "$desired_owner" "$lock_path" 2>/dev/null; then
        ownership_applied=true
    else
        if (( EUID == 0 )); then
            _operation_log error "Cannot set operation lock ownership to ${desired_owner}: ${lock_path}"
            _operation_log error "Fix: sudo chown ${desired_owner} '${lock_path}'"
            return 1
        fi
        _operation_log warn "Could not set ${lock_path} ownership to ${desired_owner} without root privileges."
        _operation_log warn "Fix: sudo chown ${desired_owner} '${lock_path}' && sudo chmod 0660 '${lock_path}'"
    fi

    if [[ "$desired_group" == root && "$created" == true && "$ownership_applied" == true ]]; then
        _operation_log warn "The 'vaultwarden' group is unavailable; using root:root mode 0660 for ${lock_path}."
        _operation_log warn "Run 'sudo utilities/setup-systemd.sh install' to create the group and enforce shared ownership."
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

_operation_write_state() {
    local state="${1:-running}" result="${2:-}" completed="${3:-}"
    local tmp pid_start
    [[ -n "$OPERATION_STATE_FILE" ]] || return 0
    _operation_prepare_state_dir || return 1
    tmp="$(mktemp "${OPERATION_STATE_FILE}.tmp.XXXXXXXX")" || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    pid_start="$(_operation_pid_start "$$" 2>/dev/null || true)"
    {
        printf 'owner=VaultWarden-OCI\n'
        printf 'operation=%s\n' "$(_operation_safe_value "$OPERATION_ID")"
        printf 'label=%s\n' "$(_operation_safe_value "$OPERATION_LABEL")"
        printf 'state=%s\n' "$(_operation_safe_value "$state")"
        printf 'pid=%s\n' "$$"
        printf 'pid_start=%s\n' "$(_operation_safe_value "$pid_start")"
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

_operation_try_lock_into() {
    local lock_path="$1" result_var="$2" lock_fd
    _operation_prepare_lock_file "$lock_path" || return 2
    { exec {lock_fd}>"$lock_path"; } 2>/dev/null || return 2
    if flock -n "$lock_fd" 2>/dev/null; then
        printf -v "$result_var" '%s' "$lock_fd"
        return 0
    fi
    { eval "exec ${lock_fd}>&-"; } 2>/dev/null || true
    return 1
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
        [[ -f "$file" ]] || continue
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

_operation_verify_owner() {
    local file="$1" pid saved_start current_start owner token
    owner="$(_operation_state_get "$file" owner 2>/dev/null || true)"
    token="$(_operation_state_get "$file" token 2>/dev/null || true)"
    pid="$(_operation_state_get "$file" pid 2>/dev/null || true)"
    saved_start="$(_operation_state_get "$file" pid_start 2>/dev/null || true)"
    [[ "$owner" == "VaultWarden-OCI" && -n "$token" && "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    current_start="$(_operation_pid_start "$pid" 2>/dev/null || true)"
    [[ -n "$saved_start" && "$current_start" == "$saved_start" ]] || return 1
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
    local pid pid_start root_identity lock_path child_identities child_pids remaining
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

    mapfile -t child_identities < <(_operation_capture_descendant_identities "$pid")
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
    local fd="${VW_OPERATION_INHERITED_FD:-}" state_file="${VW_OPERATION_PARENT_STATE:-}"
    local token="${VW_OPERATION_PARENT_TOKEN:-}" target state_token state_state
    [[ "$fd" =~ ^[0-9]+$ ]] || return 1
    [[ -e "/proc/$$/fd/${fd}" ]] || return 1
    target="$(readlink "/proc/$$/fd/${fd}" 2>/dev/null || true)"
    [[ "$target" == "$VW_OPERATIONS_LOCK" ]] || return 1
    [[ -r "$state_file" && -n "$token" ]] || return 1
    state_token="$(_operation_state_get "$state_file" token 2>/dev/null || true)"
    state_state="$(_operation_state_get "$state_file" state 2>/dev/null || true)"
    [[ "$state_token" == "$token" && "$state_state" == "running" ]] || return 1
}

operation_acquire() {
    local id="" label="" specific_lock="" no_global=false policy="fail" skip_code=75
    local arg fd rc should_claim_state=false
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
    OPERATION_TOKEN="${id}.$$.$RANDOM.$RANDOM.${OPERATION_STARTED_EPOCH}"
    OPERATION_STATE_FILE="${VW_OPERATIONS_STATE_DIR}/${id}.state"
    OPERATION_OWNS_GLOBAL=false
    OPERATION_OWNS_STATE=false
    OPERATION_RELEASED=false

    _operation_prepare_state_dir || {
        _operation_log error "Cannot prepare operation state directory: ${VW_OPERATIONS_STATE_DIR}"
        return 1
    }

    if [[ "$no_global" != "true" ]]; then
        if _operation_validate_inherited_global; then
            OPERATION_LOCK_FD="${VW_OPERATION_INHERITED_FD}"
            OPERATION_STATE_FILE="${VW_OPERATION_PARENT_STATE}"
            OPERATION_TOKEN="${VW_OPERATION_PARENT_TOKEN}"
            OPERATION_OWNS_GLOBAL=false
            OPERATION_OWNS_STATE=false
        else
            while true; do
                if _operation_try_lock_into "$VW_OPERATIONS_LOCK" fd; then
                    OPERATION_LOCK_FD="$fd"
                    OPERATION_OWNS_GLOBAL=true
                    should_claim_state=true
                    break
                fi
                rc=$?
                if (( rc == 2 )); then
                    _operation_log error "Cannot open operations lock: ${VW_OPERATIONS_LOCK}"
                    return 1
                fi
                operation_conflict_prompt "$VW_OPERATIONS_LOCK" "$policy" "$skip_code"
                rc=$?
                (( rc == 0 )) && continue
                return "$rc"
            done
        fi
    else
        should_claim_state=true
    fi

    if [[ -n "$specific_lock" ]]; then
        if ! _operation_try_lock_into "$specific_lock" fd; then
            _operation_log error "Another ${label} operation is already running."
            if [[ -n "${OPERATION_LOCK_FD:-}" && "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
                { eval "exec ${OPERATION_LOCK_FD}>&-"; } 2>/dev/null || true
                OPERATION_LOCK_FD=""
                OPERATION_OWNS_GLOBAL=false
            fi
            return 1
        fi
        OPERATION_SPECIFIC_LOCK_FD="$fd"
    fi

    if [[ "$should_claim_state" == "true" ]]; then
        OPERATION_OWNS_STATE=true
        OPERATION_PHASE="start"
        OPERATION_PHASE_NAME="Starting"
        if ! _operation_write_state running; then
            OPERATION_OWNS_STATE=false
            if [[ -n "${OPERATION_SPECIFIC_LOCK_FD:-}" ]]; then
                flock -u "$OPERATION_SPECIFIC_LOCK_FD" 2>/dev/null || true
                { eval "exec ${OPERATION_SPECIFIC_LOCK_FD}>&-"; } 2>/dev/null || true
                OPERATION_SPECIFIC_LOCK_FD=""
            fi
            if [[ -n "${OPERATION_LOCK_FD:-}" && "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
                { eval "exec ${OPERATION_LOCK_FD}>&-"; } 2>/dev/null || true
                OPERATION_LOCK_FD=""
                OPERATION_OWNS_GLOBAL=false
            fi
            return 1
        fi
        if [[ "$OPERATION_OWNS_GLOBAL" == "true" ]]; then
            export VW_OPERATION_INHERITED_FD="$OPERATION_LOCK_FD"
            export VW_OPERATION_PARENT_STATE="$OPERATION_STATE_FILE"
            export VW_OPERATION_PARENT_TOKEN="$OPERATION_TOKEN"
            export VW_OPERATION_PARENT_ID="$OPERATION_ID"
        fi
    fi
    return 0
}

# Run an external command without passing VaultWarden operation-lock file
# descriptors or inherited-operation metadata into that command or its children.
# The subshell keeps the parent shell's guard descriptors open while ensuring
# daemonizing/plugin-style children cannot outlive the operation and retain the
# kernel flock after the owning wrapper has released it.
operation_run_without_guard_fds() (
    (( $# > 0 )) || return 2
    local fd
    local -a guard_fds=(
        "${OPERATION_SPECIFIC_LOCK_FD:-}"
        "${OPERATION_LOCK_FD:-}"
        "${VW_OPERATION_INHERITED_FD:-}"
    )
    for fd in "${guard_fds[@]}"; do
        if [[ "$fd" =~ ^[0-9]+$ ]] && (( fd > 2 )); then
            { eval "exec ${fd}>&-"; } 2>/dev/null || true
        fi
    done
    unset OPERATION_LOCK_FD
    unset OPERATION_SPECIFIC_LOCK_FD
    unset VW_OPERATION_INHERITED_FD
    unset VW_OPERATION_PARENT_STATE
    unset VW_OPERATION_PARENT_TOKEN
    unset VW_OPERATION_PARENT_ID
    exec "$@"
)

operation_set_phase() {
    OPERATION_PHASE="${1:-}"
    OPERATION_PHASE_NAME="${2:-}"
    [[ -n "$OPERATION_STATE_FILE" ]] || return 0
    if [[ "$OPERATION_OWNS_STATE" != "true" ]]; then
        _operation_update_phase_fields
        return $?
    fi
    _operation_write_state running
}

operation_release() {
    local result="${1:-0}" state="complete" completed
    [[ "$OPERATION_RELEASED" == "true" ]] && return 0
    OPERATION_RELEASED=true
    completed="$(_operation_now)"
    [[ "$result" == "0" ]] || state="failed"
    if [[ "$OPERATION_OWNS_STATE" == "true" ]]; then
        _operation_write_state "$state" "$result" "$completed" 2>/dev/null || true
    fi
    if [[ -n "${OPERATION_SPECIFIC_LOCK_FD:-}" ]]; then
        flock -u "$OPERATION_SPECIFIC_LOCK_FD" 2>/dev/null || true
        { eval "exec ${OPERATION_SPECIFIC_LOCK_FD}>&-"; } 2>/dev/null || true
        OPERATION_SPECIFIC_LOCK_FD=""
    fi
    if [[ "$OPERATION_OWNS_GLOBAL" == "true" && -n "${OPERATION_LOCK_FD:-}" ]]; then
        # The global lock FD is intentionally inherited by nested mutating
        # children. Close our descriptor and let the kernel release the flock
        # only when the last inherited descriptor closes.
        { eval "exec ${OPERATION_LOCK_FD}>&-"; } 2>/dev/null || true
        OPERATION_LOCK_FD=""
    fi
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
    local ids=(crowdsec-setup maintenance maintenance-db backup restore setup startup secrets env-sync systemd-install storage-migration storage-setup update key-rotate uninstall health-check health-repair dns-update firewall-update permission-repair)
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
