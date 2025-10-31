# SCRIPTS

This reference documents the core scripts, their responsibilities, inputs/outputs, and typical operator flows in a small-scale, single-admin environment.

## Overview
- Philosophy: small, predictable, idempotent scripts; minimal prompts; clear logs; safe defaults.
- Shared libraries in lib/: common.sh (logging, env, fs), docker.sh (compose helpers), crypto.sh (Age/SOPS helpers), backup_utils.sh.
- Use Makefile or direct script calls; both are supported.

## setup.sh
Purpose:
- One-time system setup with template-based configuration and UFW hardening.
Key actions:
- Installs dependencies (Docker, compose plugin, sops, age, jq, sqlite3, ufw, etc.).
- Copies .env.example → .env and docker-compose.yml.example → docker-compose.yml; populates values.
- Generates Age keys; creates SOPS config and encrypted secrets template.
- Validates docker-compose; configures UFW with Cloudflare IP ranges and safe warnings on failure.
Inputs:
- --domain, --email; flags: --auto, --use-latest, --skip-deps, --force, --dry-run.
Outputs:
- Generated configuration, keys, and secrets; firewall state; logs to console.

## startup.sh
Purpose:
- Orchestrate up/down/restart flows with health checks and optional DNS update.
Highlights:
- Prepares Docker secrets from encrypted vault, fixes ownership, sets state dirs.
- Start vs force-recreate logic; post-start health checks with backoff.
- DNS update moved after health to avoid race conditions.
Inputs:
- Flags: --force-restart, --down, --dry-run, --skip-health, --strict-secrets, --skip-dns.
Outputs:
- Service state changed; detailed health output; logs to console.

## edit-secrets.sh
Purpose:
- Safely edit encrypted secrets via SOPS, validate structure, and produce Docker secret files at runtime.
Notes:
- Uses SOPS with Age; never commit decrypted secrets.
- Validates placeholders (e.g., CHANGE_ME_) and warns in strict mode.

## backup.sh
Purpose:
- Create encrypted backups (db, full, emergency) with pre-encryption checks and atomic writes.
Highlights:
- WAL checkpoint + .backup; PRAGMA quick_check; atomic staging file.
- Optional rclone sync of .age, .sha256, .meta.
Inputs:
- --type db|full|emergency, --rclone, --email, --list, --dry-run.
Outputs:
- Encrypted artifacts under backups/; metadata + checksums.

## restore.sh
Purpose:
- Interactive restore or direct file restore with validate-only mode.
Flows:
- List backups → select → decrypt → verify → stop services → restore → start → health.

## update.sh
Purpose:
- Pull and apply container updates with safety steps.
Flows:
- backup-full → docker compose pull → restart → health.
Optional:
- --system-only for OS packages; otherwise containers by default.

## health.sh
Purpose:
- Deep health diagnostics with auto-healing.
Checks:
- Container health & restarts; HTTP reachability; TLS; firewall; backups; disk space; versions.
Outputs:
- Human-readable summary and machine-friendly exit codes.

## maintenance.sh
Purpose:
- Routine cleanup and optimization.
Tasks:
- Log rotation, old artifact cleanup per retention, sqlite optimize, vacuum; disk usage reporting.

## cron-setup.sh
Purpose:
- Install/remove cron jobs for automation.
Defaults:
- Daily db backup, weekly full backup, weekly container update, monthly maintenance, daily health check.

## create-breakglass-admin.sh
Purpose:
- Create and manage emergency admin for OCI serial console access.
Ops:
- create, status, password rotate; idempotent; emits clear credential handling guidance.

## db-maint.sh
Purpose:
- Run sqlite integrity checks and optimizations on demand.

## update-dns.sh
Purpose:
- Update Cloudflare DNS records if needed; can be invoked manually or by startup.sh post-health.

## lib/*
- common.sh: logging, prompts, env & file helpers, validation routines.
- docker.sh: compose presence checks, service state helpers, waiters.
- crypto.sh: Age/SOPS utilities, secure file perms.
- backup_utils.sh: common backup listing, metadata helpers, email notices.
