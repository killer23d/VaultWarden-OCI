#!/usr/bin/env bash
# Consolidated systemd regression suite.
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

check_systemd_operation_runtime_paths() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
OPS="$ROOT/lib/operations.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

canonical="$(
  sed -n 's/^: "${VW_OPERATIONS_STATE_DIR:=\(.*\)}"$/\1/p' "$OPS"
)"
[[ -n "$canonical" ]] || fail "could not derive VW_OPERATIONS_STATE_DIR from lib/operations.sh"
canonical_root="${canonical%/operations}"
[[ "$canonical" == "/run/vaultwarden-oci/operations" ]] \
  || fail "unexpected canonical operations state dir: $canonical"

guarded_units=(
  vaultwarden-db-backup.service
  vaultwarden-full-backup.service
  vaultwarden-maintenance.service
  vaultwarden-health.service
  vaultwarden-dns-update.service
  vaultwarden-firewall-update.service
  vaultwarden-iptables.service
  vaultwarden-startup.service
)

for unit in "${guarded_units[@]}"; do
  file="$ROOT/systemd/$unit"
  [[ -f "$file" ]] || fail "missing unit: $unit"
  grep -Eq "^ReadWritePaths=.*${canonical_root}" "$file" \
    || fail "$unit does not grant writable canonical operation root $canonical_root"
  grep -Eq "^RuntimeDirectory=.*vaultwarden-oci" "$file" \
    || fail "$unit does not pre-create /run/vaultwarden-oci"
  if grep -Eq '^ReadWritePaths=.* /run/vaultwarden(\s|$)' "$file"; then
    fail "$unit still grants stale /run/vaultwarden operation path"
  fi
done

grep -Eq '^SuccessExitStatus=0 75$' "$ROOT/systemd/vaultwarden-dns-update.service" \
  || fail "DNS update unit must treat expected contention as success"
grep -Eq '^SuccessExitStatus=0 75$' "$ROOT/systemd/vaultwarden-firewall-update.service" \
  || fail "firewall update unit must treat expected contention as success"

printf 'PASS: systemd operation runtime paths\n'

)

