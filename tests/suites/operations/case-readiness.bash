#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../lib/test-root.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/test-root.bash"

ROOT="$VW_TEST_REPO_ROOT"
UPDATE="$ROOT/utilities/maintenance-update.sh"
SMOKE="$ROOT/utilities/smoke-test.sh"
HEALTH="$ROOT/utilities/maintenance-health.sh"
SETUP_CROWDSEC="$ROOT/utilities/setup-crowdsec.sh"
CROWDSEC_LIB="$ROOT/lib/crowdsec.sh"
WORKER_LIB="$ROOT/lib/crowdsec-worker.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require() {
    grep -Eq -- "$1" "$2" || fail "$3"
}

reject() {
    ! grep -Eq -- "$1" "$2" || fail "$3"
}

extract_function() {
    local name="$1" file="$2"
    awk -v name="$name" '
        $0 ~ "^" name "\\(\\)[[:space:]]*\\{" { capture=1; depth=0 }
        capture {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

check_update_transaction() (
    set -euo pipefail
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    extract_function run_image_update_transaction "$UPDATE" > "$tmpdir/transaction.sh"
    [[ -s "$tmpdir/transaction.sh" ]] || fail "could not extract run_image_update_transaction"

    log_success() { :; }
    log_warn() { :; }
    log_error() { :; }

    RECREATE_CALLS=0
    READY_CALLS=0
    ROLLBACK_CALLS=0
    RECREATE_RESULTS="${RECREATE_RESULTS:-0}"
    READY_RESULTS="${READY_RESULTS:-0}"
    ROLLBACK_RESULT="${ROLLBACK_RESULT:-0}"

    next_result() {
        local list="$1" index="$2"
        local -a values=()
        read -r -a values <<< "$list"
        printf '%s\n' "${values[$index]:-${values[-1]}}"
    }
    recreate_update_stack() {
        local rc
        rc="$(next_result "$RECREATE_RESULTS" "$RECREATE_CALLS")"
        (( RECREATE_CALLS++ )) || true
        return "$rc"
    }
    check_update_readiness() {
        local rc
        rc="$(next_result "$READY_RESULTS" "$READY_CALLS")"
        (( READY_CALLS++ )) || true
        return "$rc"
    }
    rollback_image_digests() {
        (( ROLLBACK_CALLS++ )) || true
        return "$ROLLBACK_RESULT"
    }
    # shellcheck disable=SC1090
    source "$tmpdir/transaction.sh"

    RECREATE_RESULTS="0" READY_RESULTS="0" ROLLBACK_RESULT=0
    RECREATE_CALLS=0 READY_CALLS=0 ROLLBACK_CALLS=0
    run_image_update_transaction || fail "healthy image update should succeed"
    [[ "$RECREATE_CALLS" -eq 1 && "$READY_CALLS" -eq 1 && "$ROLLBACK_CALLS" -eq 0 ]] \
        || fail "healthy image update must not roll back"

    RECREATE_RESULTS="0 0" READY_RESULTS="1 0" ROLLBACK_RESULT=0
    RECREATE_CALLS=0 READY_CALLS=0 ROLLBACK_CALLS=0
    set +e
    run_image_update_transaction
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "unhealthy update with healthy rollback must return 1, got $rc"
    [[ "$RECREATE_CALLS" -eq 2 && "$READY_CALLS" -eq 2 && "$ROLLBACK_CALLS" -eq 1 ]] \
        || fail "healthy rollback must restore, recreate once, and health-check once"

    RECREATE_RESULTS="0 0" READY_RESULTS="1 1" ROLLBACK_RESULT=0
    RECREATE_CALLS=0 READY_CALLS=0 ROLLBACK_CALLS=0
    set +e
    run_image_update_transaction
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "unhealthy rollback must return manual-recovery status 2, got $rc"
    [[ "$RECREATE_CALLS" -eq 2 && "$READY_CALLS" -eq 2 && "$ROLLBACK_CALLS" -eq 1 ]] \
        || fail "unhealthy rollback must not loop or attempt a second rollback"

    RECREATE_RESULTS="0" READY_RESULTS="1" ROLLBACK_RESULT=1
    RECREATE_CALLS=0 READY_CALLS=0 ROLLBACK_CALLS=0
    set +e
    run_image_update_transaction
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "failed image restoration must require manual recovery"
    [[ "$RECREATE_CALLS" -eq 1 ]] || fail "failed image restoration must not recreate a mixed set"
)

check_crowdsec_readiness() (
    set -euo pipefail
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/etc/bouncers" "$tmpdir/bin"
    cat > "$tmpdir/etc/config.yaml" <<'EOF_CONFIG'
api:
  server:
    listen_uri: 127.0.0.1:8097
EOF_CONFIG
    cat > "$tmpdir/etc/bouncers/crowdsec-cloudflare-worker-bouncer.yaml" <<'EOF_BOUNCER'
crowdsec_config:
  lapi_url: "http://127.0.0.1:8097/"
  lapi_key: "test-key"
EOF_BOUNCER

    SYSTEMCTL_UNIT=present
    SYSTEMCTL_ACTIVE=active
    cat > "$tmpdir/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    cat)
        [[ "${SYSTEMCTL_UNIT:-present}" == present ]]
        ;;
    is-active)
        [[ "${SYSTEMCTL_ACTIVE:-active}" == active ]]
        ;;
    *) exit 2 ;;
esac
EOF_SYSTEMCTL
    cat > "$tmpdir/bin/cscli" <<'EOF_CSCLI'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${CSCLI_QUERY_OK:-true}" != true ]]; then exit 1; fi
if [[ "${1:-}" == bouncers && "${2:-}" == list ]]; then
    printf '%s\n' "${CSCLI_BOUNCERS-cloudflare-worker-bouncer 127.0.0.1 valid}"
    exit 0
fi
exit 2
EOF_CSCLI
    chmod +x "$tmpdir/bin/systemctl" "$tmpdir/bin/cscli"
    PATH="$tmpdir/bin:$PATH"
    export PATH SYSTEMCTL_UNIT SYSTEMCTL_ACTIVE
    export VW_CROWDSEC_ETC_DIR="$tmpdir/etc"
    export CLOUDFLARE_PROXY_ENABLED=true CF_AUTONOMOUS_MODE=false
    export CSCLI_QUERY_OK=true CSCLI_BOUNCERS="cloudflare-worker-bouncer 127.0.0.1 valid"
    # shellcheck disable=SC1090
    source "$CROWDSEC_LIB"

    crowdsec_worker_readiness || fail "valid active golden-path bouncer should pass: $CROWDSEC_READINESS_DETAIL"

    SYSTEMCTL_UNIT=missing
    export SYSTEMCTL_UNIT
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 1 ]] || fail "missing golden-path bouncer must be NOT READY"

    SYSTEMCTL_UNIT=present SYSTEMCTL_ACTIVE=inactive
    export SYSTEMCTL_UNIT SYSTEMCTL_ACTIVE
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 1 ]] || fail "inactive golden-path bouncer must be NOT READY"

    SYSTEMCTL_ACTIVE=active
    export SYSTEMCTL_ACTIVE
    printf '%s\n' 'crowdsec_config:' '  lapi_url: "http://127.0.0.1:9999/"' > "$tmpdir/etc/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 1 ]] || fail "bouncer configured for the wrong LAPI port must be NOT READY"

    cat > "$tmpdir/etc/bouncers/crowdsec-cloudflare-worker-bouncer.yaml" <<'EOF_BOUNCER'
