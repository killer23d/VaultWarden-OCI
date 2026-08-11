#!/usr/bin/env bash
# lib/firewall-ufw.sh — Shared UFW parsing and policy helpers.
#
# This library owns only behavior that setup-time and periodic firewall
# reconciliation must interpret identically. Workflow-specific orchestration,
# snapshots, rollback, UFW enablement, and SSH provisioning remain with callers.

[[ -n "${VW_FIREWALL_UFW_LIB_LOADED:-}" ]] && return 0
readonly VW_FIREWALL_UFW_LIB_LOADED=1

firewall_ufw_status() {
    local mode="${1:-normal}" output rc=0
    case "$mode" in
        true|numbered) output="$(ufw status numbered 2>&1)" || rc=$? ;;
        verbose)       output="$(ufw status verbose 2>&1)" || rc=$? ;;
        added)         output="$(ufw show added 2>&1)" || rc=$? ;;
        false|normal)  output="$(ufw status 2>&1)" || rc=$? ;;
        *)
            log_error "Unknown UFW status mode: ${mode}"
            return 2
            ;;
    esac
    if (( rc != 0 )); then
        log_error "Unable to read UFW status (exit ${rc}): ${output:-no output}"
        return "$rc"
    fi
    printf '%s\n' "$output"
}

firewall_ufw_has_range_port() {
    local status="$1" cidr="$2" port="$3" line token i
    local -a fields=()

    while IFS= read -r line; do
        fields=()
        read -ra fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue
        [[ "${fields[0]}" == "${port}/tcp" ]] || continue

        i=1
        [[ "${fields[$i]:-}" == "(v6)" ]] && i=$((i + 1))
        if [[ "${fields[$i]:-}" == "on" ]]; then
            i=$((i + 2))
        fi
        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        case "${fields[$i]:-}" in
            OUT|FWD) continue ;;
            IN) i=$((i + 1)) ;;
        esac

        for (( ; i<${#fields[@]}; i++ )); do
            token="${fields[$i]}"
            [[ "$token" == \#* ]] && break
            token="${token%#*}"
            [[ "$token" == "$cidr" ]] && return 0
        done
    done <<< "$status"
    return 1
}

firewall_ufw_has_admin_port() {
    local status="$1" port="$2" line i action
    local -a fields=()

    # UFW status omits a direction token for normal inbound rules. Preserve any
    # explicit single-port TCP administrator rule unless it is OUT/FWD.
    while IFS= read -r line; do
        fields=()
        read -ra fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue
        [[ "${fields[0]}" == "${port}/tcp" ]] || continue
        i=1
        [[ "${fields[$i]:-}" == "(v6)" ]] && i=$((i + 1))
        if [[ "${fields[$i]:-}" == "on" ]]; then
            i=$((i + 2))
        fi
        action="${fields[$i]:-}"
        [[ "$action" == "ALLOW" || "$action" == "LIMIT" ]] || continue
        i=$((i + 1))
        case "${fields[$i]:-}" in
            OUT|FWD) continue ;;
            IN) i=$((i + 1)) ;;
        esac
        [[ -n "${fields[$i]:-}" && "${fields[$i]}" != \#* ]] && return 0
    done <<< "$status"
    return 1
}

firewall_ufw_line_cidr() {
    local line="$1" word
    local -a words=()
    read -ra words <<< "$line"
    for word in "${words[@]}"; do
        [[ "$word" == \#* ]] && break
        word="${word%\#*}"
        if [[ "$word" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ || "$word" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
            printf '%s\n' "$word"
            return 0
        fi
    done
    return 1
}

firewall_ufw_collect_web_conflicts() {
    local numbered_status="$1"
    shift
    local -a desired=("$@")
    local line rule_num cidr keep desired_cidr action body

    while IFS= read -r line; do
        body="${line%%#*}"
        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+(OUT|FWD)([[:space:]]|$) ]] && continue
        [[ "$body" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(80|443)(/tcp)?([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[6]}"
        if [[ -z "${BASH_REMATCH[3]}" || "$action" != "ALLOW" ]]; then
            printf '%s\n' "$rule_num"
            continue
        fi
        cidr="$(firewall_ufw_line_cidr "$line" || true)"
        keep=false
        if [[ -n "$cidr" ]]; then
            for desired_cidr in "${desired[@]}"; do
                if [[ "$desired_cidr" == "$cidr" ]]; then
                    keep=true
                    break
                fi
            done
        fi
        [[ "$keep" == "true" ]] || printf '%s\n' "$rule_num"
    done <<< "$numbered_status"
}

firewall_ufw_default_incoming_fail_closed() {
    local verbose_status="$1"
    local defaults_file="${UFW_DEFAULTS_FILE:-/etc/default/ufw}" policy=""

    if grep -Eqi '^Default:[[:space:]]+(deny|reject)[[:space:]]+\(incoming\)' <<< "$verbose_status"; then
        return 0
    fi

    if grep -Eq '^Status:[[:space:]]+inactive' <<< "$verbose_status" && [[ -r "$defaults_file" ]]; then
        policy="$(awk -F= '
            $1 ~ /^[[:space:]]*DEFAULT_INPUT_POLICY[[:space:]]*$/ {
                value=$2
                gsub(/^[[:space:]\"]+|[[:space:]\"\r]+$/, "", value)
                print toupper(value)
                exit
            }
        ' "$defaults_file")"
        case "$policy" in
            DROP|REJECT) return 0 ;;
        esac
    fi

    log_error "UFW default incoming policy is not provably fail-closed (deny/reject)."
    log_error "Remediation: sudo ufw default deny incoming; then review 'sudo ufw status verbose'."
    return 1
}

firewall_ufw_reject_ambiguous_inbound_allows() {
    local numbered_status="$1" line rule_num body
    while IFS= read -r line; do
        [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]] || continue
        rule_num="${BASH_REMATCH[1]}"
        body="${BASH_REMATCH[2]}"
        body="${body%%#*}"
        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)([[:space:]]|$) ]] || continue
        [[ "$body" =~ [[:space:]](ALLOW|LIMIT)[[:space:]]+OUT([[:space:]]|$) ]] && continue

        # A single numeric port with an explicit protocol is unambiguous. Literal
        # web-port rows are handled separately by firewall_ufw_collect_web_conflicts.
        if [[ "$body" =~ ^[0-9]+/(tcp|udp)([[:space:]]+\(v6\))?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)([[:space:]]+IN)?([[:space:]]|$) ]]; then
            continue
        fi

        log_error "Ambiguous inbound UFW allow rule ${rule_num}: ${body}"
        log_error "Use explicit single-port/protocol rules; remove application profiles, port ranges, multi-port, all-port, or routed allows before retrying."
        return 1
    done <<< "$numbered_status"
}

firewall_ufw_validate_common_safety() {
    local verbose_status="$1" numbered_status="$2"
    firewall_ufw_default_incoming_fail_closed "$verbose_status" || return $?
    firewall_ufw_reject_ambiguous_inbound_allows "$numbered_status" || return $?
}

firewall_ufw_allow_range() {
    local cidr="$1" label="$2" status output rc=0
    local dry_run="${3:-false}"

    status="$(firewall_ufw_status normal)" || return $?
    if ! firewall_ufw_has_range_port "$status" "$cidr" 80; then
        if [[ "$dry_run" == "true" ]]; then
            log_dry_run "Would allow Cloudflare ${cidr} to 80/tcp"
        else
            output="$(ufw allow proto tcp from "$cidr" to any port 80 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 80 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
    fi

    status="$(firewall_ufw_status normal)" || return $?
    if ! firewall_ufw_has_range_port "$status" "$cidr" 443; then
        if [[ "$dry_run" == "true" ]]; then
            log_dry_run "Would allow Cloudflare ${cidr} to 443/tcp"
        else
            rc=0
            output="$(ufw allow proto tcp from "$cidr" to any port 443 comment "$label" 2>&1)" || rc=$?
            if (( rc != 0 )); then
                log_error "Failed to add UFW port 443 rule for ${cidr} (exit ${rc}): ${output:-no output}"
                return "$rc"
            fi
        fi
    fi
}
