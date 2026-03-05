# OCI A1 Audit Revisions (Small-Team / Part-Time Admin Focus)

This addendum revises the prior audit with a maintenance-first lens and documents concrete patches applied.

## Issues (Sorted by File Name)

| File | Severity | Issue | Small-team impact | Patch applied |
|---|---:|---|---|---|
| `README.md` | Medium | Cron table said DB backup was daily, but cron job is Mon–Sat | Runbook confusion and false expectations during incidents | Updated schedule table to **4 AM Mon–Sat** |
| `caddy/entrypoint.sh` | Medium | Secret/hash material could appear in logs on validation failures | Credential exposure in logs, harder safe log sharing | Removed secret-bearing log lines and gated debug output behind `DEBUG_ENTRYPOINT=true` |
| `docker-compose.yml.example` | Medium | Mutable `busybox:latest` tag | Non-deterministic deploy/update behavior | Pinned to `busybox:1.36.1` |
| `docker-compose.yml.example` | Medium | Postfix fallback version drift (`5.1.0` fallback vs docs `4.3.0`) | Unplanned version changes and admin surprise | Aligned fallback to `4.3.0` |
| `lib/common.sh` | Medium | Missing-command install hint assumed command==package (e.g., `htpasswd`) | Slower troubleshooting for part-time admin | Added command→package hint mapping and package-manager-aware hinting |
| `maintenance.sh` | High | DNS lock used `/tmp/.vw_dns_update.lock` | Weak lock safety and concurrency race surface | Switched to `.locks` dir + `flock` lock file |
| `setup.sh` | High | Phase failure could log `exit code: 0` on real failure | Misleading diagnostics; wasted troubleshooting time | Reworked `execute_phase()` to capture true exit code |
| `update.sh` | High | Global operations lock in `/tmp` | Weak lock safety across update/restore/maintenance | Moved to project-local `.locks/operations.lock` with secure dir init |

## Why these revisions are suitable for this project

- They reduce risk **without adding enterprise-heavy operational burden**.
- They improve deterministic behavior, troubleshooting quality, and safe concurrency handling.
- They are low-to-moderate complexity changes that are maintainable by a part-time admin.

## Deferred (optional) hardening

- Digest pinning for every image (stronger than fixed tags, but higher maintenance overhead).
- Broader CI policy gates beyond shell/docs sanity checks.
