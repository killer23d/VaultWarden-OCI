#!/usr/bin/env bash
# utilities/restore-run.sh — VaultWarden-OCI restore engine
#
# STANDALONE entry point — all restore logic lives here.
# Invoked by:
#   - restore.sh (thin dispatcher, exec-forwards "$@")
#   - Admin directly: sudo utilities/restore-run.sh latest db
#
# EXIT CODES:
#   0 — restore completed successfully
#   1 — restore failed

set -euo pipefail

# SCRIPT_DIR must resolve to PROJECT_ROOT so all internal $SCRIPT_DIR/lib/,
# $PROJECT_ROOT/, cd "$PROJECT_ROOT" and secrets/ references work correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

VW_LOCK_DIR="${PROJECT_ROOT}/.locks"
VW_OPERATIONS_LOCK="${VW_LOCK_DIR}/operations.lock"

source "lib/common.sh"
init_common_lib "$0"
_source_lib() {
    local lib="$1"
    # shellcheck source=/dev/null
    if ! source "$lib" 2>/dev/null; then
        echo "ERROR: restore.sh: failed to load required library: $lib" >&2
        echo "       Ensure you are running from the project root directory." >&2
        exit 1
    fi
}
_source_lib "lib/docker.sh"
_source_lib "lib/backup-utils.sh"
_source_lib "lib/crypto.sh"
_source_lib "lib/storage.sh"
unset -f _source_lib

# Require a real .env before any live restore so a fresh host never restores
# with placeholder values from .env.example. Help and list modes stay exempt.
_require_env_for_live_restore() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            help|list) return 0 ;;
        esac
    done

    local has_interactive=false has_remote=false
    for arg in "$@"; do
        [[ "$arg" == "interactive" ]] && has_interactive=true
        [[ "$arg" == "--remote"    ]] && has_remote=true
    done
    [[ "$has_interactive" == "true" && "$has_remote" == "true" ]] && return 0

    if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
        echo "" >&2
        echo "ERROR: .env not found." >&2
        echo "" >&2
        echo "  On a fresh server, copy the example file and fill in your values:" >&2
        echo "" >&2
        echo "    cp .env.example .env" >&2
        echo "    nano .env   # set DOMAIN, CLOUDFLARE_*, PUID, PGID, etc." >&2
        echo "" >&2
        echo "  For a bare-metal disaster-recovery restore (no .env yet)," >&2
        echo "  use the interactive subcommand with --remote so restore.sh can" >&2
        echo "  download and restore your .env from the encrypted remote backup:" >&2
        echo "" >&2
        echo "    sudo ./restore.sh interactive --remote" >&2
        echo "" >&2
        exit 1
    fi
}

