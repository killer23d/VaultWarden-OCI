#!/usr/bin/env bash
# lib/crypto.sh - Cryptographic operations library for VaultWarden-OCI-NG
# All functions use 'return' with exit codes, never 'exit'

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_CRYPTO_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_CRYPTO_LIB_LOADED=1

set -euo pipefail

# --- Configuration ---
DEFAULT_AGE_KEY_FILE="secrets/keys/age-key.txt"

# Security configuration (also used by security functions merged from lib/security.sh)
readonly SECURITY_MIN_PASSWORD_LENGTH=12
readonly SECURITY_MAX_FAILED_ATTEMPTS=3
readonly SECURITY_LOCKOUT_DURATION=300  # 5 minutes

# ---------------------------------------------------------------------------
# Portable stat helpers
#
# GNU stat and BSD stat use different format strings.
# We detect which is present at call time rather than relying on a global flag.
# ---------------------------------------------------------------------------
_stat_octal_perms() {
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

_stat_owner() {
    local path="$1"
    if stat --version >/dev/null 2>&1; then
        stat -c '%U' "$path" 2>/dev/null
    else
        stat -f '%Su' "$path" 2>/dev/null
    fi
}

_stat_group() {
    local path="$1"
    if stat --version >/dev/null 2>&1; then
        stat -c '%G' "$path" 2>/dev/null
    else
        stat -f '%Sg' "$path" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# _derive_age_public_key  KEY_FILE
#
# Extract the bare age1... public key from an age private key file.
# grep for the canonical comment prefix '^# public key:' then strip the
# prefix with sed so only the bare age1... key is returned.
# ---------------------------------------------------------------------------
_derive_age_public_key() {
    local key_file="$1"

    if [[ ! -f "$key_file" ]]; then
        log_error "Age key file not found: $key_file"
        return 1
    fi

    local pub_key
    pub_key=$(grep -m1 '^# public key:' "$key_file" \
              | sed 's/^# public key: //')

    if [[ -z "$pub_key" ]]; then
        log_error "Cannot derive Age public key from: $key_file (missing '# public key:' comment)"
        return 1
    fi

    # Sanity-check: all age public keys start with 'age1'
    if [[ "$pub_key" != age1* ]]; then
        log_error "Derived Age public key has unexpected format in: $key_file (got: ${pub_key:0:20}...)"
        return 1
    fi

    printf '%s\n' "$pub_key"
    return 0
}

# --- SOPS Operations ---

# Check if a file is SOPS encrypted - STANDARDIZED: Returns exit code
# Requires top-level 'sops:' key AND nested 'mac:' field to avoid
# false positives on any YAML file that happens to contain a 'sops:' key.
is_sops_encrypted() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for SOPS check: $file"
        return 1
    fi

    # A SOPS-encrypted file always has a top-level 'sops:' map AND a 'mac:' field within it
    grep -q '^sops:' "$file" && grep -q '^\s*mac:' "$file"
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
#
# Encrypts to a mktemp staging file and atomically renames it over the
# original only on success, preventing truncation/destruction of the target
# file on any error (malformed YAML, missing .sops.yaml rule, etc.).
#
# chmod 600 is applied to the staging file immediately after mktemp, before
# any content is written, to eliminate the world-readable race window between
# mktemp (creates at process umask) and the subsequent SOPS write.
#
# Always passes --input-type yaml --output-type yaml so SOPS does not try to
# infer the format from the staging file's extension, preventing failures when
# the staging filename has no recognised extension.
#
# sops stderr is captured and emitted via log_error on failure instead of
# being silently swallowed.
#
# After the atomic mv, a sops -d round-trip verifies the ciphertext is
# readable with the current Age key. sops --encrypt exits 0 even when the
# recipient key in .sops.yaml is stale or rotated, so the round-trip catches
# silently unreadable ciphertext before it reaches startup:
#   1. Before mv, write a pre-write backup (install -m 600) of the original
#      plaintext staging file.
#   2. After mv succeeds, run `sops -d <live_file> > /dev/null`.
#   3. On success: remove the backup, return 0.
#   4. On failure: restore the original file from the backup, remove the
#      backup, emit a clear diagnostic including the Age key path and
#      .sops.yaml location, return 1.
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

    # Use a .yaml suffix so SOPS can always infer the format on this side too
    # (belt-and-braces alongside the explicit --input-type flag below).
    local tmp_file
    tmp_file=$(mktemp "${file%.*}.sops.XXXXXX.yaml") || {
        log_error "Failed to create temp file for SOPS encryption: $file"
        return 1
    }

    install -m 600 /dev/null "$tmp_file"

    # Copy original content into the temp file so SOPS can read its format
    if ! cp -- "$file" "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "Failed to copy file for SOPS encryption: $file"
        return 1
    fi

    local sops_stderr
    local sops_rc=0
    sops_stderr=$(sops --encrypt \
        --age "$age_public_key" \
        --input-type yaml \
        --output-type yaml \
        --in-place "$tmp_file" 2>&1) || sops_rc=$?

    if [[ $sops_rc -ne 0 ]]; then
        rm -f "$tmp_file"
        log_error "Failed to encrypt file with SOPS: $file"
        if [[ -n "$sops_stderr" ]]; then
            log_error "sops error: $sops_stderr"
        fi
        return 1
    fi

    local pre_write_backup
    pre_write_backup=$(mktemp "${file%.*}.pre-enc.XXXXXX") || {
        # Backup creation failure is non-fatal for the encrypt path itself,
        # but we must skip the round-trip check because we have no restore
        # point. Log a warning and proceed without validation.
        log_warn "encrypt_sops_file: could not create pre-write backup for round-trip check; skipping validation"
        if ! mv -- "$tmp_file" "$file"; then
            rm -f "$tmp_file"
            log_error "Failed to atomically replace file after SOPS encryption: $file"
            return 1
        fi
        return 0
    }
    install -m 600 /dev/null "$pre_write_backup"
    cp -- "$file" "$pre_write_backup"

    # Atomic replace — original is only overwritten after successful encryption.
    if ! mv -- "$tmp_file" "$file"; then
        rm -f "$tmp_file" "$pre_write_backup"
        log_error "Failed to atomically replace file after SOPS encryption: $file"
        return 1
    fi

    local rt_stderr
    local rt_rc=0
    { set +x; } 2>/dev/null
    rt_stderr=$(SOPS_AGE_KEY_FILE="$age_key_file" \
                sops --decrypt \
                --input-type yaml \
                --output-type yaml \
                "$file" > /dev/null 2>&1) || rt_rc=$?

    if [[ $rt_rc -ne 0 ]]; then
        # Round-trip failed: restore the original plaintext file so the
        # caller can retry after fixing the key / .sops.yaml, then abort.
        log_error "encrypt_sops_file: SOPS round-trip validation FAILED for: $file"
        log_error "  The ciphertext was written successfully but cannot be decrypted."
        log_error "  This typically means the Age public key in .sops.yaml is stale,"
        log_error "  rotated, or does not match the private key at: $age_key_file"
        log_error "  Check: cat .sops.yaml   (confirm 'age:' recipient matches your key)"
        log_error "  Check: age-keygen -y $age_key_file   (derive the current public key)"
        if [[ -n "${rt_stderr:-}" ]]; then
            log_error "  sops decrypt error: $rt_stderr"
        fi
        log_error "  Restoring original file from pre-write backup..."
        if cp -- "$pre_write_backup" "$file"; then
            log_info "  Original file restored successfully."
        else
            log_error "  CRITICAL: failed to restore original file from backup: $pre_write_backup"
            log_error "  Manual recovery required. Backup is at: $pre_write_backup"
            # Do NOT remove the backup if restore failed — it is the only copy.
            return 1
        fi
        rm -f "$pre_write_backup"
        return 1
    fi

    # Round-trip passed: clean up backup and return success.
    rm -f "$pre_write_backup"
    log_debug "encrypt_sops_file: round-trip validation passed for: $file"
    return 0
}

# --- Age Operations ---

# Generate Age key pair - STANDARDIZED: Returns exit code
#
# Sets umask 077 before calling age-keygen so the file is born mode 600
# (owner r/w only), then restores the original umask. chmod 600 is kept
# as belt-and-braces.
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

    local _saved_umask
    _saved_umask=$(umask)
    umask 077
    local _keygen_rc=0
    age-keygen -o "$output_file" 2>/dev/null || _keygen_rc=$?
    umask "$_saved_umask"  # always restore

    if [[ $_keygen_rc -ne 0 ]]; then
        log_error "Failed to generate Age key: $output_file"
        rm -f "$output_file" 2>/dev/null || true
        return 1
    fi

    # Belt-and-braces: enforce 600 even if umask was overridden externally
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
# Validates permissions (must be 600), AGE-SECRET-KEY-1 prefix, and
# performs a full encrypt/decrypt round-trip to verify key material integrity.
check_age_key() {
    local age_key_file="${1:-$DEFAULT_AGE_KEY_FILE}"

    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi

    local key_perms
    key_perms=$(_stat_octal_perms "$age_key_file")
    if [[ "$key_perms" != "600" ]]; then
        log_error "Age key has incorrect permissions: ${key_perms:-<unreadable>} (should be 600)"
        return 1
    fi

    # We deliberately do NOT print the key value in any log message.
    local priv_key_line
    priv_key_line=$(grep -m1 '^AGE-SECRET-KEY-1' "$age_key_file" 2>/dev/null || true)
    if [[ -z "$priv_key_line" ]]; then
        log_error "Age key file does not contain a valid AGE-SECRET-KEY-1 private key line: $age_key_file"
        return 1
    fi

    local age_public_key
    if ! age_public_key=$(_derive_age_public_key "$age_key_file"); then
        log_error "Age key file appears to be corrupted or missing public key comment"
        return 1
    fi

    if has_command age; then
        local test_plaintext="vaultwarden-age-key-check"
        local tmp_enc
        tmp_enc=$(mktemp) || {
            log_error "check_age_key: cannot create temp file for round-trip test — key NOT verified"
            return 1
        }
        install -m 600 /dev/null "$tmp_enc"

        local round_trip_ok=false
        if printf '%s' "$test_plaintext" \
               | age -r "$age_public_key" -o "$tmp_enc" 2>/dev/null; then
            local decrypted
            if decrypted=$(age -d -i "$age_key_file" "$tmp_enc" 2>/dev/null); then
                if [[ "$decrypted" == "$test_plaintext" ]]; then
                    round_trip_ok=true
                else
                    log_error "check_age_key: decrypt round-trip produced wrong output — key may be corrupt. Restore from backup: ${age_key_file}.bak or re-run key generation."
                fi
            fi
        fi
        rm -f "$tmp_enc"

        if [[ "$round_trip_ok" != "true" ]]; then
            log_error "Age key round-trip encrypt/decrypt failed: $age_key_file (private key may be corrupted)"
            return 1
        fi
    else
        log_warn "check_age_key: 'age' binary not found; skipping round-trip test"
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
#
# Uses dd bs=1 count=$length to avoid SIGPIPE issues with tr | head -c.
# Strict -eq assertion on length; no sleep between retries.
generate_secure_string() {
    local length="${1:-32}"
    local charset="${2:-A-Za-z0-9}"

    if [[ ! -r /dev/urandom ]]; then
        log_error "/dev/urandom is not available or not readable"
        return 1
    fi

    local random_string=""
    local attempt
    # shellcheck disable=SC2034  # attempt is the for loop variable; the body iterates only for the count
    for attempt in {1..5}; do
        local _pipe_rc=0
        random_string=$(LC_ALL=C tr -dc "$charset" < /dev/urandom \
                        | dd bs=1 count="$length" 2>/dev/null) || _pipe_rc=$?

        # Strict equality: dd bs=1 count=$length must yield exactly $length
        # bytes.  Any shortfall (pipeline error, empty charset, partial read)
        # is treated as a failure and retried.
        if [[ ${#random_string} -eq $length ]]; then
            printf '%s' "$random_string"
            return 0
        fi
        # /dev/urandom never blocks on modern Linux; no sleep needed here.
    done

    log_error "Failed to generate secure random string from /dev/urandom after 5 attempts"
    return 1
}

# Generate secure random password
#
# NOTE: charset includes shell-special characters ($, !, etc.).
# Callers MUST use `printf '%s' "$password"` (not `echo`) when passing the
# result to external commands.
generate_secure_password() {
    local length="${1:-24}"
    local charset=$'A-Za-z0-9!@#$%^&*()-_=+[]{}|;:,.<>?'

    if ! generate_secure_string "$length" "$charset"; then
        return 1
    fi

    return 0
}

# --- Argon2 Support Detection ---

check_argon2_support() {
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import argon2" 2>/dev/null; then
            printf 'python\n'
            return 0
        fi
    fi

    if command -v argon2 >/dev/null 2>&1; then
        printf 'cli\n'
        return 0
    fi

    return 1
}

# --- Hash Operations ---

# Generate Argon2id hash (for VaultWarden admin token)
#
# Uses printf '%s' (not echo -n) for POSIX compatibility.
# Python path caps stdin at 1024 bytes to prevent runaway memory on corrupt input.
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
password = sys.stdin.read(1024)
print(ph.hash(password))
")
            ;;
        cli)
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
# Default cost: 12 (OWASP recommended minimum).
# Cost factor must be in [10, 31]; values outside this range are rejected.
generate_bcrypt_hash() {
    local password="$1"
    local rounds="${2:-12}"

    [[ -z "$password" ]] && return 1

    if ! has_command htpasswd; then
        log_error "htpasswd not available — install apache2-utils: sudo apt install apache2-utils"
        return 1
    fi

    if ! [[ "$rounds" =~ ^[0-9]+$ ]] || ! (( rounds >= 10 && rounds <= 31 )); then
        log_error "bcrypt cost $rounds out of range [10-31] — refusing to generate weak hash"
        return 1
    fi

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

    printf '%s\n' "$checksum"
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

# ---------------------------------------------------------------------------
# write_file_integrity FILE
#
# Writes two sidecar files:
#   FILE.sha256       — plain SHA-256 hex digest (for legacy callers)
#   FILE.sha256.hmac  — HMAC-SHA256 of the digest using FILE_INTEGRITY_HMAC_KEY
#                       (written only when the env var is set)
#
# Callers should set FILE_INTEGRITY_HMAC_KEY to a secret random string and
# store it separately from the monitored files (e.g. in SOPS secrets).
# ---------------------------------------------------------------------------
write_file_integrity() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "write_file_integrity: file not found: $file"
        return 1
    fi

    local checksum
    if ! checksum=$(calculate_sha256 "$file"); then
        return 1
    fi

    printf '%s\n' "$checksum" > "${file}.sha256" || {
        log_error "write_file_integrity: failed to write ${file}.sha256"
        return 1
    }

    if [[ -n "${FILE_INTEGRITY_HMAC_KEY:-}" ]]; then
        if ! has_command openssl; then
            log_warn "write_file_integrity: openssl not available; skipping HMAC sidecar"
            return 0
        fi
        local hmac
        hmac=$(printf '%s' "$checksum" \
               | openssl dgst -sha256 -hmac "${FILE_INTEGRITY_HMAC_KEY}" \
               | sed 's/^.* //')
        printf '%s\n' "$hmac" > "${file}.sha256.hmac" || {
            log_error "write_file_integrity: failed to write ${file}.sha256.hmac"
            return 1
        }
        log_debug "write_file_integrity: wrote plain SHA-256 and HMAC sidecar for: $file"
    else
        log_debug "write_file_integrity: wrote plain SHA-256 sidecar for: $file (no HMAC key set)"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# verify_file_integrity FILE
# ---------------------------------------------------------------------------
verify_file_integrity() {
    local file="$1"
    local checksum_file="${2:-${file}.sha256}"

    if [[ ! -f "$file" ]]; then
        log_error "File not found for integrity verification: $file"
        return 1
    fi

    if [[ ! -f "$checksum_file" ]]; then
        log_error "Checksum file not found: $checksum_file"
        return 1
    fi

    local stored_checksum
    stored_checksum=$(cat "$checksum_file") || {
        log_error "verify_file_integrity: failed to read checksum file: $checksum_file"
        return 1
    }
    # Extract just the first whitespace-delimited token (hex digest).
    # awk '{print $1}' handles both bare-digest and full sha256sum output formats.
    stored_checksum=$(awk '{print $1}' <<< "$stored_checksum")

    if [[ -n "${FILE_INTEGRITY_HMAC_KEY:-}" ]]; then
        if ! has_command openssl; then
            log_error "verify_file_integrity: FILE_INTEGRITY_HMAC_KEY is set but openssl is not available"
            return 1
        fi

        local hmac_file="${checksum_file}.hmac"
        if [[ ! -f "$hmac_file" ]]; then
            log_error "verify_file_integrity: HMAC sidecar missing: $hmac_file (was write_file_integrity() called?)"
            return 1
        fi

        local stored_hmac
        stored_hmac=$(cat "$hmac_file") || {
            log_error "verify_file_integrity: failed to read HMAC file: $hmac_file"
            return 1
        }
        stored_hmac=$(awk '{print $1}' <<< "$stored_hmac")

        local expected_hmac
        expected_hmac=$(printf '%s' "$stored_checksum" \
                        | openssl dgst -sha256 -hmac "${FILE_INTEGRITY_HMAC_KEY}" \
                        | sed 's/^.* //')

        if [[ "$expected_hmac" != "$stored_hmac" ]]; then
            log_error "verify_file_integrity: HMAC verification FAILED for sidecar: $checksum_file"
            log_error "  Sidecar may have been tampered with alongside the monitored file."
            return 1
        fi
        log_debug "verify_file_integrity: HMAC sidecar authenticated for: $file"
    else
        log_warn "verify_file_integrity: FILE_INTEGRITY_HMAC_KEY is not set; sidecar is unauthenticated."
        log_warn "  An attacker who replaces both the file and its .sha256 sidecar will pass this check."
        log_warn "  Set FILE_INTEGRITY_HMAC_KEY and use write_file_integrity() to enable authenticated checking."
    fi

    # Plain SHA-256 comparison (always performed; HMAC authentication above
    # ensures the stored_checksum value is trustworthy when the key is set).
    local actual_checksum
    if ! actual_checksum=$(calculate_sha256 "$file"); then
        return 1
    fi

    if [[ "$actual_checksum" == "$stored_checksum" ]]; then
        log_debug "File integrity verified: $file"
        return 0
    else
        log_error "File integrity check FAILED: $file"
        log_error "  Expected: $stored_checksum"
        log_error "  Actual:   $actual_checksum"
        return 1
    fi
}

# --- Secure File Operations ---

# Securely wipe file before deletion
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
        local file_size
        file_size=$(_stat_file_size "$file" 2>/dev/null || printf '4096')
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


# ---------------------------------------------------------------------------
# simple_verify_age_key
#
# Verifies age key existence, permissions (auto-corrects if needed),
# and performs a full encrypt/decrypt roundtrip.
# ---------------------------------------------------------------------------
simple_verify_age_key() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"

    # Check 1: File exists
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key missing: $age_key"
        log_error "If you are restoring a backup, see BACKUP-RESTORE.md for key recovery steps."
        return 1
    fi

    # Check 2: Permissions (auto-fix if needed)
    local perms
    perms=$(_stat_octal_perms "$age_key" 2>/dev/null || echo "")
    if [[ "$perms" != "600" ]]; then
        log_warn "Age key permissions were ${perms:-<unreadable>} (expected 600) — auto-correcting to 600"
        chmod 600 "$age_key"
    fi

    local real_user real_group
    real_user=$(get_real_user 2>/dev/null || echo "root")
    real_group=$(id -gn "$real_user" 2>/dev/null || echo "$real_user")
    local current_owner
    current_owner=$(stat -c '%U:%G' "$age_key" 2>/dev/null || stat -f '%Su:%Sg' "$age_key" 2>/dev/null || echo "")
    if [[ -n "$current_owner" && "$current_owner" != "${real_user}:${real_group}" ]]; then
        log_warn "Age key ownership was '${current_owner}' (expected '${real_user}:${real_group}') — auto-correcting"
        if [[ "$(id -u)" -eq 0 ]]; then
            chown "${real_user}:${real_group}" "$age_key" 2>/dev/null || \
                log_warn "Could not restore ownership of $age_key to ${real_user}:${real_group}"
        else
            log_warn "Cannot correct ownership of $age_key — re-run with sudo (sudo make key-health)"
        fi
    elif [[ -n "$current_owner" ]]; then
        # Ownership is already correct — no action needed.
        :
    else
        # Could not read ownership at all — attempt chown only if root.
        if [[ "$(id -u)" -eq 0 ]]; then
            chown "${real_user}:${real_group}" "$age_key" 2>/dev/null || \
                log_warn "Could not restore ownership of $age_key to ${real_user}:${real_group}"
        else
            log_warn "Cannot verify ownership of $age_key — re-run with sudo for full check"
        fi
    fi

    # Check 3: Validity — Encrypt/Decrypt roundtrip
    local test_data
    test_data="vw-key-check-$(date +%s)"
    local result

    local public_key
    if ! public_key=$(_derive_age_public_key "$age_key"); then
        log_error "Age key corrupted: Cannot extract public key"
        return 1
    fi

    if ! result=$(printf '%s' "$test_data" | age -r "$public_key" 2>/dev/null | age -d -i "$age_key" 2>/dev/null); then
        log_error "Age key encryption/decryption test failed"
        return 1
    fi

    if [[ "$result" != "$test_data" ]]; then
        log_error "Age key data integrity check failed"
        return 1
    fi

    log_debug "Age key health check: OK"
    return 0
}

create_password_manager_escrow() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local output_file="$1"

    if [[ -z "$output_file" ]]; then
        log_error "Output file path required for escrow creation"
        return 1
    fi

    log_info "Creating password manager-ready Age key backup..."

    if ! install -m 600 /dev/null "$output_file"; then
        log_error "Failed to create secure output file: $output_file"
        return 1
    fi

    # shellcheck disable=SC2064  # intentional: expand $output_file now
    trap "_secure_remove_file '$output_file'" RETURN

    local pub_key
    if ! pub_key=$(_derive_age_public_key "$age_key"); then
        log_error "Failed to derive Age public key"
        return 1
    fi

    local hostname_val
    hostname_val=$(hostname)
    local date_val
    date_val=$(date)

    cat > "$output_file" << EOF
═══════════════════════════════════════════════════════════════
VaultWarden Age Key Backup - $date_val
═══════════════════════════════════════════════════════════════

🔐 CRITICAL: Store this entire file in your password manager
   (1Password, Bitwarden, etc.) as a secure note.

📝 Recovery Instructions:
   1. Save the key content below to: secrets/keys/age-key.txt
   2. Run: chmod 600 secrets/keys/age-key.txt
   3. Decrypt backups: age -d -i secrets/keys/age-key.txt backup.age

⚠️  If you lose this key, ALL backups are unrecoverable!

───────────────────────────────────────────────────────────────
AGE PRIVATE KEY (Copy everything below this line):
───────────────────────────────────────────────────────────────
$(cat "$age_key")
───────────────────────────────────────────────────────────────
Public Key: $pub_key
Created: $date_val
Hostname: $hostname_val
───────────────────────────────────────────────────────────────
EOF

    chmod 600 "$output_file"

    # Clear the RETURN trap on success so the output file is kept.
    trap - RETURN

    log_success "Password manager backup created: $output_file"
    log_warn "⚠️  SECURITY: Delete this file immediately after copying to your password manager:"
    log_warn "   _secure_remove_file '$output_file'"
    return 0
}

# ---------------------------------------------------------------------------
# _secure_remove_file FILE
#
# Attempts shred first; falls back to dd overwrite then unlink.
# ---------------------------------------------------------------------------
_secure_remove_file() {
    local target="$1"
    [[ -f "$target" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        shred -fuz -n 3 "$target" 2>/dev/null && return 0
    fi

    # dd fallback — overwrite then unlink
    local file_size
    file_size=$(_stat_file_size "$target" 2>/dev/null || echo "4096")
    [[ -z "$file_size" || "$file_size" -eq 0 ]] && file_size=4096
    dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$target"
}

# ---------------------------------------------------------------------------
# _html_escape STRING
#
# Replaces HTML metacharacters so key_content cannot corrupt
# the HTML document structure when embedded in the template.
# ---------------------------------------------------------------------------
_html_escape() {
    local raw="$1"
    # Order matters: & must be first to avoid double-escaping.
    raw="${raw//&/&amp;}"
    raw="${raw//</&lt;}"
    raw="${raw//>/&gt;}"
    raw="${raw//\"/&quot;}"
    raw="${raw//\'/&#39;}"
    printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# verify_key_replica [PRIMARY_KEY] [REPLICA_KEY...]
#
# Compares replicas by SHA-256 hash AND performs a functional age
# encrypt/decrypt roundtrip against each replica key file to verify
# operational validity. An empty replica list returns 1.
# ---------------------------------------------------------------------------
verify_key_replica() {
    local primary_key="${1:-${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}}"
    shift
    local replicas=("$@")

    if [[ ${#replicas[@]} -eq 0 ]]; then
        log_warn "verify_key_replica: no replicas configured — cannot verify (returning failure)"
        return 1
    fi

    if [[ ! -f "$primary_key" ]]; then
        log_error "verify_key_replica: primary key not found: $primary_key"
        return 1
    fi

    local primary_hash
    primary_hash=$(sha256sum "$primary_key" 2>/dev/null | awk '{print $1}')
    if [[ -z "$primary_hash" ]]; then
        log_error "verify_key_replica: could not hash primary key: $primary_key"
        return 1
    fi

    local test_data
    test_data="vw-replica-check-$$-$(date +%s)"
    local primary_pub
    if ! primary_pub=$(_derive_age_public_key "$primary_key" 2>/dev/null); then
        log_error "verify_key_replica: primary key is corrupt (cannot derive public key): $primary_key"
        return 1
    fi
    local roundtrip_result
    if ! roundtrip_result=$(printf '%s' "$test_data" | age -r "$primary_pub" 2>/dev/null | age -d -i "$primary_key" 2>/dev/null) \
        || [[ "$roundtrip_result" != "$test_data" ]]; then
        log_error "verify_key_replica: primary key failed functional roundtrip test — key is corrupt: $primary_key"
        return 1
    fi

    local all_ok=0
    local replica
    for replica in "${replicas[@]}"; do
        if [[ ! -f "$replica" ]]; then
            log_warn "verify_key_replica: replica not found: $replica"
            all_ok=1
            continue
        fi

        # Step 1: hash comparison (quick byte-level check)
        local replica_hash
        replica_hash=$(sha256sum "$replica" 2>/dev/null | awk '{print $1}')
        if [[ "$replica_hash" != "$primary_hash" ]]; then
            log_warn "verify_key_replica: replica hash mismatch: $replica"
            all_ok=1
            continue
        fi

        # Step 2: functional roundtrip test against the replica key
        local replica_result
        if ! replica_result=$(printf '%s' "$test_data" | age -r "$primary_pub" 2>/dev/null | age -d -i "$replica" 2>/dev/null) \
            || [[ "$replica_result" != "$test_data" ]]; then
            log_warn "verify_key_replica: replica failed functional roundtrip test (corrupt): $replica"
            all_ok=1
            continue
        fi

        log_debug "verify_key_replica: OK — $replica"
    done

    if [[ $all_ok -ne 0 ]]; then
        log_error "KEY REPLICA DEGRADED — backup will proceed but key redundancy is impaired."
        log_error "EMAIL ALERT REQUIRED: check replicas immediately with: make key-health"
    fi
    return "$all_ok"
}

# ---------------------------------------------------------------------------
# restore_key_from_replica REPLICA_KEY [PRIMARY_KEY]
#
# Copies to a .tmp sidecar first, then atomically renames into place.
# The primary is only replaced once the full copy is verified on disk.
# ---------------------------------------------------------------------------
restore_key_from_replica() {
    local replica_key="$1"
    local primary_key="${2:-${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}}"

    if [[ -z "$replica_key" ]]; then
        log_error "restore_key_from_replica: replica key path required"
        return 1
    fi

    if [[ ! -f "$replica_key" ]]; then
        log_error "restore_key_from_replica: replica not found: $replica_key"
        return 1
    fi

    local primary_dir
    primary_dir=$(dirname "$primary_key")
    local tmp_key="${primary_key}.tmp.$$"

    # Ensure the target directory exists
    if [[ ! -d "$primary_dir" ]]; then
        if ! mkdir -p "$primary_dir"; then
            log_error "restore_key_from_replica: cannot create directory: $primary_dir"
            return 1
        fi
        chmod 700 "$primary_dir"
    fi

    # Write to a sidecar first so a crash mid-copy leaves the existing primary intact.
    log_info "restore_key_from_replica: copying replica to tmp: $tmp_key"
    if ! cp "$replica_key" "$tmp_key"; then
        log_error "restore_key_from_replica: copy to tmp failed"
        rm -f "$tmp_key" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$tmp_key"

    # Atomic rename: on the same filesystem this is guaranteed by POSIX to be
    # atomic; the primary is replaced in one syscall.
    if ! mv "$tmp_key" "$primary_key"; then
        log_error "restore_key_from_replica: atomic rename failed"
        rm -f "$tmp_key" 2>/dev/null || true
        return 1
    fi

    chmod 600 "$primary_key"
    log_success "restore_key_from_replica: primary key restored from replica: $replica_key → $primary_key"
    return 0
}

# ---------------------------------------------------------------------------
# create_printable_key_backup
#
# Creates a printable PDF (or HTML fallback) of the age key with QR code.
# Uses double-quoted trap command so the temp file path expands at registration.
# Feeds key via stdin to qrencode to prevent cmdline exposure.
# Unsets key_content immediately after use.
# ---------------------------------------------------------------------------
create_printable_key_backup() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local real_user_home
    real_user_home=$(getent passwd "$(get_real_user)" 2>/dev/null | cut -d: -f6) || real_user_home="${HOME}"
    local output_pdf="${1:-${real_user_home}/vaultwarden-key-backup.pdf}"

    log_info "Creating printable key backup..."

    if ! command -v qrencode >/dev/null 2>&1; then
        log_warn "qrencode not found - skipping QR code generation"
        log_info "Install with: sudo apt install qrencode"
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    local temp_html
    # mktemp without --suffix: use POSIX-portable template (XXXXXX at the end),
    # then rename to .html so the OS registers the correct MIME type when opened.
    local _tmp_base
    _tmp_base=$(mktemp /tmp/vw-key-backup.XXXXXX)
    temp_html="${_tmp_base}.html"
    mv -- "$_tmp_base" "$temp_html"
    unset _tmp_base
    umask "$old_umask"

    # shellcheck disable=SC2064  # intentional: expand $temp_html now
    trap "_secure_remove_file '$temp_html'" EXIT

    local pub_key
    pub_key=$(_derive_age_public_key "$age_key")
    local key_content
    key_content=$(cat "$age_key")
    local hostname_val
    hostname_val=$(hostname)
    local date_val
    date_val=$(date)

    local key_content_escaped
    key_content_escaped=$(_html_escape "$key_content")

    # Feed key via stdin to prevent cmdline exposure.
    local qr_img_tag=""
    if command -v qrencode >/dev/null 2>&1; then
        local qr_base64
        qr_base64=$(printf '%s' "$key_content" | qrencode -t PNG -o - --read-from=- 2>/dev/null | base64 -w0 || true)
        if [[ -n "$qr_base64" ]]; then
            qr_img_tag="<div class='box'><h3>QR Code (Digital Import)</h3><p>Scan to import key:</p><img src='data:image/png;base64,${qr_base64}' style='width: 200px'></div>"
        fi
    fi

    cat > "$temp_html" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>VaultWarden Key Backup</title>
    <style>
        body { font-family: monospace; margin: 2cm; line-height: 1.4; }
        .box { border: 2px solid black; padding: 15px; margin: 20px 0; page-break-inside: avoid; }
        .key { background: #f0f0f0; padding: 15px; word-break: break-all; font-weight: bold; font-size: 1.1em; }
        h1 { color: #cc0000; border-bottom: 2px solid #cc0000; }
        .warning { background: #fff3cd; padding: 10px; border-left: 5px solid #ffc107; margin-bottom: 20px; }
        .delete-reminder { background: #f8d7da; padding: 10px; border-left: 5px solid #dc3545; margin-top: 20px; font-size: 0.95em; }
    </style>
</head>
<body>
    <h1>🔐 VaultWarden Encryption Key</h1>

    <div class="warning">
        <strong>⚠️ CRITICAL SECURITY DOCUMENT</strong><br>
        Store in a fireproof safe or safety deposit box.<br>
        This key is required to decrypt your VaultWarden backups.
    </div>

    <div class="box">
        <h2>Age Private Key</h2>
        <div class="key">${key_content_escaped}</div>
    </div>

    ${qr_img_tag}

    <div class="box">
        <h3>Metadata</h3>
        <strong>Created:</strong> ${date_val}<br>
        <strong>Hostname:</strong> ${hostname_val}<br>
        <strong>Public Key:</strong> ${pub_key}
    </div>

    <div class="box">
        <h3>Recovery</h3>
        1. Save key to: <code>secrets/keys/age-key.txt</code><br>
        2. Set permissions: <code>chmod 600 secrets/keys/age-key.txt</code>
    </div>

    <div class="delete-reminder">
        <strong>🗑️ DELETE THIS FILE AFTER PRINTING</strong><br>
        This HTML file contains your plaintext Age private key.<br>
        After printing or saving to PDF, securely delete it:<br>
        <code>shred -fuz '${output_pdf%.pdf}.html'</code><br>
        <em>File created: ${date_val}</em>
    </div>
</body>
</html>
EOF

    # Unset key_content immediately after the heredoc write so the
    # plaintext Age key is removed from the process environment as early as
    # possible. key_content_escaped is also cleared for the same reason.
    unset key_content
    unset key_content_escaped

    if command -v wkhtmltopdf >/dev/null 2>&1; then
        wkhtmltopdf -q "$temp_html" "$output_pdf"
        _secure_remove_file "$temp_html"
        trap - EXIT
        log_success "Printable PDF backup created: $output_pdf"
    else
        local output_html="${output_pdf%.pdf}.html"
        mv "$temp_html" "$output_html"
        trap - EXIT

        log_warn "wkhtmltopdf not found. Created HTML instead: $output_html"
        log_warn "SECURITY: The HTML file contains your plaintext Age key."
        log_warn "          Store it securely and delete it after printing:"
        log_warn "          shred -fuz '$output_html'"
        log_info  "Open in browser and print to PDF manually."

        # Schedule an auto-delete reminder 30 minutes from now.
        local remind_cmd="echo 'SECURITY REMINDER: Delete plaintext Age key backup: shred -fuz \"${output_html}\"' | logger -t vaultwarden-key-reminder 2>/dev/null; wall 'SECURITY REMINDER: VaultWarden plaintext key backup still exists at ${output_html} — delete it now with: shred -fuz ${output_html}' 2>/dev/null || true"
        if command -v at >/dev/null 2>&1; then
            echo "$remind_cmd" | at "now + 30 minutes" 2>/dev/null && \
                log_info "Scheduled security reminder in 30 minutes via at(1)." || \
                log_warn "Could not schedule at(1) reminder; set a manual reminder to delete $output_html"
        else
            log_warn "at(1) not available — cannot schedule auto-reminder."
            log_warn "SECURITY: Manually delete the plaintext key file within 30 minutes:"
            log_warn "          shred -fuz '$output_html'"
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _sops_yaml_age_recipients [SOPS_YAML]
#
# Extract all age: recipient public keys from the given .sops.yaml file.
# Prints one key per line. Returns 1 if no age recipients found.
# ---------------------------------------------------------------------------
_sops_yaml_age_recipients() {
    local sops_yaml="${1:-.sops.yaml}"
    [[ -f "$sops_yaml" ]] || return 1

    # Match lines of the form:  - age1...  (with any leading whitespace/dash)
    local keys
    keys=$(grep -E '^[[:space:]]*-[[:space:]]*(age1[A-Za-z0-9]+)' "$sops_yaml" \
           | sed -E 's/^[[:space:]]*-[[:space:]]*//')
    [[ -n "$keys" ]] || return 1
    printf '%s\n' "$keys"
}

# ---------------------------------------------------------------------------
# check_age_key_health
#
# Public entry-point for key health checks (called by startup.sh, maintenance.sh --update, Makefile).
# Delegates to simple_verify_age_key() for file/permission/roundtrip checks,
# then cross-checks the on-disk public key against the .sops.yaml recipient list.
# A mismatch means a new age key was restored while .sops.yaml still references the old key.
# ---------------------------------------------------------------------------
check_age_key_health() {
    # Step 1: standard file / permission / roundtrip checks
    simple_verify_age_key || return 1

    # Step 2: cross-check on-disk public key against .sops.yaml recipient list
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local sops_yaml="${SOPS_CONFIG_FILE:-.sops.yaml}"

    if [[ ! -f "$sops_yaml" ]]; then
        log_debug "check_age_key_health: .sops.yaml not found at '$sops_yaml' — skipping recipient check"
        return 0
    fi

    local disk_pub
    if ! disk_pub=$(_derive_age_public_key "$age_key" 2>/dev/null); then
        log_error "check_age_key_health: cannot derive public key from $age_key"
        return 1
    fi

    local recipients
    if ! recipients=$(_sops_yaml_age_recipients "$sops_yaml"); then
        log_warn "check_age_key_health: no age recipients found in $sops_yaml — skipping recipient check"
        return 0
    fi

    local recipient matched=0
    while IFS= read -r recipient; do
        if [[ "$recipient" == "$disk_pub" ]]; then
            matched=1
            break
        fi
    done <<< "$recipients"

    if [[ "$matched" -eq 0 ]]; then
        log_error "age key on disk does not match .sops.yaml recipient — secrets were encrypted to a different key"
        log_error "  on-disk public key : $disk_pub"
        log_error "  .sops.yaml expects : $(printf '%s\n' "$recipients" | head -1) (and possibly more)"
        log_error "  To fix: re-encrypt secrets with the current key, or restore the original age key."
        return 1
    fi

    log_debug "check_age_key_health: .sops.yaml recipient check passed"
    return 0
}

# ---------------------------------------------------------------------------
# validate_file_permissions FILE EXPECTED_PERMS [OWNER] [GROUP]
#
# Validates permissions (and optionally owner/group) of a file or directory.
# ---------------------------------------------------------------------------
validate_file_permissions() {
    local file_path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    local expected_group="${4:-}"

    if [[ ! -e "$file_path" ]]; then
        log_error "Path not found for permission validation: $file_path"
        return 1
    fi

    local validation_passed=true
    local current_perms current_owner current_group

    current_perms=$(_stat_octal_perms "$file_path")
    current_owner=$(_stat_owner "$file_path")
    current_group=$(_stat_group "$file_path")

    # Validate permissions
    if [[ "$current_perms" != "$expected_perms" ]]; then
        log_error "File permissions mismatch: $file_path"
        log_error "  Current: $current_perms, Expected: $expected_perms"
        validation_passed=false
    fi

    # stat returns "UNKNOWN" for unmapped UIDs; treat as a warning
    # rather than a hard mismatch so files owned by deleted users do not cause
    # spurious permission-check failures.

    # Validate owner if specified
    if [[ -n "$expected_owner" ]]; then
        if [[ "$current_owner" == "UNKNOWN" ]]; then
            log_warn "File owner is UNKNOWN (unmapped UID) for: $file_path — skipping owner check"
        elif [[ "$current_owner" != "$expected_owner" ]]; then
            log_error "File owner mismatch: $file_path"
            log_error "  Current: $current_owner, Expected: $expected_owner"
            validation_passed=false
        fi
    fi

    # Validate group if specified
    if [[ -n "$expected_group" ]]; then
        if [[ "$current_group" == "UNKNOWN" ]]; then
            log_warn "File group is UNKNOWN (unmapped GID) for: $file_path — skipping group check"
        elif [[ "$current_group" != "$expected_group" ]]; then
            log_error "File group mismatch: $file_path"
            log_error "  Current: $current_group, Expected: $expected_group"
            validation_passed=false
        fi
    fi

    if [[ "$validation_passed" == "true" ]]; then
        log_debug "File permissions validated: $file_path ($current_perms $current_owner:$current_group)"
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_directory_permissions DIR EXPECTED_PERMS [OWNER] [GROUP] [RECURSIVE] [FILE_PERMS] [SUBDIR_PERMS]
#
# Parameters:
#   $1  dir_path        — directory to validate
#   $2  expected_perms  — expected mode for $dir_path itself
#   $3  expected_owner  — (optional) expected owner
#   $4  expected_group  — (optional) expected group
#   $5  recursive       — "true" to recurse (default: false)
#   $6  file_perms      — (optional) expected mode for regular files found
#                         during recursion (default: 600)
#   $7  subdir_perms    — (optional) expected mode for sub-directories found
#                         during recursion (default: same as $expected_perms)
# ---------------------------------------------------------------------------
validate_directory_permissions() {
    local dir_path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    local expected_group="${4:-}"
    local recursive="${5:-false}"
    local file_perms="${6:-600}"
    local subdir_perms="${7:-$expected_perms}"

    if [[ ! -d "$dir_path" ]]; then
        log_error "Directory not found for permission validation: $dir_path"
        return 1
    fi

    # Validate directory itself
    if ! validate_file_permissions "$dir_path" "$expected_perms" "$expected_owner" "$expected_group"; then
        return 1
    fi

    # Recursive validation if requested
    if [[ "$recursive" == "true" ]]; then
        local validation_failed=false

        while IFS= read -r -d '' item; do
            if [[ -f "$item" ]]; then
                if ! validate_file_permissions "$item" "$file_perms" "$expected_owner" "$expected_group"; then
                    validation_failed=true
                fi
            elif [[ -d "$item" ]]; then
                if ! validate_file_permissions "$item" "$subdir_perms" "$expected_owner" "$expected_group"; then
                    validation_failed=true
                fi
            fi
        done < <(find "$dir_path" -mindepth 1 -print0)

        if [[ "$validation_failed" == "true" ]]; then
            log_error "Recursive permission validation failed for: $dir_path"
            return 1
        fi
    fi

    log_success "Directory permissions validated: $dir_path"
    return 0
}

# ---------------------------------------------------------------------------
# create_secure_file FILE_PATH CONTENT [PERMISSIONS] [OWNER] [GROUP]
#
# Creates a file atomically with restricted permissions.
# Uses a RETURN trap to guarantee umask restoration on every exit path.
# ---------------------------------------------------------------------------
create_secure_file() {
    local file_path="$1"
    local content="$2"
    local permissions="${3:-600}"
    local owner="${4:-}"
    local group="${5:-}"

    # Validate input parameters
    if [[ -z "$file_path" ]] || [[ -z "$content" ]]; then
        log_error "create_secure_file: file_path and content are required"
        return 1
    fi

    # Validate permissions format
    if [[ ! "$permissions" =~ ^[0-7]{3}$ ]]; then
        log_error "create_secure_file: invalid permissions format: $permissions"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp)

    # Save old umask and install a RETURN trap so the umask is
    # restored on every exit path (normal return, set -e abort, signal, etc.).
    local old_umask
    old_umask=$(umask)
    # shellcheck disable=SC2064  # intentional: expand $old_umask now, not on trap fire
    trap "umask '$old_umask'" RETURN
    umask 077

    if printf '%s\n' "$content" > "$temp_file"; then
        # Set permissions before moving to final location
        if chmod "$permissions" "$temp_file"; then
            # Set ownership if specified
            if [[ -n "$owner" ]]; then
                local chown_target="$owner"
                if [[ -n "$group" ]]; then
                    chown_target="$owner:$group"
                fi

                if ! chown "$chown_target" "$temp_file"; then
                    log_error "Failed to set ownership: $chown_target"
                    rm -f -- "$temp_file"
                    return 1
                fi
            fi

            # Atomic move to final location
            if mv "$temp_file" "$file_path"; then
                log_debug "Secure file created: $file_path ($permissions)"
                return 0
            else
                log_error "Failed to move secure file to final location: $file_path"
                rm -f -- "$temp_file"
                return 1
            fi
        else
            log_error "Failed to set file permissions: $permissions"
            rm -f -- "$temp_file"
            return 1
        fi
    else
        log_error "Failed to write content to temporary file"
        rm -f -- "$temp_file"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_password_strength PASSWORD [MIN_LENGTH]
# ---------------------------------------------------------------------------
validate_password_strength() {
    local password="$1"
    local min_length="${2:-$SECURITY_MIN_PASSWORD_LENGTH}"

    if [[ -z "$password" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi

    if [[ ${#password} -lt $min_length ]]; then
        log_error "Password must be at least $min_length characters long"
        return 1
    fi

    local has_lower has_upper has_digit has_special
    has_lower=false
    has_upper=false
    has_digit=false
    has_special=false

    # Check character types
    if [[ "$password" =~ [a-z] ]]; then has_lower=true; fi
    if [[ "$password" =~ [A-Z] ]]; then has_upper=true; fi
    if [[ "$password" =~ [0-9] ]]; then has_digit=true; fi
    if [[ "$password" =~ [^a-zA-Z0-9] ]]; then has_special=true; fi

    local score=0
    local requirements=()

    # '|| true' prevents set -e from killing the function when
    # ((score++)) returns exit code 1 (the pre-increment value of 0 → 1).
    if [[ "$has_lower" == "true" ]]; then ((score++)) || true; else requirements+=("lowercase letter"); fi
    if [[ "$has_upper" == "true" ]]; then ((score++)) || true; else requirements+=("uppercase letter"); fi
    if [[ "$has_digit" == "true" ]]; then ((score++)) || true; else requirements+=("digit"); fi
    if [[ "$has_special" == "true" ]]; then ((score++)) || true; else requirements+=("special character"); fi

    if [[ $score -lt 3 ]]; then
        log_error "Password is too weak. Missing: ${requirements[*]}"
        return 1
    fi

    # Check for common patterns
    if [[ "$password" =~ (012|123|234|345|456|567|678|789|890|abc|bcd|cde|def) ]]; then
        log_warn "Password contains common sequential patterns"
    fi

    if [[ "$password" =~ (111|222|333|444|555|666|777|888|999|000|aaa|bbb) ]]; then
        log_warn "Password contains repeated characters"
    fi

    log_debug "Password strength validation passed (score: $score/4)"
    return 0
}

# ---------------------------------------------------------------------------
# generate_secure_random LENGTH [CHARSET]
#
# Generates cryptographically secure random strings using rejection sampling
# to eliminate modulo bias.
# ---------------------------------------------------------------------------
generate_secure_random() {
    local length="${1:-32}"
    local charset="${2:-alphanumeric}"

    local chars
    case "$charset" in
        "alphanumeric")
            chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            ;;
        "alphanum_special")
            chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-="
            ;;
        "hex")
            chars="0123456789abcdef"
            ;;
        "base64")
            chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            ;;
        *)
            chars="$charset"
            ;;
    esac

    # Guard: /dev/urandom is required; $RANDOM is not a cryptographic source.
    if [[ ! -c /dev/urandom ]]; then
        log_error "generate_secure_random: /dev/urandom not available; cannot generate cryptographically secure string"
        return 1
    fi

    local char_count=${#chars}

    # Rejection-sampling threshold (eliminates modulo bias).
    local highest_multiple=$(( (256 / char_count) * char_count ))

    local random_string=""
    local accepted=0

    # Bulk read with 4× safety margin to make the top-up loop unreachable in practice.
    local bytes_to_read=$(( length * 4 + 128 ))
    local raw_bytes
    raw_bytes=$(od -An -N"$bytes_to_read" -tu1 /dev/urandom)

    local rand_byte
    for rand_byte in $raw_bytes; do
        [[ $accepted -ge $length ]] && break
        [[ $rand_byte -ge $highest_multiple ]] && continue
        random_string+="${chars:$(( rand_byte % char_count )):1}"
        (( accepted++ )) || true
    done

    # Top-up: handles the extremely unlikely case where the bulk read fell short.
    while [[ $accepted -lt $length ]]; do
        rand_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' \n')
        [[ $rand_byte -ge $highest_multiple ]] && continue
        random_string+="${chars:$(( rand_byte % char_count )):1}"
        (( accepted++ )) || true
    done

    echo "$random_string"
}

# Named wrapper for breakglass password generation.
generate_breakglass_password() {
    local length="${1:-48}"
    generate_secure_random "$length" "alphanumeric"
}

# ---------------------------------------------------------------------------
# secure_cleanup TARGET [PASSES] [ENCRYPTED]
#
# Removes files or directories. Uses rm -f / rm -rf (no overwrite loops).
#
# ─────────────────────────────────────────────────────────────────────────
# CALLER CONTRACT (PRECONDITION — NOT AUTOMATICALLY ENFORCED):
#
#   This function uses rm -f / rm -rf. On un-encrypted storage, deleted
#   file content remains physically recoverable until the blocks are
#   overwritten by the filesystem. Callers MUST ensure one of the
#   following is true before calling secure_cleanup():
#
#     (a) The sensitive data has already been written to an encrypted
#         destination (LUKS volume, OCI encrypted Block Volume, etc.), OR
#     (b) The entire host volume is encrypted at rest.
#
#   To enforce this contract programmatically, pass "encrypted" as the
#   third argument ($3). If the argument is absent or any other value,
#   a warning is logged as a reminder to auditors.
#
#   Example (enforced):   secure_cleanup "$tmpfile" 3 "encrypted"
#   Example (legacy):     secure_cleanup "$tmpfile"   # logs a warning
# ─────────────────────────────────────────────────────────────────────────
#
# Overwrite-based deletion is NOT performed because it is unreliable on modern
# storage stacks (ext4 journal, COW filesystems, SSD FTL/wear-levelling).
# The only reliable protection is full-disk encryption at rest.
# The $passes parameter is retained for backward compatibility but is ignored.
secure_cleanup() {
    local target="$1"
    # shellcheck disable=SC2034  # passes retained for backward compatibility; overwrite count has no effect on modern kernels
    local passes="${2:-3}"          # retained for backward compat; ignored
    local encrypted_confirmed="${3:-}"  # pass "encrypted" to silence warning

    if [[ -z "$target" ]]; then
        log_error "secure_cleanup: target is required"
        return 1
    fi

    # Warn when the caller has not confirmed that the data has been
    # persisted to an encrypted destination. This is a soft reminder only;
    # deletion proceeds regardless so that existing callers are not broken.
    if [[ "$encrypted_confirmed" != "encrypted" ]]; then
        log_debug "secure_cleanup: caller has not confirmed encrypted destination for '$target'." \
                 "Pass 'encrypted' as \$3 after verifying data is on an encrypted volume." \
                 "Plaintext residue may survive on un-encrypted storage."
    fi

    if [[ -f "$target" ]]; then
        rm -f -- "$target"
        log_debug "Secure file cleanup completed: $target"
    elif [[ -d "$target" ]]; then
        rm -rf -- "$target"
        log_debug "Secure directory cleanup completed: $target"
    else
        log_warn "Target not found for secure cleanup: $target"
        return 1
    fi

    return 0
}

# Export functions for use by scripts
export -f _stat_octal_perms _stat_file_size
export -f _derive_age_public_key
export -f is_sops_encrypted decrypt_sops_file encrypt_sops_file
export -f generate_age_key get_age_public_key check_age_key encrypt_data decrypt_data
export -f generate_secure_string generate_secure_password check_argon2_support generate_argon2_hash generate_bcrypt_hash
export -f calculate_sha256 verify_sha256 write_file_integrity verify_file_integrity secure_delete validate_crypto_environment
export -f simple_verify_age_key create_password_manager_escrow _secure_remove_file _html_escape
export -f create_printable_key_backup verify_key_replica restore_key_from_replica
export -f check_age_key_health _sops_yaml_age_recipients
export -f _stat_owner _stat_group
export -f validate_file_permissions validate_directory_permissions create_secure_file
export -f validate_password_strength generate_secure_random generate_breakglass_password secure_cleanup
export DEFAULT_AGE_KEY_FILE
export SECURITY_MIN_PASSWORD_LENGTH SECURITY_MAX_FAILED_ATTEMPTS SECURITY_LOCKOUT_DURATION

log_debug "Enhanced crypto library loaded successfully - standardized error handling with Age key validation" 2>/dev/null || true
