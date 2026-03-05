# Full Sysadmin Beta Test Report – VaultWarden-OCI (Adversarial)

## Executive Summary

This beta test was executed in a **containerized CI workspace**, not on a real OCI A1 Flex VM, so only static analysis and limited local script execution were possible.

**Bottom line:** the project is well-structured and security-conscious, but there are still production risks for first-time operators:

- Several workflows assume operator judgment beyond README wording (e.g., Cloudflare token scopes, cron lock-dir persistence, network prerequisites).
- Documentation still includes a few `:latest` utility image examples (`alpine:latest`, `caddy-cloudflare:latest`) that weaken supply-chain reproducibility.
- Full install/restore/upgrade/failure-injection/reboot validation was **not fully reproducible** in this workspace without a true fresh OCI host.

**Production readiness (for <=10 users):** Conditional YES after addressing high-priority documentation and process hardening items listed below.

---

## Static Script Audit

### Scope reviewed

- `README.md`
- Top-level operational scripts (`setup.sh`, `setup-secrets.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `update.sh`, `health.sh`, `maintenance.sh`, `cron-setup.sh`, `edit-secrets.sh`, `create-breakglass-admin.sh`)
- Shared libs in `lib/`
- Caddy entrypoint and compose templates

### Positive findings

- Main scripts consistently enforce strict shell mode (`set -euo pipefail`).
- Security-oriented architecture is present (Age/SOPS secrets, fail2ban integration, non-root containers, capability drop).
- Backup/restore documentation and helpers are extensive.

### Risk findings

| ID | Area | Severity | Finding | Suggested Fix |
|---|---|---|---|---|
| BETA-01 | `setup.sh` arg parsing | Medium | `--domain/--email` accepted without explicit value checks, resulting in brittle error paths if user typoed flags. | Added explicit missing-value guard with clear error. |
| BETA-02 | `caddy/entrypoint.sh` secret loading | Medium | Secret loading used `echo` pipelines and untrimmed token read; newline artifacts can cause false negatives/format confusion. | Switched to safer `printf` validation and newline-stripped token read. |
| BETA-03 | `caddy/entrypoint.sh` env validation | Low | `DOMAIN_NAME` failure happened late/implicitly under `set -u` behavior. | Added explicit preflight check and clear error message. |
| BETA-04 | Docs supply chain reproducibility | Medium | Troubleshooting/migration snippets still reference utility `:latest` tags. | Pin helper image tags in docs examples. |

---

## Installation Report

### Execution reality in this test

A **true fresh OCI Ubuntu minimal VM install was not available** inside this workspace; therefore, full Phase-2 install validation could not be completed exactly as requested.

### What was validated

- README flow readability and ordering was reviewed.
- Script entrypoints are syntactically valid (`bash -n`).
- Setup help and failure-mode behavior were executed and observed.

### What remains to validate on actual OCI host

- Docker package install on Ubuntu minimal ARM64 from a non-root sudo account.
- Caddy ACME issuance with grey-cloud then orange-cloud transition.
- OCI Security List + Cloudflare edge behavior end-to-end.
- Reboot persistence for docker services and cron lock path behavior.

---

## Idempotency & Repeatability Findings

- The project explicitly targets idempotent operations in docs and script behavior.
- Remaining concern: repeatability still depends on operator preserving key material and correctly sequencing `.env` + secrets population.
- Recommend adding a `make preflight` or `./setup.sh --preflight-only` mode to test host readiness safely before mutation.

---

## Failure Injection Results

Not fully executed due environment constraints (no isolated OCI VM lifecycle control in this workspace).

Recommended mandatory beta tests on real host:

1. Kill Docker during setup dependency/install phase.
2. Interrupt `setup.sh` and rerun with and without `--force`.
3. Fill disk above 95% before backup and update.
4. Kill vaultwarden/postfix containers during backup and update.
5. Start backup + restart concurrently to verify lock behavior.

---

## Backup & Restore Validation

- Static review indicates substantial effort around integrity and encrypted backups.
- Full integrity proof (users/items/attachments/admin settings) requires seeded live dataset and restore to second clean host; not completed in this workspace.

---

## Upgrade Testing Results

- Update flow is documented with rollback intent.
- Real migration/downgrade verification against live data not executed here.

---

## Concurrency & Race Condition Findings

- Project includes lock-file/`flock` patterns and lock-dir recommendations.
- Concurrency safety under real workload (parallel backup/restart/restore) remains to be proven in OCI acceptance test.

---

## Security Audit

### Security score: **7.8 / 10**

Good baseline hardening, but first-time admin safety still depends on disciplined operator behavior.

### Critical vulnerabilities found

- None confirmed as exploitable in this limited environment.

### High-priority hardening recommendations

1. Remove `:latest` references from operational docs examples to reduce supply-chain drift.
2. Add explicit preflight checks for DNS/token scopes before long-running setup paths.
3. Add a machine-readable audit mode that prints all assumptions and unresolved placeholders.

---

## ARM64 / OCI Findings

- Compose images appear ARM-capable at design level, but runtime pull/execution on A1 Flex not validated in this workspace.
- Resource limits look reasonable for <=10 users but need live profiling (RAM, disk growth, log growth).

---

## Documentation Gaps

1. OCI-only operational gotchas (lock-dir persistence, Cloudflare first-boot staging) are present but easy to miss.
2. A dedicated “fresh host acceptance checklist” document would improve repeatability for junior admins.
3. Add explicit “expected outputs” after each major step in README.

---

## Script Bugs & Code Defects

### Fixed in this beta cycle

- Added robust missing-value handling for `--domain` and `--email` in `setup.sh`.
- Hardened secret parsing/validation and explicit env preflight in `caddy/entrypoint.sh`.

### Remaining recommended fixes

- Pin helper container tags in docs snippets.
- Add optional lock around restore/startup overlapping paths if not already serialized at orchestrator level.

---

## Critical Issues List

1. **Process-level criticality:** inability to verify the full install/restore/upgrade/failure matrix in a clean OCI ARM64 lifecycle from this workspace.
2. **Operational medium risk:** docs still include `latest` helper image examples.

---

## Recommended Fixes (Priority Order)

1. Build a CI smoke test matrix for `bash -n` + shellcheck + dry-run command workflows.
2. Add preflight-only mode and explicit dependency/network/token checks.
3. Provide a scripted OCI acceptance harness (install → reboot → backup → restore → update → rollback).
4. Pin all helper image tags in docs.

---

## Final Verdict (Would I deploy to production?)

**Yes, with conditions.**

I would deploy for a <=10-user team **only after**:

- running the full acceptance matrix on real OCI A1 Flex,
- verifying restore on a second clean host,
- and implementing the documented high-priority hardening/documentation fixes.

As-is, the project is close, but the current evidence from this workspace alone is not sufficient for a no-questions-asked production signoff.
