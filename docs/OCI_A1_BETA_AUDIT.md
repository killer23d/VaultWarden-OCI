# VaultWarden-OCI Adversarial Beta Audit (OCI A1 Flex Target)

## Executive Summary

This audit was executed in an **adversarial QA/sysadmin mode** against the repository scripts and docs, with limited runtime validation in this container.

**Important scope limitation:** I could not provision an actual OCI Ampere A1 (ARM64) host from this environment, and this runner has no Docker daemon. Dynamic phases requiring real OCI networking, reboot behavior, Docker runtime, and long-running restore/upgrade drills are therefore partially blocked.

Despite those limits, the static review and dry-run checks still exposed multiple high-signal defects:

- **HIGH:** `setup.sh` phase error reporting is wrong (`exit code: 0` shown on failure), which can mislead operators during incident handling.
- **HIGH:** operation lockfiles are still placed in `/tmp` for critical paths (`update.sh`, `maintenance.sh` DNS updater), leaving avoidable lock-file tampering/symlink abuse surface.
- **MEDIUM:** documentation/schedule drift (`README` says DB backup daily; `cron-setup.sh` actually schedules Mon–Sat).
- **MEDIUM:** version pin drift/inconsistency (`docker-compose.yml.example` defaults Postfix to `5.1.0` while `.env.example` and comments state `4.3.0`).
- **MEDIUM:** secret-adjacent data is echoed by Caddy entrypoint in error/debug paths.
- **MEDIUM:** dependency remediation hint can suggest invalid apt package names (command names are printed as package names).

Bottom line: **not production-ready as-is for a first-time operator following docs blindly**. The project is close and has many safety controls, but these defects can cause misconfiguration, confused recovery, and avoidable risk.

---

## Static Script Audit

### Method
- Read `README.md` end-to-end and inspected all top-level scripts plus `lib/*.sh` and `caddy/entrypoint.sh`.
- Performed static checks (`bash -n`/`sh -n`, pattern review for locks, version pins, secrets handling, and schedule consistency).

### Findings

1. **Phase failure exit-code reporting bug in `setup.sh`** (**HIGH**)  
   `execute_phase()` uses `if ! "$phase_func"; then exit_code=$? ...` which captures the status of the negated condition context rather than the failing command status, causing misleading output.  
   Evidence: `setup.sh` implementation and observed output (`Phase failed ... exit code: 0`).

2. **Insecure lockfile location for core operations** (**HIGH**)  
   `update.sh` uses `/tmp/.vw_operations.lock`; `maintenance.sh` DNS lock uses `/tmp/.vw_dns_update.lock`. `/tmp` is world-writable and a poor location for privileged coordination files versus `/run/lock` or `/var/lock` with ownership controls.

3. **Secret-adjacent log leakage in Caddy entrypoint** (**MEDIUM**)  
   On parsing error, `caddy/entrypoint.sh` logs `Got: $ADMIN_HASH_FULL`; it also prints partial hash details in another failure branch. This can leak credential material into container logs.

4. **Version pin inconsistency (Postfix)** (**MEDIUM**)  
   Compose template comment says 4.3.0 but the default interpolation fallback is 5.1.0. `.env.example` pins 4.3.0. This is drift that can produce unplanned version changes depending on environment state.

5. **Unpinned image still present (`busybox:latest`)** (**MEDIUM**)  
   Init container uses mutable `latest`, increasing supply-chain and repeatability risk.

6. **Dependency install hint may be wrong** (**MEDIUM**)  
   `require_commands()` suggests `sudo apt install <missing commands>`, but command names do not always equal package names (`htpasswd` is from `apache2-utils`). This creates first-run friction and misleading recovery guidance.

7. **Doc vs implementation cron schedule mismatch** (**MEDIUM**)  
   README table says DB backup at 4 AM daily; cron generator sets DB backup Mon–Sat only.

### Risk classification
- **Critical:** 0
- **High:** 2
- **Medium:** 5
- **Low:** several minor style/docs nits not listed

---

## Installation Report

### What was validated
- Help/argument behavior of setup path.
- Dry-run execution path until dependency verification.

### Commands and notable output
- `bash setup.sh --help` succeeded and showed expected flags.
- `bash setup.sh --domain vault.example.com --email admin@example.com --auto --dry-run` failed at dependency verification with:

```
[ERROR] [setup] Missing required commands: age sops docker ufw htpasswd
[INFO] [setup] Install with: sudo apt install age sops docker ufw htpasswd
[ERROR] [setup] Phase failed: Dependency Verification (exit code: 0)
```

### Assessment
- Setup flow is generally structured and phased.
- Error text quality is currently compromised by the false `exit code: 0` report.
- In this environment, Docker runtime validation is blocked because Docker is not installed.

---

## Idempotency & Repeatability Findings

- Positive: repository heavily documents idempotent intent and uses lock controls in many places.
- Negative:
  - Lock strategy is inconsistent (`/var/lock` in backup/restore vs `/tmp` in update and DNS update).
  - Schedule drift between docs and cron generation undermines repeatable operator expectations.

