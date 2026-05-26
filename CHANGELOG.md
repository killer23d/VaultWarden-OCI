# Changelog

All notable changes to VaultWarden-OCI are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---
## [Unreleased]

### Changed — Shared-lib consolidation and startup deduplication

- Moved `_maybe_sudo()` from `startup.sh` to `lib/common.sh` and exported it for shared callers.
- Moved `ensure_caddy_log_permissions()` from `startup.sh` to `lib/storage.sh`.
- Changed `lib/common.sh::validate_domain()` to enforce RFC 1035 domain-length ceiling (253 chars) and reject bare IPv4 input.
- Changed `lib/common.sh::validate_email()` to enforce RFC 5321 email-length ceiling (254 chars) and apply a stricter character-class regex.
- Removed `validate_domain_secure()` and `validate_email_secure()` from `setup.sh`; callers now use upgraded canonical validators in `lib/common.sh`.
- Removed the inline NAT fallback loop from `startup.sh::ensure_vaultwarden_egress_nat()`; firewall remediation now remains canonical in `utilities/setup-firewall.sh`.
- Removed the inline service wait loop from `startup.sh::wait_for_services()`; readiness now delegates to `lib/docker.sh::wait_for_service_ready()`.

### Fixed

- `utilities/uninstall-vaultwarden.sh`: added Step 11.5 cleanup for iptables rules managed by `utilities/setup-firewall.sh`.
- `utilities/maintenance-health.sh`: fixed CrowdSec Cloudflare bouncer health check to treat a missing unit as an optional/not-installed pass state (no false warning).

### Changed — Dispatcher Refactor: maintenance.sh / backup.sh / restore.sh

- **`maintenance.sh`** is now a thin dispatcher (< 60 lines). All logic has been
  extracted into dedicated `utilities/maintenance-*.sh` standalone scripts.
  The external CLI surface is **unchanged** — every subcommand still works
  identically via the dispatcher.

- **`backup.sh`** is now a thin 3-line `exec` forwarder to
  `utilities/backup-run.sh`, which contains the complete backup engine verbatim.
  All subcommands (`run`, `list`, `verify`, `rotate`) work identically.

- **`restore.sh`** is now a thin 3-line `exec` forwarder to
  `utilities/restore-run.sh`. All subcommands work identically.

### Added — New utilities/ entry points (directly callable)

| New file | Dispatcher subcommand |
|---|---|
| `utilities/maintenance-run.sh` | `./maintenance.sh run` |
| `utilities/maintenance-health.sh` | `./maintenance.sh health` |
| `utilities/maintenance-update.sh` | `./maintenance.sh update` |
| `utilities/maintenance-db-maint.sh` | `./maintenance.sh db-maint` |
| `utilities/maintenance-email.sh` | `./maintenance.sh test-email` |
| `utilities/maintenance-update-dns.sh` | `./maintenance.sh update-dns` |
| `utilities/maintenance-update-firewall.sh` | `./maintenance.sh update-firewall` |
| `utilities/backup-run.sh` | `./backup.sh` (all subcommands) |
| `utilities/restore-run.sh` | `./restore.sh` (all subcommands) |

Each utility:
- Has `#!/usr/bin/env bash` and its own `--help`
- Sets `SCRIPT_DIR` / `PROJECT_ROOT` to the project root so all `lib/` and
  `secrets/` paths resolve correctly
- Has `main "$@"` at the bottom and an operations `flock` lock where relevant
- Is independently shellcheck-clean (`bash -n` passes)

### Added — `lib/maintenance-utils.sh`

Shared library sourced by `maintenance-run.sh`, `maintenance-db-maint.sh`, and
`maintenance-email.sh`. Contains: `cleanup_logs`, `cleanup_backups`,
`cleanup_docker_system`, `optimize_database`, `validate_system_health`,
`generate_maintenance_summary`, `_default_backup_dir`, `_default_alert_state_dir`,
`_default_report_dir`, `_wait_wal_quiesce`, `verbose_log`.