crowdsec_config:
  lapi_url: "http://127.0.0.1:8097/"
  lapi_key: "test-key"
EOF_BOUNCER
    CSCLI_BOUNCERS=""
    export CSCLI_BOUNCERS
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 1 ]] || fail "unregistered bouncer must be NOT READY"

    CLOUDFLARE_PROXY_ENABLED=false
    export CLOUDFLARE_PROXY_ENABLED
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 10 ]] || fail "explicit proxy-disabled mode must be a non-golden skip"
    [[ "$CROWDSEC_READINESS_DETAIL" == non-golden* ]] \
        || fail "proxy-disabled skip must be labelled non-golden"

    CLOUDFLARE_PROXY_ENABLED=true CF_AUTONOMOUS_MODE=true
    export CLOUDFLARE_PROXY_ENABLED CF_AUTONOMOUS_MODE
    set +e; crowdsec_worker_readiness; rc=$?; set -e
    [[ "$rc" -eq 10 ]] || fail "autonomous mode must be an explicit non-golden skip"
    [[ "$CROWDSEC_READINESS_DETAIL" == advanced\ non-golden* ]] \
        || fail "autonomous skip must be labelled advanced non-golden"
)

check_tls_contract() {
    reject 'curl[[:space:]].*-k|curl[[:space:]].*--insecure' "$SMOKE" \
        "smoke readiness must not disable TLS verification"
    require 'tls-verified' "$SMOKE" \
        "smoke readiness must include an explicit verified TLS gate"
    require 'certificate trust or hostname verification failed' "$SMOKE" \
        "verified TLS failure must be actionable"
}

