#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TESTS_RUN=0
OP="age1op00000000000000000000000000000000000000000000000000000000"
OFF="age1off0000000000000000000000000000000000000000000000000000000"
OFF2="age1of20000000000000000000000000000000000000000000000000000000"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

write_stubs() {
    local bin="$TMP/bin"
    mkdir -p "$bin"
    cat > "$bin/sops" <<'SOPS'
#!/usr/bin/env bash
set -euo pipefail
config=""; mode=""; output=""; target=""; prev=""
for arg in "$@"; do
    case "$arg" in
        --config) prev=config ;;
        --output) prev=output ;;
        --encrypt) mode=encrypt ;;
        updatekeys) mode=updatekeys ;;
        -d|--decrypt) mode=decrypt ;;
        --yes) ;;
        *)
            case "$prev" in
                config) config="$arg"; prev="" ;;
                output) output="$arg"; prev="" ;;
                *) target="$arg" ;;
            esac
            ;;
    esac
done
recipients_from_policy() {
    sed -n 's/^[[:space:]]*age:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1" | tail -1
}
write_meta() {
    local file="$1" csv="$2" r
    {
        printf 'payload: encrypted\n'
        printf 'sops:\n  age:\n'
        IFS=',' read -ra recs <<< "$csv"
        for r in "${recs[@]}"; do
            printf '    - recipient: %s\n' "$r"
        done
    } > "$file"
}
case "$mode" in
    encrypt)
        [[ -n "$config" && -n "$output" && -n "$target" ]] || exit 2
        write_meta "$output" "$(recipients_from_policy "$config")"
        ;;
    updatekeys)
        [[ -n "$config" && -n "$target" ]] || exit 2
        if [[ -n "${MOCK_FAIL_UPDATEKEYS_UNDER:-}" && "$target" == "$MOCK_FAIL_UPDATEKEYS_UNDER"/* ]]; then
            exit 42
        fi
        write_meta "$target" "$(recipients_from_policy "$config")"
        ;;
    decrypt)
        [[ -n "$target" ]] || exit 2
        cat "$target" >/dev/null
        ;;
    *) exit 2 ;;
esac
SOPS
    chmod +x "$bin/sops"
}

source_helpers() {
    export PATH="$TMP/bin:$PATH"
    export SETUP_SECRETS_TRANSACTION_TESTING=source-only
    export PROJECT_STATE_DIR="$TMP/state"
    export VW_SETUP_SECRETS_TMP_DIR="$TMP/run-tmp"
    mkdir -p "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets"
    # shellcheck source=../utilities/setup-secrets.sh
    source "$ROOT/utilities/setup-secrets.sh"
}

case_dir() {
    local d="$TMP/case-$TESTS_RUN"
    mkdir -p "$d/state/config" "$d/state/secrets" "$d/policy"
    printf 'STATE_LAYOUT_VERSION=1\n' > "$d/state/config/dr-manifest.env"
    printf '%s' "$d"
}

assert_recipients() {
    local file="$1" shift_csv="$2" r
    IFS=',' read -ra recs <<< "$shift_csv"
    for r in "${recs[@]}"; do
        grep -q "recipient: $r" "$file" || fail "missing recipient $r in $file"
    done
}

assert_policy_recipients() {
    local file="$1" csv="$2"
    grep -q "age: \"$csv\"" "$file" || fail "policy recipients mismatch in $file"
}

assert_no_plaintext_outside_tmp() {
    local d="$1"
    ! find "$d" -path "$VW_SETUP_SECRETS_TMP_DIR" -prune -o -name 'vwsecrets*.yaml' -print | grep -q . || fail 'plaintext staging leaked outside protected tmp dir'
    ! find "$VW_SETUP_SECRETS_TMP_DIR" -type f -print 2>/dev/null | grep -q . || fail 'plaintext staging file left behind'
}

assert_no_transaction_leftovers() {
    local d="$1"
    ! find "$d" \( -name '.sops.yaml.*' -o -name 'dr-manifest.env.*' -o -name 'tmp.*.yaml' -o -name 'secrets.yaml.bak' -o -name 'sops.yaml.bak' -o -name 'dr-manifest.env.bak' \) -print | grep -q . || fail 'transaction staging or backup file left behind'
}

run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@"
    pass "$name"
}

test_fresh_bootstrap() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local plain final policy
    plain="$(_ss_make_plaintext_temp)"
    chmod 0600 "$plain"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext
    rm -f "$plain"
    [[ -f "$final" ]] || fail 'ciphertext not installed'
    assert_recipients "$final" "$OP,$OFF"
    assert_policy_recipients "$policy" "$OP,$OFF"
    grep -q "OFFLINE_AGE_RECIPIENT=$OFF" "$d/state/config/dr-manifest.env" || fail 'manifest not updated'
    assert_no_plaintext_outside_tmp "$d"
}

test_add_offline_recipient_existing_ciphertext() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    unset OFFLINE_AGE_RECIPIENT || true
    local final policy
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    printf 'OFFLINE_AGE_RECIPIENT=%s\n' "$OFF2" >> "$d/state/config/dr-manifest.env"
    cat > "$policy" <<POLICY
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "$OP"
POLICY
    cat > "$final" <<CIPHER
payload: encrypted
sops:
  age:
    - recipient: $OP
CIPHER
    _ss_commit_ciphertext_transaction "" "$d/key.txt" "$OP" "$final" "$policy" rekey
    assert_recipients "$final" "$OP,$OFF2"
    assert_policy_recipients "$policy" "$OP,$OFF2"
    grep -q "OFFLINE_AGE_RECIPIENT=$OFF2" "$d/state/config/dr-manifest.env" || fail 'manifest did not preserve offline recipient'
}

test_staged_update_failure() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    cp "$d/state/config/dr-manifest.env" "$d/manifest.before"
    if MOCK_FAIL_UPDATEKEYS_UNDER="$d/state/secrets" _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        fail 'transaction unexpectedly succeeded'
    fi
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on update failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on update failure'
    cmp -s "$d/manifest.before" "$d/state/config/dr-manifest.env" || fail 'manifest changed on update failure'
    rm -f "$plain"
    assert_no_plaintext_outside_tmp "$d"
    ! find "$d/state/secrets" -name '*.yaml' ! -name 'secrets.yaml' -print | grep -q . || fail 'ciphertext staging file left behind'
    assert_no_transaction_leftovers "$d"
}

test_manifest_promotion_failure_preserves_artifacts() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    printf 'OFFLINE_AGE_RECIPIENT=%s\nMANIFEST_UPDATED_AT=original\n' "$OFF2" > "$d/state/config/dr-manifest.env"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    cp "$d/state/config/dr-manifest.env" "$d/manifest.before"
    mv() {
        if [[ "${MOCK_FAIL_MANIFEST_PROMOTE:-}" == "1" && "${*: -1}" == "$d/state/config/dr-manifest.env" ]]; then
            return 55
        fi
        command mv "$@"
    }
    if MOCK_FAIL_MANIFEST_PROMOTE=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        unset -f mv
        fail 'manifest promotion failure unexpectedly succeeded'
    fi
    unset -f mv
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on manifest promotion failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on manifest promotion failure'
    cmp -s "$d/manifest.before" "$d/state/config/dr-manifest.env" || fail 'manifest changed on manifest promotion failure'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_manifest_promotion_failure_preserves_absent_manifest() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    printf 'live-policy\n' > "$policy"
    rm -f "$d/state/config/dr-manifest.env"
    cp "$final" "$d/final.before"
    cp "$policy" "$d/policy.before"
    mv() {
        if [[ "${MOCK_FAIL_MANIFEST_PROMOTE:-}" == "1" && "${*: -1}" == "$d/state/config/dr-manifest.env" ]]; then
            return 55
        fi
        command mv "$@"
    }
    if MOCK_FAIL_MANIFEST_PROMOTE=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext; then
        unset -f mv
        fail 'absent manifest promotion failure unexpectedly succeeded'
    fi
    unset -f mv
    cmp -s "$d/final.before" "$final" || fail 'live ciphertext changed on absent manifest promotion failure'
    cmp -s "$d/policy.before" "$policy" || fail 'live policy changed on absent manifest promotion failure'
    [[ ! -e "$d/state/config/dr-manifest.env" ]] || fail 'absent manifest was created on failed transaction'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_term_after_ciphertext_promotion_rolls_back_and_preserves_traps() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local final policy plain before_return before_int before_term after_return after_int after_term status
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    printf 'live-cipher\n' > "$final"
    cp "$final" "$d/final.before"
    rm -f "$policy" "$d/state/config/dr-manifest.env"
    trap 'printf outer-return-trap >/dev/null' RETURN
    trap 'printf outer-int-trap >/dev/null' INT
    trap 'printf outer-term-trap >/dev/null' TERM
    before_return="$(trap -p RETURN)"
    before_int="$(trap -p INT)"
    before_term="$(trap -p TERM)"
    set +e
    SETUP_SECRETS_TEST_TERM_AFTER_CIPHERTEXT_PROMOTION=1 _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext
    status=$?
    set -e
    after_return="$(trap -p RETURN)"
    after_int="$(trap -p INT)"
    after_term="$(trap -p TERM)"
    trap - RETURN INT TERM
    [[ "$status" -eq 143 ]] || fail "TERM transaction returned $status instead of 143"
    [[ "$after_return" == "$before_return" ]] || fail 'outer RETURN trap was not preserved after TERM'
    [[ "$after_int" == "$before_int" ]] || fail 'outer INT trap was not preserved after TERM'
    [[ "$after_term" == "$before_term" ]] || fail 'outer TERM trap was not preserved after TERM'
    cmp -s "$d/final.before" "$final" || fail 'ciphertext not restored after TERM'
    [[ ! -e "$policy" ]] || fail 'absent policy created after TERM rollback'
    [[ ! -e "$d/state/config/dr-manifest.env" ]] || fail 'absent manifest created after TERM rollback'
    rm -f "$plain"
    assert_no_transaction_leftovers "$d"
}

test_preserves_outer_return_trap() {
    local d; d=$(case_dir)
    PROJECT_STATE_DIR="$d/state"
    export OFFLINE_AGE_RECIPIENT="$OFF"
    local plain final policy before after
    plain="$(_ss_make_plaintext_temp)"
    printf 'admin_token: PLACEHOLDER\n' > "$plain"
    final="$d/state/secrets/secrets.yaml"
    policy="$d/policy/.sops.yaml"
    trap 'printf outer-return-trap >/dev/null' RETURN
    before="$(trap -p RETURN)"
    _ss_commit_ciphertext_transaction "$plain" "$d/key.txt" "$OP" "$final" "$policy" plaintext "$OP,$OFF"
    after="$(trap -p RETURN)"
    trap - RETURN
    rm -f "$plain"
    [[ "$after" == "$before" ]] || fail 'outer RETURN trap was not preserved after transaction success'
    [[ -f "$final" ]] || fail 'ciphertext not installed with outer trap present'
}

write_stubs
source_helpers
run_test 'fresh bootstrap stages plaintext in tmpfs and installs recipients' test_fresh_bootstrap
run_test 'adding offline recipient rekeys existing ciphertext metadata' test_add_offline_recipient_existing_ciphertext
run_test 'staged update failure preserves live artifacts and cleans staging' test_staged_update_failure
run_test 'manifest promotion failure preserves existing live artifacts' test_manifest_promotion_failure_preserves_artifacts
run_test 'manifest promotion failure preserves absent manifest' test_manifest_promotion_failure_preserves_absent_manifest
run_test 'TERM after ciphertext promotion rolls back artifacts and preserves traps' test_term_after_ciphertext_promotion_rolls_back_and_preserves_traps
run_test 'successful transaction preserves existing caller return trap' test_preserves_outer_return_trap
[[ "$TESTS_RUN" -eq 7 ]] || fail "expected 7 tests, ran $TESTS_RUN"
printf '1..%s\n' "$TESTS_RUN"
