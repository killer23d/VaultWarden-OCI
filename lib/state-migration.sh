#!/usr/bin/env bash
# lib/state-migration.sh — non-destructive legacy state copy helpers.
[[ -n "${VW_STATE_MIGRATION_LIB_LOADED:-}" ]] && return 0
readonly VW_STATE_MIGRATION_LIB_LOADED=1
_MIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source "${_MIG_LIB_DIR}/log.sh"
[[ -n "${VW_CONFIG_LIB_LOADED:-}" ]] || source "${_MIG_LIB_DIR}/config.sh"
source "${_MIG_LIB_DIR}/recovery.sh"
unset _MIG_LIB_DIR

migrate_legacy_state_copy() {
    local state_dir="${1:-${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR}}}"
    local install_id="${INSTALLATION_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
    install -d -m 0700 "$state_dir/config" "$state_dir/secrets" "$state_dir/data" "$state_dir/caddy" "$state_dir/logs" "$state_dir/backups"
    [[ -f "${PROJECT_ROOT}/.env" ]] && install -m 0600 "${PROJECT_ROOT}/.env" "$state_dir/config/install.env"
    [[ -f "${PROJECT_ROOT}/.sops.yaml" ]] && install -m 0600 "${PROJECT_ROOT}/.sops.yaml" "$state_dir/config/sops-policy.yaml"
    [[ -f "${PROJECT_ROOT}/secrets/secrets.yaml" ]] && install -m 0600 "${PROJECT_ROOT}/secrets/secrets.yaml" "$state_dir/secrets/secrets.sops.yaml"
    cat > "$state_dir/config/dr-manifest.env" <<MANIFEST
STATE_LAYOUT_VERSION=2
REPO_URL=${REPO_URL:-killer23d/VaultWarden-OCI}
REPO_REF=${REPO_REF:-delta}
STATE_VOLUME_UUID=${STATE_VOLUME_UUID:-unknown}
STATE_VOLUME_ID=${STATE_VOLUME_ID:-}
EXPECTED_STATE_DIR=$state_dir
INSTALLATION_ID=$install_id
MANIFEST
    chmod 0600 "$state_dir/config/dr-manifest.env"
    printf 'INSTALLATION_ID=%s\n' "$install_id" > "$state_dir/.vw-state-volume"
    chmod 0600 "$state_dir/.vw-state-volume"
    local failed=0
    [[ -r "$state_dir/config/install.env" ]] && load_install_env "$state_dir/config/install.env" || failed=1
    if [[ -f "$state_dir/config/install.env" ]] && grep -Eq '(PASSWORD|TOKEN|SECRET|PRIVATE_KEY|API_KEY|PASSPHRASE)=' "$state_dir/config/install.env"; then
        log_error "install.env contains credential-like keys; operator review required"; failed=1
    fi
    [[ -r "$state_dir/config/sops-policy.yaml" && -r "$state_dir/secrets/secrets.sops.yaml" ]] || failed=1
    [[ $failed -eq 0 ]] && log_success "Persistent state copied and validated. Legacy files were retained; activation is manual." || log_error "Persistent state migration validation failed. Legacy files were retained."
    return "$failed"
}
