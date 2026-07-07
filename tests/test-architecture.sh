#!/usr/bin/env bash
# Consolidated architecture regression suite.
set -euo pipefail

check_architecture_helpers() (
# Focused checks for architecture selection at artifact boundaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_output() {
    local expected="$1"
    shift
    local actual
    actual="$("$@")" || fail "command failed: $*"
    [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual' from: $*"
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure from: $*"
    fi
}

setup_system="${PROJECT_ROOT}/utilities/setup-system.sh"
setup_crowdsec="${PROJECT_ROOT}/utilities/setup-crowdsec.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_output "http://archive.ubuntu.com/ubuntu" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url amd64
assert_output "http://ports.ubuntu.com/ubuntu-ports" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" ubuntu-archive-url unknown

assert_output "amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch amd64
assert_output "arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch riscv64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-release-arch unknown

assert_output "yq_linux_amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset amd64
assert_output "yq_linux_arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset arm64
assert_output "fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-sha256 amd64
assert_output "578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-sha256 arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" yq-release-asset unknown

assert_output "v3.13.2" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" sops-default-version

write_os_release() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

noble="$tmpdir/noble"
write_os_release "$noble" \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    'VERSION_CODENAME=noble' \
    'UBUNTU_CODENAME=noble'
assert_output "noble amd64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" amd64
assert_output "noble arm64" \
    env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" arm64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" armhf
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" s390x
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$noble" unknown

jammy="$tmpdir/jammy"
write_os_release "$jammy" 'ID=ubuntu' 'VERSION_ID="22.04"' 'VERSION_CODENAME=jammy' 'UBUNTU_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$jammy" amd64
unsupported_ubuntu="$tmpdir/oracular"
write_os_release "$unsupported_ubuntu" 'ID=ubuntu' 'VERSION_ID="24.10"' 'VERSION_CODENAME=oracular'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$unsupported_ubuntu" amd64
non_ubuntu="$tmpdir/debian"
write_os_release "$non_ubuntu" 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$non_ubuntu" amd64
missing_id="$tmpdir/missing-id"
write_os_release "$missing_id" 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_id" amd64
missing_version="$tmpdir/missing-version"
write_os_release "$missing_version" 'ID=ubuntu' 'VERSION_CODENAME=noble'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_version" amd64
missing_codename="$tmpdir/missing-codename"
write_os_release "$missing_codename" 'ID=ubuntu' 'VERSION_ID="24.04"'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$missing_codename" amd64
mismatch="$tmpdir/mismatch"
write_os_release "$mismatch" 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$mismatch" amd64
codename_disagree="$tmpdir/codename-disagree"
write_os_release "$codename_disagree" 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble' 'UBUNTU_CODENAME=jammy'
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" supported-host "$codename_disagree" amd64

preflight_line="$(awk '/^[[:space:]]*validate_supported_host_preflight \|\| exit 1/{print NR; exit}' "$setup_system")"
swap_line="$(awk '/^[[:space:]]*create_swapfile$/{print NR; exit}' "$setup_system")"
deps_line="$(awk '/^[[:space:]]*install_dependencies$/{print NR; exit}' "$setup_system")"
[[ -n "$preflight_line" && -n "$swap_line" && -n "$deps_line" ]] \
    || fail "setup-system main flow markers missing"
(( preflight_line < swap_line )) \
    || fail "supported-host preflight must run before create_swapfile"
(( preflight_line < deps_line )) \
    || fail "supported-host preflight must run before install_dependencies"

if ! bash "$setup_system" --use-latest --sops-version v3.13.2 >/tmp/vw-sops-ambiguous.$$ 2>&1; then
    grep -Fq "cannot be combined" /tmp/vw-sops-ambiguous.$$ \
        || fail "ambiguous --use-latest + --sops-version failure message missing"
else
    fail "ambiguous --use-latest + --sops-version unexpectedly succeeded"
fi
rm -f /tmp/vw-sops-ambiguous.$$

make_yq_stub() {
    local path="$1" mode="$2"
    cat > "$path" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
mode="$mode"
if [[ "\${1:-}" == "--version" ]]; then
    case "\$mode" in
        mikefarah4) printf 'yq (https://github.com/mikefarah/yq/) version v4.53.3\n' ;;
        mikefarah3) printf 'yq (https://github.com/mikefarah/yq/) version v3.4.1\n' ;;
        python) printf 'yq 3.1.0\n' ;;
    esac
    exit 0
fi
if [[ "\$mode" != "mikefarah4" ]]; then
    exit 1
fi
expr="\${2:-}"
case "\$expr" in
    .answer) printf 'plain-value\n' ;;
    '.secrets[] | select(.required == true) | .key') printf 'cloudflare_zone_id\n' ;;
    *) exit 1 ;;