check_systemd_operation_runtime_paths
check_systemd_install_and_validation_contracts() (
set -euo pipefail

ROOT="$VW_TEST_REPO_ROOT"
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

extract_func() {
    local file="$1" func="$2"
    awk -v f="$func" '
        $0 ~ "^" f "\\(\\)" {p=1}
        p {
          print
          opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
          depth += opens - closes
          if (depth == 0) exit
        }' "$file"
}

test_state_dir_dropins_match_unit_type() {
    local unit_dir="$TMP/state-dir-units" probe="$TMP/state-dir-dropin-probe.sh"
    local service="vaultwarden-db-backup.service" timer="vaultwarden-db-backup.timer"
    local data_mount="/mnt/vaultwarden-data" mount_unit="mnt-vaultwarden-data.mount"
    local service_dropin="$unit_dir/${service}.d/10-state-dir.conf"
    local timer_dropin="$unit_dir/${timer}.d/10-state-dir.conf"

    mkdir -p "$unit_dir"
    cp "$ROOT/systemd/$service" "$unit_dir/$service"
    cp "$ROOT/systemd/$timer" "$unit_dir/$timer"

    cat > "$probe" <<EOF_PROBE
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
ENV_FILE="$TMP/no-installed-env"
UNIT_DEST_DIR="$unit_dir"
DATA_VOLUME_DEVICE=/dev/disk/by-id/test-data
DATA_VOLUME_MOUNT="$data_mount"
_VW_DROPIN_UNITS=(
    vaultwarden-db-backup.service
    vaultwarden-db-backup.timer
)
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
log_success(){ :; }
systemd-escape(){ printf '%s\\n' '$mount_unit'; }
EOF_PROBE
    extract_func "$ROOT/utilities/setup-systemd.sh" _install_rwpaths_dropin >> "$probe"
    printf '\n_install_rwpaths_dropin\n' >> "$probe"
    bash "$probe" || fail "state-dir drop-in fixture generation failed"

    grep -Fxq '[Unit]' "$service_dropin" || fail "service state-dir drop-in lacks [Unit]"
    grep -Fxq "After=$mount_unit" "$service_dropin" || fail "service state-dir drop-in lacks data mount ordering"
    grep -Fxq '[Service]' "$service_dropin" || fail "service state-dir drop-in lacks [Service]"
    grep -Fxq "ReadWritePaths=$data_mount" "$service_dropin" || fail "service state-dir drop-in lacks data mount write path"

    grep -Fxq '[Unit]' "$timer_dropin" || fail "timer state-dir drop-in lacks [Unit]"
    grep -Fxq "After=$mount_unit" "$timer_dropin" || fail "timer state-dir drop-in lacks data mount ordering"
    ! grep -Fxq '[Service]' "$timer_dropin" || fail "timer state-dir drop-in contains service-only section"
    ! grep -Fq 'ReadWritePaths=' "$timer_dropin" || fail "timer state-dir drop-in contains service-only write path"

    if ! command -v systemd-analyze >/dev/null 2>&1; then
        printf 'SKIP: systemd-analyze unavailable; state-dir drop-in structural assertions passed\n'
        return 0
    fi

    # Keep the repository service and timer bodies in the fixture. Only the
    # command and direct dependencies unrelated to drop-in parsing are made
    # self-contained so systemd-analyze can validate this temporary unit tree.
    sed 's|^ExecStart=.*|ExecStart=/usr/bin/true|' "$unit_dir/$service" > "$unit_dir/${service}.tmp"
    mv "$unit_dir/${service}.tmp" "$unit_dir/$service"
    cat > "$unit_dir/docker.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    cat > "$unit_dir/vaultwarden-health.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT
    cat > "$unit_dir/vaultwarden-notify-failure@.service" <<'EOF_UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF_UNIT

    local verify_out="$TMP/systemd-analyze-state-dir.out"
    if ! SYSTEMD_UNIT_PATH="$unit_dir:" systemd-analyze verify "$service" "$timer" > "$verify_out" 2>&1; then
        cat "$verify_out" >&2
        fail "systemd-analyze could not verify generated state-dir unit fixture"
    fi
    if grep -Eqi 'unknown (section|lvalue|key)|invalid directive|assignment outside' "$verify_out"; then
        cat "$verify_out" >&2
        fail "systemd-analyze reported an invalid generated unit/drop-in directive"
    fi
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
    write_env "$state/config/install.env" "PROJECT_STATE_DIR=$state" "SOPS_AGE_KEY_FILE=$TMP/synthetic-age-key.txt"
    write_env "$installed" "PROJECT_STATE_DIR=$state" "SOPS_AGE_KEY_FILE=$TMP/synthetic-age-key.txt"
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

test_notify_failure_systemd_uses_helper() {
    grep -q '^ExecStart=/opt/vaultwarden-scripts/utilities/notify-failure.sh %i' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier template does not call helper with %i"
    ! grep -q 'notify_failure_.*PROJECT_STATE_DIR' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier unit still contains cooldown shell logic"
    ! grep -q '/notify_failure_' "$ROOT/systemd/vaultwarden-notify-failure@.service" \
        || fail "notifier unit can write cooldown under /"
}

test_notify_failure_helper_requires_selected_state_dir() {
    grep -q 'require_config PROJECT_STATE_DIR' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify helper does not require canonical PROJECT_STATE_DIR"
    ! grep -q 'PROJECT_STATE_DIR=/var/lib/vaultwarden' "$ROOT/utilities/notify-failure.sh" \
        || fail "notify helper silently defaults after canonical configuration failure"
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

test_stale_root_dropin_cleanup_preserves_state_dir() {
    grep -q '30-run-as-root.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "historical root drop-in is not part of managed stale inventory"
    grep -q '_list_unexpected_managed_artifacts' "$ROOT/utilities/setup-systemd.sh" \
        || fail "managed stale drop-in detection is missing"
    grep -q '10-state-dir.conf' "$ROOT/utilities/setup-systemd.sh" \
        || fail "10-state-dir.conf handling unexpectedly missing"
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
    # shellcheck disable=SC2033 # A later isolated test intentionally mocks chmod.
    find "$opt_dir/lib" -type d -exec chmod 755 {} +
    # shellcheck disable=SC2033 # A later isolated test intentionally mocks chmod.
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
        # shellcheck disable=SC2033 # A later isolated test intentionally mocks chown.
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

    installed="$opt_dir/retired-managed.sh"
    printf '#!/usr/bin/env bash\n' > "$installed"
    chmod 700 "$installed"
    stale_out="$TMP/validate-unexpected-script.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with unexpected stale managed script"
    grep -Fq "UNEXPECTED STALE MANAGED RUNTIME: $installed" "$stale_out" \
        || { cat "$stale_out" >&2; fail "unexpected stale script was not named"; }
    rm -f "$installed"

    installed="$opt_dir/lib/retired-managed.sh"
    printf '# stale managed library\n' > "$installed"
    chmod 644 "$installed"
    stale_out="$TMP/validate-unexpected-library.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with unexpected stale managed library"
    grep -Fq "UNEXPECTED STALE MANAGED RUNTIME: $installed" "$stale_out" \
        || { cat "$stale_out" >&2; fail "unexpected stale library was not named"; }
    rm -f "$installed"

    installed="$unit_dir/vaultwarden-retired.service"
    printf '[Unit]\nDescription=VaultWarden-OCI retired fixture\n' > "$installed"
    chmod 644 "$installed"
    stale_out="$TMP/validate-unexpected-unit.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with unexpected stale managed unit"
    grep -Fq "UNEXPECTED STALE MANAGED UNIT: $installed" "$stale_out" \
        || { cat "$stale_out" >&2; fail "unexpected stale unit was not named"; }
    rm -f "$installed"

    mkdir -p "$unit_dir/vaultwarden-health.service.d"
    printf '# operator-owned fixture\n[Service]\nEnvironment=OPERATOR_VALUE=1\n' \
        > "$unit_dir/vaultwarden-health.service.d/operator.conf"
    run_systemd_validate_fixture "$TMP/validate-operator-dropin.out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || { cat "$TMP/validate-operator-dropin.out" >&2; fail "operator drop-in was classified as stale managed state"; }

    installed="$unit_dir/vaultwarden-startup.service"
    printf '\n# stale rendered startup unit fixture\n' >> "$installed"
    stale_out="$TMP/validate-stale-startup-service.out"
    ! run_systemd_validate_fixture "$stale_out" "$bin" "$unit_dir" "$opt_dir" "$env_dir" "$state_dir" \
        || fail "validate succeeded with stale rendered vaultwarden-startup.service"
    grep -Fq "DRIFT: $installed does not match freshly rendered template" "$stale_out" \
        || { cat "$stale_out" >&2; fail "stale rendered startup service was not named"; }
}

test_closed_inventory_reconciles_only_project_owned_artifacts() (
    set -euo pipefail
    local opt_dir="$TMP/inventory-opt" unit_dir="$TMP/inventory-units" env_dir="$TMP/inventory-env"
    local outside="$TMP/outside-untouched" systemctl_log="$TMP/inventory-systemctl.log"
    mkdir -p "$opt_dir/lib" "$opt_dir/utilities" "$unit_dir/vaultwarden-current.service.d" \
        "$unit_dir/vaultwarden-retired.service.d" "$env_dir"
    printf 'expected\n' > "$opt_dir/maintenance.sh"
    printf 'expected\n' > "$opt_dir/lib/current.sh"
    printf 'stale script\n' > "$opt_dir/retired.sh"
    printf 'stale library\n' > "$opt_dir/lib/retired.sh"
    printf '[Unit]\nDescription=VaultWarden-OCI current\n' > "$unit_dir/vaultwarden-current.service"
    printf '[Unit]\nDescription=VaultWarden-OCI retired\n' > "$unit_dir/vaultwarden-retired.service"
    printf 'outside target\n' > "$TMP/symlink-target"
    ln -s "$TMP/symlink-target" "$unit_dir/vaultwarden-stale-link.service"
    ln -s "$TMP/symlink-target" "$unit_dir/vaultwarden-current.timer"
    ln -s "$TMP/symlink-target" "$unit_dir/unrelated.service"
    printf '# Written by setup-systemd.sh install — do not edit by hand.\n' \
        > "$unit_dir/vaultwarden-retired.service.d/30-run-as-root.conf"
    printf '# operator override\n' > "$unit_dir/vaultwarden-current.service.d/operator.conf"
    printf '# operator-owned reserved-name override\n' \
        > "$unit_dir/vaultwarden-current.service.d/10-state-dir.conf"
    printf 'runtime env\n' > "$env_dir/vaultwarden.env"
    printf 'synthetic key\n' > "$env_dir/age-key.txt"
    printf 'outside\n' > "$outside"
    : > "$systemctl_log"

    # shellcheck disable=SC2034 # Consumed by functions extracted with eval below.
    OPT_SCRIPTS_DIR="$opt_dir"
    # shellcheck disable=SC2034 # Consumed by functions extracted with eval below.
    UNIT_DEST_DIR="$unit_dir"
    # shellcheck disable=SC2034 # Consumed by functions extracted with eval below.
    DATA_VOLUME_DEVICE=""
    DRY_RUN=false
    _MANAGED_RUNTIME_FILES=(maintenance.sh lib/current.sh)
    _MANAGED_UNIT_FILES=(vaultwarden-current.service)
    _MANAGED_DROPIN_NAMES=(10-state-dir.conf 20-identity.conf 30-run-as-root.conf)
    _VW_DROPIN_UNITS=(vaultwarden-current.service)
    _IDENTITY_DROPIN_UNITS=()
    log_info(){ printf 'INFO %s\n' "$*"; }
    log_warn(){ printf 'WARN %s\n' "$*"; }
    log_error(){ printf 'ERROR %s\n' "$*"; }
    _run(){ "$@"; }
    systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        case "${1:-}" in
            is-active|is-enabled)
                [[ "${2:-}" == vaultwarden-retired.service ]]
                ;;
            *) return 0 ;;
        esac
    }

    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _inventory_contains)"
    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _managed_dropin_is_expected)"
    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _is_project_owned_unit_artifact)"
    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _list_unexpected_managed_artifacts)"
    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _reconcile_unexpected_managed_artifacts)"

    _reconcile_unexpected_managed_artifacts >/dev/null \
        || fail "closed managed inventory reconciliation failed"
    [[ ! -e "$opt_dir/retired.sh" ]] || fail "removed managed script survived reconciliation"
    [[ ! -e "$opt_dir/lib/retired.sh" ]] || fail "removed managed library survived reconciliation"
    [[ ! -e "$unit_dir/vaultwarden-retired.service" ]] || fail "removed managed unit survived reconciliation"
    [[ ! -L "$unit_dir/vaultwarden-stale-link.service" ]] || fail "unexpected project unit symlink survived reconciliation"
    [[ ! -L "$unit_dir/vaultwarden-current.timer" ]] || fail "expected managed unit symlink survived reconciliation"
    [[ -L "$unit_dir/unrelated.service" && -f "$TMP/symlink-target" ]] || fail "unrelated symlink or its target was removed"
    [[ ! -e "$unit_dir/vaultwarden-retired.service.d/30-run-as-root.conf" ]] \
        || fail "stale project-owned drop-in survived reconciliation"
    [[ -f "$unit_dir/vaultwarden-current.service.d/operator.conf" ]] \
        || fail "operator/third-party drop-in was removed"
    [[ -f "$unit_dir/vaultwarden-current.service.d/10-state-dir.conf" ]] \
        || fail "operator-owned reserved-name drop-in was removed without a project marker"
    [[ -f "$env_dir/vaultwarden.env" && -f "$env_dir/age-key.txt" ]] \
        || fail "installed environment or Age key material was removed"
    [[ -f "$outside" ]] || fail "file outside managed namespace was removed"
    grep -Fxq 'disable --now vaultwarden-retired.service' "$systemctl_log" \
        || fail "stale active unit was not stopped and disabled"
    grep -Fq 'vaultwarden-stale-link.service' "$systemctl_log" \
        || fail "stale project symlink unit identity was not checked before removal"
    grep -Fxq 'daemon-reload' "$systemctl_log" \
        || fail "daemon-reload did not follow stale unit/drop-in changes"

    local calls_before
    calls_before="$(wc -l < "$systemctl_log" | tr -d ' ')"
    _reconcile_unexpected_managed_artifacts >/dev/null \
        || fail "idempotent managed inventory rerun failed"
    [[ "$(wc -l < "$systemctl_log" | tr -d ' ')" == "$calls_before" ]] \
        || fail "idempotent inventory rerun repeated systemctl mutations"

    printf 'stale script\n' > "$opt_dir/retired.sh"
    printf '[Unit]\nDescription=VaultWarden-OCI retired\n' > "$unit_dir/vaultwarden-retired.service"
    mkdir -p "$unit_dir/vaultwarden-retired.service.d"
    printf '# Written by setup-systemd.sh install — do not edit by hand.\n' \
        > "$unit_dir/vaultwarden-retired.service.d/30-run-as-root.conf"
    DRY_RUN=true
    _run(){ log_info "[DRY RUN] $*"; }
    local dry_output
    dry_output="$(_reconcile_unexpected_managed_artifacts 2>&1)" \
        || fail "managed inventory dry-run failed"
    [[ -f "$opt_dir/retired.sh" && -f "$unit_dir/vaultwarden-retired.service" \
       && -f "$unit_dir/vaultwarden-retired.service.d/30-run-as-root.conf" ]] \
        || fail "managed inventory dry-run mutated fixture files"
    [[ "$dry_output" == *"$opt_dir/retired.sh"* \
       && "$dry_output" == *"$unit_dir/vaultwarden-retired.service"* \
       && "$dry_output" == *'systemctl disable --now vaultwarden-retired.service'* ]] \
        || fail "managed inventory dry-run did not name exact stale artifacts and intended actions"
)

    local sync_line reload_line reconcile_line render_line
    sync_line="$(grep -n '_sync_runtime_environment_files || return 1' "$ROOT/utilities/setup-systemd.sh" | head -1 | cut -d: -f1)"
    reload_line="$(grep -n '_reload_runtime_environment_after_sync || return 1' "$ROOT/utilities/setup-systemd.sh" | head -1 | cut -d: -f1)"
    reconcile_line="$(grep -n '_reconcile_unexpected_managed_artifacts || return 1' "$ROOT/utilities/setup-systemd.sh" | tail -1 | cut -d: -f1)"
    render_line="$(grep -n 'Installing systemd unit files to' "$ROOT/utilities/setup-systemd.sh" | head -1 | cut -d: -f1)"
    if [[ -z "$sync_line" || -z "$reload_line" || -z "$reconcile_line" || -z "$render_line" ]]; then
        fail "setup-systemd post-sync ordering markers are incomplete"
    fi
    if (( sync_line >= reload_line || reload_line >= reconcile_line || reconcile_line >= render_line )); then
        fail "setup-systemd does not reconcile the post-sync snapshot before rendering"
    fi
    printf 'PASS setup-systemd reloads one canonical post-sync snapshot before rendering\n'

