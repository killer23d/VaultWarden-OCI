#!/usr/bin/env bash
# utilities/key-rotate.sh — Rotate the operational SOPS/Age key safely.
#
# This script rotates the Age private key used by VaultWarden-OCI, rekeys the
# encrypted SOPS secrets file, updates canonical key references, and writes a
# root-only recovery kit containing the new private key.

HISTFILE=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

show_help() {
    cat <<'EOF'
VaultWarden-OCI Age Key Rotation

USAGE:
    sudo ./utilities/key-rotate.sh [OPTIONS]
    sudo make key-rotate

DESCRIPTION:
    Generates a new operational Age key, rekeys secrets.yaml to the new
    recipient, updates SOPS_AGE_KEY_FILE references, and writes a root-only
    recovery kit that must be copied offline.

OPTIONS:
    --yes, -y     Do not prompt before rotation
    --dry-run     Validate inputs and show what would change
    --extra-recipient AGE_PUBLIC_KEY
                  Preserve an additional explicit Age recipient
    --help, -h    Show this help
    --version, -V Print the VaultWarden-OCI version and exit

NOTES:
    This rotates the Age/SOPS encryption key. It does not rotate individual
    Vaultwarden, Cloudflare, SMTP, or push credentials. Use
    sudo ./edit-secrets.sh rotate FIELD for individual secret values.
EOF
}

ASSUME_YES=false
DRY_RUN=false
EXTRA_RECIPIENTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --extra-recipient)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "ERROR: --extra-recipient requires an Age public key" >&2; exit 1; }
            EXTRA_RECIPIENTS+=("$2")
            shift 2
            ;;
        --help|-h) show_help; exit 0 ;;
        --version|-V)
            printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION" 2>/dev/null || echo unknown)"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/config.sh"
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"
source "${PROJECT_ROOT}/lib/operations.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/setup-credentials.sh"
require_root "$@"
source "${PROJECT_ROOT}/lib/crypto.sh"

load_project_environment || exit 1

_need_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd is required for Age key rotation but is not installed."
        log_error "Install on Ubuntu 24.04 LTS Noble with: sudo apt-get install -y ${pkg}"
        return 1
    fi
}

_secure_rm() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    if command -v shred >/dev/null 2>&1 && [[ -f "$path" ]]; then
        shred -fuz "$path" 2>/dev/null || rm -f "$path"
    else
        rm -rf "$path"
    fi
}

_stage_env_with_key() {
    local source_file="$1" staged_file="$2" key_path="$3"
    [[ -f "$source_file" ]] || return 0

    awk -F= -v k="SOPS_AGE_KEY_FILE" -v v="$key_path" '
        BEGIN { done = 0 }
        $1 == k { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$source_file" > "$staged_file"

    chmod --reference="$source_file" "$staged_file" 2>/dev/null || chmod 600 "$staged_file"
    chown --reference="$source_file" "$staged_file" 2>/dev/null || true
}

_join_recipients_csv() {
    local first=true recipient
    for recipient in "$@"; do
        [[ -n "$recipient" ]] || continue
        if [[ "$first" == "true" ]]; then
            printf '%s' "$recipient"
            first=false
        else
            printf ',%s' "$recipient"
        fi
    done
}

_collect_preserved_recipients() {
    local current_pub="$1" new_pub="$2" manifest_file="$4"
    local seen=" ${new_pub} ${current_pub} "
    local candidate

    # Preserve only the explicitly recorded offline recovery recipient.
    # Do NOT scrape .sops.yaml for old recipients: that can accidentally keep
    # a retired or exposed operational key authorized after rotation.
    if [[ -f "$manifest_file" ]]; then
        candidate="$(grep -m1 '^OFFLINE_AGE_RECIPIENT=' "$manifest_file" 2>/dev/null | cut -d= -f2- | tr -d "\"'" || true)"
        if [[ "$candidate" =~ ^age1[a-z0-9]{58}$ && "$seen" != *" $candidate "* ]]; then
            printf '%s\n' "$candidate"
            seen="${seen}${candidate} "
        fi
    fi

    for candidate in "${EXTRA_RECIPIENTS[@]}"; do
        if [[ ! "$candidate" =~ ^age1[a-z0-9]{58}$ ]]; then
            log_error "Invalid --extra-recipient value: $candidate"
            return 1
        fi
        [[ "$seen" == *" $candidate "* ]] && continue
        printf '%s\n' "$candidate"
        seen="${seen}${candidate} "
    done
}

