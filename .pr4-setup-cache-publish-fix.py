from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"{label} anchor missing")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'utilities/setup-firewall.sh',
    '''_phase_ufw() {\n''',
    '''_ufw_publish_cidr_cache() {\n    local cache_file="$1"\n    shift\n    local cache_dir cache_tmp=""\n    cache_dir="$(dirname "$cache_file")"\n\n    if ! mkdir -p "$cache_dir"; then\n        log_error "Could not create Cloudflare CIDR cache directory: ${cache_dir}"\n        return 1\n    fi\n    cache_tmp="$(mktemp -p "$cache_dir" .cf-cidrs.cache.XXXXXX)" || {\n        log_error "Could not allocate a temporary Cloudflare CIDR cache in ${cache_dir}."\n        return 1\n    }\n    if ! printf '%s\\n' "$@" > "$cache_tmp"; then\n        log_error "Could not write temporary Cloudflare CIDR cache: ${cache_tmp}"\n        rm -f -- "$cache_tmp"\n        return 1\n    fi\n    if ! chmod 0640 "$cache_tmp"; then\n        log_error "Could not set Cloudflare CIDR cache permissions on ${cache_tmp}."\n        rm -f -- "$cache_tmp"\n        return 1\n    fi\n    if ! mv -f -- "$cache_tmp" "$cache_file"; then\n        log_error "Could not publish Cloudflare CIDR cache atomically: ${cache_file}"\n        rm -f -- "$cache_tmp"\n        return 1\n    fi\n    return 0\n}\n\n_phase_ufw() {\n''',
    'cache publisher insertion',
)
replace_once(
    'utilities/setup-firewall.sh',
    '''    mkdir -p "$(dirname "$cf_cidr_cache")"\n    printf '%s\\n' "${validated_cidrs[@]}" > "$cf_cidr_cache"\n    chmod 640 "$cf_cidr_cache"\n\n    log_success "UFW reconciled: 80/443 are restricted to ${#validated_cidrs[@]} Cloudflare CIDRs"\n''',
    '''    _ufw_publish_cidr_cache "$cf_cidr_cache" "${validated_cidrs[@]}" || return $?\n\n    log_success "UFW reconciled: 80/443 are restricted to ${#validated_cidrs[@]} Cloudflare CIDRs"\n''',
    'cache publication call',
)

p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
anchor = '''# Initial setup UFW acceptance checks use the same stateful UFW mock.\nSETUP_UFW_PROBE="$TMP/setup-ufw-probe.bash"\n'''
block = '''# Initial setup cache publication must fail explicitly and preserve the old\n# cache generation when a pre-rename step fails. This protects --phase all\n# from feeding stale CIDRs into the Docker gate after UFW changed.\nCACHE_PUBLISH_PROBE="$TMP/setup-cache-publish-probe.bash"\ncat > "$CACHE_PUBLISH_PROBE" <<'EOF_CACHE_PUBLISH'\n#!/usr/bin/env bash\nset -euo pipefail\nlog_error(){ printf 'ERROR: %s\\n' "$*" >> "${CACHE_PUBLISH_LOG:?}"; }\nEOF_CACHE_PUBLISH\nextract_func "$SETUP_FIREWALL" _ufw_publish_cidr_cache >> "$CACHE_PUBLISH_PROBE"\ncat >> "$CACHE_PUBLISH_PROBE" <<'EOF_CACHE_PUBLISH'\ncase "${CACHE_PUBLISH_CASE:?}" in\n    success)\n        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 203.0.113.0/24 2001:db8::/32\n        ;;\n    chmod-fail)\n        chmod(){ return 73; }\n        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 198.51.100.0/24\n        ;;\n    bad-parent)\n        _ufw_publish_cidr_cache "${CACHE_PUBLISH_FILE:?}" 198.51.100.0/24\n        ;;\n    *) exit 2 ;;\nesac\nEOF_CACHE_PUBLISH\nchmod 0755 "$CACHE_PUBLISH_PROBE"\nCACHE_PUBLISH_LOG="$TMP/cache-publish.log"\nCACHE_PUBLISH_DIR="$TMP/cache-publish"\nmkdir -p "$CACHE_PUBLISH_DIR"\nCACHE_PUBLISH_FILE="$CACHE_PUBLISH_DIR/cf-cidrs.cache"\nexport CACHE_PUBLISH_LOG CACHE_PUBLISH_FILE\n: > "$CACHE_PUBLISH_LOG"\nCACHE_PUBLISH_CASE=success "$BASH" "$CACHE_PUBLISH_PROBE"\n[[ "$(cat "$CACHE_PUBLISH_FILE")" == $'203.0.113.0/24\\n2001:db8::/32' ]] || fail "atomic setup cache publisher wrote the wrong CIDR generation"\n[[ "$(stat -c '%a' "$CACHE_PUBLISH_FILE")" == 640 ]] || fail "atomic setup cache publisher used the wrong mode"\n\nprintf 'old-generation\\n' > "$CACHE_PUBLISH_FILE"\nset +e\nCACHE_PUBLISH_CASE=chmod-fail "$BASH" "$CACHE_PUBLISH_PROBE"\nCACHE_PUBLISH_RC=$?\nset -e\n[[ "$CACHE_PUBLISH_RC" -ne 0 ]] || fail "setup cache publisher hid chmod failure"\n[[ "$(cat "$CACHE_PUBLISH_FILE")" == 'old-generation' ]] || fail "failed setup cache publish replaced the prior generation"\nassert_file_contains "$CACHE_PUBLISH_LOG" 'Could not set Cloudflare CIDR cache permissions'\n\nBAD_PARENT="$TMP/cache-parent-file"\nprintf 'not-a-directory\\n' > "$BAD_PARENT"\nCACHE_PUBLISH_FILE="$BAD_PARENT/cf-cidrs.cache"\nexport CACHE_PUBLISH_FILE\nset +e\nCACHE_PUBLISH_CASE=bad-parent "$BASH" "$CACHE_PUBLISH_PROBE"\nCACHE_PUBLISH_RC=$?\nset -e\n[[ "$CACHE_PUBLISH_RC" -ne 0 ]] || fail "setup cache publisher hid directory creation failure"\nassert_file_contains "$CACHE_PUBLISH_LOG" 'Could not create Cloudflare CIDR cache directory'\n\n# Initial setup UFW acceptance checks use the same stateful UFW mock.\nSETUP_UFW_PROBE="$TMP/setup-ufw-probe.bash"\n'''
if anchor not in t:
    raise SystemExit('cache publisher test insertion anchor missing')
p.write_text(t.replace(anchor, block, 1))
