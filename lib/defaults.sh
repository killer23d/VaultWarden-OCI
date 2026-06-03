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
# lib/defaults.sh (excerpt — add the three new arrays immediately after the existing block)

readonly _VW_DEFAULT_PUID="${_VW_DEFAULT_PUID:-1001}"
readonly _VW_DEFAULT_PGID="${_VW_DEFAULT_PGID:-1001}"

# Service log subdirectories created under PROJECT_STATE_DIR/logs/
# startup.sh iterates this array — add new sidecars here only.
readonly -a _VW_DEFAULT_LOG_SERVICES=(
    vaultwarden
    caddy
    postfix
)

# Critical services that startup.sh waits on after `docker compose up`.
# Add a new sidecar here when the compose stack grows.
readonly -a _VW_DEFAULT_CRITICAL_SERVICES=(
    vaultwarden
    caddy
)

# Valid values for the EMAIL_MODE .env variable.
# startup.sh derives the catch-all advisory string from this array at runtime.
readonly -a _VW_DEFAULT_EMAIL_MODES=(
    auto
    api
    smtp
    host
)

# System commands required before startup.sh can proceed.
# Add a new tool dependency here — no edit to startup.sh needed.
readonly -a _VW_DEFAULT_REQUIRED_COMMANDS=(
    docker
    openssl
    sops
    python3
)
readonly _VW_DEFAULT_LOG_SERVICES
