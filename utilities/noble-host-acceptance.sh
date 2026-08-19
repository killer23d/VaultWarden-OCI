#!/usr/bin/env bash
# Real-host acceptance controller for Ubuntu 24.04 LTS Noble.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Reuse the canonical volatile sensitive-workspace abstraction for all
# acceptance-owned private-key staging and delegated restore TMPDIR fallback.
# shellcheck source=../lib/crypto.sh
source "$ROOT/lib/crypto.sh"
STATE_ROOT="${VW_ACCEPTANCE_STATE_ROOT:-/var/tmp/vaultwarden-noble-acceptance}"
STATE_FILE="$STATE_ROOT/state"
META_FILE="$STATE_ROOT/metadata"
LOG_DIR="$STATE_ROOT/logs"
STATE_PATH_FILE="$STATE_ROOT/original-project-state"
PHASE="inventory"
RECOVERY_KIT=""
RCLONE_REMOTE=""
RCLONE_REMOTE_PATH=""
RCLONE_CONFIG_PATH=""
APPLICATION_E2E=""
POST_RESTORE_RECOVERY_KIT=""
DNS_MUTATION_DOMAIN=""
ALLOW_DNS_MUTATION=false
DESTRUCTIVE=false
SKIP_REBOOT=false
PROJECT_STATE_PATH=""
BOUND_BACKUP_FILE=""
VALIDATED_RECOVERY_RECIPIENT=""
ACCEPTANCE_LOCK_FILE="/run/lock/vaultwarden-noble-acceptance.lock"
ACCEPTANCE_LOCK_FD=""

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
  --rclone-path PATH       Bound rclone subpath containing acceptance backups
  --rclone-config FILE     External root-owned rclone.conf (0400/0600)
  --application-e2e FILE   Root-owned executable application E2E hook
  --dns-mutation-domain HOSTNAME
                           Exact dedicated acceptance hostname configured as DOMAIN
  --allow-dns-mutation     Acknowledge foreground/timer DNS mutation for that hostname

Full DR options:
  --destructive            Run same-host uninstall and exact full rclone restore
                           (also requires VW_NOBLE_TEST_DESTRUCTIVE=YES)
  --post-restore-recovery-kit FILE
                           On recovery-custody resume, point to the canonical full
                           recovery kit exported after restore and copied to a
                           non-root mounted recovery medium
  --skip-reboot            Development-only. This can never produce FULL ACCEPTANCE.

DNS mutation requires --allow-dns-mutation together with
VW_NOBLE_TEST_DNS_MUTATION=YES. The configured runtime DOMAIN must exactly match
--dns-mutation-domain before the DNS service or timers may run.

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

runtime_config_value() (
    local key="$1" default="${2:-}"
    export RCLONE_REMOTE_NAME="$RCLONE_REMOTE"
    export RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH"
    export RCLONE_CONFIG="$RCLONE_CONFIG_PATH"
    # shellcheck disable=SC1091
    source "$ROOT/lib/config.sh"
    load_project_environment >/dev/null
    get_config_value "$key" "$default"
)

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

