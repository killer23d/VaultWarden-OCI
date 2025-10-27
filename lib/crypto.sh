#!/usr/bin/env bash
# lib/crypto.sh - Age encryption and SOPS helpers for VaultWarden-OCI-NG
# Focused cryptographic operations

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_CRYPTO_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_CRYPTO_LIB_LOADED=1

# --- Configuration ---
readonly DEFAULT_AGE_KEY_FILE="secrets/keys/age-key.txt"
readonly DEFAULT_AGE_PUBLIC_KEY_FILE="secrets/keys/age-public-key.txt"
readonly DEFAULT_SECRETS_FILE="secrets/secrets.yaml"

# --- Age Key Operations ---

# Check if Age key exists and is accessible
check_age_key() {
    local key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$key_file" ]]; then
        return 1
    fi

    if [[ ! -r "$key_file" ]]; then
        return 1
    fi

    # Check permissions (should be 600)
    local perms
    perms=$(stat -c "%a" "$key_file" 2>/dev/null)
    [[ "$perms" == "600" ]]
}

# Generate new Age key pair
generate_age_keypair() {
    local private_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"
    local public_key_file="${2:-$DEFAULT_AGE_PUBLIC_KEY_FILE}"

    if ! command -v age-keygen >/dev/null 2>&1; then
        return 1
    fi

    # Create keys directory
    mkdir -p "$(dirname "$private_key_file")"

    # Generate private key
    age-keygen -o "$private_key_file" || return 1

    # Set secure permissions
    chmod 600 "$private_key_file"

    # Extract public key
    age-keygen -y "$private_key_file" > "$public_key_file" || return 1
    chmod 644 "$public_key_file"

    return 0
}

# Get public key from private key
get_public_key() {
    local private_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if ! check_age_key "$private_key_file"; then
        return 1
    fi

    if ! command -v age-keygen >/dev/null 2>&1; then
        return 1
    fi

    age-keygen -y "$private_key_file"
}

# --- Encryption/Decryption Operations ---

# Encrypt file with Age using public key
encrypt_file() {
    local input_file="$1"
    local output_file="$2"
    local public_key_file="${3:-$DEFAULT_AGE_PUBLIC_KEY_FILE}"

    if [[ ! -f "$input_file" ]]; then
        return 1
    fi

    if [[ ! -f "$public_key_file" ]]; then
        return 1
    fi

    if ! command -v age >/dev/null 2>&1; then
        return 1
    fi

    local public_key
    public_key=$(cat "$public_key_file") || return 1

    if [[ -n "$output_file" ]]; then
        age -r "$public_key" -o "$output_file" "$input_file"
    else
        age -r "$public_key" "$input_file"
    fi
}

# Decrypt file with Age using private key
decrypt_file() {
    local encrypted_file="$1"
    local output_file="$2"
    local private_key_file="${3:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$encrypted_file" ]]; then
        return 1
    fi

    if ! check_age_key "$private_key_file"; then
        return 1
    fi

    if ! command -v age >/dev/null 2>&1; then
        return 1
    fi

    if [[ -n "$output_file" ]]; then
        age -d -i "$private_key_file" "$encrypted_file" > "$output_file"
    else
        age -d -i "$private_key_file" "$encrypted_file"
    fi
}

# Encrypt data from stdin
encrypt_data() {
    local public_key_file="${1:-$DEFAULT_AGE_PUBLIC_KEY_FILE}"

    if [[ ! -f "$public_key_file" ]]; then
        return 1
    fi

    if ! command -v age >/dev/null 2>&1; then
        return 1
    fi

    local public_key
    public_key=$(cat "$public_key_file") || return 1

    age -r "$public_key"
}

# Decrypt data to stdout
decrypt_data() {
    local private_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if ! check_age_key "$private_key_file"; then
        return 1
    fi

    if ! command -v age >/dev/null 2>&1; then
        return 1
    fi

    age -d -i "$private_key_file"
}

# --- SOPS Operations ---

# Check if SOPS is available
check_sops_available() {
    command -v sops >/dev/null 2>&1
}

# Encrypt file with SOPS
sops_encrypt() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        return 1
    fi

    if ! check_sops_available; then
        return 1
    fi

    sops --encrypt --in-place "$input_file"
}

# Decrypt file with SOPS
sops_decrypt() {
    local encrypted_file="$1"
    local output_file="$2"

    if [[ ! -f "$encrypted_file" ]]; then
        return 1
    fi

    if ! check_sops_available; then
        return 1
    fi

    if [[ -n "$output_file" ]]; then
        sops -d "$encrypted_file" > "$output_file"
    else
        sops -d "$encrypted_file"
    fi
}

# Edit file with SOPS (interactive)
sops_edit() {
    local encrypted_file="$1"

    if [[ ! -f "$encrypted_file" ]]; then
        return 1
    fi

    if ! check_sops_available; then
        return 1
    fi

    sops "$encrypted_file"
}

# Test if file is SOPS encrypted
is_sops_encrypted() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # Check for SOPS metadata
    grep -q "sops:" "$file" 2>/dev/null
}

# --- P4 FIX: Removed get_secret function ---

# --- Utility Functions ---

# Generate secure random string
generate_secure_string() {
    local length="${1:-32}"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$length" | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        # Fallback to /dev/urandom
        < /dev/urandom tr -dc 'a-zA-Z0-9' | head -c "$length"
    fi
}

# Generate secure hex string
generate_hex_string() {
    local length="${1:-32}"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$length"
    else
        # Fallback to /dev/urandom
        < /dev/urandom tr -dc 'a-f0-9' | head -c "$((length * 2))"
    fi
}

# --- FIX #7: Removed dead code: load_secrets, set_secret, validate_age_key ---

# Export functions for use by scripts
export -f check_age_key generate_age_keypair get_public_key
export -f encrypt_file decrypt_file encrypt_data decrypt_data
export -f check_sops_available sops_encrypt sops_decrypt sops_edit is_sops_encrypted
# Removed get_secret from export
export -f generate_secure_string generate_hex_string

log_debug "Crypto library loaded successfully" 2>/dev/null || true

