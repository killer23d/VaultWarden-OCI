#!/usr/bin/env bash
# lib/defaults.sh — Canonical compile-time defaults for VaultWarden-OCI.
#
# Source this file to get single-source-of-truth defaults for paths, IDs,
# and service names. Individual scripts MUST reference these constants
# instead of inline "${VAR:-/some/path}" or magic-number fallbacks.
#
# Rules:
#   • Every constant uses ${VAR:-value} so the caller's environment wins.
#   • Add a constant here whenever a value appears in more than one script.
#   • This file has no dependencies and may be sourced at any point.
#
# Load order: none — source before all other lib/ files.

[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DEFAULTS_LOADED=1

# ---------------------------------------------------------------------------
# Filesystem paths
# ---------------------------------------------------------------------------
readonly _VW_DEFAULT_STATE_DIR="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
readonly _VW_DEFAULT_DATA_MOUNT="${_VW_DEFAULT_DATA_MOUNT:-/opt/vaultwarden/data}"

# ---------------------------------------------------------------------------
# Service user identity
# Used as the fallback when PUID / PGID are absent from .env.
# Change here and the correct UID:GID is applied everywhere in one edit.
# ---------------------------------------------------------------------------
readonly _VW_DEFAULT_PUID="${_VW_DEFAULT_PUID:-1001}"
readonly _VW_DEFAULT_PGID="${_VW_DEFAULT_PGID:-1001}"

# ---------------------------------------------------------------------------
# Log subdirectory names
# Drives mkdir in prepare_log_directories() and any future log-rotation
# helpers. Add a new service name here when a new container is introduced.
# ---------------------------------------------------------------------------
_VW_DEFAULT_LOG_SERVICES=(vaultwarden caddy postfix)
readonly _VW_DEFAULT_LOG_SERVICES
