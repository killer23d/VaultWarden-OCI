# Changelog

All notable changes to VaultWarden-OCI are documented in this file.
This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---
## [Unreleased]

- Add `utilities/env-edit.sh` as the owned environment workflow for non-interactive sync, interactive repo `.env` edits, and read-only status reporting.
- Add `make edit-env` and keep `make sync-env`/startup paths syncing generated runtime env artifacts before service starts.
- Make env sync fail closed when configured data-volume storage is missing, mismatched, unmounted, or blocked by an incomplete migration state.

- Add resilient persistent state and disaster recovery: authoritative state-volume `install.env`, persistent SOPS ciphertext, transient `/run` Docker secret files, operational plus offline Age recipients, standalone recovery, and a printable recovery card.


_(No unreleased changes yet — add entries here as work is merged.)_

---
## [1.0.0] — 2026-03-26

---

## [Unreleased]

### Added
- `log_phase` progress bar in `lib/log.sh`; `setup.sh` now calls it for all 6
  install phases so operators can track progress during the 3–8 minute install
  (ux.md #1)
- `spinner_start` / `spinner_stop` in `lib/log.sh`; `lib/common.sh`
  `download_file()` wraps both `curl` and `wget` attempts with a live spinner
  (ux.md #2)
- Dashboard live-stats forced to redraw after `Start` (option 1) and `Stop`
  (option 2) so container state is never stale on the next render (ux.md #3)
- `TZ_DISPLAY` in `dashboard.sh` now reads the `TZ` key from `.env` (fallback
  `UTC`) instead of being hardcoded to `America/Vancouver` (ux.md #4)
- Post-install summary in `setup.sh` split into two clear screens: critical
  credentials first (with a mandatory Enter gate), next-steps second; uses the
  shared `press_enter_to_continue` helper (ux.md #5, #10)
- `_confirm_destructive()` in `dashboard.sh`; `Stop Stack` (option 2) and
  `Prune Docker Resources` (option 6) now require explicit `y` confirmation
  before executing (ux.md #6)
- Destructive menu items color-coded: `Stop Stack` → red, `Prune` → yellow,
  `Uninstall` → red across all dashboard menus (ux.md #7)
- `log_header()` in `lib/log.sh` uses `wc -m` for multibyte-safe underline
  length so emoji headers no longer render with a short underline (ux.md #8)
- `_log_dry_prefix()` in `lib/log.sh`; all log functions prepend a blue
  `[DRY RUN]` tag when `DRY_RUN=true` (ux.md #9)
- `press_enter_to_continue()` added to `lib/common.sh`; all bare `read -r`
  prompts in `setup.sh` replaced with this shared helper (ux.md #10)
- `--version` / `-V` flag added to `setup.sh`; `draw_header()` in
  `dashboard.sh` now shows `v<VERSION>` from the `VERSION` file (ux.md #11)
- `draw_live_stats()` backup result now uses `grep -oE` to extract only the
  keyword (PASS/FAIL/ERROR/SUCCESS) and color-codes it green/red/yellow;
  prevents raw log lines from overflowing narrow terminals (ux.md #12)
- Per-check timing shim (`_timed_check`) in `smoke-test.sh`; checks taking
  over 2 s emit a `log_warn` with elapsed milliseconds (ux.md #13)
- `log_hint()` added to `lib/log.sh` with a blue `HINT →` prefix; used in
  `restore-run.sh` for decryption-failure guidance and in `lib/common.sh`
  `require_root()` (ux.md #14)
- `Makefile` `setup:` target now validates that `DOMAIN` and `ADMIN_EMAIL`
  in `.env` are not still placeholder values before calling `setup.sh`
  (ux.md #15)
- Dashboard unban-IP prompt validates input with `validate_ip()` from
  `lib/validate.sh` before passing to `cscli` (ux.md #16)
- `_warn_force_destructive()` in `setup.sh` prints a prominent Unicode box
  warning when `--force` is used; requires typed `YES` confirmation (ux.md #17)
- `_get_timestamp()` in `lib/log.sh` emits `HH:MM:SS` on TTY and
  `YYYY-MM-DDTHH:MM:SS±TZ` when output is a file/pipe, unambiguous for
  overnight runs (ux.md #18)
- `maintenance.sh` top-level `show_help` normalised; `help|--help|-h` routes
  to `show_help; exit 0` rather than recursive `exec "$0"` (ux.md #19)
- Dashboard main event loop uses `read -r -t 60`; on timeout the screen
  redraws live stats automatically without user input (ux.md #20)
- Cloudflare secrets commands in `show_post_install_summary()` deduplicated
  into a single `_cf_cmds` variable; no longer printed twice (ux.md #21)
- `validate_email()` in `lib/validate.sh` rewritten to enforce RFC 5321
  length limits (254 total, 64 local-part, 253 domain), reject leading/
  trailing dots, and support modern long TLDs (ux.md #22)
- `_secrets_health()` in `dashboard.sh` scans `.env` for `CHANGE_ME` /
  `CHANGEME` placeholder values and surfaces a color-coded `Secrets health`
  line in the live-stats header (ux.md #23)
- `_log_backup_size()` in `utilities/backup-run.sh` reports human-readable
  file size after every backup and warns when the result is suspiciously
  small (< 4 KB) (ux.md #24)
- `_print_drill_summary()` in `utilities/pre-production-drill.sh` rewritten
  with color-aware pass/fail/skip counts and a bulleted failed-step list
  (ux.md #25)
- `wait_for_entropy()` added to `lib/common.sh`; `setup.sh` calls it before
  the secrets phase and shows a live countdown when entropy is low (ux.md #34)
- `require_root()` in `lib/common.sh` uses `log_hint` for the re-run-with-
  sudo message instead of `log_error` (ux.md #42)
- `restore-run.sh` calls `list_backups` before the restore-file prompt so
  operators see available backups before being asked to choose (ux.md #31)
- Per-tool install hints added to `restore-run.sh` dependency checks; each
  missing tool prints the appropriate `apt install` / `snap install` command
  (ux.md #46)
- `_container_uptime()` added to `dashboard.sh`; the `Stack` live-stats line
  shows `(up Xd Yh)` when VaultWarden is running (ux.md #47)
- `lib/config.sh` accumulates all malformed `.env` lines and reports them
  together rather than failing on the first (ux.md #48)
- `utilities/pre-production-drill.sh` summary shows elapsed wall-clock time
  (ux.md #49)
- `--json` output added to `backup.sh list` and `maintenance health` for
  machine-readable consumption by monitoring tools (ux.md #50)
- `retry_with_backoff()` in `lib/common.sh` shows a live countdown on TTY
  between retry attempts (ux.md #32)
- Dashboard option 4 (View App Logs) wraps the `docker logs --follow` tail
  in a subshell with `trap 'exit 0' INT` so Ctrl-C returns to the menu
  rather than exiting the dashboard entirely (ux.md #33)
- `dashboard.sh` sources `lib/validate.sh` at startup for the unban-IP
  validation path (ux.md #16)
- `dashboard.sh` `--help` / `-h` flag added (ux.md #11)
- `edit-secrets.sh` help text normalised to match project-wide style
- `utilities/maintenance-run.sh` uses `log_phase` for all maintenance phases
- `setup-env.sh` calls `validate_domain` guard before writing `.env`
- `secrets-rotate.sh` shows a 12-char SHA-256 fingerprint preview of old and
  new values (never the value itself) and prompts for confirmation on TTY
- `lib/email.sh` rate-limit hit upgraded from `log_debug` to `log_warn`;
  `_rate_limit_reset_message()` shows when the window resets
- Makefile `help:` target lists dangerous/state-changing targets in a
  separate coloured footer block
- `uninstall-vaultwarden.sh` now sources `lib/log.sh` (with inline fallback
  stubs) for consistent log output
- `smoke-test.sh` `check_docker_secrets_materialized` expanded to cover all
  compose-defined secrets and detect `CHANGE_ME` placeholders
- `_phase_failed()` helper in `setup.sh` centralises per-phase error
  messaging with actionable `log_hint` guidance

### Changed
- `lib/log.sh` TTY color guard wraps all `COLOR_*` assignments (no-op in
  non-interactive/pipe contexts)
- Dashboard TZ label in `_epoch_to_pt()` and `draw_header()` changed from
  hardcoded `PT` to `%Z` (reads actual timezone abbreviation)
- `list_backups()` output reformatted with a `TYPE / FILE / SIZE / MODIFIED`
  column header for clarity
- `draw_main_menu()` submenu entries annotated with option counts
- Advanced menu option 6 (Prune) label changed from green to yellow to
  reflect caution level

### Fixed
- `pre-production-drill.sh` used `$SOPS_AGE_KEY_FILE` where the health-check
  helper expects `$AGE_KEY_FILE`; variable name corrected
- `pre-production-drill.sh` `tar` extraction used GNU-only `-I` flag;
  replaced with portable `--use-compress-program='zstd -d -T0'`
- `pre-production-drill.sh` `grep` called with a regex string as a literal
  match; changed to `grep -qF`
- `smoke-test.sh` `expiry_seconds` variable renamed `expiry_date_str` to
  match the value it actually holds
- `smoke-test.sh` `trap - EXIT` added in `--fail-fast` path to prevent
  double-printing the summary

---

## [1.0.0] — 2026-03-26

### Added
- Initial public release of VaultWarden-OCI
- Docker Compose stack: VaultWarden + Caddy + Postfix
- SOPS + Age encryption for secrets at rest
- Automated backup system (incremental DB + full)
- CrowdSec integration with Cloudflare Worker bouncer
- Systemd timer units for backup and maintenance
- Interactive `setup.sh` install wizard
- `dashboard.sh` AMTM-style operations menu
- `smoke-test.sh` post-install verification
- `pre-production-drill.sh` go-live readiness checker
- `restore-run.sh` interactive disaster-recovery tool
- `edit-secrets.sh` SOPS-backed secrets management CLI

[1.0.0]: https://github.com/killer23d/VaultWarden-OCI/releases/tag/v1.0.0
[Unreleased]: https://github.com/killer23d/VaultWarden-OCI/compare/v1.0.0...HEAD
