#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TESTS_RUN=0

cleanup() {
    if [[ -d "$TMP" ]]; then
        if (( EUID == 0 )); then
            rm -rf "$TMP"
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            sudo -n rm -rf "$TMP"
        else
            rm -rf "$TMP"
        fi
    fi
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
run_test() { local name="$1"; shift; TESTS_RUN=$((TESTS_RUN + 1)); "$@"; pass "$name"; }

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
    local fake_repo="$TMP/fake-repo-fallthrough" installed="$TMP/installed.env" installed_state="$TMP/installed-state"
    mkdir -p "$fake_repo"
    write_env "$fake_repo/.env" 'DOMAIN=https://repo.example.test' 'ADMIN_EMAIL=repo@example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state" 'DATA_VOLUME_MOUNT=/from-installed' 'SOPS_AGE_KEY_FILE=/installed/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
load_project_environment
printf 'PROJECT_STATE_DIR=%s\n' "$PROJECT_STATE_DIR"
PROBE
)
    grep -q "PROJECT_STATE_DIR=$installed_state" <<< "$output" || fail "expected installed PROJECT_STATE_DIR, got: $output"
}

test_config_caller_override_wins() {
    local fake_repo="$TMP/fake-repo-override" installed="$TMP/installed-override.env" installed_state="$TMP/installed-other" override_state="$TMP/override-state"
    mkdir -p "$fake_repo"
    mkdir -p "$override_state/config"
    write_env "$fake_repo/.env" 'DOMAIN=https://repo.example.test'
    write_env "$installed" "PROJECT_STATE_DIR=$installed_state"
    write_env "$override_state/config/install.env" "PROJECT_STATE_DIR=$TMP/wrong-loaded-state" 'DATA_VOLUME_MOUNT=/loaded-mount' 'SOPS_AGE_KEY_FILE=/loaded/key.txt'

    local output
    output=$(VW_CONFIG_INSTALLED_ENV_FILE="$installed" PROJECT_ROOT="$fake_repo" REAL_CONFIG="$ROOT/lib/config.sh" PROJECT_STATE_DIR="$override_state" DATA_VOLUME_MOUNT=/caller-mount SOPS_AGE_KEY_FILE=/caller/key.txt bash <<'PROBE'
set -euo pipefail
source "$REAL_CONFIG"
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
    if (( EUID != 0 )); then
        grep -Fq 'systemctl disable --now "$STARTUP_SERVICE"' "$ROOT/utilities/setup-systemd.sh" \
            || fail "setup-systemd remove does not disable startup service"
        grep -Fq 'systemctl daemon-reload' "$ROOT/utilities/setup-systemd.sh" \
            || fail "setup-systemd remove does not reload daemon"
        return
    fi

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

run_test 'repo .env without PROJECT_STATE_DIR falls through to installed environment' test_config_falls_through_empty_repo_state
run_test 'explicit caller overrides survive loading and repeated calls' test_config_caller_override_wins
test_notify_failure_systemd_uses_helper() {
    grep -q '^ExecStart=/opt/vaultwarden-scripts/utilities/notify-failure.sh %i' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier template does not call helper with %i"
    ! grep -q 'notify_failure_.*PROJECT_STATE_DIR' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier unit still contains cooldown shell logic"
    ! grep -q '/notify_failure_' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier unit can write cooldown under /"
}

test_notify_failure_helper_defaults_state_dir() {
    grep -q 'PROJECT_STATE_DIR=/var/lib/vaultwarden' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify helper does not default PROJECT_STATE_DIR safely"
    grep -q '\${PROJECT_STATE_DIR}/.vw-health-alert' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify helper does not write cooldowns under PROJECT_STATE_DIR"
    grep -q 'Refusing unsafe cooldown directory' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify helper lacks unsafe cooldown guard"
}

test_notify_failure_helper_loads_secret_resolution() {
    local helper="$ROOT/utilities/notify-failure.sh"
    local crypto_line secrets_line email_line
    crypto_line=$(awk '/source "\$\{PROJECT_ROOT\}\/lib\/crypto\.sh"/{print NR; exit}' "$helper")
    secrets_line=$(awk '/source "\$\{PROJECT_ROOT\}\/lib\/secrets\.sh"/{print NR; exit}' "$helper")
    email_line=$(awk '/source "\$\{PROJECT_ROOT\}\/lib\/email\.sh"/{print NR; exit}' "$helper")
    [[ -n "$crypto_line" ]] || fail "notify helper does not source lib/crypto.sh"
    [[ -n "$secrets_line" ]] || fail "notify helper does not source lib/secrets.sh"
    [[ -n "$email_line" ]] || fail "notify helper does not source lib/email.sh"
    (( crypto_line < email_line )) || fail "notify helper must source crypto before email"
    (( secrets_line < email_line )) || fail "notify helper must source secrets before email"
}

test_installed_runtime_secret_resolution() {
    grep -q 'load_project_environment' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not use load_project_environment"

    grep -q 'resolve_secrets_file' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not resolve SECRETS_FILE after env load"

    grep -q 'load_project_environment' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify-failure helper does not use load_project_environment"

    grep -q 'resolve_secrets_file' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify-failure helper does not resolve SECRETS_FILE after env load"

    grep -q 'unset SOPS_CONFIG' "$ROOT/lib/secrets.sh" \
        || fail "ensure_sops_env does not unset missing SOPS_CONFIG"

    grep -q 'config=<unset; no .sops.yaml found>' "$ROOT/lib/secrets.sh" \
        || fail "ensure_sops_env does not document missing .sops.yaml fallback"
}

test_dns_optional_and_strict_modes() {
    grep -q 'UPDATE_DNS=false; skipping DNS update' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not skip cleanly when UPDATE_DNS=false"
    grep -q 'DNS automation not configured' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not warn for optional missing DNS config"
    grep -q 'DNS update is required' "$ROOT/utilities/maintenance-update-dns.sh" \
        || fail "DNS updater does not fail strict missing DNS config"
}

test_stale_root_dropin_cleanup_preserves_state_dir() {
    grep -q 'vaultwarden-db-backup.service.d/30-run-as-root.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "db backup stale root drop-in cleanup missing"
    grep -q 'vaultwarden-full-backup.service.d/30-run-as-root.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "full backup stale root drop-in cleanup missing"
    grep -q '10-state-dir.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "10-state-dir.conf handling unexpectedly missing"
    ! grep -q '30-run-as-root.conf.*10-state-dir.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "stale root cleanup appears to target 10-state-dir.conf"
}

can_run_systemd_behavioral_tests() {
    [[ "$(uname -s)" == "Linux" ]] || return 1
    if (( EUID == 0 )); then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

run_root_env_capture() {
    local out="$1"
    shift
    if (( EUID == 0 )); then
        env "$@" > "$out" 2>&1
    else
        # shellcheck disable=SC2024 # The output file is owned by the test runner, not the sudo command.
        sudo -n env "$@" > "$out" 2>&1
    fi
}

write_healthy_systemctl_mock() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled)
        exit 0
        ;;
    is-active)
        if [[ "${2:-}" == "--quiet" ]]; then
            exit 0
        fi
        printf 'active\n'
        exit 0
        ;;
    show)
        printf 'Mon 2026-07-06 12:00:00 UTC\n'
        exit 0
        ;;
    status)
        printf 'mock status %s\n' "${2:-}"
        exit 0
        ;;
    *)
        printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
        exit 0
        ;;
