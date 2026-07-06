#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ETC_SNAPSHOT="$(mktemp -d)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0

USB_RECIPIENT="age1usb0000000000000000000000000000000000000000000000000000000"
NEW_RECIPIENT="age1new0000000000000000000000000000000000000000000000000000000"

cleanup_all() {
    if (( EUID == 0 )); then
        rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    else
        rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
    fi
}
trap cleanup_all EXIT

if [[ -d /etc/vaultwarden ]]; then
    cp -a /etc/vaultwarden/. "$REAL_ETC_SNAPSHOT/" 2>/dev/null || true
fi

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

assert_real_etc_unchanged() {
    if [[ -d /etc/vaultwarden ]]; then
        diff -qr "$REAL_ETC_SNAPSHOT" /etc/vaultwarden >/dev/null 2>&1 || fail 'real /etc/vaultwarden changed'
    fi
}

run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@"
    assert_real_etc_unchanged
    pass "$name"
}

assert_file_equals() {
    local expected="$1" actual="$2" label="$3"
    cmp -s "$expected" "$actual" || fail "$label"
}

assert_file_missing() {
    [[ ! -e "$1" ]] || fail "expected missing: $1"
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

canonical_path() {
    /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

env_value() {
    local key="$1" file="$2"
    if [[ -r "$file" ]]; then
        awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); found = 1 } END { exit found ? 0 : 1 }' "$file"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); found = 1 } END { exit found ? 0 : 1 }' "$file"
    else
        return 1
    fi
}

env_has_value() {
    local key="$1" expected="$2" file="$3"
    local actual
    actual="$(env_value "$key" "$file")" || return 1
    [[ "$actual" == "$expected" ]]
}

make_case() {
    local dir="$TEST_ROOT/case-$TESTS_RUN"
    mkdir -p "$dir/state/config" "$dir/state/secrets" "$dir/state/data" "$dir/repo" "$dir/etc" "$dir/mockbin"
    cp "$ROOT/recover.sh" "$dir/repo/recover.sh"
    cp -a "$ROOT/lib" "$dir/repo/lib"
    mkdir -p "$dir/repo/utilities"
    cp "$ROOT/utilities/env-edit.sh" "$dir/repo/utilities/env-edit.sh"
    cp "$ROOT/docker-compose.yml.example" "$dir/repo/docker-compose.yml.example"
    chmod +x "$dir/repo/recover.sh" "$dir/repo/utilities/env-edit.sh"
    cat > "$dir/state/config/dr-manifest.env" <<EOF_MANIFEST
DOMAIN=https://vault.example.test
REPO_URL=https://example.test/repo.git
REPO_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OFFLINE_AGE_RECIPIENT=$USB_RECIPIENT
STATE_LAYOUT_VERSION=1
MANIFEST_UPDATED_AT=2026-01-01T00:00:00Z
EOF_MANIFEST
    cat > "$dir/state/config/install.env" <<EOF_ENV
PROJECT_STATE_DIR=$dir/state
DATA_VOLUME_MOUNT=$dir/state
DATA_VOLUME_DEVICE=/dev/mock
SOPS_AGE_KEY_FILE=$dir/etc/age-key.txt
EOF_ENV
    printf 'ciphertext-v1\n' > "$dir/state/secrets/secrets.yaml"
    printf 'old-policy\n' > "$dir/repo/.sops.yaml"
    printf 'old-key\n' > "$dir/etc/age-key.txt"
    printf 'usb-key\n' > "$dir/usb-key.txt"
    printf '%s\n' "$dir"
}

write_mocks() {
    local dir="$1"
    local mock="$dir/mockbin"
    cat > "$mock/mountpoint" <<'MOUNT'
#!/usr/bin/env bash
[[ "${MOCK_MOUNTPOINT_FAIL:-false}" == true ]] && exit 1
exit 0
MOUNT
    cat > "$mock/findmnt" <<'FINDMNT'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_FINDMNT_SOURCE:-/dev/mock-source}"
FINDMNT
    cat > "$mock/blkid" <<'BLKID'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_BLKID_UUID:-1111-2222}"