### Changed — `utilities/setup-systemd.sh` (four bug fixes)

1. **`scripts_to_install` extended** with all new `utilities/` scripts and
   `restore.sh` (which was previously missing — see below). The install loop
   now uses `mkdir -p "$(dirname "$dest")"` + `install` to preserve the
   `utilities/` subdirectory structure at `/opt/vaultwarden-scripts/`.
   `setup-firewall.sh` retains its pre-existing flat-install path for
   `vaultwarden-iptables.service` compatibility.

2. **`scripts_to_check` extended** inside `validate_installation()` (the
   sha256 split-brain check at step 7/8) to cover all new `utilities/` scripts.

3. **`restore.sh` added to `scripts_to_install`** (intentional new behaviour;
   `restore.sh` is now deployed to `/opt/vaultwarden-scripts/restore.sh` on
   `setup-systemd.sh install`). This is new — `restore.sh` was never copied to
   `/opt/` before this release.

4. **`WHAT install DOES:` prose block** in `_sd_show_help()` updated to
   accurately list all installed scripts and the `utilities/` subdirectory.

---
## [Unreleased]

### Changed — Fail2Ban → CrowdSec Migration

- **Security layer**: Replaced the `crazymax/fail2ban` Docker container with
  CrowdSec running as a **host systemd service** (`crowdsec` + bouncers).
- **Cloudflare bouncer**: Bans at the Cloudflare WAF edge are now handled by
  `crowdsec-cloudflare-worker-bouncer`; reads the same `cf_worker_bouncer_token`
  secret path for backward compatibility.
- **SSH/iptables bouncer**: Host iptables rules for SSH protection are now
  managed by `crowdsec-firewall-bouncer` instead of Fail2Ban.
- **Caddy image**: Replaced third-party `CaddyBuilds/caddy-cloudflare` with a
  locally-built image (`caddy/Dockerfile`) that includes `mholt/caddy-ratelimit`
  for in-process rate limiting (first layer of the three-layer defence).
- **Docker stack**: Reduced from 4 containers (`vaultwarden`, `caddy`,
  `fail2ban`, `postfix`) to 3 (`vaultwarden`, `caddy`, `postfix`).
- **Three-layer defence**: Caddy `rate_limit` → CrowdSec detection →
  Cloudflare WAF + iptables ban.
- **Makefile**: `make logs-fail2ban` replaced by `make logs-crowdsec`
  (targets `sudo journalctl -u crowdsec -f`).
- **All documentation** updated to reflect the new architecture, CrowdSec CLI
  commands (`cscli decisions list`, `cscli alerts list`), and host-service model.

### Added

- `crowdsec/` directory with CrowdSec configuration, custom parsers for
  VaultWarden and Caddy logs, and scenario definitions.
- `systemd/vaultwarden-iptables.service`: note that SSH/web bans are managed
  by `crowdsec-firewall-bouncer`.
- `RUNBOOK.md`: new `## 🛡️ CrowdSec Operations` section with management
  commands, self-lockout prevention, and lockout recovery procedures.

### Removed

- `crazymax/fail2ban` Docker container and all Fail2Ban configuration files
  (`fail2ban/jail.d/`, `fail2ban/filter.d/`, `fail2ban/action.d/`).
- `F2B_DEST_MAIL` and `F2B_SENDER` environment variables (Fail2Ban email settings).
- `FAIL2BAN_VERSION` from container version tracking.
- `make logs-fail2ban` Makefile target.

---
## [Unreleased]

### ⚠️ BREAKING: Project-Wide CLI Refactor — Pure Subcommand Pattern

**Every operator-facing script now uses a strict verb-first subcommand pattern.**
No `--flag` top-level dispatchers, no transparent aliases, no silent unknown-argument
acceptance. This is a breaking change for any operator or automation that called
scripts with the old flag syntax.

#### Old → New Invocation Mapping

