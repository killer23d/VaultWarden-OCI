#!/usr/bin/env bash
# lib/defaults.sh — Canonical default paths for VaultWarden-OCI.
#
# Source this file to get the single-source-of-truth defaults for
# PROJECT_STATE_DIR and DATA_VOLUME_MOUNT. Individual scripts should
# reference these constants instead of inline "${VAR:-/some/path}" fallbacks.
#
# Load order: This file has no dependencies and may be sourced at any point.

[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] && return 0
readonly VAULTWARDEN_DEFAULTS_LOADED=1

# Canonical default paths — use these instead of inline fallbacks
readonly _VW_DEFAULT_STATE_DIR="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
readonly _VW_DEFAULT_DATA_MOUNT="${_VW_DEFAULT_DATA_MOUNT:-/opt/vaultwarden/data}"