test_runtime_lock_preparation_is_verified_and_stable() (
    set -euo pipefail
    local lock_dir="$TMP/runtime-locks" lock="$TMP/runtime-locks/probe.lock"
    mkdir -p "$lock_dir"
    _RUNTIME_LOCK_NAMES=(probe.lock)
    # shellcheck disable=SC2034 # Consumed by the function extracted with eval below.
    VW_SYSTEMD_RUNTIME_LOCK_DIR="$lock_dir"
    # shellcheck disable=SC2034 # Consumed by the function extracted with eval below.
    DRY_RUN=false
    CHOWN_RC=0
    CHMOD_RC=0

    _real_lock_identity() {
        if command -v gstat >/dev/null 2>&1; then
            gstat -c '%d:%i:%a' -- "$1"
        elif command stat --version >/dev/null 2>&1; then
            command stat -c '%d:%i:%a' -- "$1"
        else
            command stat -f '%d:%i:%Lp' "$1"
        fi
    }
    stat() {
        [[ "${1:-}" == "--version" ]] && return 0
        local path="${!#}" identity device inode mode
        identity="$(_real_lock_identity "$path")" || return 1
        IFS=: read -r device inode mode <<< "$identity"
        printf '%s:%s:root:vaultwarden:%s\n' "$device" "$inode" "$mode"
    }
    chown(){ return "$CHOWN_RC"; }
    chmod() {
        (( CHMOD_RC == 0 )) || return "$CHMOD_RC"
        command chmod "$@"
    }
    log_info(){ printf 'INFO %s\n' "$*"; }
    log_warn(){ printf 'WARN %s\n' "$*"; }
    log_error(){ printf 'ERROR %s\n' "$*"; }
    log_success(){ printf 'SUCCESS %s\n' "$*"; }
    eval "$(extract_func "$ROOT/utilities/setup-systemd.sh" _ensure_runtime_lock_files)"

    printf 'existing lock\n' > "$lock"
    command chmod 0644 "$lock"
    local inode_before inode_after success_output
    inode_before="$(_real_lock_identity "$lock")"
    success_output="$(_ensure_runtime_lock_files user group)" \
        || fail "valid in-place lock repair failed: $success_output"
    inode_after="$(_real_lock_identity "$lock")"
    [[ "${inode_before%:*}" == "${inode_after%:*}" ]] \
        || fail "existing lock device/inode changed during in-place repair"
    [[ "${inode_after##*:}" == "660" ]] || fail "existing lock mode was not repaired to 0660"
    [[ "$success_output" == *"Lock file ready: $lock"* ]] \
        || fail "verified lock preparation omitted readiness message"
    _ensure_runtime_lock_files user group >/dev/null \
        || fail "idempotent lock preparation rerun failed"

    command chmod 0644 "$lock"
    CHOWN_RC=41
    local output
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "lock ownership repair failure unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "ownership failure printed lock readiness"

    CHOWN_RC=0
    CHMOD_RC=42
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "lock mode repair failure unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "mode failure printed lock readiness"

    CHMOD_RC=0
    chmod(){ return 0; }
    command chmod 0644 "$lock"
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "zero-returning lock repair with false postcondition unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "false postcondition printed lock readiness"
    unset -f chmod
    chmod() {
        (( CHMOD_RC == 0 )) || return "$CHMOD_RC"
        command chmod "$@"
    }

    rm -f "$lock"
    ln -s "$TMP/symlink-target" "$lock"
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "symlink lock path unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "symlink rejection printed lock readiness"

    rm -f "$lock"
    mkdir "$lock"
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "non-regular lock path unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "non-regular rejection printed lock readiness"

    rmdir "$lock"
    rmdir "$lock_dir"
    if output="$(_ensure_runtime_lock_files user group 2>&1)"; then
        fail "lock creation failure unexpectedly succeeded"
    fi
    [[ "$output" != *'Lock file ready:'* ]] || fail "creation failure printed lock readiness"
)

run_test 'systemd remove requests startup disable and daemon reload' test_systemd_remove_disables_startup_service
run_test 'notify-failure systemd uses helper and no root cooldown path' test_notify_failure_systemd_uses_helper
run_test 'notify-failure helper requires canonical PROJECT_STATE_DIR' test_notify_failure_helper_requires_selected_state_dir
run_test 'notify-failure helper loads encrypted-secret resolution before email' test_notify_failure_helper_loads_secret_resolution
run_test 'stale 30-run-as-root cleanup preserves 10-state-dir handling' test_stale_root_dropin_cleanup_preserves_state_dir
run_test 'state-dir drop-ins match service and timer schemas' test_state_dir_dropins_match_unit_type
run_test 'systemd validation fails on stale installed runtime artifacts' test_systemd_validation_fails_on_stale_installed_runtime
run_test 'closed managed inventory reconciles only project-owned stale artifacts' test_closed_inventory_reconciles_only_project_owned_artifacts
run_test 'runtime lock preparation is verified, stable, and truthful' test_runtime_lock_preparation_is_verified_and_stable
[[ "$TESTS_RUN" -eq 9 ]] || fail "expected 9 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"

)

check_systemd_install_and_validation_contracts
check_systemd_timer_start_policy_behavior() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }

_extract_func(){
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^" f "\\(\\)" {p=1}
    p {
      print
      opens=gsub(/\{/,"{"); closes=gsub(/\}/,"}")
      depth += opens - closes
      if (depth == 0) exit
    }' "$file"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Behavior: systemd manual policy does not run enable --now, while auto does.
cat > "$TMP/systemd-policy-probe.sh" <<'EOF_PROBE'
set -euo pipefail
START_POLICY=manual; DRY_RUN=false; STARTUP_SERVICE=vaultwarden-startup.service
TIMERS=(vaultwarden-db-backup.timer vaultwarden-full-backup.timer)
log_info(){ :; }; log_warn(){ :; }; log_success(){ :; }
calls=()
_run(){ calls+=("$*"); }
probe(){
    _run systemctl enable "$STARTUP_SERVICE"
    local _enable_now=false timer
    case "$START_POLICY" in auto) _enable_now=true ;; ask) _enable_now=false ;; manual) _enable_now=false ;; esac
    if [[ "$_enable_now" == true ]]; then
      for timer in "${TIMERS[@]}"; do _run systemctl enable --now "$timer"; done
    else
      for timer in "${TIMERS[@]}"; do _run systemctl enable "$timer"; done
    fi
}
probe
printf '%s\n' "${calls[@]}" > "$PWD/calls.manual"
! grep -q -- 'enable --now' "$PWD/calls.manual"
START_POLICY=auto; calls=(); probe; printf '%s\n' "${calls[@]}" > "$PWD/calls.auto"
grep -q -- 'enable --now vaultwarden-db-backup.timer' "$PWD/calls.auto"
EOF_PROBE
(cd "$TMP" && bash systemd-policy-probe.sh) || fail 'systemd start policy behavior failed'

)

