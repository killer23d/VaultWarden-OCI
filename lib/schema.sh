#!/usr/bin/env bash
# lib/schema.sh — Schema-driven secrets helpers for VaultWarden-OCI.
#
# Provides yq-based readers for secrets-schema.yaml so that no script
# needs to hardcode the set of secret keys.
#
# Depends on:
#   lib/log.sh   — must be sourced before this file
#   yq (v4+)     — Mike Farah YAML processor; installed by setup.sh as a
#                  pinned binary, not the Ubuntu python-yq package
#
# Canonical caller source block:
#   source "${LIB_DIR}/log.sh"
#   source "${LIB_DIR}/schema.sh"
#
# All functions accept an optional trailing SCHEMA_FILE argument.
# When omitted, SECRETS_SCHEMA_FILE is used (default: PROJECT_ROOT/secrets-schema.yaml).
#
# NOTE — yq raw output (-r flag):
#   mikefarah yq v4 wraps scalar string values in double-quotes by default,
#   e.g.  yq '.secrets[].key'  →  "admin_token"
#   The -r (--raw-output) flag suppresses the surrounding quotes and emits
#   bare strings, matching the behaviour of jq -r.  Every yq call in this
#   file uses -r so that callers receive unquoted values they can use
#   directly in shell case-statements, variable assignments, and jq filters.

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

_VW_SCHEMA_VALIDATED_FILE=""
_VW_SCHEMA_VALIDATED_MTIME=""

_schema_file_mtime() {
    local schema_file="$1"
    stat -c '%Y' "$schema_file" 2>/dev/null || stat -f '%m' "$schema_file" 2>/dev/null || printf '0'
}

_schema_validate_semantics() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    local schema_mtime
    schema_mtime="$(_schema_file_mtime "$schema_file")"

    if [[ "$_VW_SCHEMA_VALIDATED_FILE" == "$schema_file" && \
          "$_VW_SCHEMA_VALIDATED_MTIME" == "$schema_mtime" ]]; then
        return 0
    fi

    local validator_output validator_rc=0
    validator_output=$(python3 - "$schema_file" "${_SCHEMA_PROJECT_ROOT}/docker-compose.yml.example" 2>&1 <<'PYEOF'
import re
import sys

try:
    import yaml
except Exception as exc:
    print(f"schema validation: Python PyYAML is required: {exc}", file=sys.stderr)
    sys.exit(1)

schema_path, compose_path = sys.argv[1], sys.argv[2]

class NoDupLoader(yaml.SafeLoader):
    pass

def no_duplicate_mapping(loader, node):
    seen = {}
    for key_node, _ in node.value:
        key = loader.construct_object(key_node)
        if key in seen:
            raise ValueError(
                "duplicate key '{}' at line {} (first declared at line {})".format(
                    key, key_node.start_mark.line + 1, seen[key]
                )
            )
        seen[key] = key_node.start_mark.line + 1
    return loader.construct_mapping(node, deep=True)

NoDupLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    no_duplicate_mapping,
)

def load_yaml(path, label):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = yaml.load(handle, Loader=NoDupLoader)
    except (OSError, yaml.YAMLError, ValueError) as exc:
        raise ValueError(f"{label}: {exc}") from exc
    return value

try:
    schema = load_yaml(schema_path, "schema")
    compose = load_yaml(compose_path, "compose")
except ValueError as exc:
    print(f"schema validation: {exc}", file=sys.stderr)
    sys.exit(1)

errors = []

def err(key, field, message):
    if key:
        errors.append(f"{key}.{field}: {message}")
    else:
        errors.append(f"{field}: {message}")

if not isinstance(schema, dict):
    err("", "root", "document must be a mapping")
