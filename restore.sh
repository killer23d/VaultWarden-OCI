#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
#
# Supports both archive formats:
#   version=2 / archive_format=relative  →  staged restore (atomic, safe)
#   version=1 (legacy absolute paths)    →  direct -C / extraction (backward compat)
#
# Safety features:
#   - require_root enforced via lib/common.sh (--list is exempt)
#   - All decrypted artifacts in mktemp dir + EXIT/INT/TERM trap
#   - Host sqlite3 for integrity checks (FIX-R06: Docker dependency removed)
#   - tar member validation blocks path traversal before extraction
#     (FIX-R01: now applied to BOTH legacy v1 AND current v2 paths)
#   - Staged full restore: extract → validate → atomic mv (all-or-nothing)
#   - PROJECT_ROOT config files (.env, docker-compose.yml, caddy/, fail2ban/)
#     restored from archive after STATE_DIR promotion; secrets/ and *.sh
#     scripts are intentionally excluded
#   - Pre-restore emergency snapshot before any destructive operation
#   - AGE_KEY_FILE read from .env (SOPS_AGE_KEY_FILE) with safe default
#   - .sha256 sidecar verified before decryption (FIX-R05)
#   - flock mutex prevents concurrent restore races (FIX-R03)
#   - .pre-restore-* artefacts pruned to keep last 3 (FIX-R08)

set -euo pipefail

SCRIPT_DIR="$(cd ""$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Shared operations lock (update.sh/maintenance.sh/restore.sh)
VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"       2>/dev/null || true
source "lib/backup_utils.sh" 2>/dev/null || true
source "lib/crypto.sh"       2>/dev/null || true

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BACKUP_FILE=""
RESTORE_TYPE=""
USE_LATEST=false
LIST_ONLY=false
DRY_RUN=false
FORCE=false
NO_PRE_BACKUP=false
SKIP_VERIFICATION=false
RESTORE_ENV=true

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh [OPTIONS]

OPTIONS:
    --list                  List available backups and exit (no root required)
    --file FILE             Restore a specific backup file (.age)
    --type TYPE             db | full | emergency (helps resolve --latest)
    --latest                Use newest backup (optionally filtered by --type)
    --no-backup             Skip pre-restore emergency snapshot
    --skip-verification     Skip integrity check (not recommended)
    --skip-env              Do not restore archived .env over current .env
    --dry-run               Show what would happen without making changes
    --force                 Skip confirmation prompts
    --help                  Show this help

EXAMPLES:
    ./restore.sh --list
    sudo ./restore.sh --latest --type db --force
    sudo ./restore.sh --file backups/full/full_backup_20260101_120000.tar.gz.age
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)               LIST_ONLY=true;         shift ;; 
        --file)               BACKUP_FILE="$2";       shift 2 ;; 
        --type)               RESTORE_TYPE="$2";      shift 2 ;; 
        --latest)             USE_LATEST=true;        shift ;; 
        --no-backup)          NO_PRE_BACKUP=true;     shift ;; 
        --skip-verification)  SKIP_VERIFICATION=true; shift ;; 
        --skip-env)           RESTORE_ENV=false;      shift ;; 
        --dry-run)            DRY_RUN=true;           shift ;; 
        --force)              FORCE=true;             shift ;; 
        --help)               show_help; exit 0 ;; 
        *)                    log_error "Unknown option: $1"; show_help; exit 1 ;; 
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_find_latest_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -name "*.age" -type f | while IFS= read -r f; do
        printf '%s %s\n' \
            "$(stat -c%Y "$f" 2>/dev/null || stat -f%m "$f" 2>/dev/null || echo 0)" \
            "$f"
    done | sort -n | tail -1 | cut -d' ' -f2- || true
}
list_backups() {
    local types=("db" "full" "emergency")
    for t in "${types[@]}"; do
        echo ""
        log_info "Available ${t} backups:"
        if [[ -d "$PROJECT_ROOT/backups/$t" ]]; then
            find "$PROJECT_ROOT/backups/$t" -name "*.age" -type f \
                -exec ls -lh {} \; 2>/dev/null | sort -r | head -n 20 || true
        else
            echo "  (none)"
        fi
    done
}
resolve_backup_file() {
    if [[ "$USE_LATEST" == "true" ]]; then
        if [[ -n "$RESTORE_TYPE" ]]; then
            BACKUP_FILE="$(_find_latest_backup "$PROJECT_ROOT/backups/$RESTORE_TYPE" || true)"
            [[ -n "$BACKUP_FILE" ]] || { log_error "No backups found for type: $RESTORE_TYPE"; return 1; }
            return 0
        fi
        local best="" best_mtime=0 candidate mtime
        for t in db full emergency; do
            candidate="$(_find_latest_backup "$PROJECT_ROOT/backups/$t" || true)"
            if [[ -n "$candidate" ]]; then
                mtime=$(stat -c%Y "$candidate" 2>/dev/null || stat -f%m "$candidate" 2>/dev/null || echo 0)
                if (( mtime > best_mtime )); then
                    best_mtime="$mtime"; best="$candidate"; RESTORE_TYPE="$t"
                fi
            fi
        done
        [[ -n "$best" ]] || { log_error "No backups found in any backup directory"; return 1; }
        BACKUP_FILE="$best"
        return 0
    fi

    if [[ -n "$BACKUP_FILE" ]]; then
        [[ -f "$BACKUP_FILE" ]] || { log_error "Backup file not found: $BACKUP_FILE"; return 1; }
        if [[ -z "$RESTORE_TYPE" ]]; then
            if   [[ "$BACKUP_FILE" == */db/* ]];        then RESTORE_TYPE="db"
            elif [[ "$BACKUP_FILE" == */full/* ]];      then RESTORE_TYPE="full"
            elif [[ "$BACKUP_FILE" == */emergency/* ]]; then RESTORE_TYPE="emergency"
            fi
        fi
        [[ -n "$RESTORE_TYPE" ]] || {
            log_error "Cannot determine backup type — specify --type db|full|emergency"
            return 1
        }
        return 0
    fi

    log_error "No backup specified. Use --file FILE or --latest."
    return 1
}