check_systemd_timer_start_policy_behavior

check_notification_features_preserve_systemd_contracts() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

unit_count="$(find "$ROOT/systemd" -maxdepth 1 -type f -name '*.service' | wc -l | tr -d ' ')"
timer_count="$(find "$ROOT/systemd" -maxdepth 1 -type f -name '*.timer' | wc -l | tr -d ' ')"
[[ "$unit_count" == "10" && "$timer_count" == "6" ]] \
    || fail "notification work added or removed a managed unit/timer (${unit_count} services, ${timer_count} timers)"
health_unit="$ROOT/systemd/vaultwarden-health.service"
grep -Fxq 'ReadWritePaths=/var/lib/vaultwarden /etc/vaultwarden /run/lock /run/vaultwarden-oci' "$health_unit" \
    || fail "health ReadWritePaths contract changed"
grep -Fxq 'SuccessExitStatus=0 1 3 75' "$health_unit" \
    || fail "health SuccessExitStatus contract changed"
grep -Fxq 'OnFailure=vaultwarden-notify-failure@%n.service' "$health_unit" \
    || fail "health OnFailure contract changed"
! grep -Fq '/etc/crowdsec' "$health_unit" \
    || fail "health unit sandbox was broadened for CrowdSec notification config"
grep -Fq 'utilities/maintenance-health.sh' "$ROOT/utilities/setup-systemd.sh" \
    || fail "installed runtime no longer carries the modified health script"
! grep -Fq 'vaultwarden-email' "$ROOT/utilities/setup-systemd.sh" \
    || fail "CrowdSec email notification added systemd installation behavior"

printf 'Notification features preserve systemd unit and sandbox contracts.\n'
)

check_notification_features_preserve_systemd_contracts

check_systemd_required_failure_propagation() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
cleanup(){
  if (( EUID == 0 )); then
    rm -rf "$TMP"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n rm -rf "$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT
fail(){ printf 'FAIL systemd failure propagation: %s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )) && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; }; then
  if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then fail 'passwordless sudo unavailable in GitHub Actions'; fi
  printf 'SKIP: systemd public failure propagation fixture requires root or passwordless sudo\n'
  exit 0
fi

root_run(){
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

REPO="$TMP/repo"
BIN="$TMP/bin"
REAL_INSTALL="$(type -P install)"
REAL_CHMOD="$(type -P chmod)"
REAL_RM="$(type -P rm)"
mkdir -p "$REPO" "$BIN"
(cd "$ROOT" && tar --exclude=.git --exclude='.migrate-volume.state' -cf - .) | (cd "$REPO" && tar -xf -)
cat >> "$REPO/lib/storage.sh" <<'EOF_STORAGE_TEST'
if [[ "${VW_TEST_ASSUME_STORAGE_READY:-false}" == "true" ]]; then
  check_project_state_ready(){ return 0; }
fi
EOF_STORAGE_TEST

cat > "$BIN/install" <<'EOF_INSTALL_WRAPPER'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "${MUTATION_LOG:?}"
dest="${!#}"
if [[ -n "${VW_FAIL_INSTALL_PATH:-}" && "$dest" == "$VW_FAIL_INSTALL_PATH" ]]; then
  exit 73
fi
exec "${REAL_INSTALL:?}" "$@"
EOF_INSTALL_WRAPPER
cat > "$BIN/chmod" <<'EOF_CHMOD_WRAPPER'
#!/usr/bin/env bash
printf 'chmod %s\n' "$*" >> "${MUTATION_LOG:?}"
for arg in "$@"; do
  if [[ -n "${VW_FAIL_CHMOD_PATH:-}" && "$arg" == "$VW_FAIL_CHMOD_PATH" ]]; then
    exit 74
  fi
done
exec "${REAL_CHMOD:?}" "$@"
EOF_CHMOD_WRAPPER
cat > "$BIN/rm" <<'EOF_RM_WRAPPER'
#!/usr/bin/env bash
printf 'rm %s\n' "$*" >> "${MUTATION_LOG:?}"
for arg in "$@"; do
  if [[ -n "${VW_FAIL_RM_PATH:-}" && "$arg" == "$VW_FAIL_RM_PATH" ]]; then
    exit 75
  fi
done
exec "${REAL_RM:?}" "$@"
EOF_RM_WRAPPER
cat > "$BIN/systemctl" <<'EOF_SYSTEMCTL_WRAPPER'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${MUTATION_LOG:?}"
if [[ -n "${VW_FAIL_SYSTEMCTL_COMMAND:-}" && "$*" == "$VW_FAIL_SYSTEMCTL_COMMAND" ]]; then
  exit 76
fi
unit="${!#}"
case "${1:-}" in
  is-active)
    case ",${VW_ACTIVE_UNITS:-}," in
      *",$unit,"*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  is-enabled)
    case ",${VW_ENABLED_UNITS:-}," in
      *",$unit,"*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  show) printf 'Fri 2099-01-01 00:00:00 UTC\n'; exit 0 ;;
  status) exit 0 ;;
  *) exit 0 ;;
esac
EOF_SYSTEMCTL_WRAPPER
cat > "$BIN/systemd-analyze" <<'EOF_ANALYZE_WRAPPER'
#!/usr/bin/env bash
exit 0
EOF_ANALYZE_WRAPPER
cat > "$BIN/mountpoint" <<'EOF_MOUNTPOINT_WRAPPER'
#!/usr/bin/env bash
exit 0
EOF_MOUNTPOINT_WRAPPER
chmod +x "$BIN/"*

CASE_DIR=""
ENV_DIR=""
UNIT_DIR=""
OPT_DIR=""
LOCK_DIR=""
MUTATION_LOG=""
RUN_RC=0
FAIL_INSTALL_PATH=""
FAIL_CHMOD_PATH=""
FAIL_RM_PATH=""
FAIL_SYSTEMCTL_COMMAND=""
ACTIVE_UNITS=""
ENABLED_UNITS=""

write_env(){
  local path="$1" state="$2" domain="$3"
  cat > "$path" <<EOF_ENV
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=
SOPS_AGE_KEY_FILE=$ENV_DIR/age-key.txt
DOMAIN=$domain
ADMIN_EMAIL=admin@$domain
CADDY_VERSION=2.11.4
EOF_ENV
  chmod 0600 "$path"
}

new_case(){
  local name="$1"
  CASE_DIR="$TMP/$name"
  ENV_DIR="$CASE_DIR/etc-vaultwarden"
  UNIT_DIR="$CASE_DIR/systemd"
  OPT_DIR="$CASE_DIR/opt"
  LOCK_DIR="$CASE_DIR/locks"
  MUTATION_LOG="$CASE_DIR/mutations.log"
  mkdir -p "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" "$CASE_DIR/state"
  : > "$MUTATION_LOG"
  write_env "$REPO/.env" "$CASE_DIR/state" "$name.example.invalid"
  write_env "$ENV_DIR/vaultwarden.env" "$CASE_DIR/old-state" "old-$name.example.invalid"
  FAIL_INSTALL_PATH=""
  FAIL_CHMOD_PATH=""
  FAIL_RM_PATH=""
  FAIL_SYSTEMCTL_COMMAND=""
  ACTIVE_UNITS=""
  ENABLED_UNITS=""
}

