from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


def replace_all(path, old, new, minimum=1):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count < minimum:
        raise SystemExit(f"{path}: expected at least {minimum} matches, found {count}: {old!r}")
    p.write_text(text.replace(old, new))


# Current stable pins verified 2026-08-14 against upstream release/tag sources.
replace_once('.env.example', 'VAULTWARDEN_VERSION=1.36.0', 'VAULTWARDEN_VERSION=1.37.1')
replace_once('.env.example', 'BUSYBOX_VERSION=1.36.1', 'BUSYBOX_VERSION=1.38.0')
replace_once('.env.example', 'FIREWALL_BOUNCER_VERSION=0.0.34', 'FIREWALL_BOUNCER_VERSION=0.0.36')
replace_once('docker-compose.yml.example', 'ghcr.io/dani-garcia/vaultwarden:${VAULTWARDEN_VERSION:-1.36.0}', 'ghcr.io/dani-garcia/vaultwarden:${VAULTWARDEN_VERSION:-1.37.1}')

# setup.sh: pinned default remains normal; --use-latest is explicit and forwarded.
replace_once('setup.sh', 'SOPS_DEFAULT_VERSION="v3.13.2"', 'SOPS_DEFAULT_VERSION="v3.13.3"')
replace_once(
    'setup.sh',
    '# Set SOPS_VERSION to use a specific release. When unset or blank, setup uses\n# the repository-pinned production default.\n',
    '# Set SOPS_VERSION to use a specific release. When unset or blank, setup uses\n# the repository-pinned production default. Pass --use-latest only when an\n# operator explicitly wants mutable upstream versions for this run.\n',
)
replace_once('setup.sh', 'AUTO_MODE=false\nSKIP_DEPS=false', 'AUTO_MODE=false\nUSE_LATEST=false\nSKIP_DEPS=false')
replace_once(
    'setup.sh',
    '                      placeholders — the post-install summary lists exact commands\n                      to rotate them.\n  --skip-deps',
    '                      placeholders — the post-install summary lists exact commands\n                      to rotate them. Does NOT imply --use-latest.\n  --use-latest        Explicit override: use current live upstream component versions\n                      for this run instead of the repository-pinned normal defaults.\n                      Caddy remains pinned because xcaddy builds require a version tag.\n  --skip-deps',
)
replace_once('setup.sh', '        --auto)         AUTO_MODE=true;            shift ;;\n        --skip-deps)', '        --auto)         AUTO_MODE=true;            shift ;;\n        --use-latest)   USE_LATEST=true;           shift ;;\n        --skip-deps)')
replace_once(
    'setup.sh',
    'done\n\n\n\n# ---------------------------------------------------------------------------\n# _warn_force_destructive',
    'done\n\nif [[ "$USE_LATEST" == "true" && "$SOPS_VERSION_ENV_SET" == "true" ]]; then\n    log_error "--use-latest cannot be combined with SOPS_VERSION from the environment; choose one SOPS version source."\n    exit 1\nfi\n\n\n# ---------------------------------------------------------------------------\n# _warn_force_destructive',
)
replace_once(
    'setup.sh',
    '    if [[ "$SOPS_VERSION_ENV_SET" == "true" ]]; then\n        log_info "SOPS version requested: ${SOPS_VERSION}"\n    else\n        log_info "SOPS version pinned default: ${SOPS_VERSION}"\n    fi\n\n    local _dry=() _force=() _auto=() _skip_deps=()\n',
    '    if [[ "$USE_LATEST" == "true" ]]; then\n        log_info "SOPS version: will resolve latest from GitHub because --use-latest was requested"\n    elif [[ "$SOPS_VERSION_ENV_SET" == "true" ]]; then\n        log_info "SOPS version requested: ${SOPS_VERSION}"\n    else\n        log_info "SOPS version pinned default: ${SOPS_VERSION}"\n    fi\n\n    local _dry=() _force=() _auto=() _skip_deps=() _use_latest=()\n',
)
replace_once('setup.sh', '    [[ "$SKIP_DEPS" == "true" ]] && _skip_deps=(--skip-deps)\n\n    local _dev_flags=()', '    [[ "$SKIP_DEPS" == "true" ]] && _skip_deps=(--skip-deps)\n    [[ "$USE_LATEST" == "true" ]] && _use_latest=(--use-latest)\n\n    local _dev_flags=()')
replace_once('setup.sh', '        "${_auto[@]}" "${_skip_deps[@]}" "${_dry[@]}" "${_force[@]}" \\\n', '        "${_auto[@]}" "${_skip_deps[@]}" "${_use_latest[@]}" "${_dry[@]}" "${_force[@]}" \\\n')
replace_once('setup.sh', '        "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \\\n', '        "${_use_latest[@]}" "${_dry[@]}" "${_force[@]}" "${_dev_flags[@]}" \\\n')

