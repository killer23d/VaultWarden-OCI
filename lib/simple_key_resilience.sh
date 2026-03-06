#!/usr/bin/env bash
# lib/simple_key_resilience.sh - Streamlined key protection for single admin

# Ensure this library is only loaded once
[[ -n "${VAULTWARDEN_KEY_RESILIENCE_LIB_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_KEY_RESILIENCE_LIB_LOADED=1

# === TIER 1: Age Key Health Check (Built into backup.sh) ===

simple_verify_age_key() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"

    # Check 1: File exists
    if [[ ! -f "$age_key" ]]; then
        log_error "Age key missing: $age_key"
        return 1
    fi

    # Check 2: Permissions (auto-fix if needed)
    local perms
    perms=$(stat -c "%a" "$age_key" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        log_warn "Fixing Age key permissions: $perms -> 600"
        chmod 600 "$age_key"
    fi

    # Check 3: Validity and Functionality (Encrypt/Decrypt roundtrip)
    # FIX: Use _derive_age_public_key() instead of calling `age-keygen -y`
    # directly. The helper is Ubuntu 22.04-compatible and is already used in
    # create_printable_key_backup(), making all public-key derivation consistent.
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

# ---------------------------------------------------------------------------
# create_password_manager_escrow OUTPUT_FILE
#
# FIX [HIGH]: Plaintext Age key written to disk with no EXIT trap.
#
# An EXIT trap is registered immediately after the output file is created
# (via install -m 600) so that any early return, signal, or error causes
# _secure_remove_file() to wipe the plaintext file. The trap is explicitly
# cleared (trap - EXIT) only on successful completion.
# ---------------------------------------------------------------------------
create_password_manager_escrow() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local output_file="$1"

    if [[ -z "$output_file" ]]; then
        log_error "Output file path required for escrow creation"
        return 1
    fi

    log_info "Creating password manager-ready Age key backup..."

    # Create the output file with secure permissions BEFORE writing any key
    # material, so that the window where the file exists but is world-readable
    # is zero.
    if ! install -m 600 /dev/null "$output_file"; then
        log_error "Failed to create secure output file: $output_file"
        return 1
    fi

    # Register EXIT trap NOW — any failure from this point on will trigger
    # _secure_remove_file() to wipe the (possibly partially-written) plaintext.
    # shellcheck disable=SC2064  # intentional: expand $output_file now
    trap "_secure_remove_file '$output_file'" EXIT

    # FIX: Use _derive_age_public_key() for Ubuntu 22.04 compatibility.
    local pub_key
    if ! pub_key=$(_derive_age_public_key "$age_key"); then
        log_error "Failed to derive Age public key"
        return 1  # EXIT trap cleans up
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

    # Ensure output file is still mode 600 after the heredoc write.
    chmod 600 "$output_file"

    # Success — disarm the EXIT trap. The caller owns the file lifecycle from
    # here and is responsible for calling _secure_remove_file() after use.
    trap - EXIT

    log_success "Password manager backup created: $output_file"
    log_warn "⚠️  SECURITY: Delete this file immediately after copying to your password manager:"
    log_warn "   _secure_remove_file '$output_file'"
    return 0
}

# === TIER 3: Paper Backup (Optional) ===

# ---------------------------------------------------------------------------
# _secure_remove_file FILE
# Overwrite FILE with random data before unlinking.
# Uses shred if available; falls back to dd; falls back to plain rm with warning.
# ---------------------------------------------------------------------------
_secure_remove_file() {
    local target="$1"
    [[ -f "$target" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        shred -fuz "$target" 2>/dev/null && return 0
    fi

    # dd fallback — overwrite then unlink
    local file_size
    file_size=$(stat -c%s "$target" 2>/dev/null || echo "4096")
    dd if=/dev/urandom of="$target" bs="$file_size" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$target"
}

create_printable_key_backup() {
    local age_key="${SOPS_AGE_KEY_FILE:-secrets/keys/age-key.txt}"
    local output_pdf="${1:-$HOME/vaultwarden-key-backup.pdf}"

    log_info "Creating printable key backup..."

    if ! command -v qrencode >/dev/null 2>&1; then
        log_warn "qrencode not found - skipping QR code generation"
        log_info "Install with: sudo apt install qrencode"
    fi

    # Set umask 077 BEFORE mktemp so the temp file is created
    # with mode 600 rather than the default 644.
    local old_umask
    old_umask=$(umask)
    umask 077
    local temp_html
    temp_html=$(mktemp --suffix=.html)
    umask "$old_umask"

    # Register the temp file for secure removal on EXIT so the
    # plaintext Age key is wiped even if the script is interrupted.
    trap '_secure_remove_file "$temp_html"' EXIT

    local pub_key
    pub_key=$(_derive_age_public_key "$age_key")
    local key_content
    key_content=$(cat "$age_key")
    local hostname_val
    hostname_val=$(hostname)
    local date_val
    date_val=$(date)

    # Generate QR Code base64 if possible
    local qr_img_tag=""
    if command -v qrencode >/dev/null 2>&1; then
        local qr_base64
        qr_base64=$(qrencode -t PNG -o - "$key_content" | base64 -w0)
        qr_img_tag="<div class='box'><h3>QR Code (Digital Import)</h3><p>Scan to import key:</p><img src='data:image/png;base64,${qr_base64}' style='width: 200px'></div>"
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
        # Secure-delete the temp HTML (contains plaintext key).
        _secure_remove_file "$temp_html"
        trap - EXIT
        log_success "Printable PDF backup created: $output_pdf"
    else
        # Move HTML to output path; secure-delete is handled by EXIT trap if
        # the caller does not explicitly clean up the HTML file.
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
