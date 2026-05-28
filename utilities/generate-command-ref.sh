#!/usr/bin/env bash
# utilities/generate-command-ref.sh — compatibility wrapper for the command
# reference writer used by CI and `make docs`.
#
# This is intentionally a thin shim.  All generation logic lives in
# write-command-reference.sh so there is a single source of truth.
#
# Root / sudo safety
# ------------------
# If invoked with sudo the generated docs/COMMAND-REFERENCE.md would end up
# owned by root, breaking the next non-root `make docs` run.  The real fix
# lives in write-command-reference.sh (which does its own chown), but we
# guard here too so the wrapper is independently safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/..") && pwd)"
# shellcheck disable=SC2164
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec bash "${SCRIPT_DIR}/utilities/write-command-reference.sh" "$@"