# setup-system.sh: explicit live SOPS resolution, pinned v3.13.3 normally.
replace_once('utilities/setup-system.sh', 'SOPS_DEFAULT_VERSION="v3.13.2"', 'SOPS_DEFAULT_VERSION="v3.13.3"')
replace_once(
    'utilities/setup-system.sh',
    'SOPS_VERSION="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"\nSKIP_DEPS=false\nAUTO_MODE=false\nDRY_RUN=false',
    '_SOPS_VERSION_ENV_SET=false\nif [[ -n "${SOPS_VERSION+x}" && -n "${SOPS_VERSION:-}" ]]; then\n    _SOPS_VERSION_ENV_SET=true\nfi\nSOPS_VERSION="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"\nSOPS_VERSION_CLI_SET=false\nSKIP_DEPS=false\nAUTO_MODE=false\nUSE_LATEST=false\nDRY_RUN=false',
)
replace_once('utilities/setup-system.sh', 'export FORCE', 'export USE_LATEST FORCE')
replace_once(
    'utilities/setup-system.sh',
    '    --auto                Non-interactive mode\n    --sops-version VER    Use a specific SOPS version (default: v3.13.2)',
    '    --auto                Non-interactive mode\n    --use-latest          Explicit override: resolve the latest SOPS release\n    --sops-version VER    Use a specific SOPS version (default: v3.13.3)',
)
replace_once('utilities/setup-system.sh', '            --auto)         AUTO_MODE=true ;;\n            --dry-run)', '            --auto)         AUTO_MODE=true ;;\n            --use-latest)   USE_LATEST=true ;;\n            --dry-run)')
replace_once('utilities/setup-system.sh', '                SOPS_VERSION="$1"\n                ;;', '                SOPS_VERSION="$1"\n                SOPS_VERSION_CLI_SET=true\n                ;;')
replace_once(
    'utilities/setup-system.sh',
    '        shift\n    done\n\n}\n\n\nvalidate_supported_host_preflight()',
    '        shift\n    done\n\n    if [[ "$USE_LATEST" == "true" && "$SOPS_VERSION_CLI_SET" == "true" ]]; then\n        log_error "--use-latest cannot be combined with --sops-version; choose one SOPS version source."\n        exit 1\n    fi\n    if [[ "$USE_LATEST" == "true" && "$_SOPS_VERSION_ENV_SET" == "true" ]]; then\n        log_error "--use-latest cannot be combined with SOPS_VERSION from the environment; choose one SOPS version source."\n        exit 1\n    fi\n}\n\n# Resolve the latest stable release tag from the GitHub API for an explicit override.\nresolve_github_latest() {\n    local repo="$1"\n    local tag api_tmpfile\n\n    api_tmpfile=$(mktemp -p "$TMP_WORKDIR" gh-latest.XXXXXXXXXX.json)\n    if ! curl -fsSL --max-time 30 \\\n            "https://api.github.com/repos/${repo}/releases/latest" \\\n            -o "$api_tmpfile" 2>/dev/null; then\n        log_error "Could not fetch release info for ${repo} from GitHub API."\n        log_error "Use --sops-version vX.Y.Z or SOPS_VERSION=vX.Y.Z to stay pinned."\n        return 1\n    fi\n\n    tag=$(jq -r ".tag_name // empty" "$api_tmpfile")\n    if [[ -z "$tag" ]] || ! _validate_sops_version_format "$tag"; then\n        log_error "Could not resolve a valid stable release tag for ${repo}."\n        log_error "Use --sops-version vX.Y.Z or SOPS_VERSION=vX.Y.Z to stay pinned."\n        return 1\n    fi\n\n    printf "%s\\n" "$tag"\n}\n\nvalidate_supported_host_preflight()',
)
replace_once(
    'utilities/setup-system.sh',
    'install_sops() {\n    local sops_ver="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"\n    if [[ -n "$sops_ver" ]]; then\n        log_info "Using SOPS version: ${sops_ver}"\n    else',
    'install_sops() {\n    local sops_ver="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"\n    if [[ "$USE_LATEST" == "true" ]]; then\n        log_info "SOPS --use-latest requested — resolving latest stable release from GitHub..."\n        sops_ver=$(resolve_github_latest "getsops/sops") || return 1\n    elif [[ -n "$sops_ver" ]]; then\n        log_info "Using SOPS version: ${sops_ver}"\n    else',
)

