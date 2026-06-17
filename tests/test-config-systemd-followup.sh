#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TESTS_RUN=0
ORIG_ENV_BACKUP=""
ORIG_ENV_EXISTS=false

cleanup() {
    if [[ "$ORIG_ENV_EXISTS" == true ]]; then
        mv "$ORIG_ENV_BACKUP" "$ROOT/.env"
    else
        rm -f "$ROOT/.env"
        [[ -n "$ORIG_ENV_BACKUP" ]] && rm -f "$ORIG_ENV_BACKUP"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
run_test() { local name="$1"; shift; TESTS_RUN=$((TESTS_RUN + 1)); "$@"; pass "$name"; }

backup_repo_env() {
    if [[ -f "$ROOT/.env" ]]; then
        ORIG_ENV_EXISTS=true
        ORIG_ENV_BACKUP="$TMP/repo.env.backup"
        cp "$ROOT/.env" "$ORIG_ENV_BACKUP"
    else
        ORIG_ENV_EXISTS=false
        ORIG_ENV_BACKUP="$TMP/repo.env.backup"
    fi
}

write_env() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$@" > "$file"
    chmod 0600 "$file"
}

run_config_probe() {
    local script="$1"
    PROJECT_ROOT="$ROOT" bash -c "$script"
}

test_config_falls_through_empty_repo_state() {
    local installed="$TMP/installed.env" installed_state="$TMP/installed-state"
    write_env "$ROOT/.env" 'DOMAIN=https://repo.example.test' 'ADMIN_EMAIL=repo@example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state" 'DATA_VOLUME_MOUNT=/from-installed' 'SOPS_AGE_KEY_FILE=/installed/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$ROOT" bash <<'PROBE'
set -euo pipefail
source "$PROJECT_ROOT/lib/config.sh"
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$installed_state" <<< "$output" || fail "expected installed PROJECT_STATE_DIR, got: $output"
}

test_config_caller_override_wins() {
    local installed="$TMP/installed-override.env" installed_state="$TMP/installed-other" override_state="$TMP/override-state"
    mkdir -p "$override_state/config"
    write_env "$ROOT/.env" 'DOMAIN=https://repo.example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state"
    write_env "$override_state/config/install.env" "PROJECT_STATE_DIR=$TMP/wrong-loaded-state" 'DATA_VOLUME_MOUNT=/loaded-mount' 'SOPS_AGE_KEY_FILE=/loaded/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$ROOT" PROJECT_STATE_DIR="$override_state" DATA_VOLUME_MOUNT=/caller-mount SOPS_AGE_KEY_FILE=/caller/key.txt bash <<'PROBE'
set -euo pipefail
source "$PROJECT_ROOT/lib/config.sh"
load_project_environment
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
printf 'DATA_VOLUME_MOUNT=%s\n' "$DATA_VOLUME_MOUNT"
printf 'SOPS_AGE_KEY_FILE=%s\n' "$SOPS_AGE_KEY_FILE"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$override_state" <<< "$output" || fail "caller PROJECT_STATE_DIR override lost: $output"
    grep -q 'DATA_VOLUME_MOUNT=/caller-mount' <<< "$output" || fail "caller DATA_VOLUME_MOUNT override lost: $output"
    grep -q 'SOPS_AGE_KEY_FILE=/caller/key.txt' <<< "$output" || fail "caller SOPS_AGE_KEY_FILE override lost: $output"
}

test_systemd_remove_disables_startup_service() {
    local state="$TMP/systemd-state" bin="$TMP/bin" out="$TMP/systemd-remove.out" installed="$TMP/systemd-installed.env"
    mkdir -p "$state/config" "$bin"
    write_env "$state/config/install.env" "PROJECT_STATE_DIR=$state"
    write_env "$installed" "PROJECT_STATE_DIR=$state"
    cat > "$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled|is-active)
        [[ "${2:-}" == vaultwarden-startup.service ]] && exit 0
        exit 1
        ;;
    *)
        printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
        exit 0
        ;;
esac
SYSTEMCTL
    chmod +x "$bin/systemctl"
    : > "$TMP/systemctl.log"

    PATH="$bin:$PATH" SYSTEMCTL_LOG="$TMP/systemctl.log" PROJECT_STATE_DIR="$state" VW_CONFIG_INSTALLED_ENV_FILE="$installed" \
        bash "$ROOT/utilities/setup-systemd.sh" remove --dry-run > "$out" 2>&1

    grep -q '\[DRY RUN\] systemctl disable --now vaultwarden-startup.service' "$out" || fail "startup disable dry-run was not requested"
    grep -q '\[DRY RUN\] systemctl daemon-reload' "$out" || fail "daemon-reload dry-run was not requested"
}

backup_repo_env
run_test 'repo .env without PROJECT_STATE_DIR falls through to installed environment' test_config_falls_through_empty_repo_state
run_test 'explicit caller overrides survive loading and repeated calls' test_config_caller_override_wins
run_test 'systemd remove requests startup disable and daemon reload' test_systemd_remove_disables_startup_service
[[ "$TESTS_RUN" -eq 3 ]] || fail "expected 3 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