Verdict: **partially repeatable, but not predictably so for first-time operators.**

---

## Failure Injection Results

Full runtime failure injection (kill Docker mid-install, disk fill to 95%, restart loops, etc.) is **blocked** here due missing Docker and no OCI VM control plane.

What I could simulate:
- Setup dry-run with missing dependencies produced deterministic failure output.
- This surfaced one real defect (incorrect exit code reporting).

---

## Backup & Restore Validation

Could not run end-to-end encrypted backup/restore cycles in this environment (no Docker services, no live VaultWarden DB).

Static review notes:
- Backup/restore scripts use host `sqlite3` and include locking plus integrity checks, which is good architecture.
- Backup lock path is in `/var/lock` (good), but cross-script lock consistency is not uniform across the project.

---

## Upgrade Testing Results

Runtime upgrade/downgrade validation blocked (no Docker runtime).

Static concerns relevant to upgrade safety:
- Mutable `busybox:latest` introduces nondeterminism.
- Postfix version default drift (`5.1.0` fallback vs `4.3.0` docs/pin comments) can surprise operators during regen/redeploy.

---

## Concurrency & Race Condition Findings

- Good: explicit `flock` usage in multiple scripts and dedicated lock directories in cron setup.
- High-risk inconsistency: lockfiles in `/tmp` for critical operation paths are weaker and more tamper-prone.
- Documentation currently advertises lock behavior that is not fully consistent with implementation details.

---

## Security Audit

### Security score: **6/10**

Strengths:
- Strong baseline intent: non-root containers, capability reduction, encrypted secrets workflows, phased setup, explicit backup/restore tooling.

Weaknesses:
- `/tmp` lockfile usage in privileged operations.
- Secret-adjacent logs in caddy entrypoint.
- Use of mutable tags (`busybox:latest`).
- Version drift inconsistencies can cause unreviewed component changes.

### Critical vulnerabilities
- None confirmed as immediately exploitable RCE from static review alone.

### Hardening recommendations
1. Move **all** operation locks to `/run/lock` or `/var/lock` with strict perms.
2. Remove all secret/hash content from startup logs and error messages.
3. Pin every image tag (including init container).
4. Fix `setup.sh` phase exit-code capture.
5. Align README cron schedule with actual generated cron.
6. Add CI linting for script behavior + docs consistency checks.

---

## ARM64 / OCI Findings

### Status
- Full ARM64 runtime validation blocked in this environment (`x86_64`, no Docker daemon).

### Static ARM/OCI notes
- `setup.sh` explicitly handles architecture and Ubuntu repo concerns, including Docker apt repo behavior on Ubuntu 24.10.
- OCI-specific guidance exists in README and docs.

### Residual risk
- Until tested on real A1 Flex with container startup and sustained load, ARM compatibility remains **not proven** end-to-end.

---

## Documentation Gaps

1. README cron schedule mismatch with generated cron jobs.
2. Dependency remediation string may mislead users into invalid package names.
3. Some implementation constraints (runtime limits, lock path details) are not consistently surfaced in operator-facing docs.

---

## Script Bugs & Code Defects

1. `setup.sh`: incorrect phase exit code logging.
2. `update.sh`: lockfile in `/tmp` for global operations lock.
3. `maintenance.sh`: DNS update lockfile in `/tmp`.
4. `caddy/entrypoint.sh`: logs include sensitive hash material on errors.
5. `docker-compose.yml.example`: `busybox:latest` mutable image.
6. `docker-compose.yml.example` vs `.env.example`: Postfix default/tag mismatch.
7. `lib/common.sh` dependency install hint assumes command name == apt package.

---

## Complete Issue List (Sorted by File Name, then Severity)

Severity order used per file: **HIGH → MEDIUM → LOW**.

### `README.md`

1. **MEDIUM** — Cron schedule mismatch for DB backup  
   **Issue:** README states “4 AM daily” while generated cron is Mon–Sat.  
   **Proposed code change:** Update the schedule table text to match `cron-setup.sh` (Mon–Sat), and add a short note explaining Sunday exclusion due to full-backup lock contention prevention.

2. **LOW** — Dependency install troubleshooting wording can mislead first-time users  
   **Issue:** README implies straightforward package install recovery paths, but command names may not match package names in all cases (e.g., `htpasswd`).  
   **Proposed code change:** Add a troubleshooting snippet mapping common commands to Ubuntu package names (`htpasswd -> apache2-utils`, etc.).

### `caddy/entrypoint.sh`

1. **MEDIUM** — Secret/hash material is logged on parse failure  
   **Issue:** Error branch prints `Got: $ADMIN_HASH_FULL`; another branch prints partial hash output.  
   **Proposed code change:** Remove secret-bearing output and replace with redacted diagnostics, e.g.:
   - `echo "Got invalid admin hash format" >&2`
   - optionally log only safe metadata (string length, presence/absence), never contents.