# setup-env.sh: normal rendering stays pinned; explicit override writes mutable tags where supported.
replace_once('utilities/setup-env.sh', 'ADMIN_EMAIL=""\nDATA_VOLUME_DEVICE=', 'ADMIN_EMAIL=""\nUSE_LATEST=false\nDATA_VOLUME_DEVICE=')
replace_once(
    'utilities/setup-env.sh',
    '    --email EMAIL         Admin email address (required)\n    --data-device DEV',
    '    --email EMAIL         Admin email address (required)\n    --use-latest          Explicit override: set supported component versions to latest;\n                          Caddy remains pinned because xcaddy builder tags require\n                          an explicit version.\n    --data-device DEV',
)
replace_once('utilities/setup-env.sh', '            --force)        FORCE=true ;;', '            --use-latest)   USE_LATEST=true ;;\n            --force)        FORCE=true ;;')
replace_once(
    'utilities/setup-env.sh',
    '        local domain_matches=false email_matches=false versions_match=false storage_matches=false\n        grep -qF "DOMAIN=$domain_with_protocol" "$env_file" && domain_matches=true\n        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL"      "$env_file" && email_matches=true\n\n        grep -qE \'^(VAULTWARDEN|CADDY|POSTFIX|BUSYBOX|CROWDSEC|CF_WORKER_BOUNCER|FIREWALL_BOUNCER)_VERSION=latest\' "$env_file" \\\n            || versions_match=true\n',
    '        local domain_matches=false email_matches=false versions_match=false storage_matches=false\n        grep -qF "DOMAIN=$domain_with_protocol" "$env_file" && domain_matches=true\n        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL"      "$env_file" && email_matches=true\n\n        if [[ "$USE_LATEST" == "true" ]]; then\n            if grep -qE \'^VAULTWARDEN_VERSION=latest\' "$env_file" && \\\n               grep -qE \'^POSTFIX_VERSION=latest\'     "$env_file" && \\\n               grep -qE \'^BUSYBOX_VERSION=latest\'     "$env_file" && \\\n               ! grep -qE \'^CADDY_VERSION=latest\'     "$env_file" && \\\n               grep -qE \'^CROWDSEC_VERSION=latest\'    "$env_file" && \\\n               grep -qE \'^CF_WORKER_BOUNCER_VERSION=latest\' "$env_file" && \\\n               grep -qE \'^FIREWALL_BOUNCER_VERSION=latest\'  "$env_file"; then\n                versions_match=true\n            fi\n        else\n            grep -qE \'^(VAULTWARDEN|CADDY|POSTFIX|BUSYBOX|CROWDSEC|CF_WORKER_BOUNCER|FIREWALL_BOUNCER)_VERSION=latest\' "$env_file" \\\n                || versions_match=true\n        fi\n',
)
replace_once(
    'utilities/setup-env.sh',
    '    \' "$env_template" > "$temp_env" || { rm -f "$temp_env"; return 1; }\n\n\n    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then',
    '    \' "$env_template" > "$temp_env" || { rm -f "$temp_env"; return 1; }\n\n    if [[ "$USE_LATEST" == "true" ]]; then\n        local temp2\n        temp2=$(_make_owned_temp "$env_dir" "$real_user" "$real_group") \\\n            || { rm -f "$temp_env"; return 1; }\n\n        awk \'{\n            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");\n            sub(/^POSTFIX_VERSION=.*/,     "POSTFIX_VERSION=latest");\n            sub(/^BUSYBOX_VERSION=.*/,     "BUSYBOX_VERSION=latest");\n            sub(/^CROWDSEC_VERSION=.*/,    "CROWDSEC_VERSION=latest");\n            sub(/^CF_WORKER_BOUNCER_VERSION=.*/, "CF_WORKER_BOUNCER_VERSION=latest");\n            sub(/^FIREWALL_BOUNCER_VERSION=.*/,  "FIREWALL_BOUNCER_VERSION=latest");\n            print;\n        }\' "$temp_env" > "$temp2" || { rm -f "$temp_env" "$temp2"; return 1; }\n\n        rm -f "$temp_env"\n        temp_env="$temp2"\n    fi\n\n    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then',
)

