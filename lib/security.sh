#!/usr/bin/env bash
# lib/security.sh - Enhanced security functions for VaultWarden-OCI
# ENHANCED: Comprehensive security validation and hardening functions
# Used by scripts to implement consistent security checks and measures

# Prevent multiple sourcing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: lib/security.sh should be sourced, not executed directly"
    exit 1
fi

if [[ -n "${LIB_SECURITY_LOADED:-}" ]]; then
    return 0
fi
readonly LIB_SECURITY_LOADED=1

# Ensure common.sh is loaded first
if [[ -z "${LIB_COMMON_LOADED:-}" ]]; then
    echo "Error: lib/common.sh must be loaded before lib/security.sh"
    return 1
fi

# Security configuration
readonly SECURITY_MIN_PASSWORD_LENGTH=12
readonly SECURITY_MAX_FAILED_ATTEMPTS=3
readonly SECURITY_LOCKOUT_DURATION=300  # 5 minutes

# ENHANCED: File permission validation with detailed reporting
validate_file_permissions() {
    local file_path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    local expected_group="${4:-}"

    if [[ ! -f "$file_path" ]]; then
        log_error "File not found for permission validation: $file_path"
        return 1
    fi

    local validation_passed=true
    local current_perms current_owner current_group

    # Get current file attributes
    current_perms=$(stat -c '%a' "$file_path" 2>/dev/null)
    current_owner=$(stat -c '%U' "$file_path" 2>/dev/null)
    current_group=$(stat -c '%G' "$file_path" 2>/dev/null)

    # Validate permissions
    if [[ "$current_perms" != "$expected_perms" ]]; then
        log_error "File permissions mismatch: $file_path"
        log_error "  Current: $current_perms, Expected: $expected_perms"
        validation_passed=false
    fi

    # Validate owner if specified
    if [[ -n "$expected_owner" ]] && [[ "$current_owner" != "$expected_owner" ]]; then
        log_error "File owner mismatch: $file_path"
        log_error "  Current: $current_owner, Expected: $expected_owner"
        validation_passed=false
    fi

    # Validate group if specified
    if [[ -n "$expected_group" ]] && [[ "$current_group" != "$expected_group" ]]; then
        log_error "File group mismatch: $file_path"
        log_error "  Current: $current_group, Expected: $expected_group"
        validation_passed=false
    fi

    if [[ "$validation_passed" == "true" ]]; then
        log_debug "File permissions validated: $file_path ($current_perms $current_owner:$current_group)"
        return 0
    else
        return 1
    fi
}

# ENHANCED: Directory permission validation with recursive option
validate_directory_permissions() {
    local dir_path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    local expected_group="${4:-}"
    local recursive="${5:-false}"

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
                if ! validate_file_permissions "$item" "600" "$expected_owner" "$expected_group"; then
                    validation_failed=true
                fi
            elif [[ -d "$item" ]]; then
                if ! validate_file_permissions "$item" "$expected_perms" "$expected_owner" "$expected_group"; then
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

# ENHANCED: Secure file creation with atomic operations
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
    # NOTE: cleanup_temp local variable removed (was eval "$cleanup_temp", see BUG-R class).
    # All error paths now call: rm -f -- "$temp_file"

    # Set restrictive umask for secure creation
    local old_umask
    old_umask=$(umask)
    umask 077

    # FIX (echo "$content" LOW): printf avoids misinterpreting content that
    # begins with '-' as an echo flag on POSIX implementations.
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
                    umask "$old_umask"
                    # FIX (eval "$cleanup_temp" LOW): direct rm -f eliminates
                    # the eval injection vector.
                    rm -f -- "$temp_file"
                    return 1
                fi
            fi

            # Atomic move to final location
            if mv "$temp_file" "$file_path"; then
                umask "$old_umask"
                log_debug "Secure file created: $file_path ($permissions)"
                return 0
            else
                log_error "Failed to move secure file to final location: $file_path"
                umask "$old_umask"
                rm -f -- "$temp_file"
                return 1
            fi
        else
            log_error "Failed to set file permissions: $permissions"
            umask "$old_umask"
            rm -f -- "$temp_file"
            return 1
        fi
    else
        log_error "Failed to write content to temporary file"
        umask "$old_umask"
        rm -f -- "$temp_file"
        return 1
    fi
}

# ENHANCED: Password strength validation
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

    if [[ "$has_lower" == "true" ]]; then ((score++)); else requirements+=("lowercase letter"); fi
    if [[ "$has_upper" == "true" ]]; then ((score++)); else requirements+=("uppercase letter"); fi
    if [[ "$has_digit" == "true" ]]; then ((score++)); else requirements+=("digit"); fi
    if [[ "$has_special" == "true" ]]; then ((score++)); else requirements+=("special character"); fi

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

