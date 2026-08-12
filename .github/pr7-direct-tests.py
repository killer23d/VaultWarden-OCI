from pathlib import Path

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''if [[ "$MODE" == "core" || "$MODE" == "all" ]]; then
    check_recovery_kit_attachment_passphrase_contract
fi
'''
if anchor not in t:
    raise SystemExit('test insertion anchor not found')
block = r'''

check_pr7_sensitive_workspace_and_sops_promotion() (
set -euo pipefail
ROOT="$VW_TEST_REPO_ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../../../lib/crypto.sh
source "$ROOT/lib/crypto.sh"

# Production sensitive workspaces are root-only. The focused root run verifies
# backing refusal and real root:root mode/cleanup; the ordinary-user full suite
# verifies that the root boundary itself fails closed.
if (( EUID == 0 )); then
    _sensitive_backing_is_volatile() { return 1; }
    if create_sensitive_workspace refusal-test >/dev/null 2>&1; then
        fail 'sensitive workspace succeeded when all backing verification was forced to fail'
    fi

    # The source guard prevents re-sourcing; restore an accepting verifier
    # explicitly for the cleanup-only assertion below.
    _sensitive_backing_is_volatile() { return 0; }
    workspace="$(create_sensitive_workspace test-cleanup)" || fail 'could not create verified volatile workspace on Noble runner'
    [[ "$(stat -c '%u:%g:%a' "$workspace")" == '0:0:700' ]] || fail 'sensitive workspace is not root:root mode 0700'
    printf 'sensitive sentinel\n' >"$workspace/plaintext"
    remove_sensitive_workspace "$workspace" || fail 'sensitive workspace cleanup failed'
    [[ ! -e "$workspace" ]] || fail 'sensitive workspace remained after cleanup'
else
    if create_sensitive_workspace nonroot-test >/dev/null 2>&1; then
        fail 'sensitive workspace unexpectedly allowed non-root allocation'
    fi
fi

key="$TMP/age-key.txt"
printf 'dummy-key\n' >"$key"
dest="$TMP/secrets.yaml"
staged="$TMP/staged.yaml"
printf 'OLD-CIPHERTEXT\n' >"$dest"
printf 'GOOD-CIPHERTEXT\n' >"$staged"

# Mock only the SOPS validity oracle; file operations remain real.
sops() {
    local last="${!#}"
    case " $* " in
        *' --decrypt '*)
            [[ "$(cat "$last")" != *BAD-CIPHERTEXT* ]]
            ;;
        *' --encrypt --in-place '*)
            printf 'GOOD-CIPHERTEXT\n' >"$last"
            ;;
        *) return 1 ;;
    esac
}

# The rollback copy is a hard precondition: a failed copy must not replace live ciphertext.
cp() { return 42; }
if promote_sops_ciphertext "$staged" "$dest" "$key" >/dev/null 2>&1; then
    fail 'SOPS promotion succeeded despite rollback-copy failure'
fi
[[ "$(cat "$dest")" == 'OLD-CIPHERTEXT' ]] || fail 'rollback-copy failure modified live ciphertext'
[[ -f "$staged" ]] || fail 'rollback-copy failure consumed staged ciphertext'
unset -f cp

# A promoted file that fails post-move validation must restore the previous ciphertext.
printf 'BAD-CIPHERTEXT\n' >"$staged"
sops() {
    local last="${!#}"
    case " $* " in
        *' --decrypt '*)
            if [[ "$last" == "$staged" ]]; then return 0; fi
            [[ "$(cat "$last")" != *BAD-CIPHERTEXT* ]]
            ;;
        *) return 1 ;;
    esac
}
if promote_sops_ciphertext "$staged" "$dest" "$key" >/dev/null 2>&1; then
    fail 'SOPS promotion succeeded despite failed post-promotion round-trip'
fi
[[ "$(cat "$dest")" == 'OLD-CIPHERTEXT' ]] || fail 'failed promoted ciphertext was not rolled back'
! compgen -G "$TMP/.secrets.yaml.rollback.*" >/dev/null || fail 'successful rollback left a rollback artifact'

# Successful promotion removes its rollback only after validation.
printf 'GOOD-CIPHERTEXT\n' >"$staged"
sops() { return 0; }
promote_sops_ciphertext "$staged" "$dest" "$key" || fail 'valid staged ciphertext did not promote'
[[ "$(cat "$dest")" == 'GOOD-CIPHERTEXT' ]] || fail 'valid staged ciphertext was not installed'
! compgen -G "$TMP/.secrets.yaml.rollback.*" >/dev/null || fail 'successful promotion left a rollback artifact'

# encrypt_sops_file validates the encrypted temporary result before replacing its plaintext staging input.
plain="$TMP/plain.yaml"
printf 'PLAINTEXT\n' >"$plain"
sops() {
    local last="${!#}"
    case " $* " in
        *' --encrypt --in-place '*) printf 'GOOD-CIPHERTEXT\n' >"$last" ;;
        *' --decrypt '*) [[ "$(cat "$last")" == 'GOOD-CIPHERTEXT' ]] ;;
        *) return 1 ;;
    esac
}
encrypt_sops_file "$plain" "$key" || fail 'encrypt_sops_file rejected valid round-trip'
[[ "$(cat "$plain")" == 'GOOD-CIPHERTEXT' ]] || fail 'encrypt_sops_file did not atomically install validated ciphertext'

# Edit and rotate may allocate same-directory staging files for atomic promotion,
# but those files must receive only ciphertext: encrypt the volatile file first.
edit_encrypt_line="$(grep -nF 'encrypt_sops_file "$temp_file"' "$ROOT/utilities/secrets-edit.sh" | cut -d: -f1)"
edit_copy_line="$(grep -nF 'cp -- "$temp_file" "$encrypted_temp"' "$ROOT/utilities/secrets-edit.sh" | cut -d: -f1)"
[[ -n "$edit_encrypt_line" && -n "$edit_copy_line" && "$edit_encrypt_line" -lt "$edit_copy_line" ]] \
    || fail 'secret edit writes plaintext to disk staging before encryption'
rotate_encrypt_line="$(grep -nF 'encrypt_sops_file "$temp_patched"' "$ROOT/utilities/secrets-rotate.sh" | cut -d: -f1)"
rotate_copy_line="$(grep -nF 'cp -- "$temp_patched" "$temp_enc"' "$ROOT/utilities/secrets-rotate.sh" | cut -d: -f1)"
[[ -n "$rotate_encrypt_line" && -n "$rotate_copy_line" && "$rotate_encrypt_line" -lt "$rotate_copy_line" ]] \
    || fail 'secret rotate writes plaintext to disk staging before encryption'

printf 'PR7 sensitive workspace and SOPS promotion regressions passed.\n'
)

if [[ "$MODE" == "sensitive-cleanup" || "$MODE" == "all" ]]; then
    check_pr7_sensitive_workspace_and_sops_promotion
fi
'''
t = t.replace(anchor, anchor + block, 1)
p.write_text(t)
