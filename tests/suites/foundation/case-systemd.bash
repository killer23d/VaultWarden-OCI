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