2. **LOW** — Debug verbosity includes operationally sensitive metadata by default  
   **Issue:** Startup logs include hash length and username every boot.  
   **Proposed code change:** Gate diagnostic logging behind an explicit `DEBUG_ENTRYPOINT=true` env flag, defaulting to silent for production.

### `docker-compose.yml.example`

1. **MEDIUM** — Mutable image tag (`busybox:latest`) in init service  
   **Issue:** Non-deterministic deployments and supply-chain drift risk.  
   **Proposed code change:** Pin `busybox` to a specific version or digest (`busybox:1.36.x` or `busybox@sha256:...`) and document update cadence.

2. **MEDIUM** — Postfix version fallback drift  
   **Issue:** Compose fallback defaults to `5.1.0` while comments/`.env.example` indicate `4.3.0`.  
   **Proposed code change:** Align all sources to one intended version; preferably remove fallback drift by requiring `.env` pin and failing fast if unset.

### `lib/common.sh`

1. **MEDIUM** — `require_commands()` suggests apt packages by command name  
   **Issue:** Installation guidance may be wrong (command ≠ package).  
   **Proposed code change:** Add a mapping function for known commands to packages and print a deduplicated package list. Example mapping: `htpasswd -> apache2-utils`, `docker -> docker-ce|docker.io` context-specific hint.

2. **LOW** — Generic remediation message misses distro variance  
   **Issue:** Single apt-centric hint may be incorrect on non-Ubuntu OCI images.  
   **Proposed code change:** Include distro-aware hints (`apt`, `dnf`) based on `/etc/os-release` detection.

### `maintenance.sh`

1. **HIGH** — DNS updater lock in `/tmp`  
   **Issue:** World-writable lock location for privileged workflow (`/tmp/.vw_dns_update.lock`).  
   **Proposed code change:** Move to `/run/lock/vaultwarden-oci/dns-update.lock` (or `/var/lock/...`), ensure directory ownership/permissions (`root:root`, `0700`) and use `flock` for consistency.

2. **LOW** — Locking model differs from other critical scripts  
   **Issue:** Mix of noclobber file-lock and flock-based locks across codebase increases maintenance risk.  
   **Proposed code change:** Standardize on a shared lock helper (library function) for all critical operations.

### `setup.sh`

1. **HIGH** — Phase failure exit code logged incorrectly  
   **Issue:** `execute_phase()` reports `exit code: 0` on a real failure due to capturing status after negation context.  
   **Proposed code change:** Capture command status directly without `if ! ...` status ambiguity. Example pattern:

   ```bash
   "$phase_func"
   exit_code=$?
   if [[ $exit_code -ne 0 ]]; then
       log_error "Phase failed: $phase_name (exit code: $exit_code)"
       [[ "$phase_critical" == "true" ]] && return 1 || return 2
   fi
   ```

2. **LOW** — Dry-run still hits dependency verification path assumptions  
   **Issue:** In constrained environments, dry-run behavior can still terminate early for missing runtime commands.  
   **Proposed code change:** Add a `--dry-run` mode guard that downgrades hard dependency verification to warnings (or a `--strict-dry-run` toggle).

### `update.sh`

1. **HIGH** — Global operations lock in `/tmp`  
   **Issue:** `/tmp/.vw_operations.lock` for update/restore/maintenance mutual exclusion is weaker than root-owned lock locations.  
   **Proposed code change:** Move to `/run/lock/vaultwarden-oci/operations.lock` (or `/var/lock/...`), enforce secure dir creation, and keep a consistent fd/flock approach.

2. **LOW** — Lock path duplication across scripts  
   **Issue:** Shared lock name/path is hardcoded, increasing drift risk during future edits.  
   **Proposed code change:** Define lock path in one shared library/config constant (`lib/common.sh`) consumed by all scripts.

---

## Critical Issues List

- **HIGH-1:** Misleading setup error code (`exit code: 0`) during failed phase.
- **HIGH-2:** Insecure `/tmp` lockfiles in privileged operational paths.

---

## Recommended Fixes

1. Fix exit-code capture in `setup.sh` by explicitly capturing command return before conditional negation side-effects.
2. Standardize locking to root-owned `/run/lock/vaultwarden-oci/*.lock` or `/var/lock/*`.
3. Strip credential/hash values from all logs (including malformed-secret branches).
4. Pin `busybox` to an explicit version/digest.
5. Reconcile Postfix version defaults between templates/comments.
6. Correct README cron table or cron generation schedule.
7. Improve `require_commands()` messaging with command→package mapping table.

---

## Final Verdict (Would you deploy to production?)

**No, not yet.**

I would require the two HIGH issues to be fixed first, plus the version/docs consistency defects, before approving this for production password-vault duty on OCI A1.

After those fixes and one full on-host OCI ARM64 runbook test (install → reboot → backup/restore → upgrade/downgrade), this could become production-acceptable.
