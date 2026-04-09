#!/usr/bin/env bash
# VaultWarden-OCI Setup Script
# Configures the VaultWarden deployment environment
# Usage: sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]

set -euo pipefail

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# Colors for output
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DOMAIN=""
ADMIN_EMAIL=""
OVERWRITE=false
NON_INTERACTIVE=false
SKIP_CHECKS=false
SKIP_DNS_CHECK=false
CLEAN_DOMAIN=""

show_help() {
    cat <<EOF
Usage: sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]

OPTIONS:
  --domain DOMAIN       Your VaultWarden domain (e.g. vault.example.com or https://vault.example.com)
  --email EMAIL         Administrator email address
  --overwrite           Overwrite existing .env file without prompting
  --non-interactive     Skip all interactive prompts
  --skip-checks         Skip system requirement checks (also skips DNS check)
  --skip-dns-check      Skip DNS propagation check only (use in CI / local testing)
  --help                Show this help message

EXAMPLE:
  sudo ./setup.sh --domain vault.example.com --email admin@example.com
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --overwrite) OVERWRITE=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --skip-checks) SKIP_CHECKS=true; SKIP_DNS_CHECK=true; shift ;;
        --skip-dns-check) SKIP_DNS_CHECK=true; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log_info()    { printf "${COLOR_BLUE}[INFO]${COLOR_RESET}  %s\n" "$1"; }
