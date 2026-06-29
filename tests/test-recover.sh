#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ETC_SNAPSHOT="$(mktemp -d)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0

USB_RECIPIENT="age1usb0000000000000000000000000000000000000000000000000000000"
NEW_RECIPIENT="age1new0000000000000000000000000000000000000000000000000000000"

cleanup_all() {
    rm -rf "$TEST_ROOT" "$REAL_ETC_SNAPSHOT"
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

make_case() {
    local dir="$TEST_ROOT/case-$TESTS_RUN"
    mkdir -p "$dir/state/config" "$dir/state/secrets" "$dir/state/data" "$dir/repo" "$dir/etc" "$dir/mockbin"
    cp "$ROOT/recover.sh" "$dir/repo/recover.sh"
    cp -a "$ROOT/lib" "$dir/repo/lib"
    cp "$ROOT/docker-compose.yml.example" "$dir/repo/docker-compose.yml.example"
    chmod +x "$dir/repo/recover.sh"
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
exit 0
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
    if [[ "${2:-}" == "$MOCK_USB_KEY_PATH" ]]; then
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
        [[ "${MOCK_SOPS_FAIL_OP:-}" == updatekeys ]] && exit 1
        cat "$config" >> "$target"
        printf '# mock-age=%s,%s\n' "$MOCK_NEW_RECIPIENT" "$MOCK_USB_RECIPIENT" >> "$target"
        ;;
    decrypt)
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_staged && "$target" == "${MOCK_CIPHER_STAGING:-}" ]]; then exit 1; fi
        if [[ "${MOCK_SOPS_FAIL_OP:-}" == decrypt_live && "$target" == "${MOCK_LIVE_CIPHER:-}" ]]; then exit 1; fi
        cat "$target" >/dev/null
        ;;
    *) exit 1 ;;
esac
SOPS
    cat > "$mock/mv" <<'MV'
#!/usr/bin/env bash
last="${@: -1}"
if [[ -n "${MOCK_MV_FAIL_DEST:-}" && "$last" == "$MOCK_MV_FAIL_DEST" ]]; then
    exit 1
fi
exec /bin/mv "$@"
MV
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
        VW_RECOVER_ETC_DIR="$dir/etc" \
        VW_RECOVER_STARTUP_SCRIPT="$dir/startup.sh" \
        MOCK_USB_KEY_PATH="$MOCK_USB_KEY_PATH" \
        MOCK_USB_RECIPIENT="$MOCK_USB_RECIPIENT" \
        MOCK_NEW_RECIPIENT="$MOCK_NEW_RECIPIENT" \
        MOCK_LIVE_CIPHER="$MOCK_LIVE_CIPHER" \
        MOCK_MOUNTPOINT_FAIL="${MOCK_MOUNTPOINT_FAIL:-false}" \
        MOCK_SOPS_FAIL_OP="${MOCK_SOPS_FAIL_OP:-}" \
        MOCK_MV_FAIL_DEST="${MOCK_MV_FAIL_DEST:-}" \
        bash "$dir/repo/recover.sh" --state-dir "$dir/state" --key "$dir/usb-key.txt" "$@" > "$dir/out" 2>&1
    rc=$?
    set -e
    return "$rc"
}

setup_startup() {
    local dir="$1"
    cat > "$dir/startup.sh" <<'START'
#!/usr/bin/env bash
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

test_non_mounted() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode block; then fail 'non-mounted block should fail'; fi
    grep -q 'ERROR: State directory is not a mounted data/block volume. Attach and mount the data volume first.' "$dir/out" || fail 'mount error mismatch'
}

test_boot_mode_clears_block_env() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if ! MOCK_MOUNTPOINT_FAIL=true run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'boot mode should not require mountpoint'; fi
    grep -q "PROJECT_STATE_DIR=$dir/state" "$dir/state/config/install.env" || fail 'project state not set'
    grep -q '^DATA_VOLUME_MOUNT=$' "$dir/state/config/install.env" || fail 'data mount not cleared'
    grep -q '^DATA_VOLUME_DEVICE=$' "$dir/state/config/install.env" || fail 'data device not cleared'
}

test_block_mode_uuid_device() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    mkdir -p /dev/disk/by-uuid
    touch /dev/mock-source
    ln -sf /dev/mock-source /dev/disk/by-uuid/1111-2222
    if ! run_recover "$dir" --storage-mode block; then cat "$dir/out"; fail 'block mode should succeed'; fi
    grep -q '^DATA_VOLUME_DEVICE=/dev/disk/by-uuid/1111-2222$' "$dir/state/config/install.env" || fail 'uuid device path not used'
    [[ -e "$dir/state/.vw-data-volume" ]] || fail 'sentinel missing'
    rm -f /dev/disk/by-uuid/1111-2222
    rm -f /dev/mock-source
}

