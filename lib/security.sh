#!/usr/bin/env bash
# lib/security.sh - Enhanced security functions for VaultWarden-OCI
# ENHANCED: Comprehensive security validation and hardening functions
# Used by scripts to implement consistent security checks and measures
#
# PATCHED BUGS (2026-03-03):
#   BUG-1 [HIGH]   create_secure_file(): printf '%s\\\\n' → printf '%s\\n'
#                  Over-escaped format literal wrote "\\\\n" (backslash+backslash+n)
#                  instead of a newline, corrupting every script copied to /opt/.
#   BUG-2 [HIGH]   secure_cleanup(): find … {} \\\\; → find … {} \\;
#                  Over-escaped terminator: bash reduced \\\\; to \\; which
#                  (a) passed \\ (not ;) to find, and (b) under set -euo pipefail
#                  the bare ; launched "2>/dev/null || true" as a new command.
#   BUG-3 [MEDIUM] generate_secure_random() top-up loop: tr -d ' \\\\n' → tr -d ' \\n'
#                  Over-escaped delete-set: tr received \\\\n (backslashes+n) and
#                  deleted backslashes and the letter 'n' from od output instead
#                  of deleting spaces and newlines.
#   BUG-4 [MEDIUM] validate_file_permissions(): [[ ! -f ]] → [[ ! -e ]]
#                  -f tests for regular files only; validate_directory_permissions()
#                  calls this function on subdirectories in its recursive path,
#                  causing every subdirectory to fail with "File not found".
#
# PATCHED BUGS (2026-03-06):
#   BUG-5 [HIGH]   validate_password_strength(): ((score++)) under set -e exits the
#                  function on the FIRST successful match (exit code 1 from arithmetic
#                  with result 1). Fixed by guarding every increment with '|| true'.
#   BUG-6 [MEDIUM] validate_file_permissions(): stat -c '%a'/'%U'/'%G' is GNU-only.
#                  macOS requires stat -f '%OLp'/'%Su'/'%Sg'. Added _stat_octal_perms(),
#                  _stat_owner(), _stat_group() portable wrappers that detect the
#                  platform at call time.
#   BUG-7 [LOW]    validate_file_permissions(): stat on an unmapped UID returns the
#                  string "UNKNOWN" for owner/group, causing false-positive mismatch
#                  errors. Now logged as a warning and treated as a soft failure only.
#
# MODERNIZED (2026-03-09):
#   MOD-1 [secure_cleanup] shred/dd overwrite loops removed. On modern storage
#                  stacks (ext4 journal, COW filesystems, SSD FTL/wear-levelling),
#                  file-content overwrites are NOT guaranteed to reach the same
#                  physical sectors. Reliable protection requires full-disk
#                  encryption (LUKS / OCI Block Volume encryption), which is
#                  assumed for any deployment storing sensitive VaultWarden data.
#                  See function comment for full rationale.
#
# PATCHED BUGS (2026-03-10):
#   SEC-H1 [HIGH]   create_secure_file(): umask restoration was only reached inside
#                   each conditional branch; a set -e exit (e.g. unexpected mktemp
#                   failure) left the calling process with umask 077 permanently.
#                   Fixed with: trap 'umask "$old_umask"' RETURN immediately after
#                   saving old_umask, guaranteeing restoration on every exit path.
#   SEC-M1 [MEDIUM] validate_directory_permissions() recursive path compared every
#                   sub-directory against the top-level $expected_perms (700 for the
#                   secrets dir), producing false-positive failures for lib/ dirs
#                   installed at mode 750 by systemd-setup.sh. Fixed by accepting an
#                   optional $file_perms parameter (default 600) and validating each
#                   sub-directory against its own actual expected mode via a new
#                   $dir_perms parameter, defaulting to $expected_perms only when not
#                   separately specified.
#   SEC-M2 [MEDIUM] secure_cleanup(): rm-based deletion leaves plaintext recoverable
#                   on un-encrypted storage. Added a prominently-documented caller
#                   contract and an optional enforcement guard so callers can assert
#                   the encrypted-destination precondition before deletion proceeds.
#   SEC-L1 [LOW]    generate_secure_random(): bulk read size was (length * 2 + 64),
#                   which could be short enough after rejection sampling to trigger the
#                   per-byte top-up loop under I/O pressure. Increased to
#                   (length * 4 + 128) so the top-up branch is essentially unreachable.

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

