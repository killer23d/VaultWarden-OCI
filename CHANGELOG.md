# Changelog

All notable changes to VaultWarden-OCI are documented in this file.
This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added

- Added bounded quick, standard, and comprehensive health profiles. Quick health reuses one local Compose snapshot and intentionally omits external/network/configuration-audit/report checks.
- Added process-local dashboard snapshot reuse for Compose state, batched container inspection, and one backup-tree pass per redraw without a persistent cache, background collector, daemon, database, or extra timer.
- Added resilient persistent-state and disaster-recovery workflows built around the authoritative state-volume `install.env`, persistent SOPS ciphertext, transient `/run/vaultwarden-oci/secrets` material, operational and optional offline Age recipients, standalone `recover.sh`, and a printable recovery card.
- Added a three-tier backup model for `db`, `full`, and `emergency` backups. Backup creation now stages and verifies consistent SQLite snapshots, records snapshot/encryption metadata, and keeps live database/WAL files and transient runtime secrets out of full archives.
- Added independently protected emergency recovery material and an SMTP-only encrypted recovery-kit attachment workflow using a user-selected passphrase with a minimum-length and confirmation contract.
- Added a repository-wide operation guard for long-running and mutating workflows, with verified runtime ownership metadata, inherited foreground lock support, operation-specific locks where needed, safe contention handling, and `sudo make operations` for operator inspection.
- Added focused storage setup guidance for attached block storage while preserving fail-closed mount-marker, migration, and device-safety checks.
- Added schema-owned secret `apply` metadata so runtime secret reconciliation and downstream configuration actions are driven by validated schema contracts rather than loose service-name metadata.
- Added a canonical CrowdSec Cloudflare Workers configuration apply helper and an explicit timed `yes`/`no` prompt after relevant secrets edits so operators can immediately re-render and verify the installed bouncer configuration.
- Added machine-readable JSON output for backup listing and maintenance health status.
- Added `utilities/crowdsec-email.sh` as a transaction-safe root-operated controller for enabling, disabling, inspecting, and testing the optional CrowdSec security-event email integration.
- Added root-operated Postfix queue summary, inspection, targeted retry/deletion, bounded log filtering, and confirmation-gated snapshot purge workflows across the utility, Makefile, dashboard, tests, and operator documentation.
- Hardened snapshot purge against Postfix queue-ID reuse with stable identity verification, a host mutation lock, hold/release rollback, fixed-count queue inventories, exact-ID batching, and long queue IDs as defence in depth.
- Closed the targeted-delete confirmation race by holding the selected queue ID, revalidating its stable identity, preserving reused IDs, and rolling back only newly introduced holds after failures or handled signals.
- Made effective `enable_long_queue_ids=yes` a fail-closed prerequisite for targeted deletion and snapshot purge; legitimate duplicate queue-list records are now normalized safely while conflicting identities block mutation.

### Changed

