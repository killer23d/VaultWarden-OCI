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
    local cleanup_temp="rm -f '$temp_file'"

    # Set restrictive umask for secure creation
    local old_umask
    old_umask=$(umask)
    umask 077

    # Create file content atomically
    if echo "$content" > "$temp_file"; then
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
                    eval "$cleanup_temp"
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
                eval "$cleanup_temp"
                return 1
            fi
        else
            log_error "Failed to set file permissions: $permissions"
            umask "$old_umask"
            eval "$cleanup_temp"
            return 1
        fi
    else
        log_error "Failed to write content to temporary file"
        umask "$old_umask"
        eval "$cleanup_temp"
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

# ENHANCED: Generate secure random strings
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

    # Use multiple entropy sources
    local random_string=""
    local char_count=${#chars}

    for ((i=0; i<length; i++)); do
        # Use multiple entropy sources for better randomness
        local rand_byte
        if [[ -c /dev/urandom ]]; then
            rand_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
        else
            rand_byte=$((RANDOM % 256))
        fi

        local char_index=$((rand_byte % char_count))
        random_string+="${chars:$char_index:1}"
    done

    echo "$random_string"
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
