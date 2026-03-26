# Changelog

All notable changes to VaultWarden-OCI are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

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
    `setup.sh` fresh install); operator must press Enter to confirm.
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

---

[1.0.0]: https://github.com/killer23d/VaultWarden-OCI/releases/tag/v1.0.0
[Unreleased]: https://github.com/killer23d/VaultWarden-OCI/compare/v1.0.0...HEAD
