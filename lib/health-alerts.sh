#!/usr/bin/env bash

# Shared health incident and recovery-notification state helpers.
#
# This file is source-only. The caller supplies log_debug, log_info, log_warn,
# and the dynamic-scope health state used by these helpers: ALERT_LOCK_DIR,
# ACTIVE_INCIDENT_FILE, RECOVERY_DELIVERY_STATE_FILE,
# ALERT_COOLDOWN_SECONDS, ALERT_RECOVERY_TTL, ALERT_RECOVERY_PENDING_TTL,
# failed, warnings, passed, ACTIVE_INCIDENT_*, incident_* collections,
# and for unhealthy updates check_order, check_results, and check_messages.
#
# Recovery state machine summary:
# - healthy + no incident: silent no-op;
# - invalid incident or corrupt delivery state: preserve evidence and fail
#   closed before email;
# - pending same-incident delivery lease: suppress recent duplicates, retry when
#   stale;
# - delivered same-incident marker: never resend, retry closure only;
# - SMTP success is followed by a best-effort local delivered-state write, so a
#   crash after SMTP acceptance and before local persistence remains an
#   unavoidable ambiguous window.

_state_path_present() {
    local path="$1"

    [[ -e "$path" || -L "$path" ]]
}

_state_file_size_bytes() {
    local path="$1" size

    size="$(LC_ALL=C wc -c < "$path" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$size"
}

_state_file_has_nul() {
    local path="$1" original_bytes stripped_bytes

    original_bytes="$(_state_file_size_bytes "$path")" || return 1
    stripped_bytes="$(LC_ALL=C tr -d '\000' < "$path" | wc -c | tr -d '[:space:]')" || return 1
    [[ "$stripped_bytes" =~ ^[0-9]+$ ]] || return 1
    (( stripped_bytes != original_bytes ))
}

_state_file_ends_with_newline() {
    local path="$1" size="$2" last_byte

    (( size > 0 )) || return 1
    last_byte="$(LC_ALL=C od -An -tu1 -j "$(( size - 1 ))" -N1 -- "$path" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$last_byte" == 10 ]]
}

_state_mode() {
    local path="$1" mode

    mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$mode"
}

_state_destination_is_safe() {
    local path="$1" label="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    if [[ -f "$path" && ! -L "$path" ]]; then
        return 0
    fi

    log_warn "${label} '${path}' is not a regular file; preserving it and skipping this state update."
    return 1
}

_state_remove_regular_file() {
    local path="$1" label="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    if [[ -f "$path" && ! -L "$path" ]]; then
        rm -f -- "$path" || return 1
        return 0
    fi

    log_warn "${label} '${path}' is not a regular file; preserving it for operator review."
    return 1
}

_state_prepare_tmp_file() {
    local pattern="$1" old_umask tmp_file

    old_umask="$(umask)"
    umask 077
    tmp_file="$(mktemp "$pattern")" || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"
    chmod 0600 "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }
    printf '%s' "$tmp_file"
}

_ensure_alert_dir() {
    if _state_path_present "$ALERT_LOCK_DIR"; then
        if [[ ! -d "$ALERT_LOCK_DIR" || -L "$ALERT_LOCK_DIR" ]]; then
            log_warn "_ensure_alert_dir: '${ALERT_LOCK_DIR}' is not a real directory; health alert state tracking is disabled for this cycle."
            return 1
        fi
    else
        if ! mkdir -p -- "$ALERT_LOCK_DIR" 2>/dev/null; then
            log_warn "_ensure_alert_dir: cannot create '${ALERT_LOCK_DIR}'" \
                "— health alert state tracking is disabled for this cycle." \
                "Fix: sudo mkdir -p '${ALERT_LOCK_DIR}' && sudo chown $(id -un) '${ALERT_LOCK_DIR}'"
            return 1
        fi
    fi

    if ! chmod 0750 -- "$ALERT_LOCK_DIR" 2>/dev/null; then
        log_warn "_ensure_alert_dir: cannot enforce mode 0750 on '${ALERT_LOCK_DIR}'"
        return 1
    fi
    return 0
}