- Scheduled daily maintenance now runs the routine path with email reporting; DNS and firewall reconciliation remain owned by their dedicated timers. Routine SQLite work stays online with `PRAGMA optimize` and passive WAL checkpointing, while the separate deep database-maintenance workflow owns backup, integrity checks, service stop/start, and `VACUUM`.
- Backup retention now uses one precedence chain: explicit nonempty `--keep`, matching `BACKUP_RETENTION_*_DAYS`, shared `BACKUP_RETENTION_DAYS`, then the per-tier fallback. A missing remote tier may be empty, but an actual remote listing failure skips pruning for that tier and makes a requested rotate/prune operation fail.
- Ordinary database/full backup payloads now stage on the configured backup filesystem with small control material isolated separately; emergency plaintext remains on verified, capacity-checked tmpfs. Full verification streams decryption into archive inspection instead of creating another plaintext full archive.
- Restore now separates sensitive control material from large target-filesystem payload staging, validates and checks initial capacity before service stop, repeats required capacity checks after the pre-restore snapshot, and cleans only invocation-owned workspaces.
- Documentation/development validation now covers changes under `crowdsec/**`, `VERSION`, and the development override; setup uses `docker-compose.override.dev.yml.example`, and CI validates production Compose both alone and merged with the development override. External actions remain immutably pinned.
- DB backup, full backup, and routine maintenance services now use soft process/I/O scheduling priority (`Nice=10`, best-effort I/O, priority `7`) without imposing hard resource quotas.
- Compose cleanup removed only inactive CPU reservation declarations. Active standalone memory/swap, CPU, PID, memory-reservation, and security controls remain intact.
- Prevented Docker/Compose children from inheriting the email-queue mutation lock, reported post-delete queue-ID reuse accurately, and aligned invalid email-diagnostic options with exit status 2.
- Replaced deprecated Python `crypt` verification with the Ubuntu `python3-bcrypt` package, including normal setup installation and explicit dependency checks even with `--skip-deps`.
- Recovery-kit export now accepts a 30-minute systemd transient cleanup timer before email, uses `at` only as an optional fallback, fails closed when scheduling is unavailable, and removes the local plaintext copy immediately after successful encrypted delivery.
- Standardized the supported production-host contract on Ubuntu 24.04 LTS Noble for `amd64` and `arm64`, with Cloudflare as the mandatory edge and a root-operated lifecycle/maintenance model.
- Normal setup now owns and verifies production dependencies required by supported workflows, including exact repository-pinned SOPS and Mike Farah `yq` contracts and the `zstd`, GnuPG, tar, and related backup/recovery tooling used by production paths.
- Lifecycle, secrets mutation, environment configuration, systemd installation/removal, storage migration, restore, backup, maintenance, firewall, CrowdSec, key rotation, permission repair, update, and uninstall mutation paths now coordinate through the shared operation guard where appropriate.
- Scheduled backup and maintenance services now treat expected operation contention as a clean exit `75` skip while preserving real failures; managed calendar timers no longer perform boot/install catch-up bursts and non-interactive systemd installation defaults to a manual start policy.
- Backup retention now preserves the newest parseable timestamped recovery point and its sidecars regardless of age, fails safe around unparseable archive names, and uses the same canonical retention selection for local, remote, and dry-run reporting paths.
- Rclone configuration resolution now narrowly accepts the canonical root fallback at `/root/.config/rclone/rclone.conf` only when the resolved file satisfies the required ownership and permission checks.
- Restore and recovery flows now use bounded prompts, staged and validated Age keys, explicit restore plans, pre-destructive confirmation, database integrity gates before automatic restart, configurable health waits, and truthful post-restore/recovery status messaging.
- Operator CLI contracts were normalized across public scripts: metadata paths are root-free where appropriate, unsupported option combinations and trailing arguments fail clearly, missing option values are checked before shifting, and explicit CLI values take precedence over loaded storage/migration defaults.
- `setup-storage.sh` now requires the explicit canonical `setup`, `verify`, or `migrate` subcommand; migration parsing and runtime-derived argument resolution are separately owned and explicit CLI options win over environment defaults.
- Secrets runtime export now reconciles schema-managed files, revokes stale or inactive schema-managed runtime secret files, and preserves operator-owned files outside the schema contract.
- The operator `Makefile` was simplified by removing redundant developer test/lint wrappers. `./tests/run-tests.sh all` is the canonical permanent regression entry point.
- Permanent regression cases were organized under four public domain suites and now execute directly at their registered `tests/suites/<suite>/case-*.bash` paths without creating compatibility links in the checkout.
- Generated operator command-reference capture was expanded and kept deterministic so long help output, including systemd installation/validation and recovery commands, is not silently truncated.
- Documentation and operator prompts were aligned with the root-operated model, the three backup tiers, offline Age recipient custody, recovery-kit terminology, restore start policies, and supported systemd workflows.

### Fixed