check_port_exhaustion_and_installer_contract() {
    require 'port > 65535|port >= 65535' "$SETUP_CROWDSEC" \
        "CrowdSec free-port search must have an explicit exhaustion boundary"
    reject 'safety fallback.*8090|echo[[:space:]]+"8090"[[:space:]]*#.*fallback' "$SETUP_CROWDSEC" \
        "CrowdSec free-port exhaustion must never guess 8090"
    reject 'falling back to GitHub release tarball|go install .*cs-cloudflare-worker-bouncer|apt -> tarball -> go' "$SETUP_CROWDSEC" \
        "Workers bouncer install must not retain apt/archive/source fallback ladders"
    require 'apt-get install -y.*crowdsec-cloudflare-worker-bouncer|_worker_pkg=.*crowdsec-cloudflare-worker-bouncer' "$SETUP_CROWDSEC" \
        "Workers bouncer install must use the canonical package source"
}

check_port_exhaustion_behavior() (
    set -euo pipefail
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    extract_function _cs_find_free_port "$SETUP_CROWDSEC" > "$tmpdir/find-free-port.sh"
    [[ -s "$tmpdir/find-free-port.sh" ]] || fail "could not extract _cs_find_free_port"
    mkdir -p "$tmpdir/bin"
    cat > "$tmpdir/bin/ss" <<'EOF_SS'
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:65535 0.0.0.0:* users:(("occupied",pid=1,fd=1))'
EOF_SS
    chmod +x "$tmpdir/bin/ss"
    PATH="$tmpdir/bin:$PATH"
    export PATH
    log_error() { :; }
    # shellcheck disable=SC1090
    source "$tmpdir/find-free-port.sh"
    set +e
    output="$(_cs_find_free_port 65535)"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "exhausted CrowdSec port search must fail, got $rc"
    [[ -z "$output" ]] || fail "exhausted CrowdSec port search must not guess a port: $output"
)

check_tls_failure_behavior() (
    set -euo pipefail
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    extract_function check_tls_certificate "$SMOKE" > "$tmpdir/tls-check.sh"
    [[ -s "$tmpdir/tls-check.sh" ]] || fail "could not extract check_tls_certificate"
    export QUIET=true
    export DOMAIN="https://wrong-host.example.invalid"
    TLS_RESULT=""
    _require_project_environment() { return 0; }
    _check_fail() { TLS_RESULT="FAIL|$1|$2"; }
    curl() { return 60; }
    # shellcheck disable=SC1090
    source "$tmpdir/tls-check.sh"
    check_tls_certificate
    [[ "$TLS_RESULT" == FAIL\|tls-verified\|certificate\ trust\ or\ hostname\ verification\ failed* ]] \
        || fail "certificate/hostname verification failure must fail smoke readiness: $TLS_RESULT"
)

check_shared_resolver_contract() {
    require 'source .*crowdsec\.sh' "$WORKER_LIB" \
        "Workers helper must source the shared CrowdSec resolver"
    reject 'grep -oP.*listen_uri|echo[[:space:]]+"8090"' "$WORKER_LIB" \
        "Workers helper must not duplicate LAPI parsing or fallback guessing"
    require 'crowdsec_resolve_lapi_port' "$SETUP_CROWDSEC" \
        "CrowdSec setup must reuse the shared LAPI resolver"
}

check_health_contract() {
    require 'crowdsec_worker_readiness' "$HEALTH" \
        "standard health must use the golden-path CrowdSec readiness contract"
    reject 'No CrowdSec bouncer installed \(optional' "$HEALTH" \
        "standard health must not PASS a missing bouncer"
}

check_docs_contract() {
    require 'utilities/setup-crowdsec\.sh' "$ROOT/README.md" \
        "README golden path must explicitly run setup-crowdsec.sh"
    require 'utilities/setup-crowdsec\.sh' "$ROOT/docs/DEPLOYMENT.md" \
        "deployment golden path must explicitly run setup-crowdsec.sh"
}

check_update_transaction
check_crowdsec_readiness
check_tls_contract
check_tls_failure_behavior
check_port_exhaustion_and_installer_contract
check_port_exhaustion_behavior
check_shared_resolver_contract
check_health_contract
check_docs_contract

printf 'PASS readiness regression contracts\n'