_acquire_alert_lock() {
    local key="$1" safe_key state_file ttl now last_sent tmp_file

    safe_key="$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')"
    _ensure_alert_dir || return 1

    state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    ttl="${2:-${ALERT_COOLDOWN_SECONDS:-3600}}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=3600
    now="$(date +%s)"

    _state_destination_is_safe "$state_file" "Alert cooldown state" || return 1
    if [[ -f "$state_file" && ! -L "$state_file" ]]; then
        last_sent="$(cat -- "$state_file" 2>/dev/null || printf '0')"
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        if (( last_sent > now || now - last_sent < ttl )); then
            return 1
        fi
    fi

    tmp_file="$(_state_prepare_tmp_file "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX")" || {
        log_warn "_acquire_alert_lock: mktemp failed in '${ALERT_LOCK_DIR}' — skipping alert for '${key}'"
        return 1
    }
    printf '%s\n' "$now" > "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }
    _state_destination_is_safe "$state_file" "Alert cooldown state" || {
        rm -f -- "$tmp_file"
        return 1
    }
    mv -fT -- "$tmp_file" "$state_file" || {
        rm -f -- "$tmp_file"
        return 1
    }
    return 0
}

_release_alert_lock() {
    local key="$1" safe_key state_file

    safe_key="$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')"
    state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    _state_remove_regular_file "$state_file" "Alert cooldown state" || true
}

_release_recovery_lock() {
    _state_remove_regular_file "${ALERT_LOCK_DIR}/recovery.cooldown" "Recovery cooldown state" || true
}

_incident_sanitize() {
    local value="${1:-}" max_length="${2:-512}"

    [[ "$max_length" =~ ^[0-9]+$ ]] || max_length=512
    value="$(printf '%s' "$value" | LC_ALL=C sed -E \
        -e 's/[[:cntrl:]]/ /g' \
        -e 's/((password|passwd|token|api[_-]?key|authorization|credential|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
        -e 's/(Bearer)[[:space:]]+[^[:space:]]+/\1 [REDACTED]/Ig')"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\t'/ }"
    while [[ "$value" == *"  "* ]]; do value="${value//  / }"; done
    value="${value# }"
    value="${value% }"
    printf '%s' "${value:0:max_length}"
}

_incident_id_is_valid() {
    local incident_id="${1:-}"

    [[ "$incident_id" =~ ^[[:alnum:]][[:alnum:].:_-]{0,79}$ ]]
}

