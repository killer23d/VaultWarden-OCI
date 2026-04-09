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
#
# PATCHED BUGS (2026-04-08):
#   CRY-M1-followup [MEDIUM]
#       generate_secure_string(): the retry condition used -ge (greater-than-
#       or-equal), which accepted any string of $length or more characters.
#       A dd partial-read or a pipefail-swallowed error could theoretically
#       produce a shorter string that still passes -ge if the pipe filled
#       a buffer with extra bytes. Replaced with a strict -eq assertion.
#       sleep 1 between retries removed: /dev/urandom on modern Linux never
#       blocks, so the sleep adds up to 5 s of latency for no benefit.
#       The || true that previously swallowed the dd pipeline rc is removed;
#       the -eq guard now serves as the explicit failure detector.
#
# PATCHED BUGS (2026-04-09):
#   FIX-ENC-RT1 [HIGH]
#       encrypt_sops_file(): sops --encrypt exits 0 but writes unreadable
#       ciphertext when the Age public key in .sops.yaml is stale, rotated,
#       or mismatched. The failure was previously not surfaced until 'make up'
#       startup time, producing a cryptic SOPS decryption error rather than
#       a clear error at secret-write time.
#       Fix: after the atomic mv succeeds, immediately perform a sops -d
#       round-trip validation. If decryption fails, the original file is
#       restored from a pre-write backup (written before the mv with
#       install -m 600), a clear diagnostic is emitted pointing at the Age
#       key and .sops.yaml, and the function returns 1. The backup is cleaned
#       up unconditionally on both success and failure paths.

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
# failure instead of silently swallowing it with 2>/dev/null.
#
# FIX-ENC-RT1 FIX: After the atomic mv, perform a sops -d round-trip on the
# live secrets file to verify the ciphertext is actually readable with the
# current Age key. sops --encrypt exits 0 even when the recipient key in
# .sops.yaml is stale or rotated; the resulting ciphertext is silently
# unreadable and the failure only surfaces at 'make up' startup time.
# Round-trip approach:
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
    # BUG-CRY-ES2c FIX: capture stderr so we can surface the real error
    # message on failure instead of silently swallowing it.
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

    # -----------------------------------------------------------------------
    # FIX-ENC-RT1: Pre-write backup for round-trip restore path.
    #
    # Write a secure copy of the ORIGINAL (pre-encryption) plaintext staging
    # file before we atomically replace it. This is the restore point used
    # below if the round-trip decryption check fails, ensuring the caller
    # can retry after fixing .sops.yaml or the Age key.
    #
    # The backup is intentionally a copy of $file (the plaintext staging
    # file supplied by the caller, e.g. a mktemp produced by write_secrets()),
    # NOT a copy of $tmp_file (the just-encrypted ciphertext). The plaintext
    # staging file is transient and controlled by the caller; placing the
    # backup next to it keeps cleanup straightforward.
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # FIX-ENC-RT1: Round-trip decryption validation.
    #
    # Verify the newly-written ciphertext is actually readable with the
    # current Age key. sops --encrypt exits 0 even when the recipient key in
    # .sops.yaml is stale or rotated; the round-trip catches this immediately
    # instead of at 'make up' startup time.
    #
    # - Suppress xtrace so the Age key file path does not appear in bash -x
    #   output (consistent with decrypt_secret() in lib/secrets.sh).
    # - Discard decrypted output to /dev/null; we only need the exit code.
    # - On failure: restore $file from $pre_write_backup and return 1.
    # - Unconditionally remove $pre_write_backup on both paths.
    # -----------------------------------------------------------------------
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
# AUD-H4 FIX: The previous implementation ran
#   age-keygen -o "$output_file"
# (or age-keygen > "$output_file" in earlier revisions) with no umask
# control. The invoking process umask is typically 022, which means the
# file is created mode 644 (world-readable) before the subsequent
# `chmod 600` closes the race window. On a busy system or under an
# attacker-controlled TMPDIR with inotify, the private key can be read
# during this window.
#
# Fix: save the current umask, set umask 077 so any new file is born
# mode 600 (u=rw, g=---, o=---), generate the key, then immediately
# restore the original umask. chmod 600 is kept as belt-and-braces.
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

    # AUD-H4 FIX: Set restrictive umask before generating the key so the
    # file is born mode 600 (owner r/w only). Save and restore the original
    # umask regardless of whether age-keygen succeeds or fails.
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
# BUG-K1 FIX: replaced stat -c "%a" (GNU-only) with _stat_octal_perms_local()
# which selects the correct format string for the host platform.
#
# AUD-M3 FIX: validate the AGE-SECRET-KEY-1 prefix on the private key body
# (not just the '# public key:' comment). A file whose comment header is
# intact but whose private key line is truncated or corrupted (e.g. written
# by a partial write) passes the old header check and is not caught until
# SOPS actually attempts a decrypt, which happens much later and is harder
# to diagnose.
#
# CRY-L2 FIX: In addition to permission and format checks, perform a full
# encrypt/decrypt round-trip using age to detect corrupted private key
# material.
#
# LC-2 FIX: mktemp failure path now returns 1 (fail-closed) instead of 0
# (fail-open). A key that cannot be tested is no longer silently reported
# as healthy.
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

    # AUD-M3 FIX: Verify the private key line carries the canonical
    # 'AGE-SECRET-KEY-1' prefix defined by the age specification.
    # A file missing this line is either empty, truncated, or not an age key.
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

    # CRY-L2 FIX: encrypt/decrypt round-trip to verify private key material integrity
    # LC-2 FIX: fail closed on mktemp failure — a key that cannot be tested
    # must NOT be reported healthy (fail-open was the previous behaviour).
    if has_command age; then
        local test_plaintext="vaultwarden-age-key-check"
        local tmp_enc
        tmp_enc=$(mktemp) || {
            log_error "check_age_key: cannot create temp file for round-trip test — key NOT verified"
            return 1
        }
        # BUG-#12 FIX: Secure the temp file immediately after mktemp to close the
        # window between creation (at process umask) and first write.
        install -m 600 /dev/null "$tmp_enc"

        local round_trip_ok=false
        # BUG-P4-6 FIX: Validate that the decrypted output matches the original
        # plaintext byte-for-byte. A successful exit code from age -d only confirms
        # the ciphertext was well-formed; it does not guarantee the key produced the
        # correct plaintext (e.g. a truncated or partially-overwritten key file could
        # decrypt to garbage with exit 0 in some age versions).
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
# CRY-M1 FIX: The previous implementation piped tr into head -c, which causes tr
# to receive SIGPIPE when head exits after reading enough bytes.  Under
# set -euo pipefail this makes tr exit non-zero and || true yields a potentially
# short string.  We now use dd bs=1 count=$length 2>/dev/null as the consumer,
# which reads exactly the requested number of bytes in a single pass with no
# broken-pipe risk.
#
# CRY-M1-followup FIX:
#   - Removed sleep 1 between retry attempts. /dev/urandom on modern Linux
#     (kernel >= 3.17 with getrandom(2)) never truly blocks once the entropy
#     pool is initialised; sleeping wastes up to 5 s per secret during
#     early-boot container setup for no benefit.
#   - Replaced the -ge (greater-than-or-equal) retry guard with a strict -eq
#     assertion. dd bs=1 count=$length reads exactly $length bytes from
#     /dev/urandom; any shorter output indicates a pipeline error that must
#     be retried, not silently accepted. The previous || true swallowing the
#     dd rc is replaced by capturing rc explicitly and letting the -eq guard
#     detect any mismatch.
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
        # CRY-M1 FIX: dd bs=1 count=$length avoids the SIGPIPE that head -c
        # sends to tr when it finishes reading, which would exit non-zero under
        # set -euo pipefail.
        #
        # CRY-M1-followup: capture rc explicitly; do not swallow with || true.
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
# CRY-H1 FIX: The charset was previously a double-quoted string:
#   local charset="A-Za-z0-9!@#$%^&*()-_=+[]{}|;:,.<>?"
# The shell expands $%, $^, $*, $@ (and any matching variables) inside double
# quotes BEFORE tr sees the string, silently dropping those characters from
# the effective charset and producing weaker passwords with no error.
# Fixed by using $'...' ANSI-C quoting, where the $ prefix is part of the
# quoting syntax and all characters are treated as literals.
#
# NOTE: charset includes shell-special characters ($, !, etc.).
# Callers MUST use `printf '%s' "$password"` (not `echo`) when passing the
# result to external commands.
generate_secure_password() {
    local length="${1:-24}"
    # CRY-H1 FIX: $'...' ANSI-C quoting — every character is literal
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
# BUG-K3 FIX: CLI path previously used `echo -n "$password" | argon2`.
# echo -n is not POSIX; on dash and zsh it outputs the literal string '-n'
# followed by the password. Replaced with `printf '%s' "$password"` which
# is POSIX and behaves consistently across all shells.
#
# CRY-L1 FIX: Python path called sys.stdin.read() with no size cap, risking
# a very large argon2 call on corrupted input. Changed to sys.stdin.read(1024)
# to mirror the protective intent of printf '%s' on the CLI path.
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
            # CRY-L1 FIX: sys.stdin.read(1024) caps input to prevent runaway
            # memory usage on unexpectedly large / corrupted input.
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
#
# LC-1 FIX: Validate the cost factor before calling htpasswd. A caller
# passing rounds=6 (e.g. from a misconfigured .env) would silently produce
# a cryptographically weak credential. bcrypt cost must be in [10, 31]:
#   • 10 is the OWASP-recommended minimum for interactive logins.
#   • 31 is the maximum accepted by the bcrypt specification.
generate_bcrypt_hash() {
    local password="$1"
    local rounds="${2:-12}"

    [[ -z "$password" ]] && return 1

    # LC-1 FIX: guard against out-of-range cost factor.
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
#
# AUD-L2 FIX: The previous implementation computed SHA-256 of the file and
# compared it against the .sha256 sidecar, but the sidecar itself was not
# authenticated. An attacker who could replace both the file and its .sha256
# sidecar (e.g. via a misconfigured backup restore or a container volume
# mount) would pass the integrity check silently.
#
# Fix: when FILE_INTEGRITY_HMAC_KEY is set, re-derive the HMAC-SHA256 of the
# stored checksum and compare it against the .sha256.hmac sidecar BEFORE
# trusting the plain checksum. This ensures the sidecar itself has not been
# tampered with. If the HMAC sidecar is missing when the key is set, the
# check fails loudly (the operator is expected to have written it via
# write_file_integrity()).
#
# When FILE_INTEGRITY_HMAC_KEY is not set, the function falls back to the
# original plain SHA-256 comparison with a warning, preserving backward
# compatibility for callers that have not yet adopted HMAC sidecars.
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
    # Trim any trailing whitespace / newline
    stored_checksum="${stored_checksum%%[[:space:]]*}"

    # AUD-L2 FIX: Authenticate the sidecar via HMAC before trusting it.
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
        stored_hmac="${stored_hmac%%[[:space:]]*}"

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

# Export functions for use by scripts
export -f _stat_octal_perms_local _stat_file_size
export -f _derive_age_public_key
export -f is_sops_encrypted decrypt_sops_file encrypt_sops_file
export -f generate_age_key get_age_public_key check_age_key encrypt_data decrypt_data
export -f generate_secure_string generate_secure_password check_argon2_support generate_argon2_hash generate_bcrypt_hash
export -f calculate_sha256 verify_sha256 write_file_integrity verify_file_integrity secure_delete validate_crypto_environment
export DEFAULT_AGE_KEY_FILE

log_debug "Enhanced crypto library loaded successfully - standardized error handling with Age key validation" 2>/dev/null || true
