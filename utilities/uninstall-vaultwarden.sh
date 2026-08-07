#!/usr/bin/env bash
# Stable uninstall entrypoint.
#
# The bulk implementation is kept in uninstall-vaultwarden-core.sh. This thin
# layer contains only the narrow safety overrides that need to remain obvious at
# the operator-facing entrypoint.

set -euo pipefail

_UNINSTALL_ENTRYPOINT="${BASH_SOURCE[0]}"
_UNINSTALL_ENTRYPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=uninstall-vaultwarden-core.sh
source "${_UNINSTALL_ENTRYPOINT_DIR}/uninstall-vaultwarden-core.sh"

# Detached devices cannot be re-probed for UUID. Only accept the exact fstab
# shape written by setup-storage; mountpoint alone is not ownership proof.
_fstab_has_setup_mount_signature() {
    local mountpoint="$1"
    [[ -n "$mountpoint" && -f "$FSTAB_FILE" ]] || return 1
    awk -v mp="$mountpoint" '
        /^[[:space:]]*($|#)/ { next }
        $2 == mp && $1 ~ /^UUID=/ && ($3 == "ext4" || $3 == "xfs") {
            noatime=nofail=timeout=0
            n=split($4, opt, ",")
            for (i=1; i<=n; i++) {
                if (opt[i] == "noatime") noatime=1
                if (opt[i] == "nofail") nofail=1
                if (opt[i] == "x-systemd.device-timeout=30s") timeout=1
            }
            if (noatime && nofail && timeout) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$FSTAB_FILE"
}

_remove_fstab_mount() {
    local mountpoint="$1" source="${2:-}" uuid="${3:-}"
    [[ -n "$mountpoint" && -f "$FSTAB_FILE" ]] || return 0

    local tmp count identity_available=false
    [[ -n "$source" && ( -e "$source" || -L "$source" ) ]] && identity_available=true
    [[ -n "$uuid" ]] && identity_available=true
    count="$(_fstab_mount_entry_count "$mountpoint")"

    if _fstab_has_configured_volume_entry "$mountpoint" "$source" "$uuid"; then
        tmp="$(mktemp "${FSTAB_FILE}.vw-uninstall.XXXXXXXXXX")" || return 1
        if awk -v mp="$mountpoint" -v src="$source" -v uuid="$uuid" '
            !(($2 == mp) && ((src != "" && $1 == src) || (uuid != "" && $1 == "UUID=" uuid))) { print }
        ' "$FSTAB_FILE" > "$tmp" && mv -f "$tmp" "$FSTAB_FILE"; then
            success "Removed positively identified fstab entry for configured data volume."
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if [[ "$identity_available" != "true" && "$count" == "1" ]] \
        && _fstab_has_setup_mount_signature "$mountpoint"; then
        tmp="$(mktemp "${FSTAB_FILE}.vw-uninstall.XXXXXXXXXX")" || return 1
        if awk -v mp="$mountpoint" '!(($2 == mp) && $0 !~ /^[[:space:]]*#/) { print }' "$FSTAB_FILE" > "$tmp" \
            && mv -f "$tmp" "$FSTAB_FILE"; then
            warn "Data device is unavailable, so UUID identity could not be re-derived."
            success "Removed the single setup-signature fstab entry at configured mountpoint: $mountpoint"
            return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if [[ "$count" == "0" ]] && ! _fstab_has_configured_source_entry "$source" "$uuid"; then
        info "No fstab entry found for configured data volume."
        return 0
    fi

    warn "Preserving ambiguous fstab entry for $mountpoint."
    warn "Expected a source/UUID match or one setup-signature entry at the configured mountpoint; found mountpoint count=$count."
    return 1
}

# Repo-local secrets are removed by test-reset and by the retained-checkout
# cleanup path, so their Age key must always stay inside the recovery guard.
_age_key_will_be_deleted() {
    local key="$1"
    _path_is_inside "$key" "$ETC_VAULTWARDEN_DIR" && return 0
    _path_is_inside "$key" "${PROJECT_DIR}/secrets" && return 0
    if _path_is_inside "$key" "$PROJECT_DIR"; then
        [[ "$TEST_RESET" == "true" ]] && return 0
        if ! (_backup_dir_is_external_to_state 2>/dev/null \
            && _path_is_inside "$BACKUP_DIR" "$PROJECT_DIR" 2>/dev/null \
            && [[ -d "$BACKUP_DIR" ]]); then
            return 0
        fi
    fi
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]] && _path_is_inside "$key" "$PROJECT_STATE_DIR"; then
        return 0
    fi
    return 1
}

if [[ "$_UNINSTALL_ENTRYPOINT" == "$0" ]]; then
    main "$@"
fi