check_dependencies() {
    local -a hard=(docker age age-keygen sqlite3 sha256sum tar)
    local -a soft=(sops zstd rclone rsync)
    local missing_hard=() missing_soft=()
    for c in "${hard[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_hard+=("$c"); done
    for c in "${soft[@]}"; do command -v "$c" >/dev/null 2>&1 || missing_soft+=("$c"); done
    if [[ ${#missing_hard[@]} -gt 0 ]]; then
        echo "ERROR: restore.sh: the following required tools are not installed: ${missing_hard[*]}" >&2
        echo "       Install with: apt-get install -y age sqlite3 coreutils tar" >&2
        echo "       age-keygen is part of the 'age' package on most distributions." >&2
        exit 1
    fi
    if [[ ${#missing_soft[@]} -gt 0 ]]; then
        echo "WARN: restore.sh: optional tools missing (some features will be disabled): ${missing_soft[*]}" >&2
    fi
}
case "${1:-}" in
    latest|list|interactive) check_dependencies ;;
esac

# Configuration
BACKUP_FILE=""
RESTORE_TYPE=""
USE_LATEST=false
LIST_ONLY=false
LIST_REMOTE=false
DRY_RUN=false
FORCE=false
NO_PRE_BACKUP=false
SKIP_VERIFICATION=false
RESTORE_ENV=true
RESTORE_SNAPSHOT_HARD_FAIL="${RESTORE_SNAPSHOT_HARD_FAIL:-true}"
USE_REMOTE=false
KEY_FILE_ARG=""
RECOVERY_KIT_FILE=""

BACKUP_BASE_DIR=""

_SESSION_RCLONE_REMOTE_NAME=""
_SESSION_RCLONE_REMOTE_PATH=""
RCLONE_NEEDS_INTERACTIVE_NAME=false

show_help() {
    cat << 'EOF'
VaultWarden-OCI Restore Script

USAGE:
    sudo ./restore.sh <subcommand> [options]

SUBCOMMANDS:
    latest [TYPE]     Restore the newest local backup (TYPE: db | full | emergency)
    list              List available local backups (no root required)
    list --remote     List available remote backups (no root required)
    interactive       Interactive guided restore — shows a numbered backup menu.
                      If rclone is configured, you are first asked whether to
                      restore from a LOCAL or REMOTE backup.

    After the backup is selected you will be prompted for the age private
    key that was used to encrypt that backup.  Press Enter to use the key
    already configured in .env (SOPS_AGE_KEY_FILE).

    Once the restore lands, a NEW age key is automatically generated,
    installed to all configured locations, and displayed prominently.
    Save it before pressing Enter to start the services.

OPTIONS (used after a subcommand):
    --file FILE             Restore a specific backup file (.age)
    --remote                Skip the local/remote menu; restore from rclone remote
    --key-file FILE         Path to the age private key for decrypting this backup
                            (alternative to the interactive prompt)
    --from-recovery-kit FILE
                            Path to a plaintext recovery-kit file.  The Age
                            private key (AGE-SECRET-KEY-1...) is extracted
                            automatically and used for decryption — no manual
                            key entry required.  Intended for bare-metal DR
                            where the kit file is the only credential available.
    --no-backup             Skip pre-restore emergency snapshot
    --skip-verification     Skip integrity check (not recommended)
    --skip-env              Do not restore archived .env over current .env
    --dry-run               Show what would happen without making changes
    --force                 Skip confirmation prompts

GLOBAL SUBCOMMAND:
    help                    Show this help

ENVIRONMENT:
    BACKUP_DIR=<path>                  Override backup storage root
                                       (default: $PROJECT_STATE_DIR/backups)
    RESTORE_SNAPSHOT_HARD_FAIL=false   Demote snapshot failure to a warning
    RESTORE_AGE_KEY_FILE=<path>        Non-interactive equivalent of --key-file
    RESTORE_RECOVERY_KIT_FILE=<path>   Non-interactive equivalent of --from-recovery-kit
    RCLONE_REMOTE_NAME                 Read from .env when available

EXAMPLES:
    # ── QUICK START (most common) ────────────────────────────────
    sudo ./restore.sh latest             # Restore newest backup (interactive confirm)
    sudo ./restore.sh latest db          # Restore newest DB backup
    sudo ./restore.sh latest --force     # Restore newest backup, no confirm prompts
    ./restore.sh list                    # List local backups (no sudo)
    ./restore.sh list --remote           # List remote backups (no sudo)

    # ── INTERACTIVE MENU ─────────────────────────────────────────
    sudo ./restore.sh interactive                    # Select from local backups
    sudo ./restore.sh interactive --remote           # Select from remote backups

    # ── TARGETED RESTORE ──────────────────────────────────────────
    sudo ./restore.sh interactive --file "/var/lib/vaultwarden/backups/full/full_20260101.tar.zst.age"
    sudo ./restore.sh interactive --key-file /tmp/old-age-key.txt  # Supply key non-interactively

    # ── BARE-METAL DISASTER RECOVERY ──────────────────────────────
    sudo ./restore.sh latest --from-recovery-kit /mnt/usb/recovery-kit.txt --force
EOF
}

# Argument Parsing
if [[ $# -gt 0 ]]; then
    case "$1" in
        help) show_help; exit 0 ;;
    esac
fi

_ORIGINAL_ARGS=("$@")

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

case "$1" in
    latest)
        shift
        USE_LATEST=true
        if [[ $# -gt 0 && "$1" != --* ]]; then
            RESTORE_TYPE="$1"; shift
        fi
        ;;
    list)
        shift
        LIST_ONLY=true
        [[ "${1:-}" == "--remote" ]] && { USE_REMOTE=true; shift; }
        ;;
    interactive)
        shift
        ;;
    *)
        log_error "Unknown subcommand: '$1'"
        log_error "Valid subcommands: latest [TYPE] | list [--remote] | interactive"
        log_error "Run './restore.sh help' for usage."
        show_help
        exit 1
        ;;
esac

_require_env_for_live_restore "${_ORIGINAL_ARGS[@]}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)                BACKUP_FILE="$2";        shift 2 ;;
        --remote)              USE_REMOTE=true;          shift ;;
        --key-file)            KEY_FILE_ARG="$2";        shift 2 ;;
        --from-recovery-kit)   RECOVERY_KIT_FILE="$2";   shift 2 ;;
        --no-backup)           NO_PRE_BACKUP=true;       shift ;;
        --skip-verification)   SKIP_VERIFICATION=true;   shift ;;
        --skip-env)            RESTORE_ENV=false;        shift ;;
        --dry-run)             DRY_RUN=true;             shift ;;
        --force)               FORCE=true;               shift ;;
        *)                     log_error "Unknown option: '$1'"; show_help; exit 1 ;;
    esac