_incident_timestamp_is_valid() {
    local value="${1:-}"

    [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
    date -d "$value" +%s >/dev/null 2>&1
}

_incident_set_check() {
    local name="$1" status="$2" detail="$3"

    if [[ -z "${incident_statuses[$name]+set}" ]]; then
        incident_check_order+=("$name")
    fi
    incident_statuses["$name"]="$status"
    incident_details["$name"]="$detail"
}

_incident_reset_loaded_state() {
    ACTIVE_INCIDENT_AVAILABLE=false
    ACTIVE_INCIDENT_ID=""
    ACTIVE_INCIDENT_STARTED_AT=""
    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT=""
    ACTIVE_INCIDENT_HOSTNAME=""
    incident_statuses=()
    incident_details=()
    incident_check_order=()
}

_incident_load() {
    local path="${1:-$ACTIVE_INCIDENT_FILE}"
    local size line record key rest value detail sanitized
    local seen_incident_id=0 seen_started_at=0 seen_last_unhealthy_at=0 seen_hostname=0 check_count=0
    local -A seen_checks=()

    _incident_reset_loaded_state
    _state_path_present "$path" || return 1
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1

    size="$(_state_file_size_bytes "$path")" || return 1
    (( size > 0 && size <= 16384 )) || return 1
    _state_file_has_nul "$path" && return 1
    _state_file_ends_with_newline "$path" "$size" || return 1

    while IFS= read -r line; do
        [[ "$line" == *$'\t'* ]] || return 1
        record="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        [[ "$rest" == *$'\t'* ]] || return 1
        key="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"

        case "$record:$key" in
            meta:incident_id)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_incident_id == 0 )) || return 1
                _incident_id_is_valid "$rest" || return 1
                ACTIVE_INCIDENT_ID="$rest"
                seen_incident_id=1
                ;;
            meta:started_at)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_started_at == 0 )) || return 1
                _incident_timestamp_is_valid "$rest" || return 1
                ACTIVE_INCIDENT_STARTED_AT="$rest"
                seen_started_at=1
                ;;
            meta:last_unhealthy_at)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_last_unhealthy_at == 0 )) || return 1
                _incident_timestamp_is_valid "$rest" || return 1
                ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="$rest"
                seen_last_unhealthy_at=1
                ;;
            meta:hostname)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_hostname == 0 )) || return 1
                sanitized="$(_incident_sanitize "$rest" 255)"
                [[ -n "$sanitized" && "$sanitized" == "$rest" ]] || return 1
                ACTIVE_INCIDENT_HOSTNAME="$sanitized"
                seen_hostname=1
                ;;
            check:*)
                [[ "$rest" == *$'\t'* ]] || return 1
                value="${rest%%$'\t'*}"
                detail="${rest#*$'\t'}"
                [[ "$detail" != *$'\t'* ]] || return 1
                sanitized="$(_incident_sanitize "$key" 128)"
                [[ -n "$sanitized" && "$sanitized" == "$key" ]] || return 1
                [[ "$value" == "warn" || "$value" == "fail" ]] || return 1
                [[ -z "${seen_checks[$sanitized]+set}" ]] || return 1
                seen_checks["$sanitized"]=1
                sanitized="$(_incident_sanitize "$detail" 512)"
                [[ "$sanitized" == "$detail" ]] || return 1
                _incident_set_check "$key" "$value" "$detail"
                (( check_count += 1 )) || true
                ;;
            *)
                return 1
                ;;
        esac
    done < "$path"

    (( seen_incident_id == 1 && seen_started_at == 1 && check_count >= 1 )) || return 1
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_write() {
    local tmp_file line line_bytes bytes name

    _ensure_alert_dir || {
        log_warn "Health incident context unavailable: alert-state directory is not writable; continuing without incident correlation."
        return 1
    }
    _state_destination_is_safe "$ACTIVE_INCIDENT_FILE" "Active incident state" || {
        log_warn "Health incident context unavailable: active incident destination is invalid; continuing without incident correlation."
        return 1
    }
    _incident_id_is_valid "$ACTIVE_INCIDENT_ID" || return 1
    _incident_timestamp_is_valid "$ACTIVE_INCIDENT_STARTED_AT" || return 1
    _incident_timestamp_is_valid "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT" || return 1
    [[ -n "$ACTIVE_INCIDENT_HOSTNAME" && "$(_incident_sanitize "$ACTIVE_INCIDENT_HOSTNAME" 255)" == "$ACTIVE_INCIDENT_HOSTNAME" ]] || return 1

    tmp_file="$(_state_prepare_tmp_file "${ALERT_LOCK_DIR}/.active-incident.XXXXXXXX")" || {
        log_warn "Health incident context unavailable: cannot create state in '${ALERT_LOCK_DIR}'; continuing without incident correlation."
        return 1
    }

    {
        printf 'meta\tincident_id\t%s\n' "$ACTIVE_INCIDENT_ID"
        printf 'meta\tstarted_at\t%s\n' "$ACTIVE_INCIDENT_STARTED_AT"
        printf 'meta\tlast_unhealthy_at\t%s\n' "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT"
        printf 'meta\thostname\t%s\n' "$ACTIVE_INCIDENT_HOSTNAME"
    } > "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }

    bytes="$(_state_file_size_bytes "$tmp_file")" || {
        rm -f -- "$tmp_file"
        return 1
    }
    for name in "${incident_check_order[@]}"; do
        printf -v line 'check\t%s\t%s\t%s\n' \
            "$name" "${incident_statuses[$name]}" "${incident_details[$name]}"
        line_bytes="$(printf '%s' "$line" | LC_ALL=C wc -c | tr -d '[:space:]')" || {
            rm -f -- "$tmp_file"
            return 1
        }
        [[ "$line_bytes" =~ ^[0-9]+$ ]] || {
            rm -f -- "$tmp_file"
            return 1
        }
        if (( bytes + line_bytes > 16384 )); then
            log_warn "Health incident context would exceed 16384 bytes; preserving the existing incident state instead of writing a truncated replacement."
            rm -f -- "$tmp_file"
            return 1
        fi
        printf '%s' "$line" >> "$tmp_file" || {
            rm -f -- "$tmp_file"
            return 1
        }
        (( bytes += line_bytes )) || true
    done

    _state_destination_is_safe "$ACTIVE_INCIDENT_FILE" "Active incident state" || {
        rm -f -- "$tmp_file"
        return 1
    }
    mv -fT -- "$tmp_file" "$ACTIVE_INCIDENT_FILE" || {
        rm -f -- "$tmp_file"
        return 1
    }
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_update_unhealthy() {
    local now name original_name status detail

    (( failed > 0 || warnings > 0 )) || return 0
    now="$(date -Iseconds)"
    if _state_path_present "$ACTIVE_INCIDENT_FILE"; then
        if ! _incident_load "$ACTIVE_INCIDENT_FILE"; then
            log_warn "Health incident context is unreadable or invalid; preserving it and continuing without incident correlation."
            ACTIVE_INCIDENT_AVAILABLE=false
            return 1
        fi
    else
        ACTIVE_INCIDENT_ID="$(_incident_sanitize "vw-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6 2>/dev/null || printf '%06d' "$RANDOM")" 80)"
        ACTIVE_INCIDENT_STARTED_AT="$now"
        ACTIVE_INCIDENT_HOSTNAME="$(_incident_sanitize "$(hostname -f 2>/dev/null || hostname)" 255)"
        incident_statuses=()
        incident_details=()
        incident_check_order=()
    fi

    ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="$now"
    for original_name in "${check_order[@]}"; do
        status="${check_results[$original_name]:-}"
        [[ "$status" == "warn" || "$status" == "fail" ]] || continue
        name="$(_incident_sanitize "$original_name" 128)"
        detail="$(_incident_sanitize "${check_messages[$original_name]:-}" 512)"
        _incident_set_check "$name" "$status" "$detail"
    done
    if (( ${#incident_check_order[@]} == 0 )); then
        log_warn "Health incident context had no warn/fail checks to persist; continuing without incident correlation."
        ACTIVE_INCIDENT_AVAILABLE=false
        return 1
    fi

    if ! _incident_write; then
        ACTIVE_INCIDENT_AVAILABLE=false
        return 1
    fi
}

_incident_format_duration() {
    local seconds="${1:-0}" days hours minutes

    [[ "$seconds" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    minutes=$(( (seconds % 3600) / 60 ))
    printf '%sd %sh %sm (%ss)' "$days" "$hours" "$minutes" "$seconds"
}

_recovery_delivery_state_path() {
    printf '%s' "${RECOVERY_DELIVERY_STATE_FILE:-${ALERT_LOCK_DIR}/recovery-delivery.state}"
}

_recovery_delivery_state_reset() {
    RECOVERY_DELIVERY_PHASE=""
    RECOVERY_DELIVERY_INCIDENT_ID=""
    RECOVERY_DELIVERY_UPDATED_AT=""
}

_recovery_delivery_state_load() {
    local path size line rest version phase incident_id updated_at
    local -a lines=()

    path="$(_recovery_delivery_state_path)"
    _recovery_delivery_state_reset

    _state_path_present "$path" || return 1
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 2
    size="$(_state_file_size_bytes "$path")" || return 2
    (( size > 0 && size <= 512 )) || return 2
    _state_file_has_nul "$path" && return 2
    _state_file_ends_with_newline "$path" "$size" || return 2

    mapfile -t lines < "$path" || return 2
    [[ ${#lines[@]} -eq 1 ]] || return 2
    line="${lines[0]}"
    [[ "$line" == *$'\t'* ]] || return 2
    version="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    phase="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    [[ "$rest" == *$'\t'* ]] || return 2
    incident_id="${rest%%$'\t'*}"
    updated_at="${rest#*$'\t'}"
    [[ "$updated_at" != *$'\t'* ]] || return 2
    [[ "$version" == "v1" ]] || return 2
    [[ "$phase" == "pending" || "$phase" == "delivered" ]] || return 2
    _incident_id_is_valid "$incident_id" || return 2
    [[ "$updated_at" =~ ^[0-9]+$ ]] || return 2

    RECOVERY_DELIVERY_PHASE="$phase"
    RECOVERY_DELIVERY_INCIDENT_ID="$incident_id"
    RECOVERY_DELIVERY_UPDATED_AT="$updated_at"
}

_recovery_delivery_state_write() {
    local phase="$1" incident_id="$2" updated_at="${3:-}"
    local path tmp_file size

    path="$(_recovery_delivery_state_path)"
    [[ "$phase" == "pending" || "$phase" == "delivered" ]] || return 1
    _incident_id_is_valid "$incident_id" || return 1
    [[ -n "$updated_at" ]] || updated_at="$(date +%s)"
    [[ "$updated_at" =~ ^[0-9]+$ ]] || return 1
    _ensure_alert_dir || return 1
    [[ "$(dirname -- "$path")" == "$ALERT_LOCK_DIR" ]] || return 1
    _state_destination_is_safe "$path" "Recovery delivery state" || return 1

    tmp_file="$(_state_prepare_tmp_file "${ALERT_LOCK_DIR}/.recovery-delivery.XXXXXXXX")" || return 1
    printf 'v1\t%s\t%s\t%s\n' "$phase" "$incident_id" "$updated_at" > "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }
    size="$(_state_file_size_bytes "$tmp_file")" || {
        rm -f -- "$tmp_file"
        return 1
    }
    (( size <= 512 )) || {
        rm -f -- "$tmp_file"
        return 1
    }
    _state_destination_is_safe "$path" "Recovery delivery state" || {
        rm -f -- "$tmp_file"
        return 1
    }
    mv -fT -- "$tmp_file" "$path" || {
        rm -f -- "$tmp_file"
        return 1
    }

    RECOVERY_DELIVERY_PHASE="$phase"
    RECOVERY_DELIVERY_INCIDENT_ID="$incident_id"
    RECOVERY_DELIVERY_UPDATED_AT="$updated_at"
}

_recovery_delivery_state_clear() {
    local expected_incident_id="${1:-}" path load_rc=0

    path="$(_recovery_delivery_state_path)"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    if _recovery_delivery_state_load; then
        if [[ -n "$expected_incident_id" && "$RECOVERY_DELIVERY_INCIDENT_ID" != "$expected_incident_id" ]]; then
            return 0
        fi
    else
        load_rc=$?
        (( load_rc == 1 )) && return 0
        return 1
    fi

    _state_remove_regular_file "$path" "Recovery delivery state" || return 1
    _recovery_delivery_state_reset
}

_recovery_pending_is_recent() {
    local updated_at="$1" now ttl

    now="$(date +%s)"
    ttl="${ALERT_RECOVERY_PENDING_TTL:-900}"
    [[ "$updated_at" =~ ^[0-9]+$ ]] || return 1
    [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || ttl=900

    if (( updated_at > now )); then
        log_warn "Recovery delivery pending timestamp is in the future; suppressing duplicate delivery. Review the state file if the system clock is correct."
        return 0
    fi
    (( now - updated_at < ttl ))
}

_recovery_lock_path() {
    printf '%s' "${ALERT_LOCK_DIR}/recovery-delivery.lock"
}

_recovery_lock_prepare() {
    local lock_path="$1" tmp_file

    _ensure_alert_dir || return 1
    if _state_path_present "$lock_path"; then
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || {
            log_warn "Recovery notification suppressed because the delivery lock '${lock_path}' is not a regular file."
            return 1
        }
        chmod 0600 -- "$lock_path" 2>/dev/null || {
            log_warn "Recovery notification suppressed because mode 0600 could not be enforced on '${lock_path}'."
            return 1
        }
        [[ "$(_state_mode "$lock_path")" == "600" ]] || {
            log_warn "Recovery notification suppressed because '${lock_path}' is not mode 0600."
            return 1
        }
        return 0
    fi

    tmp_file="$(_state_prepare_tmp_file "${ALERT_LOCK_DIR}/.recovery-lock.XXXXXXXX")" || {
        log_warn "Recovery notification suppressed because a temporary lock file could not be created in '${ALERT_LOCK_DIR}'."
        return 1
    }
    if ln -- "$tmp_file" "$lock_path" 2>/dev/null; then
        rm -f -- "$tmp_file" || true
    else
        rm -f -- "$tmp_file" || true
        if ! _state_path_present "$lock_path"; then
            log_warn "Recovery notification suppressed because '${lock_path}' could not be created safely."
            return 1
        fi
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || {
            log_warn "Recovery notification suppressed because the delivery lock '${lock_path}' is not a regular file."
            return 1
        }
    fi

    chmod 0600 -- "$lock_path" 2>/dev/null || {
        log_warn "Recovery notification suppressed because mode 0600 could not be enforced on '${lock_path}'."
        return 1
    }
    [[ "$(_state_mode "$lock_path")" == "600" ]] || {
        log_warn "Recovery notification suppressed because '${lock_path}' is not mode 0600."
        return 1
    }
}

_recovery_lock_acquire() {
    local lock_path="$1" flock_rc

    _recovery_lock_prepare "$lock_path" || return 1
    if ! exec {RECOVERY_LOCK_FD}<> "$lock_path"; then
        log_warn "Recovery notification suppressed because the delivery lock '${lock_path}' could not be opened."
        return 1
    fi
    flock -n -E 75 "$RECOVERY_LOCK_FD"
    flock_rc=$?
    if (( flock_rc == 0 )); then
        return 0
    fi

    exec {RECOVERY_LOCK_FD}>&-
    RECOVERY_LOCK_FD=""
    if (( flock_rc == 75 )); then
        return 75
    fi

    log_warn "Recovery notification suppressed because acquiring the delivery lock '${lock_path}' failed."
    return 1
}

_recovery_lock_release() {
    if [[ -n "${RECOVERY_LOCK_FD:-}" ]]; then
        flock -u "$RECOVERY_LOCK_FD" 2>/dev/null || true
        exec {RECOVERY_LOCK_FD}>&-
        RECOVERY_LOCK_FD=""
    fi
}

_send_notification() {
    local subject="$1" body="$2"

    if [[ "${_email_available:-true}" == "false" ]]; then
        log_warn "Email notifications not available"
        return 1
    fi
    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        log_warn "ADMIN_EMAIL not set — cannot send health notification"
        return 1
    fi
    if ! send_email "$ADMIN_EMAIL" "$subject" "$body" 2>/dev/null; then
        log_warn "Failed to send health notification email"
        return 1
    fi
    return 0
}

_notify_failures() {
    local alerted_any=false name status message alert_date subject body

    for name in "${check_order[@]}"; do
        status="${check_results[$name]:-}"
        [[ "$status" == "fail" || "$status" == "warn" ]] || continue
        if ! _acquire_alert_lock "$name"; then
            log_info "Alert cooldown active for '${name}' — suppressing repeat notification"
            continue
        fi
        message="${check_messages[$name]:-}"
        alert_date="$(date)"
        if [[ "$ACTIVE_INCIDENT_AVAILABLE" == "true" && -n "$ACTIVE_INCIDENT_ID" ]]; then
            message="$(_incident_sanitize "$message" 512)"
            subject="VaultWarden Health [${status^^}] [Incident ${ACTIVE_INCIDENT_ID}]: ${name} on $(hostname)"
            printf -v body \
                'Health check alert at %s\n\nIncident: %s\nIncident started: %s\nCheck: %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nFor the full live status, run: ./maintenance.sh health\nTo also write a report file, run: ./maintenance.sh health --report' \
                "$alert_date" "$ACTIVE_INCIDENT_ID" "$ACTIVE_INCIDENT_STARTED_AT" \
                "$name" "${status^^}" "$message" \
                "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"
        else
            subject="VaultWarden Health [${status^^}]: ${name} on $(hostname)"
            printf -v body \
                'Health check alert at %s\n\nCheck: %s\nStatus: %s\nDetail: %s\n\nThis alert will not repeat for %ss (%s min).\nFor the full live status, run: ./maintenance.sh health\nTo also write a report file, run: ./maintenance.sh health --report' \
                "$alert_date" "$name" "${status^^}" "$message" \
                "$ALERT_COOLDOWN_SECONDS" "$(( ALERT_COOLDOWN_SECONDS / 60 ))"
        fi
        if ! _send_notification "$subject" "$body"; then
            log_warn "_notify_failures: delivery failed for '${name}' — releasing cooldown for retry next cycle"
            _release_alert_lock "$name"
            continue
        fi
        alerted_any=true
        log_info "Alert sent for '${name}' (${status})"
    done
    if [[ "$alerted_any" == "true" ]]; then
        log_debug "_notify_failures: at least one alert was sent this cycle"
    fi
    if [[ $failed -gt 0 || $warnings -gt 0 ]]; then
        _release_recovery_lock
    fi
    return 0
}

_recovery_close_active_incident() {
    local incident_id="$1" recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"

    if [[ ! -e "$ACTIVE_INCIDENT_FILE" && ! -L "$ACTIVE_INCIDENT_FILE" ]]; then
        return 0
    fi
    if [[ ! -f "$ACTIVE_INCIDENT_FILE" || -L "$ACTIVE_INCIDENT_FILE" ]]; then
        log_warn "Recovery email for incident '${incident_id}' was delivered, but active incident state '${ACTIVE_INCIDENT_FILE}' is not a regular file. The delivered marker is retained so later cycles will not resend; resolve the filesystem error and rerun health to retry closure."
        return 1
    fi
    _state_destination_is_safe "$recovered_file" "Recovered incident evidence" || {
        log_warn "Recovery email for incident '${incident_id}' was delivered, but recovered incident destination '${recovered_file}' is invalid. The delivered marker is retained so later cycles will not resend; resolve the filesystem error and rerun health to retry closure."
        return 1
    }
    if ! mv -fT -- "$ACTIVE_INCIDENT_FILE" "$recovered_file"; then
        log_warn "Recovery email for incident '${incident_id}' was delivered, but the active incident could not be archived from '${ACTIVE_INCIDENT_FILE}' to '${recovered_file}'. The delivered marker is retained so later cycles will not resend; resolve the filesystem error and rerun health to retry closure."
        return 1
    fi

    if ! rm -f -- "$recovered_file"; then
        log_warn "Recovery email for incident '${incident_id}' was delivered and the active incident was closed, but recovered incident cleanup failed; bounded evidence remains at '${recovered_file}'. Review and remove this file manually."
    fi
    return 0
}

_notify_recovery_locked() {
    local incident_id state_rc=0 state_path recovery_date recovery_time subject body
    local started_epoch recovery_epoch duration prior_lines="" name rc=0

    if [[ ! -e "$ACTIVE_INCIDENT_FILE" && ! -L "$ACTIVE_INCIDENT_FILE" ]]; then
        log_debug "No active health incident — recovery notification not applicable"
        return 0
    fi
    if ! _incident_load "$ACTIVE_INCIDENT_FILE"; then
        log_warn "Active health incident state is unreadable or invalid; preserving '${ACTIVE_INCIDENT_FILE}' and suppressing recovery notification."
        return 1
    fi

    incident_id="$ACTIVE_INCIDENT_ID"
    state_path="$(_recovery_delivery_state_path)"
    if _recovery_delivery_state_load; then
        if [[ "$RECOVERY_DELIVERY_INCIDENT_ID" == "$incident_id" ]]; then
            case "$RECOVERY_DELIVERY_PHASE" in
                delivered)
                    log_info "Recovery notification for incident '${incident_id}' was already delivered; suppressing duplicate delivery and retrying incident closure."
                    _recovery_close_active_incident "$incident_id" || return 1
                    if ! _recovery_delivery_state_clear "$incident_id"; then
                        log_warn "Incident '${incident_id}' is closed, but its delivered recovery marker could not be removed from '${state_path}'. A new incident is not blocked because delivery state is incident-scoped."
                    fi
                    return 0
                    ;;
                pending)
                    if _recovery_pending_is_recent "$RECOVERY_DELIVERY_UPDATED_AT"; then
                        log_info "Recovery notification for incident '${incident_id}' already has a recent pending delivery lease — suppressing a concurrent duplicate attempt."
                        return 0
                    fi
                    log_warn "Stale recovery delivery lease found for incident '${incident_id}'; treating it as an abandoned pre-delivery attempt and retrying."
                    _release_recovery_lock
                    ;;
            esac
        else
            log_debug "Ignoring recovery delivery state for older incident '${RECOVERY_DELIVERY_INCIDENT_ID}' while processing '${incident_id}'."
        fi
    else
        state_rc=$?
        if (( state_rc == 2 )); then
            log_warn "Recovery delivery state '${state_path}' is unreadable or invalid; preserving it and suppressing recovery delivery to avoid a silent duplicate. Repair or remove the file after confirming delivery history."
            return 1
        fi
    fi

    if ! _acquire_alert_lock recovery "${ALERT_RECOVERY_TTL}"; then
        log_info "Recovery notification already sent within TTL — suppressing"
        return 0
    fi
    if ! _recovery_delivery_state_write pending "$incident_id"; then
        _release_recovery_lock
        log_warn "Recovery notification for incident '${incident_id}' was not attempted because its pending delivery lease could not be persisted; cooldown released for retry next health cycle."
        return 1
    fi

    recovery_date="$(date)"
    recovery_time="$(date -Iseconds)"
    started_epoch="$(date -d "$ACTIVE_INCIDENT_STARTED_AT" +%s 2>/dev/null || printf '')"
    recovery_epoch="$(date -d "$recovery_time" +%s 2>/dev/null || date +%s)"
    if [[ "$started_epoch" =~ ^[0-9]+$ && "$recovery_epoch" =~ ^[0-9]+$ && "$recovery_epoch" -ge "$started_epoch" ]]; then
        duration="$(_incident_format_duration "$(( recovery_epoch - started_epoch ))")"
    else
        duration="unknown"
    fi
    for name in "${incident_check_order[@]}"; do
        printf -v prior_lines '%s- %s [%s]: %s\n' \
            "$prior_lines" "$name" "${incident_statuses[$name]^^}" "${incident_details[$name]}"
    done

    subject="VaultWarden Health RECOVERED [Incident ${incident_id}] on $(hostname)"
    printf -v body \
        'All health checks passed at %s\n\nIncident: %s\nIncident started: %s\nLast unhealthy observation: %s\nRecovered: %s\nDuration: %s\nHost: %s\n\nPreviously unhealthy checks:\n%s\nCurrent totals:\nPassed : %s\nWarnings: %s\nFailed : %s\n\nNo further alerts will fire until the next failure.' \
        "$recovery_date" "$incident_id" "$ACTIVE_INCIDENT_STARTED_AT" \
        "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT" "$recovery_time" "$duration" \
        "$ACTIVE_INCIDENT_HOSTNAME" "$prior_lines" "$passed" "$warnings" "$failed"

    if ! _send_notification "$subject" "$body"; then
        if ! _recovery_delivery_state_clear "$incident_id"; then
            log_warn "Recovery delivery failed for incident '${incident_id}', and its pending lease could not be cleared; retry is deferred until the lease expires or the state file is repaired."
        fi
        _release_recovery_lock
        log_warn "Recovery notification delivery failed; cooldown released for retry next health cycle"
        return 1
    fi

    log_info "Recovery notification sent"
    if _recovery_delivery_state_write delivered "$incident_id"; then
        _recovery_close_active_incident "$incident_id" || return 1
        if ! _recovery_delivery_state_clear "$incident_id"; then
            log_warn "Incident '${incident_id}' is closed, but its delivered recovery marker could not be removed from '${state_path}'. A new incident is not blocked because delivery state is incident-scoped."
        fi
        return 0
    fi

    log_warn "Recovery email for incident '${incident_id}' was delivered, but the delivered marker could not be persisted. Attempting immediate incident closure to prevent a later duplicate."
    rc=1
    if _recovery_close_active_incident "$incident_id"; then
        if ! _recovery_delivery_state_clear "$incident_id"; then
            log_warn "Incident '${incident_id}' is closed, but its pending recovery marker could not be removed from '${state_path}'."
        fi
    else
        log_warn "Recovery email for incident '${incident_id}' was delivered, but neither the delivered marker nor incident closure could be persisted. The pending lease is retained; after it becomes stale, delivery status is ambiguous and operator remediation is required to avoid a possible duplicate."
    fi
    return "$rc"
}

_notify_recovery() {
    local lock_path rc

    [[ $failed -eq 0 && $warnings -eq 0 ]] || return 0
    if [[ ! -e "$ACTIVE_INCIDENT_FILE" && ! -L "$ACTIVE_INCIDENT_FILE" ]]; then
        log_debug "No active health incident — recovery notification not applicable"
        return 0
    fi

    lock_path="$(_recovery_lock_path)"
    if _recovery_lock_acquire "$lock_path"; then
        :
    else
        rc=$?
        if (( rc == 75 )); then
            log_info "Another recovery notification attempt is already in progress — suppressing a concurrent duplicate attempt."
            return 0
        fi
        return 1
    fi

    if _notify_recovery_locked; then
        rc=0
    else
        rc=$?
    fi
    _recovery_lock_release
    return "$rc"
}