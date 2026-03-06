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
        log_warn "Fixing Age key permissions: ${perms:-<unreadable>} -> 600"
        chmod 600 "$age_key"
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

    # Register EXIT trap NOW — any failure from this point on will trigger
    # _secure_remove_file() to wipe the (possibly partially-written) plaintext.
    # shellcheck disable=SC2064  # intentional: expand $output_file now
    trap "_secure_remove_file '$output_file'" EXIT

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
    trap - EXIT

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
        shred -fuz "$target" 2>/dev/null && return 0
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
# ---------------------------------------------------------------------------
create_printable_key_backup() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local output_pdf="${1:-$HOME/vaultwarden-key-backup.pdf}"

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
        <div class="key">${key_content}</div>
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
</body>
</html>
EOF

    if command -v wkhtmltopdf >/dev/null 2>&1; then
        wkhtmltopdf -q "$temp_html" "$output_pdf"
        _secure_remove_file "$temp_html"
        trap - EXIT
        log_success "Printable PDF backup created: $output_pdf"
    else
        mv "$temp_html" "${output_pdf%.pdf}.html"
        trap - EXIT
        log_warn "wkhtmltopdf not found. Created HTML instead: ${output_pdf%.pdf}.html"
        log_warn "SECURITY: The HTML file contains your plaintext Age key."
        log_warn "          Store it securely and delete it after printing:"
        log_warn "          shred -fuz '${output_pdf%.pdf}.html'"
        log_info  "Open in browser and print to PDF manually."
    fi

    return 0
}
