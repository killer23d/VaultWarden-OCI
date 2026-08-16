#!/usr/bin/env bash
# Real-host acceptance controller for Ubuntu 24.04 LTS Noble.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
STATE_ROOT="${VW_ACCEPTANCE_STATE_ROOT:-/var/tmp/vaultwarden-noble-acceptance}"
STATE_FILE="$STATE_ROOT/state"
META_FILE="$STATE_ROOT/metadata"
LOG_DIR="$STATE_ROOT/logs"
STATE_PATH_FILE="$STATE_ROOT/original-project-state"
PHASE="inventory"
RECOVERY_KIT=""
RCLONE_REMOTE=""
RCLONE_CONFIG_PATH=""
APPLICATION_E2E=""
POST_RESTORE_RECOVERY_KIT=""
DESTRUCTIVE=false
SKIP_REBOOT=false
PROJECT_STATE_PATH=""

usage() {
    cat <<'EOF_USAGE'
VaultWarden-OCI Noble host acceptance

Usage:
  sudo utilities/noble-host-acceptance.sh run OPTIONS
  sudo utilities/noble-host-acceptance.sh resume OPTIONS
  sudo utilities/noble-host-acceptance.sh status

Required options:
  --recovery-kit FILE      External root-owned recovery kit (0400/0600)
  --rclone-remote NAME     rclone remote containing acceptance backups
  --rclone-config FILE     External root-owned rclone.conf (0400/0600)
  --application-e2e FILE   Root-owned executable application E2E hook

Full DR options:
  --destructive            Run same-host uninstall and full rclone restore
                           (also requires VW_NOBLE_TEST_DESTRUCTIVE=YES)
  --post-restore-recovery-kit FILE
                           On recovery-custody resume, point to the newly rotated
                           recovery kit copied to a non-root mounted recovery medium
  --skip-reboot            Development-only. This can never produce FULL ACCEPTANCE.

The destructive DR phase is intentionally limited to boot-volume project state.
Attached or ambiguously mounted project state is rejected through the canonical
uninstaller's own scope resolver and storage-ambiguity checks.
EOF_USAGE
}

log() { printf '[acceptance] %s\n' "$*"; }
die() { printf '[acceptance] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die 'Run with sudo/root.'; }

hash_text() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }
machine_id_hash() { hash_text "$(cat /etc/machine-id)"; }
current_sha() { git rev-parse HEAD; }

ensure_state_dirs() {
    install -d -m 0700 -o root -g root "$STATE_ROOT" "$LOG_DIR"
}

meta_add() {
    local key="$1" value="$2"
    printf '%s=%s\n' "$key" "$value" >> "$META_FILE"
    chmod 0600 "$META_FILE"
}

meta_get() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k { value=substr($0, index($0, "=") + 1) } END { if (value != "") print value }' "$META_FILE"
}

save_phase() {
    PHASE="$1"
    ensure_state_dirs
    printf '%s\n' "$PHASE" > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

load_phase() {
    [[ -f "$STATE_FILE" ]] || die 'No checkpoint; use run first.'
    PHASE="$(cat "$STATE_FILE")"
}

validate_host() {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" && "${VERSION_CODENAME:-}" == "noble" ]] \
        || die 'Ubuntu 24.04 LTS Noble is required.'
    case "$(dpkg --print-architecture)" in
        amd64|arm64) ;;
        *) die 'Only amd64 and arm64 are supported.' ;;
    esac
}

