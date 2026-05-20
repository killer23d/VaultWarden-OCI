#!/usr/bin/env bash
# utilities/setup-env.sh — VaultWarden-OCI environment file configuration
#
# Creates or updates .env and docker-compose.yml from templates.
# Safe to re-run (idempotent): existing files are not overwritten unless
# --force is passed or key values (domain/email) have changed.
#
# USAGE:
#   sudo utilities/setup-env.sh --domain DOMAIN --email EMAIL [OPTIONS]
#
# FLAGS:
#   --domain DOMAIN       Your domain name (required)
#   --email EMAIL         Admin email address (required)
#   --use-latest          Set all container versions to 'latest'
#   --data-device DEV     Data volume block device path
#   --data-mount PATH     Data volume mount point (default: /mnt/vw-data)
#   --force               Overwrite existing .env/docker-compose.yml
#   --dry-run             Preview actions without executing
#   --help, -h            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Bootstrap common library
# ---------------------------------------------------------------------------
if [[ ! -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
    echo "ERROR: Required library not found: ${PROJECT_ROOT}/lib/common.sh" >&2
    exit 1
fi
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

# shellcheck source=../lib/crypto.sh
source "${PROJECT_ROOT}/lib/crypto.sh"

# ---------------------------------------------------------------------------
# Variable defaults
# ---------------------------------------------------------------------------
DOMAIN=""
ADMIN_EMAIL=""
USE_LATEST=false
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
FORCE=false
DRY_RUN=false
CLEAN_DOMAIN=""

# ---------------------------------------------------------------------------
# show_help
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
utilities/setup-env.sh — VaultWarden-OCI environment file configuration

Creates or updates .env and docker-compose.yml from templates.
Safe to re-run (idempotent): existing files are not overwritten unless
--force is passed or key values (domain/email) have changed.

USAGE:
    sudo utilities/setup-env.sh --domain DOMAIN --email EMAIL [OPTIONS]

FLAGS:
    --domain DOMAIN       Your domain name (required)
    --email EMAIL         Admin email address (required)
    --use-latest          Set all container versions to 'latest'
    --data-device DEV     Data volume block device path
    --data-mount PATH     Data volume mount point (default: /mnt/vw-data)
    --force               Overwrite existing .env/docker-compose.yml
    --dry-run             Preview actions without executing
    --help, -h            Show this help

EXAMPLES:
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --force
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --dry-run
EOF
}

# ---------------------------------------------------------------------------
# _parse_args
# ---------------------------------------------------------------------------
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                shift
                [[ $# -gt 0 ]] || { log_error "--domain requires an argument"; exit 1; }
                DOMAIN="$1"
                ;;
            --email)
                shift
                [[ $# -gt 0 ]] || { log_error "--email requires an argument"; exit 1; }
                ADMIN_EMAIL="$1"
                ;;
            --use-latest)   USE_LATEST=true ;;
            --force)        FORCE=true ;;
            --dry-run)      DRY_RUN=true ;;
            --data-device)
                shift
                [[ $# -gt 0 ]] || { log_error "--data-device requires an argument"; exit 1; }
                DATA_VOLUME_DEVICE="$1"
                ;;
            --data-mount)
                shift
                [[ $# -gt 0 ]] || { log_error "--data-mount requires an argument"; exit 1; }
                DATA_VOLUME_MOUNT="$1"
                ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# detect_ssh_log_path
# ---------------------------------------------------------------------------
detect_ssh_log_path() {
    local ssh_log_path="/var/log/secure"
    local os_id

    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'")
        case "$os_id" in
            ol|rhel|centos|rocky|almalinux|fedora) ssh_log_path="/var/log/secure" ;;
            ubuntu|debian) ssh_log_path="/var/log/auth.log" ;;
            *)
                if [[ -f "/var/log/secure" ]]; then ssh_log_path="/var/log/secure"
                else ssh_log_path="/var/log/auth.log"; fi ;;
        esac
    fi
    echo "$ssh_log_path"
}

