#!/usr/bin/env bash
# lib/firewall.sh — Shared Docker/Cloudflare packet-filtering helpers.
#
# This library deliberately owns only the Docker-published web ingress gate and
# Docker firewall-backend validation. UFW remains a host-firewall defence layer;
# Docker-published traffic is enforced in DOCKER-USER before Docker's own
# forwarding/isolation chains.

[[ -n "${VW_FIREWALL_LIB_LOADED:-}" ]] && return 0
readonly VW_FIREWALL_LIB_LOADED=1
readonly VW_CF_DOCKER_CHAIN="VW-CF-INGRESS"
readonly VW_CADDY_EXTERNAL_CIDR="172.22.0.0/28"

_firewall_find_running_dockerd_pid() {
    local proc_root="${DOCKER_PROC_ROOT:-/proc}" proc_dir comm pid="" count=0
    for proc_dir in "$proc_root"/[0-9]*; do
        [[ -r "$proc_dir/comm" && -r "$proc_dir/cmdline" ]] || continue
        IFS= read -r comm < "$proc_dir/comm" || continue
        [[ "$comm" == "dockerd" ]] || continue
        pid="${proc_dir##*/}"
        count=$((count + 1))
    done
    if (( count != 1 )); then
        log_error "Expected exactly one running dockerd process, found ${count}."
        log_error "Check: systemctl status docker --no-pager -l"
        return 1
    fi
    printf '%s\n' "$pid"
}

