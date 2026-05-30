#!/usr/bin/env bash
# utilities/setup-crowdsec.sh
#
# Render the CrowdSec Cloudflare Worker bouncer config from the template.
# Reads all values from .env and the CrowdSec LAPI, then writes the live
# config to /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml.
#
# Usage:
#   sudo ./utilities/setup-crowdsec.sh [--force] [--dry-run] [--help]
#
# Options:
#   --force    Overwrite the live config even if it already exists.
#   --dry-run  Print the rendered config without writing it.
#   --help     Show this help.
#
# Prerequisites:
#   - .env exists and contains: DOMAIN_NAME, CLOUDFLARE_ZONE_ID,
#     CF_ACCOUNT_ID, CF_ACCOUNT_NAME
#   - The CF_WORKER_BOUNCER_TOKEN secret must already be set via
#     ./edit-secrets.sh (stored in secrets/.docker_secrets/cf_worker_bouncer_token
#     or exported as CF_WORKER_BOUNCER_TOKEN in the environment).
#   - crowdsec is installed and running (for LAPI key generation).
#
# Idempotent: safe to re-run.  Without --force, skips rendering if the
# live config already exists and contains a real LAPI key (non-placeholder).
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
_info()    { printf "${CYAN}[INFO]${NC}  %s\n"    "$*"; }
_success() { printf "${GREEN}[OK]${NC}    %s\n"    "$*"; }
_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n"   "$*" >&2; }
_error()   { printf "${RED}[ERROR]${NC} %s\n"   "$*" >&2; }
_die()     { _error "$*"; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
FORCE=false
DRY_RUN=false

TEMPLATE="${PROJECT_ROOT}/crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example"
DEST="/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
ENV_FILE="${PROJECT_ROOT}/.env"
DOCKER_SECRETS_DIR="${PROJECT_ROOT}/secrets/.docker_secrets"

# ── Argument parsing ──────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
Usage: sudo ./utilities/setup-crowdsec.sh [OPTIONS]

Renders the CrowdSec Cloudflare Worker bouncer config from the template at:
  ${TEMPLATE}
and writes the live config to:
  ${DEST}

Options:
  --force    Overwrite the live config even if it already exists.
  --dry-run  Print the rendered config to stdout without writing.
  --help     Show this help and exit.

All values are read from ${ENV_FILE} and
the CrowdSec LAPI. The CF_WORKER_BOUNCER_TOKEN is read from:
  ${DOCKER_SECRETS_DIR}/cf_worker_bouncer_token
or from the CF_WORKER_BOUNCER_TOKEN environment variable.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)    FORCE=true;   shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)  show_help; exit 0 ;;
        *) _die "Unknown option: $1  (use --help for usage)" ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 && "$DRY_RUN" != "true" ]]; then
    _die "This script must be run as root (or with sudo) when writing to ${DEST}."
fi

# ── Validate template ─────────────────────────────────────────────────────────
[[ -f "$TEMPLATE" ]] || _die "Template not found: ${TEMPLATE}\nRun from the VaultWarden-OCI repository root."

# ── Helper: read a key from .env ──────────────────────────────────────────────
_read_env() {
    local key="$1" file="${2:-${ENV_FILE}}"
    [[ -f "$file" ]] || { echo ""; return 0; }
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'" || true
}

# ── Load .env values ──────────────────────────────────────────────────────────
_info "Reading configuration from ${ENV_FILE} ..."

DOMAIN_NAME="$(_read_env DOMAIN_NAME)"
CLOUDFLARE_ZONE_ID="$(_read_env CLOUDFLARE_ZONE_ID)"
CF_ACCOUNT_ID="$(_read_env CF_ACCOUNT_ID)"
CF_ACCOUNT_NAME="$(_read_env CF_ACCOUNT_NAME)"
CF_FREE_PLAN="$(_read_env CF_FREE_PLAN)"
CF_FREE_PLAN="${CF_FREE_PLAN:-true}"