# Local live-generation transaction state. The backup directory remains the
# durable rollback source until every coupled artifact is promoted and the new
# canonical key decrypts the live ciphertext.
_KEY_ROTATE_COMMITTED=false
_KEY_ROTATE_PROMOTION_STARTED=false
_KEY_ROTATE_ROLLBACK_DONE=false
_KEY_ROTATE_OLD_KEY=""
_KEY_ROTATE_LIVE_SECRETS=""
_KEY_ROTATE_PROMOTED_DESTS=()
_KEY_ROTATE_PROMOTED_BACKUPS=()
_KEY_ROTATE_PROMOTED_EXISTED=()
_KEY_ROTATE_PROMOTED_MODES=()
_KEY_ROTATE_PROMOTED_OWNERS=()
_KEY_ROTATE_PROMOTED_GROUPS=()

_key_rotate_reset_transaction() {
    _KEY_ROTATE_COMMITTED=false
    _KEY_ROTATE_PROMOTION_STARTED=false
    _KEY_ROTATE_ROLLBACK_DONE=false
    _KEY_ROTATE_PROMOTED_DESTS=()
    _KEY_ROTATE_PROMOTED_BACKUPS=()
    _KEY_ROTATE_PROMOTED_EXISTED=()
    _KEY_ROTATE_PROMOTED_MODES=()
    _KEY_ROTATE_PROMOTED_OWNERS=()
    _KEY_ROTATE_PROMOTED_GROUPS=()
}

_key_rotate_promote_file() {
    local source_file="$1" dest_file="$2" backup_file="$3" existed="$4"
    local mode="$5" owner="${6:-}" group="${7:-}"
    local -a install_args=(-m "$mode")

    # Track the destination before replacement so an install error or signal
    # after a partial copy still restores/removes this member.
    _KEY_ROTATE_PROMOTION_STARTED=true
    _KEY_ROTATE_PROMOTED_DESTS+=("$dest_file")
    _KEY_ROTATE_PROMOTED_BACKUPS+=("$backup_file")
    _KEY_ROTATE_PROMOTED_EXISTED+=("$existed")
    _KEY_ROTATE_PROMOTED_MODES+=("$mode")
    _KEY_ROTATE_PROMOTED_OWNERS+=("$owner")
    _KEY_ROTATE_PROMOTED_GROUPS+=("$group")

    [[ -n "$owner" ]] && install_args+=(-o "$owner")
    [[ -n "$group" ]] && install_args+=(-g "$group")
    install "${install_args[@]}" "$source_file" "$dest_file"
}

