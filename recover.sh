#!/usr/bin/env bash
#recover.sh - disaster-recovery bootstrap script for restoring a VaultWarden instance from a state directory or attached data volume plus an offline Age key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
init_common_lib "$0"
source "${SCRIPT_DIR}/lib/storage.sh"
SOPS_CONFIG_FILE="${SCRIPT_DIR}/.sops.yaml"
VW_ETC_DIR="${VW_RECOVER_ETC_DIR:-/etc/vaultwarden}"
VW_STARTUP_SCRIPT="${VW_RECOVER_STARTUP_SCRIPT:-${SCRIPT_DIR}/startup.sh}"
ACTIVE_KEY="${VW_ETC_DIR}/age-key.txt"
DEV_BY_UUID_DIR="${VW_RECOVER_DEV_BY_UUID_DIR:-/dev/disk/by-uuid}"

STATE_DIR=""
STORAGE_MODE="auto"
EFFECTIVE_STORAGE_MODE=""
KEY_FILE=""
DOMAIN=""
REPO_COMMIT=""
LAYOUT=""
OFFLINE_RECIPIENT=""
USB_PUBLIC_RECIPIENT=""
NEW_PUBLIC_RECIPIENT=""
DEVICE_PATH=""
MANIFEST=""
INSTALL_ENV=""
SECRETS_FILE=""
WORKDIR=""
CIPHERTEXT_STAGING=""
POLICY_STAGING=""
NEW_PRIVATE_KEY=""
STAGED_ACTIVE_KEY=""
CIPHERTEXT_BACKUP=""
ACTIVE_KEY_BACKUP=""
POLICY_BACKUP=""
MANIFEST_BACKUP=""
CIPHERTEXT_EXISTED=false
ACTIVE_KEY_EXISTED=false
POLICY_EXISTED=false
MANIFEST_EXISTED=false
CIPHERTEXT_PROMOTED=false
KEY_PROMOTED=false
POLICY_PROMOTED=false
ROLLBACK_DONE=false

usage() {
    echo "Usage: ./recover.sh --state-dir DIR --key FILE [--storage-mode auto|boot|block]"
}

fatal() {
    echo "ERROR: $*" >&2
    exit 1
}

allow_non_root_test_mode() {
    [[ "${VW_TEST_MODE:-false}" == true && "${VW_RECOVER_TEST_ALLOW_NON_ROOT:-false}" == true ]]
}

read_env_value() {
    local key="$1" file="$2"
    awk -F= -v k="$key" '
        $1 == k {
            value = substr($0, index($0, "=") + 1)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            found = value
        }
        END { if (found != "") print found }
    ' "$file"
}