test_final_permissions() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    chmod 0777 "$dir/state/config/install.env" "$dir/state/config/dr-manifest.env" "$dir/state/secrets/secrets.yaml" "$dir/repo/.sops.yaml" "$dir/etc/age-key.txt"
    if ! run_recover "$dir" --storage-mode boot; then cat "$dir/out"; fail 'permissions case failed'; fi
    [[ "$(stat -c '%a' "$dir/repo/.sops.yaml")" == "644" ]] || fail '.sops mode mismatch'
    [[ "$(stat -c '%a' "$dir/etc/age-key.txt")" == "600" ]] || fail 'active key mode mismatch'
    [[ "$(stat -c '%a' "$dir/state/config/install.env")" == "600" ]] || fail 'install env mode mismatch'
    [[ "$(stat -c '%a' "$dir/state/config/dr-manifest.env")" == "600" ]] || fail 'manifest mode mismatch'
    [[ "$(stat -c '%a' "$dir/state/secrets/secrets.yaml")" == "600" ]] || fail 'secrets mode mismatch'
}

test_cleanup_removes_staged_key() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir" --storage-mode boot; then fail 'updatekeys failure should fail'; fi
    if find "$dir" -name 'new-age-key.txt' -type f | grep -q .; then fail 'staged private key leaked'; fi
}

test_updatekeys_failure() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"; cp "$dir/etc/age-key.txt" "$dir/key.before"; cp "$dir/repo/.sops.yaml" "$dir/policy.before"
    if MOCK_SOPS_FAIL_OP=updatekeys run_recover "$dir"; then fail 'updatekeys failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher changed on updatekeys failure'
    assert_file_equals "$dir/key.before" "$dir/etc/age-key.txt" 'key changed on updatekeys failure'
    assert_file_equals "$dir/policy.before" "$dir/repo/.sops.yaml" 'policy changed on updatekeys failure'
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

test_final_decrypt_failure_no_prior_artifacts() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/etc/age-key.txt" "$dir/repo/.sops.yaml"
    cp "$dir/state/secrets/secrets.yaml" "$dir/cipher.before"
    if MOCK_SOPS_FAIL_OP=decrypt_live run_recover "$dir"; then fail 'live decrypt failure should fail'; fi
    assert_file_equals "$dir/cipher.before" "$dir/state/secrets/secrets.yaml" 'cipher not restored after final decrypt failure'
    assert_file_missing "$dir/etc/age-key.txt"
    assert_file_missing "$dir/repo/.sops.yaml"
}

test_success_fresh_clone() {
    local dir; dir=$(make_case); write_mocks "$dir"; setup_startup "$dir"
    rm -f "$dir/repo/.sops.yaml"
    if ! run_recover "$dir"; then cat "$dir/out"; fail 'happy path failed'; fi
    grep -q 'mock startup: OK' "$dir/out" || fail 'startup output missing'
    [[ -f "$dir/etc/age-key.txt" ]] || fail 'new operational key missing'
    grep -q "# mock-age=$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/state/secrets/secrets.yaml" || fail 'cipher metadata missing mock recipients'
    grep -q "$NEW_RECIPIENT,$USB_RECIPIENT" "$dir/repo/.sops.yaml" || fail 'policy recipients missing'
    grep -q "SOPS_AGE_KEY_FILE=$dir/etc/age-key.txt" "$dir/state/config/install.env" || fail 'install.env not updated'
    grep -q "OFFLINE_AGE_RECIPIENT=$USB_RECIPIENT" "$dir/state/config/dr-manifest.env" || fail 'manifest recipient not updated'
    grep -q '^MANIFEST_UPDATED_AT=' "$dir/state/config/dr-manifest.env" || fail 'manifest timestamp missing'
}

run_test 'missing --state-dir prints usage and fails' test_missing_state_dir
run_test 'missing --key prints usage and fails' test_missing_key
run_test 'non-mounted state directory prints exact message' test_non_mounted
run_test 'boot storage mode clears block-volume env values' test_boot_mode_clears_block_env
run_test 'block storage mode writes UUID device path and sentinel' test_block_mode_uuid_device
run_test 'final permissions match split contract' test_final_permissions
run_test 'cleanup removes staged private key on failure' test_cleanup_removes_staged_key
run_test 'sops updatekeys failure leaves artifacts unchanged' test_updatekeys_failure
run_test 'active-key promotion failure rolls back artifacts' test_active_key_promotion_failure
run_test 'policy promotion failure rolls back artifacts' test_policy_promotion_failure
run_test 'final live-decryption failure restores absent artifacts' test_final_decrypt_failure_no_prior_artifacts
run_test 'successful fresh-clone recovery updates all artifacts' test_success_fresh_clone

[[ "$TESTS_RUN" -eq 12 ]] || fail "expected 12 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