| Script | Old (pre-refactor) | New (subcommand) |
| :-- | :-- | :-- |
| `backup.sh` | `./backup.sh` (no args) | `./backup.sh` → now prints help + exits 0 |
| `backup.sh` | `./backup.sh --type db --rclone` | `./backup.sh run db --rclone` |
| `backup.sh` | `./backup.sh --type full --rclone` | `./backup.sh run full --rclone` |
| `backup.sh` | `./backup.sh --list` | `./backup.sh list` |
| `restore.sh` | `./restore.sh` (no args) | exits 1 + shows help; use `./restore.sh interactive` |
| `restore.sh` | `./restore.sh --remote` | `./restore.sh interactive --remote` |
| `restore.sh` | `./restore.sh --file PATH` | `./restore.sh interactive --file PATH` |
| `restore.sh` | `./restore.sh --preflight` | `./restore.sh interactive --dry-run` |
| `setup.sh` | `./setup.sh systemd --install` | `./setup.sh systemd install` |
| `setup.sh` | `./setup.sh systemd --remove` | `./setup.sh systemd remove` |
| `setup.sh` | `./setup.sh systemd --validate` | `./setup.sh systemd validate` |
| `setup.sh` | `./setup.sh systemd --status` | `./setup.sh systemd status` |
| `maintenance.sh` | `./maintenance.sh` (no args) | `./maintenance.sh run` |
| `maintenance.sh` | `./maintenance.sh --full` | `./maintenance.sh run --comprehensive` |
| `maintenance.sh` | `./maintenance.sh --backup` | `./backup.sh run db` |
| `maintenance.sh` | `./maintenance.sh health --auto-recover` | `./maintenance.sh health --fix` |
| `uninstall-vaultwarden.sh` | `./uninstall-vaultwarden.sh` | `./uninstall-vaultwarden.sh run` |
| `uninstall-vaultwarden.sh` | `./uninstall-vaultwarden.sh --i-have-saved-my-recovery-kit` | `./uninstall-vaultwarden.sh run --i-have-saved-my-recovery-kit` |

#### Scripts Changed

- **`backup.sh`** — zero-arg → `show_help; exit 0`; `help` bare-word arm added
- **`restore.sh`** — `interactive` subcommand added for the former no-subcommand interactive mode; zero-arg → `show_help; exit 1`; `help` bare-word arm added; `_require_env_for_live_restore` updated
- **`setup.sh`** — `*)` catch-all added to top-level dispatch; `systemd` arm no longer converts positional `install` → `--install`; `run_phase_systemd` now accepts `install|remove|validate|status` as positional sub-actions; `help` bare-word arm added
- **`maintenance.sh`** — `help` bare-word arm added; `health` sub-parser now exits 1 on unknown options (was `log_warn` + continue)
- **`startup.sh`** — `help` bare-word arm added; unknown first positional emits "Unknown subcommand" (was "Unknown option")
- **`utilities/secrets-edit.sh`** — `help` bare-word arm added; `*)` catch-all added
- **`create-breakglass-admin.sh`** — `help` bare-word arm added
- **`uninstall-vaultwarden.sh`** — full refactor: `show_help()` function extracted; `run` subcommand added; zero-arg guard exits 1; `for _arg` loop replaced with `case "$1"`; silent `*) ;;` fallthrough removed

#### Infrastructure / Call-Site Updates

- `systemd/vaultwarden-db-backup.service` — `ExecStart` updated to `backup.sh run db …`
- `systemd/vaultwarden-full-backup.service` — `ExecStart` updated to `backup.sh run full …`
- `Makefile` — 10 targets updated: `test-email`, `health-quick`, `health-email`, `restore`, `restore-preflight`, `restore-remote`, `maintenance`, `maintenance-full`, `db-backup`, `uninstall`, `uninstall-dry-run`
- All documentation code blocks updated in: `SCRIPTS.md`, `OPERATIONS.md`, `BACKUP-RESTORE.md`, `DEPLOYMENT.md`, `BOOTSTRAP_KEY_RECOVERY.md`, `TROUBLESHOOTING.md`, `CONFIGURATION.md`, `SECURITY.md`, `README.md`

