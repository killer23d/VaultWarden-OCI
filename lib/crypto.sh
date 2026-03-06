#!/usr/bin/env bash
# lib/crypto.sh - Cryptographic operations library for VaultWarden-OCI-NG
# ENHANCED: Standardized error handling patterns - functions return, callers decide
# ADDED: Age key validation function for health checks and verification
# All functions use 'return' with exit codes, never 'exit'
#
# PATCHED BUGS (2026-03-06):
#   BUG-K1 [HIGH]   check_age_key(): stat -c '%a' is GNU-only; macOS/BSD needs
#                   stat -f '%OLp'. Replaced with portable _stat_octal_perms_local()
#                   helper defined below (mirrors the wrapper in security.sh).
#   BUG-K2 [HIGH]   secure_delete(): stat -c%s is GNU-only; macOS needs stat -f%z.
#                   Replaced with portable _stat_file_size() helper.
#   BUG-K3 [MEDIUM] generate_argon2_hash() CLI path: echo -n is not POSIX;
#                   on dash/zsh it outputs '-n'. Replaced with printf '%s'.

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_CRYPTO_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_CRYPTO_LIB_LOADED=1

# --- Configuration ---
DEFAULT_AGE_KEY_FILE="secrets/keys/age-key.txt"

# ---------------------------------------------------------------------------
# Portable stat helpers  (mirrors the wrappers in lib/security.sh)
#
# BUG-K1 / BUG-K2 FIX: GNU stat and BSD stat use different format strings.
# We detect which is present at call time rather than relying on a global flag.
# ---------------------------------------------------------------------------
_stat_octal_perms_local() {
    # Returns the octal permission string (e.g. "600") for the given path.
    local path="$1"
    if stat --version >/dev/null 2>&1; then
        stat -c '%a' "$path" 2>/dev/null   # GNU coreutils (Linux)
    else
        stat -f '%OLp' "$path" 2>/dev/null  # BSD / macOS
    fi
}

_stat_file_size() {
    # Returns the size in bytes of the given regular file.
    local path="$1"
    if stat --version >/dev/null 2>&1; then
        stat -c '%s' "$path" 2>/dev/null   # GNU
    else
        stat -f '%z' "$path" 2>/dev/null   # BSD / macOS
    fi
}

# ---------------------------------------------------------------------------
# _derive_age_public_key  KEY_FILE
#
# [MEDIUM FIX] Canonical helper to extract the Age public key from a private
# key file WITHOUT calling `age-keygen -y`, which is absent on some Ubuntu
# 22.04 age builds.  age-keygen always writes the public key as a comment:
#   # public key: age1...
# We grep for that comment and strip the prefix.  This works with every
# version of age that writes the standard comment format.
#
# This function is now the single source of truth for public-key derivation
# across the entire codebase (crypto.sh, secrets.sh, simple_key_resilience.sh).
# ---------------------------------------------------------------------------
_derive_age_public_key() {
    local key_file="$1"

    if [[ ! -f "$key_file" ]]; then
        log_error "Age key file not found: $key_file"
        return 1
    fi

    local pub_key
    pub_key=$(grep -m1 '^# public key:' "$key_file" | sed 's/^# public key: //')

    if [[ -z "$pub_key" ]]; then
        log_error "Cannot derive Age public key from: $key_file (missing '# public key:' comment)"
        return 1
    fi

    printf '%s\n' "$pub_key"
    return 0
}

# --- SOPS Operations ---

# Check if a file is SOPS encrypted - STANDARDIZED: Returns exit code
is_sops_encrypted() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for SOPS check: $file"
        return 1
    fi

    if grep -q "sops:" "$file" && grep -q "version:" "$file"; then
        return 0
    else
        return 1
    fi
}

# Decrypt SOPS file to stdout - STANDARDIZED: Returns exit code
decrypt_sops_file() {
    local file="$1"
    local age_key_file="${2:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$file" ]]; then
        log_error "SOPS file not found: $file"
        return 1
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if ! has_command sops; then
        log_error "sops command not available"
        return 1
    fi

    SOPS_AGE_KEY_FILE="$age_key_file" sops --decrypt "$file" 2>/dev/null
}

# Encrypt file with SOPS - STANDARDIZED: Returns exit code
# [MEDIUM FIX] Replaced `age-keygen -y` with _derive_age_public_key() for
# Ubuntu 22.04 compatibility and codebase consistency.
encrypt_sops_file() {
    local file="$1"
    local age_key_file="${2:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$file" ]]; then
        log_error "File to encrypt not found: $file"
        return 1
    fi

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if ! has_command sops; then
        log_error "sops command not available"
        return 1
    fi

    local age_public_key
    if ! age_public_key=$(_derive_age_public_key "$age_key_file"); then
        log_error "Failed to extract public key from: $age_key_file"
        return 1
    fi

    if ! sops --encrypt --age "$age_public_key" --in-place "$file" 2>/dev/null; then
        log_error "Failed to encrypt file with SOPS: $file"
        return 1
    fi

    return 0
}