firewall_docker_backend_preflight() {
    local cmd
    for cmd in docker iptables iptables-save iptables-restore python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "$cmd command not found"
            return 1
        fi
    done

    local proc_root="${DOCKER_PROC_ROOT:-/proc}" pid
    pid="$(_firewall_find_running_dockerd_pid)" || return $?

    local -a argv=()
    mapfile -d '' -t argv < "$proc_root/$pid/cmdline" || {
        log_error "Could not read running dockerd command line from $proc_root/$pid/cmdline"
        return 1
    }
    (( ${#argv[@]} > 0 )) || {
        log_error "Running dockerd command line is empty."
        return 1
    }

    local config_file="${DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}"
    local config_explicit=false cli_backend="" cli_iptables="" arg value i
    for (( i=1; i<${#argv[@]}; i++ )); do
        arg="${argv[$i]}"
        case "$arg" in
            --config-file=*)
                config_file="${arg#*=}"
                config_explicit=true
                ;;
            --config-file)
                (( i + 1 < ${#argv[@]} )) || {
                    log_error "Running dockerd has --config-file without a value."
                    return 1
                }
                i=$((i + 1))
                config_file="${argv[$i]}"
                config_explicit=true
                ;;
            --firewall-backend=*)
                cli_backend="${arg#*=}"
                ;;
            --firewall-backend)
                (( i + 1 < ${#argv[@]} )) || {
                    log_error "Running dockerd has --firewall-backend without a value."
                    return 1
                }
                i=$((i + 1))
                cli_backend="${argv[$i]}"
                ;;
            --iptables=*)
                cli_iptables="${arg#*=}"
                ;;
            --iptables)
                # Docker boolean flags default to true when present without =VALUE.
                cli_iptables=true
                if (( i + 1 < ${#argv[@]} )); then
                    value="${argv[$((i + 1))]}"
                    if [[ "$value" == "true" || "$value" == "false" ]]; then
                        i=$((i + 1))
                        cli_iptables="$value"
                    fi
                fi
                ;;
        esac
    done

    local backend="iptables" iptables_enabled="true" config_values=""
    if [[ -e "$config_file" ]]; then
        if [[ ! -r "$config_file" ]]; then
            log_error "Docker daemon configuration is not readable: ${config_file}"
            return 1
        fi
        config_values="$(python3 - "$config_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)
backend = cfg.get("firewall-backend", "iptables")
iptables_enabled = cfg.get("iptables", True)
if not isinstance(backend, str) or not isinstance(iptables_enabled, bool):
    raise SystemExit(2)
print(f"{backend}\t{'true' if iptables_enabled else 'false'}")
PY
)" || {
            log_error "Could not parse Docker daemon firewall configuration: ${config_file}"
            return 1
        }
        IFS=$'\t' read -r backend iptables_enabled <<< "$config_values"
    elif [[ "$config_explicit" == "true" ]]; then
        log_error "Running dockerd explicitly references a missing config file: ${config_file}"
        return 1
    fi

    [[ -z "$cli_backend" ]] || backend="$cli_backend"
    if [[ -n "$cli_iptables" ]]; then
        case "$cli_iptables" in
            true|false) iptables_enabled="$cli_iptables" ;;
            *)
                log_error "Unsupported dockerd --iptables value: ${cli_iptables}"
                return 1
                ;;
        esac
    fi

    if [[ "$backend" != "iptables" || "$iptables_enabled" != "true" ]]; then
        log_error "Unsupported running Docker firewall configuration: backend=${backend}, iptables=${iptables_enabled}."
        log_error "VaultWarden-OCI requires the Docker iptables firewall backend with iptables management enabled."
        log_error "Inspect: systemctl cat docker && tr '\\0' ' ' < /proc/${pid}/cmdline"
        return 1
    fi

    if ! iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
        log_error "Docker DOCKER-USER chain is unavailable under the running iptables backend."
        log_error "Restart docker.service after correcting Docker firewall configuration, then retry."
        return 1
    fi
    if ! iptables -m conntrack -h >/dev/null 2>&1; then
        log_error "iptables conntrack matching is unavailable; cannot safely identify Docker-published web ports."
        return 1
    fi
}

firewall_fail_closed_stop_caddy() {
    local container="${VW_CADDY_CONTAINER_NAME:-vaultwarden_caddy}" running="" rc=0
    [[ "${DRY_RUN:-false}" != "true" ]] || return 0
    command -v docker >/dev/null 2>&1 || {
        log_error "CRITICAL: firewall reconciliation failed and Docker is unavailable; cannot confirm ${container} is stopped."
        return 1
    }

    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        local listed=""
        if ! listed="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>/dev/null)"; then
            log_error "CRITICAL: firewall reconciliation failed and Docker could not confirm whether ${container} exists."
            return 1
        fi
        [[ "$listed" != "$container" ]] && return 0
        log_error "CRITICAL: firewall reconciliation failed and ${container} running state could not be determined."
        return 1
    fi
    [[ "$running" == "true" ]] || return 0

    log_warn "Firewall reconciliation failed; stopping ${container} to keep published web ingress fail-closed."
    if ! docker stop --time 30 "$container" >/dev/null; then
        log_error "CRITICAL: could not stop ${container} after firewall failure."
        return 1
    fi
    log_warn "${container} is stopped. Fix the firewall error, then start the stack normally."
    return 0
}

firewall_normalize_caddy_runtime_contract() {
    local container="${VW_CADDY_CONTAINER_NAME:-vaultwarden_caddy}"
    local listed="" policy="" bindings="" binding_ok=false
    [[ "${DRY_RUN:-false}" != "true" ]] || return 0

    command -v docker >/dev/null 2>&1 || {
        log_error "Docker is unavailable; cannot verify the existing Caddy runtime contract."
        return 1
    }
    listed="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>/dev/null)" || {
        log_error "Docker could not query the existing Caddy container."
        return 1
    }
    [[ "$listed" == "$container" ]] || return 0

    policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)" || {
        log_error "Could not inspect ${container} restart policy."
        return 1
    }
    bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$container" 2>/dev/null)" || {
        log_error "Could not inspect ${container} published-port bindings."
        return 1
    }

    if python3 - "$bindings" <<'PY'
import json
import sys
try:
    bindings = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
for port in ("80/tcp", "443/tcp"):
    entries = bindings.get(port)
    if not isinstance(entries, list) or len(entries) != 1:
        raise SystemExit(1)
    entry = entries[0]
    if entry.get("HostIp") != "0.0.0.0" or entry.get("HostPort") != port.split("/", 1)[0]:
        raise SystemExit(1)