atomic_set_env() {
    local file="$1" key="$2" value="$3" tmp
    tmp=$(mktemp -p "$(dirname "$file")" env.XXXXXXXXXX) || return 1
    awk -F= -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        $1 == k { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

restore_or_remove() {
    local existed="$1" backup="$2" target="$3"
    if [[ "$existed" == "true" ]]; then
        cp "$backup" "$target"
    else
        rm -f "$target"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state-dir)
                shift
                [[ $# -gt 0 && -n "${1:-}" ]] || fatal "Option --state-dir requires a value."
                STATE_DIR="$1"
                ;;
            --key)
                shift
                [[ $# -gt 0 && -n "${1:-}" ]] || fatal "Option --key requires a value."
                KEY_FILE="$1"
                ;;
            --storage-mode)
                shift
                [[ "${1:-}" =~ ^(auto|boot|block)$ ]] || fatal "Option --storage-mode requires one of: auto, boot, block."
                STORAGE_MODE="$1"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
        shift
    done

    [[ -n "$STATE_DIR" ]] || { usage; exit 1; }
    [[ -n "$KEY_FILE" ]] || { usage; exit 1; }
    STATE_DIR="$(realpath -e "$STATE_DIR" 2>/dev/null)" || fatal "--state-dir path does not exist or is invalid: $STATE_DIR"
    KEY_FILE="$(realpath -e "$KEY_FILE" 2>/dev/null)" || fatal "--key path does not exist or is invalid: $KEY_FILE"
}

check_prerequisites() {
    if [[ $EUID -ne 0 ]] && ! allow_non_root_test_mode; then
        fatal "Must run as root."
    fi

    local cmd
    for cmd in mountpoint findmnt sops age-keygen awk git install docker curl bash blkid mktemp cp mv rm chmod sed realpath; do
        command -v "$cmd" >/dev/null 2>&1 || fatal "Missing required command: $cmd"
    done

    docker compose version >/dev/null 2>&1 || fatal "Missing required command: docker compose version"
    case "$STORAGE_MODE" in
        auto)
            if mountpoint -q "$STATE_DIR"; then EFFECTIVE_STORAGE_MODE="block"; else EFFECTIVE_STORAGE_MODE="boot"; fi
            ;;
        boot) EFFECTIVE_STORAGE_MODE="boot" ;;
        block)
            mountpoint -q "$STATE_DIR" || fatal "State directory is not a mounted data/block volume. Attach and mount the data volume first."
            EFFECTIVE_STORAGE_MODE="block"
            ;;
    esac

    MANIFEST="$STATE_DIR/config/dr-manifest.env"
    INSTALL_ENV="$STATE_DIR/config/install.env"
    SECRETS_FILE="$STATE_DIR/secrets/secrets.yaml"

    [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fatal "Missing recovery manifest: $MANIFEST"
    [[ -d "$STATE_DIR/data" ]] || fatal "Missing state data directory: $STATE_DIR/data"
    [[ -f "$SECRETS_FILE" ]] || fatal "Missing secrets file: $SECRETS_FILE"
    [[ -f "$INSTALL_ENV" && ! -L "$INSTALL_ENV" ]] || fatal "Missing install environment: $INSTALL_ENV"
    [[ -f "$KEY_FILE" ]] || fatal "Missing offline Age key: $KEY_FILE"
    [[ -f "$SCRIPT_DIR/docker-compose.yml.example" ]] || fatal "Repository is missing docker-compose.yml.example"
}

parse_manifest() {
    DOMAIN="$(read_env_value DOMAIN "$MANIFEST")"
    REPO_COMMIT="$(read_env_value REPO_COMMIT "$MANIFEST")"
    LAYOUT="$(read_env_value STATE_LAYOUT_VERSION "$MANIFEST")"
    OFFLINE_RECIPIENT="$(read_env_value OFFLINE_AGE_RECIPIENT "$MANIFEST")"

    [[ "$DOMAIN" == https://* ]] || fatal "Invalid DOMAIN in manifest."
    [[ "$REPO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fatal "Invalid REPO_COMMIT in manifest."
    [[ "$LAYOUT" == 1 ]] || fatal "Unsupported STATE_LAYOUT_VERSION in manifest."
    [[ -z "$OFFLINE_RECIPIENT" || "$OFFLINE_RECIPIENT" =~ ^age1[a-z0-9]{58}$ ]] || fatal "Invalid OFFLINE_AGE_RECIPIENT in manifest."

    local current_commit
    current_commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
    if [[ "$current_commit" != "$REPO_COMMIT" ]]; then
        fatal "Checked-out commit does not match recovery manifest. current=${current_commit} expected=${REPO_COMMIT}. Run: sudo git -C ${SCRIPT_DIR} checkout ${REPO_COMMIT}"
    fi

    if ! SOPS_AGE_KEY_FILE="$KEY_FILE" sops -d "$SECRETS_FILE" >/dev/null; then
        fatal "Decryption failed — wrong key or corrupted secrets file."
    fi

    USB_PUBLIC_RECIPIENT="$(age-keygen -y "$KEY_FILE")"
    [[ "$USB_PUBLIC_RECIPIENT" =~ ^age1[a-z0-9]{58}$ ]] || fatal "USB Age key produced an invalid public recipient."
    if [[ -n "$OFFLINE_RECIPIENT" && "$OFFLINE_RECIPIENT" != "$USB_PUBLIC_RECIPIENT" ]]; then
        fatal "USB Age key does not match OFFLINE_AGE_RECIPIENT in manifest."
    fi
}

create_backups() {
    WORKDIR="$(mktemp -d)"
    if allow_non_root_test_mode && [[ $EUID -ne 0 ]]; then
        install -d -m 0700 "$VW_ETC_DIR"
    else
        install -d -m 0700 -o root -g root "$VW_ETC_DIR"
    fi
    CIPHERTEXT_STAGING="$(mktemp -p "$(dirname "$SECRETS_FILE")" secrets.XXXXXXXXXX.yaml)"
    POLICY_STAGING="$(mktemp -p "$SCRIPT_DIR" .sops.yaml.XXXXXXXXXX)"
    NEW_PRIVATE_KEY="$WORKDIR/new-age-key.txt"
    STAGED_ACTIVE_KEY="$(mktemp -p "$VW_ETC_DIR" .age-key.txt.XXXXXXXXXX)"
    CIPHERTEXT_BACKUP="$WORKDIR/secrets.yaml.bak"
    ACTIVE_KEY_BACKUP="$WORKDIR/age-key.bak"
    POLICY_BACKUP="$WORKDIR/sops.yaml.bak"
    MANIFEST_BACKUP="$WORKDIR/dr-manifest.env.bak"

    cp "$SECRETS_FILE" "$CIPHERTEXT_STAGING"
    cp "$SECRETS_FILE" "$CIPHERTEXT_BACKUP"
    CIPHERTEXT_EXISTED=true
    if [[ -f "$ACTIVE_KEY" ]]; then
        cp "$ACTIVE_KEY" "$ACTIVE_KEY_BACKUP"
        ACTIVE_KEY_EXISTED=true
    fi
    if [[ -f "$SOPS_CONFIG_FILE" ]]; then
        cp "$SOPS_CONFIG_FILE" "$POLICY_BACKUP"
        POLICY_EXISTED=true
    fi
    cp "$MANIFEST" "$MANIFEST_BACKUP"
    MANIFEST_EXISTED=true
}

generate_new_key() {
    age-keygen -o "$NEW_PRIVATE_KEY" >/dev/null 2>&1 || fatal "New operational key validation failed."
    NEW_PUBLIC_RECIPIENT="$(age-keygen -y "$NEW_PRIVATE_KEY")"
    [[ "$NEW_PUBLIC_RECIPIENT" =~ ^age1[a-z0-9]{58}$ ]] || fatal "New operational key validation failed."

    install -m 0600 "$NEW_PRIVATE_KEY" "$STAGED_ACTIVE_KEY"
}

write_policy() {
    cat > "$POLICY_STAGING" <<POLICY
creation_rules:
  - path_regex: '.*\.yaml$'
    # Offline recovery key — USB only, never stored on server
    age: "${NEW_PUBLIC_RECIPIENT},${USB_PUBLIC_RECIPIENT}"
POLICY
}

run_staged_rekey() {
    write_policy
    if ! SOPS_AGE_KEY_FILE="$KEY_FILE" sops --config "$POLICY_STAGING" updatekeys --yes "$CIPHERTEXT_STAGING"; then
        fatal "Key rotation failed — live recovery artifacts were not changed."
    fi
}

validate_staged() {
    if ! SOPS_AGE_KEY_FILE="$NEW_PRIVATE_KEY" sops -d "$CIPHERTEXT_STAGING" >/dev/null; then
        fatal "New operational key validation failed."
    fi
    if ! SOPS_AGE_KEY_FILE="$STAGED_ACTIVE_KEY" sops -d "$CIPHERTEXT_STAGING" >/dev/null; then
        fatal "New operational key validation failed."
    fi
}

rollback() {
    [[ "$ROLLBACK_DONE" == "true" ]] && return 0
    ROLLBACK_DONE=true

    if [[ "$CIPHERTEXT_PROMOTED" == "true" ]]; then
        restore_or_remove "$CIPHERTEXT_EXISTED" "$CIPHERTEXT_BACKUP" "$SECRETS_FILE"
    fi
    if [[ "$KEY_PROMOTED" == "true" ]]; then
        restore_or_remove "$ACTIVE_KEY_EXISTED" "$ACTIVE_KEY_BACKUP" "$ACTIVE_KEY"
    fi
    if [[ "$POLICY_PROMOTED" == "true" ]]; then
        restore_or_remove "$POLICY_EXISTED" "$POLICY_BACKUP" "$SOPS_CONFIG_FILE"
    fi
    if [[ "$MANIFEST_EXISTED" == "true" && -f "$MANIFEST_BACKUP" ]]; then
        cp "$MANIFEST_BACKUP" "$MANIFEST"
    fi
}

promote_artifacts() {
    if ! mv "$CIPHERTEXT_STAGING" "$SECRETS_FILE"; then
        fatal "Ciphertext promotion failed."
    fi
    CIPHERTEXT_PROMOTED=true

    if ! mv "$STAGED_ACTIVE_KEY" "$ACTIVE_KEY"; then
        rollback
        fatal "Operational key promotion failed — recovery artifacts were rolled back."
    fi
    KEY_PROMOTED=true

    if ! mv "$POLICY_STAGING" "$SOPS_CONFIG_FILE"; then
        rollback
        fatal "SOPS policy promotion failed — recovery artifacts were rolled back."
    fi
    POLICY_PROMOTED=true

    if ! SOPS_AGE_KEY_FILE="$ACTIVE_KEY" sops -d "$SECRETS_FILE" >/dev/null; then
        rollback
        fatal "Post-promotion decryption failed — recovery artifacts were rolled back."
    fi
    chmod 0600 "$ACTIVE_KEY" "$SECRETS_FILE" 2>/dev/null || true
    chown root:root "$ACTIVE_KEY" "$SECRETS_FILE" 2>/dev/null || true
    chmod 0644 "$SOPS_CONFIG_FILE" 2>/dev/null || true
}

update_env_files() {
    local source_dev uuid
    DEVICE_PATH=""
    if [[ "$EFFECTIVE_STORAGE_MODE" == "block" ]]; then
        source_dev="$(findmnt -n -o SOURCE --target "$STATE_DIR")"
        uuid="$(blkid -s UUID -o value "$source_dev" 2>/dev/null || true)"
        DEVICE_PATH="$source_dev"
        [[ -n "$uuid" && -e "${DEV_BY_UUID_DIR}/${uuid}" ]] && DEVICE_PATH="${DEV_BY_UUID_DIR}/${uuid}"
    fi

    atomic_set_env "$INSTALL_ENV" PROJECT_STATE_DIR "$STATE_DIR"
    if [[ "$EFFECTIVE_STORAGE_MODE" == "block" ]]; then
        atomic_set_env "$INSTALL_ENV" DATA_VOLUME_MOUNT "$STATE_DIR"
        atomic_set_env "$INSTALL_ENV" DATA_VOLUME_DEVICE "$DEVICE_PATH"
    else
        atomic_set_env "$INSTALL_ENV" DATA_VOLUME_MOUNT ""
        atomic_set_env "$INSTALL_ENV" DATA_VOLUME_DEVICE ""
    fi
    atomic_set_env "$INSTALL_ENV" SOPS_AGE_KEY_FILE "$ACTIVE_KEY"

    atomic_set_env "$MANIFEST" OFFLINE_AGE_RECIPIENT "$USB_PUBLIC_RECIPIENT"
    atomic_set_env "$MANIFEST" MANIFEST_UPDATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    chmod 0600 "$INSTALL_ENV" "$MANIFEST" "$SECRETS_FILE" "$ACTIVE_KEY" 2>/dev/null || true
    chown root:root "$INSTALL_ENV" "$MANIFEST" "$SECRETS_FILE" "$ACTIVE_KEY" 2>/dev/null || true
    if [[ "$EFFECTIVE_STORAGE_MODE" == "block" ]]; then
        touch "$STATE_DIR/.vw-data-volume"
    fi
}

run_startup_health() {
    [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || cp "$SCRIPT_DIR/docker-compose.yml.example" "$SCRIPT_DIR/docker-compose.yml"
    if [[ "$EFFECTIVE_STORAGE_MODE" == "block" ]]; then
        export PROJECT_STATE_DIR="$STATE_DIR" DATA_VOLUME_MOUNT="$STATE_DIR" DATA_VOLUME_DEVICE="$DEVICE_PATH" SOPS_AGE_KEY_FILE="$ACTIVE_KEY"
    else
        export PROJECT_STATE_DIR="$STATE_DIR" DATA_VOLUME_MOUNT="" DATA_VOLUME_DEVICE="" SOPS_AGE_KEY_FILE="$ACTIVE_KEY"
    fi
    auto_fix_critical_permissions "$SCRIPT_DIR"
    bash "$VW_STARTUP_SCRIPT"

    if curl -sf "${DOMAIN%/}/alive" >/dev/null; then
        echo "Health check: PASS"
    else
        echo "Health check: FAIL"
        echo "Inspect logs: docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs --tail=200"
    fi
    echo "Recovery complete. Vaultwarden is running at $DOMAIN"
}

cleanup() {
    local rc=$?
    if [[ $rc -ne 0 && "$ROLLBACK_DONE" != "true" ]] && { [[ "$CIPHERTEXT_PROMOTED" == "true" ]] || [[ "$KEY_PROMOTED" == "true" ]] || [[ "$POLICY_PROMOTED" == "true" ]]; }; then
        rollback || true
    fi
    rm -rf "${WORKDIR:-}"
    [[ -n "${CIPHERTEXT_STAGING:-}" && -f "$CIPHERTEXT_STAGING" ]] && rm -f "$CIPHERTEXT_STAGING"
    [[ -n "${POLICY_STAGING:-}" && -f "$POLICY_STAGING" ]] && rm -f "$POLICY_STAGING"
    [[ -n "${STAGED_ACTIVE_KEY:-}" && -f "$STAGED_ACTIVE_KEY" ]] && rm -f "$STAGED_ACTIVE_KEY"
    return 0
}

main() {
    trap cleanup EXIT INT TERM
    parse_args "$@"
    check_prerequisites
    parse_manifest
    create_backups
    generate_new_key
    run_staged_rekey
    validate_staged
    promote_artifacts
    update_env_files
    run_startup_health
}

main "$@"
