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
#
#   BUG-R2 [HIGH]  No pre-flight dependency check before beginning a restore
#                  operation.  On a fresh disaster-recovery host any missing
#                  binary (age, docker, sha256sum, sqlite3, tar) would cause
#                  the script to abort mid-restore, potentially leaving the
#                  stack in a partial state.
#                  Fix: added check_restore_dependencies() called at the top
#                  of main(), before any locks or file operations, using the
#                  existing require_commands() helper already exported by
#                  lib/common.sh.  rclone is checked separately only when
#                  --remote is active, because it is optional.
#
#   BUG-R3 [MED]   When the .sha256 sidecar file is absent (e.g. a backup
#                  produced by an older version of backup.sh), the encrypted
#                  archive's integrity was silently skipped with a log_warn
#                  and processing continued.  A truncated or zero-byte
#                  download would not be detected until age -d failed, by
#                  which point TMPDIR_RESTORE had been created and temp space
#                  consumed.
#                  Fix: added verify_archive_file() called from the existing
#                  Step 3 block.  When no .sha256 sidecar is present it
#                  verifies that the archive file is non-empty and carries a
#                  valid age envelope header (magic bytes "age-encryption.org"
#                  in the first 512 bytes).  This catches zero-byte files and
#                  truncated downloads before any decryption attempt.