### Added
- **`tests/cli-smoke.sh`** — smoke test suite covering `--help` / `--dry-run` / zero-arg behaviour for every Type A script subcommand.

### Fixed
- `backup.sh` zero-arg no longer exits with code 2 and a misleading error; now correctly shows help and exits 0.
- `restore.sh` zero-arg no longer silently drops into interactive mode on a destructive script; now exits 1 with usage.
- `setup.sh systemd` no longer silently converts `install` → `--install` internally.
- `maintenance.sh health` no longer silently accepts and ignores unknown option flags (`--auto-recover`, `--email`, `--quick`) via a `log_warn` loop.
- `uninstall-vaultwarden.sh` no longer silently accepts all unknown arguments via `*) ;;`.

### Added
- **Separate-volume storage mode** (`DATA_VOLUME_DEVICE` / `DATA_VOLUME_MOUNT`):
  `setup.sh` can now format, UUID-mount, and persist a dedicated OCI block
  volume for all VaultWarden state. Boot-only mode (blank `DATA_VOLUME_DEVICE`)
  is unchanged and remains the default.
- **`lib/storage.sh`** — new shared library providing `require_project_state_ready()`
  (fail-closed guard against writing state to the boot volume when the data
  disk is absent) and `setup_data_volume()` / `install_docker_mount_guard()`.
  Sourced by all operational scripts.
- **Docker systemd mount guard** — `setup.sh` installs a `RequiresMountsFor=`
  drop-in on `docker.service` in separate-volume mode, preventing Docker from
  starting if the data disk is not mounted.
- **Per-unit `ReadWritePaths` drop-ins** — `setup.sh systemd install`
  appends `DATA_VOLUME_MOUNT` to each managed unit's `ReadWritePaths` so
  `ProtectSystem=strict` does not silently block writes to the data volume.

### Fixed
- `_install_rwpaths_dropin()` no longer relies on dynamic scope to inherit
  `SERVICES`/`TIMERS` from `run_phase_systemd()`; unit list is now self-contained
  (`Bug A` fix).
- `remove_units()` now cleans up per-unit `.d/` drop-in directories on
  `setup.sh systemd remove`.
- `uninstall-vaultwarden.sh` now removes the Docker mount guard drop-in
  (`10-vaultwarden-data-volume.conf`) so Docker is not left in a broken state
  after uninstall on separate-volume hosts.
- `BACKUP_DIR` default now derives from `PROJECT_STATE_DIR`, not a hardcoded
  `/var/lib/vaultwarden` path, in both `setup.sh` and `restore.sh`.

## [1.0.0] — 2026-03-26

### Added
- **`.gitignore`** — prevents accidental commits of `.env`, `secrets/`,
  `backups/`, `*.age` keys, `docker-compose.yml`, and editor noise.
- **`VERSION`** file — single source of truth for the stack version,
  read by `make version` and `make info`.
- **`CHANGELOG.md`** — this file; tracks all notable changes.
- **`make logs-fail2ban`** — mirrors the existing `logs-vaultwarden`,
  `logs-caddy`, and `logs-postfix` targets for the Fail2ban service.
- **`make diagnose`** — one-command debug dump: Docker/Compose versions,
  age key status, disk usage, container state, and last 20 log lines
  per service. Replaces ad-hoc debugging sessions.
- **`make backup-status`** — shows last backup time per type, total
  backup directory size, retention window, and count of retained archives.
- **`make lint`** — runs `shellcheck` over all `*.sh` scripts when
  available, catches unquoted variables and other common shell pitfalls.
- **`make version`** — now also displays the stack script version from
  the `VERSION` file.
- **`make info`** — now also shows backup directory size, retention
  window (`BACKUP_RETENTION_DAYS` from `.env`), and script version.
- **`make backup` TYPE default warning** — emits a visible notice when
  `TYPE=` is not specified so operators know `db` was used by default.
