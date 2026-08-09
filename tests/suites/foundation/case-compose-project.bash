#!/usr/bin/env bash
# Installed-runtime Compose identity regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail 'docker CLI is required for Compose identity regression'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose plugin is required for Compose identity regression'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required for Compose identity regression'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUNTIME="$TMP/vaultwarden-scripts"
STATE="$TMP/state"
INSTALLED_ENV="$TMP/vaultwarden.env"
mkdir -p "$RUNTIME" "$STATE"
cp -a "$ROOT/lib" "$ROOT/caddy" "$RUNTIME/"
cp "$ROOT/docker-compose.yml.example" "$RUNTIME/docker-compose.yml"

cat > "$INSTALLED_ENV" <<EOF_ENV
DOMAIN=https://compose-identity.example.test
ADMIN_EMAIL=admin@example.test
PUID=1000
PGID=1000
TZ=UTC
PROJECT_STATE_DIR=$STATE
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=$STATE
SOPS_AGE_KEY_FILE=
VAULTWARDEN_VERSION=1.36.0
CADDY_VERSION=2.11.4
POSTFIX_VERSION=5.1.0
SMTP_HOST=smtp.example.test
SMTP_PORT=587
SMTP_USERNAME=test-user
COMPOSE_PROJECT_NAME=wrong-project
EOF_ENV
chmod 0600 "$INSTALLED_ENV"

(
    cd "$RUNTIME"
    export PROJECT_ROOT="$RUNTIME"
    export VW_CONFIG_INSTALLED_ENV_FILE="$INSTALLED_ENV"
    export COMPOSE_PROJECT_NAME=wrong-shell-project

    # shellcheck source=../../../lib/config.sh
    source "$RUNTIME/lib/config.sh"
    [[ "$COMPOSE_PROJECT_NAME" == "vaultwarden-oci" ]] \
        || fail "config source did not pin Compose project identity: $COMPOSE_PROJECT_NAME"

    load_project_environment >/dev/null
    [[ "$COMPOSE_PROJECT_NAME" == "vaultwarden-oci" ]] \
        || fail "installed environment overrode Compose project identity: $COMPOSE_PROJECT_NAME"

    project_name="$(docker compose config --format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name", ""))')"
    [[ "$project_name" == "vaultwarden-oci" ]] \
        || fail "installed runtime resolved Compose project '$project_name' instead of vaultwarden-oci"

    images="$(docker compose config --images)"
    grep -Fxq 'vaultwarden-oci-caddy' <<< "$images" \
        || { printf '%s\n' "$images" >&2; fail 'installed runtime did not resolve the canonical Caddy image tag'; }
    ! grep -Fq 'vaultwarden-scripts-caddy' <<< "$images" \
        || fail 'installed runtime still derived the Caddy image tag from /opt directory name'
)

printf 'Installed runtime preserves Compose project vaultwarden-oci and Caddy image vaultwarden-oci-caddy.\n'
