#!/usr/bin/env bash
# utilities/setup-env.sh — Creates or updates VaultWarden-OCI environment files from project templates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for _lib in "lib/log.sh" "lib/validate.sh" "lib/config.sh" "lib/common.sh"; do
    if [[ ! -f "${PROJECT_ROOT}/${_lib}" ]]; then
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    fi
done
unset _lib
# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/validate.sh
source "${PROJECT_ROOT}/lib/validate.sh"
# shellcheck source=../lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

# shellcheck source=../lib/crypto.sh
source "${PROJECT_ROOT}/lib/crypto.sh"
# shellcheck source=../lib/defaults.sh
source "${PROJECT_ROOT}/lib/defaults.sh"
# shellcheck source=../lib/operations.sh
source "${PROJECT_ROOT}/lib/operations.sh"

DOMAIN=""
ADMIN_EMAIL=""
USE_LATEST=false
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
DATA_VOLUME_DEVICE_EXPLICIT=false
DATA_VOLUME_MOUNT_EXPLICIT=false
FORCE=false
DRY_RUN=false
SETUP_ENV_GUARD_HELD=false

_setup_env_acquire_guard() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ "$SETUP_ENV_GUARD_HELD" == "true" ]] && return 0

    local policy="fail"
    if [[ ! -t 0 || ! -t 1 ]]; then
        policy="skip"
    fi
    operation_acquire \
        --id env-sync \
        --label "Environment setup" \
        --non-interactive "$policy" || return $?
    SETUP_ENV_GUARD_HELD=true
    _setup_env_cleanup() {
        local rc=$?
        operation_release "$rc"
        return "$rc"
    }
    trap _setup_env_cleanup EXIT
    trap 'operation_release 130; exit 130' INT
    trap 'operation_release 143; exit 143' HUP TERM
    operation_set_phase "setup-env" "Generating environment configuration"
}

show_help() {
    cat <<'EOF' | sed "s|@DEFAULT_DATA_MOUNT@|${_VW_DEFAULT_DATA_MOUNT}|g"
VaultWarden-OCI Environment Setup

USAGE:
    sudo utilities/setup-env.sh --domain DOMAIN --email EMAIL [OPTIONS]

DESCRIPTION:
    Creates or updates .env and docker-compose.yml from project templates.
    Safe to re-run (idempotent) — existing files are not overwritten unless
    --force is passed. Called automatically by setup.sh during phase 3.

OPTIONS:
    --domain DOMAIN       Your domain name (required, e.g. vault.example.com)
    --email EMAIL         Admin email address (required)
    --use-latest          Explicit override: write supported image/CrowdSec version fields
                          as 'latest' in .env. This persists across later pulls until
                          those fields are re-pinned. Caddy remains pinned because
                          xcaddy builder tags require an explicit version.
    --data-device DEV     Data volume block device path
    --data-mount PATH     Data volume mount point (default: @DEFAULT_DATA_MOUNT@)
    --force               Overwrite existing .env/docker-compose.yml
    --dry-run             Preview actions without executing
    --help, -h            Show this help
    --version, -V         Print the VaultWarden-OCI version and exit

DOMAIN REQUIREMENTS:
    - Must be a bare hostname with no scheme (not https://vault.example.com)
    - Must be a fully-qualified domain name with at least one dot
    - Must not include a port number or a path
    - Must not be a placeholder (e.g. vault.example.com, CHANGE_ME)
    - Must not be a bare IP address (Caddy ACME requires a DNS name)

EXAMPLES:
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --force
    sudo utilities/setup-env.sh --domain vault.example.com --email admin@example.com --dry-run
EOF
}

_parse_args() {
    _require_cli_value() {
        local opt="$1" value="${2-}"
        if [[ -z "$value" || "$value" == --* ]]; then
            log_error "$opt requires an argument"
            exit 1
        fi
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                shift
                _require_cli_value "--domain" "${1-}"
                DOMAIN="$1"
                ;;
            --email)
                shift
                _require_cli_value "--email" "${1-}"
                ADMIN_EMAIL="$1"
                ;;
            --use-latest)   USE_LATEST=true ;;
            --force)        FORCE=true ;;
            --dry-run)      DRY_RUN=true ;;
            --data-device)
                shift
                _require_cli_value "--data-device" "${1-}"
                DATA_VOLUME_DEVICE="$1"
                DATA_VOLUME_DEVICE_EXPLICIT=true
                ;;
            --data-mount)
                shift
                _require_cli_value "--data-mount" "${1-}"
                DATA_VOLUME_MOUNT="$1"
                DATA_VOLUME_MOUNT_EXPLICIT=true
                ;;
            --help|-h) show_help; exit 0 ;;
            --version|-V) print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

