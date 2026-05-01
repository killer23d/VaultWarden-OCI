#!/usr/bin/env bash
# restore.sh - VaultWarden-OCI safe restore
# Supports local and rclone remote backup selection.
# After restore: prompts for the decryption key, restores data, then
# generates/rotates a fresh age key and displays it like a new setup.
# Requires root for most operations (exception: --list).
# Run from the VaultWarden-OCI project root.
#
# Usage:
#   sudo ./restore.sh                 # interactive menu (local + remote)
#   sudo ./restore.sh --remote        # remote-only interactive menu
#   ./restore.sh --list               # list available backups (no root)
#   sudo ./restore.sh --latest --type db --force
#   sudo ./restore.sh --file <path>
#   sudo ./restore.sh --latest --from-recovery-kit /mnt/usb/recovery-kit.txt
