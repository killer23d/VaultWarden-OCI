#!/usr/bin/env bash

# Shared health incident and recovery-notification state helpers.
#
# This file is source-only. The caller supplies log_debug, log_info, log_warn,
# and _send_notification. The helpers intentionally use Bash dynamic scope for
# the health-run state: ALERT_LOCK_DIR, ACTIVE_INCIDENT_FILE,
# RECOVERY_DELIVERY_STATE_FILE, ALERT_COOLDOWN_SECONDS,
# ALERT_RECOVERY_TTL, ALERT_RECOVERY_PENDING_TTL, failed, warnings, passed,
# ACTIVE_INCIDENT_*, the incident_* collections, and for unhealthy updates
# check_order, check_results, and check_messages.
#
# Delivery guarantee: after a delivered marker is atomically persisted for
# incident X, later healthy cycles never send another recovery email for X even
# if incident closure keeps failing. SMTP success followed by a crash or
# filesystem failure before that delivered transition is persisted is
# inherently ambiguous; a stale pending lease eventually permits retry rather
# than suppressing recovery forever.

_ensure_alert_dir() {
    [[ -d "${ALERT_LOCK_DIR}" ]] && return 0

    if mkdir -p "${ALERT_LOCK_DIR}" 2>/dev/null; then
        chmod 0750 "${ALERT_LOCK_DIR}" 2>/dev/null || true
        return 0
    fi

    log_warn "_ensure_alert_dir: cannot create '${ALERT_LOCK_DIR}'" \
        "— health alert state tracking is disabled for this cycle." \
        "Fix: sudo mkdir -p '${ALERT_LOCK_DIR}' && sudo chown $(id -un) '${ALERT_LOCK_DIR}'"
    return 1
}

_acquire_alert_lock() {
    local key="$1" safe_key state_file ttl now last_sent tmp_file

    safe_key="$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')"
    _ensure_alert_dir || return 1

    state_file="${ALERT_LOCK_DIR}/${safe_key}.cooldown"
    ttl="${2:-${ALERT_COOLDOWN_SECONDS:-3600}}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=3600
    now="$(date +%s)"

    if [[ -f "$state_file" ]]; then
        last_sent="$(cat -- "$state_file" 2>/dev/null || printf '0')"
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        if (( last_sent > now || now - last_sent < ttl )); then
            return 1
        fi
    fi

    tmp_file="$(mktemp "${ALERT_LOCK_DIR}/.tmp.XXXXXXXXXX")" || {
        log_warn "_acquire_alert_lock: mktemp failed in '${ALERT_LOCK_DIR}' — skipping alert for '${key}'"
        return 1
    }
    printf '%s\n' "$now" > "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    mv -f -- "$tmp_file" "$state_file" || { rm -f -- "$tmp_file"; return 1; }
    return 0
}

_release_alert_lock() {
    local key="$1" safe_key

    safe_key="$(printf '%s' "$key" | tr -cs '[:alnum:]-' '_')"
    rm -f -- "${ALERT_LOCK_DIR}/${safe_key}.cooldown" 2>/dev/null || true
}