run_public(){
  local output="$1"; shift
  if root_run env \
      PATH="$BIN:$PATH" \
      MUTATION_LOG="$MUTATION_LOG" \
      REAL_INSTALL="$REAL_INSTALL" REAL_CHMOD="$REAL_CHMOD" REAL_RM="$REAL_RM" \
      VW_FAIL_INSTALL_PATH="$FAIL_INSTALL_PATH" \
      VW_FAIL_CHMOD_PATH="$FAIL_CHMOD_PATH" \
      VW_FAIL_RM_PATH="$FAIL_RM_PATH" \
      VW_FAIL_SYSTEMCTL_COMMAND="$FAIL_SYSTEMCTL_COMMAND" \
      VW_ACTIVE_UNITS="$ACTIVE_UNITS" \
      VW_ENABLED_UNITS="$ENABLED_UNITS" \
      SERVICE_USER=root SERVICE_GROUP=root \
      VW_TEST_ASSUME_STORAGE_READY=true \
      VW_CONFIG_INSTALLED_ENV_FILE="$ENV_DIR/vaultwarden.env" \
      VW_SYNC_ETC_DIR="$ENV_DIR" \
      VW_SYSTEMD_ENV_DIR="$ENV_DIR" \
      VW_SYSTEMD_UNIT_DEST_DIR="$UNIT_DIR" \
      VW_SYSTEMD_OPT_SCRIPTS_DIR="$OPT_DIR" \
      VW_SYSTEMD_RUNTIME_LOCK_DIR="$LOCK_DIR" \
      bash "$REPO/utilities/setup-systemd.sh" "$@" >"$output" 2>&1; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

assert_failed(){
  local output="$1" diagnostic="$2" path="$3"
  (( RUN_RC != 0 )) || fail "injected failure unexpectedly returned zero: $diagnostic"
  grep -Fq "$diagnostic" "$output" || { cat "$output" >&2; fail "missing actionable diagnostic: $diagnostic"; }
  grep -Fq "$path" "$output" || { cat "$output" >&2; fail "diagnostic omitted exact failed path: $path"; }
}

assert_no_install_success(){
  local output="$1"
  ! grep -Fq 'Installation complete.' "$output" || fail 'required install failure printed final success'
}

assert_no_enablement(){
  ! grep -Eq '^systemctl enable( |$)' "$MUTATION_LOG" \
    || { cat "$MUTATION_LOG" >&2; fail 'enablement followed an earlier required install failure'; }
}

assert_log_order(){
  local first="$1" second="$2"
  local first_line second_line
  first_line="$(grep -n -F -x "$first" "$MUTATION_LOG" | head -1 | cut -d: -f1 || true)"
  second_line="$(grep -n -F -x "$second" "$MUTATION_LOG" | head -1 | cut -d: -f1 || true)"
  [[ -n "$first_line" ]] || { cat "$MUTATION_LOG" >&2; fail "missing command log entry: $first"; }
  [[ -n "$second_line" ]] || { cat "$MUTATION_LOG" >&2; fail "missing command log entry: $second"; }
  (( first_line < second_line )) \
    || { cat "$MUTATION_LOG" >&2; fail "command order was not preserved: $first before $second"; }
}

snapshot_fixture(){
  local output="$1"
  {
    root_run find "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" \
      -printf 'meta|%p|%y|%m|%u|%g|%s|%T@|%l\n'
    while IFS= read -r -d '' path; do
      root_run sha256sum "$path" | sed 's/^/sha256|/'
    done < <(root_run find "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" -type f -print0)
  } | sort > "$output"
}

# 1. Managed script installation failure stops before any systemd mutation.
new_case install-script-failure
FAIL_INSTALL_PATH="$OPT_DIR/maintenance.sh"
output="$CASE_DIR/output.log"
run_public "$output" install --no-start
assert_failed "$output" 'Failed to install managed script:' "$FAIL_INSTALL_PATH"
assert_no_install_success "$output"
assert_no_enablement
! grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || fail 'daemon-reload followed managed script installation failure'
[[ ! -e "$FAIL_INSTALL_PATH" ]] || fail 'failed managed script path was unexpectedly published'

# 2. Managed unit chmod failure stops before daemon-reload and enablement.
new_case unit-chmod-failure
FAIL_CHMOD_PATH="$UNIT_DIR/vaultwarden-maintenance.service"
output="$CASE_DIR/output.log"
run_public "$output" install --no-start
assert_failed "$output" 'Failed to set managed unit mode:' "$FAIL_CHMOD_PATH"
assert_no_install_success "$output"
assert_no_enablement
! grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || fail 'daemon-reload followed managed unit chmod failure'
! grep -Fq 'Installed unit: vaultwarden-maintenance.service' "$output" \
  || fail 'failed unit chmod printed false unit-installed success'

# 3. daemon-reload failure prevents all enablement.
new_case daemon-reload-failure
FAIL_SYSTEMCTL_COMMAND='daemon-reload'
output="$CASE_DIR/output.log"
run_public "$output" install --no-start
(( RUN_RC != 0 )) || fail 'daemon-reload failure unexpectedly returned zero'
grep -Fq 'Failed to reload systemd after installing managed units.' "$output" \
  || { cat "$output" >&2; fail 'daemon-reload failure lacked actionable diagnostic'; }
assert_no_install_success "$output"
assert_no_enablement

# 4. Startup-service enable failure prevents timer enablement.
new_case startup-enable-failure
FAIL_SYSTEMCTL_COMMAND='enable vaultwarden-startup.service'
output="$CASE_DIR/output.log"
run_public "$output" install --no-start
(( RUN_RC != 0 )) || fail 'startup-service enable failure unexpectedly returned zero'
grep -Fq 'Failed to enable startup service: vaultwarden-startup.service' "$output" \
  || { cat "$output" >&2; fail 'startup-service enable failure lacked exact diagnostic'; }
assert_no_install_success "$output"
! grep -Eq '^systemctl enable vaultwarden-.*\.timer$' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'timer enablement began after startup-service enable failure'; }

# 5. A timer enable failure prevents false success and later timer actions.
new_case timer-enable-failure
failed_timer='vaultwarden-db-backup.timer'
later_timer='vaultwarden-full-backup.timer'
FAIL_SYSTEMCTL_COMMAND="enable $failed_timer"
output="$CASE_DIR/output.log"
run_public "$output" install --no-start
(( RUN_RC != 0 )) || fail 'timer enable failure unexpectedly returned zero'
grep -Fq "Failed to enable timer: $failed_timer" "$output" \
  || { cat "$output" >&2; fail 'timer enable failure lacked exact diagnostic'; }
assert_no_install_success "$output"
! grep -Fq "Enabled: $failed_timer" "$output" || fail 'failed timer printed false enabled success'
! grep -Fxq "systemctl enable $later_timer" "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'later timer enablement followed required timer failure'; }

# 6. Managed unit removal failure is observable and stops final success.
new_case remove-unit-failure
failed_remove="$UNIT_DIR/vaultwarden-maintenance.service"
printf '[Unit]\nDescription=fixture\n' > "$failed_remove"
FAIL_RM_PATH="$failed_remove"
output="$CASE_DIR/output.log"
run_public "$output" remove
assert_failed "$output" 'Failed to remove managed unit:' "$failed_remove"
[[ -f "$failed_remove" ]] || fail 'failed managed removal path did not remain observable'
! grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || fail 'managed removal failure printed final success'
! grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || fail 'removal daemon-reload followed an earlier required removal failure'

# 7. Removal-time daemon-reload failure prevents final removal success.
new_case remove-reload-failure
FAIL_SYSTEMCTL_COMMAND='daemon-reload'
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC != 0 )) || fail 'removal daemon-reload failure unexpectedly returned zero'
grep -Fq 'Failed to reload systemd after removing managed units.' "$output" \
  || { cat "$output" >&2; fail 'removal daemon-reload failure lacked actionable diagnostic'; }
! grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || fail 'removal daemon-reload failure printed final success'

# 8. An active but disabled timer is stopped before its unit file is removed.
new_case remove-active-disabled-timer
active_timer='vaultwarden-maintenance.timer'
active_timer_path="$UNIT_DIR/$active_timer"
printf '[Unit]\nDescription=active disabled fixture\n' > "$active_timer_path"
ACTIVE_UNITS="$active_timer"
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC == 0 )) || { cat "$output" >&2; fail 'active but disabled timer removal returned nonzero'; }
grep -Fxq "systemctl disable --now $active_timer" "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'active but disabled timer was not stopped'; }
assert_log_order "systemctl is-active $active_timer" "systemctl is-enabled $active_timer"
assert_log_order "systemctl is-enabled $active_timer" "systemctl disable --now $active_timer"
assert_log_order "systemctl disable --now $active_timer" "rm -f $active_timer_path"
[[ ! -e "$active_timer_path" ]] || fail 'active but disabled timer file remained after successful disable'
grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || { cat "$output" >&2; fail 'active but disabled timer removal omitted final success'; }

