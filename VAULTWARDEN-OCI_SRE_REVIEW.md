# VaultWarden OCI Reliability Review

## Executive Summary

This repository is strongly aligned with the reliability goals in `docs/full_audit.md`: script hardening is broadly present (`set -euo pipefail`), most scheduled operations are lock-protected, backup/restore paths include integrity checks, and the project is intentionally optimized for small-team unattended operation.

Compared to the required audit checklist, the implementation is **mostly compliant** for automation, backup, and restore reliability, but there are several meaningful risks that can break unattended behavior:

- one high-impact host secret-permission issue in `docker-compose.yml.example`
- one high-impact lock-coordination gap across long-running operations
- a few medium-level script reliability gaps around lock lifecycle and parsing fragility

Overall assessment: **good small-team operational design with targeted hardening still needed for truly unattended reliability**.

---

# Findings (Validated Against docs/full_audit.md)

Validation approach used:
- Cross-checked each issue against the reliability objectives and known failure modes in `docs/full_audit.md` (race conditions, cron safety, brittle parsing, temp-file collisions, secrets leakage, Cloudflare DNS/API failure modes, DR gaps).
- Kept recommendations simple for small-team operations (no enterprise tooling).

## Outstanding Issues (sorted by file name)

### [HIGH] docker-compose.yml.example

Problem:
`init-permissions` sets host-mounted Docker secret files under `/secrets/.docker_secrets/*` to mode `644`.

Why it matters:
This directly maps to `full_audit.md` secret lifecycle/leakage risk checks.

Failure scenario:
A low-privilege host account can read world-readable secret files (Cloudflare tokens, SMTP password, admin token/hash).

Suggested fix:
Set secret files to `600` (or strict `640` with dedicated group), and verify ownership remains restricted.

---

### [MEDIUM] health.sh

Problem:
Health auto-recovery checks `/tmp/.vw_maintenance.lock`, while maintenance uses `${PROJECT_STATE_DIR}/.locks/global-maintenance.lock`.

Why it matters:
This matches race/automation safety checks in `full_audit.md` (jobs/scripts conflicting around shared state).

Failure scenario:
During planned maintenance, health auto-recover may restart services unexpectedly.

Suggested fix:
Standardize on one maintenance lock signal and read that same lock in health auto-recovery.

---

### [LOW] maintenance.sh

Problem:
External IP lookup for DNS updates uses a single provider (`checkip.amazonaws.com`) without fallback.

Why it matters:
This maps to Cloudflare DNS/API failure-mode resilience checks.

Failure scenario:
Transient provider outage causes repeated DNS-update failures.

Suggested fix:
Add one or two fallback IP providers with short retry/backoff.

---

### [MEDIUM] maintenance.sh

Problem:
Primary maintenance mutual exclusion uses mkdir lock-directories (`$state_dir/.locks/maintenance.lock`, `db-maint.lock`), which can remain stale after abrupt termination.

Why it matters:
This maps to race-condition/locking reliability criteria.

Failure scenario:
Stale lock dir blocks future unattended maintenance until manual cleanup.

Suggested fix:
Use fd-based `flock` where practical, or add stale lock age/PID validation and safe auto-cleanup.

---

### [HIGH] restore.sh

Problem:
Cross-operation locking is inconsistent: `update.sh` uses `${PROJECT_ROOT}/.locks/operations.lock`, but `restore.sh` uses `/var/lock/vaultwarden-restore.lock`.

Why it matters:
This aligns with `full_audit.md` race-condition and update/restore safety requirements.

Failure scenario:
Restore and update can run concurrently under certain paths, causing state mutation collisions.

Suggested fix:
Use one shared operations lock across update/restore/maintenance, with optional task-specific secondary locks.

---

### [MEDIUM] setup-secrets.sh

Problem:
Secrets are staged in a fixed temp filename (`secrets/.temp_secrets.yaml`) instead of unique `mktemp` output.

Why it matters:
This directly maps to temp-file collision checks in `full_audit.md`.

Failure scenario:
Concurrent or interrupted runs collide on temp file, risking partial/corrupted write flow.

Suggested fix:
Use secure `mktemp` in the secrets directory and atomic move into place.

---

### [MEDIUM] startup.sh

Problem:
`prepare_docker_secrets()` extracts YAML using `grep | cut | sed`.

Why it matters:
This maps to brittle parsing checks in `full_audit.md`.

Failure scenario:
Edge-case YAML values (special characters/format variations) are parsed incorrectly, producing broken runtime secret files.

Suggested fix:
Use structured extraction (`sops --extract`, or YAML-aware parser) instead of line-based parsing.

---

# Race Condition Analysis

- **Well-covered areas:**
  - `backup.sh` uses fd-based `flock` in `/var/lock`.
  - cron jobs for maintenance/health/dns/firewall use `flock -n` wrappers.
- **Remaining race risks:**
  - lock model divergence between update/restore/maintenance reduces true mutual exclusion.
  - mkdir-based maintenance locks can become stale, creating pseudo-deadlocks.
  - fixed temp-file path in `setup-secrets.sh` allows concurrent collision.

---

# Automation Reliability Assessment

Against `docs/full_audit.md` requirements:

- **Automation reliability:** mostly strong; cron orchestration and structured scripts are mature.
- **Cron safety:** mostly good (explicit `cd`, skip logging, lock wrappers).
- **Idempotency:** generally good in setup paths, with some edge-case fragility.
- **Update safety:** strong backup-first and rollback intent, but lock consistency gap weakens safety under concurrency.
- **Cloudflare integration:** functional but DNS update path could be more resilient to transient API/IP-source failures.

---

# Backup and Restore Evaluation

- **Strengths:** atomic SQLite snapshot approach, verification modes, encryption, retention, and documented DR workflows.
- **Risks:** restore locking does not fully align with update lock strategy; potential concurrency hazards remain.
- **Net:** good for small-team operations once lock unification is implemented.

---

# Disaster Recovery Evaluation

- **Strengths:** emergency backup tier, documented complete server rebuild flow, rollback path after update failure.
- **Gaps:** stale-lock/manual cleanup risks can block unattended job continuity; secret file host permissions increase breach blast radius in DR compromise scenarios.

---

# Security Observations

- Good use of Age+SOPS and Docker secrets model.
- High-priority host permission issue (`644` on secret files) should be corrected immediately.
- Cloudflare token handling and split-token model are appropriate for this project scale.

---

# Operational Complexity Review

- Design is appropriately simple for a part-time junior admin.
- Documentation is extensive and practical.
- Remaining complexity/risk is mostly in lock coordination and edge-case script behavior, not architectural overreach.

---

# Suggested Improvements

1. Normalize a single shared operations lock across update/restore/maintenance.
2. Replace mkdir lockdirs with fd-based `flock` for long-running maintenance tasks.
3. Fix secret file permissions to least privilege in init-permissions.
4. Switch secrets parsing in startup to structured extraction.
5. Make setup-secrets temp writing collision-safe via `mktemp`.
6. Add simple multi-endpoint fallback for external IP detection.

(These keep the system simple and avoid enterprise-only tooling.)

---

# Reliability Score

- **Unattended reliability:** 7.5/10
- **Maintainability:** 8/10
- **Disaster recovery:** 8/10
- **Operational safety:** 7/10

---

# Positive Observations

- Strong script hardening baseline and clear operational docs.
- Practical cron scheduling to avoid common overlap windows.
- Good backup/restore feature depth for a small deployment.
- Thoughtful Cloudflare-first model for proxied traffic realities.