- Corrected the systemd health contract: the five-minute service runs `health --quick --fix`, treats only `0`, `1`, and `75` as successful, and reports exits `2`, `3`, and `4` as real failures. Exit `3` is a critical prerequisite/execution failure, not a new-install success state.
- Routine maintenance now treats health status `1` as successful completion with warnings and `75` as a visible successful skip while preserving genuine health failures as maintenance failures.
- Fixed operation-lock lifetime so one owner-bound holder owns the global and operation-specific descriptors and releases both when the guarded shell exits, even if an arbitrary workload child remains alive.
- Fixed gaps where startup/restart/down, safe restart, secrets mutation, environment setup/edit/sync, and systemd configuration could mutate state outside the shared operation guard.
- Fixed systemd runtime-path and installed-utility contracts, including the structured firewall utility path and operation-state runtime directory ownership.
- Fixed systemd state-directory drop-in rendering so service-only directives are not written into timer drop-ins; systemd regression coverage now verifies generated units with `systemd-analyze verify` when available.
- Fixed maintenance backup dry-run reporting to delegate to the canonical retention preview instead of maintaining a separate candidate-selection contract.
- Fixed DNS/firewall contention propagation and aggregate maintenance handling so clean skips remain skips, real nonzero failures remain failures, and Bash `set -e` does not abort on the first counter increment.
- Fixed backup dry-run contradictions and local/remote retention selection so reported deletion candidates match the canonical retention behavior.
- Fixed uninstall/test-reset cleanup gaps: data-volume mount guards fail closed before mutation, UFW cleanup is limited to managed/historical VaultWarden rules, ambiguous normal-uninstall swap/SOPS state is preserved, and explicit test reset handles disposable `/swapfile` cleanup.
- Fixed restore confirmation timeout/EOF handling so automatic startup is blocked when required Age key custody acknowledgement is incomplete and generated key material is preserved for manual recovery.
- Fixed recovery and deep database maintenance status output that could previously report success after health checks failed.
- Fixed CrowdSec Workers secret edits that could leave the installed bouncer configuration stale without an explicit operator apply path.
- Fixed Postfix startup compatibility by removing the upstream-incompatible read-only root filesystem setting while retaining compatible container hardening controls.
- Fixed dependency ownership gaps for supported backup paths, including normal setup ownership and verification of `zstd`.
- Fixed CrowdSec notification reconciliation to validate sender-domain policy, reject duplicate/unmanaged notification references, normalize managed-file metadata, escape dynamic HTML fields, and preserve operator-owned profile content.
- Removed operation-lock descriptor lifecycle knowledge from CrowdSec validation, the shared spinner, and external bouncer execution because workload processes no longer own or inherit those descriptors.
- Fixed hardened systemd maintenance services so UFW and optional CrowdSec validation receive only the required writable paths while real firewall-update failures still propagate.
- Fixed state-volume recovery so it acquires the shared operation guard before creating or promoting recovery artifacts and returns exit `75` without mutation when another operation owns the guard.
- Fixed destructive setup acknowledgement, root-remediation command hints, read-only dashboard environment inspection, and lazy Docker project-label resolution so public operator paths remain executable and truthful.

### Security

- Emergency backup plaintext that can contain operational private-key material now remains on verified, capacity-checked tmpfs and fails with capacity guidance instead of silently falling back to persistent plaintext staging.
- Restore now keeps small sensitive control material in a restrictive control workspace and large decrypted payloads on the target filesystem, checks capacity before the destructive boundary, and retains staging only for genuine manual rollback/recovery with a clear sensitive-material warning.
- Corrected sensitive-file cleanup language to describe best-effort overwrite/unlink without claiming guaranteed physical erasure on SSD, snapshot, journaling, or copy-on-write storage.
- Hardened recovery-kit attachment protection so the passphrase is validated, held only for the required shell operation with tracing disabled, passed to the encryption tool through a file descriptor, and kept out of argv, environment variables, temporary passphrase files, and logs.
- Hardened secret and Age-key custody around root-owned persistent configuration and transient runtime secret material; runtime secrets are materialized under `/run/vaultwarden-oci/secrets` for container consumption rather than treated as persistent plaintext state.
- Hardened operation-owner attribution and stop behavior with explicit global ownership metadata, owner/holder PID-start verification, open-lock-inode validation, controlled descendant signalling, and refusal to automatically terminate or bypass active apt/dpkg/repository package work.
- Hardened data-volume, restore, and uninstall paths to fail closed when mount identity, migration state, archive requirements, or database integrity cannot be safely established.
- Hardened backup encryption/verification metadata and emergency backup policy so archives containing operational key material cannot rely solely on that same operational Age recipient for protection.

---

## [1.0.0] — 2026-03-26

### Added

- Initial public release of VaultWarden-OCI.
- Docker Compose stack: VaultWarden, Caddy, and Postfix.
- SOPS and Age encryption for secrets at rest.
- Automated backup system with database and full backups.
- CrowdSec integration with the Cloudflare Worker bouncer.
- Systemd timer units for backup and maintenance.
- Interactive `setup.sh` install wizard.
- `dashboard.sh` operations menu.
- `smoke-test.sh` post-install verification.
- `pre-production-drill.sh` go-live readiness checker.
- `restore-run.sh` interactive disaster-recovery tool.
- `edit-secrets.sh` SOPS-backed secrets management CLI.
[1.0.0]: https://github.com/killer23d/VaultWarden-OCI/releases/tag/v1.0.0
[Unreleased]: https://github.com/killer23d/VaultWarden-OCI/compare/v1.0.0...HEAD