else:
    if schema.get("schema_version") != 1:
        err("", "schema_version", "must be integer 1")
    secrets = schema.get("secrets")
    if not isinstance(secrets, list):
        err("", "secrets", "must be a list")
        secrets = []

    compose_services = set()
    if isinstance(compose, dict) and isinstance(compose.get("services"), dict):
        compose_services = set(compose["services"].keys())
    if not compose_services:
        err("", "compose", "docker-compose.yml.example must declare services for apply target validation")

    required_fields = {
        "key", "label", "hash", "placeholder", "collect", "auto_fn",
        "apply", "required", "hint",
    }
    allowed_fields = required_fields | {"condition_fn", "conditional_group"}
    allowed_hashes = {"plain", "none", "argon2id", "bcrypt"}
    allowed_collect = {"interactive", "auto", "conditional", "skip"}
    allowed_auto_fns = {"auto_generate_secret_field"}
    allowed_condition_fns = {"condition_push_enabled"}
    allowed_apply = {"compose_restart", "systemd_restart", "crowdsec_worker_config", "none"}
    supported_systemd = {"crowdsec-cloudflare-worker-bouncer"}
    safe_key = re.compile(r"^[a-z][a-z0-9_]*$")
    safe_bash_fn = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

    seen_keys = set()
    for index, entry in enumerate(secrets, start=1):
        entry_key = "<entry-{}>".format(index)
        if not isinstance(entry, dict):
            err(entry_key, "entry", "must be a mapping")
            continue

        key = entry.get("key", entry_key)
        if not isinstance(key, str) or not key:
            err(entry_key, "key", "must be a non-empty string")
            key = entry_key
        elif not safe_key.match(key):
            err(key, "key", "must match ^[a-z][a-z0-9_]*$")
        elif key in seen_keys:
            err(key, "key", "must be unique")
        seen_keys.add(key)

        missing = sorted(required_fields - set(entry.keys()))
        for field in missing:
            err(key, field, "required field is missing")

        unknown = sorted(set(entry.keys()) - allowed_fields)
        for field in unknown:
            err(key, field, "unsupported schema field")

        for field in ("label", "placeholder", "auto_fn", "hint"):
            if field in entry and not isinstance(entry[field], str):
                err(key, field, "must be a string")

        hash_type = entry.get("hash")
        if hash_type not in allowed_hashes:
            err(key, "hash", "must be one of: " + ", ".join(sorted(allowed_hashes)))

        collect = entry.get("collect")
        if collect not in allowed_collect:
            err(key, "collect", "must be one of: " + ", ".join(sorted(allowed_collect)))

        required = entry.get("required")
        if not isinstance(required, bool):
            err(key, "required", "must be a YAML boolean")

        auto_fn = entry.get("auto_fn", "")
        if collect == "auto":
            if auto_fn not in allowed_auto_fns:
                err(key, "auto_fn", "collect=auto requires a supported auto_fn")
        elif auto_fn:
            err(key, "auto_fn", "must be empty unless collect=auto")

        condition_fn = entry.get("condition_fn", "")
        if condition_fn is not None and not isinstance(condition_fn, str):
            err(key, "condition_fn", "must be a string when present")
            condition_fn = ""
        if collect == "conditional":
            if not condition_fn:
                err(key, "condition_fn", "collect=conditional requires condition_fn")
            elif not safe_bash_fn.match(condition_fn):
                err(key, "condition_fn", "must be a safe Bash function name")
            elif condition_fn not in allowed_condition_fns:
                err(key, "condition_fn", "unsupported condition function")
        elif condition_fn:
            err(key, "condition_fn", "must be empty unless collect=conditional")

        apply = entry.get("apply")
        if not isinstance(apply, dict):
            err(key, "apply", "must be a mapping with type and targets")
            continue
        apply_type = apply.get("type")
        targets = apply.get("targets")
        if apply_type not in allowed_apply:
            err(key, "apply.type", "must be one of: " + ", ".join(sorted(allowed_apply)))
        if not isinstance(targets, list):
            err(key, "apply.targets", "must be an array")
            targets = []
        elif not all(isinstance(t, str) and t for t in targets):
            err(key, "apply.targets", "must contain non-empty strings")

        if apply_type == "compose_restart":
            if not targets:
                err(key, "apply.targets", "compose_restart requires at least one target")
            for target in targets:
                if target not in compose_services:
                    err(key, "apply.targets", f"unknown compose service '{target}'")
        elif apply_type == "systemd_restart":
            if not targets:
                err(key, "apply.targets", "systemd_restart requires at least one target")
            for target in targets:
                if target not in supported_systemd:
                    err(key, "apply.targets", f"unsupported project-managed systemd service '{target}'")
        elif apply_type == "crowdsec_worker_config":
            if targets != ["crowdsec-cloudflare-worker-bouncer"]:
                err(key, "apply.targets", "crowdsec_worker_config requires crowdsec-cloudflare-worker-bouncer")
        elif apply_type == "none":
            if targets:
                err(key, "apply.targets", "must be empty when apply.type=none")