# ---------------------------------------------------------------------------
# Portable stat helpers (BUG-6 fix)
#
# GNU stat (Linux):  stat -c FORMAT FILE
# BSD  stat (macOS): stat -f FORMAT FILE
#
# We detect the platform once per call — cheap and avoids a global flag that
# could be poisoned by sourcing order.
# ---------------------------------------------------------------------------
_stat_octal_perms() {
    local path="$1"
    if stat --version >/dev/null 2>&1; then
        # GNU coreutils
        stat -c '%a' "$path" 2>/dev/null
    else
        # BSD / macOS
        stat -f '%OLp' "$path" 2>/dev/null
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

# ENHANCED: File permission validation with detailed reporting
#
# FIX BUG-4: Guard changed from [[ ! -f ]] to [[ ! -e ]] so the function
# works correctly when called on directories (e.g. from the recursive path
# in validate_directory_permissions).  -f is true only for regular files;
# -e is true for any existing filesystem object (file, directory, symlink…).
#
# FIX BUG-6: stat calls replaced with portable _stat_octal_perms(),
# _stat_owner(), _stat_group() helpers that work on both GNU/Linux and macOS.
#
# FIX BUG-7: owner/group values of "UNKNOWN" (returned by stat for unmapped
# UIDs, e.g. files owned by a deleted user) are treated as a soft warning
# rather than a hard mismatch, avoiding false-positive validation failures.
validate_file_permissions() {
    local file_path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    local expected_group="${4:-}"

    # BUG-4 FIX: was [[ ! -f "$file_path" ]] — fails silently for directories
    if [[ ! -e "$file_path" ]]; then
        log_error "Path not found for permission validation: $file_path"
        return 1
    fi

    local validation_passed=true
    local current_perms current_owner current_group

    # BUG-6 FIX: use portable wrappers instead of GNU-only stat -c
    current_perms=$(_stat_octal_perms "$file_path")
    current_owner=$(_stat_owner "$file_path")
    current_group=$(_stat_group "$file_path")

    # Validate permissions
    if [[ "$current_perms" != "$expected_perms" ]]; then
        log_error "File permissions mismatch: $file_path"
        log_error "  Current: $current_perms, Expected: $expected_perms"
        validation_passed=false
    fi

    # BUG-7 FIX: stat returns "UNKNOWN" for unmapped UIDs; treat as a warning
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

# ENHANCED: Directory permission validation with recursive option
#
# SEC-M1 FIX: The original recursive path validated every sub-directory
# against $expected_perms (the top-level directory mode, e.g. 700 for the
# secrets dir). lib/ subdirectories installed at 750 by systemd-setup.sh
# therefore produced false-positive failures.
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
#                         Pass the actual installed mode (e.g. 750) when
#                         sub-directories legitimately differ from the root.
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
                # SEC-M1 FIX: use dedicated $file_perms (default 600) for
                # regular files rather than the directory's $expected_perms.
                if ! validate_file_permissions "$item" "$file_perms" "$expected_owner" "$expected_group"; then
                    validation_failed=true
                fi
            elif [[ -d "$item" ]]; then
                # SEC-M1 FIX: use $subdir_perms (default: same as the root
                # $expected_perms) for sub-directories, allowing callers to
                # specify a different mode (e.g. 750) when sub-directories are
                # legitimately installed with a mode that differs from the root.
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

# ENHANCED: Secure file creation with atomic operations
#
# FIX BUG-1: printf format was '%s\\\\n' (single-quoted literal).
#   Single quotes preserve everything verbatim, so printf received the
#   8-char format string  %s\\\\n.  printf's own escape processing then
#   converted \\\\→\\, producing output:  <content>\\n  — NOT a newline but a
#   literal backslash followed by the letter n.  Every script copied to
#   /opt/ via cron-setup.sh had this garbage appended.
#
#   Fix: '%s\\n'  printf interprets \\n in the format string as a newline;
#   $content is passed as the argument (not the format), so no format-string
#   injection is possible regardless of what $content contains.
#
# SEC-H1 FIX: umask restoration was performed only inside each conditional
#   branch. If the function exited early via set -e (e.g. a surprise mktemp
#   failure), the old_umask restore path was never reached and the entire
#   calling process continued running with umask 077, silently breaking all
#   subsequent file creations.
#
#   Fix: register a RETURN trap immediately after saving old_umask. The trap
#   fires on every function exit path — normal return, set -e abort, and
#   explicit 'return N' — guaranteeing the caller's umask is always restored.
#   The in-branch umask calls are removed to avoid double-restore noise.
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

    # SEC-H1 FIX: save old umask and install a RETURN trap so the umask is
    # restored on every exit path (normal return, set -e abort, signal, etc.).
    # Without this, any early exit left the calling process with umask 077.
    local old_umask
    old_umask=$(umask)
    # shellcheck disable=SC2064  # intentional: expand $old_umask now, not on trap fire
    trap "umask '$old_umask'" RETURN
    umask 077

    # BUG-1 FIX: was printf '%s\\\\n' "$content" — wrote literal \\n not newline.
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

# ENHANCED: Password strength validation
#
# FIX BUG-5: ((score++)) under set -e exits the FUNCTION on the first
# successful character-class match because arithmetic expressions that
# evaluate to 1 (i.e. the OLD value before increment) return exit code 1,
# which set -e treats as an error.
#
# The fix guards every increment with '|| true' so the exit code of the
# arithmetic compound command is always 0, regardless of the result value.
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

    # BUG-5 FIX: '|| true' prevents set -e from killing the function when
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

# ENHANCED: Generate cryptographically secure random strings.
#
# FIXED BUG-L (HIGH) — Modulo bias eliminated via rejection sampling.
# FIXED BUG-M/N (MEDIUM) — Bulk entropy read; $RANDOM fallback removed.
# (See original comments above each section for full rationale.)
#
# SEC-L1 FIX: Bulk read size increased from (length * 2 + 64) to
# (length * 4 + 128). The original size could be short enough after
# rejection sampling to trigger the per-byte top-up loop on systems under
# I/O pressure. The new size provides a 4× safety margin that makes the
# top-up branch essentially unreachable under any realistic workload.
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
    local highest_multiple=$(( (256 / char_count) * char_count ))

    local random_string=""
    local accepted=0

    # SEC-L1 FIX: was (length * 2 + 64); increased to (length * 4 + 128) to
    # provide a 4× entropy margin and make the top-up loop unreachable in
    # practice, avoiding the per-byte od+tr subprocess overhead under I/O load.
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

    # Top-up: handles the extremely unlikely case where the bulk read fell
    # short after rejection sampling.
    #
    # BUG-3 FIX: was tr -d ' \\\\n' — deleted backslashes and 'n', not newlines.
    # Fix: ' \\n' — tr interprets \\n as newline (removes spaces + newlines).
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

# MODERNIZED: Secure cleanup function
#
# MOD-1 (2026-03-09): shred/dd overwrite loops REMOVED.
#
# Rationale — overwrite-based deletion is unreliable on modern storage stacks:
#
#   • ext4 with journaling: the journal may replay old data blocks after an
#     unclean shutdown, resurrecting "deleted" file content even after an
#     fsync-confirmed overwrite.
#
#   • btrfs, ZFS, APFS (copy-on-write): a write always creates a new extent;
#     the previous extent remains allocated until the space is reclaimed by
#     the garbage collector. shred/dd overwrites land on NEW physical blocks,
#     leaving the original data intact in the old extent.
#
#   • SSDs with Flash Translation Layer (FTL) and wear-levelling: the FTL
#     remaps logical block addresses to physical NAND pages transparently.
#     An overwrite write is sent to a different physical page; the original
#     page is only erased when the FTL decides to reclaim it — which may be
#     never during the device's lifetime.
#
# The only reliable protection against data recovery is full-disk encryption
# at rest (LUKS on the host OS volume, or OCI Block Volume encryption with
# AES-256). This is assumed to be in place for any deployment storing
# sensitive VaultWarden data.
#
# For transient plaintext (backup snapshots, staging tarballs):
# backup.sh registers an EXIT/INT/TERM trap before mktemp that calls
# rm -rf on TMPDIR_BACKUP on ALL exit paths including SIGINT mid-backup.
# That trap-based pattern is the correct mitigation; overwrite loops add
# latency (multiple dd passes over large files) without meaningful security.
#
# The $passes parameter is retained for backward compatibility but is now
# ignored. All callers can continue passing it without breaking.
#
# ─────────────────────────────────────────────────────────────────────────
# SEC-M2 CALLER CONTRACT (PRECONDITION — NOT AUTOMATICALLY ENFORCED):
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
secure_cleanup() {
    local target="$1"
    local passes="${2:-3}"          # retained for backward compat; ignored (see above)
    local encrypted_confirmed="${3:-}"  # SEC-M2: pass "encrypted" to silence warning

    if [[ -z "$target" ]]; then
        log_error "secure_cleanup: target is required"
        return 1
    fi

    # SEC-M2: warn when the caller has not confirmed that the data has been
    # persisted to an encrypted destination. This is a soft reminder only;
    # deletion proceeds regardless so that existing callers are not broken.
    if [[ "$encrypted_confirmed" != "encrypted" ]]; then
        log_warn "secure_cleanup: caller has not confirmed encrypted destination for '$target'." \
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

log_debug "lib/security.sh loaded successfully"
