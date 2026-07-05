#!/usr/bin/env bash
# Restart the stack without pulling images and restore the pre-restart compose
# model plus image IDs if startup or health checks fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Safe Restart

USAGE:
    sudo make safe-restart

DESCRIPTION:
    Captures the resolved Compose model and current local image IDs, restarts
    without pulling, and restores the captured model and image tags if startup
    or health checks fail.

    This restores container configuration and images only. It does not reverse
    database migrations, host package changes, or operator-edited data.
EOF
}

case "${1:-}" in
    --help|-h|help)
        show_help
        exit 0
        ;;
    "") ;;
    *)
        log_error "Unknown option: $1"
        show_help >&2
        exit 2
        ;;
esac

if [[ $EUID -ne 0 ]]; then
    log_error "safe-restart requires root. Run: sudo make safe-restart"
    exit 1
fi

_safe_restart_policy="fail"
if [[ ! -t 0 || ! -t 1 ]]; then
    _safe_restart_policy="skip"
fi
operation_acquire \
    --id startup \
    --label "Safe restart" \
    --non-interactive "$_safe_restart_policy" || exit $?
_safe_restart_operation_cleanup() {
    local rc=$?
    operation_release "$rc"
    rm -rf "${rollback_dir:-}" 2>/dev/null || true
    exit "$rc"
}
trap _safe_restart_operation_cleanup EXIT
trap 'operation_release 130; rm -rf "${rollback_dir:-}" 2>/dev/null || true; exit 130' INT
trap 'operation_release 143; rm -rf "${rollback_dir:-}" 2>/dev/null || true; exit 143' HUP TERM
operation_set_phase "snapshot" "Capturing safe-restart rollback state"

command -v docker >/dev/null 2>&1 || {
    log_error "docker is not installed."
    exit 1
}

rollback_dir=$(mktemp -d -p /dev/shm 2>/dev/null \
               || mktemp -d -t vaultwarden-safe-restart.XXXXXXXXXX) || {
    log_error "Could not create a secure rollback directory."
    exit 1
}
chmod 700 "$rollback_dir"
compose_snapshot="${rollback_dir}/compose.yaml"
image_snapshot="${rollback_dir}/images.tsv"

log_info "Capturing the current resolved Compose model and local image IDs..."
docker compose config > "$compose_snapshot" || {
    log_error "Current Compose configuration is invalid; restart was not attempted."
    exit 1
}
chmod 600 "$compose_snapshot"

: > "$image_snapshot"
while IFS= read -r image_ref; do
    [[ -n "$image_ref" ]] || continue
    image_id=$(docker image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
    printf '%s\t%s\n' "$image_ref" "$image_id" >> "$image_snapshot"
done < <(docker compose config --images | sort -u)
chmod 600 "$image_snapshot"

log_info "Restarting with the existing image set (--skip-pull)..."
operation_set_phase "startup" "Running guarded startup"
if "${PROJECT_ROOT}/startup.sh" --force --skip-pull; then
    log_success "Safe restart completed successfully."
    exit 0
fi

log_error "Restart failed; restoring the pre-restart image tags and Compose model."
operation_set_phase "rollback" "Restoring pre-restart Compose state"
rollback_failed=false
while IFS=$'\t' read -r image_ref image_id; do
    [[ -n "$image_ref" && -n "$image_id" ]] || continue
    if ! docker image tag "$image_id" "$image_ref"; then
        log_error "Could not restore image tag ${image_ref} to ${image_id}."
        rollback_failed=true
    fi
done < "$image_snapshot"

if ! docker compose \
        --project-directory "$PROJECT_ROOT" \
        -f "$compose_snapshot" \
        up -d --force-recreate --no-build --pull never; then
    log_error "Rollback Compose start failed. Manual recovery is required."
    rollback_failed=true
fi

if [[ "$rollback_failed" == "true" ]]; then
    log_error "Rollback was incomplete. Inspect: docker compose ps && docker compose logs"
    exit 2
fi

# Internal rollback validation; direct health commands still refuse root.
if VAULTWARDEN_INTERNAL_HEALTH_CHECK=true "${PROJECT_ROOT}/utilities/maintenance-health.sh" health; then
    log_warn "Rollback succeeded and the previous stack is healthy."
else
    log_error "Rollback containers started, but the health check still reports failures."
    exit 2
fi

# The requested restart did not succeed even though rollback recovered service.
exit 1