_key_rotate_rollback_live_generation() {
    [[ "$_KEY_ROTATE_COMMITTED" == "true" ]] && return 0
    [[ "$_KEY_ROTATE_PROMOTION_STARTED" == "true" ]] || return 0
    [[ "$_KEY_ROTATE_ROLLBACK_DONE" == "true" ]] && return 0
    _KEY_ROTATE_ROLLBACK_DONE=true

    local rollback_failed=false i dest backup existed mode owner group
    local -a install_args=()
    log_warn "Rotation did not commit; restoring the previous live Age/SOPS generation..."

    for (( i=${#_KEY_ROTATE_PROMOTED_DESTS[@]} - 1; i >= 0; i-- )); do
        dest="${_KEY_ROTATE_PROMOTED_DESTS[$i]}"
        backup="${_KEY_ROTATE_PROMOTED_BACKUPS[$i]}"
        existed="${_KEY_ROTATE_PROMOTED_EXISTED[$i]}"
        mode="${_KEY_ROTATE_PROMOTED_MODES[$i]}"
        owner="${_KEY_ROTATE_PROMOTED_OWNERS[$i]}"
        group="${_KEY_ROTATE_PROMOTED_GROUPS[$i]}"
        if [[ "$existed" == "true" ]]; then
            install_args=(-m "$mode")
            [[ -n "$owner" ]] && install_args+=(-o "$owner")
            [[ -n "$group" ]] && install_args+=(-g "$group")
            if ! install "${install_args[@]}" "$backup" "$dest"; then
                log_error "Failed to restore rotation backup for: $dest"
                rollback_failed=true
            fi
        elif ! rm -f "$dest"; then
            log_error "Failed to remove newly created rotation artifact: $dest"
            rollback_failed=true
        fi
    done

    if [[ "$rollback_failed" == "false" ]]; then
        if ! check_age_key "$_KEY_ROTATE_OLD_KEY" >/dev/null 2>&1 \
            || ! SOPS_AGE_KEY_FILE="$_KEY_ROTATE_OLD_KEY" sops -d "$_KEY_ROTATE_LIVE_SECRETS" >/dev/null; then
            log_error "Previous Age/SOPS generation was restored, but decryption validation failed."
            rollback_failed=true
        else
            log_success "Previous Age/SOPS generation restored and decryptable."
        fi
    fi

    [[ "$rollback_failed" == "false" ]]
}

_key_rotate_test_signal_after() {
    local artifact="$1"
    if [[ "${VW_TEST_KEY_ROTATE_SIGNAL_AFTER:-}" == "$artifact" ]]; then
        kill -TERM "$BASHPID"
    fi
}

_display_rotated_age_key_summary() {
  # VWOCI-PRR-PATCH-01: private identity remains only in the protected handoff.
  local _key_file="$1" public_key="$2" kit_file="$3"
  : "$_key_file"
  printf '\n'
  printf '╭──────────────────────────────────────────────────────────────────────────────╮\n'
  printf '│  AGE KEY ROTATION HANDOFF SAVED                                              │\n'
  printf '├──────────────────────────────────────────────────────────────────────────────┤\n'
  printf '│  %-76s│\n' "$kit_file"
  printf '│  Owner          root:root                                                    │\n'
  printf '│  Permissions    0600                                                         │\n'
  printf '│  Public key     %-60s│\n' "$public_key"
  printf '│                                                                              │\n'
  printf '│  No private key material was written to terminal output.                    │\n'
  printf '╰──────────────────────────────────────────────────────────────────────────────╯\n'
}

log_header "VaultWarden-OCI Age Key Rotation"

_need_cmd age-keygen age || exit 1
_need_cmd sops sops || exit 1

state_dir="$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")"
secrets_file="${SECRETS_FILE:-${state_dir}/secrets/secrets.yaml}"
system_key="/etc/vaultwarden/age-key.txt"
repo_key="${PROJECT_ROOT}/secrets/keys/age-key.txt"
repo_env="${PROJECT_ROOT}/.env"
system_env="/etc/vaultwarden/vaultwarden.env"
install_env="${state_dir}/config/install.env"
sops_policy_file="${PROJECT_ROOT}/.sops.yaml"
manifest_file="${state_dir}/config/dr-manifest.env"
canonical_key="$system_key"

current_key="$(resolve_age_key_path)" || exit 1

log_info "Configured state dir: $state_dir"
log_info "Secrets file:         $secrets_file"
log_info "Current Age key:     $current_key"
log_info "Canonical Age key:   $canonical_key"

[[ -s "$secrets_file" ]] || { log_error "Secrets file not found or empty: $secrets_file"; exit 1; }
[[ -s "$current_key" ]] || { log_error "Current Age key not found or empty: $current_key"; exit 1; }

check_age_key "$current_key" || {
    log_error "Current Age key failed health validation. Aborting rotation."
    exit 1
}

log_info "Validating current key can decrypt secrets.yaml..."
SOPS_AGE_KEY_FILE="$current_key" sops -d "$secrets_file" >/dev/null

current_pub="$(age-keygen -y "$current_key")"
[[ "$current_pub" =~ ^age1[a-z0-9]{58}$ ]] || {
    log_error "Could not derive a valid public recipient from current key."
    exit 1
}

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would generate a new Age key."
    log_info "[DRY RUN] Would rekey: $secrets_file"
    log_info "[DRY RUN] Would install new key to: $system_key"
    log_info "[DRY RUN] Would update SOPS_AGE_KEY_FILE in .env, vaultwarden.env, and install.env when present."
    exit 0
fi

workdir=""
_key_rotate_reset_transaction
_KEY_ROTATE_OLD_KEY="$current_key"
_KEY_ROTATE_LIVE_SECRETS="$secrets_file"
operation_acquire \
    --id key-rotate \
    --label "Age key rotation" \
    --specific-lock /run/lock/vaultwarden-key-rotate.lock || exit $?
operation_set_phase "1" "Validating current Age key"
_key_rotate_cleanup() {
    local rc=$?
    local rollback_rc=0
    if [[ "$_KEY_ROTATE_COMMITTED" != "true" && "$_KEY_ROTATE_PROMOTION_STARTED" == "true" ]]; then
        _key_rotate_rollback_live_generation || rollback_rc=$?
        if (( rc == 0 || rollback_rc != 0 )); then
            (( rc == 0 )) && rc=1
        fi
    fi
    operation_release "$rc"
    [[ -n "${workdir:-}" ]] && _secure_rm "$workdir"
    return "$rc"
}
trap _key_rotate_cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

if [[ "$ASSUME_YES" != "true" ]]; then
    operator_attention warn "Age key rotation" \
        "This will generate a NEW operational Age key and re-encrypt secrets.yaml." \
        "Backups created after this point require the new private key." \
        "A root-only recovery kit will be written under /root/ and must be copied offline."
    if ! operator_confirm_yes_no "Continue with Age key rotation?" "no" 30; then
        log_warn "Age key rotation cancelled."
        exit 0
    fi
fi

ts="$(date +%Y%m%d-%H%M%S)"
workdir="$(mktemp -d -p /dev/shm vw-age-rotate.XXXXXXXX 2>/dev/null || mktemp -d -t vw-age-rotate.XXXXXXXX)"
operation_set_phase "2" "Generating and installing new Age key"

backup_dir="/root/vw-age-rotation-backups/${ts}"
install -d -m 700 -o root -g root "$backup_dir"

new_key_tmp="${workdir}/new-age-key.txt"
old_umask="$(umask)"
umask 077
age-keygen -o "$new_key_tmp" >/dev/null 2>&1
umask "$old_umask"
chmod 600 "$new_key_tmp"

check_age_key "$new_key_tmp" || {
    log_error "Newly generated Age key failed health validation. Aborting."
    exit 1
}

new_pub="$(age-keygen -y "$new_key_tmp")"
[[ "$new_pub" =~ ^age1[a-z0-9]{58}$ ]] || {
    log_error "New Age key did not produce a valid public recipient."
    exit 1
}

preserved_recipients_file="${workdir}/preserved-recipients.txt"
if ! _collect_preserved_recipients "$current_pub" "$new_pub" "$sops_policy_file" "$manifest_file" > "$preserved_recipients_file"; then
    exit 1
fi
mapfile -t preserved_recipients < "$preserved_recipients_file"
recipients_csv="$(_join_recipients_csv "$new_pub" "${preserved_recipients[@]:-}")"

policy_tmp="${workdir}/.sops.yaml"
cipher_tmp="${workdir}/secrets.yaml"

{
    echo "creation_rules:"
    echo "  - path_regex: '.*\\.yaml$'"
    echo "    age: \"${recipients_csv}\""
} > "$policy_tmp"
chmod 600 "$policy_tmp"

cp -f "$secrets_file" "$cipher_tmp"
chmod 600 "$cipher_tmp"

log_info "Rekeying staged secrets.yaml to the new Age recipient..."
log_info "SOPS recipients:"
log_info "  + new operational recipient: $new_pub"
if [[ ${#preserved_recipients[@]} -gt 0 ]]; then
    for recipient in "${preserved_recipients[@]}"; do
        log_info "  = preserved explicit/offline recipient: $recipient"
    done
    unset recipient
else
    log_info "  = no extra/offline recipients preserved"
fi
log_info "  - previous operational recipient will be removed: $current_pub"

sops_updatekeys_log="${backup_dir}/sops-updatekeys.log"
operation_set_phase "3" "Re-encrypting secrets with new Age key"
if ! SOPS_AGE_KEY_FILE="$current_key" sops --config "$policy_tmp" updatekeys --yes "$cipher_tmp" >"$sops_updatekeys_log" 2>&1; then
    log_error "SOPS updatekeys failed. Details: $sops_updatekeys_log"
    exit 1
fi
SOPS_AGE_KEY_FILE="$new_key_tmp" sops -d "$cipher_tmp" >/dev/null

repo_env_tmp="${workdir}/repo.env"
system_env_tmp="${workdir}/vaultwarden.env"
install_env_tmp="${workdir}/install.env"

_stage_env_with_key "$repo_env" "$repo_env_tmp" "$canonical_key"
_stage_env_with_key "$system_env" "$system_env_tmp" "$canonical_key"
_stage_env_with_key "$install_env" "$install_env_tmp" "$canonical_key"

log_info "Backing up current key, policy, secrets, and env files to: $backup_dir"
secrets_existed=false
policy_existed=false
system_key_existed=false
repo_key_existed=false
repo_env_existed=false
system_env_existed=false
install_env_existed=false
if [[ -f "$secrets_file" ]]; then install -m 600 -o root -g root "$secrets_file" "${backup_dir}/secrets.yaml"; secrets_existed=true; fi
if [[ -f "$sops_policy_file" ]]; then install -m 644 "$sops_policy_file" "${backup_dir}/.sops.yaml"; policy_existed=true; fi
if [[ -f "$system_key" ]]; then install -m 600 -o root -g root "$system_key" "${backup_dir}/age-key.system.txt"; system_key_existed=true; fi
if [[ -f "$repo_key" ]]; then install -m 600 "$repo_key" "${backup_dir}/age-key.repo.txt"; repo_key_existed=true; fi
if [[ -f "$repo_env" ]]; then install -m 600 "$repo_env" "${backup_dir}/.env"; repo_env_existed=true; fi
if [[ -f "$system_env" ]]; then install -m 600 -o root -g root "$system_env" "${backup_dir}/vaultwarden.env"; system_env_existed=true; fi
if [[ -f "$install_env" ]]; then install -m 600 -o root -g root "$install_env" "${backup_dir}/install.env"; install_env_existed=true; fi

repo_env_mode="$(_stat_octal_perms "$repo_env" 2>/dev/null || printf '600')"
repo_env_owner="$(_stat_owner "$repo_env" 2>/dev/null || printf 'root')"
repo_env_group="$(_stat_group "$repo_env" 2>/dev/null || printf 'root')"

operation_set_phase "4" "Promoting new key and rekeyed secrets"
log_info "Promoting new key and rekeyed secrets..."
install -d -m 700 -o root -g root /etc/vaultwarden
install -d -m 700 "$(dirname "$repo_key")"
install -d -m 700 -o root -g root "$(dirname "$secrets_file")"

_key_rotate_promote_file "$new_key_tmp" "$system_key" "${backup_dir}/age-key.system.txt" "$system_key_existed" 600 root root
_key_rotate_test_signal_after system-key
_key_rotate_promote_file "$new_key_tmp" "$repo_key" "${backup_dir}/age-key.repo.txt" "$repo_key_existed" 600 root root
_key_rotate_test_signal_after repo-key
_key_rotate_promote_file "$cipher_tmp" "$secrets_file" "${backup_dir}/secrets.yaml" "$secrets_existed" 600 root root
_key_rotate_test_signal_after ciphertext
_key_rotate_promote_file "$policy_tmp" "$sops_policy_file" "${backup_dir}/.sops.yaml" "$policy_existed" 644 root root
_key_rotate_test_signal_after policy

if [[ -f "$repo_env_tmp" ]]; then
    _key_rotate_promote_file "$repo_env_tmp" "$repo_env" "${backup_dir}/.env" "$repo_env_existed" "$repo_env_mode" "$repo_env_owner" "$repo_env_group"
    _key_rotate_test_signal_after repo-env
fi
if [[ -f "$system_env_tmp" ]]; then
    _key_rotate_promote_file "$system_env_tmp" "$system_env" "${backup_dir}/vaultwarden.env" "$system_env_existed" 600 root root
    _key_rotate_test_signal_after system-env
fi
if [[ -f "$install_env_tmp" ]]; then
    _key_rotate_promote_file "$install_env_tmp" "$install_env" "${backup_dir}/install.env" "$install_env_existed" 600 root root
    _key_rotate_test_signal_after install-env
fi

log_info "Validating promoted secrets with new key..."
SOPS_AGE_KEY_FILE="$system_key" sops -d "$secrets_file" >/dev/null
check_age_key "$system_key" >/dev/null
_KEY_ROTATE_COMMITTED=true

kit_file="$(publish_age_rotation_handoff "$system_key" "$new_pub" "$ts")" || {
  log_error "Could not publish the protected Age rotation handoff."
  exit 1
}

log_success "Age key rotation complete."
log_success "New public key: $new_pub"
log_warn "Recovery kit saved: $kit_file"
log_warn "COPY THIS FILE OFFLINE NOW, then delete it from /root/."
log_warn "Refresh runtime secrets/services with: sudo make restart"

if [[ "$ASSUME_YES" != "true" ]]; then
    _display_rotated_age_key_summary "$system_key" "$new_pub" "$kit_file"
    saved=""
    while [[ "$saved" != "SAVED" ]]; do
        if ! read -r -t 300 -p "Type SAVED after copying the recovery kit offline: " saved; then
            printf '\n' >&2
            log_error "No confirmation received within 5 minutes. Recovery-kit acknowledgement failed closed."
            exit 1
        fi
        [[ "$saved" == "SAVED" ]] || log_warn "Please type exactly: SAVED"
    done
fi