# ENHANCED: Generate cryptographically secure random strings.
#
# FIXED BUG-L (HIGH) — Modulo bias eliminated via rejection sampling.
#   The old code used `rand_byte % char_count` directly.  Because a byte
#   spans [0,255] and most charsets do not divide 256 evenly, the first
#   (256 mod char_count) indices were over-represented:
#
#     Charset           Size  256 mod N  Bias on first N indices
#     hex                 16      0      None (256 = 16×16)
#     base64              64      0      None (256 = 4×64)
#     alphanumeric        62      8      +25% on indices 0-7  (A-H)
#     alphanum_special    74     34      +33% on indices 0-33
#
#   Fix: compute highest_multiple = (256 / char_count) * char_count and
#   discard any byte whose value >= highest_multiple before applying modulo.
#   For hex and base64 highest_multiple == 256, so no bytes are discarded.
#
# FIXED BUG-M/N (MEDIUM) — Bulk entropy read; $RANDOM fallback removed.
#   The old loop forked `od` + `tr` (~3 processes) for every character,
#   producing ~96 subprocess spawns for a 48-character password.  The
#   else-branch fell back to $RANDOM, a 15-bit LCG that is not
#   cryptographically secure.
#
#   Fix: all bytes are obtained with a single `od` invocation reading
#   (length * 2 + 64) bytes — enough to absorb rejected bytes with
#   very high probability even for the worst-case charset (74 chars,
#   ~13.3% rejection rate).  A top-up loop handles the astronomically
#   unlikely case where the bulk read falls short.
#   The $RANDOM fallback is removed entirely; if /dev/urandom is absent
#   the function returns 1 with an explicit error.
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

    # Rejection-sampling threshold (BUG-L fix).
    # highest_multiple is the largest value < 256 that is an exact multiple of
    # char_count.  Bytes in [highest_multiple, 255] are discarded so that the
    # remaining range maps evenly onto the charset with no over-representation.
    local highest_multiple=$(( (256 / char_count) * char_count ))

    local random_string=""
    local accepted=0

    # Single bulk read — (BUG-M/N fix).
    # Over-read by 2x + 64 to absorb rejected bytes comfortably.  Even the
    # worst case (alphanum_special, ~13.3% rejection) leaves ample margin.
    local bytes_to_read=$(( length * 2 + 64 ))
    local raw_bytes
    raw_bytes=$(od -An -N"$bytes_to_read" -tu1 /dev/urandom)

    local rand_byte
    for rand_byte in $raw_bytes; do
        [[ $accepted -ge $length ]] && break
        # Discard bytes that would introduce modulo bias
        [[ $rand_byte -ge $highest_multiple ]] && continue
        random_string+="${chars:$(( rand_byte % char_count )):1}"
        (( accepted++ ))
    done

    # Top-up: handles the extremely unlikely case where the bulk read fell
    # short after rejection sampling.  Each iteration is a single od call,
    # but this path is essentially unreachable in normal operation.
    while [[ $accepted -lt $length ]]; do
        rand_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' \n')
        [[ $rand_byte -ge $highest_multiple ]] && continue
        random_string+="${chars:$(( rand_byte % char_count )):1}"
        (( accepted++ ))
    done

    echo "$random_string"
}

# Named wrapper for breakglass password generation.
#
# FIX (Dead generate_breakglass_password, MEDIUM): Both call sites in
# create-breakglass-admin.sh previously bypassed this wrapper and called
# generate_secure_random() directly with inline charset arguments, making
# the function unreachable dead code.  Having the wrapper here provides:
#   - a semantically clear call site
#   - a single place to adjust charset or length policy
#   - automatic inheritance of the BUG-L rejection-sampling fix above
#
# Uses the alphanumeric (62-char) charset.  256 mod 62 = 8, so bytes
# 248-255 are discarded (~3.1% rejection rate); no bias remains.
generate_breakglass_password() {
    local length="${1:-48}"
    generate_secure_random "$length" "alphanumeric"
}

# ENHANCED: Secure cleanup function for sensitive data
secure_cleanup() {
    local target="$1"
    local passes="${2:-3}"

    if [[ -z "$target" ]]; then
        log_error "secure_cleanup: target is required"
        return 1
    fi

    if [[ -f "$target" ]]; then
        # Secure file deletion with multiple overwrites
        if command -v shred >/dev/null 2>&1; then
            if shred -vfz -n "$passes" "$target" 2>/dev/null; then
                log_debug "Secure file cleanup completed: $target"
                return 0
            else
                log_warn "Shred failed, falling back to rm: $target"
            fi
        fi

        # Fallback: overwrite and remove
        local file_size
        file_size=$(stat -c%s "$target" 2>/dev/null || echo "0")

        for ((i=1; i<=passes; i++)); do
            dd if=/dev/urandom of="$target" bs="$file_size" count=1 2>/dev/null || true
        done

        rm -f "$target"
        log_debug "Fallback secure cleanup completed: $target"

    elif [[ -d "$target" ]]; then
        # Secure directory deletion
        find "$target" -type f -exec shred -vfz -n "$passes" {} \; 2>/dev/null || true
        rm -rf "$target"
        log_debug "Secure directory cleanup completed: $target"
    else
        log_warn "Target not found for secure cleanup: $target"
        return 1
    fi

    return 0
}

log_debug "lib/security.sh loaded successfully"
