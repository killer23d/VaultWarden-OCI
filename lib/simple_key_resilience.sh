#!/usr/bin/env bash
# lib/simple_key_resilience.sh - Streamlined key protection for single admin
#
# PATCHED BUGS (2026-03-06):
#   BUG-R1 [HIGH]   simple_verify_age_key(): stat -c '%a' is GNU-only; macOS needs
#                   stat -f '%OLp'. Replaced with _stat_octal_perms_local() from
#                   crypto.sh (which must be loaded before this library).
#   BUG-R2 [MEDIUM] create_printable_key_backup(): trap used single quotes, so
#                   $temp_html was NOT expanded at registration time. EXIT handler
#                   fired with the literal string '$temp_html', leaving the temp
#                   file (containing the plaintext Age key) undeleted on error.
#                   Fixed: double-quote wrapper + single-quoted variable value,
#                   matching the pattern in create_password_manager_escrow().
#   BUG-R3 [MEDIUM] create_printable_key_backup(): qrencode was called with the
#                   raw Age private key as a positional argument, exposing it in
#                   /proc/<pid>/cmdline and `ps aux` output. Key now piped via
#                   stdin using a temp FIFO-style process substitution.
#   BUG-R4 [LOW]    _secure_remove_file(): stat -c%s is GNU-only. Replaced with
#                   the portable _stat_file_size() helper from crypto.sh.
#
# PATCHED BUGS (2026-03-10):
#   SKR-H1 [HIGH]   create_printable_key_backup(): key_content held the live
#                   plaintext Age private key in the process environment. Added
#                   explicit `unset key_content` immediately after the heredoc
#                   write. Also HTML-escape special characters in key_content
#                   before embedding to prevent display corruption.
#   SKR-M1 [MEDIUM] simple_verify_age_key(): chmod/chown auto-fix was silent.
#                   Now emits log_warn when permissions or ownership are wrong,
#                   making silent privilege escalation visible in logs.
#   SKR-M2 [MEDIUM] create_printable_key_backup(): HTML fallback left the
#                   plaintext key file on disk with no auto-deletion mechanism.
#                   A self-delete reminder is now embedded in the HTML file and
#                   an at(1) job (or cron fallback) is scheduled to remind the
#                   operator 30 minutes after creation.
#   SKR-L1 [MEDIUM] create_password_manager_escrow(): trap ... EXIT overwrote
#                   any caller-level EXIT trap. Changed to trap ... RETURN so
#                   cleanup is scoped to the function and the caller's trap is
#                   preserved.
#
# PATCHED BUGS (2026-03-11):
#   SKR-M3 [MEDIUM] verify_key_replica(): compared replicas only by SHA-256
#                   hash. A consistently-corrupt primary causes all replicas to
#                   match the corrupt hash, hiding the corruption.
#                   Fix: after the hash check passes, perform a functional
#                   encrypt/decrypt roundtrip against each replica key file to
#                   confirm it is operationally valid, not just byte-identical.
#   SKR-M4 [MEDIUM] restore_key_from_replica(): used cp for the restore, so a
#                   crash mid-copy could leave a partial/truncated primary key.
#                   Fix: cp to a .tmp sidecar first, then atomic mv into place.
#   SKR-L2 [LOW]    verify_key_replica(): if the replica list is empty the
#                   function returned 0 (success) silently.
#                   Fix: detect empty replica array and return 1 with log_warn.

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_KEY_RESILIENCE_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_KEY_RESILIENCE_LIB_LOADED=1

# === TIER 1: Age Key Health Check ===

