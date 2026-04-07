#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
# Supports local and rclone remote backup selection.
# After restore: prompts for the decryption key, restores data, then
# generates/rotates a fresh age key and displays it like a new setup.
#
# PATCHED BUGS:
#   BUG-R1 [HIGH]  Every backup search path was hardcoded as
#                  $PROJECT_ROOT/backups/<type>/.  backup.sh stores backups
#                  at get_config_value("BACKUP_DIR",
#                  "/var/lib/vaultwarden/backups") — under /var/ on a
#                  standard install.  The mismatch caused --list to always
#                  show "(none)", --latest to always fail, and the interactive
#                  menu to be empty.
#                  Fix: derive BACKUP_BASE_DIR from .env using the same key
#                  ("BACKUP_DIR") and default that backup.sh uses, and replace
#                  every $PROJECT_ROOT/backups reference with $BACKUP_BASE_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
_source_lib "lib/backup_utils.sh"
_source_lib "lib/crypto.sh"
_source_lib "lib/simple_key_resilience.sh"
unset -f _source_lib

# ---------------------------------------------------------------------------
# Dependency pre-flight
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local required_cmds=(docker age sops sqlite3 sha256sum)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: restore.sh: the following required tools are not installed:" >&2
        for cmd in "${missing[@]}"; do
            echo "         - $cmd" >&2
        done
        echo "       Install the missing tools before running a restore." >&2
        exit 1
    fi
}
check_dependencies

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
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
KEY_FILE_ARG=""   # set by --key-file; path to age private key for this restore

# BUG-R1 FIX: declared here (empty) so set -u never fires before main()
# initialises it via get_config_value().  Every function that references
# BACKUP_BASE_DIR is only called after main() has set it.
BACKUP_BASE_DIR=""

# Issue: session-scoped rclone remote name / path for emergency restores.
# When .env is absent (fresh server), _prompt_rclone_remote_name() fills
# these; they are used in place of the .env values for this run only and
# are never written back to disk.
_SESSION_RCLONE_REMOTE_NAME=""
_SESSION_RCLONE_REMOTE_PATH=""

# Set by _rclone_is_available() when rclone binary + config are present but
# RCLONE_REMOTE_NAME is missing — signals that an interactive prompt is
# needed rather than a hard failure.
RCLONE_NEEDS_INTERACTIVE_NAME=false