# ---------------------------------------------------------------------------
# create_env_file
# ---------------------------------------------------------------------------
create_env_file() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create .env file"; return 0; fi

    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"

    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        local domain_matches=false email_matches=false latest_matches=false
        grep -qF "DOMAIN=$DOMAIN" "$env_file"           && domain_matches=true
        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file" && email_matches=true

        if [[ "$USE_LATEST" == "true" ]]; then
            if grep -qE '^VAULTWARDEN_VERSION=latest' "$env_file" && \
               grep -qE '^CADDY_VERSION=latest'       "$env_file" && \
               grep -qE '^POSTFIX_VERSION=latest'     "$env_file" && \
               grep -qE '^BUSYBOX_VERSION=latest'     "$env_file"; then
                latest_matches=true
            fi
        else
            if ! grep -qE '^(VAULTWARDEN|CADDY|POSTFIX|BUSYBOX)_VERSION=latest' "$env_file"; then
                latest_matches=true
            fi
        fi

        if [[ "$domain_matches" == "true" ]] && \
           [[ "$email_matches" == "true" ]] && \
           [[ "$latest_matches" == "true" ]]; then
            return 0
        fi
    fi

    local prev_umask; prev_umask=$(umask)
    umask 077
    cp "$env_template" "$env_file" || { umask "$prev_umask"; return 1; }
    umask "$prev_umask"

    local real_user; real_user=$(get_real_user)
    local user_id; user_id=$(id -u "$real_user")
    local group_id; group_id=$(id -g "$real_user")
    local detected_ssh_log_path; detected_ssh_log_path=$(detect_ssh_log_path 2>/dev/null)

    local domain_with_protocol
    [[ "$DOMAIN" =~ ^https?:// ]] && domain_with_protocol="$DOMAIN" || domain_with_protocol="https://$DOMAIN"

    local clean_domain; clean_domain=$(echo "$domain_with_protocol" | sed -E 's|https?://||; s|/.*$||')
    CLEAN_DOMAIN="$clean_domain"
    export CLEAN_DOMAIN

    local temp_env=""
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1

    # Compute PROJECT_STATE_DIR value: when a data volume is configured it MUST
    # equal DATA_VOLUME_MOUNT; otherwise use the default boot-volume location.
    local awk_state_dir
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        awk_state_dir="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    else
        awk_state_dir="/var/lib/vaultwarden"
    fi

    AWK_DOMAIN="$domain_with_protocol" \
    AWK_EMAIL="$ADMIN_EMAIL" \
    AWK_UID="$user_id" \
    AWK_GID="$group_id" \
    AWK_SMTP_FROM="noreply@$clean_domain" \
    AWK_ALLOWED_SENDER_DOMAINS="$clean_domain" \
    AWK_SSH_LOG="$detected_ssh_log_path" \
    AWK_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}" \
    AWK_DATA_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}" \
    AWK_STATE_DIR="$awk_state_dir" \
    awk '
        {
            sub(/^DOMAIN=.*/, "DOMAIN=" ENVIRON["AWK_DOMAIN"]);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/, "PUID=" ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/, "PGID=" ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" ENVIRON["AWK_SMTP_FROM"]);
            sub(/^ALLOWED_SENDER_DOMAINS=.*/, "ALLOWED_SENDER_DOMAINS=" ENVIRON["AWK_ALLOWED_SENDER_DOMAINS"]);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ENVIRON["AWK_SSH_LOG"]);
            sub(/^DATA_VOLUME_DEVICE=.*/, "DATA_VOLUME_DEVICE=" ENVIRON["AWK_DATA_DEVICE"]);
            sub(/^DATA_VOLUME_MOUNT=.*/, "DATA_VOLUME_MOUNT=" ENVIRON["AWK_DATA_MOUNT"]);
            sub(/^PROJECT_STATE_DIR=.*/, "PROJECT_STATE_DIR=" ENVIRON["AWK_STATE_DIR"]);
            print;
        }' "$env_file" > "$temp_env"

    mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }

    if [[ "$USE_LATEST" == "true" ]]; then
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^CADDY_VERSION=.*/, "CADDY_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/, "POSTFIX_VERSION=latest");
            sub(/^BUSYBOX_VERSION=.*/, "BUSYBOX_VERSION=latest");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
    fi

    # Ensure the canonical production Age key path is written to .env so the
    # verification in generate_age_keys() always succeeds on a clean install.
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
    awk '{
        sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
        print;
    }' "$env_file" > "$temp_env"
    mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }

    # In separate-volume mode, auto-populate BACKUP_DIR if it is currently
    # blank in .env.  This ensures backup.sh finds backups on the data volume
    # without the operator having to manually edit the file.  An explicit
    # BACKUP_DIR already set by the operator is left untouched.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        local current_backup_dir
        current_backup_dir=$(_read_env_value "BACKUP_DIR" "$env_file")
        if [[ -z "$current_backup_dir" ]]; then
            _set_env_var "BACKUP_DIR" "${DATA_VOLUME_MOUNT:-/mnt/vw-data}/backups" "$env_file"
            log_info "Auto-set BACKUP_DIR=${DATA_VOLUME_MOUNT:-/mnt/vw-data}/backups in .env (separate-volume mode)"
        fi
    fi

    chown "$real_user:$(id -g -n "$real_user")" "$env_file" || return 1
    chmod 600 "$env_file" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# create_docker_compose
# ---------------------------------------------------------------------------
create_docker_compose() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create docker-compose.yml"; return 0; fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        docker compose -f "$compose_file" config >/dev/null 2>&1 && return 0
    fi

    cp "$compose_template" "$compose_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$compose_file" || return 1
    chmod 640 "$compose_file" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    (( EUID == 0 )) || { log_error "Must run as root."; exit 1; }

    [[ -n "$DOMAIN" ]]      || { log_error "--domain is required"; exit 1; }
    [[ -n "$ADMIN_EMAIL" ]] || { log_error "--email is required"; exit 1; }

    [[ "$DRY_RUN" == "true" ]] && log_info "DRY RUN mode — no changes will be made"

    create_env_file
    create_docker_compose

    log_success "Environment configuration complete"
}

_parse_args "$@"
main