# CrowdSec: default path requires source pins; only --use-latest clears them.
replace_once('utilities/setup-crowdsec.sh', 'AUTONOMOUS_MODE=false\nADMIN_IP=', 'AUTONOMOUS_MODE=false\nUSE_LATEST=false\nADMIN_IP=')
replace_once(
    'utilities/setup-crowdsec.sh',
    '    --force              Re-run all phases even if already applied.\n    --autonomous',
    '    --force              Re-run all phases even if already applied.\n    --use-latest         Explicit override: install current repository candidates\n                         instead of the source-controlled component pins.\n    --autonomous',
)
replace_once('utilities/setup-crowdsec.sh', '        --force)       FORCE=true; shift ;;\n        --autonomous)', '        --force)       FORCE=true; shift ;;\n        --use-latest)  USE_LATEST=true; shift ;;\n        --autonomous)')
replace_once(
    'utilities/setup-crowdsec.sh',
    'for _version_var in CROWDSEC_VERSION CF_WORKER_BOUNCER_VERSION FIREWALL_BOUNCER_VERSION; do\n    _version_value="${!_version_var:-}"\n    if [[ -z "$_version_value" || "$_version_value" == "latest" ]]; then\n        log_error "${_version_var} must be pinned to a source-controlled version in .env."\n        exit 1\n    fi\ndone\nunset _version_var _version_value',
    'if [[ "$USE_LATEST" == "true" ]]; then\n    CROWDSEC_VERSION=""\n    CF_WORKER_BOUNCER_VERSION=""\n    FIREWALL_BOUNCER_VERSION=""\n    log_warn "--use-latest requested: CrowdSec component pins are bypassed for this run."\nelse\n    for _version_var in CROWDSEC_VERSION CF_WORKER_BOUNCER_VERSION FIREWALL_BOUNCER_VERSION; do\n        _version_value="${!_version_var:-}"\n        if [[ -z "$_version_value" || "$_version_value" == "latest" ]]; then\n            log_error "${_version_var} must be pinned to a source-controlled version in .env for normal operation."\n            log_error "Pass --use-latest only for an explicit live-version override."\n            exit 1\n        fi\n    done\n    unset _version_var _version_value\nfi',
)
replace_once(
    'utilities/setup-crowdsec.sh',
    '    _cs_pkg="crowdsec=${CROWDSEC_VERSION}"\n    log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"',
    '    _cs_pkg="crowdsec"\n    if [[ "$USE_LATEST" == "true" ]]; then\n        log_warn "CrowdSec --use-latest override: installing current packagecloud candidate"\n    else\n        _cs_pkg="crowdsec=${CROWDSEC_VERSION}"\n        log_info "CrowdSec version pinned: ${CROWDSEC_VERSION}"\n    fi',
)
replace_once(
    'utilities/setup-crowdsec.sh',
    '    _fw_pkg="${_fw_base}-${_fw_suffix}=${FIREWALL_BOUNCER_VERSION}"\n    log_info "Firewall bouncer version pinned: ${FIREWALL_BOUNCER_VERSION}"',
    '    _fw_pkg="${_fw_base}-${_fw_suffix}"\n    if [[ "$USE_LATEST" == "true" ]]; then\n        log_warn "Firewall bouncer --use-latest override: installing current packagecloud candidate"\n    else\n        _fw_pkg="${_fw_base}-${_fw_suffix}=${FIREWALL_BOUNCER_VERSION}"\n        log_info "Firewall bouncer version pinned: ${FIREWALL_BOUNCER_VERSION}"\n    fi',
)
replace_once(
    'utilities/setup-crowdsec.sh',
    '        _worker_pkg="crowdsec-cloudflare-worker-bouncer=${CF_WORKER_BOUNCER_VERSION#v}"\n        log_info "CF Workers bouncer package version pinned: ${CF_WORKER_BOUNCER_VERSION#v}"',
    '        _worker_pkg="crowdsec-cloudflare-worker-bouncer"\n        if [[ "$USE_LATEST" == "true" ]]; then\n            log_warn "CF Workers bouncer --use-latest override: installing current configured-repository candidate"\n        else\n            _worker_pkg="${_worker_pkg}=${CF_WORKER_BOUNCER_VERSION#v}"\n            log_info "CF Workers bouncer package version pinned: ${CF_WORKER_BOUNCER_VERSION#v}"\n        fi',
)

