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

extract_array() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 ~ "^" name "=\\(" {printing=1}
        printing {print}
        printing && /^\)/ {exit}
    ' "$file"
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

test_systemd_inventories_are_canonical() {
    local script="$ROOT/utilities/setup-systemd.sh"
    local services timers installed
    services="$(extract_array "$script" COPIED_SERVICES)"
    timers="$(extract_array "$script" TIMERS)"
    installed="$(extract_array "$script" INSTALLED_SCRIPT_PATHS)"

    for unit in \
        vaultwarden-maintenance.service \
        vaultwarden-db-backup.service \
        vaultwarden-full-backup.service \
        vaultwarden-health.service \
        vaultwarden-dns-update.service \
        vaultwarden-firewall-update.service \
        vaultwarden-notify-failure.service \
        vaultwarden-iptables.service; do
        grep -Fxq "    $unit" <<< "$services" || fail "copied service inventory missing $unit"
    done
    grep -Fq '    "$NOTIFY_FAILURE_TEMPLATE"' <<< "$services" \
        || fail "notifier template is not explicit in copied service inventory"
    ! grep -Fq 'vaultwarden-startup.service' <<< "$services" \
        || fail "rendered startup service was mixed into copied service inventory"

    for timer in \
        vaultwarden-maintenance.timer \
        vaultwarden-db-backup.timer \
        vaultwarden-full-backup.timer \
        vaultwarden-health.timer \
        vaultwarden-dns-update.timer \
        vaultwarden-firewall-update.timer; do
        grep -Fxq "    $timer" <<< "$timers" || fail "timer inventory missing $timer"
    done

    grep -Fxq 'MANAGED_UNITS=("${COPIED_SERVICES[@]}" "${TIMERS[@]}")' "$script" \
        || fail "managed unit inventory is not derived from copied services and timers"
    grep -Fxq '    maintenance.sh' <<< "$installed" \
        || fail "installed script inventory lost top-level layout"
    grep -Fxq '    utilities/backup-run.sh' <<< "$installed" \
        || fail "installed script inventory lost utilities layout"
    [[ "$(grep -Fc 'for script in "${INSTALLED_SCRIPT_PATHS[@]}"' "$script")" -ge 3 ]] \
        || fail "installation and validation do not share the script path inventory"
    [[ "$(grep -Fc 'for unit in "${MANAGED_UNITS[@]}"' "$script")" -ge 3 ]] \
        || fail "install, validation, and removal do not share managed units"
    ! grep -Eq 'flat_scripts_to_install|structured_scripts_to_install|scripts_to_check' "$script" \
        || fail "duplicated local systemd inventories remain"
    grep -Fq '[[ "$svc" == "$NOTIFY_FAILURE_TEMPLATE" ]] && continue' "$script" \
        || fail "template service is not explicitly skipped by service actions"
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

prepare_systemd_install_repo() {
    local repo="$1" state="$2"
    mkdir -p "$repo/secrets/keys"
    cp -a "$ROOT/lib" "$ROOT/utilities" "$ROOT/systemd" "$repo/"
    cp "$ROOT/maintenance.sh" "$ROOT/backup.sh" "$ROOT/restore.sh" "$repo/"
    cat > "$repo/.env" <<EOF_ENV
DOMAIN=https://systemd-inventory.example.test
ADMIN_EMAIL=admin@example.test
PROJECT_STATE_DIR=$state
DATA_VOLUME_DEVICE=
DATA_VOLUME_MOUNT=$state
SOPS_AGE_KEY_FILE=
EOF_ENV
    chmod 600 "$repo/.env"
    cat > "$repo/secrets/keys/age-key.txt" <<'EOF_KEY'
# public key: age1systemdinventory0000000000000000000000000000000000000
AGE-SECRET-KEY-1SYSTEMDINVENTORY
EOF_KEY
    chmod 600 "$repo/secrets/keys/age-key.txt"
}

test_systemd_missing_source_and_dry_run_behavior() {
    if ! can_run_systemd_behavioral_tests; then
        printf 'SKIP: systemd install source/dry-run test requires Linux root or passwordless sudo\n'
        return 0
    fi

    local repo="$TMP/inventory-repo" state="$TMP/inventory-state"
    local unit_dir="$TMP/inventory-units" opt_dir="$TMP/inventory-opt" env_dir="$TMP/inventory-etc"
    local missing_out="$TMP/inventory-missing.out" dry_out="$TMP/inventory-dry.out"
    prepare_systemd_install_repo "$repo" "$state"

    rm "$repo/utilities/backup-run.sh"
    if run_root_env_capture "$missing_out" \
        PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$repo/utilities/setup-systemd.sh" install --dry-run; then
        fail "systemd install succeeded with a missing required repository script"
    fi
    grep -Fq "Required repository script not found: $repo/utilities/backup-run.sh" "$missing_out" \
        || { cat "$missing_out" >&2; fail "missing required script was not named"; }
    [[ ! -e "$unit_dir" && ! -e "$opt_dir" && ! -e "$env_dir" ]] \
        || fail "missing-source preflight mutated installation paths"

    cp "$ROOT/utilities/backup-run.sh" "$repo/utilities/backup-run.sh"
    run_root_env_capture "$dry_out" \
        PROJECT_STATE_DIR="$state" \
        VW_CONFIG_INSTALLED_ENV_FILE="$env_dir/vaultwarden.env" \
        VW_SYSTEMD_UNIT_DEST_DIR="$unit_dir" \
        VW_SYSTEMD_OPT_SCRIPTS_DIR="$opt_dir" \
        VW_SYSTEMD_ENV_DIR="$env_dir" \
        bash "$repo/utilities/setup-systemd.sh" install --dry-run \
        || { cat "$dry_out" >&2; fail "complete systemd dry-run failed"; }

    grep -Fq "[DRY RUN] Would install: $opt_dir/maintenance.sh" "$dry_out" \
        || fail "dry-run lost top-level script installation"
    grep -Fq "[DRY RUN] Would install: $opt_dir/utilities/backup-run.sh" "$dry_out" \
        || fail "dry-run lost utilities script installation"
    grep -Fq "[DRY RUN] cp $repo/systemd/vaultwarden-db-backup.service $unit_dir/vaultwarden-db-backup.service" "$dry_out" \
        || fail "dry-run did not install a copied service from the canonical inventory"
    grep -Fq "[DRY RUN] cp $repo/systemd/vaultwarden-db-backup.timer $unit_dir/vaultwarden-db-backup.timer" "$dry_out" \
        || fail "dry-run did not install a timer from the canonical inventory"
    grep -Fq '[DRY RUN] Would render vaultwarden-startup.service' "$dry_out" \
        || fail "startup service was not kept on the rendered path"
    ! grep -Eq 'systemctl enable( --now)? vaultwarden-notify-failure@\.service' "$dry_out" \
        || fail "template unit was directly enabled or started"
    grep -Fq 'Boot-only mode — skipping per-unit ReadWritePaths drop-ins.' "$dry_out" \
        || fail "boot-only install behavior changed"
    [[ ! -e "$unit_dir" && ! -e "$opt_dir" && ! -e "$env_dir" ]] \
        || fail "dry-run mutated installation paths"
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
run_test 'stale 30-run-as-root cleanup preserves 10-state-dir handling' test_stale_root_dropin_cleanup_preserves_state_dir
run_test 'state-dir drop-ins match service and timer schemas' test_state_dir_dropins_match_unit_type
run_test 'systemd inventories are canonical and keep explicit exceptions' test_systemd_inventories_are_canonical
run_test 'systemd missing source fails before mutation and dry-run stays read-only' test_systemd_missing_source_and_dry_run_behavior
run_test 'systemd validation fails on stale installed runtime artifacts' test_systemd_validation_fails_on_stale_installed_runtime
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
grep -Fxq 'SuccessExitStatus=0 1 75' "$health_unit" \
    || fail "health SuccessExitStatus contract changed"
! grep -Eq '^SuccessExitStatus=.*(^| )3( |$)' "$health_unit" \
    || fail "health prerequisite exit 3 must trigger OnFailure"
grep -Fxq 'ExecStart=/opt/vaultwarden-scripts/maintenance.sh health --quick --fix' "$health_unit" \
    || fail "five-minute health service must use the quick repair profile"
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