esac
SYSTEMCTL
    chmod +x "$bin/systemctl"
}

prepare_systemd_validation_fixture() {
    local unit_dir="$1" opt_dir="$2" env_dir="$3" state_dir="$4"
    mkdir -p "$unit_dir" "$opt_dir" "$env_dir" "$state_dir/config"

    cp -a "$ROOT/lib" "$opt_dir/lib"
    find "$opt_dir/lib" -type d -exec chmod 755 {} +
    find "$opt_dir/lib" -type f -name '*.sh' -exec chmod 644 {} +

    local script
    for script in maintenance.sh backup.sh restore.sh; do
        cp "$ROOT/$script" "$opt_dir/$script"
        chmod 700 "$opt_dir/$script"
    done
    for script in \
        utilities/setup-firewall.sh \
        utilities/maintenance-run.sh \
        utilities/maintenance-health.sh \
        utilities/maintenance-update.sh \
        utilities/maintenance-db-maint.sh \
        utilities/maintenance-email.sh \
        utilities/maintenance-update-dns.sh \
        utilities/notify-failure.sh \
        utilities/maintenance-update-firewall.sh \
        utilities/backup-run.sh \
        utilities/restore-run.sh; do
        mkdir -p "$opt_dir/$(dirname "$script")"
        cp "$ROOT/$script" "$opt_dir/$script"
        chmod 700 "$opt_dir/$script"
    done

    cp "$ROOT"/systemd/vaultwarden-*.service "$unit_dir/"
    cp "$ROOT"/systemd/vaultwarden-*.timer "$unit_dir/"
    chmod 644 "$unit_dir"/vaultwarden-*.service "$unit_dir"/vaultwarden-*.timer
    sed -e "s|@PROJECT_ROOT@|$ROOT|g" \
        -e "s|@PROJECT_STATE_DIR@|$state_dir|g" \
        "$ROOT/systemd/vaultwarden-startup.service" > "$unit_dir/vaultwarden-startup.service"
    chmod 644 "$unit_dir/vaultwarden-startup.service"

    cat > "$env_dir/vaultwarden.env" <<EOF_ENV
PROJECT_STATE_DIR=$state_dir
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=$state_dir
SOPS_AGE_KEY_FILE=$env_dir/age-key.txt
EOF_ENV
    cat > "$env_dir/age-key.txt" <<'EOF_KEY'
# public key: age1systemdvalidation000000000000000000000000000000000000000
AGE-SECRET-KEY-1SYSTEMDVALIDATION
EOF_KEY
    chmod 700 "$env_dir"
    chmod 600 "$env_dir/vaultwarden.env" "$env_dir/age-key.txt"
    if (( EUID == 0 )); then
        chown root:root "$env_dir" "$env_dir/vaultwarden.env" "$env_dir/age-key.txt"
    else
        sudo -n chown root:root "$env_dir" "$env_dir/vaultwarden.env" "$env_dir/age-key.txt"
    fi
}