# Tests: preserve pinned defaults and prove the override is explicit/conflict-safe.
replace_once('tests/suites/foundation/case-runner-contracts.bash', 'SOPS_DEFAULT_VERSION="v3.13.2"', 'SOPS_DEFAULT_VERSION="v3.13.3"')
replace_once(
    'tests/suites/foundation/case-runner-contracts.bash',
    'grep -Fq \'SOPS_VERSION="$1"\' utilities/setup-system.sh \\\n    || fail \'setup-system must retain explicit --sops-version overrides\'\ngrep -Fq \'[[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")\' setup.sh \\\n    || fail \'setup.sh must pass explicit SOPS_VERSION overrides to setup-system\'\nawk \'/install_sops\\(\\)/,/^}/\' utilities/setup-system.sh | grep -Fq \'_sops_resolved_version\' \\\n',
    'grep -Fq \'SOPS_VERSION="$1"\' utilities/setup-system.sh \\\n    || fail \'setup-system must retain explicit --sops-version overrides\'\ngrep -Fq \'SOPS_VERSION_CLI_SET=true\' utilities/setup-system.sh \\\n    || fail \'setup-system must track explicit --sops-version ownership\'\ngrep -Fq \'[[ "$SOPS_VERSION_ENV_SET" == "true" ]] && _sops_flags=(--sops-version "$SOPS_VERSION")\' setup.sh \\\n    || fail \'setup.sh must pass explicit SOPS_VERSION overrides to setup-system\'\nawk \'/install_sops\\(\\)/,/^}/\' utilities/setup-system.sh | grep -Fq \'if [[ "$USE_LATEST" == "true" ]]\' \\\n    || fail \'SOPS latest resolution must be owned by explicit --use-latest\'\nawk \'/install_sops\\(\\)/,/^}/\' utilities/setup-system.sh | grep -Fq \'_sops_resolved_version\' \\\n',
)
replace_once(
    'tests/suites/foundation/case-storage-setup.bash',
    'for removed_latest_surface in \\\n    "$PROJECT_ROOT/setup.sh" \\\n    "$setup_system" \\\n    "$PROJECT_ROOT/utilities/setup-env.sh" \\\n    "$setup_crowdsec"; do\n    if grep -Fq -- \'--use-latest\' "$removed_latest_surface"; then\n        fail "removed --use-latest production contract remains in $removed_latest_surface"\n    fi\ndone\n',
    'if ! bash "$setup_system" --use-latest --sops-version v3.13.3 >/tmp/vw-sops-ambiguous.$$ 2>&1; then\n    grep -Fq "cannot be combined" /tmp/vw-sops-ambiguous.$$ \\\n        || fail "ambiguous --use-latest + --sops-version failure message missing"\nelse\n    fail "ambiguous --use-latest + --sops-version unexpectedly succeeded"\nfi\nrm -f /tmp/vw-sops-ambiguous.$$\n',
)

replace_once(
    'docs/PROJECT-BOUNDARY.md',
    'Production setup consumes source-controlled version pins and does not offer a mutable `--use-latest` mode.',
    'Production setup consumes source-controlled version pins by default. An explicit `--use-latest` override remains available for operator-requested live-version runs, but it is outside the normal/golden path.',
)

# Audit cleanup: the removed Compose init-permissions service must not be named as an owner.
replace_once(
    'caddy/Dockerfile',
    '# other services. init-permissions chowns /data/caddy, /config/caddy, and\n# the log files to this UID before Caddy starts.',
    '# other services. Host-side startup/setup prepares the persistent Caddy\n# data, config, and log ownership for this UID before Caddy starts.',
)

print('PR10 latest-version override refresh applied.')
