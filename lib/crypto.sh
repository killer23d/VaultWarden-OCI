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
#
# PATCHED BUGS (2026-03-10):
#   CRY-H1 [HIGH]   generate_secure_password(): charset was double-quoted,
#                   causing shell to expand $%, $^, $*, $@, etc. before tr
#                   ever saw them, silently weakening the charset.
#                   Fixed: use $'...' ANSI-C quoting for the charset literal.
#   CRY-M1 [MEDIUM] generate_secure_string(): `tr ... | head -c` triggers
#                   SIGPIPE on tr under set -euo pipefail.
#                   Fixed: use dd bs=1 count=$length 2>/dev/null.
#
# PATCHED BUGS (2026-04-08):
#   CRY-M1b [MEDIUM] generate_secure_string(): retry loop slept 1 s between
#                   attempts (up to 5 s stall per secret in container
#                   environments) and used a >= $length guard that could
#                   accept a short result on a partial dd read.
#                   /dev/urandom on modern Linux never truly blocks; sleep 1
#                   is unnecessary. Fixed: removed sleep 1; changed guard
#                   to strict == $length.
#
# PATCHED BUGS (2026-03-10):
#   CRY-M2 [MEDIUM] encrypt_sops_file(): sops --in-place truncates/destroys
#                   the file on any error (malformed YAML, missing .sops.yaml).
#                   Fixed: write to mktemp, then atomic mv.
#   CRY-L1 [LOW]    generate_argon2_hash() Python path: sys.stdin.read() had
#                   no size cap, risking high-memory on corrupted input.
#                   Fixed: sys.stdin.read(1024).
#   CRY-L2 [LOW]    check_age_key(): only checked permissions and comment header;
#                   could not detect corrupted private key material.
#                   Fixed: perform encrypt/decrypt round-trip with age.
#
# SECURITY / QUALITY FIXES (2026-03-11):
#   AUD-H3 [HIGH]   get_age_public_key() / _derive_age_public_key():
#                   grep -o '# public key: .*' returned the entire comment
#                   line including the '# public key: ' prefix. Downstream
#                   callers (SOPS config, encrypt_sops_file) received a
#                   malformed recipient string.
#                   Fixed: grep for '^# public key:' then strip the prefix
#                   with sed so only the bare age1... key is returned.
#   AUD-H4 [HIGH]   generate_age_key(): age-keygen > "$key_file" created
#                   the file at the invoking umask (typically 022 = 644)
#                   before a subsequent chmod 600 closed the race window.
#                   Fixed: save + restore umask around age-keygen; file is
#                   born mode 600. chmod 600 retained as belt-and-braces.
#   AUD-M3 [MEDIUM] check_age_key(): validated the '# public key:' comment
#                   but not the private key body. A file with a correct
#                   header but truncated/corrupt key material passed until
#                   SOPS tried to decrypt.
#                   Fixed: verify that the private key line starts with
#                   'AGE-SECRET-KEY-1' (the canonical prefix for all age
#                   private keys) before proceeding to the round-trip test.
#   AUD-L2 [LOW]    verify_file_integrity(): computed SHA-256 of the file
#                   but the .sha256 sidecar was not authenticated; an attacker
#                   who replaced both the file and its sidecar passed silently.
#                   Fixed: verify_file_integrity() now accepts an optional
#                   HMAC key (env var FILE_INTEGRITY_HMAC_KEY). When set,
#                   the sidecar is re-derived with openssl dgst -hmac and
#                   compared before the plain SHA-256 check. A helper
#                   write_file_integrity() writes both the plain SHA-256 and
#                   the HMAC sidecar so new callers can adopt authenticated
#                   integrity checking without changing their call sites.
#
# PATCHED BUGS (2026-03-13):
#   LC-1  [HIGH]    generate_bcrypt_hash(): no local validation of the cost
#                   factor range. A caller passing rounds=6 (e.g. from a
#                   misconfigured .env) silently generates a cryptographically
#                   weak credential.
#                   Fix: guard [[ "$rounds" =~ ^[0-9]+$ ]] &&
#                   (( rounds >= 10 && rounds <= 31 )) before calling htpasswd.
#   LC-2  [MEDIUM]  check_age_key(): mktemp failure path returned 0 (success)
#                   via `|| { log_warn ...; return 0; }`. A key that cannot be
#                   tested was reported healthy — a fail-open path.
#                   Fix: fail closed — return 1 with log_error when mktemp
#                   cannot create the temp file.
#   LC-3  [MEDIUM]  encrypt_sops_file(): temp file created at process umask
#                   (022 → 644) before SOPS writes encrypted content. A brief
#                   window exists where partially-written ciphertext is
#                   world-readable.
#                   Fix: chmod 600 "$tmp_file" immediately after mktemp,
#                   before the cp and sops calls.
#
# PATCHED BUGS (2026-03-24):
#   BUG-CRY-ES2b [HIGH]
#       encrypt_sops_file(): mktemp creates an internal staging file as
#       "${file}.sops.XXXXXX". When the caller passes a file whose name ends
#       in .yaml.enc (as edit-secrets.sh now does for its staging files), the
#       staging file name has no recognised extension (e.g.
#       secrets/tmp.XXXX.yaml.enc.sops.YYYYYY). SOPS infers input format from
#       the file extension; an unrecognised extension causes:
#           'Failed to get the data tree from the file'
#       Fix: always pass --input-type yaml --output-type yaml to `sops
#       --encrypt` so format inference from the filename is bypassed entirely.
#   BUG-CRY-ES2c [MEDIUM]
#       encrypt_sops_file(): `sops --encrypt ... 2>/dev/null` silently
#       discarded the real error message. Operators only ever saw the generic
#       'Failed to encrypt file with SOPS' log line, making diagnosis
#       impossible without attaching strace.
#       Fix: capture sops stderr into a variable; if sops exits non-zero,
#       emit the captured output via log_error before returning 1.

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_CRYPTO_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_CRYPTO_LIB_LOADED=1