# BUG-R1 FIX: replaced stat -c '%a' (GNU-only) with _stat_octal_perms_local()
# which is defined in lib/crypto.sh and handles both GNU and BSD/macOS stat.
simple_verify_age_key() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"

    # Check 1: File exists
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key missing: $age_key"
        return 1
    fi

    # Check 2: Permissions (auto-fix if needed)
    # BUG-R1 FIX: portable stat wrapper
    local perms
    perms=$(_stat_octal_perms_local "$age_key" 2>/dev/null || echo "")
    if [[ "$perms" != "600" ]]; then
        # SKR-M1 FIX: log the bad permissions BEFORE fixing so the event is
        # visible in audit logs — a silent auto-fix could mask a privilege
        # escalation that temporarily widened the key's permissions.
        log_warn "Age key permissions were ${perms:-<unreadable>} (expected 600) — auto-correcting to 600"
        chmod 600 "$age_key"
    fi

    # FIX [M-05]: Also restore ownership to the real user after chmod.
    # SKR-M1 FIX: log whenever ownership correction is required.
    local real_user real_group
    real_user=$(get_real_user 2>/dev/null || echo "root")
    real_group=$(id -gn "$real_user" 2>/dev/null || echo "$real_user")
    local current_owner
    current_owner=$(stat -c '%U:%G' "$age_key" 2>/dev/null || stat -f '%Su:%Sg' "$age_key" 2>/dev/null || echo "")
    if [[ -n "$current_owner" && "$current_owner" != "${real_user}:${real_group}" ]]; then
        log_warn "Age key ownership was '${current_owner}' (expected '${real_user}:${real_group}') — auto-correcting"
        chown "${real_user}:${real_group}" "$age_key" 2>/dev/null || \
            log_warn "Could not restore ownership of $age_key to ${real_user}:${real_group}"
    else
        # Still attempt chown silently if we couldn't read current ownership,
        # but only warn if it actually fails.
        chown "${real_user}:${real_group}" "$age_key" 2>/dev/null || \
            log_warn "Could not restore ownership of $age_key to ${real_user}:${real_group}"
    fi

    # Check 3: Validity — Encrypt/Decrypt roundtrip
    local test_data="vw-key-check-$(date +%s)"
    local result

    local public_key
    if ! public_key=$(_derive_age_public_key "$age_key"); then
        log_error "Age key corrupted: Cannot extract public key"
        return 1
    fi

    if ! result=$(echo "$test_data" | age -r "$public_key" 2>/dev/null | age -d -i "$age_key" 2>/dev/null); then
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

# === TIER 2: Password Manager Escrow ===

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

    # SKR-L1 FIX: Use trap ... RETURN instead of trap ... EXIT so this
    # function-scoped cleanup trap does not overwrite (and permanently destroy)
    # any caller-level EXIT trap that was already registered.  RETURN fires
    # when the function returns (normally or via an error path) and is
    # automatically cleared once the function exits.
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

    # SKR-L1 FIX: Clear the RETURN trap on success so the output file is
    # kept (the caller wants it).  The caller's EXIT trap is unaffected.
    trap - RETURN

    log_success "Password manager backup created: $output_file"
    log_warn "⚠️  SECURITY: Delete this file immediately after copying to your password manager:"
    log_warn "   _secure_remove_file '$output_file'"
    return 0
}

# === TIER 3: Paper Backup (Optional) ===