detect_ssh_log_path() {
    printf '%s\n' '/var/log/auth.log'
}

_make_owned_temp() {
    local dir="$1" owner="$2" group="$3"
    local tmp
    tmp=$(mktemp -p "$dir" .env.tmp.XXXXXXXXXX) || return 1
    chown "$owner:$group" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600              "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s' "$tmp"
}

create_env_file() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create .env file"
        return 0
    fi

    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"

    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        return 1
    fi

    local domain_with_protocol clean_domain
    [[ "$DOMAIN" =~ ^https?:// ]] \
        && domain_with_protocol="$DOMAIN" \
        || domain_with_protocol="https://$DOMAIN"
    clean_domain=$(printf '%s' "$domain_with_protocol" | sed -E 's|https?://||; s|/.*$||')

    # Optional storage flags are overrides, not reset switches. When an existing
    # .env is present, omitted flags preserve its current storage identity.
    if [[ -f "$env_file" ]]; then
        if [[ "$DATA_VOLUME_DEVICE_EXPLICIT" != "true" ]]; then
            DATA_VOLUME_DEVICE="$(_read_env_value DATA_VOLUME_DEVICE "$env_file")"
        fi
        if [[ "$DATA_VOLUME_MOUNT_EXPLICIT" != "true" ]]; then
            local existing_mount
            existing_mount="$(_read_env_value DATA_VOLUME_MOUNT "$env_file")"
            [[ -n "$existing_mount" ]] && DATA_VOLUME_MOUNT="$existing_mount"
        fi
    fi
    DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"

    local effective_state_dir
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        effective_state_dir="$DATA_VOLUME_MOUNT"
    else
        effective_state_dir="/var/lib/vaultwarden"
    fi

    # Idempotency compares the same effective storage identity that rendering
    # uses, so an explicit storage change cannot be mistaken for a no-op.
    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        local domain_matches=false email_matches=false versions_match=false storage_matches=false
        grep -qF "DOMAIN=$domain_with_protocol" "$env_file" && domain_matches=true
        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL"      "$env_file" && email_matches=true

        if [[ "$USE_LATEST" == "true" ]]; then
            if grep -qE '^VAULTWARDEN_VERSION=latest' "$env_file" && \
               grep -qE '^POSTFIX_VERSION=latest'     "$env_file" && \
               grep -qE '^BUSYBOX_VERSION=latest'     "$env_file" && \
               ! grep -qE '^CADDY_VERSION=latest'     "$env_file" && \
               grep -qE '^CROWDSEC_VERSION=latest'    "$env_file" && \
               grep -qE '^CF_WORKER_BOUNCER_VERSION=latest' "$env_file" && \
               grep -qE '^FIREWALL_BOUNCER_VERSION=latest'  "$env_file"; then
                versions_match=true
            fi
        else
            grep -qE '^(VAULTWARDEN|CADDY|POSTFIX|BUSYBOX|CROWDSEC|CF_WORKER_BOUNCER|FIREWALL_BOUNCER)_VERSION=latest' "$env_file" \
                || versions_match=true
        fi

        if [[ "$(_read_env_value DATA_VOLUME_DEVICE "$env_file")" == "${DATA_VOLUME_DEVICE:-}" &&
              "$(_read_env_value DATA_VOLUME_MOUNT "$env_file")" == "$DATA_VOLUME_MOUNT" &&
              "$(_read_env_value PROJECT_STATE_DIR "$env_file")" == "$effective_state_dir" ]]; then
            storage_matches=true
        fi

        if [[ "$domain_matches"  == "true" ]] && \
           [[ "$email_matches"   == "true" ]] && \
           [[ "$versions_match" == "true" ]] && \
           [[ "$storage_matches" == "true" ]]; then
            log_info ".env is already up-to-date — skipping (use --force to overwrite)"
            return 0
        fi
    fi

    local real_user real_group user_id group_id
    real_user=$(get_real_user)
    real_group=$(id -gn "$real_user")
    user_id=$(id -u  "$real_user")
    group_id=$(id -g "$real_user")

    local detected_ssh_log_path
    detected_ssh_log_path=$(detect_ssh_log_path)

    local env_dir
    env_dir="$(dirname "$env_file")"

    local temp_env
    temp_env=$(_make_owned_temp "$env_dir" "$real_user" "$real_group") || return 1

    AWK_DOMAIN="$domain_with_protocol"                \
    AWK_EMAIL="$ADMIN_EMAIL"                          \
    AWK_UID="$user_id"                                \
    AWK_GID="$group_id"                               \
    AWK_SMTP_FROM="noreply@$clean_domain"             \
    AWK_ALLOWED_SENDER_DOMAINS="$clean_domain"        \
    AWK_SSH_LOG="$detected_ssh_log_path"              \
    AWK_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}"         \
    AWK_DATA_MOUNT="$DATA_VOLUME_MOUNT"               \
    AWK_STATE_DIR="$effective_state_dir"              \
    awk '
        {
            sub(/^DOMAIN=.*/,                 "DOMAIN="                 ENVIRON["AWK_DOMAIN"]);
            sub(/^ADMIN_EMAIL=.*/,            "ADMIN_EMAIL="            ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/,                   "PUID="                   ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/,                   "PGID="                   ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/,              "SMTP_FROM="              ENVIRON["AWK_SMTP_FROM"]);
            sub(/^ALLOWED_SENDER_DOMAINS=.*/, "ALLOWED_SENDER_DOMAINS=" ENVIRON["AWK_ALLOWED_SENDER_DOMAINS"]);
            sub(/^SSH_LOG_PATH=.*/,           "SSH_LOG_PATH="           ENVIRON["AWK_SSH_LOG"]);
            sub(/^DATA_VOLUME_DEVICE=.*/,     "DATA_VOLUME_DEVICE="     ENVIRON["AWK_DATA_DEVICE"]);
            sub(/^DATA_VOLUME_MOUNT=.*/,      "DATA_VOLUME_MOUNT="      ENVIRON["AWK_DATA_MOUNT"]);
            sub(/^PROJECT_STATE_DIR=.*/,      "PROJECT_STATE_DIR="      ENVIRON["AWK_STATE_DIR"]);
            sub(/^SOPS_AGE_KEY_FILE=.*/,      "SOPS_AGE_KEY_FILE=");
            print;
        }
    ' "$env_template" > "$temp_env" || { rm -f "$temp_env"; return 1; }

    if [[ "$USE_LATEST" == "true" ]]; then
        log_warn "--use-latest is writing persistent mutable version tags to .env; re-pin those fields to return to reproducible updates."
        local temp2
        temp2=$(_make_owned_temp "$env_dir" "$real_user" "$real_group") \
            || { rm -f "$temp_env"; return 1; }

        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/,     "POSTFIX_VERSION=latest");
            sub(/^BUSYBOX_VERSION=.*/,     "BUSYBOX_VERSION=latest");
            sub(/^CROWDSEC_VERSION=.*/,    "CROWDSEC_VERSION=latest");
            sub(/^CF_WORKER_BOUNCER_VERSION=.*/, "CF_WORKER_BOUNCER_VERSION=latest");
            sub(/^FIREWALL_BOUNCER_VERSION=.*/,  "FIREWALL_BOUNCER_VERSION=latest");
            print;
        }' "$temp_env" > "$temp2" || { rm -f "$temp_env" "$temp2"; return 1; }

        rm -f "$temp_env"
        temp_env="$temp2"
    fi

    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        local current_backup_dir
        current_backup_dir=$(_read_env_value "BACKUP_DIR" "$temp_env")
        if [[ -z "$current_backup_dir" ]]; then
            _set_env_var "BACKUP_DIR" "$DATA_VOLUME_MOUNT/backups" "$temp_env"
            log_info "Auto-set BACKUP_DIR=$DATA_VOLUME_MOUNT/backups in .env (separate-volume mode)"
        fi
    fi

    mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
    log_success ".env written: $env_file (owner: $real_user:$real_group, mode: 600)"
    return 0
}