canonical_destructive_survival_scope() (
    local path unit volume_id volume_mount
    set -- run --dry-run --test-reset --i-have-saved-my-recovery-kit --force
    # Source the exact canonical destructive owner, then resolve its current
    # configured paths. Acceptance intentionally over-approximates managed trees:
    # a dependency must not merely be likely to survive; it must be outside every
    # resolved tree or exact file that this test-reset can remove, rewrite, or
    # unmount before the later restore/E2E phases need it.
    # shellcheck disable=SC1091
    source "$ROOT/utilities/uninstall-vaultwarden.sh"
    resolve

    emit_scope() {
        local kind="$1" raw="$2" resolved
        [[ -n "$raw" ]] || return 0
        resolved="$(canon "$raw")" || exit 43
        [[ "$resolved" == /* ]] || exit 43
        printf '%s\t%s\n' "$kind" "$resolved"
    }

    # Recursive/removal or accessibility-loss roots. ROOT is conservative for
    # --test-reset checkout cleanup; RECOVERY_DIR is conservative because only
    # canonical handoff names are normally removed there.
    emit_scope tree "$ROOT"
    if [[ -z "$DATA_VOLUME_DEVICE" ]]; then
        emit_scope tree "$PROJECT_STATE_DIR"
    elif [[ -n "$DATA_VOLUME_MOUNT" ]]; then
        emit_scope tree "$DATA_VOLUME_MOUNT"
    fi
    for path in "$OPT_DIR" "$ETC_DIR" "$RUNTIME" "$RECOVERY_DIR"; do
        emit_scope tree "$path"
    done

    # Test-reset and managed-host files that are removed or rewritten exactly.
    for path in \
        "$SWAPFILE" "$UNIVERSE_SOURCE" "$FSTAB" "$SYSCTL" \
        "$MOUNT_GUARD" "$DOCKER_RUNTIME_DROPIN" \
        "$CS_EMAIL" "$CS_PROFILES" "$CS_WORKER" "$CS_WORKER_UNIT"; do
        emit_scope exact "$path"
    done
    for unit in "${TIMERS[@]}" "${SERVICES[@]}"; do
        emit_scope exact "$SYSTEMD/$unit"
        emit_scope exact "$SYSTEMD/$unit.d/10-state-dir.conf"
    done

    # Canonical uninstall also removes compose-labelled Docker volumes. Their
    # host mountpoints are dynamic rather than resolve() variables, so include
    # them when the daemon can be inspected. If Docker is unavailable, canonical
    # live uninstall itself fails before persistent-state deletion.
    if has docker && docker info >/dev/null 2>&1; then
        while IFS= read -r volume_id; do
            [[ -n "$volume_id" ]] || continue
            volume_mount="$(docker volume inspect --format '{{.Mountpoint}}' "$volume_id" 2>/dev/null || true)"
            [[ -n "$volume_mount" ]] && emit_scope tree "$volume_mount"
        done < <(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null || true)
    fi
)

validate_destructive_survival() {
    local scope_output kind scope_path candidate label i state_candidate
    local -a candidates labels

    [[ "$STATE_ROOT" == /* ]] || die 'VW_ACCEPTANCE_STATE_ROOT must be an absolute path.'
    [[ ! -L "$STATE_ROOT" ]] || die 'VW_ACCEPTANCE_STATE_ROOT must not be a symlink.'
    [[ ! -e "$STATE_ROOT" || -d "$STATE_ROOT" ]] \
        || die 'VW_ACCEPTANCE_STATE_ROOT must be a directory path.'
    state_candidate="$(realpath -m -- "$STATE_ROOT")" \
        || die 'Cannot canonicalize VW_ACCEPTANCE_STATE_ROOT.'
    case "$state_candidate" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/var/lib)
            die 'VW_ACCEPTANCE_STATE_ROOT must be a dedicated subdirectory, not a top-level host path.'
            ;;
    esac

    candidates[0]="$(realpath -e -- "$RECOVERY_KIT")" \
        || die 'Cannot re-resolve the pre-DR recovery kit for destructive survival.'
    candidates[1]="$(realpath -e -- "$RCLONE_CONFIG_PATH")" \
        || die 'Cannot re-resolve the rclone config for destructive survival.'
    candidates[2]="$(realpath -e -- "$APPLICATION_E2E")" \
        || die 'Cannot re-resolve the application E2E hook for destructive survival.'
    candidates[3]="$state_candidate"
    labels=('Pre-DR recovery kit' 'rclone config' 'application E2E hook' 'acceptance state root')

    scope_output="$(canonical_destructive_survival_scope)" \
        || die 'Cannot resolve the canonical --test-reset destructive survival scope.'
    while IFS=$'\t' read -r kind scope_path; do
        [[ -n "$kind" && -n "$scope_path" ]] || continue
        case "$kind" in tree|exact) ;; *) die 'Canonical destructive survival scope returned an invalid record.' ;; esac
        for i in "${!candidates[@]}"; do
            candidate="${candidates[$i]}"
            label="${labels[$i]}"
            if [[ "$kind" == tree ]]; then
                case "$candidate" in
                    "$scope_path"|"$scope_path"/*)
                        die "$label is inside canonical --test-reset removal/access-loss scope: $scope_path"
                        ;;
                esac
            elif [[ "$candidate" == "$scope_path" ]]; then
                die "$label is a canonical --test-reset managed file and will not safely survive: $scope_path"
            fi
        done
    done <<< "$scope_output"
}

acquire_controller_lock() {
    local lock_dir
    command -v flock >/dev/null 2>&1 || die 'flock is required for the acceptance controller lock.'
    [[ "$ACCEPTANCE_LOCK_FILE" == /* ]] || die 'Acceptance controller lock path must be absolute.'
    lock_dir="$(dirname -- "$ACCEPTANCE_LOCK_FILE")"
    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || die "Acceptance lock directory is unavailable or unsafe: $lock_dir"
    [[ ! -L "$ACCEPTANCE_LOCK_FILE" ]] || die 'Acceptance controller lock file must not be a symlink.'
    [[ ! -e "$ACCEPTANCE_LOCK_FILE" || -f "$ACCEPTANCE_LOCK_FILE" ]] \
        || die 'Acceptance controller lock path exists but is not a regular file.'
    umask 077
    unset ACCEPTANCE_LOCK_FD
    exec {ACCEPTANCE_LOCK_FD}>"$ACCEPTANCE_LOCK_FILE" \
        || die 'Cannot open acceptance controller lock file.'
    chmod 0600 "$ACCEPTANCE_LOCK_FILE" \
        || die 'Cannot secure acceptance controller lock file.'
    flock -n "$ACCEPTANCE_LOCK_FD" \
        || die 'Another Noble host acceptance run/resume process is already active.'
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
    meta_add RCLONE_REMOTE_PATH_HASH "$(hash_text "$RCLONE_REMOTE_PATH")"
    meta_add RCLONE_CONFIG_PATH_HASH "$(hash_text "$RCLONE_CONFIG_PATH")"
    meta_add RCLONE_CONFIG_SHA256 "$(sha_file "$RCLONE_CONFIG_PATH")"
    meta_add RECOVERY_KIT_PATH_HASH "$(hash_text "$RECOVERY_KIT")"
    meta_add RECOVERY_KIT_SHA256 "$(sha_file "$RECOVERY_KIT")"
    meta_add E2E_PATH_HASH "$(hash_text "$APPLICATION_E2E")"
    meta_add E2E_SHA256 "$(sha_file "$APPLICATION_E2E")"
    meta_add DNS_MUTATION_DOMAIN_HASH "$(hash_text "$DNS_MUTATION_DOMAIN")"
    meta_add ALLOW_DNS_MUTATION "$ALLOW_DNS_MUTATION"
    meta_add DESTRUCTIVE "$DESTRUCTIVE"
    meta_add SKIP_REBOOT "$SKIP_REBOOT"
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        validate_boot_volume
        write_original_state_path
        meta_add PROJECT_STATE_PATH_HASH "$(hash_text "$PROJECT_STATE_PATH")"
    fi
}

verify_metadata() {
    local post_restore_digest
    [[ -f "$META_FILE" ]] || die 'Acceptance metadata is missing.'
    [[ "$(meta_get RUN_SHA)" == "$(current_sha)" ]] || die 'Checkout SHA changed since the acceptance run started.'
    [[ "$(meta_get HOST_MACHINE_ID_HASH)" == "$(machine_id_hash)" ]] || die 'Host identity changed since the acceptance run started.'
    [[ "$(meta_get RCLONE_REMOTE_HASH)" == "$(hash_text "$RCLONE_REMOTE")" ]] || die 'rclone remote changed since run start.'
    [[ "$(meta_get RCLONE_REMOTE_PATH_HASH)" == "$(hash_text "$RCLONE_REMOTE_PATH")" ]] || die 'rclone path changed since run start.'
    [[ "$(meta_get RCLONE_CONFIG_PATH_HASH)" == "$(hash_text "$RCLONE_CONFIG_PATH")" ]] || die 'rclone config path changed since run start.'
    [[ "$(meta_get RCLONE_CONFIG_SHA256)" == "$(sha_file "$RCLONE_CONFIG_PATH")" ]] || die 'rclone config content changed since run start.'
    [[ "$(meta_get RECOVERY_KIT_PATH_HASH)" == "$(hash_text "$RECOVERY_KIT")" ]] || die 'Recovery-kit path changed since run start.'
    [[ "$(meta_get RECOVERY_KIT_SHA256)" == "$(sha_file "$RECOVERY_KIT")" ]] || die 'Recovery-kit content changed since run start.'
    [[ "$(meta_get E2E_PATH_HASH)" == "$(hash_text "$APPLICATION_E2E")" ]] || die 'Application E2E hook path changed since run start.'
    [[ "$(meta_get E2E_SHA256)" == "$(sha_file "$APPLICATION_E2E")" ]] || die 'Application E2E hook content changed since run start.'
    [[ "$(meta_get DNS_MUTATION_DOMAIN_HASH)" == "$(hash_text "$DNS_MUTATION_DOMAIN")" ]] || die 'DNS mutation domain changed since run start.'
    [[ "$(meta_get ALLOW_DNS_MUTATION)" == "$ALLOW_DNS_MUTATION" ]] || die 'DNS mutation acknowledgement changed since run start.'
    [[ "$(meta_get DESTRUCTIVE)" == "$DESTRUCTIVE" ]] || die 'Destructive mode changed since run start.'
    [[ "$(meta_get SKIP_REBOOT)" == "$SKIP_REBOOT" ]] || die 'Reboot policy changed since run start.'
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        read_original_state_path
        [[ "$(meta_get PROJECT_STATE_PATH_HASH)" == "$(hash_text "$PROJECT_STATE_PATH")" ]] \
            || die 'Original project-state checkpoint changed.'
    fi
    post_restore_digest="$(meta_get POST_RESTORE_RECOVERY_KIT_SHA256)"
    if [[ -n "$post_restore_digest" ]]; then
        [[ -n "$POST_RESTORE_RECOVERY_KIT" ]] \
            || die 'Post-restore recovery kit is checkpoint-bound; pass it again on resume.'
        [[ "$(meta_get POST_RESTORE_RECOVERY_KIT_PATH_HASH)" == "$(hash_text "$POST_RESTORE_RECOVERY_KIT")" ]] \
            || die 'Post-restore recovery-kit path changed after custody was proven.'
        [[ "$post_restore_digest" == "$(sha_file "$POST_RESTORE_RECOVERY_KIT")" ]] \
            || die 'Post-restore recovery-kit content changed after custody was proven.'
    fi
}

step() {
    local name="$1"
    shift
    log "START $name"
    "$@" > >(tee "$LOG_DIR/$name.log") 2> >(tee -a "$LOG_DIR/$name.log" >&2)
    log "PASS  $name"
}

full_backup_inventory() {
    command -v yq >/dev/null 2>&1 || die 'yq is required to bind the exact full backup.'
    bash ./backup.sh list --json \
        | yq -r '.backups[] | select(.type == "full") | .path' \
        | LC_ALL=C sort -u
}

backup_cohort_digest() {
    local archive="$1" suffix member material=""
    for suffix in '' '.sha256' '.sha256.hmac' '.meta'; do
        member="${archive}${suffix}"
        [[ -f "$member" && ! -L "$member" && -s "$member" ]] || return 1
        material+="${suffix}:$(sha_file "$member")"$'\n'
    done
    hash_text "$material"
}

run_and_bind_full_backup() {
    local prefix="$1" before after archive cohort_digest archive_digest canary_epoch mtime
    local -a new_backups=()
    before="$STATE_ROOT/${prefix,,}-full-before.list"
    after="$STATE_ROOT/${prefix,,}-full-after.list"
    full_backup_inventory > "$before"
    env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
        RCLONE_CONFIG="$RCLONE_CONFIG_PATH" \
        bash ./backup.sh run full --full-verification --rclone
    full_backup_inventory > "$after"
    mapfile -t new_backups < <(comm -13 "$before" "$after")
    [[ ${#new_backups[@]} -eq 1 ]] || {
        log "Expected exactly one newly published full backup; found ${#new_backups[@]}."
        return 1
    }
    archive="${new_backups[0]}"
    [[ "$(basename "$archive")" == full_backup_*.tar.zst.age ]] || return 1
    archive_digest="$(sha_file "$archive")"
    cohort_digest="$(backup_cohort_digest "$archive")" || return 1
    mtime="$(stat -c '%Y' "$archive")"
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    if [[ "$prefix" == "DR_SOURCE" ]]; then
        canary_epoch="$(meta_get PRE_DR_E2E_COMPLETED_EPOCH)"
        [[ "$canary_epoch" =~ ^[0-9]+$ ]] || die 'Missing pre-DR E2E completion checkpoint.'
        (( mtime >= canary_epoch )) \
            || die 'Bound DR source backup predates the successful pre-DR E2E/canary step.'
    fi
    meta_add "${prefix}_BACKUP_BASENAME" "$(basename "$archive")"
    meta_add "${prefix}_BACKUP_ARCHIVE_SHA256" "$archive_digest"
    meta_add "${prefix}_BACKUP_COHORT_SHA256" "$cohort_digest"
    meta_add "${prefix}_BACKUP_CREATED_EPOCH" "$mtime"
    meta_add "${prefix}_BACKUP_REMOTE_OBJECT_HASH" \
        "$(hash_text "${RCLONE_REMOTE}:${RCLONE_REMOTE_PATH}/full/$(basename "$archive")")"
    log "Bound ${prefix} full backup: $(basename "$archive") sha256=$archive_digest"
}

download_bound_backup() {
    local prefix="$1" stage_name="$2" basename expected_archive expected_cohort
    local stage_dir remote_member suffix member actual_cohort
    basename="$(meta_get "${prefix}_BACKUP_BASENAME")"
    expected_archive="$(meta_get "${prefix}_BACKUP_ARCHIVE_SHA256")"
    expected_cohort="$(meta_get "${prefix}_BACKUP_COHORT_SHA256")"
    [[ -n "$basename" && "$basename" != */* && "$basename" == full_backup_*.tar.zst.age ]] \
        || die "Missing or unsafe ${prefix} backup identity."
    [[ "$expected_archive" =~ ^[0-9a-f]{64}$ && "$expected_cohort" =~ ^[0-9a-f]{64}$ ]] \
        || die "Missing ${prefix} backup digest checkpoint."
    stage_dir="$STATE_ROOT/$stage_name/full"
    rm -rf -- "${STATE_ROOT:?}/${stage_name:?}"
    install -d -m 0700 "$stage_dir"
    for suffix in '' '.sha256' '.sha256.hmac' '.meta'; do
        remote_member="${RCLONE_REMOTE}:${RCLONE_REMOTE_PATH}/full/${basename}${suffix}"
        rclone copy --config "$RCLONE_CONFIG_PATH" "$remote_member" "$stage_dir/" \
            --checksum --contimeout 15s --timeout 60s
        member="$stage_dir/${basename}${suffix}"
        [[ -f "$member" && ! -L "$member" && -s "$member" ]] \
            || die "Exact remote cohort member is missing after download: ${basename}${suffix}"
    done
    BOUND_BACKUP_FILE="$stage_dir/$basename"
    [[ "$(sha_file "$BOUND_BACKUP_FILE")" == "$expected_archive" ]] \
        || die "Downloaded ${prefix} archive digest differs from the bound source."
    actual_cohort="$(backup_cohort_digest "$BOUND_BACKUP_FILE")" || die 'Downloaded backup cohort is incomplete.'
    [[ "$actual_cohort" == "$expected_cohort" ]] \
        || die "Downloaded ${prefix} cohort digest differs from the bound source."
}

write_recovery_kit_identity() {
    local kit="$1" output="$2"
    awk '/^AGE-SECRET-KEY-1/{print; count++} END { exit(count == 1 ? 0 : 1) }' "$kit" > "$output"
}

recovery_kit_has_integrity_hmac() {
    local kit="$1"
    awk '
        $0 == "[Backup integrity HMAC key (auto-generated)]" {
            count++
            if ((getline value) > 0 && value != "" && value !~ /^</) valid++
        }
        END { exit(count == 1 && valid == 1 ? 0 : 1) }
    ' "$kit"
}

run_with_sensitive_tmp() (
    local workspace=""
    workspace="$(create_sensitive_workspace acceptance-restore)" || return 1
    trap '[[ -z "${workspace:-}" ]] || remove_sensitive_workspace "$workspace" >/dev/null 2>&1 || true' EXIT
    TMPDIR="$workspace" "$@"
)

verify_bound_backup_with_recovery_kit() {
    local prefix="$1" kit="$2"
    local stage_name="${3:-verify-${prefix,,}}" retain_stage="${4:-false}"
    local verify_root archive_digest verified_epoch
    [[ "$stage_name" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Invalid recovery verification stage name.'
    [[ "$retain_stage" == "true" || "$retain_stage" == "false" ]] \
        || die 'Recovery verification retain flag must be true or false.'
    verify_root="$STATE_ROOT/$stage_name"
    download_bound_backup "$prefix" "$stage_name"
    if ! run_with_sensitive_tmp env \
            RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
            RCLONE_CONFIG="$RCLONE_CONFIG_PATH" \
            bash ./restore.sh inspect --remote --file "$BOUND_BACKUP_FILE" \
            --from-recovery-kit "$kit"; then
        rm -rf -- "$verify_root"
        return 1
    fi
    archive_digest="$(sha_file "$BOUND_BACKUP_FILE")"
    verified_epoch="$(date +%s)"
    meta_add "${prefix}_RECOVERY_KIT_INSPECT_VERIFIED_SHA256" "$archive_digest"
    meta_add "${prefix}_RECOVERY_KIT_INSPECT_VERIFIED_EPOCH" "$verified_epoch"
    if [[ "$retain_stage" == "true" ]]; then
        meta_add "${prefix}_RECOVERY_CACHE_ARCHIVE_SHA256" "$archive_digest"
        meta_add "${prefix}_RECOVERY_CACHE_PATH_HASH" "$(hash_text "$BOUND_BACKUP_FILE")"
        meta_add "${prefix}_RECOVERY_CACHE_VERIFIED_EPOCH" "$verified_epoch"
        log "Retained exact authenticated ${prefix} recovery cache until restore completes: $BOUND_BACKUP_FILE"
    else
        rm -rf -- "$verify_root"
    fi
}

pre_uninstall_recovery_gate() {
    # STATE_ROOT and every external dependency must survive the canonical reset
    # before we create the retained safety copy. Recheck after the authenticated
    # download/inspect too so the final action before uninstall is still the
    # canonical destructive-survival boundary.
    validate_destructive_survival
    verify_bound_backup_with_recovery_kit \
        DR_SOURCE "$RECOVERY_KIT" pre-uninstall-recovery-cache true
    validate_destructive_survival
    log 'Fresh post-reboot authenticated DR-source proof passed immediately before destructive reset.'
}

validate_dns_mutation_scope() {
    local configured_domain
    [[ "$ALLOW_DNS_MUTATION" == "true" ]] || die 'DNS mutation is not explicitly allowed for this run.'
    [[ "${VW_NOBLE_TEST_DNS_MUTATION:-}" == "YES" ]] \
        || die 'Set VW_NOBLE_TEST_DNS_MUTATION=YES before testing the managed DNS updater.'
    configured_domain="$(runtime_config_value DOMAIN "")" \
        || die 'Cannot load the installed runtime DOMAIN before DNS mutation.'
    configured_domain="$(printf '%s' "$configured_domain" | tr '[:upper:]' '[:lower:]')"
    [[ "$configured_domain" == "$DNS_MUTATION_DOMAIN" ]] \
        || die "Configured runtime DOMAIN '$configured_domain' does not match the acknowledged DNS mutation domain '$DNS_MUTATION_DOMAIN'."
}

systemd_job_execution_succeeded() {
    local unit="$1" before_start="$2" after_start result status
    after_start="$(systemctl show "$unit" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)"
    result="$(systemctl show "$unit" --property=Result --value 2>/dev/null || true)"
    status="$(systemctl show "$unit" --property=ExecMainStatus --value 2>/dev/null || true)"

    [[ "$after_start" =~ ^[0-9]+$ && "$after_start" != "0" && "$after_start" != "$before_start" ]] || {
        log "Managed job did not record a new ExecStart invocation: $unit"
        return 1
    }
    [[ "$result" == "success" ]] || {
        log "Managed job result is not success: $unit result=${result:-unknown}"
        return 1
    }
    case "$unit" in
        vaultwarden-health.service)
            [[ "$status" == "0" || "$status" == "1" ]] || {
                log "Health job did not execute to an accepted real result: $unit status=${status:-unknown}"
                return 1
            }
            ;;
        *)
            [[ "$status" == "0" ]] || {
                if [[ "$status" == "75" ]]; then
                    log "Managed job skipped because of operation-lock contention; certification requires a real execution: $unit"
                else
                    log "Managed job did not execute successfully: $unit status=${status:-unknown}"
                fi
                return 1
            }
            ;;
    esac
}

systemd_jobs() {
    local unit before_start
    for unit in \
        vaultwarden-health.service \
        vaultwarden-db-backup.service \
        vaultwarden-full-backup.service \
        vaultwarden-maintenance.service \
        vaultwarden-dns-update.service \
        vaultwarden-firewall-update.service; do
        if [[ "$unit" == "vaultwarden-dns-update.service" ]]; then
            validate_dns_mutation_scope
        fi
        before_start="$(systemctl show "$unit" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)"
        systemctl start "$unit"
        systemd_job_execution_succeeded "$unit" "$before_start" || return 1
    done
}

manual_systemd_install_check() (
    local timer cleanup_rc
    local -a timers=(
        vaultwarden-maintenance.timer
        vaultwarden-db-backup.timer
        vaultwarden-full-backup.timer
        vaultwarden-health.timer
        vaultwarden-dns-update.timer
        vaultwarden-firewall-update.timer
    )

    disable_timers_until_custody() {
        local managed_timer
        for managed_timer in "${timers[@]}"; do
            systemctl disable --now "$managed_timer" >/dev/null 2>&1 || true
        done
        for managed_timer in "${timers[@]}"; do
            if systemctl is-enabled --quiet "$managed_timer"; then
                log "Managed timer is still enabled before recovery custody: $managed_timer"
                return 1
            fi
            if systemctl is-active --quiet "$managed_timer"; then
                log "Managed timer is still active before recovery custody: $managed_timer"
                return 1
            fi
        done
    }

    cleanup_pre_custody_timers() {
        cleanup_rc=$?
        trap - EXIT
        if ! disable_timers_until_custody; then
            log 'Could not leave all managed timers disabled before recovery custody.'
            exit 1
        fi
        exit "$cleanup_rc"
    }

    # Canonical manual install enables timers for future boots before it returns.
    # EXIT cleanup covers ordinary success/failure and catchable termination and
    # leaves timers disabled after this helper returns, but it cannot eliminate
    # the narrow abrupt power-loss/SIGKILL window while the canonical installer
    # itself is enabling them. Operators must not reboot/power-cycle during this
    # validation step. activate-automation is the only later controller phase
    # allowed to intentionally re-enable/start recurring automation.
    trap cleanup_pre_custody_timers EXIT
    bash ./utilities/setup-systemd.sh install --no-enable-now || return 1
    for timer in "${timers[@]}"; do
        systemctl is-enabled --quiet "$timer" || return 1
        ! systemctl is-active --quiet "$timer" || return 1
    done
    systemctl is-enabled --quiet vaultwarden-startup.service
)

post_uninstall_check() {
    local etc_dir="${1:-/etc/vaultwarden}"
    local runtime_dir="${2:-/run/vaultwarden-oci}"
    local checkout_root="${3:-$ROOT}"
    local compose_project="${4:-vaultwarden-oci}"
    read_original_state_path
    [[ ! -e "$etc_dir" ]] || return 1
    [[ ! -e "$runtime_dir" ]] || return 1
    [[ ! -e "$PROJECT_STATE_PATH" ]] || return 1
    [[ ! -e "$checkout_root/.env" ]] || return 1
    [[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$compose_project" 2>/dev/null)" ]] || return 1
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

recovery_kit_recipient() (
    local kit="$1" workspace="" key_file recipient
    workspace="$(create_sensitive_workspace acceptance-recovery-key)" || return 1
    trap '[[ -z "${workspace:-}" ]] || remove_sensitive_workspace "$workspace" >/dev/null 2>&1 || true' EXIT
    key_file="$workspace/recovery-kit-age-key.txt"
    install -m 0600 /dev/null "$key_file" || return 1
    write_recovery_kit_identity "$kit" "$key_file" || return 1
    recipient="$(age-keygen -y "$key_file" 2>/dev/null)" || return 1
    [[ "$recipient" == age1* ]] || return 1
    remove_sensitive_workspace "$workspace" || return 1
    workspace=""
    printf '%s
' "$recipient"
)

validate_recovery_recipient_binding() {
    local path="$1" live_key="${2:-/etc/vaultwarden/age-key.txt}"
    local old_recipient new_recipient live_recipient
    old_recipient="$(recovery_kit_recipient "$RECOVERY_KIT")" \
        || die 'Pre-DR recovery kit does not contain a usable Age identity.'
    new_recipient="$(recovery_kit_recipient "$path")" \
        || die 'Post-restore recovery kit does not contain a usable Age identity.'
    [[ -f "$live_key" && ! -L "$live_key" ]] \
        || die 'Active operational Age key is unavailable for rotated-custody verification.'
    live_recipient="$(age-keygen -y "$live_key" 2>/dev/null)" \
        || die 'Active operational Age key cannot derive its recipient.'
    [[ "$new_recipient" == "$live_recipient" ]] \
        || die 'Post-restore recovery kit Age identity does not match the active rotated operational key.'
    [[ "$new_recipient" != "$old_recipient" ]] \
        || die 'Post-restore Age identity matches the pre-DR identity; key rotation/custody was not proven.'
    VALIDATED_RECOVERY_RECIPIENT="$new_recipient"
}

recovery_kit_inventory() {
    local recovery_dir="/root/vaultwarden-recovery"
    [[ -d "$recovery_dir" ]] || return 0
    find "$recovery_dir" -maxdepth 1 -type f -name 'vaultwarden-recovery-kit-*.txt' -print 2>/dev/null \
        | LC_ALL=C sort
}

export_post_restore_full_recovery_kit() {
    local before after kit restore_epoch mtime digest
    local -a new_kits=()
    before="$STATE_ROOT/post-restore-kit-before.list"
    after="$STATE_ROOT/post-restore-kit-after.list"
    recovery_kit_inventory > "$before"
    log 'Exporting the canonical full post-restore recovery kit. If prompted about encrypted email, answer no so the protected local file remains available for the custody copy.'
    bash ./utilities/secrets-export-recovery-kit.sh
    recovery_kit_inventory > "$after"
    mapfile -t new_kits < <(comm -13 "$before" "$after")
    [[ ${#new_kits[@]} -eq 1 ]] || {
        log "Expected exactly one newly published full recovery kit; found ${#new_kits[@]}."
        log 'If encrypted email removed the local plaintext copy, resume this phase and decline email delivery so the exact exported kit can be copied to the recovery medium.'
        return 1
    }
    kit="${new_kits[0]}"
    [[ -f "$kit" && ! -L "$kit" ]] || return 1
    restore_epoch="$(meta_get RESTORE_COMPLETED_EPOCH)"
    mtime="$(stat -c '%Y' "$kit")"
    [[ "$restore_epoch" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || return 1
    (( mtime >= restore_epoch )) || {
        log 'Canonical full recovery kit predates the completed restore.'
        return 1
    }
    recovery_kit_has_integrity_hmac "$kit" || {
        log 'Canonical full recovery kit is missing a usable backup-integrity HMAC field.'
        return 1
    }
    digest="$(sha_file "$kit")"
    meta_add POST_RESTORE_EXPORTED_KIT_BASENAME "$(basename "$kit")"
    meta_add POST_RESTORE_EXPORTED_KIT_SHA256 "$digest"
    log "Canonical full post-restore recovery kit exported: $kit"
    log 'Copy this exact file to the non-root mounted recovery medium, then resume with --post-restore-recovery-kit FILE.'
}

validate_post_restore_recovery_kit() {
    local path root_dev kit_dev kit_target restore_epoch mtime old_digest new_digest exported_digest exported_basename
    [[ -n "$POST_RESTORE_RECOVERY_KIT" ]] || {
        exported_basename="$(meta_get POST_RESTORE_EXPORTED_KIT_BASENAME)"
        log 'Canonical restore also publishes vaultwarden-age-key-rotation-*.txt; that file is only an Age-rotation handoff and is NOT a full recovery kit.'
        if [[ -n "$exported_basename" ]]; then
            log "Copy the exact canonical full kit exported by this run: /root/vaultwarden-recovery/$exported_basename"
        else
            log 'No canonical full recovery-kit export is checkpointed; resume the recovery-export phase first.'
        fi
        die 'Resume with --post-restore-recovery-kit FILE after that exact full kit is secured on the external recovery medium.'
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
    recovery_kit_has_integrity_hmac "$path" \
        || die 'Post-restore recovery kit is missing a usable backup-integrity HMAC field.'
    old_digest="$(meta_get RECOVERY_KIT_SHA256)"
    new_digest="$(sha_file "$path")"
    exported_digest="$(meta_get POST_RESTORE_EXPORTED_KIT_SHA256)"
    [[ "$exported_digest" =~ ^[0-9a-f]{64}$ ]] \
        || die 'Canonical post-restore full recovery-kit export digest is missing.'
    [[ "$new_digest" == "$exported_digest" ]] \
        || die 'Post-restore recovery kit does not match the exact canonical full kit exported by this acceptance run.'
    [[ "$new_digest" != "$old_digest" ]] || die 'Post-restore recovery kit matches the pre-DR kit; rotated custody was not proven.'
    validate_recovery_recipient_binding "$path"
    POST_RESTORE_RECOVERY_KIT="$path"
    meta_add POST_RESTORE_RECOVERY_KIT_PATH_HASH "$(hash_text "$path")"
    meta_add POST_RESTORE_RECOVERY_KIT_SHA256 "$new_digest"
    meta_add POST_RESTORE_AGE_RECIPIENT_HASH "$(hash_text "$VALIDATED_RECOVERY_RECIPIENT")"
}

parse() {
    while (($#)); do
        case "$1" in
            --recovery-kit) [[ $# -ge 2 ]] || die '--recovery-kit requires a value.'; RECOVERY_KIT="$2"; shift 2 ;;
            --rclone-remote) [[ $# -ge 2 ]] || die '--rclone-remote requires a value.'; RCLONE_REMOTE="$2"; shift 2 ;;
            --rclone-path) [[ $# -ge 2 ]] || die '--rclone-path requires a value.'; RCLONE_REMOTE_PATH="$2"; shift 2 ;;
            --rclone-config) [[ $# -ge 2 ]] || die '--rclone-config requires a value.'; RCLONE_CONFIG_PATH="$2"; shift 2 ;;
            --application-e2e) [[ $# -ge 2 ]] || die '--application-e2e requires a value.'; APPLICATION_E2E="$2"; shift 2 ;;
            --post-restore-recovery-kit) [[ $# -ge 2 ]] || die '--post-restore-recovery-kit requires a value.'; POST_RESTORE_RECOVERY_KIT="$2"; shift 2 ;;
            --dns-mutation-domain) [[ $# -ge 2 ]] || die '--dns-mutation-domain requires a value.'; DNS_MUTATION_DOMAIN="$2"; shift 2 ;;
            --allow-dns-mutation) ALLOW_DNS_MUTATION=true; shift ;;
            --destructive) DESTRUCTIVE=true; shift ;;
            --skip-reboot) SKIP_REBOOT=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

validate_inputs() {
    [[ -n "$RECOVERY_KIT" && -n "$RCLONE_REMOTE" && -n "$RCLONE_REMOTE_PATH" \
        && -n "$RCLONE_CONFIG_PATH" && -n "$APPLICATION_E2E" && -n "$DNS_MUTATION_DOMAIN" ]] \
        || die 'Recovery kit, rclone remote/path/config, application E2E hook, and DNS mutation domain are required.'
    [[ "$RCLONE_REMOTE" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid rclone remote name.'
    RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH#/}"
    RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH%/}"
    [[ -n "$RCLONE_REMOTE_PATH" && "$RCLONE_REMOTE_PATH" != *".."* \
        && "$RCLONE_REMOTE_PATH" =~ ^[A-Za-z0-9_./-]+$ ]] \
        || die 'Invalid rclone path; use a relative path without .. or unsafe characters.'
    DNS_MUTATION_DOMAIN="$(printf '%s' "$DNS_MUTATION_DOMAIN" | tr '[:upper:]' '[:lower:]')"
    [[ "$DNS_MUTATION_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        || die 'Invalid DNS mutation domain.'
    [[ "$ALLOW_DNS_MUTATION" == "true" ]] \
        || die 'Pass --allow-dns-mutation for the named dedicated acceptance hostname.'
    [[ "${VW_NOBLE_TEST_DNS_MUTATION:-}" == "YES" ]] \
        || die 'Set VW_NOBLE_TEST_DNS_MUTATION=YES together with --allow-dns-mutation.'
    RECOVERY_KIT="$(external_file "$RECOVERY_KIT" 'recovery kit')"
    RCLONE_CONFIG_PATH="$(external_file "$RCLONE_CONFIG_PATH" 'rclone config')"
    validate_e2e_hook
    if [[ -n "$POST_RESTORE_RECOVERY_KIT" ]]; then
        POST_RESTORE_RECOVERY_KIT="$(external_file "$POST_RESTORE_RECOVERY_KIT" 'post-restore recovery kit')"
    fi
    if [[ "$DESTRUCTIVE" == "true" ]]; then
        validate_destructive_survival
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
                save_phase canary
                ;;
            canary)
                step application-before-dr "$APPLICATION_E2E"
                meta_add PRE_DR_E2E_COMPLETED_EPOCH "$(date +%s)"
                save_phase backups
                ;;
            backups)
                step db-backup-rclone env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
                    RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
                step dr-full-backup run_and_bind_full_backup DR_SOURCE
                step backup-verify bash ./backup.sh verify
                step backup-sync env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
                    RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh sync
                step remote-list env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
                    RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./restore.sh list --remote
                step pre-dr-recovery-kit-inspect verify_bound_backup_with_recovery_kit DR_SOURCE "$RECOVERY_KIT"
                save_phase automation
                ;;
            automation)
                step systemd-validate bash ./utilities/setup-systemd.sh validate
                step dns-mutation-scope validate_dns_mutation_scope
                step systemd-jobs systemd_jobs
                step docker-restart systemctl restart docker.service
                step smoke-after-docker-restart bash ./utilities/smoke-test.sh
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
                step pre-uninstall-recovery-gate pre_uninstall_recovery_gate
                step uninstall-reset bash ./utilities/uninstall-vaultwarden.sh run --test-reset --i-have-saved-my-recovery-kit --force
                step uninstall-residuals post_uninstall_check
                save_phase restore
                ;;
            restore)
                log 'Certification requires a fresh post-reset remote download. If it fails, the retained pre-uninstall authenticated cache remains under STATE_ROOT for emergency non-certifying recovery; do not treat that fallback as acceptance evidence.'
                step dr-source-download download_bound_backup DR_SOURCE restore-source
                step exact-full-restore run_with_sensitive_tmp env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
                    RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./restore.sh interactive --remote --file "$BOUND_BACKUP_FILE" \
                    --from-recovery-kit "$RECOVERY_KIT" --start-policy manual --force
                meta_add RESTORE_COMPLETED_EPOCH "$(date +%s)"
                meta_add RESTORED_BACKUP_BASENAME "$(meta_get DR_SOURCE_BACKUP_BASENAME)"
                meta_add RESTORED_BACKUP_ARCHIVE_SHA256 "$(meta_get DR_SOURCE_BACKUP_ARCHIVE_SHA256)"
                save_phase post-restore-validation
                rm -rf -- "$STATE_ROOT/restore-source" "$STATE_ROOT/pre-uninstall-recovery-cache" || true
                ;;
            post-restore-validation)
                step repair-permissions bash ./utilities/repair-permissions.sh
                step startup bash ./startup.sh
                step systemd-install-manual manual_systemd_install_check
                step make-health-after-restore make health
                step email-after-restore bash ./maintenance.sh test-email --verbose
                step pre-production-after-restore bash ./utilities/pre-production-drill.sh
                step application-after-dr "$APPLICATION_E2E"
                save_phase recovery-export
                ;;
            recovery-export)
                step post-restore-full-kit-export export_post_restore_full_recovery_kit
                save_phase recovery-custody
                ;;
            recovery-custody)
                validate_post_restore_recovery_kit
                save_phase activate-automation
                ;;
            activate-automation)
                step dns-mutation-scope-after-restore validate_dns_mutation_scope
                step systemd-activate bash ./utilities/setup-systemd.sh install --enable-now
                step systemd-after-restore bash ./utilities/setup-systemd.sh validate
                step smoke-after-restore bash ./utilities/smoke-test.sh
                save_phase final-backup
                ;;
            final-backup)
                step post-dr-db env RCLONE_REMOTE_NAME="$RCLONE_REMOTE" RCLONE_REMOTE_PATH="$RCLONE_REMOTE_PATH" \
                    RCLONE_CONFIG="$RCLONE_CONFIG_PATH" bash ./backup.sh run db --rclone
                step post-dr-full run_and_bind_full_backup POST_DR
                step post-dr-verify bash ./backup.sh verify
                step post-dr-recovery-kit-inspect verify_bound_backup_with_recovery_kit POST_DR "$POST_RESTORE_RECOVERY_KIT"
                save_phase complete
                ;;
            complete)
                log "FULL ACCEPTANCE PASSED: $(current_sha)"
                log "DR source: $(meta_get DR_SOURCE_BACKUP_BASENAME) $(meta_get DR_SOURCE_BACKUP_ARCHIVE_SHA256)"
                log "Post-DR full: $(meta_get POST_DR_BACKUP_BASENAME) $(meta_get POST_DR_BACKUP_ARCHIVE_SHA256)"
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
    acquire_controller_lock
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