# 9. An enabled but inactive timer is disabled before removal.
new_case remove-enabled-inactive-timer
enabled_timer='vaultwarden-db-backup.timer'
enabled_timer_path="$UNIT_DIR/$enabled_timer"
printf '[Unit]\nDescription=enabled inactive fixture\n' > "$enabled_timer_path"
ENABLED_UNITS="$enabled_timer"
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC == 0 )) || { cat "$output" >&2; fail 'enabled but inactive timer removal returned nonzero'; }
grep -Fxq "systemctl disable --now $enabled_timer" "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'enabled but inactive timer was not disabled'; }
assert_log_order "systemctl is-active $enabled_timer" "systemctl is-enabled $enabled_timer"
assert_log_order "systemctl is-enabled $enabled_timer" "systemctl disable --now $enabled_timer"
assert_log_order "systemctl disable --now $enabled_timer" "rm -f $enabled_timer_path"
[[ ! -e "$enabled_timer_path" ]] || fail 'enabled but inactive timer file remained after successful disable'
grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || { cat "$output" >&2; fail 'enabled but inactive timer removal omitted final success'; }

# 10. A timer disable failure stops before any managed unit removal.
new_case remove-timer-disable-failure
failed_disable_timer='vaultwarden-full-backup.timer'
failed_disable_path="$UNIT_DIR/$failed_disable_timer"
later_remove_path="$UNIT_DIR/vaultwarden-maintenance.service"
printf '[Unit]\nDescription=failed timer fixture\n' > "$failed_disable_path"
printf '[Unit]\nDescription=must remain fixture\n' > "$later_remove_path"
ACTIVE_UNITS="$failed_disable_timer"
FAIL_SYSTEMCTL_COMMAND="disable --now $failed_disable_timer"
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC != 0 )) || fail 'timer disable failure unexpectedly returned zero'
grep -Fq "Failed to disable and stop managed timer: $failed_disable_timer" "$output" \
  || { cat "$output" >&2; fail 'timer disable failure omitted the exact timer diagnostic'; }
grep -Fxq "systemctl disable --now $failed_disable_timer" "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'timer disable failure command was not attempted'; }
[[ -f "$failed_disable_path" ]] || fail 'failed timer unit file was removed'
[[ -f "$later_remove_path" ]] || fail 'later managed unit file was removed after timer disable failure'
! grep -Eq '^rm ' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'managed unit removal followed timer disable failure'; }
! grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || fail 'removal daemon-reload followed timer disable failure'
! grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || fail 'timer disable failure printed final removal success'

# 11. An active startup-service disable failure is fatal before removal.
new_case remove-startup-disable-failure
startup_path="$UNIT_DIR/vaultwarden-startup.service"
later_startup_remove_path="$UNIT_DIR/vaultwarden-health.service"
printf '[Unit]\nDescription=startup fixture\n' > "$startup_path"
printf '[Unit]\nDescription=must remain fixture\n' > "$later_startup_remove_path"
ACTIVE_UNITS='vaultwarden-startup.service'
FAIL_SYSTEMCTL_COMMAND='disable --now vaultwarden-startup.service'
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC != 0 )) || fail 'startup-service disable failure unexpectedly returned zero'
grep -Fq 'Failed to disable and stop startup service: vaultwarden-startup.service' "$output" \
  || { cat "$output" >&2; fail 'startup-service disable failure omitted the exact diagnostic'; }
grep -Fxq 'systemctl disable --now vaultwarden-startup.service' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'startup-service disable failure command was not attempted'; }
[[ -f "$startup_path" ]] || fail 'failed startup-service unit file was removed'
[[ -f "$later_startup_remove_path" ]] || fail 'later managed unit file was removed after startup-service disable failure'
! grep -Eq '^rm ' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'managed unit removal followed startup-service disable failure'; }
! grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || fail 'removal daemon-reload followed startup-service disable failure'
! grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || fail 'startup-service disable failure printed final removal success'

# 12. Already inactive and disabled units are removed without disable calls.
new_case remove-already-inactive-disabled
inactive_timer_path="$UNIT_DIR/vaultwarden-health.timer"
inactive_startup_path="$UNIT_DIR/vaultwarden-startup.service"
inactive_service_path="$UNIT_DIR/vaultwarden-health.service"
printf '[Unit]\nDescription=inactive timer fixture\n' > "$inactive_timer_path"
printf '[Unit]\nDescription=inactive startup fixture\n' > "$inactive_startup_path"
printf '[Unit]\nDescription=inactive service fixture\n' > "$inactive_service_path"
output="$CASE_DIR/output.log"
run_public "$output" remove
(( RUN_RC == 0 )) || { cat "$output" >&2; fail 'inactive and disabled removal returned nonzero'; }
! grep -Eq '^systemctl disable --now ' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'inactive and disabled unit triggered disable --now'; }
[[ ! -e "$inactive_timer_path" && ! -e "$inactive_startup_path" && ! -e "$inactive_service_path" ]] \
  || fail 'inactive and disabled managed unit removal did not complete'
grep -Fxq 'systemctl daemon-reload' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'inactive and disabled removal omitted daemon-reload'; }
grep -Fq 'All timer units removed and daemon reloaded.' "$output" \
  || { cat "$output" >&2; fail 'inactive and disabled removal omitted final success'; }

# 13. Removal dry-run reports active units without mutating state.
new_case remove-active-dry-run
dry_timer='vaultwarden-firewall-update.timer'
dry_timer_path="$UNIT_DIR/$dry_timer"
dry_startup_path="$UNIT_DIR/vaultwarden-startup.service"
printf '[Unit]\nDescription=dry timer fixture\n' > "$dry_timer_path"
printf '[Unit]\nDescription=dry startup fixture\n' > "$dry_startup_path"
ACTIVE_UNITS="$dry_timer,vaultwarden-startup.service"
before="$CASE_DIR/remove-before.snapshot"
after="$CASE_DIR/remove-after.snapshot"
snapshot_fixture "$before"
output="$CASE_DIR/output.log"
run_public "$output" remove --dry-run
(( RUN_RC == 0 )) || { cat "$output" >&2; fail 'active removal dry-run returned nonzero'; }
snapshot_fixture "$after"
cmp -s "$before" "$after" || { diff -u "$before" "$after" >&2 || true; fail 'removal dry-run changed fixture contents or metadata'; }
grep -Fq "[DRY RUN] systemctl disable --now $dry_timer" "$output" \
  || { cat "$output" >&2; fail 'removal dry-run omitted active timer disable action'; }
grep -Fq '[DRY RUN] systemctl disable --now vaultwarden-startup.service' "$output" \
  || { cat "$output" >&2; fail 'removal dry-run omitted active startup-service disable action'; }
[[ -f "$dry_timer_path" && -f "$dry_startup_path" ]] \
  || fail 'removal dry-run deleted a managed unit file'
! grep -Eq '^rm ' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'removal dry-run invoked the rm mutation wrapper'; }
! grep -Eq '^systemctl (disable --now|daemon-reload)( |$)' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'removal dry-run invoked a systemctl mutation'; }

# 14. Armed installation mutation failures remain irrelevant during a truthful dry-run.
new_case dry-run-failure-mocks
FAIL_INSTALL_PATH="$OPT_DIR/maintenance.sh"
FAIL_CHMOD_PATH="$UNIT_DIR/vaultwarden-maintenance.service"
FAIL_RM_PATH="$UNIT_DIR/vaultwarden-maintenance.service"
FAIL_SYSTEMCTL_COMMAND='daemon-reload'
before="$CASE_DIR/before.snapshot"
after="$CASE_DIR/after.snapshot"
root_run find "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" -printf '%p|%y|%m|%l\n' | sort > "$before"
output="$CASE_DIR/output.log"
run_public "$output" install --dry-run --no-start
(( RUN_RC == 0 )) || { cat "$output" >&2; fail 'dry-run required successful mutation mocks'; }
root_run find "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" -printf '%p|%y|%m|%l\n' | sort > "$after"
cmp -s "$before" "$after" || fail 'dry-run mutated fixture paths while failures were armed'
grep -Fq '[DRY RUN] Intended post-sync source:' "$output" \
  || fail 'dry-run omitted intended post-sync configuration'
