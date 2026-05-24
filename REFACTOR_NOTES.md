# Refactor Notes — lib/common.sh Decomposition + Multi-Arch Support

## Summary
Refactored `lib/common.sh` into a facade model and extracted logging, validation, and config concerns into dedicated libraries with idempotency guards.
`init_common_lib()` now exports `HOST_ARCH` and `GITHUB_ARCH`, and architecture selection logic in setup scripts was consolidated to use these shared exports.

## Files Created
| File | Purpose | Idempotency Guard |
|------|---------|-------------------|
| lib/log.sh | Logging, colour constants, log-level filtering | VW_LOG_LIB_LOADED |
| lib/validate.sh | Pure input validation (RFC-compliant) | VW_VALIDATE_LIB_LOADED |
| lib/config.sh | Secure .env parsing, config state management | VW_CONFIG_LIB_LOADED |

## Dependency Map
| FILE | SOURCES common.sh? | FUNCTIONS USED FROM common.sh | INLINE ARCH DETECTION? |
|---|---|---|---|
| setup.sh | yes | init_common_lib, log_info, log_warn, log_error, log_header, is_root, validate_email, validate_domain, _require_script | no |
| startup.sh | yes | init_common_lib, log_info/log_success/log_warn/log_error, get_config_value, auto_fix_critical_permissions, get_real_user, _maybe_sudo | no |
| edit-secrets.sh | yes | init_common_lib, log_error | no |
| utilities/setup-system.sh | yes | init_common_lib, log_*, require_commands, get_real_user, _require_script | no |
| utilities/setup-crowdsec.sh | yes | init_common_lib, set_log_prefix, load_env_file | yes (fallback-only; see deviations) |
| utilities/setup-env.sh | yes | init_common_lib, log_*, get_real_user, _set_env_var, _read_env_value | no |
| utilities/setup-firewall.sh | yes | init_common_lib, log_*, log_rollback, log_dry_run | no |
| utilities/setup-secrets.sh | yes | init_common_lib, log_*, require_commands, get_real_user, _require_script, _read_env_value | no |
| utilities/setup-storage.sh | yes | init_common_lib, log_*, load_env_file, require_commands, get_real_user, ensure_dir | no |
| utilities/setup-systemd.sh | yes | init_common_lib, log_*, _set_env_var, _read_env_value | no |
| utilities/backup-run.sh | yes | init_common_lib, log_*, load_env_file, get_config_value, require_commands, require_root, ensure_dir, secure_file | no |
| utilities/restore-run.sh | yes | init_common_lib, log_*, load_env_file, get_config_value, require_root, ensure_dir | no |
| utilities/maintenance-*.sh | yes | init_common_lib, log_*, load_env_file/get_config_value, cleanup helpers | no |
| utilities/secrets-*.sh | yes | init_common_lib, log_*, register_cleanup, perform_cleanup | no |
| utilities/pre-production-drill.sh | yes | init_common_lib, log_*, load_env_file, get_config_value, has_command, require_root | no |
| utilities/smoke-test.sh | yes | init_common_lib, log_*, load_env_file, get_config_value, has_command, require_root | no |

## Function Moves
| FUNCTION | CURRENT FILE | MOVES TO |
|---|---|---|
| log_info | lib/common.sh | lib/log.sh |
| log_success | lib/common.sh | lib/log.sh |
| log_warn | lib/common.sh | lib/log.sh |
| log_error | lib/common.sh | lib/log.sh |
| log_debug | lib/common.sh | lib/log.sh |
| log_header | lib/common.sh | lib/log.sh |
| log_rollback | lib/common.sh | lib/log.sh |
| log_dry_run | lib/common.sh | lib/log.sh |
| set_log_prefix | lib/common.sh | lib/log.sh |
| _should_log | lib/common.sh | lib/log.sh |
| _get_timestamp | lib/common.sh | lib/log.sh |
| validate_email | lib/common.sh | lib/validate.sh |
| validate_domain | lib/common.sh | lib/validate.sh |
| validate_port | lib/common.sh | lib/validate.sh |
| validate_ip | lib/common.sh | lib/validate.sh |
| validate_url | lib/common.sh | lib/validate.sh |
| _get_file_perms | lib/common.sh | lib/config.sh |
| load_env_file | lib/common.sh | lib/config.sh |
| get_config_value | lib/common.sh | lib/config.sh |
| require_config | lib/common.sh | lib/config.sh |
| _set_env_var | lib/common.sh | lib/config.sh |
| _read_env_value | lib/common.sh | lib/config.sh |
| init_common_lib | lib/common.sh | stays in common.sh |