# Validate required .env values
for var in DOMAIN_NAME CLOUDFLARE_ZONE_ID CF_ACCOUNT_ID CF_ACCOUNT_NAME; do
    val="${!var:-}"
    if [[ -z "$val" || "$val" == *CHANGE_ME* || "$val" == *your_* || "$val" == *example* ]]; then
        _die "${var} is missing or is still a placeholder in ${ENV_FILE}.\nSet it to a real value and re-run."
    fi
done

# ── Derive the Worker route wildcard ──────────────────────────────────────────
# Bouncer v0.9.0+ requires at least one explicit route; empty = no routes bound.
# We derive *DOMAIN_NAME/* so the Worker intercepts every request in the zone.
WORKER_ROUTE="*${DOMAIN_NAME}/*"
_info "Worker route: ${WORKER_ROUTE}"

# ── Read CF_WORKER_BOUNCER_TOKEN ──────────────────────────────────────────────
CF_WORKER_BOUNCER_TOKEN="${CF_WORKER_BOUNCER_TOKEN:-}"

# Prefer the decrypted docker-secret file if it exists
if [[ -z "$CF_WORKER_BOUNCER_TOKEN" ]]; then
    SECRET_FILE="${DOCKER_SECRETS_DIR}/cf_worker_bouncer_token"
    if [[ -f "$SECRET_FILE" && -s "$SECRET_FILE" ]]; then
        CF_WORKER_BOUNCER_TOKEN=$(cat "$SECRET_FILE")
        _info "CF_WORKER_BOUNCER_TOKEN read from ${SECRET_FILE}"
    fi
fi

# Fall back to asking the user if still empty
if [[ -z "$CF_WORKER_BOUNCER_TOKEN" || "$CF_WORKER_BOUNCER_TOKEN" == *CHANGE_ME* ]]; then
    _warn "CF_WORKER_BOUNCER_TOKEN not found in secrets or environment."
    _warn "Set it with: ./edit-secrets.sh --rotate cf_worker_bouncer_token"
    _warn "Then re-run this script."
    if [[ "$DRY_RUN" == "true" ]]; then
        CF_WORKER_BOUNCER_TOKEN="CHANGE_ME_CF_WORKER_BOUNCER_TOKEN"
        _warn "Dry-run: using placeholder for CF_WORKER_BOUNCER_TOKEN"
    else
        _die "CF_WORKER_BOUNCER_TOKEN is required to write the live config."
    fi
fi

# ── Generate or retrieve the CrowdSec LAPI key ────────────────────────────────
# cscli bouncers add is idempotent — it errors if the name already exists,
# so we check first and reuse the existing key when possible.
BOUNCER_NAME="cloudflare-worker-bouncer"
CROWDSEC_LAPI_KEY=""

if command -v cscli &>/dev/null; then
    # Check if the bouncer is already registered
    if cscli bouncers list -o json 2>/dev/null | grep -q "\"${BOUNCER_NAME}\""; then
        _info "CrowdSec bouncer '${BOUNCER_NAME}' already registered."
        # Try to read the key from the existing live config if present
        if [[ -f "$DEST" ]]; then
            CROWDSEC_LAPI_KEY=$(grep -E '^\s*lapi_key:' "$DEST" 2>/dev/null \
                | awk '{print $2}' | tr -d "'\"" || true)
            if [[ -n "$CROWDSEC_LAPI_KEY" && "$CROWDSEC_LAPI_KEY" != %%* ]]; then
                _info "Reusing existing LAPI key from live config."
            else
                CROWDSEC_LAPI_KEY=""
            fi
        fi
        if [[ -z "$CROWDSEC_LAPI_KEY" ]]; then
            _warn "Could not read existing LAPI key. Deleting and re-creating bouncer registration."
            cscli bouncers delete "$BOUNCER_NAME" 2>/dev/null || true
            CROWDSEC_LAPI_KEY=$(cscli bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null || true)
        fi
    else
        _info "Registering CrowdSec bouncer '${BOUNCER_NAME}' ..."
        CROWDSEC_LAPI_KEY=$(cscli bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null || true)
    fi
fi

