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

_display_rotated_age_key_summary() {
    local key_file="$1" public_key="$2" kit_file="$3"
    local private_key_line=""

    { set +x; } 2>/dev/null
    private_key_line="$(grep -m1 '^AGE-SECRET-KEY-1' "$key_file" 2>/dev/null || true)"

    printf '\n%s' "${COLOR_RED:-}"
    cat <<'CRED_BANNER'
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
  !                                                                       !
  !       🚨 CRITICAL: SAVE THIS NEW AGE KEY FOR DISASTER RECOVERY 🚨      !
  !     Future backups and secrets require this new private key.          !
  !                                                                       !
  ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
CRED_BANNER
    printf '%s\n' "${COLOR_RESET:-}"

    printf '\n%s[1] SOPS AGE SECRET KEY%s\n' "${COLOR_CYAN:-}" "${COLOR_RESET:-}"
    printf '    Public key:  %s%s%s\n' "${COLOR_GREEN:-}" "$public_key" "${COLOR_RESET:-}"
    printf '%s%s%s\n' "${COLOR_GREEN:-}" "${private_key_line:-ERROR: could not read private key}" "${COLOR_RESET:-}"

    printf '\n%sRecovery kit:%s %s\n' "${COLOR_CYAN:-}" "${COLOR_RESET:-}" "$kit_file"
    printf '\n%s!!! TYPE SAVED ONLY AFTER SAVING THIS KEY OFFLINE !!!%s\n' "${COLOR_RED:-}" "${COLOR_RESET:-}"
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
operation_acquire \
    --id key-rotate \
    --label "Age key rotation" \
    --specific-lock /run/lock/vaultwarden-key-rotate.lock || exit $?
operation_set_phase "1" "Validating current Age key"
_key_rotate_cleanup() {
    local rc=$?
    operation_release "$rc"
    [[ -n "${workdir:-}" ]] && _secure_rm "$workdir"
    return "$rc"
}
trap _key_rotate_cleanup EXIT
trap 'operation_release 130; [[ -n "${workdir:-}" ]] && _secure_rm "$workdir"; exit 130' INT
trap 'operation_release 143; [[ -n "${workdir:-}" ]] && _secure_rm "$workdir"; exit 143' HUP TERM

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
[[ -f "$secrets_file" ]] && install -m 600 -o root -g root "$secrets_file" "${backup_dir}/secrets.yaml"
[[ -f "$sops_policy_file" ]] && install -m 644 "$sops_policy_file" "${backup_dir}/.sops.yaml"
[[ -f "$system_key" ]] && install -m 600 -o root -g root "$system_key" "${backup_dir}/age-key.system.txt"
[[ -f "$repo_key" ]] && install -m 600 "$repo_key" "${backup_dir}/age-key.repo.txt"
[[ -f "$repo_env" ]] && install -m 600 "$repo_env" "${backup_dir}/.env"
[[ -f "$system_env" ]] && install -m 600 -o root -g root "$system_env" "${backup_dir}/vaultwarden.env"
[[ -f "$install_env" ]] && install -m 600 -o root -g root "$install_env" "${backup_dir}/install.env"

operation_set_phase "4" "Promoting new key and rekeyed secrets"
log_info "Promoting new key and rekeyed secrets..."
install -d -m 700 -o root -g root /etc/vaultwarden
install -d -m 700 "$(dirname "$repo_key")"
install -d -m 700 -o root -g root "$(dirname "$secrets_file")"

install -m 600 -o root -g root "$new_key_tmp" "$system_key"
install -m 600 "$new_key_tmp" "$repo_key"
install -m 600 -o root -g root "$cipher_tmp" "$secrets_file"
install -m 644 "$policy_tmp" "$sops_policy_file"

[[ -f "$repo_env_tmp" ]] && cp -f "$repo_env_tmp" "$repo_env"
[[ -f "$system_env_tmp" ]] && install -m 600 -o root -g root "$system_env_tmp" "$system_env"
[[ -f "$install_env_tmp" ]] && install -m 600 -o root -g root "$install_env_tmp" "$install_env"

log_info "Validating promoted secrets with new key..."
SOPS_AGE_KEY_FILE="$system_key" sops -d "$secrets_file" >/dev/null
check_age_key "$system_key" >/dev/null

kit_file="/root/vaultwarden-recovery-kit-age-rotate-${ts}.txt"
{
    echo "# VaultWarden-OCI Age Key Recovery Kit"
    echo "# Generated: $(date -u)"
    echo "# Host:      $(hostname -f 2>/dev/null || hostname)"
    echo "# Reason:    Operational Age key rotation"
    echo "#"
    echo "# Store this file offline in a secure password manager or USB."
    echo "# Delete it from /root after it is safely copied."
    echo
    echo "[AGE PRIVATE KEY]"
    cat "$system_key"
    echo
    echo "[AGE PUBLIC KEY]"
    echo "$new_pub"
} > "$kit_file"
chmod 600 "$kit_file"

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
