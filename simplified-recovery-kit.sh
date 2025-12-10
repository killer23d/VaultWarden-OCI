#!/usr/bin/env bash
# simplified-recovery-kit.sh - Practical key escrow for single admin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/simple_key_resilience.sh"

show_help() {
    cat << 'EOF'
Simplified VaultWarden Recovery Kit for Single Admin

USAGE:
  ./simplified-recovery-kit.sh [OPTIONS]

OPTIONS:
  --create          Create password manager-ready key backup
  --verify          Verify existing key health
  --print           Generate printable/PDF backup (optional)
  --help            Show this help

RECOMMENDED WORKFLOW:
  1. ./simplified-recovery-kit.sh --create
  2. Copy output to password manager (1Password, Bitwarden, etc.)
  3. Delete local copy after confirming saved
  4. Optional: ./simplified-recovery-kit.sh --print (store in safe)

ONGOING MAINTENANCE:
  - Key verification happens automatically with every backup
  - Re-run --create only if you rotate your key
EOF
}

ACTION=""
for arg in "$@"; do
    case "$arg" in
        --create) ACTION="create" ;;
        --verify) ACTION="verify" ;;
        --print) ACTION="print" ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $arg"; show_help; exit 1 ;;
    esac
done

[[ -z "$ACTION" ]] && { show_help; exit 1; }

load_env_file || exit 1

case "$ACTION" in
    verify)
        log_info "Verifying Age key health..."
        if simple_verify_age_key; then
            log_success "✅ Age key is healthy and functional"
            exit 0
        else
            log_error "❌ Age key verification failed"
            exit 1
        fi
        ;;
    
    create)
        log_info "Creating password manager-ready backup..."
        output_file="$HOME/vaultwarden-age-key-$(date +%Y%m%d-%H%M%S).txt"
        
        create_password_manager_escrow "$output_file" || exit 1
        
        echo ""
        log_warn "═══════════════════════════════════════════════════════"
        log_warn "  IMMEDIATE ACTION REQUIRED"
        log_warn "═══════════════════════════════════════════════════════"
        echo ""
        echo "1. Open your password manager (1Password, Bitwarden, etc.)"
        echo "2. Create a new Secure Note called: 'VaultWarden Age Key'"
        echo "3. Copy the entire file content:"
        echo "   cat $output_file"
        echo ""
        echo "4. After confirming it's saved, DELETE the local file:"
        echo "   rm $output_file"
        echo ""
        read -p "Press Enter after you've saved to password manager..."
        
        if [[ -f "$output_file" ]]; then
            read -p "Delete local copy now? (Y/n): " delete_confirm
            if [[ ! "$delete_confirm" =~ ^[Nn]$ ]]; then
                if command -v shred >/dev/null 2>&1; then
                    shred -u "$output_file"
                else
                    rm -f "$output_file"
                fi
                log_success "Local copy deleted securely"
            else
                log_warn "Remember to delete manually: rm $output_file"
            fi
        fi
        ;;
    
    print)
        create_printable_key_backup || exit 1
        log_info "Print and store in fireproof safe or safety deposit box"
        ;;
esac

exit 0
