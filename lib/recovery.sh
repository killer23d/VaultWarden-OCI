#!/usr/bin/env bash
# lib/recovery.sh — pure validation and recovery helpers.

[[ -n "${VW_RECOVERY_LIB_LOADED:-}" ]] && return 0
readonly VW_RECOVERY_LIB_LOADED=1
_RECOVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_RECOVERY_LIB_DIR}/log.sh"
[[ -n "${VW_CONFIG_LIB_LOADED:-}" ]] || source "${_RECOVERY_LIB_DIR}/config.sh"
unset _RECOVERY_LIB_DIR

_recovery_read_env_key() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); found=1} END {exit found?0:1}' "$file"
}

validate_state_manifest() {
    local state_dir="$1" require_mount="${2:-true}"
    local manifest="${state_dir}/config/dr-manifest.env" sentinel="${state_dir}/.vw-state-volume"
    [[ "$require_mount" != true ]] || mountpoint -q "$state_dir" || { log_error "State dir is not a mount point: $state_dir"; return 1; }
    [[ -r "$manifest" ]] || { log_error "Missing recovery manifest: $manifest"; return 1; }
    [[ -r "$sentinel" ]] || { log_error "Missing state sentinel: $sentinel"; return 1; }
    local layout expected mid sid
    layout=$(_recovery_read_env_key "$manifest" STATE_LAYOUT_VERSION || true)
    [[ "$layout" == 2 ]] || { log_error "Unsupported STATE_LAYOUT_VERSION: ${layout:-missing}"; return 1; }
    expected=$(_recovery_read_env_key "$manifest" EXPECTED_STATE_DIR || true)
    [[ "$expected" == "$state_dir" ]] || { log_error "EXPECTED_STATE_DIR mismatch: manifest '$expected' != '$state_dir'"; return 1; }
    mid=$(_recovery_read_env_key "$manifest" INSTALLATION_ID || true)
    sid=$(_recovery_read_env_key "$sentinel" INSTALLATION_ID || true)
    [[ -n "$mid" && "$mid" == "$sid" ]] || { log_error "INSTALLATION_ID mismatch between manifest and sentinel"; return 1; }
}

verify_age_key_decrypts_state() {
    local state_dir="$1" age_key_file="$2"
    [[ -r "$age_key_file" ]] || { log_error "Age key file is not readable: $age_key_file"; return 1; }
    local secrets_file="${state_dir}/secrets/secrets.sops.yaml"
    [[ -r "$secrets_file" ]] || { log_error "Secrets file missing: $secrets_file"; return 1; }
    SOPS_AGE_KEY_FILE="$age_key_file" sops -d "$secrets_file" >/dev/null
}

install_recovery_age_key() {
    local src="$1" dest="${2:-/etc/vaultwarden/age-key.txt}"
    install -d -m 0700 "$(dirname "$dest")"
    install -m 0600 -o root -g root "$src" "$dest"
}

run_recovery() {
    local state_dir="" age_key_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state-dir) state_dir="${2:-}"; shift 2 ;;
            --age-key-file) age_key_file="${2:-}"; shift 2 ;;
            *) log_error "Unknown recover option: $1"; return 1 ;;
        esac
    done
    [[ -n "$state_dir" ]] || { log_error "recover requires --state-dir"; return 1; }
    [[ -n "$age_key_file" ]] || { log_error "recover requires --age-key-file"; return 1; }
    validate_state_manifest "$state_dir" true || return 1
    PROJECT_STATE_DIR="$state_dir" load_install_env "${state_dir}/config/install.env" || return 1
    verify_age_key_decrypts_state "$state_dir" "$age_key_file" || return 1
    install_recovery_age_key "$age_key_file" || return 1
    log_info "Regenerating host, systemd, and CrowdSec configuration (host-only steps follow)."
    materialize_runtime_secrets "${_VW_RUNTIME_SECRETS_DIR}" "${state_dir}/secrets/secrets.sops.yaml" || return 1
    vw_compose up -d --remove-orphans || return 1
    log_success "Recovery completed for state dir: $state_dir"
}
