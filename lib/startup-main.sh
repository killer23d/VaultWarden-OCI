# shellcheck shell=bash

main() {
  log_info "Starting VaultWarden-OCI startup workflow..."

  trap 'operation_release 130; exit 130' INT
  trap 'operation_release 143; exit 143' HUP TERM

  operation_set_phase "startup" "Validating runtime and starting services"
  load_environment || exit 1

  if [[ "$SKIP_PULL" == "true" ]]; then
    log_warn "--skip-pull is deprecated and ignored; ordinary startup never pulls images."
  fi
  if [[ "$SKIP_EGRESS_FIX" == "true" ]]; then
    log_warn "--skip-egress-fix is deprecated and ignored; ordinary startup validates NAT without repairing it."
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    _show_dry_run_configuration_plan
    _report_dry_run_permission_state || exit 1
    check_project_state_ready || exit 1
    validate_prerequisites || exit 1
    prepare_directories || exit 1
    prepare_log_directories || exit 1
    prepare_docker_secrets || exit 1
    prepare_push_secret_placeholders || exit 1
    log_info "[DRY RUN] Would inspect managed Docker orphans without deleting resources."
    log_info "[DRY RUN] Would validate VaultWarden egress NAT without modifying firewall state."
    log_info "[DRY RUN] Would validate configured DNS without calling the provider."
    log_info "[DRY RUN] Would verify every required pinned image is available locally."
    _startup_start_services || exit 1
    log_success "VaultWarden-OCI startup dry-run completed"
    _show_startup_warnings
    return 0
  fi

  check_project_state_ready || exit 1

  if [[ "$REPAIR" == "true" ]]; then
    operation_set_phase "repair-permissions" "Repairing runtime permissions"
    repair_critical_permissions || exit 1
    operation_set_phase "repair-orphans" "Reconciling managed Docker orphans"
    reconcile_managed_orphans || exit 1
    operation_set_phase "repair-nat" "Reconciling VaultWarden egress NAT"
    repair_vaultwarden_egress_nat || exit 1
    operation_set_phase "repair-dns" "Reconciling DNS"
    repair_dns_state || exit 1
  fi

  operation_set_phase "validate" "Validating runtime state"
  validate_critical_permissions || exit 1
  check_age_key_health_preflight || exit 1
  validate_prerequisites || exit 1
  inspect_managed_orphans || exit 1
  validate_vaultwarden_egress_nat || exit 1
  validate_dns_state || exit 1
  validate_local_images || exit 1

  operation_set_phase "prepare" "Preparing ephemeral runtime state"
  prepare_directories || exit 1
  prepare_log_directories || exit 1
  prepare_docker_secrets || exit 1
  prepare_push_secret_placeholders || exit 1
  check_email_config_consistency || true
  warn_plaintext_secret_overrides || true

  operation_set_phase "start" "Starting services"
  _startup_start_services || exit 1

  if [[ "$BACKGROUND" != "true" ]]; then
    local readiness_rc=0
    local health_rc=0

    wait_for_services || readiness_rc=$?
    wait_for_optional_services || true
    run_health_check || health_rc=$?

    if (( readiness_rc != 0 )); then
      log_error "One or more critical services failed their startup readiness check"
      log_error "Review the health output and container logs before retrying"
      _show_startup_warnings
      exit "$readiness_rc"
    fi

    if (( health_rc != 0 )); then
      log_error "Startup tip: if the failure is key-related, run: sudo make key-health"
      log_error "Canonical production key path: ${AGE_KEY_FILE}"
      _show_startup_warnings
      exit "$health_rc"
    fi

    show_status || true
  fi

  log_success "VaultWarden-OCI startup completed"
  _show_startup_warnings
}

main "$@"