raise SystemExit(0)
PY
    then
        binding_ok=true
    fi

    if [[ "$binding_ok" != "true" ]]; then
        log_warn "Existing ${container} has legacy/non-IPv4-only published web bindings; removing the ephemeral container after firewall reconciliation."
        log_warn "Run the normal startup workflow to recreate Caddy from the current Compose contract."
        docker stop --time 30 "$container" >/dev/null 2>&1 || true
        if ! docker rm -f "$container" >/dev/null; then
            log_error "Could not remove unsafe legacy ${container} runtime."
            return 1
        fi
        return 0
    fi

    if [[ "$policy" != "on-failure" ]]; then
        log_info "Updating ${container} restart policy to on-failure for Docker lifecycle safety."
        if ! docker update --restart on-failure "$container" >/dev/null; then
            log_error "Could not update ${container} restart policy."
            return 1
        fi
    fi
    return 0
}

firewall_load_cached_cloudflare_ipv4() {
    local out_name="$1"
    local -n out_ref="$out_name"
    local cache_file="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"
    local cidr
    out_ref=()

    if [[ ! -s "$cache_file" ]]; then
        log_error "Cloudflare CIDR cache is missing: ${cache_file}"
        log_error "Run: sudo utilities/setup-firewall.sh --phase ufw"
        return 1
    fi
    if [[ -n "$(find "$cache_file" -mtime +7 -print -quit 2>/dev/null)" ]]; then
        log_error "Cloudflare CIDR cache is older than 7 days: ${cache_file}"
        log_error "Refresh it before Docker ingress reconciliation."
        return 1
    fi

    while IFS= read -r cidr || [[ -n "$cidr" ]]; do
        [[ -z "$cidr" || "$cidr" == \#* ]] && continue
        if [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            out_ref+=("$cidr")
        elif [[ "$cidr" == *:* ]]; then
            # Public Caddy bindings are IPv4-only; IPv6 ranges remain relevant
            # to the UFW defence layer but are not used in this iptables gate.
            continue
        else
            log_error "Invalid entry in Cloudflare CIDR cache: ${cidr}"
            return 1
        fi
    done < "$cache_file"

    if (( ${#out_ref[@]} == 0 )); then
        log_error "Cloudflare CIDR cache contains no IPv4 ranges: ${cache_file}"
        return 1
    fi
}

_firewall_chain_rule_count() {
    local chain="$1"
    iptables -t filter -S "$chain" 2>/dev/null | grep -c "^-A ${chain} " || true
}

_firewall_parent_jump_is_exact() {
    local line first_rule="" jump_count=0
    while IFS= read -r line; do
        [[ "$line" == "-A DOCKER-USER "* ]] || continue
        [[ -n "$first_rule" ]] || first_rule="$line"
        [[ "$line" == "-A DOCKER-USER -j ${VW_CF_DOCKER_CHAIN}" ]] && jump_count=$((jump_count + 1))
    done < <(iptables -t filter -S DOCKER-USER 2>/dev/null)
    [[ "$first_rule" == "-A DOCKER-USER -j ${VW_CF_DOCKER_CHAIN}" && "$jump_count" -eq 1 ]]
}

_firewall_managed_chain_order_is_safe() {
    iptables -t filter -S "$VW_CF_DOCKER_CHAIN" 2>/dev/null |
        awk -v chain="$VW_CF_DOCKER_CHAIN" '
            $1 == "-A" && $2 == chain {
                if ($NF == "RETURN" && seen_drop) bad=1
                if ($NF == "DROP") seen_drop=1
            }
            END { exit bad ? 1 : 0 }
        '
}

firewall_docker_ingress_is_exact() {
    local -a cidrs=("$@")
    (( ${#cidrs[@]} > 0 )) || return 1

    _firewall_parent_jump_is_exact || return 1
    iptables -t filter -S "$VW_CF_DOCKER_CHAIN" >/dev/null 2>&1 || return 1

    local expected_count=$(( ${#cidrs[@]} * 2 + 3 )) actual_count cidr port
    actual_count="$(_firewall_chain_rule_count "$VW_CF_DOCKER_CHAIN")"
    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" -eq "$expected_count" ]] || return 1
    _firewall_managed_chain_order_is_safe || return 1

    # Replies to connections initiated by Caddy must return to Docker's normal
    # forwarding path instead of being mistaken for new public web ingress.
    iptables -t filter -C "$VW_CF_DOCKER_CHAIN" \
        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
        >/dev/null 2>&1 || return 1

    for cidr in "${cidrs[@]}"; do
        for port in 80 443; do
            iptables -t filter -C "$VW_CF_DOCKER_CHAIN" \
                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \
                >/dev/null 2>&1 || return 1
        done
    done
    for port in 80 443; do
        iptables -t filter -C "$VW_CF_DOCKER_CHAIN" \
            -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport "$port" -j DROP \
            >/dev/null 2>&1 || return 1
    done
    return 0
}

_firewall_delete_duplicate_parent_jumps() {
    local -a positions=()
    local pos i
    mapfile -t positions < <(
        iptables -t filter -S DOCKER-USER 2>/dev/null | \
        awk -v exact="-A DOCKER-USER -j ${VW_CF_DOCKER_CHAIN}" '
            /^-A DOCKER-USER / {n++}
            $0 == exact {print n}
        '
    )
    (( ${#positions[@]} >= 1 )) || return 1
    for (( i=${#positions[@]}-1; i>=1; i-- )); do
        pos="${positions[$i]}"
        iptables -t filter -D DOCKER-USER "$pos" || return $?
    done
}

firewall_reconcile_cloudflare_docker_ingress() {
    local -a cidrs=("$@")
    (( ${#cidrs[@]} > 0 )) || {
        log_error "Refusing Docker ingress reconciliation without Cloudflare IPv4 CIDRs."
        return 1
    }

    if ! iptables -t filter -S "$VW_CF_DOCKER_CHAIN" >/dev/null 2>&1; then
        iptables -t filter -N "$VW_CF_DOCKER_CHAIN" || {
            log_error "Could not create ${VW_CF_DOCKER_CHAIN}."
            return 1
        }
    fi

    # Put fail-closed, project-scoped sentinels at the front before replacing
    # existing managed rules. A failed refresh may temporarily block project web
    # traffic, but unrelated Docker destinations fall through and the origin is
    # never left publicly exposed.
    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 443 -j DROP || return $?
    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
        -d "$VW_CADDY_EXTERNAL_CIDR" -p tcp -m conntrack --ctorigdstport 80 -j DROP || return $?

    local count
    count="$(_firewall_chain_rule_count "$VW_CF_DOCKER_CHAIN")"
    while [[ "$count" =~ ^[0-9]+$ ]] && (( count > 2 )); do
        iptables -t filter -D "$VW_CF_DOCKER_CHAIN" 3 || return $?
        count=$((count - 1))
    done
    [[ "$count" == "2" ]] || {
        log_error "Could not normalize ${VW_CF_DOCKER_CHAIN} before rebuilding it."
        return 1
    }

    local cidr port
    # RETURN, never ACCEPT: permitted Cloudflare packets continue through
    # Docker's own forwarding/isolation rules instead of bypassing them.
    for cidr in "${cidrs[@]}"; do
        for port in 80 443; do
            iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
                -d "$VW_CADDY_EXTERNAL_CIDR" -s "$cidr" -p tcp -m conntrack --ctorigdstport "$port" -j RETURN \
                || return $?
        done
    done

    # This must remain ahead of the source DROP rules: Caddy-initiated HTTP,
    # HTTPS, DNS, and related reply traffic is not new public ingress. RETURN
    # keeps Docker authoritative for the eventual forwarding decision.
    iptables -t filter -I "$VW_CF_DOCKER_CHAIN" 1 \
        -d "$VW_CADDY_EXTERNAL_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
        || return $?

    # Install a new first-rule jump before deleting older duplicate jumps, so
    # an existing gate is never removed before its replacement is active.
    iptables -t filter -I DOCKER-USER 1 -j "$VW_CF_DOCKER_CHAIN" || return $?
    _firewall_delete_duplicate_parent_jumps || {
        log_error "Could not normalize the DOCKER-USER jump to ${VW_CF_DOCKER_CHAIN}."
        return 1
    }

    if ! firewall_docker_ingress_is_exact "${cidrs[@]}"; then
        log_error "Docker Cloudflare ingress gate failed final exact-state verification."
        return 1
    fi
    log_success "Project Caddy TCP 80/443 restricted to current Cloudflare IPv4 ranges without ACCEPT shortcuts"
}