BLKID
    cat > "$mock/realpath" <<'REALPATH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-e" ]]; then
    shift
    [[ $# -eq 1 && -e "${1:-}" ]] || exit 1
    cd "$(dirname "$1")" || exit 1
    printf '%s/%s\n' "$(pwd)" "$(basename "$1")"
    exit 0
fi
exec /bin/realpath "$@"
REALPATH
    cat > "$mock/docker" <<'DOCKER'
#!/usr/bin/env bash
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    echo 'Docker Compose mock'
    exit 0
fi
exit 0
DOCKER
    cat > "$mock/curl" <<'CURL'
#!/usr/bin/env bash
exit "${MOCK_CURL_EXIT:-0}"
CURL
    cat > "$mock/git" <<'GIT'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${4:-}" == HEAD ]]; then
    printf '%s\n' "${MOCK_GIT_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    exit 0
fi
exit 0
GIT
    cat > "$mock/age-keygen" <<'AGE'
#!/usr/bin/env bash
if [[ "${1:-}" == -y ]]; then
    [[ -n "${MOCK_USB_KEY_PATH:-}" ]] || exit 2
    if [[ "$(basename "${2:-}")" == "usb-key.txt" ]]; then
        printf '%s\n' "$MOCK_USB_RECIPIENT"
    else
        printf '%s\n' "$MOCK_NEW_RECIPIENT"
    fi
    exit 0
fi
if [[ "${1:-}" == -o ]]; then
    printf 'new-private-key\n' > "$2"
    exit 0
fi
exit 1
AGE
    cat > "$mock/sops" <<'SOPS'
#!/usr/bin/env bash
mode=""; target=""; config=""
prev=""
for arg in "$@"; do
    case "$arg" in
        --config) prev="config" ;;
        updatekeys) mode="updatekeys" ;;
        -d|--decrypt) mode="decrypt" ;;
        --*) ;;
        *)
            if [[ "$prev" == config ]]; then
                config="$arg"; prev=""
            else
                target="$arg"
            fi
            ;;
    esac
done
case "$mode" in
    updatekeys)
        if [[ "${MOCK_SOPS_SIGNAL:-}" == TERM ]]; then
            kill -TERM "$PPID"
            sleep 1
        elif [[ "${MOCK_SOPS_SIGNAL:-}" == INT ]]; then
            kill -INT "$PPID"
            sleep 1
        fi
        if [[ "${MOCK_SOPS_PAUSE:-}" == updatekeys ]]; then
            [[ -n "${MOCK_SIGNAL_READY:-}" ]] && : > "$MOCK_SIGNAL_READY"
            sleep 30
        fi
        [[ "${MOCK_SOPS_FAIL_OP:-}" == updatekeys ]] && exit 1
        cat "$config" >> "$target"
        printf '# mock-age=%s,%s\n' "$MOCK_NEW_RECIPIENT" "$MOCK_USB_RECIPIENT" >> "$target"
        ;;
    decrypt)
        canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_staged && -n "${MOCK_CIPHER_STAGING:-}" && "$(canon "$target")" == "$(canon "$MOCK_CIPHER_STAGING")" ]]; then exit 1; fi
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_live && -n "${MOCK_LIVE_CIPHER:-}" && "$(canon "$target")" == "$(canon "$MOCK_LIVE_CIPHER")" ]]; then exit 1; fi
        cat "$target" >/dev/null
        ;;
    *) exit 1 ;;
esac
SOPS
    cat > "$mock/mv" <<'MV'
#!/usr/bin/env bash
last="${@: -1}"
canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
if [[ -n "${MOCK_MV_FAIL_DEST:-}" && "$(canon "$last")" == "$(canon "$MOCK_MV_FAIL_DEST")" ]]; then
    exit 1
fi
if [[ -n "${MOCK_MV_SIGNAL_DEST:-}" && "$(canon "$last")" == "$(canon "$MOCK_MV_SIGNAL_DEST")" ]]; then
    /bin/mv "$@" || exit $?
    kill "-${MOCK_MV_SIGNAL_NAME:-TERM}" "$PPID"
    sleep 1
    exit 0
fi
exec /bin/mv "$@"
MV
    cat > "$mock/touch" <<'TOUCH'
