#!/usr/bin/env bash
# backup-with-bootstrap.sh - Enhanced backup with bootstrap key management
# Solves circular dependency by encrypting Age key with GPG (separate passphrase)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Source existing libraries
source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"

# Configuration
BACKUP_TYPE="${1:-emergency}"
BOOTSTRAP_DIR="$HOME/.vaultwarden-bootstrap"
GPG_KEY_NAME="vaultwarden-bootstrap"

show_help() {
    cat << 'EOF'
VaultWarden Enhanced Backup with Bootstrap Key Management

USAGE:
  ./backup-with-bootstrap.sh [TYPE] [OPTIONS]

ARGUMENTS:
  TYPE                          Backup type: db, full, or emergency (default: emergency)

OPTIONS:
  --rclone                      Sync backup to rclone remote
  --email                       Send email notification
  --help                        Show this help

WHAT THIS DOES:
  1. Creates standard encrypted backup using Age key
  2. Creates GPG-encrypted copy of Age key (bootstrap key)
  3. Generates recovery instructions
  4. Optional: Syncs to remote storage

BOOTSTRAP KEY SECURITY:
  - Age key encrypted with GPG passphrase (you set this)
  - GPG passphrase is NOT stored anywhere
  - Store bootstrap key separately from encrypted backups
  - Store GPG private key backup in password manager

RECOVERY WORKFLOW:
  1. Decrypt bootstrap key with GPG passphrase
  2. Use Age key to decrypt backup
  3. Restore system
EOF
}

# Parse arguments
BACKUP_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --help) show_help; exit 0 ;;
        db|full|emergency) BACKUP_TYPE="$arg" ;;
        *) BACKUP_ARGS+=("$arg") ;;
    esac
done

log_section() {
    echo "" >&2
    echo -e "${COLOR_CYAN}========================================${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}$1${COLOR_RESET}" >&2
    echo -e "${COLOR_CYAN}========================================${COLOR_RESET}" >&2
}

check_gpg_prerequisites() {
    log_info "Checking GPG prerequisites..."
    
    if ! has_command gpg; then
        log_error "GPG not found. Install with: apt-get install gnupg"
        return 1
    fi
    
    # Check if GPG key exists
    if ! gpg --list-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
        log_warn "GPG key '$GPG_KEY_NAME' not found. Creating one now..."
        create_gpg_key || return 1
    else
        log_success "GPG key '$GPG_KEY_NAME' exists"
    fi
    
    return 0
}

create_gpg_key() {
    log_info "Creating GPG key for bootstrap key escrow..."
    
    cat > /tmp/gpg-keygen.conf << EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: VaultWarden Bootstrap
Name-Email: vaultwarden-bootstrap@localhost
Expire-Date: 0
%no-protection
%commit
EOF
    
    if gpg --batch --gen-key /tmp/gpg-keygen.conf 2>&1 | tee /tmp/gpg-gen.log >&2; then
        rm -f /tmp/gpg-keygen.conf /tmp/gpg-gen.log
        log_success "GPG key created successfully"
        
        # Immediately backup the GPG key
        local gpg_backup_file="$BOOTSTRAP_DIR/gpg-private-key-backup.asc"
        mkdir -p "$BOOTSTRAP_DIR"
        chmod 700 "$BOOTSTRAP_DIR"
        
        gpg --export-secret-keys --armor "$GPG_KEY_NAME" > "$gpg_backup_file"
        chmod 600 "$gpg_backup_file"
        
        log_warn "IMPORTANT: GPG private key backed up to: $gpg_backup_file"
        log_warn "Store this file in your password manager or secure location!"
        return 0
    else
        log_error "Failed to create GPG key"
        rm -f /tmp/gpg-keygen.conf /tmp/gpg-gen.log
        return 1
    fi
}