set -euo pipefail

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
# AUD-H3 FIX: The previous implementation used
#   grep -o '# public key: .*'
# which returns the entire matched string, including the '# public key: '
# prefix. Callers that embed this value directly into a SOPS --age flag or
# a .sops.yaml recipients list received a string like:
#   # public key: age1...
# instead of the bare:
#   age1...
# This caused SOPS to reject the recipient with a parsing error.
#
# Fix: grep for the canonical comment prefix '^# public key:' and then
# strip the prefix with sed, emitting only the bare age1... key.
# This is the single source of truth for public-key derivation across the
# entire codebase (crypto.sh, secrets.sh, simple_key_resilience.sh).
# ---------------------------------------------------------------------------
_derive_age_public_key() {
    local key_file="$1"

    if [[ ! -f "$key_file" ]]; then
        log_error "Age key file not found: $key_file"
        return 1
    fi

    # AUD-H3 FIX: grep for the line, then strip the literal prefix with sed.
    # sed 's/^# public key: //' removes only the expected prefix and leaves
    # the bare age1... key; it is a no-op if the prefix is not present, in
    # which case the empty-string guard below catches the corruption.
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
# FIX [M-04]: Require top-level 'sops:' key AND nested 'mac:' field to avoid
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
# CRY-M2 FIX: sops --in-place will truncate/destroy the target file on any
# error (malformed YAML, missing .sops.yaml rule, etc.).  We now encrypt to
# a mktemp file and atomically rename it over the original only on success,
# matching the safe pattern used by write_secrets() in setup-secrets.sh.
#
# [MEDIUM FIX] Replaced `age-keygen -y` with _derive_age_public_key() for
# Ubuntu 22.04 compatibility and codebase consistency.
#
# LC-3 FIX: chmod 600 applied to tmp_file immediately after mktemp, before
# any content is written, to eliminate the world-readable race window that
# exists between mktemp (creates file at process umask, typically 644) and
# the subsequent SOPS write.
#
# BUG-CRY-ES2b FIX: Always pass --input-type yaml --output-type yaml so SOPS
# does not try to infer the format from the staging file's extension. The
# staging file is named "${file}.sops.XXXXXX" and when $file itself ends in
# .yaml.enc the staging name has no recognised extension, causing SOPS to
# abort with 'Failed to get the data tree from the file'.
#
# BUG-CRY-ES2c FIX: Capture sops stderr and emit it via log_error on
# failure instead of silently discarding it with 2>/dev/null.
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

    # CRY-M2 FIX: encrypt to a temp file; only overwrite original on success.
    # Use a .yaml suffix so SOPS can always infer the format on this side too
    # (belt-and-braces alongside the explicit --input-type flag below).
    local tmp_file
    tmp_file=$(mktemp "${file%.*}.sops.XXXXXX.yaml") || {
        log_error "Failed to create temp file for SOPS encryption: $file"
        return 1
    }

    # LC-3 FIX / BUG-#12 FIX: Use install -m 600 to atomically set mode 600 on
    # the temp file, eliminating the window between mktemp (creates file at
    # process umask, typically 644) and a subsequent chmod call. install -m 600
    # /dev/null truncates the already-created mktemp file and sets its mode in
    # one operation, so no partially-written SOPS ciphertext is ever readable.
    install -m 600 /dev/null "$tmp_file"

    # Copy original content into the temp file so SOPS can read its format
    if ! cp -- "$file" "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "Failed to copy file for SOPS encryption: $file"
        return 1
    fi

    # BUG-CRY-ES2b FIX: pass --input-type yaml --output-type yaml explicitly
    # so SOPS does not attempt to infer the format from the file extension.
    # BUG-CRY-ES2c FIX: capture stderr so we can surface the real cause.
    local sops_stderr=""
    if ! sops_stderr=$(SOPS_AGE_RECIPIENTS="$age_public_key" sops --encrypt --input-type yaml --output-type yaml "$tmp_file" > "${tmp_file}.out" 2>&1); then
        rm -f "$tmp_file" "${tmp_file}.out"
        log_error "Failed to encrypt file with SOPS: $file"
        [[ -n "$sops_stderr" ]] && log_error "$sops_stderr"
        return 1
    fi

    mv -f "${tmp_file}.out" "$file"
    rm -f "$tmp_file"
    return 0
}