external_file() {
    local input="$1" label="$2" path owner mode
    [[ ! -L "$input" ]] || die "$label must not be a symlink"
    path="$(realpath -e -- "$input")" || die "Cannot resolve $label"
    [[ -f "$path" ]] || die "$label must be a regular file"
    case "$path" in
        "$ROOT"|"$ROOT"/*|/etc/vaultwarden/*|/var/lib/vaultwarden/*|/mnt/vw-data/*|/run/vaultwarden-oci/*)
            die "$label must survive uninstall and live outside managed paths"
            ;;
    esac
    owner="$(stat -c '%u:%g' "$path")"
    mode="$(stat -c '%a' "$path")"
    [[ "$owner" == "0:0" && ( "$mode" == "600" || "$mode" == "400" ) ]] \
        || die "$label must be root:root mode 0600/0400"
    printf '%s\n' "$path"
}

validate_e2e_hook() {
    local path owner mode mode_num
    [[ ! -L "$APPLICATION_E2E" ]] || die 'Application E2E hook must not be a symlink.'
    path="$(realpath -e -- "$APPLICATION_E2E")" || die 'Cannot resolve application E2E hook.'
    [[ -f "$path" && -x "$path" ]] || die 'Application E2E hook must be an executable regular file.'
    owner="$(stat -c '%u:%g' "$path")"
    mode="$(stat -c '%a' "$path")"
    [[ "$owner" == "0:0" ]] || die 'Application E2E hook must be root:root.'
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die 'Application E2E hook has an invalid mode.'
    mode_num=$((8#$mode))
    (( (mode_num & 8#022) == 0 )) || die 'Application E2E hook must not be group/world writable.'
    APPLICATION_E2E="$path"
}

canonical_boot_scope() {
    (
        set -- run --dry-run
        # Source the canonical uninstaller so acceptance uses the same installed
        # environment precedence and storage ambiguity rules as destructive reset.
        # shellcheck disable=SC1091
        source "$ROOT/utilities/uninstall-vaultwarden.sh"
        resolve
        [[ -z "$DATA_VOLUME_DEVICE" ]] || exit 42
        storage_ambiguous && exit 42
        printf '%s\n' "$PROJECT_STATE_DIR"
    )
}

validate_boot_volume() {
    local rc=0 output=""
    set +e
    output="$(canonical_boot_scope)"
    rc=$?
    set -e
    case "$rc" in
        0)
            [[ "$output" == /* ]] || die 'Canonical uninstall scope did not return an absolute project state path.'
            PROJECT_STATE_PATH="$output"
            ;;
        42) die 'Destructive same-host DR refuses attached or ambiguously mounted project state.' ;;
        *) die 'Canonical uninstall storage-scope resolution failed.' ;;
    esac
}

write_original_state_path() {
    printf '%s\n' "$PROJECT_STATE_PATH" > "$STATE_PATH_FILE"
    chmod 0600 "$STATE_PATH_FILE"
}

read_original_state_path() {
    [[ -f "$STATE_PATH_FILE" ]] || die 'Original project-state checkpoint is missing.'
    PROJECT_STATE_PATH="$(cat "$STATE_PATH_FILE")"
}

init_metadata() {
    : > "$META_FILE"
    chmod 0600 "$META_FILE"
    meta_add RUN_SHA "$(current_sha)"
    meta_add HOST_MACHINE_ID_HASH "$(machine_id_hash)"
    meta_add INITIAL_BOOT_ID "$(boot_id)"
    meta_add RCLONE_REMOTE_HASH "$(hash_text "$RCLONE_REMOTE")"
    meta_add RCLONE_CONFIG_PATH_HASH "$(hash_text "$RCLONE_CONFIG_PATH")"
    meta_add RCLONE_CONFIG_SHA256 "$(sha_file "$RCLONE_CONFIG_PATH")"
    meta_add RECOVERY_KIT_PATH_HASH "$(hash_text "$RECOVERY_KIT")"
    meta_add RECOVERY_KIT_SHA256 "$(sha_file "$RECOVERY_KIT")"
    meta_add E2E_PATH_HASH "$(hash_text "$APPLICATION_E2E")"
    meta_add E2E_SHA256 "$(sha_file "$APPLICATION_E2E")"
    meta_add DESTRUCTIVE "$DESTRUCTIVE"
    meta_add SKIP_REBOOT "$SKIP_REBOOT"
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        validate_boot_volume
        write_original_state_path
        meta_add PROJECT_STATE_PATH_HASH "$(hash_text "$PROJECT_STATE_PATH")"
    fi
}

verify_metadata() {
    [[ -f "$META_FILE" ]] || die 'Acceptance metadata is missing.'
    [[ "$(meta_get RUN_SHA)" == "$(current_sha)" ]] || die 'Checkout SHA changed since the acceptance run started.'
    [[ "$(meta_get HOST_MACHINE_ID_HASH)" == "$(machine_id_hash)" ]] || die 'Host identity changed since the acceptance run started.'
    [[ "$(meta_get RCLONE_REMOTE_HASH)" == "$(hash_text "$RCLONE_REMOTE")" ]] || die 'rclone remote changed since run start.'
    [[ "$(meta_get RCLONE_CONFIG_PATH_HASH)" == "$(hash_text "$RCLONE_CONFIG_PATH")" ]] || die 'rclone config path changed since run start.'
    [[ "$(meta_get RCLONE_CONFIG_SHA256)" == "$(sha_file "$RCLONE_CONFIG_PATH")" ]] || die 'rclone config content changed since run start.'
    [[ "$(meta_get RECOVERY_KIT_PATH_HASH)" == "$(hash_text "$RECOVERY_KIT")" ]] || die 'Recovery-kit path changed since run start.'
    [[ "$(meta_get RECOVERY_KIT_SHA256)" == "$(sha_file "$RECOVERY_KIT")" ]] || die 'Recovery-kit content changed since run start.'
    [[ "$(meta_get E2E_PATH_HASH)" == "$(hash_text "$APPLICATION_E2E")" ]] || die 'Application E2E hook path changed since run start.'
    [[ "$(meta_get E2E_SHA256)" == "$(sha_file "$APPLICATION_E2E")" ]] || die 'Application E2E hook content changed since run start.'
    [[ "$(meta_get DESTRUCTIVE)" == "$DESTRUCTIVE" ]] || die 'Destructive mode changed since run start.'
    [[ "$(meta_get SKIP_REBOOT)" == "$SKIP_REBOOT" ]] || die 'Reboot policy changed since run start.'
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        read_original_state_path
        [[ "$(meta_get PROJECT_STATE_PATH_HASH)" == "$(hash_text "$PROJECT_STATE_PATH")" ]] \
            || die 'Original project-state checkpoint changed.'
    fi
}

step() {
    local name="$1"
    shift
    log "START $name"
    "$@" > >(tee "$LOG_DIR/$name.log") 2> >(tee -a "$LOG_DIR/$name.log" >&2)
    log "PASS  $name"
}

systemd_jobs() {
    local unit
    for unit in \
        vaultwarden-health.service \
        vaultwarden-db-backup.service \
        vaultwarden-full-backup.service \
        vaultwarden-maintenance.service \
        vaultwarden-dns-update.service \
        vaultwarden-firewall-update.service; do
        systemctl start "$unit"
        ! systemctl --quiet is-failed "$unit" || return 1
    done
}

manual_systemd_install_check() {
    local timer
    bash ./utilities/setup-systemd.sh install --no-enable-now
    for timer in \
        vaultwarden-maintenance.timer \
        vaultwarden-db-backup.timer \
        vaultwarden-full-backup.timer \
        vaultwarden-health.timer \
        vaultwarden-dns-update.timer \
        vaultwarden-firewall-update.timer; do
        systemctl is-enabled --quiet "$timer" || return 1
        ! systemctl is-active --quiet "$timer" || return 1
    done
    systemctl is-enabled --quiet vaultwarden-startup.service
}

post_uninstall_check() {
    read_original_state_path
    [[ ! -e /etc/vaultwarden ]] || return 1
    [[ ! -e /run/vaultwarden-oci ]] || return 1
    [[ ! -e "$PROJECT_STATE_PATH" ]] || return 1
    [[ ! -e "$ROOT/.env" ]] || return 1
    [[ -z "$(docker ps -aq --filter label=com.docker.compose.project=vaultwarden-oci 2>/dev/null)" ]] || return 1
}

verify_reboot_transition() {
    local before current
    if [[ "$SKIP_REBOOT" == "true" ]]; then
        return 2
    fi
    before="$(meta_get REBOOT_FROM_BOOT_ID)"
    [[ -n "$before" ]] || die 'Missing pre-reboot boot ID checkpoint.'
    current="$(boot_id)"
    [[ "$current" != "$before" ]] || die 'Host has not rebooted since the reboot checkpoint.'
    return 0
}

validate_post_restore_recovery_kit() {
    local path root_dev kit_dev kit_target restore_epoch mtime old_digest new_digest
    [[ -n "$POST_RESTORE_RECOVERY_KIT" ]] || {
        log 'Copy the newly rotated recovery handoff to a durable off-host mounted recovery medium.'
        find /root/vaultwarden-recovery -maxdepth 1 -type f -name 'vaultwarden-recovery-kit-*' -print 2>/dev/null || true
        die 'Resume with --post-restore-recovery-kit FILE after the off-host copy is secured.'
    }
    path="$(external_file "$POST_RESTORE_RECOVERY_KIT" 'post-restore recovery kit')"
    command -v findmnt >/dev/null 2>&1 || die 'findmnt is required to verify recovery-kit custody.'
    root_dev="$(findmnt -n -o MAJ:MIN --target /)"
    kit_dev="$(findmnt -n -o MAJ:MIN --target "$path")"
    kit_target="$(findmnt -n -o TARGET --target "$path")"
    [[ -n "$kit_dev" && "$kit_dev" != "$root_dev" && "$kit_target" != "/" ]] \
        || die 'Post-restore recovery kit must be on a non-root mounted recovery medium.'
    restore_epoch="$(meta_get RESTORE_COMPLETED_EPOCH)"
    [[ "$restore_epoch" =~ ^[0-9]+$ ]] || die 'Missing restore completion timestamp.'
    mtime="$(stat -c '%Y' "$path")"
    (( mtime >= restore_epoch )) || die 'Post-restore recovery kit predates the successful restore.'
    [[ "$(grep -Fxc 'END OF RECOVERY KIT' "$path" 2>/dev/null || true)" == "1" ]] \
        || die 'Post-restore recovery kit is missing the canonical completion marker.'
    [[ "$(grep -c '^AGE-SECRET-KEY-1' "$path" 2>/dev/null || true)" == "1" ]] \
        || die 'Post-restore recovery kit does not contain exactly one Age private identity.'
    old_digest="$(meta_get RECOVERY_KIT_SHA256)"
    new_digest="$(sha_file "$path")"
    [[ "$new_digest" != "$old_digest" ]] || die 'Post-restore recovery kit matches the pre-DR kit; rotated custody was not proven.'
    POST_RESTORE_RECOVERY_KIT="$path"
    meta_add POST_RESTORE_RECOVERY_KIT_SHA256 "$new_digest"
}

parse() {
    while (($#)); do
        case "$1" in
            --recovery-kit) [[ $# -ge 2 ]] || die '--recovery-kit requires a value.'; RECOVERY_KIT="$2"; shift 2 ;;
            --rclone-remote) [[ $# -ge 2 ]] || die '--rclone-remote requires a value.'; RCLONE_REMOTE="$2"; shift 2 ;;
            --rclone-config) [[ $# -ge 2 ]] || die '--rclone-config requires a value.'; RCLONE_CONFIG_PATH="$2"; shift 2 ;;
            --application-e2e) [[ $# -ge 2 ]] || die '--application-e2e requires a value.'; APPLICATION_E2E="$2"; shift 2 ;;
            --post-restore-recovery-kit) [[ $# -ge 2 ]] || die '--post-restore-recovery-kit requires a value.'; POST_RESTORE_RECOVERY_KIT="$2"; shift 2 ;;
            --destructive) DESTRUCTIVE=true; shift ;;
            --skip-reboot) SKIP_REBOOT=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

validate_inputs() {
    [[ -n "$RECOVERY_KIT" && -n "$RCLONE_REMOTE" && -n "$RCLONE_CONFIG_PATH" && -n "$APPLICATION_E2E" ]] \
        || die 'Recovery kit, rclone remote/config, and application E2E hook are required.'
    [[ "$RCLONE_REMOTE" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid rclone remote name.'
    RECOVERY_KIT="$(external_file "$RECOVERY_KIT" 'recovery kit')"
    RCLONE_CONFIG_PATH="$(external_file "$RCLONE_CONFIG_PATH" 'rclone config')"
    validate_e2e_hook
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        [[ "${VW_NOBLE_TEST_DESTRUCTIVE:-}" == "YES" ]] \
            || die 'Set VW_NOBLE_TEST_DESTRUCTIVE=YES together with --destructive.'
    fi
}

capture_inventory() {
    {
        date -u +%FT%TZ
        current_sha
        uname -a
        cat /etc/os-release
        dpkg --print-architecture
        lsblk -f
        docker version
        docker compose version
    } > "$LOG_DIR/inventory.log"
}

run_phases() {
    while true; do
        case "$PHASE" in
            inventory)
                capture_inventory
                save_phase contracts
                ;;
            contracts)
                step contract-tests bash ./tests/run-tests.sh all
                save_phase live
                ;;
            live)
                step make-health make health
                step email-test bash ./maintenance.sh test-email --verbose
                step pre-production-drill bash ./utilities/pre-production-drill.sh
                step smoke-before-dr bash ./utilities/smoke-test.sh
                save_phase backups
                ;;
            backups)
                step db-backup-rclone env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
                step full-backup-rclone env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run full --full-verification --rclone
                step backup-verify bash ./backup.sh verify
                step backup-sync env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh sync
                step remote-list env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./restore.sh list --remote
                save_phase automation
                ;;
            automation)
                step systemd-validate bash ./utilities/setup-systemd.sh validate
                step systemd-jobs systemd_jobs
                step docker-restart systemctl restart docker.service
                step smoke-after-docker-restart bash ./utilities/smoke-test.sh
                step application-before-dr "$APPLICATION_E2E"
                save_phase reboot
                ;;
            reboot)
                meta_add REBOOT_FROM_BOOT_ID "$(boot_id)"
                save_phase post-reboot
                if [[ "$SKIP_REBOOT" == "true" ]]; then
                    log 'Reboot skipped for development. This run is permanently non-certifying.'
                else
                    log 'Checkpoint saved. Reboot the host now, then rerun the same options with resume.'
                    exit 75
                fi
                ;;
            post-reboot)
                if verify_reboot_transition; then
                    step systemd-after-reboot bash ./utilities/setup-systemd.sh validate
                    step smoke-after-reboot bash ./utilities/smoke-test.sh
                    if [[ "$DESTRUCTIVE" == "true" ]]; then
                        save_phase uninstall
                    else
                        save_phase incomplete
                    fi
                else
                    step systemd-without-reboot bash ./utilities/setup-systemd.sh validate
                    step smoke-without-reboot bash ./utilities/smoke-test.sh
                    save_phase incomplete
                fi
                ;;
            uninstall)
                validate_boot_volume
                local current_state_path="$PROJECT_STATE_PATH"
                read_original_state_path
                [[ "$current_state_path" == "$PROJECT_STATE_PATH" ]] \
                    || die 'Project state path changed before destructive reset.'
                [[ "$(meta_get PROJECT_STATE_PATH_HASH)" == "$(hash_text "$PROJECT_STATE_PATH")" ]] \
                    || die 'Original project-state checkpoint changed before destructive reset.'
                step uninstall-reset bash ./utilities/uninstall-vaultwarden.sh run --test-reset --i-have-saved-my-recovery-kit --force
                step uninstall-residuals post_uninstall_check
                save_phase restore
                ;;
            restore)
                step remote-full-restore env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" \
                    bash ./restore.sh latest full --remote --from-recovery-kit "$RECOVERY_KIT" --no-backup --start-policy manual --force
                meta_add RESTORE_COMPLETED_EPOCH "$(date +%s)"
                step repair-permissions bash ./utilities/repair-permissions.sh
                step startup bash ./startup.sh
                step systemd-install-manual manual_systemd_install_check
                step make-health-after-restore make health
                step email-after-restore bash ./maintenance.sh test-email --verbose
                step pre-production-after-restore bash ./utilities/pre-production-drill.sh
                step application-after-dr "$APPLICATION_E2E"
                save_phase recovery-custody
                ;;
            recovery-custody)
                validate_post_restore_recovery_kit
                save_phase activate-automation
                ;;
            activate-automation)
                step systemd-activate bash ./utilities/setup-systemd.sh install --enable-now
                step systemd-after-restore bash ./utilities/setup-systemd.sh validate
                step smoke-after-restore bash ./utilities/smoke-test.sh
                save_phase final-backup
                ;;
            final-backup)
                step post-dr-db env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
                step post-dr-full env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run full --full-verification --rclone
                step post-dr-verify bash ./backup.sh verify
                save_phase complete
                ;;
            complete)
                log "FULL ACCEPTANCE PASSED: $(current_sha)"
                return 0
                ;;
            incomplete)
                die 'Run is non-certifying. Full acceptance requires destructive mode and a verified real reboot.'
                ;;
            *) die "Unknown phase: $PHASE" ;;
        esac
    done
}

main() {
    local action
    case "${1:-}" in
        -h|--help|help) usage; exit 0 ;;
        status)
            require_root
            [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo 'No checkpoint.'
            exit 0
            ;;
        run|resume) action="$1"; shift ;;
        *) usage >&2; exit 2 ;;
    esac

    require_root
    parse "$@"
    validate_host
    validate_inputs
    ensure_state_dirs

    if [[ "$action" == "run" ]]; then
        [[ ! -e "$STATE_FILE" ]] || die 'Checkpoint exists; use resume.'
        init_metadata
        save_phase inventory
    else
        load_phase
        verify_metadata
    fi
    run_phases
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