- **`make watch`** — now uses `health-quick` instead of full `health`
  so the 5-second poll does not hammer the VaultWarden HTTPS endpoint.
- **`make shell` service hint** — prints which container you are entering
  before `exec sh` to reduce accidental wrong-container edits.
- **`restore.sh`** — full rework of the restore flow:
  - Step 2: interactive age decryption key prompt (silent echo).
  - Priority order: `--key-file` flag → `RESTORE_AGE_KEY_FILE` env var
    → interactive prompt → blank-Enter fallback to `SOPS_AGE_KEY_FILE`.
  - Pre-restore key validated with live encrypt/decrypt round-trip.
  - Step 10: post-restore automatic age key generation and rotation to
    all configured locations (`secrets/keys/age-key.txt`,
    `/etc/vaultwarden/age-key.txt`, `.env`, `vaultwarden.env`).
  - Step 11: new key displayed in prominent banner (same style as
    `setup.sh` fresh install); operator must type `SAVED` (all caps) to confirm.
  - Key rotation failure is non-fatal — services start regardless.
  - `--key-file <path>` CLI flag for non-interactive / scripted restores.
  - `RESTORE_AGE_KEY_FILE` env var for CI pipeline use.

### Changed
- **`make watch`** polls with `health-quick` (fast port + container check)
  instead of full `health` (deep endpoint + DB + Fail2ban probes).
- **`docs/BACKUP-RESTORE.md`** — updated restore flow table to 12 steps;
  added _Supplying the Decryption Key_ section; added _Post-Restore Key
  Rotation_ section with banner example and escrow reminder.

### Fixed
- **`make key-rotate`** (`MAKE-KR1`) — invoked `source` inside
  `/bin/sh` (dash); `source` is not a dash builtin so `rotate_age_key`
  never executed. Fixed by invoking `bash` explicitly.
- **`make key-rotate`** (`MAKE-KR2`) — added `key-health` pre-flight so
  a corrupt key is caught before any write occurs.
- **`update.sh`** (`UPDATE-1`) — `lib/simple_key_resilience.sh` was
  never sourced; age key health is now checked before update operations.
- **`update.sh`** (`BUG-EP1`) — `caddy/entrypoint.sh` execute bit is
  now enforced before `docker compose up`, mirroring `startup.sh`.
- **`Makefile`** (`P5-L1`) — inverted root check: `sudo make setup`
  works; direct root login is rejected.
- **`Makefile`** (`P5-H1`) — `up`/`restart` invoke `sudo ./startup.sh`
  so `require_root` passes correctly.
- **`Makefile`** (`P5-H2`) — `dry-run` no longer appends `|| true`;
  failures propagate correctly.
- **`Makefile`** (`P5-H3`) — `clean-all` and `uninstall` abort in
  non-interactive (piped/CI) context.
- **`Makefile`** (`P5-C1`) — `safe-restart` captures pre-restart
  container IDs and rolls back on health-check failure.
- **`Makefile`** (`P5-M1`) — `logs` defaults to `--tail=100`.
- **`Makefile`** (`P5-M2`) — `test-secrets` propagates failure exit code.
- **`Makefile`** (`P5-M3`) — `watch` passes Makefile variables into
  subprocess environment.
- **`Makefile`** (`P5-M4`) — `backup` always passes `--email` for
  systemd timer invocations.
- **`Makefile`** (`P5-M5`) — anchored `grep` prevents multi-line
  leakage in `info` and `config` targets.
- **`Makefile`** (`P5-L2`) — `version` non-running container is
  non-fatal informational state.
- **`Makefile`** (item 4) — `restore-db` no longer passes `--force`
  so the age key prompt and confirmation step run as intended.
- **`Makefile`** (item 14) — `info` now shows age key status.
- **`Makefile`** (item 15) — `config` shows truncation notice when
  `.env` has more than 15 non-sensitive lines.

---

## [Unreleased]