# --- Age Operations ---

# Generate Age key pair - STANDARDIZED: Returns exit code
generate_age_key() {
    local output_file="$1"
    local overwrite="${2:-false}"

    if [[ -f "$output_file" ]]; then
        if [[ "$overwrite" == "true" ]]; then
            log_info "Removing existing Age key for regeneration: $output_file"
            if ! rm -f "$output_file"; then
                log_error "Failed to remove existing Age key: $output_file"
                return 1
            fi
        else
            log_error "Age key file already exists: $output_file (use overwrite=true to replace)"
            return 1
        fi
    fi

    if ! has_command age-keygen; then
        log_error "age-keygen command not available"
        return 1
    fi

    local key_dir
    key_dir=$(dirname "$output_file")
    if ! ensure_dir "$key_dir" 700; then
        return 1
    fi

    if ! age-keygen -o "$output_file" 2>/dev/null; then
        log_error "Failed to generate Age key: $output_file"
        return 1
    fi

    if ! secure_file "$output_file" 600; then
        return 1
    fi

    log_success "Age key generated: $output_file"
    return 0
}

# Get Age public key from private key file - delegates to _derive_age_public_key()
get_age_public_key() {
    local age_key_file="$1"
    _derive_age_public_key "$age_key_file"
}

# Check Age key validity - STANDARDIZED: Returns exit code
#
# BUG-K1 FIX: replaced stat -c "%a" (GNU-only) with _stat_octal_perms_local()
# which selects the correct format string for the host platform.
check_age_key() {
    local age_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    # BUG-K1 FIX: portable stat wrapper
    local key_perms
    key_perms=$(_stat_octal_perms_local "$age_key_file")
    if [[ "$key_perms" != "600" ]]; then
        log_error "Age key has incorrect permissions: ${key_perms:-<unreadable>} (should be 600)"
        return 1
    fi

    if ! _derive_age_public_key "$age_key_file" >/dev/null; then
        log_error "Age key file appears to be corrupted or missing public key comment"
        return 1
    fi

    log_debug "Age key validation passed: $age_key_file"
    return 0
}

# Encrypt data with Age (reads from stdin, writes to stdout)
encrypt_data() {
    local age_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if ! has_command age; then
        log_error "age command not available"
        return 1
    fi

    local public_key
    if ! public_key=$(get_age_public_key "$age_key_file"); then
        return 1
    fi

    if ! age -r "$public_key"; then
        log_error "Age encryption failed"
        return 1
    fi

    return 0
}

# Decrypt data with Age (reads from stdin, writes to stdout)
decrypt_data() {
    local age_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    if ! has_command age; then
        log_error "age command not available"
        return 1
    fi

    if ! age -d -i "$age_key_file"; then
        log_error "Age decryption failed"
        return 1
    fi

    return 0
}

# --- Secure Random Generation ---

# Generates a cryptographically strong random string of N characters (safe charset)
generate_secure_string() {
    local length="${1:-32}"
    local charset="${2:-A-Za-z0-9}"

    if [[ ! -r /dev/urandom ]]; then
        log_error "/dev/urandom is not available or not readable"
        return 1
    fi

    local random_string=""
    local attempt
    for attempt in {1..5}; do
        random_string=$(LC_ALL=C tr -dc "$charset" < /dev/urandom | head -c "$length" || true)

        if [[ ${#random_string} -ge $length ]]; then
            echo "$random_string"
            return 0
        fi

        sleep 1
    done

    log_error "Failed to generate secure random string from /dev/urandom"
    return 1
}

# Generate secure random password
# NOTE: charset includes shell-special characters ($, !, etc.).
# Callers MUST use `printf '%s' "$password"` (not `echo`) when passing the
# result to external commands.
generate_secure_password() {
    local length="${1:-24}"
    local charset="A-Za-z0-9!@#$%^&*()-_=+[]{}|;:,.<>?"

    if ! generate_secure_string "$length" "$charset"; then
        return 1
    fi

    return 0
}

# --- Argon2 Support Detection ---

check_argon2_support() {
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import argon2" 2>/dev/null; then
            echo "python"
            return 0
        fi
    fi

    if command -v argon2 >/dev/null 2>&1; then
        echo "cli"
        return 0
    fi

    return 1
}

# --- Hash Operations ---

# Generate Argon2id hash (for VaultWarden admin token)
#
# BUG-K3 FIX: CLI path previously used `echo -n "$password" | argon2`.
# echo -n is not POSIX; on dash and zsh it outputs the literal string '-n'
# followed by the password. Replaced with `printf '%s' "$password"` which
# is POSIX and behaves consistently across all shells.
generate_argon2_hash() {
    local password="$1"
    local hash=""
    local method

    method=$(check_argon2_support) || {
        log_error "No Argon2 implementation available"
        return 1
    }

    case "$method" in
        python)
            hash=$(printf '%s' "$password" | python3 -c "
import sys
from argon2 import PasswordHasher
from argon2 import Type
ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16, type=Type.ID)
password = sys.stdin.read()
print(ph.hash(password))
")
            ;;
        cli)
            # BUG-K3 FIX: was `echo -n "$password"` — not POSIX, broken on dash/zsh.
            local salt
            salt=$(generate_secure_string 16)
            hash=$(printf '%s' "$password" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e 2>/dev/null)
            ;;
    esac

    if [[ -z "$hash" ]]; then
        log_error "Failed to generate Argon2 hash"
        return 1
    fi

    printf '%s\n' "$hash"
    return 0
}

# Generate bcrypt hash (for Caddy basic auth)
#
# [MEDIUM FIX] Default cost documented: 12 (OWASP recommended minimum).
generate_bcrypt_hash() {
    local password="$1"
    local rounds="${2:-12}"

    [[ -z "$password" ]] && return 1

    local bcrypt_hash
    bcrypt_hash=$(printf '%s\n' "$password" | htpasswd -niBC "$rounds" user 2>/dev/null | cut -d: -f2)

    [[ -n "$bcrypt_hash" ]] || return 1

    printf '%s\n' "$bcrypt_hash"
    return 0
}

# --- File Integrity Operations ---

# Calculate SHA256 checksum
calculate_sha256() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for checksum: $file"
        return 1
    fi

    local checksum
    if has_command sha256sum; then
        if ! checksum=$(sha256sum "$file" | cut -d' ' -f1); then
            log_error "Failed to calculate SHA256 checksum: $file"
            return 1
        fi
    elif has_command shasum; then
        if ! checksum=$(shasum -a 256 "$file" | cut -d' ' -f1); then
            log_error "Failed to calculate SHA256 checksum: $file"
            return 1
        fi
    else
        log_error "No SHA256 calculator available (tried sha256sum and shasum)"
        return 1
    fi

    echo "$checksum"
    return 0
}