refresh_state_artifacts() {
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would refresh state-volume install.env, manifest, and recovery card"; return 0; }

    local env_file="$PROJECT_ROOT/.env"
    local rendered_domain rendered_state_dir repo_commit recovery_repo_url existing_offline_recipient
    rendered_domain="$(_read_env_value DOMAIN "$env_file")"
    rendered_state_dir="$(_read_env_value PROJECT_STATE_DIR "$env_file")"
    [[ "$rendered_domain" == https://* ]] || rendered_domain="https://${rendered_domain#http://}"
    [[ "$rendered_state_dir" == /* ]] || { log_error "PROJECT_STATE_DIR must be absolute: $rendered_state_dir"; return 1; }
    repo_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
    [[ "$repo_commit" =~ ^[0-9a-f]{40}$ ]] || { log_error "Unable to resolve 40-character repository commit"; return 1; }
    recovery_repo_url="https://github.com/killer23d/VaultWarden-OCI.git"
    local manifest_dir="$rendered_state_dir/config"
    local manifest_file="$manifest_dir/dr-manifest.env"
    existing_offline_recipient=""
    if [[ -f "$manifest_file" ]]; then
        existing_offline_recipient="$(_read_env_value OFFLINE_AGE_RECIPIENT "$manifest_file")"
        [[ "$existing_offline_recipient" =~ ^age1[a-z0-9]{58}$ ]] || existing_offline_recipient=""
    fi
    export PROJECT_STATE_DIR="$rendered_state_dir"
    install -d -m 0700 -o root -g root "$manifest_dir" "$rendered_state_dir/secrets" || return 1

    "${PROJECT_ROOT}/utilities/env-edit.sh" sync || return 1

    local tmp
    tmp=$(mktemp -p "$manifest_dir" dr-manifest.env.XXXXXX) || return 1
    {
        printf 'DOMAIN=%s\n' "$rendered_domain"
        printf 'REPO_URL=%s\n' "$recovery_repo_url"
        printf 'REPO_COMMIT=%s\n' "$repo_commit"
        printf 'OFFLINE_AGE_RECIPIENT=%s\n' "$existing_offline_recipient"
        printf 'STATE_LAYOUT_VERSION=1\n'
        printf 'MANIFEST_UPDATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$tmp" && chown root:root "$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$manifest_file" || { rm -f "$tmp"; return 1; }
    chown root:root "$manifest_file" || return 1
    chmod 0600 "$manifest_file" || return 1

    if [[ -f "$PROJECT_ROOT/docs/recovery-card.md" ]]; then
        tmp=$(mktemp -p "$manifest_dir" recovery-card.md.XXXXXX) || return 1
        sed -e "s|<DOMAIN>|$rendered_domain|g" -e "s|<REPO_URL>|$recovery_repo_url|g" -e "s|<REPO_COMMIT>|$repo_commit|g" \
            "$PROJECT_ROOT/docs/recovery-card.md" > "$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$manifest_dir/recovery-card.md" || { rm -f "$tmp"; return 1; }
    fi
}

create_docker_compose() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create docker-compose.yml"
        return 0
    fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ ! -f "$compose_template" ]]; then
        log_error "Template not found: $compose_template"
        return 1
    fi

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        docker compose -f "$compose_file" config >/dev/null 2>&1 && return 0
    fi

    local real_user real_group
    real_user=$(get_real_user)
    real_group=$(id -gn "$real_user")

    local compose_dir
    compose_dir="$(dirname "$compose_file")"

    local temp_compose
    temp_compose=$(_make_owned_temp "$compose_dir" "$real_user" "$real_group") || return 1

    cp "$compose_template" "$temp_compose" || { rm -f "$temp_compose"; return 1; }
    mv "$temp_compose" "$compose_file"     || { rm -f "$temp_compose"; return 1; }
    chmod 640 "$compose_file" || return 1
    log_success "docker-compose.yml written: $compose_file (owner: $real_user:$real_group, mode: 640)"
    return 0
}

_check_domain() {
    local domain="$1"

    if validate_domain "$domain"; then
        return 0
    fi

    local reason
    reason="$(_validate_domain_reason "$domain")"

    log_error "Invalid --domain value: '${domain}'"

    if [[ -n "$reason" ]]; then
        log_hint "$reason"
    fi

    log_hint "Pass a bare registered hostname, e.g.: --domain vault.yourdomain.com"
    exit 1
}

main() {
    (( EUID == 0 )) || { log_error "Must run as root (use: sudo $0 $*)"; exit 1; }

    [[ -n "$DOMAIN" ]]      || { log_error "--domain is required"; show_help; exit 1; }
    [[ -n "$ADMIN_EMAIL" ]] || { log_error "--email is required";  show_help; exit 1; }

    _check_domain "$DOMAIN"

    if ! validate_email "$ADMIN_EMAIL"; then
        log_error "Invalid --email value: '${ADMIN_EMAIL}'"
        log_hint  "Provide a valid email address, e.g.: --email you@yourdomain.com"
        exit 1
    fi

    [[ "$DRY_RUN" == "true" ]] && log_info "DRY RUN mode — no changes will be made"
    _setup_env_acquire_guard || exit $?

    create_env_file         || { log_error "Failed to create .env";               exit 1; }
    refresh_state_artifacts || { log_error "Failed to refresh state artifacts";   exit 1; }
    create_docker_compose   || { log_error "Failed to create docker-compose.yml"; exit 1; }

    log_success "Environment configuration complete"
}

_parse_args "$@"
main "$@"
