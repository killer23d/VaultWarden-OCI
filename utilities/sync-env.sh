#!/usr/bin/env bash
# utilities/sync-env.sh — Compatibility shim; delegates to env-edit.sh sync.
# Use utilities/env-edit.sh directly for new call sites.
exec "${BASH_SOURCE%/*}/env-edit.sh" sync "$@"