if errors:
    for item in errors:
        print(f"schema validation: {item}", file=sys.stderr)
    sys.exit(1)
PYEOF
    ) || validator_rc=$?

    if [[ "$validator_rc" -ne 0 ]]; then
        while IFS= read -r _schema_line; do
            [[ -n "$_schema_line" ]] && log_error "$_schema_line"
        done <<< "$validator_output"
        return 1
    fi

    _VW_SCHEMA_VALIDATED_FILE="$schema_file"
    _VW_SCHEMA_VALIDATED_MTIME="$schema_mtime"
    return 0
}

# ---------------------------------------------------------------------------
# _schema_check_prerequisites
#
# Internal guard: verifies yq is installed and the schema file exists.
# Called at the top of every public function.
# ---------------------------------------------------------------------------
_schema_check_prerequisites() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"

    if ! command -v yq > /dev/null 2>&1; then
        log_error "schema.sh: 'yq' is not installed."
        log_error "schema.sh: Re-run setup so it can install the pinned Mike Farah yq binary."
        log_error "schema.sh: yq (v4+, mikefarah) is required to read secrets-schema.yaml"
        return 1
    fi

    local _yq_version
    _yq_version=$(yq --version 2>&1) || _yq_version=""
    if [[ "$_yq_version" != *"mikefarah/yq"* || ! "$_yq_version" =~ version[[:space:]]v?4\. ]]; then
        log_error "schema.sh: unsupported yq implementation: ${_yq_version:-unknown}"
        log_error "schema.sh: Mike Farah yq v4 is required; re-run sudo ./setup.sh install."
        return 1
    fi

    if [[ ! -f "${schema_file}" ]]; then
        log_error "schema.sh: schema file not found: ${schema_file}"
        log_error "schema.sh: Expected at: ${SECRETS_SCHEMA_FILE}"
        return 1
    fi

    local _schema_ver
    _schema_ver=$(yq -r '.schema_version' "${schema_file}" 2>/dev/null) || true
    if [[ "${_schema_ver}" != "1" ]]; then
        log_error "schema.sh: unsupported schema_version '${_schema_ver}' in ${schema_file}"
        log_error "schema.sh: expected schema_version: 1"
        return 1
    fi
    _schema_validate_semantics "$schema_file" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# schema_keys [SCHEMA_FILE]