#!/usr/bin/env bash
canon(){ /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
for arg in "$@"; do
    if [[ -n "${MOCK_TOUCH_SIGNAL_PATH:-}" && "$(canon "$arg")" == "$(canon "$MOCK_TOUCH_SIGNAL_PATH")" ]]; then
        /usr/bin/touch "$@" || exit $?
        kill "-${MOCK_TOUCH_SIGNAL_NAME:-TERM}" "$PPID"
        sleep 1
        exit 0
    fi
done
exec /usr/bin/touch "$@"
TOUCH
    chmod +x "$mock"/*
}

run_recover() {
    local dir="$1" rc=0
    shift || true
    [[ -n "$dir" ]] || fail 'test dir required'
    export MOCK_USB_KEY_PATH="$dir/usb-key.txt"
    [[ -n "$MOCK_USB_KEY_PATH" ]] || fail 'MOCK_USB_KEY_PATH must be set'
    export MOCK_USB_RECIPIENT="$USB_RECIPIENT"
    export MOCK_NEW_RECIPIENT="$NEW_RECIPIENT"
    export MOCK_LIVE_CIPHER="$dir/state/secrets/secrets.yaml"
    set +e
    env PATH="$dir/mockbin:$PATH" \
        MOCK_FINDMNT_SOURCE="/dev/mock-source" \
        VW_TEST_MODE=true \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
        MOCK_MV_FAIL_DEST="${MOCK_MV_FAIL_DEST:-}" \
        MOCK_MV_SIGNAL_DEST="${MOCK_MV_SIGNAL_DEST:-}" \
        MOCK_MV_SIGNAL_NAME="${MOCK_MV_SIGNAL_NAME:-}" \
        MOCK_TOUCH_SIGNAL_PATH="${MOCK_TOUCH_SIGNAL_PATH:-}" \
        MOCK_TOUCH_SIGNAL_NAME="${MOCK_TOUCH_SIGNAL_NAME:-}" \
        MOCK_CURL_EXIT="${MOCK_CURL_EXIT:-0}" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" "$@" > "$dir/out" 2>&1
    rc=$?
    set -e
    return "$rc"
}

run_recover_async() {
    local dir="$1"
    shift || true
    export MOCK_USB_KEY_PATH="$dir/usb-key.txt"
    export MOCK_USB_RECIPIENT="$USB_RECIPIENT"
    export MOCK_NEW_RECIPIENT="$NEW_RECIPIENT"
    export MOCK_LIVE_CIPHER="$dir/state/secrets/secrets.yaml"
    env PATH="$dir/mockbin:$PATH" \
        MOCK_FINDMNT_SOURCE="/dev/mock-source" \
        VW_TEST_MODE=true \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_SOPS_SIGNAL="${MOCK_SOPS_SIGNAL:-}" \
        MOCK_SOPS_PAUSE="${MOCK_SOPS_PAUSE:-}" \
        MOCK_SIGNAL_READY="${MOCK_SIGNAL_READY:-}" \
        MOCK_MV_FAIL_DEST="${MOCK_MV_FAIL_DEST:-}" \
        MOCK_MV_SIGNAL_DEST="${MOCK_MV_SIGNAL_DEST:-}" \
        MOCK_MV_SIGNAL_NAME="${MOCK_MV_SIGNAL_NAME:-}" \
        MOCK_TOUCH_SIGNAL_PATH="${MOCK_TOUCH_SIGNAL_PATH:-}" \
        MOCK_TOUCH_SIGNAL_NAME="${MOCK_TOUCH_SIGNAL_NAME:-}" \
        MOCK_CURL_EXIT="${MOCK_CURL_EXIT:-0}" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" "$@" > "$dir/out" 2>&1 &
    printf '%s\n' "$!"
}

setup_startup() {
    local dir="$1"
    cat > "$dir/startup.sh" <<'START'
#!/usr/bin/env bash
echo 'mock startup: OK'
START
    chmod +x "$dir/startup.sh"
}

setup_startup_with_env_sync() {
    local dir="$1"
    cat > "$dir/startup.sh" <<START
#!/usr/bin/env bash
set -euo pipefail
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n env VW_SYNC_ETC_DIR="$dir/etc" "$dir/repo/utilities/env-edit.sh" sync
    echo 'env-sync: ran'
else
    echo 'env-sync: skipped'
fi
echo 'mock startup: OK'
START
    chmod +x "$dir/startup.sh"
}

test_missing_state_dir() {
    local out="$TEST_ROOT/missing-state.out"
    if bash "$ROOT/recover.sh" --key /nope > "$out" 2>&1; then fail 'missing state should fail'; fi
    grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$out" || fail 'usage missing'
}

test_missing_key() {
    local out="$TEST_ROOT/missing-key.out"
    if bash "$ROOT/recover.sh" --state-dir /nope > "$out" 2>&1; then fail 'missing key should fail'; fi
    grep -q 'Usage: ./recover.sh --state-dir DIR --key FILE' "$out" || fail 'usage missing'
}

test_non_root_bypass_requires_test_mode() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if env PATH="$dir/mockbin:$PATH" \
        VW_RECOVER_TEST_ALLOW_NON_ROOT=true \
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_DEV_BY_UUID_DIR="$dir/dev-by-uuid" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" > "$dir/out" 2>&1; then
        fail 'single-variable non-root bypass should fail'
    fi
    grep -q 'ERROR: Must run as root.' "$dir/out" || fail 'root error missing when VW_TEST_MODE is absent'
}

test_non_mounted() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode block; then fail 'non-mounted block should fail'; fi
    grep -q 'ERROR: State directory is not a mounted data/block volume. Attach and mount the data volume first.' "$dir/out" || fail 'mount error mismatch'
}

test_boot_mode_clears_block_env() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if ! MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'boot mode should not require mountpoint'; fi
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'project state not set'
    grep -q '^DATA_VOLUME_MOUNT=$' "$dir/state/config/install.env" || fail 'data mount not cleared'
    grep -q '^DATA_VOLUME_DEVICE=$' "$dir/state/config/install.env" || fail 'data device not cleared'
}

test_block_mode_uuid_device() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    mkdir -p "$dir/dev-by-uuid"
    touch "$dir/mock-source"
    ln -sf "$dir/mock-source" "$dir/dev-by-uuid/1111-2222"
    if ! run_recover "$dir" --storage-mode block; then cat "$dir/out"; fail 'block mode should succeed'; fi
    grep -q "^DATA_VOLUME_DEVICE=$dir/dev-by-uuid/1111-2222$" "$dir/state/config/install.env" || fail 'uuid device path not used'
    [[ -e "$dir/state/.vw-data-volume" ]] || fail 'sentinel missing'
}

test_final_permissions() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    chmod 0777 "$dir/state/config/install.env" "$dir/state/config/dr-manifest.env" "$dir/state/secrets/secrets.yaml" "$dir/repo/.sops.yaml" "$dir/etc/age-key.txt"
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'permissions case failed'; fi
    [[ "$(file_mode "$dir/repo/.sops.yaml")" == "644" ]] || fail '.sops mode mismatch'
    [[ "$(file_mode "$dir/etc/age-key.txt")" == "600" ]] || fail 'active key mode mismatch'
    [[ "$(file_mode "$dir/state/config/install.env")" == "600" ]] || fail 'install env mode mismatch'
    [[ "$(file_mode "$dir/state/config/dr-manifest.env")" == "600" ]] || fail 'manifest mode mismatch'
    [[ "$(file_mode "$dir/state/secrets/secrets.yaml")" == "600" ]] || fail 'secrets mode mismatch'
}

test_cleanup_removes_staged_key() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir" --storage-mode boot; then fail 'updatekeys failure should fail'; fi
    if find "$dir" -name 'new-age-key.txt' -type f | grep -q .; then fail 'staged private key leaked'; fi
}

test_updatekeys_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir"; then fail 'updatekeys failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher changed on updatekeys failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key changed on updatekeys failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy changed on updatekeys failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env changed on updatekeys failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest changed on updatekeys failure'
}

test_active_key_promotion_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    if MOCK_MV_FAIL_DEST="$dir/etc/age-key.txt" run_recover "$dir"; then fail 'key promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after key failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after key failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy changed after key failure'
}

test_policy_promotion_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    if MOCK_MV_FAIL_DEST="$dir/repo/.sops.yaml" run_recover "$dir"; then fail 'policy promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after policy failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after policy failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy not restored after policy failure'
}

test_install_env_promotion_failure_rolls_back_all_artifacts() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_MV_FAIL_DEST="$dir/state/config/install.env" run_recover "$dir"; then fail 'install.env promotion failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after install.env failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key not restored after install.env failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy not restored after install.env failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env not restored after install.env failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest changed after install.env failure'
}

test_final_decrypt_failure_no_prior_artifacts() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/etc/age-key.txt" "$dir/repo/.sops.yaml"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
    if MOCK_SOPS_FAIL_OP=decrypt_live run_recover "$dir"; then fail 'live decrypt failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after final decrypt failure'
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" 'install.env not restored after final decrypt failure'
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" 'manifest not restored after final decrypt failure'
    assert_file_missing "$dir/etc/age-key.txt"
    assert_file_missing "$dir/repo/.sops.yaml"
    assert_file_missing "$dir/state/.vw-data-volume"
}

test_existing_sentinel_survives_precommit_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    touch "$dir/state/.vw-data-volume"
    if MOCK_SOPS_FAIL_OP=decrypt_live run_recover "$dir"; then fail 'live decrypt failure should fail'; fi
    [[ -e "$dir/state/.vw-data-volume" ]] || fail 'pre-existing sentinel was removed'
}

test_precommit_signals_exit_and_do_not_continue() {
    local sig expected_rc dir
    for sig in INT TERM; do
        dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
        cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"; cp "$dir/state/config/install.env" "$dir/install.before"; cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
        expected_rc=130
        [[ "$sig" == TERM ]] && expected_rc=143
        local rc
        set +e
        ( MOCK_SOPS_SIGNAL="$sig" run_recover "$dir" )
        rc=$?
        set -e
        [[ "$rc" -eq "$expected_rc" ]] || fail "$sig expected exit $expected_rc, got $rc"
        ! grep -q 'mock startup: OK' "$dir/out" || fail "$sig continued into startup"
        assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" "cipher changed after $sig"
        assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" "key changed after $sig"
        assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" "policy changed after $sig"
        assert_file_equals "$dir/install.before" "$dir/state/config/install.env" "install.env changed after $sig"
        assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" "manifest changed after $sig"
    done
}

assert_recovery_state_unchanged() {
    local dir="$1" label="$2"
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" "cipher changed after $label"
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" "key changed after $label"
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" "policy changed after $label"
    assert_file_equals "$dir/install.before" "$dir/state/config/install.env" "install.env changed after $label"
    assert_file_equals "$dir/manifest.before" "$dir/state/config/dr-manifest.env" "manifest changed after $label"
}

snapshot_recovery_state() {
    local dir="$1"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"
    cp "$dir/etc/age-key.txt" "$dir/key.before"
    cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    cp "$dir/state/config/install.env" "$dir/install.before"
    cp "$dir/state/config/dr-manifest.env" "$dir/manifest.before"
}

test_signal_after_live_cipher_mutation_rolls_back() {
    local dir rc
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"; snapshot_recovery_state "$dir"
    set +e
    ( MOCK_MV_SIGNAL_DEST="$dir/state/secrets/secrets.yaml" MOCK_MV_SIGNAL_NAME=TERM run_recover "$dir" )
    rc=$?
    set -e
    [[ "$rc" -eq 143 ]] || fail "live cipher mutation signal expected 143, got $rc"
    ! grep -q 'mock startup: OK' "$dir/out" || fail 'continued into startup after live cipher signal'
    assert_recovery_state_unchanged "$dir" 'live cipher signal'
}

test_signal_after_new_sentinel_mutation_rolls_back() {
    local dir rc
    dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"; snapshot_recovery_state "$dir"
    set +e
    ( MOCK_TOUCH_SIGNAL_PATH="$dir/state/.vw-data-volume" MOCK_TOUCH_SIGNAL_NAME=TERM run_recover "$dir" --storage-mode block )
    rc=$?
    set -e
    [[ "$rc" -eq 143 ]] || fail "sentinel mutation signal expected 143, got $rc"
    ! grep -q 'mock startup: OK' "$dir/out" || fail 'continued into startup after sentinel signal'
    assert_recovery_state_unchanged "$dir" 'sentinel signal'
    assert_file_missing "$dir/state/.vw-data-volume"
}

test_reconciles_absent_repo_env_before_startup_sync() {
    local dir
    dir=$(make_case); write_mocks "$dir"; setup_startup_with_env_sync "$dir"
    rm -f "$dir/repo/.env"
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'absent repo env recovery failed'; fi
    [[ -f "$dir/repo/.env" ]] || fail 'repo .env was not created'
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/repo/.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'repo .env PROJECT_STATE_DIR not recovered'
    env_has_value DATA_VOLUME_MOUNT "" "$dir/repo/.env" || fail 'repo .env boot DATA_VOLUME_MOUNT not blank'
    env_has_value DATA_VOLUME_DEVICE "" "$dir/repo/.env" || fail 'repo .env boot DATA_VOLUME_DEVICE not blank'
    ! grep -q '^SOPS_AGE_KEY_FILE=' "$dir/repo/.env" || fail 'runtime SOPS_AGE_KEY_FILE leaked into repo .env'
    ! grep -q '^RCLONE_CONFIG=' "$dir/repo/.env" || fail 'runtime RCLONE_CONFIG leaked into repo .env'
    if grep -q 'env-sync: ran' "$dir/out"; then
        [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'env sync undid recovered PROJECT_STATE_DIR'
        env_has_value DATA_VOLUME_MOUNT "" "$dir/state/config/install.env" || fail 'env sync undid boot DATA_VOLUME_MOUNT'
        env_has_value DATA_VOLUME_DEVICE "" "$dir/state/config/install.env" || fail 'env sync undid boot DATA_VOLUME_DEVICE'
    fi
}

test_reconciles_stale_repo_env_before_startup_sync() {
    local dir
    dir=$(make_case); write_mocks "$dir"; setup_startup_with_env_sync "$dir"
    cat > "$dir/repo/.env" <<EOF_STALE
PROJECT_STATE_DIR=$dir/stale-state
DATA_VOLUME_MOUNT=$dir/stale-mount
DATA_VOLUME_DEVICE=/dev/stale
SOPS_AGE_KEY_FILE=$dir/stale-key.txt
RCLONE_CONFIG=$dir/stale-rclone.conf
EOF_STALE
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'stale repo env recovery failed'; fi
    [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/repo/.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'stale repo .env PROJECT_STATE_DIR was not reconciled'
    env_has_value DATA_VOLUME_MOUNT "" "$dir/repo/.env" || fail 'stale repo .env DATA_VOLUME_MOUNT was not reconciled'
    env_has_value DATA_VOLUME_DEVICE "" "$dir/repo/.env" || fail 'stale repo .env DATA_VOLUME_DEVICE was not reconciled'
    ! grep -q '^SOPS_AGE_KEY_FILE=' "$dir/repo/.env" || fail 'stale runtime SOPS_AGE_KEY_FILE persisted into repo .env'
    ! grep -q '^RCLONE_CONFIG=' "$dir/repo/.env" || fail 'stale runtime RCLONE_CONFIG persisted into repo .env'
    if grep -q 'env-sync: ran' "$dir/out"; then
        [[ "$(canonical_path "$(env_value PROJECT_STATE_DIR "$dir/state/config/install.env")")" == "$(canonical_path "$dir/state")" ]] || fail 'env sync restored stale PROJECT_STATE_DIR'
        env_has_value DATA_VOLUME_MOUNT "" "$dir/state/config/install.env" || fail 'env sync restored stale DATA_VOLUME_MOUNT'
        env_has_value DATA_VOLUME_DEVICE "" "$dir/state/config/install.env" || fail 'env sync restored stale DATA_VOLUME_DEVICE'
    fi
}

test_success_fresh_clone() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/repo/.sops.yaml"
    if ! run_recover "$dir"; then cat "$dir/out"; fail 'happy path failed'; fi
    grep -q 'mock startup: OK' "$dir/out" || fail 'startup output missing'
    [[ -f "$dir/etc/age-key.txt" ]] || fail 'new operational key missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher metadata missing mock recipients'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy recipients missing'
    [[ "$(canonical_path "$(env_value SOPS_AGE_KEY_FILE "$dir/state/config/install.env")")" == "$(canonical_path "$dir/etc/age-key.txt")" ]] || fail 'install.env not updated'
    grep -q "OFFLINE_AGE_RECIPIENT=$USB_RECIPIENT" "$dir/state/config/dr-manifest.env" || fail 'manifest recipient not updated'
    grep -q '^MANIFEST_UPDATED_AT=' "$dir/state/config/dr-manifest.env" || fail 'manifest timestamp missing'
    grep -q 'Recovery complete. Vaultwarden passed health check at https://vault.example.test/alive' "$dir/out" || fail 'health success message missing'
}

test_startup_failure_returns_nonzero_without_rollback() {
    local dir; dir=$(make_case); write_mocks "$dir"
    cat > "$dir/startup.sh" <<'START'
#!/usr/bin/env bash
echo 'mock startup: FAIL'
exit 42
START
    chmod +x "$dir/startup.sh"
    if run_recover "$dir"; then fail 'startup failure should return non-zero'; fi
    grep -q 'Startup: FAIL' "$dir/out" || fail 'startup failure marker missing'
    grep -q 'Committed recovery identity/config remains installed.' "$dir/out" || fail 'startup failure commit message missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher artifacts rolled back after startup failure'
    grep -q 'new-private-key' "$dir/etc/age-key.txt" || fail 'active key rolled back after startup failure'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy rolled back after startup failure'
}

test_health_failure_reports_nonzero_without_rollback() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_CURL_EXIT=22 run_recover "$dir"; then fail 'health failure should return non-zero'; fi
    if grep -q 'Vaultwarden is running' "$dir/out"; then fail 'health failure must not say Vaultwarden is running'; fi
    grep -q 'Health check: FAIL' "$dir/out" || fail 'health failure marker missing'
    grep -q 'Recovery artifacts were promoted, but Vaultwarden did not pass the health check.' "$dir/out" || fail 'partial-success message missing'
    grep -q 'Committed recovery identity/config remains installed.' "$dir/out" || fail 'committed artifacts message missing'
    grep -q 'Do not treat the service as healthy until the checks below pass.' "$dir/out" || fail 'operator warning missing'
    grep -Eq 'docker compose -f .*docker-compose\.yml ps' "$dir/out" || fail 'compose ps next step missing'
    grep -Eq 'docker compose -f .*docker-compose\.yml logs --tail=200' "$dir/out" || fail 'compose logs next step missing'
    grep -q 'Failed health URL: https://vault.example.test/alive' "$dir/out" || fail 'failed alive URL missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher artifacts rolled back after health failure'
    grep -q 'new-private-key' "$dir/etc/age-key.txt" || fail 'active key rolled back after health failure'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy rolled back after health failure'
}

run_test 'missing --state-dir prints usage and fails' test_missing_state_dir
run_test 'missing --key prints usage and fails' test_missing_key
run_test 'non-root bypass requires VW_TEST_MODE and recover flag' test_non_root_bypass_requires_test_mode
run_test 'non-mounted state directory prints exact message' test_non_mounted
run_test 'boot storage mode clears block-volume env values' test_boot_mode_clears_block_env
run_test 'block storage mode writes UUID device path and sentinel' test_block_mode_uuid_device
run_test 'final permissions match split contract' test_final_permissions
run_test 'cleanup removes staged private key on failure' test_cleanup_removes_staged_key
run_test 'sops updatekeys failure leaves artifacts unchanged' test_updatekeys_failure
run_test 'active-key promotion failure rolls back artifacts' test_active_key_promotion_failure
run_test 'policy promotion failure rolls back artifacts' test_policy_promotion_failure
run_test 'install.env promotion failure rolls back full recovery scope' test_install_env_promotion_failure_rolls_back_all_artifacts
run_test 'final live-decryption failure restores absent artifacts' test_final_decrypt_failure_no_prior_artifacts
run_test 'pre-existing block sentinel survives pre-commit failure' test_existing_sentinel_survives_precommit_failure
run_test 'pre-commit INT and TERM exit with signal status and stop execution' test_precommit_signals_exit_and_do_not_continue
run_test 'signal after live ciphertext mutation rolls back' test_signal_after_live_cipher_mutation_rolls_back
run_test 'signal after new sentinel mutation rolls back' test_signal_after_new_sentinel_mutation_rolls_back
run_test 'fresh recovery creates repo env before startup sync' test_reconciles_absent_repo_env_before_startup_sync
run_test 'stale repo env is reconciled before startup sync' test_reconciles_stale_repo_env_before_startup_sync
run_test 'successful fresh-clone recovery updates all artifacts' test_success_fresh_clone
run_test 'startup failure after commit exits non-zero without rollback' test_startup_failure_returns_nonzero_without_rollback
run_test 'health-check failure after commit exits non-zero without rollback' test_health_failure_reports_nonzero_without_rollback

[[ "$TESTS_RUN" -eq 22 ]] || fail "expected 22 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