generate_secure_string() {
    local length="${1:-32}"
    local charset="${2:-A-Za-z0-9}"

    [[ "$length" =~ ^[0-9]+$ ]] || {
        log_error "generate_secure_string: length must be numeric"
        return 1
    }
    (( length > 0 )) || {
        log_error "generate_secure_string: length must be > 0"
        return 1
    }

    # CRY-M1b FIX: /dev/urandom on modern Linux never truly blocks
    # (GRND_NONBLOCK behaviour since kernel 3.17). Retries guard only against
    # a partial dd read (e.g. interrupted by a signal), NOT entropy starvation,
    # so sleep 1 between attempts is unnecessary and stalls secrets setup by
    # up to 5 s per secret in container environments.
    local random_string=""
    local attempt
    for attempt in {1..5}; do
        random_string=$(LC_ALL=C tr -dc "$charset" < /dev/urandom \
                        | dd bs=1 count="$length" 2>/dev/null || true)

        # CRY-M1b FIX: strict equality. dd bs=1 count=$length must deliver
        # exactly $length bytes. A >= guard could accept a shorter result on
        # a partial read; == ensures the full requested entropy was collected.
        if [[ ${#random_string} -eq $length ]]; then
            printf '%s' "$random_string"
            return 0
        fi
    done

    log_error "generate_secure_string: failed to generate ${length} characters after 5 attempts"
    return 1
}