esac
EOF_STUB
    chmod +x "$path"
}
make_yq_stub "$tmpdir/yq-good" mikefarah4
make_yq_stub "$tmpdir/yq-python" python
make_yq_stub "$tmpdir/yq-v3" mikefarah3
env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-good" \
    || fail "Mike Farah yq v4 contract was rejected"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-python"
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_system" validate-yq "$tmpdir/yq-v3"

assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" amd64
assert_output "amd64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" x86_64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" arm64
assert_output "arm64" env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" aarch64
assert_fails env VAULTWARDEN_TEST_ARCH_HELPERS=1 "$setup_crowdsec" riscv64

printf 'Architecture helper tests passed.\n'

)

check_architecture_helpers
check_repository_interface_cleanup_contracts() (
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The direct shell runner remains the canonical repository regression entry point.
grep -Fq 'Usage: ./tests/run-tests.sh all' tests/run-tests.sh \
    || fail 'run-tests usage must advertise ./tests/run-tests.sh all'
grep -Fq 'tests/test-architecture.sh' tests/run-tests.sh \
    || fail 'consolidated tests must be inventoried directly in run-tests.sh'

extract_make_target() {
    local target="$1"
    awk -v target="$target" '
        BEGIN { in_target=0; found=0 }
        $0 ~ "^" target ":" { in_target=1; found=1; print; next }
        in_target && $0 ~ /^[A-Za-z0-9_.-]+:([^=]|$)/ { exit }
        in_target { print }
        END { if (!found) exit 2 }
    ' Makefile
}

for target in test test-unit fmt lint shellcheck; do
    if extract_make_target "$target" >/dev/null 2>&1; then
        fail "Makefile must not define removed developer target: $target"
    fi
    if grep -RInE "make[[:space:]]+${target}([^[:alnum:]_-]|$)" README.md RUNBOOK.md docs --exclude='COMMAND-REFERENCE.md' >/tmp/vw-removed-make-target.$$ 2>/dev/null; then
        cat /tmp/vw-removed-make-target.$$ >&2
        rm -f /tmp/vw-removed-make-target.$$
        fail "removed Make target is still referenced: make ${target}"
    fi
    rm -f /tmp/vw-removed-make-target.$$
done

if find .github/workflows -type f ! -name 'append-*' -print0 \
  | xargs -0 grep -nE 'make[[:space:]]+(test|test-unit|fmt|lint|shellcheck)([^[:alnum:]_-]|$)' >/tmp/vw-ci-make-target.$$ 2>/dev/null; then
    cat /tmp/vw-ci-make-target.$$ >&2
    rm -f /tmp/vw-ci-make-target.$$
    fail 'CI must call direct validation tools, not removed Make wrappers'
fi
rm -f /tmp/vw-ci-make-target.$$

if find tests -maxdepth 1 -type f -name 'test-*.sh' | grep -E 'followup|post-pr|pr[0-9]|[0-9]{3}' >/tmp/vw-historical-tests.$$; then
    cat /tmp/vw-historical-tests.$$ >&2
    rm -f /tmp/vw-historical-tests.$$
    fail 'permanent top-level test filenames must not retain historical PR/follow-up names'
fi
rm -f /tmp/vw-historical-tests.$$

while IFS= read -r test_file; do
    rel="${test_file#./}"
    grep -Fq "    ${rel}" tests/run-tests.sh || fail "permanent test file is not inventoried: $rel"
done <<EOF_TESTS
$(find tests -maxdepth 1 -type f -name 'test-*.sh' -print | sort)
EOF_TESTS

grep -Fq 'SOPS_DEFAULT_VERSION="v3.13.2"' utilities/setup-system.sh \
    || fail 'setup-system must pin the normal SOPS default'
grep -Fq 'SOPS_VERSION="$1"' utilities/setup-system.sh \
    || fail 'setup-system must retain explicit --sops-version overrides'
grep -Fq 'SOPS_VERSION_CLI_SET=true' utilities/setup-system.sh \
    || fail 'setup-system must track explicit --sops-version ownership'
grep -Fq '[[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")' setup.sh \
    || fail 'setup.sh must pass explicit SOPS_VERSION overrides to setup-system'
awk '/install_sops\(\)/,/^}/' utilities/setup-system.sh | grep -Fq 'if [[ "$USE_LATEST" == "true" ]]' \
    || fail 'SOPS latest resolution must be owned by explicit --use-latest'
! grep -Fq 'SOPS_VERSION not pinned' utilities/setup-system.sh \
    || fail 'normal setup must not resolve latest merely because SOPS_VERSION is blank'

grep -Fq '"python3-yaml"' utilities/setup-system.sh \
    || fail 'setup-system must explicitly own python3-yaml'
! grep -Eq 'local basic_packages=.*"yq"' utilities/setup-system.sh \
    || fail 'setup-system basic apt packages must not install Ubuntu python-yq'
grep -Fq 'python3 -c "import yaml"' utilities/setup-system.sh \
    || fail 'verify_dependencies must verify PyYAML import'

yq_version="$(sed -n 's/^YQ_VERSION="\([^"]*\)"/\1/p' utilities/setup-system.sh)"
yq_sha_amd64="$(sed -n 's/^YQ_SHA256_AMD64="\([^"]*\)"/\1/p' utilities/setup-system.sh)"
[[ -n "$yq_version" && -n "$yq_sha_amd64" ]] || fail 'setup-system yq constants missing'
grep -Fq "YQ_VERSION=\"${yq_version}\"" .github/workflows/doc-drift.yml \
    || fail 'CI yq version must match production setup'
grep -Fq "$yq_sha_amd64" .github/workflows/doc-drift.yml \
    || fail 'CI yq checksum must match production amd64 setup pin'
grep -Fq 'v3.13.2/sops-v3.13.2.linux.amd64' .github/workflows/doc-drift.yml \
    || fail 'CI SOPS binary must match the production SOPS default version'

if grep -En '^[[:space:]]*--with[[:space:]]+github.com/[^[:space:]@]+([[:space:]\\]|$)' caddy/Dockerfile >/tmp/vw-xcaddy-unpinned.$$; then
    cat /tmp/vw-xcaddy-unpinned.$$ >&2
    rm -f /tmp/vw-xcaddy-unpinned.$$
    fail 'every direct xcaddy module must include an immutable tag or commit'
fi
rm -f /tmp/vw-xcaddy-unpinned.$$
if grep -En '^[[:space:]]*--with[[:space:]]+github.com/.*@(latest|main|master|HEAD)([[:space:]\\]|$)' caddy/Dockerfile >/tmp/vw-xcaddy-mutable.$$; then
    cat /tmp/vw-xcaddy-mutable.$$ >&2
    rm -f /tmp/vw-xcaddy-mutable.$$
    fail 'direct xcaddy modules must not use mutable refs'
fi
rm -f /tmp/vw-xcaddy-mutable.$$
for module in \
    'github.com/caddy-dns/cloudflare@v0.2.4' \
    'github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5' \
    'github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1' \
    'github.com/mholt/caddy-ratelimit@v0.1.0'; do
    grep -Fq -- "--with ${module}" caddy/Dockerfile \
        || fail "pinned Caddy module missing: ${module}"
done
grep -Fq "dns cloudflare" caddy/Caddyfile \
    || fail 'Caddyfile must retain Cloudflare DNS provider usage'
grep -Fq "rate_limit" caddy/Caddyfile \
    || fail 'Caddyfile must retain Caddy rate_limit usage'
grep -Fq "'caddy/**'" .github/workflows/doc-drift.yml \
    || fail 'Caddy changes must trigger the permanent workflow'
grep -Fq "'AGENTS.md'" .github/workflows/doc-drift.yml \
    || fail 'AGENTS changes must trigger the permanent workflow'

grep -Fq 'Ubuntu 24.04 Noble amd64' AGENTS.md \
    || fail 'AGENTS must document the Noble amd64 production contract'
grep -Fq 'Ubuntu 24.04 Noble arm64' AGENTS.md \
    || fail 'AGENTS must document the Noble arm64 production contract'
! grep -Fq 'Ubuntu 22.04 LTS Jammy or Ubuntu 24.04 LTS Noble' AGENTS.md \
    || fail 'AGENTS must not retain the obsolete Jammy/Noble production matrix'
grep -Fq 'Ubuntu 24.04 LTS Noble' README.md \
    || fail 'README must state the Noble production contract'
grep -Fq 'Ubuntu 24.04 LTS Noble host on amd64 or arm64' docs/PROJECT-BOUNDARY.md \
    || fail 'PROJECT-BOUNDARY must state Noble amd64/arm64'
grep -Fq 'Ubuntu 24.04 LTS Noble host on amd64 or arm64' docs/DISASTER-RECOVERY.md \
    || fail 'DISASTER-RECOVERY must state Noble amd64/arm64'
grep -Fq 'Use Ubuntu 24.04 LTS Noble on amd64 or arm64.' docs/RECOVERY-CARD.md \
    || fail 'RECOVERY-CARD must state Noble amd64/arm64'
grep -Fq 'provider firewall, security group, or network firewall' RUNBOOK.md \
    || fail 'RUNBOOK must use provider-neutral firewall wording'
! grep -Fq 'Configure OCI Security List' RUNBOOK.md \
    || fail 'RUNBOOK must not present OCI Security List as universal setup'

printf 'PASS: repository interface cleanup contracts\n'
)

check_repository_interface_cleanup_contracts
