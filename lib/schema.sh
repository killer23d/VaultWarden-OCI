#!/usr/bin/env bash
# lib/schema.sh — Schema-driven secrets helpers for VaultWarden-OCI.
#
# Provides yq-based readers for secrets-schema.yaml so that no script
# needs to hardcode the set of secret keys.
#
# Depends on:
#   lib/log.sh   — must be sourced before this file
#   yq (v4+)     — YAML processor; installed by setup.sh as a prerequisite
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/schema.sh"
#
# All functions accept an optional trailing SCHEMA_FILE argument.
# When omitted, SECRETS_SCHEMA_FILE is used (default: PROJECT_ROOT/secrets-schema.yaml).

[[ -n "${_VW_SCHEMA_LIB_LOADED:-}" ]] && return 0
readonly _VW_SCHEMA_LIB_LOADED=1

# Resolve LIB_DIR and PROJECT_ROOT relative to this file so the library can be
# sourced from any working directory.
_SCHEMA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCHEMA_PROJECT_ROOT="$(cd "${_SCHEMA_LIB_DIR}/.." && pwd)"

# Default schema file path; callers may override by setting SECRETS_SCHEMA_FILE
# before sourcing this library, or by passing a path as the last argument to
# any helper function.
SECRETS_SCHEMA_FILE="${SECRETS_SCHEMA_FILE:-${_SCHEMA_PROJECT_ROOT}/secrets-schema.yaml}"

# ---------------------------------------------------------------------------
# _schema_check_prerequisites
#
# Internal guard: verifies yq is installed and the schema file exists.
# Called at the top of every public function.
# ---------------------------------------------------------------------------
_schema_check_prerequisites() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"

    if ! command -v yq > /dev/null 2>&1; then
        log_error "schema.sh: 'yq' is not installed. Install it with: sudo snap install yq"
        log_error "schema.sh: yq is required to read secrets-schema.yaml"
        return 1
    fi

    if [[ ! -f "${schema_file}" ]]; then
        log_error "schema.sh: schema file not found: ${schema_file}"
        log_error "schema.sh: Expected at: ${SECRETS_SCHEMA_FILE}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# schema_keys [SCHEMA_FILE]
#
# Prints all secret key names to stdout, one per line, in schema order.
#
# Example:
#   while IFS= read -r key; do ...; done < <(schema_keys)
# ---------------------------------------------------------------------------
schema_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq '.secrets[].key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_field KEY FIELD [SCHEMA_FILE]
#
# Prints the value of FIELD for the given KEY.
# Returns 1 and emits an error if the key does not exist in the schema.
#
# Example:
#   hint=$(schema_field admin_token hint)
#   services=$(schema_field caddy_cloudflare_dns_token services)
# ---------------------------------------------------------------------------
schema_field() {
    local key="$1"
    local field="$2"
    local schema_file="${3:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local value
    # Use yq select to locate the entry with the matching key, then read the field.
    value=$(yq ".secrets[] | select(.key == \"${key}\") | .${field}" "$schema_file") || {
        log_error "schema_field: failed to read field '${field}' for key '${key}'"
        return 1
    }

    # yq returns "null" for missing keys/fields.
    if [[ "$value" == "null" ]]; then
        log_error "schema_field: key '${key}' or field '${field}' not found in schema: ${schema_file}"
        return 1
    fi

    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# schema_field_safe KEY FIELD [SCHEMA_FILE]
#
# Like schema_field but returns an empty string (instead of an error) when
# the field value is null or the key is not present.  Use for optional fields
# such as `hint` and `auto_fn` where absence is expected.
# ---------------------------------------------------------------------------
schema_field_safe() {
    local key="$1"
    local field="$2"
    local schema_file="${3:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local value
    value=$(yq ".secrets[] | select(.key == \"${key}\") | .${field}" "$schema_file" 2>/dev/null) || true
    [[ "$value" == "null" ]] && value=""
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# schema_required_keys [SCHEMA_FILE]
#
# Prints keys where required=true, one per line, in schema order.
# Used by check_placeholder_values() in lib/secrets.sh.
# ---------------------------------------------------------------------------
schema_required_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq '.secrets[] | select(.required == true) | .key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_hinted_keys [SCHEMA_FILE]
#
# Prints keys where hint is a non-empty string, one per line, in schema order.
# Used by secrets-edit.sh to inject inline YAML comments.
# ---------------------------------------------------------------------------
schema_hinted_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq '.secrets[] | select(.hint != "" and .hint != null) | .key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_services_for_key KEY [SCHEMA_FILE]
#
# Prints the space-separated list of Docker Compose service names for KEY.
# Used by secrets-rotate.sh to build the restart hint.
#
# Example:
#   services=$(schema_services_for_key cloudflare_zone_id)
#   # → "caddy crowdsec-cloudflare-worker-bouncer"
# ---------------------------------------------------------------------------
schema_services_for_key() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    # Read the services list as a newline-separated sequence, then join with spaces.
    local services_nl
    services_nl=$(yq ".secrets[] | select(.key == \"${key}\") | .services[]" "$schema_file" 2>/dev/null) || true
    if [[ -z "$services_nl" || "$services_nl" == "null" ]]; then
        printf ''
        return 0
    fi
    # Convert newlines to spaces for the existing restart-hint code.
    printf '%s' "${services_nl//$'\n'/ }"
}

# ---------------------------------------------------------------------------
# schema_placeholder_for_key KEY [SCHEMA_FILE]
#
# Prints the placeholder string for KEY.
# Convenience wrapper around schema_field for the most common field access
# in the bootstrap path.
# ---------------------------------------------------------------------------
schema_placeholder_for_key() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    schema_field "$key" "placeholder" "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_key_exists KEY [SCHEMA_FILE]
#
# Returns 0 if KEY is defined in the schema, 1 otherwise.
# Used by secrets-rotate.sh to validate the field argument.
# ---------------------------------------------------------------------------
schema_key_exists() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local found
    found=$(yq ".secrets[] | select(.key == \"${key}\") | .key" "$schema_file" 2>/dev/null) || true
    [[ -n "$found" && "$found" != "null" ]]
}

# ---------------------------------------------------------------------------
# schema_collect_type KEY [SCHEMA_FILE]
#
# Prints the collect type for KEY: one of interactive | auto | conditional | skip.
# Named accessor so callers can branch cleanly without re-reading the raw field.
#
# "conditional" is a forward-declaration marker used by push notification keys.
# No schema dispatch loop interprets it automatically — the caller must handle
# it explicitly with a verbatim preserved block.
#
# Example:
#   case "$(schema_collect_type "$key")" in
#     interactive) ... ;;
#     auto)        ... ;;
#     conditional) ... ;;  # verbatim block below
#     skip)        continue ;;
#   esac
# ---------------------------------------------------------------------------
schema_collect_type() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    schema_field_safe "$key" "collect" "$schema_file"
}

export -f _schema_check_prerequisites
export -f schema_keys schema_field schema_field_safe
export -f schema_required_keys schema_hinted_keys
export -f schema_services_for_key schema_placeholder_for_key
export -f schema_key_exists schema_collect_type

log_debug "Schema library loaded (schema: ${SECRETS_SCHEMA_FILE})"
