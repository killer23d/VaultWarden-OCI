# shellcheck shell=bash

_startup_expected_services() {
  docker compose config --services 2>/dev/null
}

_startup_project_containers() {
  docker ps -a \
    --filter "$DOCKER_PROJECT_LABEL" \
    --format '{{.ID}}\t{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Names}}'
}

inspect_managed_orphans() {
  local id service state name conflict=false
  local -A expected=()
  while IFS= read -r service; do
    [[ -n "$service" ]] && expected["$service"]=1
  done < <(_startup_expected_services)
  (( ${#expected[@]} > 0 )) || {
    log_error "Could not resolve expected Compose services for orphan validation."
    return 1
  }

  while IFS=$'\t' read -r id service state name; do
    [[ -n "$id" ]] || continue
    [[ -n "$service" && -n "${expected[$service]:-}" ]] && continue
    case "$state" in
      running|restarting|paused)
        log_error "Conflicting managed orphan container is active: ${name:-$id} (state: $state)"
        conflict=true
        ;;
      *)
        log_warn "Harmless stopped managed orphan remains: ${name:-$id} (state: ${state:-unknown})"
        ;;
    esac
  done < <(_startup_project_containers | sort -k4)

  if [[ "$conflict" == "true" ]]; then
    log_error "Ordinary startup will not delete managed Docker resources."
    log_error "Run: ${STARTUP_REPAIR_COMMAND}"
    return 1
  fi
  return 0
}

reconcile_managed_orphans() {
  local id service state name
  local -a orphan_ids=()
  local -A expected=()
  while IFS= read -r service; do
    [[ -n "$service" ]] && expected["$service"]=1
  done < <(_startup_expected_services)
  (( ${#expected[@]} > 0 )) || {
    log_error "Could not resolve expected Compose services for orphan reconciliation."
    return 1
  }

  while IFS=$'\t' read -r id service state name; do
    [[ -n "$id" ]] || continue
    [[ -n "$service" && -n "${expected[$service]:-}" ]] && continue
    log_info "Removing managed orphan container: ${name:-$id} (state: ${state:-unknown})"
    orphan_ids+=("$id")
  done < <(_startup_project_containers | sort -k4)

  if (( ${#orphan_ids[@]} == 0 )); then
    log_info "No managed orphan containers require reconciliation."
    return 0
  fi
  docker rm -f -- "${orphan_ids[@]}" >/dev/null || {
    log_error "Managed orphan container reconciliation failed."
    return 1
  }
  log_success "Managed orphan containers reconciled."
}

validate_vaultwarden_egress_nat() {
  local failed=false subnet
  command -v iptables >/dev/null 2>&1 || {
    log_error "iptables is unavailable; required VaultWarden egress NAT cannot be verified."
    log_error "Run: ${STARTUP_FIREWALL_REPAIR_COMMAND}"
    log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
    return 1
  }

  if ! iptables -t nat -C POSTROUTING -s 172.21.0.0/16 ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
    log_error "Missing VaultWarden egress MASQUERADE rule for 172.21.0.0/16."
    failed=true
  fi
  for subnet in 172.21.0.0/16 172.22.0.0/16 172.23.0.0/16; do
    if ! iptables -t filter -C DOCKER-USER -s "$subnet" -j ACCEPT >/dev/null 2>&1; then
      log_error "Missing DOCKER-USER ACCEPT rule for managed subnet $subnet."
      failed=true
    fi
  done
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    log_error "netfilter-persistent is unavailable; verified live NAT rules would not be durable."
    failed=true
  fi

  if [[ "$failed" == "true" ]]; then
    log_error "Ordinary startup will not modify live or persisted firewall state."
    log_error "Run: ${STARTUP_FIREWALL_REPAIR_COMMAND}"
    log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
    return 1
  fi
  log_success "VaultWarden egress NAT and persistence prerequisites validated."
}

repair_vaultwarden_egress_nat() {
  local firewall_script="${PROJECT_ROOT}/utilities/setup-firewall.sh"
  [[ -x "$firewall_script" ]] || {
    log_error "Firewall repair script is missing or not executable: $firewall_script"
    return 1
  }
  log_info "Reconciling VaultWarden egress NAT..."
  # The parent startup guard is exported by lib/operations.sh and verified by
  # the child operation. Omit --auto so repair never installs packages.
  "$firewall_script" --phase iptables </dev/null || {
    log_error "VaultWarden egress NAT repair failed."
    return 1
  }
  validate_vaultwarden_egress_nat || {
    log_error "VaultWarden egress NAT is still incomplete after repair."
    return 1
  }
  log_success "VaultWarden egress NAT reconciled."
}

validate_dns_state() {
  local domain="${DOMAIN:-}"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  [[ -n "$domain" ]] || {
    log_error "DOMAIN is empty; DNS state cannot be validated."
    return 1
  }
  if getent ahosts "$domain" >/dev/null 2>&1; then
    log_success "DNS resolves for configured domain: $domain"
    return 0
  fi
  log_error "Configured domain does not currently resolve: $domain"
  log_error "Ordinary startup will not modify external DNS records."
  log_error "Run: ${STARTUP_DNS_REPAIR_COMMAND}"
  log_error "Or run: ${STARTUP_REPAIR_COMMAND}"
  return 1
}

repair_dns_state() {
  local dns_script="${PROJECT_ROOT}/utilities/maintenance-update-dns.sh"
  [[ -x "$dns_script" ]] || {
    log_error "DNS repair script is missing or not executable: $dns_script"
    return 1
  }
  log_info "Reconciling configured DNS state..."
  # The existing DNS entrypoint inherits and verifies the parent startup guard.
  "$dns_script" || {
    log_error "DNS reconciliation failed."
    return 1
  }
  validate_dns_state || {
    log_error "DNS is still unresolved after reconciliation."
    return 1
  }
  log_success "DNS reconciliation completed."
}

validate_local_images() {
  local image
  local -a images=() missing=()
  mapfile -t images < <(docker compose config --images 2>/dev/null | awk 'NF && !seen[$0]++')
  (( ${#images[@]} > 0 )) || {
    log_error "No Compose images could be resolved from the selected configuration."
    return 1
  }
  for image in "${images[@]}"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      missing+=("$image")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "Required local container image(s) are unavailable:"
    for image in "${missing[@]}"; do
      log_error "  $image"
    done
    log_error "Startup will not pull images implicitly."
    log_error "Run: ${STARTUP_IMAGE_UPDATE_COMMAND}"
    return 1
  fi
  log_success "All required pinned images are available locally."
}

_startup_start_services() {
  log_info "Starting VaultWarden services with local images only..."

  local compose_args=(
    up
    -d
    --pull never
  )

  if [[ "$FORCE_RESTART" == "true" ]]; then
    compose_args+=(--force-recreate)
    log_info "Force restart requested; Docker Compose will recreate existing containers."
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: docker compose ${compose_args[*]}"
    return 0
  fi

  if ! docker compose "${compose_args[@]}"; then
    log_error "docker compose ${compose_args[*]} failed"
    log_error "If an image is missing, run: ${STARTUP_IMAGE_UPDATE_COMMAND}"
    return 1
  fi

  log_success "Services started"
  return 0
}

# Critical services to health-wait are declared in _VW_DEFAULT_CRITICAL_SERVICES
# (lib/defaults.sh). Add a new sidecar there — not here — when the stack grows.
