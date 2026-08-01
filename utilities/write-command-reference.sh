#!/usr/bin/env bash
# utilities/write-command-reference.sh — Writes docs/COMMAND-REFERENCE.md
# from live Makefile targets and script help output.
#
# The script writes the generated Markdown through a temporary file and then
# atomically replaces docs/COMMAND-REFERENCE.md. This avoids hand-patching the
# generated file and keeps CI doc-drift checks deterministic.
#
# Root / sudo safety
# ------------------
# When run as root (e.g. `sudo make docs`) the output file would end up owned
# by root:root, causing "Permission denied" on the next non-root invocation.
# After the atomic mv we detect the real invoking user via SUDO_USER (set by
# sudo) and chown the file back.  When not running under sudo this is a no-op.

set -euo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
    for bash5 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$bash5" ]]; then
            exec "$bash5" "$0" "$@"
        fi
    done
fi
PATH="$(dirname "$BASH"):$PATH"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/docs/COMMAND-REFERENCE.md"

show_help() {
    cat <<'HELP'
VaultWarden-OCI Command Reference Writer

USAGE:
    bash utilities/write-command-reference.sh [--help|-h]
    bash utilities/generate-command-ref.sh
    make docs

DESCRIPTION:
    Rebuilds docs/COMMAND-REFERENCE.md from Makefile targets and script help
    output. The file is generated from scratch each time so CI can detect real
    doc drift without carrying over stale or malformed content.

OPTIONS:
    --help, -h      Show this help without rewriting docs
    --version, -V   Print the VaultWarden-OCI version and exit
HELP
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h|help)
            show_help
            exit 0
            ;;
        --version|-V)
            printf 'VaultWarden-OCI %s\n' "$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 2
            ;;
    esac
fi

# ── Makefile targets ─────────────────────────────────────────────────────────
generate_makefile_targets() {
    printf '## Makefile Targets\n\n'
    printf '| Target | Description |\n'
    printf '|--------|-------------|\n'
    awk -F ':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "| `make %s` | %s |\n", $1, $2 }' \
        "${SCRIPT_DIR}/Makefile"
    printf '\n'
}