> Place entries here during development; move to a versioned section on release.

### Added
- **`caddy/Caddyfile`** — Caddy 2.11 compliance: `encode zstd gzip` on main site
  block; `roll_compression zstd` in all three log blocks; connection timeouts merged
  into global `servers` block; `request_body` size limits on admin and auth handlers;
  health-check log suppression (`output discard`). *(Phase 2)*
- **`caddy/entrypoint.sh`** — FQDN validation for `DOMAIN_NAME` at startup; Caddy
  version logged on container start. *(Phase 2)*

### Changed
- **`.env.example`** — sentinel tokens for all external credentials; `LOG_LEVEL=warn`
  default; `PUSH_ENABLED=false`; Mailgun EU region note; backup retention comment.
  *(Phase 3)*
- **`.env.example`** (`STARTUP-14`) — updated `SOPS_AGE_KEY_FILE` comment block
  (`WHAT HAPPENS IF THE PATHS DISAGREE`) to document the auto-recovery behaviour
  introduced in STARTUP-14: startup.sh no longer exits with an error when the
  configured key path is absent but `secrets/keys/age-key.txt` is healthy; it
  auto-recovers for the current boot and prints an ACTION REQUIRED advisory.
  Updated item 14 in TEMPLATE REPLACEMENT NOTES accordingly.
- **`docker-compose.yml.example`** — `read_only` filesystem; `tmpfs` mounts; `ulimits`
  (nofile); image-pin comment; `restart: unless-stopped`; `no-new-privileges:true`;
  Caddy log rotation tightened. *(Phase 3)*
- **`docker-compose.override.yml.example`** — dev-only warning banner; no plaintext
  secrets. *(Phase 3)*
- **Caddy minimum version** bumped to `2.11.2` (fixes TLS ACME renewal regression
  introduced in 2.11.1). *(Phase 4/5)*

### Fixed
- **`restore.sh`** — `restore_db()` now checks `DRY_RUN` before overwriting the live
  database file, matching the dry-run guards already present for full/emergency
  restores. *(Phase 4 — P4-S1)*
- **`health.sh`** — `check_configuration()` now checks for `DOMAIN_NAME` (the
  canonical env var) instead of `DOMAIN` when validating `.env` required fields.
  *(Phase 4 — P4-S2)*
- **`startup.sh`** — post-startup health check now re-runs `./health.sh` (verbose)
  when `./health.sh --quiet` exits non-zero, ensuring full diagnostics reach the
  operator instead of being silently swallowed. *(Phase 4 — P4-S5)*
- **`setup.sh`** — post-install checklist now displays `CLEAN_DOMAIN` (the bare
  domain written to `.env` as `DOMAIN_NAME`) instead of the `DOMAIN` variable
  which may include the `https://` protocol prefix. *(Phase 4 — P4-S6)*
- **`create-breakglass-admin.sh`** — added `trap 'rm -f "${_BG_LOCK_FILE:-}"' EXIT`
  guard so the operations lock file is always cleaned up on any exit path.
  *(Phase 4 — P4-S7)*
- **`setup-systemd.sh`** — `--install` now validates all `OnCalendar=` expressions
  via `systemd-analyze calendar` before enabling timers and warns on invalid
  expressions. *(Phase 5 — P5-SD1)*
- **`systemd/*.service`** — added `[Install]` section (`WantedBy=multi-user.target`) to all
  generated service unit files so `systemctl enable` is no longer a no-op.
  *(Phase 5 — P5-SD2)*
- **`startup.sh`** (`STARTUP-8`) — `wait_for_services()` was called with bare service
  names (`vaultwarden`, `caddy`) but `docker inspect` requires the full container name
  set in `docker-compose.yml`. `docker inspect` on an unknown name exits 1 and returns
  empty strings for health/running status, causing the polling loop to run for the full
  90 s timeout on every startup before emitting misleading WARN messages despite the
  stack being healthy. Fix: resolve container ID via `docker compose ps -q <service>`
  so the lookup is correct regardless of `COMPOSE_PROJECT_NAME`.