if [[ -z "$CROWDSEC_LAPI_KEY" ]]; then
    _warn "Could not generate a CrowdSec LAPI key (is crowdsec running?)"
    if [[ "$DRY_RUN" == "true" ]]; then
        CROWDSEC_LAPI_KEY="CHANGE_ME_CROWDSEC_LAPI_KEY"
        _warn "Dry-run: using placeholder for CROWDSEC_LAPI_KEY"
    else
        _die "CROWDSEC_LAPI_KEY is required. Ensure crowdsec is running:\n  sudo systemctl status crowdsec"
    fi
fi

# ── Idempotency check ─────────────────────────────────────────────────────────
if [[ -f "$DEST" && "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    existing_key=$(grep -E '^\s*lapi_key:' "$DEST" 2>/dev/null \
        | awk '{print $2}' | tr -d "'\"" || true)
    if [[ -n "$existing_key" && "$existing_key" != %%* && "$existing_key" != CHANGE_ME* ]]; then
        _success "Live config already exists at ${DEST} with a real LAPI key."
        _info    "Use --force to overwrite."
        exit 0
    fi
fi

# ── Apply free-plan only_include_decisions_from guard ────────────────────────
# Free plan: restrict to local decisions only to avoid exhausting KV quota.
# Paid plan (CF_FREE_PLAN=false): allow all decision sources.
if [[ "$CF_FREE_PLAN" == "false" ]]; then
    ONLY_INCLUDE='[]'
else
    ONLY_INCLUDE='["cscli", "crowdsec"]'
fi

# ── Render ────────────────────────────────────────────────────────────────────
_info "Rendering config template ..."

rendered=$(sed \
    -e "s|%%CLOUDFLARE_ZONE_ID%%|${CLOUDFLARE_ZONE_ID}|g" \
    -e "s|%%CF_ACCOUNT_ID%%|${CF_ACCOUNT_ID}|g" \
    -e "s|%%CF_WORKER_BOUNCER_TOKEN%%|${CF_WORKER_BOUNCER_TOKEN}|g" \
    -e "s|%%CROWDSEC_LAPI_KEY%%|${CROWDSEC_LAPI_KEY}|g" \
    -e "s|%%CF_ACCOUNT_NAME%%|${CF_ACCOUNT_NAME}|g" \
    -e "s|only_include_decisions_from: \[\]|only_include_decisions_from: ${ONLY_INCLUDE}|g" \
    -e "s|routes_to_protect: \[\]|routes_to_protect:\n          - \"${WORKER_ROUTE}\"|g" \
    "$TEMPLATE")

# ── Output or write ───────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    _info "=== DRY RUN — rendered config (not written) ==="
    echo "$rendered"
    exit 0
fi

# Write atomically
TMP=$(mktemp /tmp/cs-cf-bouncer.XXXXXXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$rendered" > "$TMP"
chmod 600 "$TMP"

# Ensure destination directory exists
install -d -m 755 "$(dirname "$DEST")"

mv "$TMP" "$DEST"
chmod 600 "$DEST"

_success "Live config written to ${DEST}"

# ── Restart the bouncer ───────────────────────────────────────────────────────
if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer 2>/dev/null \
   || systemctl is-enabled --quiet crowdsec-cloudflare-worker-bouncer 2>/dev/null; then
    _info "Restarting crowdsec-cloudflare-worker-bouncer ..."
    # Clean shutdown: the bouncer removes the Worker on stop and recreates on start.
    systemctl restart crowdsec-cloudflare-worker-bouncer
    _success "crowdsec-cloudflare-worker-bouncer restarted."
    _info    "Watch logs: sudo journalctl -u crowdsec-cloudflare-worker-bouncer -f"
else
    _info "crowdsec-cloudflare-worker-bouncer is not enabled yet."
    _info "Enable it with:"
    _info "  sudo systemctl enable --now crowdsec-cloudflare-worker-bouncer"
fi

# ── Reminder about metrics warning ───────────────────────────────────────────
cat <<'NOTE'

NOTE: The bouncer will emit this warning every ~15 minutes:
  level=warning msg="failed to send metrics: 200 OK"

This is a known upstream cosmetic bug — HTTP 200 (success) is misclassified
as an error by the metrics sender. It does NOT affect IP blocking.
Track the fix: https://github.com/crowdsecurity/cs-cloudflare-worker-bouncer
NOTE