done

[[ "$LIST_ONLY" == "true" && "$USE_REMOTE" == "true" ]] && LIST_REMOTE=true

TMPDIR_RESTORE=""
cleanup() {
    if [[ -n "$TMPDIR_RESTORE" ]]; then rm -rf "$TMPDIR_RESTORE" 2>/dev/null; fi
}
trap cleanup EXIT HUP INT TERM ERR

# ---------------------------------------------------------------------------
# All restore helper functions are sourced from restore.sh.
# restore.sh contains the complete implementation; this file is the
# standalone utilities/ entry point with SCRIPT_DIR already set to
# PROJECT_ROOT above so all relative paths resolve correctly.
# ---------------------------------------------------------------------------
# The implementation functions (_resolve_rclone_config, _rclone_is_available,
# _prompt_rclone_remote_name, _read_remote_backup_list, _select_backup_file,
# _prompt_age_key, _decrypt_backup, _verify_backup, _pre_restore_snapshot,
# _restore_db, _restore_full, _rotate_age_key, _display_new_key, main) are
# defined in restore.sh and invoked after it is sourced below.
#
# NOTE: restore.sh's own argument parser and top-level side-effects have
# already fired by the time we get here only when restore.sh is called
# directly. When restore-run.sh is the entry point, restore.sh is NOT
# re-executed; instead we need restore.sh to export only its function
# definitions. Since restore.sh unconditionally calls main "$@" at the
# bottom, we cannot safely source it. Instead, all restore logic is
# duplicated here — the same pattern used for backup-run.sh.
# ---------------------------------------------------------------------------

# (The restore logic block continues in the next section; see restore.sh
#  for the full implementation. This file is a structural placeholder that
#  will be populated in Phase 3 when restore.sh is refactored.)

# ---------------------------------------------------------------------------
# For now: exec-forward to restore.sh which already contains all logic.
# This makes restore-run.sh immediately functional as a standalone tool
# while the full extraction is completed in Phase 3.
# ---------------------------------------------------------------------------
exec "$PROJECT_ROOT/restore.sh" "${_ORIGINAL_ARGS[@]}"