run_systemd_validate_fixture() {
    local out="$1" bin="$2" unit_dir="$3" opt_dir="$4" env_dir="$5" state_dir="$6"
    run_root_env_capture "$out" \
        PATH="$bin:$PATH" \
        SYSTEMCTL_LOG="$TMP/systemctl.log" \
        PROJECT_STATE_DIR="$state_dir" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$ROOT/utilities/setup-systemd.sh" validate
}

test_systemd_validation_fails_on_stale_installed_runtime() {
    if ! can_run_systemd_behavioral_tests; then
        printf 'SKIP: systemd validation behavioral test requires Linux root or passwordless sudo\n'
        return 0
    fi

    local unit_dir="$TMP/systemd-units" opt_dir="$TMP/opt-scripts" env_dir="$TMP/etc-vaultwarden" state_dir="$TMP/state"
    local bin="$TMP/bin" clean_out="$TMP/validate-clean.out" stale_out
    write_healthy_systemctl_mock "$bin"
    prepare_systemd_validation_fixture "$unit_dir" "$opt_dir" "$env_dir" "$state_dir"

    run_systemd_validate_fixture "$clean_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || { cat "$clean_out" >&2; fail "clean temp-installed systemd tree did not validate"; }

    local installed
    installed="$opt_dir/utilities/backup-run.sh"
    printf '\n# stale backup-run fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-backup-run.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale installed backup-run.sh"
    grep -Fq "STALE: $installed does not match repo source" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale backup-run.sh was not named"; }
    grep -Fq 'Re-run: sudo utilities/setup-systemd.sh install' "$stale_out" \
        || fail "stale backup-run.sh output did not tell operator to rerun install"
    cp "$ROOT/utilities/backup-run.sh" "$installed"
    chmod 700 "$installed"

    installed="$opt_dir/lib/backup-utils.sh"
    printf '\n# stale backup-utils fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-backup-utils.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale installed backup-utils.sh"
    grep -Fq "STALE: $installed does not match repo source" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale backup-utils.sh was not named"; }
    cp "$ROOT/lib/backup-utils.sh" "$installed"
    chmod 644 "$installed"

    installed="$unit_dir/vaultwarden-db-backup.service"
    printf '\n# stale db backup unit fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-db-backup-service.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale installed vaultwarden-db-backup.service"
    grep -Fq "STALE: $installed does not match repo source" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale vaultwarden-db-backup.service was not named"; }
    cp "$ROOT/systemd/vaultwarden-db-backup.service" "$installed"
    chmod 644 "$installed"

    installed="$unit_dir/vaultwarden-startup.service"
    printf '\n# stale rendered startup unit fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-startup-service.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale rendered vaultwarden-startup.service"
    grep -Fq "DRIFT: $installed does not match freshly rendered template" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale rendered startup service was not named"; }
}

run_test 'systemd remove requests startup disable and daemon reload' test_systemd_remove_disables_startup_service
run_test 'notify-failure systemd uses helper and no root cooldown path' test_notify_failure_systemd_uses_helper
run_test 'notify-failure helper defaults PROJECT_STATE_DIR safely' test_notify_failure_helper_defaults_state_dir
run_test 'notify-failure helper loads encrypted-secret resolution before email' test_notify_failure_helper_loads_secret_resolution
run_test 'DNS update optional and strict modes are represented' test_dns_optional_and_strict_modes
run_test 'installed runtime secret resolution is guarded' test_installed_runtime_secret_resolution
run_test 'stale 30-run-as-root cleanup preserves 10-state-dir handling' test_stale_root_dropin_cleanup_preserves_state_dir
run_test 'systemd validation fails on stale installed runtime artifacts' test_systemd_validation_fails_on_stale_installed_runtime
[[ "$TESTS_RUN" -eq 10 ]] || fail "expected 10 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