## Files Modified
- `lib/common.sh` — converted to facade loader, added modular sources, retained core utility functions, added architecture export logic.
- `lib/log.sh` — new logging/color domain library with logging exports.
- `lib/validate.sh` — new pure validation domain library with validation exports.
- `lib/config.sh` — new secure environment/config domain library with config exports.
- `utilities/setup-system.sh` — replaced inline architecture detection with `HOST_ARCH`/`GITHUB_ARCH`.
- `utilities/setup-crowdsec.sh` — initialized common facade via `init_common_lib`; uses `GITHUB_ARCH` when available.
- `README.md` — updated `lib/` structure docs and architecture support statement.
- `RUNBOOK.md` — added facade and multi-arch support note.
- `CHANGELOG.md` — added top unreleased entry for this refactor.
- `docs/SCRIPTS.md` — updated library inventory and API docs for facade/log/validate/config split.
- `docs/DEPLOYMENT.md` — clarified arm64 + amd64/x86_64 Ubuntu support.
- `docs/EMAIL.md`, `docs/CONFIGURATION.md`, `docs/ADVANCED-CUSTOMIZATION.md`, `docs/MIGRATION.md` — corrected email library references to `lib/email.sh`.

## Architecture Detection
`HOST_ARCH` and `GITHUB_ARCH` are intentionally separate:
- `HOST_ARCH` is dpkg-canonical (`amd64`, `arm64`, `armhf`) for apt sources and Docker manifest semantics.
- `GITHUB_ARCH` matches release asset naming (`amd64`, `arm64`, `arm`) to avoid `armhf` asset mismatches.

## Inline Arch Detection Instances Removed
| File | Location / Function | Replacement |
|---|---|---|
| utilities/setup-system.sh | `install_docker()` apt source arch | `local arch="${HOST_ARCH}"` |
| utilities/setup-system.sh | `install_dependencies()` universe fallback branch 1 | `local arch="${HOST_ARCH}"` |
| utilities/setup-system.sh | `install_dependencies()` universe fallback branch 2 | `local arch="${HOST_ARCH}"` |
| utilities/setup-system.sh | SOPS installer asset arch + armhf override | `local arch="${GITHUB_ARCH}"` (manual override removed) |

## Instruction Deviations
1. **Overridden instruction:** place common facade source directives immediately after `LIB_DIR` declaration.
   **Alternative used:** source directives were placed after both `LIB_DIR` and `PROJECT_ROOT` declarations.
   **Why better:** `lib/config.sh` computes default `.env` search paths from project root context; retaining `PROJECT_ROOT` initialization first avoids order-coupling and keeps stable behavior for existing callers.

2. **Overridden instruction:** eliminate all inline architecture detection in files that source `common.sh`.
   **Alternative used:** `utilities/setup-crowdsec.sh` now uses `GITHUB_ARCH` when `common.sh` is loaded, but retains a local fallback detection path only when common libraries are unavailable.
   **Why better:** preserves standalone safety behavior already present in that script while still consolidating architecture logic for normal/common-sourced execution.

## Known Limitations / Follow-up Work
- `utilities/setup-crowdsec.sh` still contains fallback arch detection for no-lib standalone mode; this is intentional and documented above.
- Repository-level `make test` currently fails at `test-secrets` due missing secrets context in sandbox; unchanged by this refactor.