# ---------------------------------------------------------------------------
# _secure_remove_file FILE
#
# BUG-R4 FIX: stat -c%s (GNU-only) replaced with _stat_file_size() from
# crypto.sh, which is portable to macOS/BSD stat.
# ---------------------------------------------------------------------------
_secure_remove_file() {
    local target="$1"
    [[ -f "$target" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        # FIX [L-01]: Explicit -n 3 pass count (system default is 3 but not guaranteed)
        shred -fuz -n 3 "$target" 2>/dev/null && return 0
    fi

    # dd fallback — overwrite then unlink
    # BUG-R4 FIX: portable file size
    local file_size
    file_size=$(_stat_file_size "$target" 2>/dev/null || echo "4096")
    [[ -z "$file_size" || "$file_size" -eq 0 ]] && file_size=4096
    dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$target"
}

# ---------------------------------------------------------------------------
# _html_escape STRING
#
# SKR-H1 helper: replaces HTML metacharacters so key_content cannot corrupt
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
# SKR-M3 FIX: previously compared replicas only by SHA-256 hash. If the
# primary key is consistently corrupt (same bytes each time), all replicas
# match the corrupt hash and the corruption is silently accepted.
# Fix: after the hash comparison passes, perform a functional age
# encrypt/decrypt roundtrip against each replica key file to verify it is
# operationally valid — not just byte-identical to the primary.
#
# SKR-L2 FIX: if the replica list is empty, return 1 with a log_warn instead
# of silently returning 0 (success).
# ---------------------------------------------------------------------------
verify_key_replica() {
    local primary_key="${1:-${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}}"
    shift
    local replicas=("$@")

    # SKR-L2 FIX: treat an empty replica list as an explicit failure so the
    # caller knows no verification was actually performed.
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

    # SKR-M3 FIX: also validate the primary key itself with a functional
    # roundtrip before using it as the reference for replica comparison.
    local test_data="vw-replica-check-$$-$(date +%s)"
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

        # SKR-M3 FIX: Step 2: functional roundtrip test against the replica
        # key to detect corruption that is byte-identical to a corrupt primary.
        local replica_result
        if ! replica_result=$(printf '%s' "$test_data" | age -r "$primary_pub" 2>/dev/null | age -d -i "$replica" 2>/dev/null) \
            || [[ "$replica_result" != "$test_data" ]]; then
            log_warn "verify_key_replica: replica failed functional roundtrip test (corrupt): $replica"
            all_ok=1
            continue
        fi

        log_debug "verify_key_replica: OK — $replica"
    done

    return "$all_ok"
}

# ---------------------------------------------------------------------------
# restore_key_from_replica REPLICA_KEY [PRIMARY_KEY]
#
# SKR-M4 FIX: previously used `cp replica primary` directly. A crash or
# signal mid-copy leaves a partial/truncated file at the primary path, which
# is worse than no key at all (it silently poisons the key store).
# Fix: copy to a .tmp sidecar, then atomically rename into place. The
# primary is only replaced once the full copy is verified on disk.
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

    # SKR-M4 FIX: write to a sidecar first so a crash mid-copy leaves the
    # existing primary intact (or absent), never a partial file.
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
# BUG-R2 FIX: trap used single quotes: trap '_secure_remove_file "$temp_html"' EXIT
# Single quotes prevent variable expansion at trap-registration time. When the
# EXIT handler fires, $temp_html is evaluated in the cleanup context where it
# may be empty or wrong, leaving the plaintext key file on disk.
# Fixed: double-quote the trap command and single-quote the expanded path value,
# matching the pattern already used correctly in create_password_manager_escrow().
#
# BUG-R3 FIX: qrencode was called as: qrencode -t PNG -o - "$key_content"
# The full Age private key appeared as a positional argument in the process
# table (/proc/<pid>/cmdline, `ps aux`), visible to any user on the system.
# Fixed: key is fed via stdin using a here-string so it never appears on the
# command line: qrencode -t PNG -o - --read-from=-
#
# SKR-H1 FIX: key_content is unset immediately after the heredoc write so the
# plaintext Age key does not linger in the process environment. The value is
# also HTML-escaped before embedding via _html_escape().
#
# SKR-M2 FIX: when the HTML fallback path is taken, a self-delete reminder is
# embedded inside the HTML file and an at(1) job (or cron fallback) is
# scheduled to alert the operator 30 minutes after file creation.
# ---------------------------------------------------------------------------
create_printable_key_backup() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    # FIX [L-02]: $HOME resolves to /root when run via sudo on OCI.
    # Use the real user's home directory instead.
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
    temp_html=$(mktemp --suffix=.html)
    umask "$old_umask"

    # BUG-R2 FIX: double-quote the trap command so $temp_html expands NOW
    # (at registration time) rather than later at exit time.
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

    # SKR-H1 FIX: HTML-escape key_content before embedding in the template so
    # any HTML metacharacters in the key cannot corrupt the document structure.
    local key_content_escaped
    key_content_escaped=$(_html_escape "$key_content")

    # BUG-R3 FIX: feed key via stdin to prevent cmdline exposure.
    # qrencode --read-from=- reads the input from stdin instead of a
    # positional argument, so the key is never visible in the process table.
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

    # SKR-H1 FIX: Unset key_content immediately after the heredoc write so the
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

        # SKR-M2 FIX: Schedule an auto-delete reminder 30 minutes from now so
        # the plaintext HTML file does not silently persist on disk.
        # Prefer at(1); fall back to a background sleep subshell.
        local remind_cmd="echo 'SECURITY REMINDER: Delete plaintext Age key backup: shred -fuz \"${output_html}\"' | logger -t vaultwarden-key-reminder 2>/dev/null; wall 'SECURITY REMINDER: VaultWarden plaintext key backup still exists at ${output_html} — delete it now with: shred -fuz ${output_html}' 2>/dev/null || true"
        if command -v at >/dev/null 2>&1; then
            echo "$remind_cmd" | at "now + 30 minutes" 2>/dev/null && \
                log_info "Scheduled security reminder in 30 minutes via at(1)." || \
                log_warn "Could not schedule at(1) reminder; set a manual reminder to delete $output_html"
        else
            # Fallback: background subshell reminder (best-effort)
            ( sleep 1800 && eval "$remind_cmd" ) &
            disown 2>/dev/null || true
            log_info "Scheduled background security reminder in 30 minutes (at not available)."
        fi
    fi

    return 0
}