! grep -Eq '^(install|chmod|rm) ' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'dry-run invoked a filesystem mutation wrapper'; }
! grep -Eq '^systemctl (daemon-reload|enable|disable|reset-failed)( |$)' "$MUTATION_LOG" \
  || { cat "$MUTATION_LOG" >&2; fail 'dry-run invoked a systemctl mutation'; }

# Supplement the public failure cases with a direct dispatch shape assertion.
main_body="$(sed -n '/^main() {/,/^}/p' "$ROOT/utilities/setup-systemd.sh")"
grep -Eq '^[[:space:]]+install_units[[:space:]]*$' <<< "$main_body" \
  || fail 'public main does not directly invoke install_units'
grep -Eq '^[[:space:]]+remove_units[[:space:]]*$' <<< "$main_body" \
  || fail 'public main does not directly invoke remove_units'
! grep -Eq '(install_units|remove_units)[[:space:]]*(&&|\|\|)' <<< "$main_body" \
  || fail 'public main still invokes install/remove in an errexit-suppressing list'

printf 'PASS setup-systemd public failures stop without false success or later mutations\n'
printf 'PASS setup-systemd removal handles active state and disable failures fail-closed\n'
)
check_systemd_required_failure_propagation

check_systemd_post_sync_snapshot_contract() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
DEVICE_A="/dev/vw-pr280-a-$$"
DEVICE_B="/dev/vw-pr280-b-$$"
cleanup(){
  if (( EUID == 0 )); then
    rm -rf "$TMP"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n rm -rf "$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT
fail(){ printf 'FAIL systemd A-to-B snapshot: %s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )) && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; }; then
  if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then fail 'passwordless sudo unavailable in GitHub Actions'; fi
  printf 'SKIP: systemd A-to-B public install fixture requires root or passwordless sudo\n'
  exit 0
fi

root_run(){
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}
REPO="$TMP/repo"
mkdir -p "$REPO"
(cd "$ROOT" && tar --exclude=.git --exclude='.migrate-volume.state' -cf - .) | (cd "$REPO" && tar -xf -)
# The transition contract under test is systemd inventory/rendering. Keep the
# public env-edit sync boundary, but make its attached-volume readiness probe a
# fixture-local success so the test does not require a privileged block device.
cat >> "$REPO/lib/storage.sh" <<'EOF_STORAGE_TEST'
if [[ "${VW_TEST_ASSUME_STORAGE_READY:-false}" == "true" ]]; then
  check_project_state_ready(){ return 0; }
fi
EOF_STORAGE_TEST
ENV_DIR="$TMP/etc-vaultwarden"
UNIT_DIR="$TMP/systemd"
OPT_DIR="$TMP/opt"
LOCK_DIR="$TMP/locks"
BOOT_A="$TMP/boot-a"
BOOT_B="$TMP/boot-b"
MOUNT_A="$TMP/mount-a"
MOUNT_B="$TMP/mount-b"
BIN="$TMP/bin"
mkdir -p "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" "$BOOT_A" "$BOOT_B" "$MOUNT_A" "$MOUNT_B" "$BIN"
: > "$MOUNT_A/.vw-data-volume"
: > "$MOUNT_B/.vw-data-volume"

DROPIN_UNITS=(
  vaultwarden-maintenance.service
  vaultwarden-db-backup.service
  vaultwarden-full-backup.service
  vaultwarden-health.service
  vaultwarden-dns-update.service
  vaultwarden-firewall-update.service
  vaultwarden-notify-failure.service
  vaultwarden-notify-failure@.service
  vaultwarden-maintenance.timer
  vaultwarden-db-backup.timer
  vaultwarden-full-backup.timer
  vaultwarden-health.timer
  vaultwarden-dns-update.timer
  vaultwarden-firewall-update.timer
)

write_env(){
  local path="$1" state="$2" device="$3" mount="$4" domain="$5"
  local optional_key="${6:-}" sops_key="${7:-}"
  cat > "$path" <<EOF_ENV
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=$device
DATA_VOLUME_MOUNT=$mount
SOPS_AGE_KEY_FILE=$sops_key
DOMAIN=$domain
ADMIN_EMAIL=admin@$domain
CADDY_VERSION=2.11.4
EOF_ENV
  if [[ -n "$optional_key" ]]; then
    printf 'A_ONLY_TRANSITION_KEY=%s\n' "$optional_key" >> "$path"
  fi
  chmod 0600 "$path"
}

write_env "$ENV_DIR/vaultwarden.env" "$BOOT_A" "" "" "a.example.invalid" "legacy-only" "$ENV_DIR/age-key.txt"
write_env "$REPO/.env" "$BOOT_B" "" "" "b.example.invalid"

cat > "$BIN/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
printf 'cmd=%s|A_ONLY=%s|STATE=%s|DEVICE=%s|MOUNT=%s\n' \
  "$*" "${A_ONLY_TRANSITION_KEY-<unset>}" "${PROJECT_STATE_DIR-<unset>}" \
  "${DATA_VOLUME_DEVICE-<unset>}" "${DATA_VOLUME_MOUNT-<unset>}" \
  >> "${SYSTEMCTL_LOG:?}"
case "${1:-}" in
  is-active|is-enabled) exit 0 ;;
  show) printf 'Fri 2099-01-01 00:00:00 UTC\n'; exit 0 ;;
  status) exit 0 ;;
  *) exit 0 ;;
esac
EOF_SYSTEMCTL
cat > "$BIN/systemd-analyze" <<'EOF_ANALYZE'
#!/usr/bin/env bash
exit 0
EOF_ANALYZE
cat > "$BIN/mountpoint" <<'EOF_MOUNTPOINT'
#!/usr/bin/env bash
exit 0
EOF_MOUNTPOINT
chmod +x "$BIN/"*
: > "$TMP/systemctl.log"

run_setup(){
  local action="$1"; shift
  local -a cmd=(env PATH="$BIN:$PATH" SYSTEMCTL_LOG="$TMP/systemctl.log" SERVICE_USER=root SERVICE_GROUP=root
    VW_TEST_ASSUME_STORAGE_READY=true
    VW_CONFIG_INSTALLED_ENV_FILE="$ENV_DIR/vaultwarden.env" VW_SYNC_ETC_DIR="$ENV_DIR"
    VW_SYSTEMD_ENV_DIR="$ENV_DIR" VW_SYSTEMD_UNIT_DEST_DIR="$UNIT_DIR"
    VW_SYSTEMD_OPT_SCRIPTS_DIR="$OPT_DIR" VW_SYSTEMD_RUNTIME_LOCK_DIR="$LOCK_DIR"
    bash "$REPO/utilities/setup-systemd.sh" "$action" "$@")
  root_run "${cmd[@]}"
}

read_fixture_file(){
  local path="$1"
  if [[ -r "$path" ]]; then cat "$path"; else root_run cat "$path"; fi
}

snapshot_fixture(){
  local output="$1"
  local -a roots=("$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" "$LOCK_DIR" "$BOOT_A" "$BOOT_B" "$MOUNT_A" "$MOUNT_B")
  {
    root_run find "${roots[@]}" -printf '%p|%y|%m|%l\n' | sort
    root_run find "${roots[@]}" -type f -print0 | sort -z | root_run xargs -0 -r sha256sum
  } > "$output"
}

ensure_fixture_key(){
  if (( EUID == 0 )); then
    printf 'fixture-key\n' > "$ENV_DIR/age-key.txt"
    chmod 0600 "$ENV_DIR/age-key.txt"
    chown root:root "$ENV_DIR/age-key.txt"
  else
    printf 'fixture-key\n' | sudo -n tee "$ENV_DIR/age-key.txt" >/dev/null
    sudo -n "$(type -P chmod)" 0600 "$ENV_DIR/age-key.txt"
    sudo -n "$(type -P chown)" root:root "$ENV_DIR/age-key.txt"
  fi
}

assert_boot_only(){
  local unit file
  for unit in "${DROPIN_UNITS[@]}"; do
    file="$UNIT_DIR/${unit}.d/10-state-dir.conf"
    [[ ! -e "$file" ]] || fail "boot-only install retained generated state-dir drop-in: $file"
  done
}