- **`startup.sh`** (`STARTUP-9`) — plaintext `EMAIL_API_TOKEN` or `SMTP_PASSWORD`
  values in `.env` silently overrode the SOPS-managed workflow: `send_email()` preferred
  `EMAIL_API_TOKEN` from the environment before decrypting from `secrets.yaml`, and
  `_smtp_send()` switched to direct external SMTP whenever `SMTP_PASSWORD` was non-empty.
  Fix: startup guard inspects the loaded environment after SOPS secrets are prepared and
  emits loud warnings when these plaintext overrides are detected.
- **`startup.sh`** (`STARTUP-10`) — `run_health_check()` treated `health.sh` exit 1
  (warnings) and exit 2 (critical failures) identically — both fell through to a single
  `log_warn`, giving operators a false green signal on a critically unhealthy stack.
  Fix: capture the exit code explicitly and map: exit 0 → log_success, exit 1 →
  log_warn (startup continues), exit 2 → log_error + abort. Matches the documented
  exit-code contract in `health.sh --help`.
- **`startup.sh`** (`STARTUP-11`) — `prepare_docker_secrets()` Python heredoc opened
  `secrets.yaml` with a hardcoded relative path, ignoring the `SECRETS_FILE` variable
  defined in `lib/secrets.sh`. Fix: pass `"$SECRETS_FILE"` as `sys.argv[1]` so the path
  is always explicit and consistent with the rest of the secrets subsystem.
- **`startup.sh`** (`STARTUP-12`) — `pull_images()` ran unconditionally on every
  startup, including the systemd `ExecStart` path, adding 30–120 s to every restart on
  metered or slow OCI connections. Fix: add `--skip-pull` flag (`SKIP_PULL=false`
  default). Documented in `show_help()`. systemd operators should pass `--skip-pull`;
  `update.sh` and manual `./startup.sh` remain the intended pull path.
- **`startup.sh`** (`STARTUP-13`) — **HIGH** — `prepare_docker_secrets()` Python heredoc
  was passed `"$secrets_file"` (the SOPS-encrypted source) as `sys.argv[1]` instead of
  `"$cache_file"` (the decrypted output of `sops -d`). `yaml.safe_load()` parsed the
  `ENC[AES256_GCM,…]` ciphertext strings as plain YAML and wrote them verbatim to
  every file under `secrets/.docker_secrets/`. All Docker secret files contained raw
  SOPS ciphertext rather than the actual decrypted token values. Fix: pass `"$cache_file"`
  to the Python snippet so it reads the plaintext YAML that `sops -d` already wrote.
- **`startup.sh`** (`STARTUP-14`) — **HIGH** — `check_age_key_health_preflight()`
  aborted startup unconditionally when `SOPS_AGE_KEY_FILE` pointed at a non-existent
  path (e.g. `/etc/vaultwarden/age-key.txt` not yet installed) even when the repo-local
  key (`secrets/keys/age-key.txt`) was present and healthy. This blocked `make up` on
  hosts where `setup.sh` placed the key under `secrets/keys/` but `.env` still
  referenced the canonical system path — a common state after a fresh clone or
  migration. `utilities/secrets-edit.sh` and `make test-secrets` succeeded on the same host
  because they locate the key differently. Fix: if the configured path is absent but
  the repo-local key passes `check_age_key_health()`, export
  `SOPS_AGE_KEY_FILE=secrets/keys/age-key.txt` for the lifetime of the current process
  only and continue startup, while emitting a prominent ACTION REQUIRED advisory (logged
  at WARN level and repeated at the end of startup) instructing the operator to install
  the key to `/etc/vaultwarden/age-key.txt` or update `.env` before the next restart.

---

[1.0.0]: https://github.com/killer23d/VaultWarden-OCI/releases/tag/v1.0.0
[Unreleased]: https://github.com/killer23d/VaultWarden-OCI/compare/v1.0.0...HEAD
