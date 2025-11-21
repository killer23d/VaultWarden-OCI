#!/usr/bin/env bash
# setup-secrets.sh - Interactive secret population for VaultWarden-OCI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SECRETS_FILE="secrets/secrets.yaml"
AGE_KEY_FILE="secrets/keys/age-key.txt"

require_tools() {
    for bin in sops python3 docker jq; do
        command -v "$bin" >/dev/null || { echo "Missing required: $bin" >&2; exit 1; }
    done
}

# Helpers: Argon2 hash via Python (ensure argon2-cffi installed)
argon2_hash() {
    python3 -c "from argon2 import PasswordHasher; print(PasswordHasher().hash('$1'))"
}

# Bcrypt hash via Caddy container
bcrypt_hash() {
    echo "$1" | docker run --rm -i ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password --stdin
}

# Secure random
rand() { LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "${1:-24}"; }

edit_yaml() {
    # Decrypt, edit in memory, and re-encrypt
    local tmp
    tmp=$(mktemp)
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d "$SECRETS_FILE" > "$tmp"
    "$@"
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --encrypt "$tmp" > "$SECRETS_FILE"
    rm -f "$tmp"
}

echo "VaultWarden Interactive Secrets Setup"
require_tools

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Run setup.sh first to generate $SECRETS_FILE"
    exit 1
fi

# Interactive prompt for all values (or --auto for random)
echo "Generating secrets. Leave blank to keep existing or set a new value."
edit_yaml bash -c '
  replace() {
    local key="$1" prompt="$2" is_pw="$3" genfunc="$4" secret old
    old=$(grep -E "^$key:" "$0" | sed -E "s/^$key: *//")
    if [[ "$is_pw" == "y" ]]; then
      read -s -p "$prompt: " secret; echo
      [[ -z "$secret" && "$old" != PLACEHOLDER_NOT_CONFIGURED ]] && secret="$old"
    else
      read -p "$prompt: " secret
      [[ -z "$secret" && "$old" != PLACEHOLDER_NOT_CONFIGURED ]] && secret="$old"
    fi
    if [[ "$key" == "admin_token" ]] && [[ -n "$secret" ]] && [[ "$secret" != "$old" ]]; then
      secret='"$(argon2_hash "$secret")"'
    elif [[ "$key" == "admin_basic_auth_hash" ]] && [[ -n "$secret" ]] && [[ "$secret" != "$old" ]]; then
      secret='"$(bcrypt_hash "$secret")"'
    elif [[ "$key" == "backup_passphrase" ]] && [[ -z "$secret" ]]; then
      secret='"$(rand 32)"'
    elif [[ -z "$secret" ]]; then
      secret=PLACEHOLDER_NOT_CONFIGURED
    fi
    sed -i -E "s|^($key:).*|\1 $secret|" "$0"
  }
  replace admin_token "VaultWarden admin password (will be Argon2-hashed)" "y"
  replace admin_basic_auth_hash "Caddy admin password for /admin (will be bcrypt-hashed)" "y"
  replace smtp_password "SMTP password (for email notifications)" "y"
  replace backup_passphrase "Backup encryption passphrase (leave blank for random)" "n"
  replace push_installation_id "Bitwarden push notification installation ID (optional)" "n"
  replace push_installation_key "Bitwarden push notification key (optional)" "n"
  replace caddy_cloudflare_dns_token "Cloudflare DNS API token" "n"
  replace fail2ban_cloudflare_firewall_token "Cloudflare Firewall API token" "n"
'

echo "Secrets encrypted and saved to $SECRETS_FILE"
echo "You may now start VaultWarden. Re-run this script at any time to update secrets."