assert_separate_volume(){
  local mount="$1" old_value="${2:-}" unit file mount_unit
  mount_unit="$(systemd-escape --path --suffix=mount "$mount")"
  for unit in "${DROPIN_UNITS[@]}"; do
    file="$UNIT_DIR/${unit}.d/10-state-dir.conf"
    [[ -f "$file" ]] || fail "missing state-dir drop-in for $unit"
    grep -Fq "After=$mount_unit" "$file" || fail "drop-in for $unit does not use $mount"
    if [[ "$unit" == *.service ]]; then
      grep -Fq "ReadWritePaths=$mount" "$file" || fail "service drop-in for $unit lacks $mount"
    fi
    if [[ -n "$old_value" ]]; then
      ! grep -Fq "$old_value" "$file" || fail "drop-in for $unit retained old value $old_value"
    fi
  done
}

assert_preserved_operator_state(){
  [[ -f "$UNIT_DIR/vaultwarden-health.service.d/90-operator.conf" ]] \
    || fail 'operator drop-in was removed'
  [[ -f "$UNIT_DIR/third-party.service.d/10-state-dir.conf" ]] \
    || fail 'third-party drop-in was removed'
  [[ -L "$UNIT_DIR/timers.target.wants/external.timer" ]] \
    || fail 'ordinary wants link was removed'
}

assert_generated_value_absent(){
  local value="$1"
  [[ -n "$value" ]] || return 0
  if root_run grep -R -F -- "$value" "$ENV_DIR" "$UNIT_DIR" "$OPT_DIR" >/dev/null 2>&1; then
    fail "generated runtime artifact retained obsolete value: $value"
  fi
}

validate_and_check_idempotence(){
  local label="$1"
  local before="$TMP/${label}.before" after="$TMP/${label}.after"
  ensure_fixture_key
  run_setup validate >"$TMP/${label}.validate.out" 2>&1 \
    || { cat "$TMP/${label}.validate.out" >&2; fail "$label immediate validation failed"; }
  snapshot_fixture "$before"
  run_setup install --no-start >"$TMP/${label}.second.out" 2>&1 \
    || { cat "$TMP/${label}.second.out" >&2; fail "$label second install failed"; }
  snapshot_fixture "$after"
  cmp -s "$before" "$after" || fail "$label second installation was not content-idempotent"
  assert_preserved_operator_state
}

run_dry_transition(){
  local label="$1" old_value="$2" new_value="$3" expected="$4"
  local before="$TMP/${label}.dry.before" after="$TMP/${label}.dry.after"
  local output="$TMP/${label}.dry.out"
  snapshot_fixture "$before"
  run_setup install --dry-run --no-start >"$output" 2>&1 \
    || { cat "$output" >&2; fail "$label dry-run failed"; }
  snapshot_fixture "$after"
  cmp -s "$before" "$after" || fail "$label dry-run mutated installed state"
  grep -Fq '[DRY RUN] Current runtime source:' "$output" || fail "$label dry-run omitted current source"
  grep -Fq '[DRY RUN] Intended post-sync source:' "$output" || fail "$label dry-run omitted intended source"
  if [[ -n "$old_value" ]]; then
    ! grep -Fq "PROJECT_STATE_DIR=$old_value" "$output" || fail "$label dry-run reported old state as intended"
    ! grep -Fq "ReadWritePaths=$old_value" "$output" || fail "$label dry-run reported old mount as intended"
  fi
  if [[ "$expected" == boot ]]; then
    local unit
    for unit in "${DROPIN_UNITS[@]}"; do
      grep -Fq "$UNIT_DIR/${unit}.d/10-state-dir.conf" "$output" \
        || fail "$label dry-run omitted stale drop-in for $unit"
    done
  else
    grep -Fq "DATA_VOLUME_MOUNT=$new_value" "$output" \
      || fail "$label dry-run did not report intended mount $new_value"
    local unit
    for unit in "${DROPIN_UNITS[@]}"; do
      grep -Fq "Would write state-dir drop-in: $UNIT_DIR/${unit}.d/10-state-dir.conf" "$output" \
        || fail "$label dry-run omitted new drop-in for $unit"
    done
  fi
}

mkdir -p "$UNIT_DIR/vaultwarden-health.service.d" "$UNIT_DIR/third-party.service.d" "$UNIT_DIR/timers.target.wants"
printf '[Service]\nEnvironment=OPERATOR_PRESERVED=yes\n' > "$UNIT_DIR/vaultwarden-health.service.d/90-operator.conf"
printf '# third-party reserved-name file\n' > "$UNIT_DIR/third-party.service.d/10-state-dir.conf"
ln -s /tmp/external.timer "$UNIT_DIR/timers.target.wants/external.timer"

# 1. Boot-only A -> boot-only B, including removal of an A-only variable.
run_setup install --no-start >"$TMP/boot-to-boot.out" 2>&1 \
  || { cat "$TMP/boot-to-boot.out" >&2; fail 'boot-only A-to-B install failed'; }
read_fixture_file "$ENV_DIR/vaultwarden.env" | grep -Fxq "PROJECT_STATE_DIR=$BOOT_B" \
  || fail 'boot-only A-to-B sync did not select B'
! grep -Fq "$BOOT_A" "$UNIT_DIR/vaultwarden-startup.service" \
  || fail 'boot-only A-to-B startup unit retained A'
! grep -Fq 'A_ONLY=legacy-only' "$TMP/systemctl.log" \
  || fail 'A-only variable survived the post-sync reload'
! read_fixture_file "$ENV_DIR/vaultwarden.env" | grep -Fq 'A_ONLY_TRANSITION_KEY=' \
  || fail 'A-only variable survived in the synchronized environment'
assert_generated_value_absent "$BOOT_A"
assert_generated_value_absent 'legacy-only'
assert_boot_only
validate_and_check_idempotence boot-to-boot

# 2. Boot-only -> separate volume creates every B drop-in truthfully.
write_env "$REPO/.env" "$MOUNT_A" "$DEVICE_A" "$MOUNT_A" "volume-a.example.invalid"
run_dry_transition boot-to-volume "$BOOT_B" "$MOUNT_A" volume
run_setup install --no-start >"$TMP/boot-to-volume.out" 2>&1 \
  || { cat "$TMP/boot-to-volume.out" >&2; fail 'boot-only to separate-volume install failed'; }
assert_separate_volume "$MOUNT_A" "$BOOT_B"
assert_generated_value_absent "$BOOT_B"
validate_and_check_idempotence boot-to-volume

# 3. Separate volume -> boot-only removes every generated state-dir drop-in.
write_env "$REPO/.env" "$BOOT_B" "" "" "boot-b.example.invalid"
local_reload_before="$(grep -c 'cmd=daemon-reload' "$TMP/systemctl.log" || true)"
run_dry_transition volume-to-boot "$MOUNT_A" "$BOOT_B" boot
run_setup install --no-start >"$TMP/volume-to-boot.out" 2>&1 \
  || { cat "$TMP/volume-to-boot.out" >&2; fail 'separate-volume to boot-only install failed'; }
assert_boot_only
assert_generated_value_absent "$MOUNT_A"
local_reload_after="$(grep -c 'cmd=daemon-reload' "$TMP/systemctl.log" || true)"
(( local_reload_after >= local_reload_before + 2 )) \
  || fail 'daemon-reload did not follow stale drop-in reconciliation'
validate_and_check_idempotence volume-to-boot

# 4. Boot-only -> separate volume B creates all expected B content.
write_env "$REPO/.env" "$MOUNT_B" "$DEVICE_B" "$MOUNT_B" "volume-b.example.invalid"
run_dry_transition boot-to-volume-b "$BOOT_B" "$MOUNT_B" volume
run_setup install --no-start >"$TMP/boot-to-volume-b.out" 2>&1 \
  || { cat "$TMP/boot-to-volume-b.out" >&2; fail 'boot-only to separate-volume B install failed'; }
assert_separate_volume "$MOUNT_B" "$BOOT_B"
assert_generated_value_absent "$BOOT_B"
validate_and_check_idempotence boot-to-volume-b

# 5. Separate-volume mount B -> mount A rewrites every generated file.
write_env "$REPO/.env" "$MOUNT_A" "$DEVICE_A" "$MOUNT_A" "volume-a2.example.invalid"
run_setup install --no-start >"$TMP/volume-to-volume.out" 2>&1 \
  || { cat "$TMP/volume-to-volume.out" >&2; fail 'separate-volume mount transition failed'; }
assert_separate_volume "$MOUNT_A" "$MOUNT_B"
assert_generated_value_absent "$MOUNT_B"
validate_and_check_idempotence volume-to-volume

printf 'PASS setup-systemd public install covers boot-only and separate-volume transitions\n'
)
check_systemd_post_sync_snapshot_contract