# Verify SHA256 checksum
verify_sha256() {
    local file="$1"
    local expected_checksum="$2"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for verification: $file"
        return 1
    fi

    local actual_checksum
    if ! actual_checksum=$(calculate_sha256 "$file"); then
        return 1
    fi

    if [[ "$actual_checksum" == "$expected_checksum" ]]; then
        log_debug "SHA256 verification successful: $file"
        return 0
    else
        log_error "SHA256 verification failed: $file"
        log_error "Expected: $expected_checksum"
        log_error "Actual:   $actual_checksum"
        return 1
    fi
}

# --- Secure File Operations ---

# Securely wipe file before deletion
#
# BUG-K2 FIX: stat -c%s is GNU-only; macOS/BSD needs stat -f%z.
# Replaced with portable _stat_file_size() wrapper.
secure_delete() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for secure deletion: $file"
        return 1
    fi

    if has_command shred; then
        if shred -vfz -n 3 "$file" 2>/dev/null; then
            log_debug "File securely deleted with shred: $file"
            return 0
        fi
    fi

    # Fallback: overwrite with random data then delete
    if has_command dd && [[ -c /dev/urandom ]]; then
        # BUG-K2 FIX: portable file size
        local file_size
        file_size=$(_stat_file_size "$file" 2>/dev/null || echo "4096")
        # Guard against empty/zero size to prevent dd bs=0 error
        [[ -z "$file_size" || "$file_size" -eq 0 ]] && file_size=4096
        if dd if=/dev/urandom of="$file" bs="$file_size" count=1 2>/dev/null; then
            rm -f "$file"
            log_debug "File securely deleted with dd: $file"
            return 0
        fi
    fi

    rm -f "$file"
    log_warn "File deleted but not securely wiped: $file"
    return 0
}

# --- Enhanced Security Validation ---

# Comprehensive cryptographic environment check
validate_crypto_environment() {
    log_debug "Validating cryptographic environment..."

    local issues=()

    if ! has_command age; then
        issues+=("age command not available")
    fi

    if ! has_command age-keygen; then
        issues+=("age-keygen command not available")
    fi

    if ! has_command sops; then
        issues+=("sops command not available")
    fi

    if [[ -f "$DEFAULT_AGE_KEY_FILE" ]]; then
        if ! check_age_key "$DEFAULT_AGE_KEY_FILE"; then
            issues+=("Default Age key validation failed")
        fi
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        log_error "Cryptographic environment validation failed:"
        for issue in "${issues[@]}"; do
            log_error "  - $issue"
        done
        return 1
    fi

    log_debug "Cryptographic environment validation passed"
    return 0
}

# Export functions for use by scripts
export -f _stat_octal_perms_local _stat_file_size
export -f _derive_age_public_key
export -f is_sops_encrypted decrypt_sops_file encrypt_sops_file
export -f generate_age_key get_age_public_key check_age_key encrypt_data decrypt_data
export -f generate_secure_string generate_secure_password check_argon2_support generate_argon2_hash generate_bcrypt_hash
export -f calculate_sha256 verify_sha256 secure_delete validate_crypto_environment
export DEFAULT_AGE_KEY_FILE

log_debug "Enhanced crypto library loaded successfully - standardized error handling with Age key validation" 2>/dev/null || true