#
# Prints all secret key names to stdout, one per line, in schema order.
# -r ensures each key is emitted as a bare string without surrounding quotes.
#
# Example:
#   while IFS= read -r key; do ...; done < <(schema_keys)
# ---------------------------------------------------------------------------
schema_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq -r '.secrets[].key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_field KEY FIELD [SCHEMA_FILE]
#
# Prints the value of FIELD for the given KEY.
# Returns 1 and emits an error if the key does not exist in the schema.
# -r ensures the returned value is a bare string without surrounding quotes.
#
# Example:
#   hint=$(schema_field admin_token hint)
#   apply_type=$(schema_field caddy_cloudflare_dns_token apply.type)
# ---------------------------------------------------------------------------
schema_field() {
    local key="$1"
    local field="$2"
    local schema_file="${3:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local value
    value=$(yq -r ".secrets[] | select(.key == \"${key}\") | .${field}" "$schema_file") || {
        log_error "schema_field: failed to read field '${field}' for key '${key}'"
        return 1
    }

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
# -r ensures the returned value is a bare string without surrounding quotes.
# ---------------------------------------------------------------------------
schema_field_safe() {
    local key="$1"
    local field="$2"
    local schema_file="${3:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local value
    value=$(yq -r ".secrets[] | select(.key == \"${key}\") | .${field}" "$schema_file" 2>/dev/null) || true
    [[ "$value" == "null" ]] && value=""
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# schema_required_keys [SCHEMA_FILE]
#
# Prints keys where required=true, one per line, in schema order.
# -r ensures each key is emitted as a bare string without surrounding quotes.
# Used by check_placeholder_values() in lib/secrets.sh.
# ---------------------------------------------------------------------------
schema_required_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq -r '.secrets[] | select(.required == true) | .key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_hinted_keys [SCHEMA_FILE]
#
# Prints keys where hint is a non-empty string, one per line, in schema order.
# -r ensures each key is emitted as a bare string without surrounding quotes.
# Used by secrets-edit.sh to inject inline YAML comments.
# ---------------------------------------------------------------------------
schema_hinted_keys() {
    local schema_file="${1:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq -r '.secrets[] | select(.hint != "" and .hint != null) | .key' "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_apply_type_for_key KEY [SCHEMA_FILE]
#
# Prints the closed apply type for KEY.
# ---------------------------------------------------------------------------
schema_apply_type_for_key() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    schema_field "$key" "apply.type" "$schema_file"
}

# ---------------------------------------------------------------------------
# schema_apply_targets_for_key KEY [SCHEMA_FILE]
#
# Prints the space-separated list of apply targets for KEY.
# ---------------------------------------------------------------------------
schema_apply_targets_for_key() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local targets_nl
    targets_nl=$(yq -r ".secrets[] | select(.key == \"${key}\") | .apply.targets[]" "$schema_file" 2>/dev/null) || true
    if [[ -z "$targets_nl" || "$targets_nl" == "null" ]]; then
        printf ''
        return 0
    fi
    printf '%s' "${targets_nl//$'\n'/ }"
}

# Backward-compatible helper for callers that only need Docker Compose restart
# targets. Non-compose apply types intentionally return an empty string so a
# host systemd service is never presented as a compose service.
schema_services_for_key() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    local apply_type
    apply_type=$(schema_apply_type_for_key "$key" "$schema_file") || return 1
    if [[ "$apply_type" != "compose_restart" ]]; then
        printf ''
        return 0
    fi
    schema_apply_targets_for_key "$key" "$schema_file"
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
# -r ensures the returned value is a bare string for the non-empty check.
# Used by secrets-rotate.sh to validate the field argument.
# ---------------------------------------------------------------------------
schema_key_exists() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1

    local found
    found=$(yq -r ".secrets[] | select(.key == \"${key}\") | .key" "$schema_file" 2>/dev/null) || true
    [[ -n "$found" && "$found" != "null" ]]
}

# ---------------------------------------------------------------------------
# schema_collect_type KEY [SCHEMA_FILE]
#
# Prints the collect type for KEY: one of interactive | auto | conditional | skip.
# Named accessor so callers can branch cleanly without re-reading the raw field.
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

# Prints the Bash predicate named by condition_fn for a conditional key.
# The predicate receives the schema key and returns 0 to collect or 1 to write
# the key's placeholder without prompting.
schema_condition_fn() {
    local key="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    schema_field_safe "$key" "condition_fn" "$schema_file"
}

schema_keys_for_conditional_group() {
    local group="$1"
    local schema_file="${2:-${SECRETS_SCHEMA_FILE}}"
    _schema_check_prerequisites "$schema_file" || return 1
    yq -r ".secrets[] | select(.conditional_group == \"${group}\") | .key" "$schema_file"
}

export -f _schema_check_prerequisites _schema_validate_semantics
export -f schema_keys schema_field schema_field_safe
export -f schema_required_keys schema_hinted_keys
export -f schema_apply_type_for_key schema_apply_targets_for_key schema_services_for_key
export -f schema_placeholder_for_key schema_key_exists schema_collect_type
export -f schema_condition_fn schema_keys_for_conditional_group

log_debug "Schema library loaded (schema: ${SECRETS_SCHEMA_FILE})"