log_success() { printf "${COLOR_GREEN}[OK]${COLOR_RESET}    %s\n" "$1"; }
log_warn()    { printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s\n" "$1"; }
log_error()   { printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$1" >&2; }

validate_domain_secure() {
    local domain="$1"
    # Strip protocol if present
    domain="${domain#https://}"
    domain="${domain#http://}"
    # Remove trailing slash
    domain="${domain%/}"
    # Must not be empty after stripping
    [[ -n "$domain" ]] || return 1
    # Must look like a valid FQDN: labels separated by dots, no leading/trailing dots
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || return 1
    return 0
}

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1
    return 0
}

# =============================================================================
# VALIDATION
# =============================================================================

if [[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]; then show_help; exit 1; fi
if ! validate_domain_secure "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if ! validate_email "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

# Normalise: strip any protocol prefix from DOMAIN before processing.
# If the user passed 'vault.example.com' we add https://; if they passed
# 'https://vault.example.com' we preserve it exactly.
clean_domain="${DOMAIN#https://}"
clean_domain="${clean_domain#http://}"
clean_domain="${clean_domain%/}"
domain_with_protocol="https://${clean_domain}"

# =============================================================================
# SYSTEM CHECKS
# =============================================================================

if [[ "$SKIP_CHECKS" == "false" ]]; then
    log_info "Checking system requirements..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Check Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi

    # Check Docker Compose
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 is not available"
        exit 1
    fi

    log_success "System requirements met"
fi

# =============================================================================
# DNS PROPAGATION PRE-FLIGHT
#
# Rationale: Caddy requests a TLS certificate on the first `docker compose up`.
# If the domain does not yet point to this machine's public IP, the ACME
# HTTP-01 challenge will fail. Repeated failures consume the Let's Encrypt
# failed-authorizations rate limit (5 per hostname per hour) and can lock the
# domain out of certificate issuance for up to 6 hours.
#
# This check resolves the domain and compares it to the host's public IP
# BEFORE writing .env or starting any services. Mismatches produce a clear
# warning and — in interactive mode — require explicit admin confirmation
# before proceeding.
# =============================================================================

check_dns_propagation() {
    local domain="$1"

    log_info "Checking DNS propagation for ${domain}..."

    # --- Resolve domain to IP ------------------------------------------------
    local resolved_ip=""

    if command -v dig &>/dev/null; then
        # +time=3 +tries=2 keeps the timeout short on OCI where the default
        # resolver can be slow; +short emits only the A record value.
        resolved_ip=$(dig +short +time=3 +tries=2 "${domain}" A 2>/dev/null \
            | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | head -1 || true)
    fi

    # Fallback: nslookup (available on more minimal images)
    if [[ -z "$resolved_ip" ]] && command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "${domain}" 2>/dev/null \
            | awk '/^Address/ && NR>2 {print $2; exit}' \
            | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | head -1 || true)
    fi

    # --- Determine this host's public IPv4 -----------------------------------
    # api.ipify.org is Cloudflare/Akamai-backed; timeout=5 is generous for
    # an OCI instance that has outbound internet (required for ACME anyway).
    local host_ip=""
    host_ip=$(curl -sf --max-time 5 --connect-timeout 3 \
        "https://api.ipify.org" 2>/dev/null \
        | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)

    # --- Compare & decide ----------------------------------------------------
    if [[ -z "$resolved_ip" ]]; then
        _dns_preflight_warn \
            "Could not resolve ${domain} — DNS may not be configured yet." \
            "(resolved: <none>, host: ${host_ip:-unknown})"
        return
    fi

    if [[ -z "$host_ip" ]]; then
        log_warn "DNS pre-flight: cannot determine host public IP (no outbound connectivity?)."
        log_warn "Resolved ${domain} -> ${resolved_ip}. Proceeding anyway — verify manually."
        return
    fi

    if [[ "$resolved_ip" == "$host_ip" ]]; then
        log_success "DNS propagation OK: ${domain} -> ${resolved_ip} (matches host IP)"
        return
    fi

    _dns_preflight_warn \
        "DNS mismatch: ${domain} resolves to ${resolved_ip} but this host's public IP is ${host_ip}." \
        "Caddy's ACME certificate request will fail until DNS propagation completes."
}

# _dns_preflight_warn  — called when DNS does not match.
# In interactive mode: print warning and ask the admin to confirm.
# In non-interactive mode: print warning and exit 1.
_dns_preflight_warn() {
    local msg1="$1" msg2="${2:-}"

    printf "\n"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  *** DNS PRE-FLIGHT FAILED ***\n"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s\n" "$msg1"
    [[ -n "$msg2" ]] && printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s\n" "$msg2"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  If you start services now, Caddy may exhaust the Let's Encrypt\n"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  rate limit and lock this domain out of TLS issuance for ~6 hours.\n"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  Wait for DNS propagation to complete before starting the stack.\n"
    printf "\n"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_error "DNS pre-flight failed in non-interactive mode. Exiting."
        log_error "Pass --skip-dns-check to bypass this check (e.g. in CI / local testing)."
        exit 1
    fi

    # Interactive: let the admin decide
    local response=""
    read -r -p "  Proceed anyway? This may cause a Let's Encrypt rate-limit. [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Aborted. Re-run after DNS has propagated."
        exit 0
    fi

    log_warn "Proceeding at operator request. Verify DNS before starting the stack."
    printf "\n"
}

# Run the DNS pre-flight (skipped by --skip-checks or --skip-dns-check)
if [[ "$SKIP_DNS_CHECK" == "false" ]]; then
    check_dns_propagation "${clean_domain}"
fi

# =============================================================================
# DETERMINE DETECTED SSH LOG PATH
# =============================================================================

detected_ssh_log_path="/var/log/secure"
if [[ -f "/var/log/auth.log" ]]; then
    detected_ssh_log_path="/var/log/auth.log"
elif [[ -f "/var/log/secure" ]]; then
    detected_ssh_log_path="/var/log/secure"
fi

# =============================================================================
# DETERMINE USER/GROUP IDs
# =============================================================================

user_id=$(id -u)
group_id=$(id -g)

# If running as root via sudo, use the invoking user's IDs
if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    user_id=$(id -u "$SUDO_USER")
    group_id=$(id -g "$SUDO_USER")
fi

# =============================================================================
# ENV FILE SETUP
# =============================================================================

setup_env_file() {
    local env_file="$1"
    local domain_with_protocol="$2"
    local clean_domain="$3"

    # Check for existing .env
    if [[ -f "$env_file" ]]; then
        if [[ "$OVERWRITE" == "false" ]] && [[ "$NON_INTERACTIVE" == "false" ]]; then
            log_warn ".env file already exists"
            read -r -p "Overwrite? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log_info "Keeping existing .env file"
                return 0
            fi
        elif [[ "$OVERWRITE" == "false" ]]; then
            # Check if .env already has the right domain
            local domain_matches=false
            local email_matches=false
            grep -qF "DOMAIN=$domain_with_protocol" "$env_file"       && domain_matches=true
            grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL"     "$env_file"       && email_matches=true
            if [[ "$domain_matches" == "true" ]] && [[ "$email_matches" == "true" ]]; then
                log_info ".env already configured correctly, skipping"
                return 0
            fi
        fi
    fi

    # Copy from example if needed
    if [[ ! -f "$env_file" ]]; then
        if [[ ! -f "$ENV_EXAMPLE" ]]; then
            log_error ".env.example not found at $ENV_EXAMPLE"
            return 1
        fi
        cp "$ENV_EXAMPLE" "$env_file"
        log_info "Created .env from .env.example"
    fi

    CLEAN_DOMAIN="$clean_domain"

    local temp_env
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1

    AWK_DOMAIN="$domain_with_protocol" \
    AWK_EMAIL="$ADMIN_EMAIL" \
    AWK_UID="$user_id" \
    AWK_GID="$group_id" \
    AWK_SMTP_FROM="noreply@$clean_domain" \
    AWK_SSH_LOG="$detected_ssh_log_path" \
    awk '
        {
            sub(/^DOMAIN=.*/, "DOMAIN=" ENVIRON["AWK_DOMAIN"]);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/, "PUID=" ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/, "PGID=" ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" ENVIRON["AWK_SMTP_FROM"]);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ENVIRON["AWK_SSH_LOG"]);
            print;
        }' "$env_file" > "$temp_env"

    # Atomic replace
    mv "$temp_env" "$env_file"
    chmod 640 "$env_file"

    log_success ".env configured"
    return 0
}

# =============================================================================
# SECRETS DIRECTORY SETUP
# =============================================================================

setup_secrets_dir() {
    local secrets_dir="${SCRIPT_DIR}/secrets/.docker_secrets"

    mkdir -p "$secrets_dir"
    chmod 700 "${SCRIPT_DIR}/secrets"
    chmod 700 "$secrets_dir"

    log_success "Secrets directory ready"
}

# =============================================================================
# STATE DIRECTORY SETUP
# =============================================================================

setup_state_dirs() {
    # Load PROJECT_STATE_DIR from .env if available
    local state_dir
    state_dir=$(grep -m1 '^PROJECT_STATE_DIR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
    state_dir="${state_dir:-/var/lib/vaultwarden}"

    local dirs=(
        "$state_dir/data"
        "$state_dir/logs/vaultwarden"
        "$state_dir/logs/caddy"
        "$state_dir/logs/fail2ban"
        "$state_dir/logs/postfix"
        "$state_dir/caddy/data"
        "$state_dir/caddy/config"
        "$state_dir/fail2ban"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    # Caddy log files must be pre-created as root:root 644 so that the Caddy
    # container (running as root) can open them even after the init container
    # chowns /logs to PUID:PGID.
    touch "$state_dir/logs/caddy/access.log"
    touch "$state_dir/logs/caddy/security.log"
    chown root:root "$state_dir/logs/caddy/access.log" \
                    "$state_dir/logs/caddy/security.log"
    chmod 644 "$state_dir/logs/caddy/access.log" \
              "$state_dir/logs/caddy/security.log"
    chmod 755 "$state_dir/logs/caddy"

    # Fail2ban db dir must be root:root 755 (crazymax/fail2ban runs as root)
    chown root:root "$state_dir/fail2ban"
    chmod 755       "$state_dir/fail2ban"

    # Data and other logs owned by PUID:PGID
    chown -R "${user_id}:${group_id}" "$state_dir/data" \
                                      "$state_dir/logs/vaultwarden" \
                                      "$state_dir/logs/fail2ban" \
                                      "$state_dir/logs/postfix"

    log_success "State directories ready at $state_dir"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

log_info "Starting VaultWarden-OCI setup..."
log_info "Domain: $domain_with_protocol"
log_info "Email:  $ADMIN_EMAIL"

setup_env_file   "$ENV_FILE" "$domain_with_protocol" "$clean_domain"
setup_secrets_dir
setup_state_dirs

printf "\n"
printf "${COLOR_GREEN}Setup complete!${COLOR_RESET}\n"
printf "\n"
printf "Next steps:\n"
printf '1. [ ] Domain Name:   %s%s%s\n' "${COLOR_GREEN}" "${CLEAN_DOMAIN:-Not Set}" "${COLOR_RESET}"
printf '2. [ ] Email:         %s%s%s\n' "${COLOR_GREEN}" "${ADMIN_EMAIL}" "${COLOR_RESET}"
printf '3. [ ] Init secrets:  %ssudo ./edit-secrets.sh --init%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
printf '4. [ ] Copy compose:  %scp docker-compose.yml.example docker-compose.yml%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
printf '5. [ ] Start stack:   %sdocker compose up -d%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
printf '\n'
printf '   ► Verify: DOMAIN and ADMIN_EMAIL are correct\n'