# ── Script help output ──────────────────────────────────────────────────────
sanitize_help_output() {
    # Keep generated docs deterministic across runs and environments:
    #
    # 1. docker.sh diagnostic — scripts that source lib/docker.sh emit a
    #    "docker.sh: could not auto-detect Compose project name" line to
    #    stderr (captured via 2>&1).  Strip the whole line so it never
    #    appears in the generated reference.
    #
    # 2. Bracketed wall-clock timestamps  [HH:MM:SS]  →  [HH:MM:SS] literal
    #    (already normalised by the placeholder substitution below).
    #
    # 3. ISO-8601 datetime stamps  2026-05-28T14:32:01Z  →  TIMESTAMP
    #
    # 4. Bare date stamps  2026-05-28  that may appear in log sample lines.
    #    Only replaced when surrounded by word boundaries to avoid mangling
    #    version strings like "1.32.0".
    #
    # 5. ANSI escape sequences (colour / cursor codes).
    #
    # 6. NUL bytes — written as the \x00 escape so this source file never
    #    contains literal NUL characters.
    #
    # Cap at 180 lines so expanded operator help remains complete while no single script can inflate the reference file.
    head -180 \
        | sed \
            -e '/^docker\.sh:.*auto-detect/d' \
            -e '/^lib\/docker\.sh:.*auto-detect/d' \
            -e 's|/[^[:space:]]*/utilities/notify-failure\.sh|utilities/notify-failure.sh|g' \
            -e 's/Called automatically by setup\.sh phase 1\./Called automatically by setup.sh during phase 1./g' \
            -e 's/\[[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\]/[HH:MM:SS]/g' \
            -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\([+-][0-9]\{4\}\|Z\)/TIMESTAMP/g' \
            -e 's/\b[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\b/DATE/g' \
            -e 's/\x1b\[[0-9;]*[mKHF]//g' \
        | perl -pe 's/\x00//g'
}

run_help_command() {
    local script="$1"
    shift

    local raw_out rc tmp_state
    tmp_state=$(mktemp -d)
    set +e
    if command -v timeout >/dev/null 2>&1; then
        raw_out="$(PROJECT_STATE_DIR="$tmp_state" timeout 5 bash "$script" "$@" 2>&1)"
    else
        raw_out="$(PROJECT_STATE_DIR="$tmp_state" bash "$script" "$@" 2>&1)"
    fi
    rc=$?
    set -e
    rm -rf "$tmp_state"

    HELP_COMMAND_OUTPUT="$(printf '%s\n' "$raw_out" | sanitize_help_output)"
    return "$rc"
}

generate_script_help() {
    local script="$1"
    local name
    name="$(basename "$script")"

    echo "### ${name}"
    echo ""
    echo '```'
    if [[ "$name" == "notify-failure.sh" ]]; then
        echo '(internal systemd OnFailure helper; not a direct operator command)'
        echo '```'
        echo ""
        return 0
    fi
    # Try --help first; if that fails (non-zero exit or empty output), fall back
    # to the 'help' subcommand used by subcommand-driven scripts. Capture the
    # command status before truncating output so a successful help page longer
    # than 60 lines is not mistaken for a failure due to SIGPIPE.
    local help_out=""
    if run_help_command "$script" --help && [[ -n "$HELP_COMMAND_OUTPUT" ]]; then
        help_out="$HELP_COMMAND_OUTPUT"
    elif run_help_command "$script" help && [[ -n "$HELP_COMMAND_OUTPUT" ]]; then
        help_out="$HELP_COMMAND_OUTPUT"
    fi

    if [[ -n "$help_out" ]]; then
        printf '%s\n' "$help_out"
    else
        echo '(--help not available or requires root)'
    fi
    echo '```'
    echo ""
}

write_command_reference() {
    cat <<'HEADER'
<!-- AUTO-GENERATED by utilities/write-command-reference.sh — DO NOT EDIT -->
<!-- Regenerate: make docs -->

# Command Reference

This document is auto-generated from the Makefile and script `--help`
output. Do not edit manually; run `make docs` to regenerate.

---

HEADER

    generate_makefile_targets

    echo '---'
    echo ''
    echo '## Entry-Point Scripts'
    echo ''

    # Root-level entry points
    for script in \
        "${SCRIPT_DIR}/setup.sh" \
        "${SCRIPT_DIR}/startup.sh" \
        "${SCRIPT_DIR}/backup.sh" \
        "${SCRIPT_DIR}/restore.sh" \
        "${SCRIPT_DIR}/maintenance.sh" \
        "${SCRIPT_DIR}/edit-secrets.sh" \
        "${SCRIPT_DIR}/dashboard.sh" \
        "${SCRIPT_DIR}/recover.sh"; do
        [[ -f "$script" ]] && generate_script_help "$script"
    done

    echo '## Utility Scripts'
    echo ''

    # Utility entry points (sorted for deterministic output)
    while IFS= read -r script; do
        [[ -f "$script" ]] && generate_script_help "$script"
    done < <(find "${SCRIPT_DIR}/utilities" -maxdepth 1 -name '*.sh' -type f \
        | grep -v 'notify-failure\.sh' \
        | sort)
}

tmp_file="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

write_command_reference > "$tmp_file"

# Keep the generated Markdown clean for git diff --check.
perl -0pi -e 's/\n+\z/\n/' "$tmp_file"

chmod 0644 "$tmp_file"
mv "$tmp_file" "$OUTPUT_FILE"
trap - EXIT

# ── Root / sudo ownership fix ────────────────────────────────────────────────
# If this script was invoked via sudo, the output file is now owned by root.
# Chown it back to the real invoking user so the next non-root `make docs`
# run (and git operations) are not blocked by a permission error.
if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    real_uid="$(id -u "${SUDO_USER}")"
    real_gid="$(id -g "${SUDO_USER}")"
    chown "${real_uid}:${real_gid}" "${OUTPUT_FILE}"
    echo "Ownership restored to ${SUDO_USER} (uid=${real_uid} gid=${real_gid})"
fi

echo "Generated: $OUTPUT_FILE"