create_bootstrap_key() {
    local timestamp="$1"
    local age_key_file="$SOPS_AGE_KEY_FILE"
    
    log_section "Creating Bootstrap Key Escrow"
    
    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: $age_key_file"
        return 1
    fi
    
    mkdir -p "$BOOTSTRAP_DIR"
    chmod 700 "$BOOTSTRAP_DIR"
    
    local bootstrap_file="$BOOTSTRAP_DIR/age-key-$timestamp.gpg"
    
    log_info "Encrypting Age key with GPG..."
    log_warn "You will be prompted for a BOOTSTRAP PASSPHRASE."
    log_warn "This passphrase is SEPARATE from any other system password."
    log_warn "Remember it or store it in your password manager!"
    echo "" >&2
    
    # Encrypt Age key with symmetric GPG (requires passphrase)
    if gpg --symmetric \
           --cipher-algo AES256 \
           --output "$bootstrap_file" \
           "$age_key_file" 2>&1 | grep -v "^gpg:"; then
        
        chmod 600 "$bootstrap_file"
        log_success "Bootstrap key created: $(basename "$bootstrap_file")"
        echo "$bootstrap_file"
        return 0
    else
        log_error "Failed to create bootstrap key"
        return 1
    fi
}

create_recovery_manifest() {
    local timestamp="$1"
    local backup_file="$2"
    local bootstrap_file="$3"
    
    log_info "Creating recovery manifest..."
    
    local manifest_file="$BOOTSTRAP_DIR/RECOVERY-$timestamp.txt"
    local backup_filename="$(basename "$backup_file")"
    local bootstrap_filename="$(basename "$bootstrap_file")"
    local backup_checksum="$(cat "$backup_file.sha256" 2>/dev/null || echo "N/A")"
    local backup_size="$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "N/A")"
    
    cat > "$manifest_file" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║        VaultWarden Emergency Recovery Kit - $timestamp         ║
╚══════════════════════════════════════════════════════════════════════╝

Created: $(date)
Hostname: $(hostname)
Backup Type: $BACKUP_TYPE

═══════════════════════════════════════════════════════════════════════
📦 BACKUP FILES INCLUDED
═══════════════════════════════════════════════════════════════════════

1. Encrypted Backup (Age-encrypted):
   File: $backup_filename
   Size: $backup_size
   SHA256: $backup_checksum
   Location: $(dirname "$backup_file")
   
2. Bootstrap Key (GPG-encrypted Age key):
   File: $bootstrap_filename
   Location: $(dirname "$bootstrap_file")
   
3. This Recovery Manifest:
   File: $(basename "$manifest_file")

═══════════════════════════════════════════════════════════════════════
🔐 SECURITY ARCHITECTURE
═══════════════════════════════════════════════════════════════════════

Tier 1: Bootstrap Key (Age key encrypted with GPG passphrase)
  └─> Requires: GPG passphrase you set during backup creation
  └─> Protected: Symmetric AES-256 encryption
  
Tier 2: Encrypted Backup (Age-encrypted with the Age key)
  └─> Requires: Age key from Tier 1
  └─> Protected: Age encryption
  
This eliminates circular dependency: GPG passphrase ≠ Age key

═══════════════════════════════════════════════════════════════════════
🚨 RECOVERY PROCEDURE
═══════════════════════════════════════════════════════════════════════

Step 1: Decrypt the Bootstrap Key
────────────────────────────────
Command:
  gpg --decrypt $bootstrap_filename > age-key.txt

You will be prompted for the BOOTSTRAP PASSPHRASE you set during backup.

Step 2: Decrypt the Encrypted Backup
─────────────────────────────────────
Command:
  age -d -i age-key.txt $backup_filename | tar -xzf -

This extracts all files to current directory.

Step 3: Restore Age Key to Project
───────────────────────────────────
Command:
  cd VaultWarden-OCI
  mkdir -p secrets/keys
  cp ../age-key.txt secrets/keys/age-key.txt
  chmod 600 secrets/keys/age-key.txt

Step 4: Extract Other Secrets (if needed)
──────────────────────────────────────────
If this was an emergency backup, the 'secrets' directory is in the archive.
All SOPS-encrypted files should already be present.

Step 5: Start the System
─────────────────────────
Command:
  ./startup.sh
  make up

═══════════════════════════════════════════════════════════════════════
💾 BACKUP STORAGE RECOMMENDATIONS
═══════════════════════════════════════════════════════════════════════

Store BOOTSTRAP KEY ($bootstrap_filename) in:
  ✓ Password manager (1Password, Bitwarden) as secure note
  ✓ USB drive in fireproof safe
  ✓ Encrypted cloud storage (separate from main backup)
  ✓ Trusted family member/friend (sealed envelope)

Store ENCRYPTED BACKUP ($backup_filename) in:
  ✓ Primary: Encrypted cloud (rclone remote)
  ✓ Secondary: External HDD/NAS
  ✓ Tertiary: Offsite USB drive

Store GPG PRIVATE KEY BACKUP in:
  ✓ Password manager (highest priority!)
  ✓ Bank safety deposit box
  ✓ Trusted contact (encrypted)

CRITICAL: Never store bootstrap key and backup in the same location!

═══════════════════════════════════════════════════════════════════════
✅ TESTING YOUR BACKUP
═══════════════════════════════════════════════════════════════════════

Test recovery quarterly:
1. Try decrypting bootstrap key in a test directory
2. Verify Age key extraction succeeds
3. Test decrypt backup (don't need to extract fully)
4. Document any issues

Testing command:
  gpg --decrypt $bootstrap_filename | head -c 50
  (Should show Age key beginning)

═══════════════════════════════════════════════════════════════════════
⚠️  IMPORTANT NOTES
═══════════════════════════════════════════════════════════════════════

• Bootstrap passphrase is NOT stored anywhere - memorize or save in
  password manager separately
  
• If you lose the bootstrap passphrase, you cannot decrypt the Age key,
  and you cannot recover the backup - THERE IS NO RECOVERY

• The GPG private key backup ($BOOTSTRAP_DIR/gpg-private-key-backup.asc)
  allows recovery if you lose your GPG keyring
  
• Test recovery procedure at least once before relying on this backup

═══════════════════════════════════════════════════════════════════════
📞 EMERGENCY CONTACTS
═══════════════════════════════════════════════════════════════════════

Primary Admin: _______________________
Backup Admin:  _______________________
Hosting Info:  _______________________

═══════════════════════════════════════════════════════════════════════

Generated by: backup-with-bootstrap.sh
Repository: https://github.com/killer23d/VaultWarden-OCI
EOF

    chmod 600 "$manifest_file"
    log_success "Recovery manifest created: $(basename "$manifest_file")"
    echo "$manifest_file"
}

cleanup_old_bootstrap_files() {
    log_info "Cleaning up old bootstrap files (keeping last 5)..."
    
    cd "$BOOTSTRAP_DIR" || return 0
    
    # Remove old Age key bootstrap files
    ls -t age-key-*.gpg 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    
    # Remove old recovery manifests
    ls -t RECOVERY-*.txt 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    
    log_success "Cleanup completed"
}

create_complete_emergency_kit() {
    local timestamp="$1"
    local backup_file="$2"
    local bootstrap_file="$3"
    local manifest_file="$4"
    
    log_section "Creating Complete Emergency Kit Package"
    
    local kit_dir="$HOME/vaultwarden-emergency-kit-$timestamp"
    local kit_archive="$HOME/vaultwarden-emergency-kit-$timestamp.tar.gz"
    
    mkdir -p "$kit_dir"
    chmod 700 "$kit_dir"
    
    # Copy all components
    cp "$backup_file" "$kit_dir/" || return 1
    cp "$backup_file.sha256" "$kit_dir/" 2>/dev/null || true
    cp "$backup_file.meta" "$kit_dir/" 2>/dev/null || true
    cp "$bootstrap_file" "$kit_dir/" || return 1
    cp "$manifest_file" "$kit_dir/README.txt" || return 1
    
    # Create archive
    tar -czf "$kit_archive" -C "$(dirname "$kit_dir")" "$(basename "$kit_dir")" || return 1
    chmod 600 "$kit_archive"
    rm -rf "$kit_dir"
    
    log_success "Complete emergency kit: $kit_archive"
    echo "$kit_archive"
}

main() {
    log_section "VaultWarden Enhanced Backup with Bootstrap Protection"
    
    load_env_file || exit 1
    
    # Check prerequisites
    check_gpg_prerequisites || exit 1
    
    # Generate timestamp for all files
    local timestamp="$(date +%Y%m%d-%H%M%S)"
    
    # Step 1: Create standard backup using existing backup.sh
    log_section "Step 1: Creating Standard Encrypted Backup"
    log_info "Running: ./backup.sh --type $BACKUP_TYPE ${BACKUP_ARGS[*]}"
    
    local backup_file
    backup_file=$(./backup.sh --type "$BACKUP_TYPE" "${BACKUP_ARGS[@]}" 2>&1 | tee /dev/stderr | tail -1)
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup creation failed or file not found: $backup_file"
        exit 1
    fi
    
    log_success "Backup created: $(basename "$backup_file")"
    
    # Step 2: Create bootstrap key (GPG-encrypted Age key)
    log_section "Step 2: Creating Bootstrap Key Escrow"
    local bootstrap_file
    bootstrap_file=$(create_bootstrap_key "$timestamp") || exit 1
    
    # Step 3: Create recovery manifest
    log_section "Step 3: Generating Recovery Documentation"
    local manifest_file
    manifest_file=$(create_recovery_manifest "$timestamp" "$backup_file" "$bootstrap_file") || exit 1
    
    # Step 4: Optional - Create complete kit package
    log_section "Step 4: Creating Complete Emergency Kit Package"
    local kit_archive
    kit_archive=$(create_complete_emergency_kit "$timestamp" "$backup_file" "$bootstrap_file" "$manifest_file") || exit 1
    
    # Step 5: Cleanup
    cleanup_old_bootstrap_files
    
    # Final summary
    log_section "Backup with Bootstrap Protection Complete!"
    
    cat << EOF >&2

╔══════════════════════════════════════════════════════════════════════╗
║                      BACKUP SUMMARY                                  ║
╚══════════════════════════════════════════════════════════════════════╝

📦 Files Created:
   1. Encrypted Backup:     $(basename "$backup_file")
      Location: $(dirname "$backup_file")
      
   2. Bootstrap Key:        $(basename "$bootstrap_file")
      Location: $BOOTSTRAP_DIR
      
   3. Recovery Manifest:    $(basename "$manifest_file")
      Location: $BOOTSTRAP_DIR
      
   4. Complete Kit:         $(basename "$kit_archive")
      Location: $(dirname "$kit_archive")

🔐 Security Architecture:
   ✓ Backup encrypted with Age key
   ✓ Age key encrypted with GPG passphrase
   ✓ No circular dependency
   ✓ Two-tier protection

📋 Next Steps:

   1. CRITICAL - Backup GPG Private Key:
      $ gpg --export-secret-keys --armor "$GPG_KEY_NAME" > ~/gpg-backup.asc
      Store in password manager: ~/gpg-backup.asc
      (Or use: $BOOTSTRAP_DIR/gpg-private-key-backup.asc)

   2. Store Bootstrap Key Separately:
      • Copy $bootstrap_file to:
        - Password manager (as secure attachment)
        - USB drive (encrypted, in safe)
        - Cloud storage (separate from main backup)

   3. Store Complete Kit:
      • Copy $kit_archive to:
        - Primary: Encrypted cloud storage
        - Secondary: External backup drive
        - Tertiary: Offsite location

   4. Store Recovery Manifest:
      • Read: $manifest_file
      • Keep copy with each backup location

   5. Test Recovery:
      • Verify you can decrypt bootstrap key
      • Test quarterly: gpg --decrypt $(basename "$bootstrap_file")

⚠️  REMEMBER:
   • Bootstrap passphrase is NOT stored anywhere
   • Store it in your password manager
   • Without it, backups are unrecoverable
   • Test recovery before you need it!

EOF

    exit 0
}

main "$@"