_release_recovery_lock() {
    rm -f -- "${ALERT_LOCK_DIR}/recovery.cooldown" 2>/dev/null || true
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
    local line record key value detail rest name sanitized size
    local seen_incident_id=0 seen_started_at=0 seen_last_unhealthy_at=0 seen_hostname=0
    local -A seen_checks=()

    _incident_reset_loaded_state
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
    size="$(wc -c < "$path" 2>/dev/null || printf '999999')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -le 16384 ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
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
                sanitized="$(_incident_sanitize "$rest" 64)"
                [[ -n "$sanitized" && "$sanitized" == "$rest" ]] || return 1
                ACTIVE_INCIDENT_STARTED_AT="$sanitized"
                seen_started_at=1
                ;;
            meta:last_unhealthy_at)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_last_unhealthy_at == 0 )) || return 1
                sanitized="$(_incident_sanitize "$rest" 64)"
                [[ "$sanitized" == "$rest" ]] || return 1
                ACTIVE_INCIDENT_LAST_UNHEALTHY_AT="$sanitized"
                seen_last_unhealthy_at=1
                ;;
            meta:hostname)
                [[ "$rest" != *$'\t'* ]] || return 1
                (( seen_hostname == 0 )) || return 1
                sanitized="$(_incident_sanitize "$rest" 255)"
                [[ "$sanitized" == "$rest" ]] || return 1
                ACTIVE_INCIDENT_HOSTNAME="$sanitized"
                seen_hostname=1
                ;;
            check:*)
                [[ "$rest" == *$'\t'* ]] || return 1
                value="${rest%%$'\t'*}"
                detail="${rest#*$'\t'}"
                [[ "$detail" != *$'\t'* ]] || return 1
                name="$(_incident_sanitize "$key" 128)"
                [[ -n "$name" && "$name" == "$key" ]] || return 1
                [[ "$value" == "warn" || "$value" == "fail" ]] || return 1
                [[ -z "${seen_checks[$name]+set}" ]] || return 1
                seen_checks["$name"]=1
                _incident_set_check "$name" "$value" "$(_incident_sanitize "$detail" 512)"
                ;;
            *)
                return 1
                ;;
        esac
    done < "$path"

    (( seen_incident_id == 1 && seen_started_at == 1 )) || return 1
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_write() {
    local tmp_file old_umask line name bytes=0 max_bytes=16384

    if ! _ensure_alert_dir; then
        log_warn "Health incident context unavailable: alert-state directory is not writable; continuing without incident correlation."
        return 1
    fi

    _incident_id_is_valid "$ACTIVE_INCIDENT_ID" || return 1
    old_umask="$(umask)"
    umask 077
    tmp_file="$(mktemp "${ALERT_LOCK_DIR}/.active-incident.XXXXXXXX")" || {
        umask "$old_umask"
        log_warn "Health incident context unavailable: cannot create state in '${ALERT_LOCK_DIR}'; continuing without incident correlation."
        return 1
    }
    umask "$old_umask"

    chmod 0600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    {
        printf 'meta\tincident_id\t%s\n' "$ACTIVE_INCIDENT_ID"
        printf 'meta\tstarted_at\t%s\n' "$ACTIVE_INCIDENT_STARTED_AT"
        printf 'meta\tlast_unhealthy_at\t%s\n' "$ACTIVE_INCIDENT_LAST_UNHEALTHY_AT"
        printf 'meta\thostname\t%s\n' "$ACTIVE_INCIDENT_HOSTNAME"
    } > "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }

    bytes="$(wc -c < "$tmp_file")"
    for name in "${incident_check_order[@]}"; do
        printf -v line 'check\t%s\t%s\t%s\n' \
            "$name" "${incident_statuses[$name]}" "${incident_details[$name]}"
        if (( bytes + ${#line} > max_bytes )); then
            log_warn "Health incident context reached ${max_bytes} bytes; additional check details were omitted."
            break
        fi
        printf '%s' "$line" >> "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
        (( bytes += ${#line} )) || true
    done

    mv -f -- "$tmp_file" "$ACTIVE_INCIDENT_FILE" || { rm -f -- "$tmp_file"; return 1; }
    chmod 0600 "$ACTIVE_INCIDENT_FILE" 2>/dev/null || true
    ACTIVE_INCIDENT_AVAILABLE=true
}

_incident_update_unhealthy() {
    local now name original_name status detail

    (( failed > 0 || warnings > 0 )) || return 0
    now="$(date -Iseconds)"
    if [[ -e "$ACTIVE_INCIDENT_FILE" ]]; then
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

    [[ -e "$path" ]] || return 1
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 2
    size="$(wc -c < "$path" 2>/dev/null || printf '999999')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -le 512 ]] || return 2

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
    local path tmp_file old_umask

    path="$(_recovery_delivery_state_path)"
    [[ "$phase" == "pending" || "$phase" == "delivered" ]] || return 1
    _incident_id_is_valid "$incident_id" || return 1
    [[ -n "$updated_at" ]] || updated_at="$(date +%s)"
    [[ "$updated_at" =~ ^[0-9]+$ ]] || return 1
    _ensure_alert_dir || return 1
    [[ "$(dirname -- "$path")" == "$ALERT_LOCK_DIR" ]] || return 1

    old_umask="$(umask)"
    umask 077
    tmp_file="$(mktemp "${ALERT_LOCK_DIR}/.recovery-delivery.XXXXXXXX")" || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"

    chmod 0600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    printf 'v1\t%s\t%s\t%s\n' "$phase" "$incident_id" "$updated_at" \
        > "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    if ! mv -f -- "$tmp_file" "$path"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    chmod 0600 "$path" 2>/dev/null || true

    RECOVERY_DELIVERY_PHASE="$phase"
    RECOVERY_DELIVERY_INCIDENT_ID="$incident_id"
    RECOVERY_DELIVERY_UPDATED_AT="$updated_at"
}

_recovery_delivery_state_clear() {
    local expected_incident_id="${1:-}" path load_rc=0

    path="$(_recovery_delivery_state_path)"
    [[ -e "$path" ]] || return 0

    if _recovery_delivery_state_load; then
        if [[ -n "$expected_incident_id" && "$RECOVERY_DELIVERY_INCIDENT_ID" != "$expected_incident_id" ]]; then
            return 0
        fi
    else
        load_rc=$?
        (( load_rc == 1 )) && return 0
        return 1
    fi

    rm -f -- "$path" || return 1
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

_recovery_close_active_incident() {
    local incident_id="$1" recovered_file="${ACTIVE_INCIDENT_FILE}.recovered"

    [[ -e "$ACTIVE_INCIDENT_FILE" ]] || return 0
    if ! mv -f -- "$ACTIVE_INCIDENT_FILE" "$recovered_file"; then
        log_warn "Recovery email for incident '${incident_id}' was delivered, but the active incident could not be archived from '${ACTIVE_INCIDENT_FILE}' to '${recovered_file}'. The delivered marker is retained so later cycles will not resend; resolve the filesystem error and rerun health to retry closure."
        return 1
    fi

    chmod 0600 "$recovered_file" 2>/dev/null || true
    if ! rm -f -- "$recovered_file"; then
        log_warn "Recovery email for incident '${incident_id}' was delivered and the active incident was closed, but recovered incident cleanup failed; bounded evidence remains at '${recovered_file}'. Review and remove this file manually."
    fi
    return 0
}

_notify_recovery_locked() {
    local incident_id state_rc=0 state_path recovery_date recovery_time subject body
    local started_epoch recovery_epoch duration prior_lines="" name

    if [[ ! -e "$ACTIVE_INCIDENT_FILE" ]]; then
        log_debug "No active health incident — recovery notification not applicable"
        return 0
    fi
    if ! _incident_load "$ACTIVE_INCIDENT_FILE"; then
        log_warn "Active health incident state is unreadable or invalid; preserving '${ACTIVE_INCIDENT_FILE}' and suppressing recovery notification."
        return 0
    fi

    incident_id="$ACTIVE_INCIDENT_ID"
    state_path="$(_recovery_delivery_state_path)"
    if _recovery_delivery_state_load; then
        if [[ "$RECOVERY_DELIVERY_INCIDENT_ID" == "$incident_id" ]]; then
            case "$RECOVERY_DELIVERY_PHASE" in
                delivered)
                    log_info "Recovery notification for incident '${incident_id}' was already delivered; suppressing duplicate delivery and retrying incident closure."
                    if _recovery_close_active_incident "$incident_id"; then
                        if ! _recovery_delivery_state_clear "$incident_id"; then
                            log_warn "Incident '${incident_id}' is closed, but its delivered recovery marker could not be removed from '${state_path}'. A new incident is not blocked because delivery state is incident-scoped."
                        fi
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
            return 0
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
        if _recovery_close_active_incident "$incident_id"; then
            if ! _recovery_delivery_state_clear "$incident_id"; then
                log_warn "Incident '${incident_id}' is closed, but its delivered recovery marker could not be removed from '${state_path}'. A new incident is not blocked because delivery state is incident-scoped."
            fi
        fi
        return 0
    fi

    log_warn "Recovery email for incident '${incident_id}' was delivered, but the delivered marker could not be persisted. Attempting immediate incident closure to prevent a later duplicate."
    if _recovery_close_active_incident "$incident_id"; then
        if ! _recovery_delivery_state_clear "$incident_id"; then
            log_warn "Incident '${incident_id}' is closed, but its pending recovery marker could not be removed from '${state_path}'."
        fi
    else
        log_warn "Recovery email for incident '${incident_id}' was delivered, but neither the delivered marker nor incident closure could be persisted. The pending lease is retained; after it becomes stale, delivery status is ambiguous and operator remediation is required to avoid a possible duplicate."
    fi
    return 0
}

_notify_recovery() {
    local lock_file lock_fd old_umask rc

    [[ $failed -eq 0 && $warnings -eq 0 ]] || return 0
    if [[ ! -e "$ACTIVE_INCIDENT_FILE" ]]; then
        log_debug "No active health incident — recovery notification not applicable"
        return 0
    fi

    lock_file="${ALERT_LOCK_DIR}/recovery-delivery.lock"
    _ensure_alert_dir || return 1
    old_umask="$(umask)"
    umask 077
    if ! exec {lock_fd}> "$lock_file"; then
        umask "$old_umask"
        log_warn "Recovery notification suppressed because the delivery lock '${lock_file}' could not be opened."
        return 1
    fi
    umask "$old_umask"
    chmod 0600 "$lock_file" 2>/dev/null || true

    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        log_info "Another recovery notification attempt is already in progress — suppressing a concurrent duplicate attempt."
        return 0
    fi

    if _notify_recovery_locked; then
        rc=0
    else
        rc=$?
    fi
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-
    return "$rc"
}