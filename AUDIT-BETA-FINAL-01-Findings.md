# AUDIT-BETA-FINAL-01 — Final Pre-Production Findings

**Repository:** killer23d/VaultWarden-OCI  
**Branch:** Beta  
**Audit Date:** 2026-05-26  
**Auditor:** Claude Opus 4.6  
**Commit audited:** fc55afc (Add files via upload)  
**Prior PRR:** PRR-Beta-Findings.md (all 9 items — re-verified in Part 1)

---

## Overall Verdict

🟡 **Conditionally Ready**

The system is architecturally sound and operationally complete for a 10-person VaultWarden deployment. However, two PRR-mandated fixes (CrowdSec version pinning, sidecar upload failure surfacing) remain unimplemented, the documentation contains ~25 factual inaccuracies that will mislead a junior admin during disaster recovery, and the full-backup archive silently includes the `secrets/` directory despite documentation stating otherwise. These issues must be resolved before production deployment; none require architectural changes and all are low-to-medium effort fixes.

---

## Part 0 — File Inventory & Drift Check

All directories read successfully. Actual contents match the expected file list exactly.

| Directory | Expected | Actual | Status |
|---|---|---|---|
| Root | 19 files | 19 files + `RPP2-AUDIT.md` | ✅ `RPP2-AUDIT.md` is the audit instruction file — expected |
| lib/ | 11 files | 11 files | ✅ Match |
| utilities/ | 25 files | 25 files | ✅ Match |
| caddy/ | 4 files | 4 files | ✅ Match |
| crowdsec/ | 3 files | 3 files | ✅ Match |
| systemd/ | 14 files | 14 files | ✅ Match |
| docs/ | 14 files | 14 files | ✅ Match |

No [MISSING] or [NEW — UNAUDITED] files found.

---

## Part 1 — PRR Re-Verification

| # | PRR Fix | Pass/Fail | Evidence (file:line → code quote) |
|---|---|---|---|
| 1 | Lock moved to `/run/lock/` + `flock` on open FD | **Pass** | `utilities/maintenance-run.sh:124-128` → `local _MAINT_LOCK="/run/lock/vaultwarden-maintenance.lock"` / `exec {_MAINT_LOCK_FD}>"$_MAINT_LOCK"` / `if ! flock -n "$_MAINT_LOCK_FD"; then`; `utilities/backup-run.sh:1111-1117` → `LOCK_FILE="/run/lock/vaultwarden-backup.lock"` / `exec {LOCK_FD}>"$LOCK_FILE"` / `if ! flock -n "$LOCK_FD"; then`; `utilities/maintenance-health.sh:127-137` → `local _HEALTH_RUN_LOCK_FILE="/run/lock/vaultwarden-health.lock"` / `exec {_HEALTH_LOCK_FD}>"$_HEALTH_RUN_LOCK_FILE"` / `if ! flock -n "$_HEALTH_LOCK_FD"` |
| 2 | `User=ubuntu`/`Group=ubuntu` removed; no ubuntu fallback | **Pass** | `systemd/vaultwarden-db-backup.service:23-24` → `# User/Group are NOT set here. They are injected at install time via`; `utilities/setup-systemd.sh:225-228` → `candidate=$(getent passwd \| awk -F: '$3>=1000 && $7!~/false\|nologin/{print $1; exit}')` / `echo "$candidate"`; `utilities/setup-systemd.sh:319-320` → `User=${service_user}` / `Group=${service_group}` |
| 3 | Remote sidecar upload failures surface as partial-failure | **Fail** | `utilities/backup-run.sh:548-551` only warns: `One or more sidecar files could not be uploaded...` / `fall back to size-only verification...`; then `utilities/backup-run.sh:583-586` still reports success: `backup_log_info "Offsite sync complete → ${remote_file_path}"` followed by function end. **No partial-failure exit code or state is propagated to the caller.** |
| 4 | Remote retention pruning mirrors local retention | **Pass** | `utilities/backup-run.sh:590-592` → `Prunes backup files older than RETENTION_DAYS...`; `utilities/backup-run.sh:681-694` → `rclone deletefile ... "${remote_path}/${_file}"` and sidecars; `utilities/backup-run.sh:1099-1101` → `_prune_remote_backups "$KEEP_DAYS"` |
| 5 | Cloudflare CIDR fetch is cached/fail-closed | **Pass** | `utilities/setup-firewall.sh:121` → `local cf_cidr_cache="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/cf-cidrs.cache"`; `utilities/setup-firewall.sh:156-157` → `Could not fetch Cloudflare CIDR lists and no cache is available.` / `SECURITY: Refusing to configure ports 80/443 without valid CIDR data.` |
| 6 | `.env` mutations are atomic temp-file + `mv` | **Pass** | `lib/config.sh:182-185` → `tmp_file="$(dirname "$file")/.env.tmp.$$"`; `lib/config.sh:195-203` → `sed ... > "$tmp_file"` / `chmod --reference="$file" "$tmp_file"` / `mv "$tmp_file" "$file"` |
| 7 | CrowdSec bootstrap versions pinned, no `curl \| bash` | **Fail** | `utilities/setup-crowdsec.sh:192` → `curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \| bash`; `utilities/setup-crowdsec.sh:127-128` → `CROWDSEC_VERSION="${CROWDSEC_VERSION:-}"` / `CF_BOUNCER_VERSION="${CF_BOUNCER_VERSION:-}"` (blank by default); `utilities/setup-crowdsec.sh:279-280` → `_gh_api=".../releases/latest"`; `utilities/setup-crowdsec.sh:376` → `_go_pkg_ref="...@latest"` |
| 8 | Full-backup / full-restore scope gap documented | **Pass** | `docs/BACKUP-RESTORE.md:20-25` → `**Full** ... (no secrets)` / `Emergency ... Everything + secrets + Age key`; `docs/BACKUP-RESTORE.md:77-78` → `Included: ...` / `Excluded: secrets/ directory, Age keys...` |
| 9 | Minimum TLS version in both Caddyfiles | **Pass** | `caddy/Caddyfile:81-84` → `tls { dns cloudflare {env.CLOUDFLARE_API_TOKEN} min_version tls1.2 }`; `caddy/Caddyfile.degraded:77-80` → `tls { dns cloudflare {env.CLOUDFLARE_API_TOKEN} min_version tls1.2 }` |

**Summary:** 7 Pass, 2 Fail. Items #3 and #7 are carried forward as Critical findings in Parts 5 and 6 respectively.

---

## Part 2 — Command Validity

### Critical Failures

None. All 42 `.sh` files audited. Every external command invocation verified for valid subcommands, flags, and positional arguments.

### Validated Commands (summary)

| Command | Call Sites Verified | Notes |
|---|---|---|
| `docker` / `docker compose` | `ps --status --quiet`, `config --format json`, `compose up -d`, `down`, `pull`, `exec`, `logs`, `inspect --format` | All valid |
| `systemctl` | `is-active`, `is-enabled`, `enable --now`, `disable --now`, `daemon-reload`, `show --property --value` | All valid |
| `rclone` | `copy`, `lsd`, `lsf`, `lsl`, `deletefile`, `size`, `listremotes` | All valid; `sync`, `ls`, `delete`, `purge`, `about` not used |
| `cscli` | `decisions`, `bouncers`, `collections`, `hub`, `metrics` | All valid CrowdSec v1.x syntax |
| `openssl` | `dgst`, `rand` | All valid; `enc`, `pkeyutl`, `genrsa`, `req` not used |
| `sops` | `-d`, `--extract`, `--output-type`, `--encrypt --in-place` | All valid v3.x syntax |
| `age` / `age-keygen` | Flag syntax verified | Valid |
| `iptables` / `ip6tables` | `-A`, `-I`, `-D`, `-F`, `-P`, `--dport`, `-m conntrack`, `-j` | All valid |
| `curl` | `--retry`, `--connect-timeout`, `--max-time`, `-H`, `-o`, `-s`, `-L` | `--fail-with-body` not used |
| `jq` | Filter syntax verified across all call sites | All valid |
| `sqlite3` | `PRAGMA`, `.backup` | All valid |
| `netfilter-persistent` | `save` | `restart` (invalid) not used |
| `nc` | `-w 3` | Valid for GNU netcat |

### Minor Issues

- None identified.

---

## Part 3 — Shell Safety

### Critical

| # | File | Line | Finding |
|---|---|---|---|
| 3-1 | `lib/email.sh` | 605 | **Secret exposed in process argv.** SMTP password passed as `--user "${SMTP_USERNAME}:${SMTP_PASSWORD}"` to `curl`, visible in `ps aux` / `/proc/*/cmdline` during direct-SMTP mode execution. |

### Moderate

| # | File(s) | Line(s) | Finding |
|---|---|---|---|
| 3-2 | `utilities/maintenance-run.sh`, `maintenance-db-maint.sh`, `maintenance-health.sh`, `backup-run.sh` | Various | **Lock paths are not shared across all operations.** maintenance-run uses `/run/lock/vaultwarden-operations.lock` + `/run/lock/vaultwarden-maintenance.lock`; maintenance-db-maint uses the same two; maintenance-health uses `/run/lock/vaultwarden-health.lock`; backup-run uses `/run/lock/vaultwarden-backup.lock`. No single mutex prevents concurrent backup + health + maintenance. |
| 3-3 | `utilities/maintenance-health.sh:131`, `backup-run.sh:1114` | — | **Lock file permissions block non-root service users.** Lock files are created with `install -m 0660 -o root -g root`, but services can be installed as a non-root user via `setup-systemd.sh:319-320`. Non-root users cannot acquire the lock. |
| 3-4 | Multiple utilities | Various | **Lock FDs opened but not explicitly closed in EXIT trap.** Scripts rely on process exit to release flock, but do not explicitly `exec {FD}>&-` in cleanup handlers. While this works in practice, it violates the requested flock pattern. |
| 3-5 | `startup.sh` | 6 | **No EXIT trap.** Only ERR trap is set. |
| 3-6 | `utilities/maintenance-email.sh`, `maintenance-update.sh`, `maintenance-update-dns.sh`, `setup-systemd.sh`, `uninstall-vaultwarden.sh` | Lines 1-4 | **No EXIT or ERR trap declarations** in these entry-point scripts. |
| 3-7 | `startup.sh` | 112 | **Docker used before prereq check.** `docker compose down` is called before the `command -v` validation loop at line 214-218. |
| 3-8 | `utilities/maintenance-email.sh` | 62, 102, 109 | **No `command -v` guard** before `docker inspect`, `systemctl`, or `sudo cscli`. |

### Minor

| # | File | Line(s) | Finding |
|---|---|---|---|
| 3-9 | `utilities/secrets-view.sh` | 85, 98, 105-108 | **Not stdout-only.** Output is staged through a temp file (`mktemp -p /dev/shm`) and displayed via `less` or `cat`. This is intentional for security (avoiding shell history capture), but diverges from the audit requirement. |
| 3-10 | `utilities/uninstall-vaultwarden.sh` | 336, 344 | **Unquoted `$(...)` in `for` loops** for Docker volume/network listing. Low practical impact for Docker names. |

### Pass — Atomic `.env` Write (3d)

Verified correct:
- Same-directory temp file: `lib/config.sh:185` → `tmp_file="$(dirname "$file")/.env.tmp.$$"`
- Permission preservation: `lib/config.sh:202` → `chmod --reference="$file" "$tmp_file"`
- Atomic rename: `lib/config.sh:203` → `mv "$tmp_file" "$file"`

---

## Part 4 — Systemd Units

### Hardening Matrix

| Service | PrivateTmp | ProtectSystem | NoNewPrivileges | ProtectHome | RestrictSUIDSGID | CapabilityBoundingSet |
|---|---|---|---|---|---|---|
| db-backup | yes `:31` | strict `:32` | yes `:30` | read-only `:35` | — | — |
| dns-update | yes `:29` | strict `:30` | yes `:28` | read-only `:33` | — | — |
| firewall-update | yes `:28` | strict `:29` | yes `:27` | read-only `:32` | — | — |
| full-backup | yes `:28` | strict `:29` | yes `:27` | read-only `:32` | — | — |
| health | yes `:30` | strict `:31` | yes `:29` | read-only `:34` | — | — |
| **iptables** | yes `:35` | strict `:36` | **—** | yes `:37` | — | — |
| maintenance | yes `:26` | strict `:27` | yes `:25` | read-only `:28` | — | — |
| notify-failure | yes `:45` | strict `:46` | yes `:44` | yes `:49` | — | empty `:50` |

**Outlier:** `vaultwarden-iptables.service` is the only service missing `NoNewPrivileges=`. This service manages iptables rules and may legitimately need elevated capabilities, but should be documented.

**Global gaps:** No service sets `RestrictSUIDSGID=` or `AmbientCapabilities=`. This is consistent and acceptable for the threat model.

### Moderate

| # | File(s) | Finding |
|---|---|---|
| 4-1 | `vaultwarden-db-backup.service:7`, `vaultwarden-full-backup.service:4-5` | **Backup health dependency chain is incomplete.** `db-backup` has `After=vaultwarden-health.service` but no `Requires=`/`Wants=` to pull it in. `full-backup` has no health-unit dependency at all. Backups are not guaranteed to wait for a successful health check. |
| 4-2 | `vaultwarden-notify-failure.service` | **Missing `DefaultDependencies=no`.** Without this, the notify-failure service can be blocked during system shutdown, preventing failure notifications from firing. |

### Minor

| # | File(s) | Finding |
|---|---|---|
| 4-3 | `vaultwarden-maintenance.service` | **No `Conflicts=` with backup units.** Relies solely on flock locking (which works, but systemd-level conflict declaration would provide defense-in-depth). |

### Timer Schedule Overlap Analysis

| Timer | OnCalendar | RandomizedDelaySec |
|---|---|---|
| health | `*:0/5` | 60s |
| maintenance | `*-*-* 02:05:00` | 30s |
| db-backup | `*-*-* 04:00:00` | 60s |
| full-backup | `Sun *-*-* 03:00:00` | 300s |
| dns-update | `*-*-* *:00:00` | 120s |
| firewall-update | `Sat *-*-* 04:00:00` | 120s |

**Worst-case overlap:** Saturday 04:00 — 4 timers can fire within the same window: `db-backup + dns-update + firewall-update + health`. The flock locking prevents actual concurrent execution of conflicting operations, but timer stacking could cause service start failures or timeouts.

### Identity Verification (4d)

**Pass.** No `User=ubuntu` or `Group=ubuntu` found in any systemd unit. Only explicit identities are `User=root`/`Group=root` in `firewall-update.service:22-23`, `maintenance.service:20-21`, and `notify-failure.service:37`. All `ExecCondition=` lines invoke `/bin/bash -c` with inline checks — valid.

---

## Part 5 — Backup & Restore

### Critical

| # | File(s) | Finding |
|---|---|---|
| 5-1 | `utilities/backup-run.sh:871-886` | **Full/emergency backups silently include `secrets/` directory.** The tar excludes only `.git/backups/logs/.rate-limit/*.sock/*.lock/*.tmp/*.age.tmp`, then archives the entire project root (`tar_sources+=("${SCRIPT_DIR#/}")`). There is no `--exclude=${SCRIPT_DIR#/}/secrets`. A configured install creates `secrets/keys/age-key.txt` and `secrets/.docker_secrets/` via `setup-secrets.sh:1725-1737`. **Impact:** offsite backups may contain the Age private key and Docker secrets, contradicting documentation that says they are excluded. |
| 5-2 | `docs/BACKUP-RESTORE.md:19-25,83` vs `docs/DISASTER-RECOVERY.md:209-227` | **Contradictory documentation about backup contents.** BACKUP-RESTORE says emergency backups include "secrets + Age key" and full backups exclude them. DISASTER-RECOVERY says "Neither type includes the secrets/ directory or the Age key." The actual code includes everything. A junior admin's DR plan will be based on wrong assumptions. |
| 5-3 (PRR #3) | `utilities/backup-run.sh:548-586` | **Remote sidecar upload failures do not surface as partial-failure state.** (Carried from Part 1 Fail.) The function warns but still exits normally, reporting "Offsite sync complete." |

### Moderate

| # | File(s) | Finding |
|---|---|---|
| 5-4 | `utilities/restore-run.sh:1522-1552` | **Restore is not archive-faithful.** Backup archives the entire project root; restore selectively copies only `docker-compose.yml`, `docker-compose.override.yml`, `.env.example`, and `caddy/crowdsec/nginx` directories. Scripts, docs, lib, systemd files are archived but never restored. This is intentional (scripts come from git) but the gap is not clearly communicated. |
| 5-5 | `utilities/backup-run.sh:1230-1248` vs `:1063-1104` | **Remote prune only runs via `backup.sh rotate`, not during normal `run --rclone`.** Shipped timers invoke `backup.sh run ... --rclone --full-verification`, not `rotate`. Remote backups accumulate without pruning unless the admin manually runs `backup.sh rotate`. |
| 5-6 | `utilities/pre-production-drill.sh:153-273` | **Pre-production drill does not test full restore.** It runs backup dry-runs, verifies the latest existing backup, and performs DB-only decrypt/integrity checks. It does NOT call `restore-run.sh`, does not test full-backup restore, and does not validate a restored service can start. |

### Minor

| # | File(s) | Finding |
|---|---|---|
| 5-7 | `utilities/restore-run.sh:1894-1897` | **Post-restore summary is incomplete.** Only reminds to run `setup.sh systemd install`. Recovery-kit copy/delete warnings are shown earlier in the flow, not in the final summary. |

---

## Part 6 — Security

### Critical

| # | File(s) | Finding |
|---|---|---|
| 6-1 (PRR #7) | `utilities/setup-crowdsec.sh:192,127-128,279,376` | **CrowdSec bootstrap still uses `curl \| bash` and `latest` tags.** (Carried from Part 1 Fail.) Package repository setup uses piped shell execution. Version variables default to empty, causing latest-version installs. GitHub API fallback uses `/releases/latest`. Go package reference uses `@latest`. Only the GitHub tarball fallback path verifies SHA256 (`setup-crowdsec.sh:309-313`). |

### Moderate

| # | File(s) | Finding |
|---|---|---|
| 6-2 | `utilities/secrets-rotate.sh:288-301` | **Secrets rotation is not atomic.** Services are restarted individually via `docker compose restart $_affected_service`. If rotation fails mid-way, exported flat files and running services are not auto-rolled back. Backup is created before rotation (`secrets-rotate.sh:112-125`), but recovery is manual. |
| 6-3 | `utilities/setup-firewall.sh:143-154` | **Cloudflare CIDR cache lacks hardening.** Cache file written via plain `printf > "$cf_cidr_cache"` with no explicit `chmod`/restrictive permissions. No TTL/mtime validation — any existing cache is accepted regardless of age. No CIDR format validation before loading entries into iptables/ufw rules. |
| 6-4 | `utilities/setup-firewall.sh:167-175,263-276` | **Firewall rebuild is not atomic.** UFW phase exits early if rules exist (no reconciliation of changed CIDRs). iptables rules are mutated incrementally with per-rule commands. A rollback trap exists, but partial failures can leave mixed state. |
| 6-5 | `utilities/setup-crowdsec.sh:662` | **Firewall bouncer enable failure silently ignored.** `systemctl enable --now crowdsec-firewall-bouncer \|\| true` — if the bouncer fails to start, enforcement is silently absent. |

### Minor

| # | File(s) | Finding |
|---|---|---|
| 6-6 | `utilities/setup-crowdsec.sh:685-714` | **CrowdSec admin allowlist is conditional.** Only created if `--admin-ip` or SSH client IP is available. When created, it persists at `/etc/crowdsec/parsers/s02-enrich/vaultwarden-admin-allowlist.yaml` and survives restarts/upgrades. |

### Pass

- **Caddy TLS:** `min_version tls1.2` confirmed in both `caddy/Caddyfile:81-84` and `caddy/Caddyfile.degraded:77-80`.
- **Caddy headers:** All 5 headers (X-Frame-Options, X-Content-Type-Options, Strict-Transport-Security, Referrer-Policy, Content-Security-Policy) present in both Caddyfiles. 2FA connector routes intentionally omit XFO/CSP.
- **Caddy degraded mode:** Exposes no routes beyond production config; differences are only in log outputs.
- **Caddy Dockerfile:** Uses pinned image tags: `caddy:2.11.2-builder` and `caddy:2.11.2-alpine` (`caddy/Dockerfile:7,15`).

---

## Part 7 — README

### Moderate

| # | Finding |
|---|---|
| 7-1 | **No prominent "Start here → docs/DEPLOYMENT.md" link** in the first 50 lines. The deployment link is buried in the docs table at `README.md:401-405`. A junior admin cannot find the starting point within 30 seconds. |
| 7-2 | **README is overloaded.** Content that belongs in `docs/` includes: install walkthrough + optional volume flow (lines 20-227), email architecture deep-dive (lines 231-282), script catalog / library catalog (lines 285-347), backup strategy + Makefile reference (lines 357-395). Each should be replaced with a one-line link to the appropriate doc. |

### Minor

| # | Finding |
|---|---|
| 7-3 | `README.md:24,50-52` says ports 80/443 + grey-cloud DNS are required for cert issuance. The default Caddy path uses **Cloudflare DNS-01** challenge (`caddy/Caddyfile:80-82`, `caddy/entrypoint.sh:167-204`), which does not require inbound HTTP. |
| 7-4 | `README.md:233` says email lives in `lib/common.sh`. Actual implementation is in `lib/email.sh:14,821-879`. |
| 7-5 | `README.md:353` documents bare `maintenance.sh update`. Actual update requires `--images\|--system\|--all` flag (`utilities/maintenance-update.sh:40-53,353`). |
| 7-6 | `README.md:390` says `make logs` defaults to tailing 100 lines. Actual target follows a single service (`Makefile:460-466`). |

### Pass

- Utility count (24 scripts) is accurate.
- README correctly describes CrowdSec (not fail2ban).

---

## Part 8 — Documentation

### Accuracy Failures

| Document | Line | Documented | Actual | Type |
|---|---|---|---|---|
| DEPLOYMENT.md | 23 | Must open 80/443 before setup for TLS cert provisioning | Default TLS is Cloudflare DNS-01; cert issuance does not require inbound HTTP (`caddy/Caddyfile:80-82`) | WRONG_BEHAVIOR |
| DEPLOYMENT.md | 47 | Grey-cloud DNS needed so Caddy can reach Let's Encrypt directly | Default path is DNS-01, not HTTP-01 | WRONG_BEHAVIOR |
| DEPLOYMENT.md | 255 | Re-run `setup.sh install --force` to apply config changes | `--force` rotates the Age key and can orphan old backups (`setup.sh:94-101,205-213`) | WRONG_BEHAVIOR |
| OPERATIONS.md | 133 | `make logs` = all services, last 100 lines | `make logs` is `docker compose logs -f $(SERVICE)` (`Makefile:460-463`) | WRONG_BEHAVIOR |
| OPERATIONS.md | 137 | `make logs FOLLOW=true` follows all services | `FOLLOW` variable is ignored by `make logs` | WRONG_BEHAVIOR |
| OPERATIONS.md | 138 | `make logs-tail` follows all services | `make logs-tail` is only `docker compose logs --tail=100` (`Makefile:464-466`) | WRONG_BEHAVIOR |
| OPERATIONS.md | 308 | `./maintenance.sh update` updates containers | Bare `update` errors unless a flag is supplied (`utilities/maintenance-update.sh:40-53,353`) | WRONG_FLAG |
| OPERATIONS.md | 316 | `make update-system` is alias for full system+container update | `make update-system` only updates OS packages (`Makefile:752-761`); `make update` runs `--all` (`Makefile:742-746`) | WRONG_TARGET |
| OPERATIONS.md | 722 | `simple_verify_age_key` as a shell command | Library function in `lib/crypto.sh:945`, not standalone CLI | STALE_TERM |
| BACKUP-RESTORE.md | 19-21 | `db/full/emergency` have different contents; emergency includes key | `full` and `emergency` both call `perform_full_backup()` (`utilities/backup-run.sh:829-917,1186-1187`) | WRONG_BEHAVIOR |
| BACKUP-RESTORE.md | 51 | Timestamp format is `YYYYMMDD-HHMMSS` | Filenames use `YYYYMMDD_HHMMSS` (`docs/BACKUP-RESTORE.md:35-37`) | STALE_TERM |
| BACKUP-RESTORE.md | 169 | `make key-backup` generates printable PDF/HTML paper backup | `make key-backup` copies the key to `$HOME/age-key-backup-*.txt` (`Makefile:691-704`) | WRONG_BEHAVIOR |
| BACKUP-RESTORE.md | 451 | `simple_verify_age_key` as a shell command | Library function only (`lib/crypto.sh:945`) | STALE_TERM |
| DISASTER-RECOVERY.md | 3 | Secrets are out of scope/excluded from DR artifact | Backup code tars project root without excluding `secrets/` (`utilities/backup-run.sh:871-905`) | WRONG_BEHAVIOR |
| DISASTER-RECOVERY.md | 21 | `*.sh` scripts are excluded from full backup | They are not excluded by `perform_full_backup()` | WRONG_BEHAVIOR |
| DISASTER-RECOVERY.md | 209 | Full/emergency backups exclude `secrets/` and Age key | Archive includes project root; restore code refuses to restore `secrets/` (`utilities/restore-run.sh:1520-1551`) | WRONG_BEHAVIOR |
| DISASTER-RECOVERY.md | 241 | Re-run `setup.sh` with `--puid` / `--pgid` | `setup.sh` has no such flags (`setup.sh:73-110,172-197`) | WRONG_FLAG |
| SECURITY.md | 82 | `cs-cloudflare-bouncer` systemd unit/log name | Actual unit is `crowdsec-cloudflare-bouncer` (`utilities/setup-crowdsec.sh:400-419`) | WRONG_TARGET |
| SECURITY.md | 791 | `sudo systemctl status cs-cloudflare-bouncer` | Actual service is `crowdsec-cloudflare-bouncer` | WRONG_TARGET |
| SCRIPTS.md | 408 | `make update` = containers only | `make update` runs `./maintenance.sh update --all` (`Makefile:742-746`) | WRONG_BEHAVIOR |
| SCRIPTS.md | 409 | `make update-system` = containers + system packages | `make update-system` only updates OS packages (`Makefile:752-761`) | WRONG_BEHAVIOR |
| SCRIPTS.md | 727 | `make up` / `make start` → `sudo ./startup.sh` | Target runs non-sudo `./startup.sh` (`Makefile:254-310`) | WRONG_BEHAVIOR |
| SCRIPTS.md | 736 | `make logs` = `docker compose logs --tail=100 [SERVICE]` | Actual is `docker compose logs -f $(SERVICE)` (`Makefile:460-463`) | WRONG_BEHAVIOR |
| SCRIPTS.md | 737 | `make logs-tail` follows logs with timestamps | Actual is `docker compose logs --tail=100` (`Makefile:464-466`) | WRONG_BEHAVIOR |
| SCRIPTS.md | 849 | Functions come from `simple_key_resilience.sh` | They live in `lib/crypto.sh` (`lib/crypto.sh:945,1021,1276`) | STALE_TERM |
| TROUBLESHOOTING.md | 616 | `--quick-verify` flag | No such flag; quick verify is default behavior; full verify uses `--full-verification` | STALE_TERM |

### Reading Order Issues

- No explicit recommended reading order across docs.
- No "next step" links at the end of most documents. Dead-end docs include: `DEPLOYMENT.md`, `OPERATIONS.md`, `EMAIL.md`, `API.md`.
- Admin must rely on README's docs table to navigate — but the table has no ordering guidance.

### Per-Document Health

| Document | Accurate? | Junior-Admin-Followable? | Priority Issues |
|---|---|---|---|
| DEPLOYMENT.md | Mostly | Yes, with caveats | TLS prereq guidance is stale (DNS-01 vs HTTP-01) |
| CONFIGURATION.md | Yes | Yes | — |
| SECURITY.md | Mostly | Yes | Wrong CrowdSec bouncer service name (×2) |
| OPERATIONS.md | Poor | Partially | 6 inaccurate Make/script references |
| BACKUP-RESTORE.md | Poor | Partially | Contradictory backup contents; wrong behavior descriptions |
| DISASTER-RECOVERY.md | Poor | No | 4 factual errors about backup contents and flags |
| TROUBLESHOOTING.md | Mostly | Yes | One stale flag reference |
| SCRIPTS.md | Poor | Partially | 5 wrong Make target descriptions |
| EMAIL.md | Yes | Yes | — |
| API.md | Yes | Yes | Dead-end (no next link) |
| ADVANCED-CUSTOMIZATION.md | Yes | Yes | — |
| BOOTSTRAP_KEY_RECOVERY.md | Yes | Yes | — |
| MIGRATION.md | Yes | Yes | — |
| VOLUME-MIGRATION.md | Yes | Yes | — |

---

## Part 9 — Optimization

### 9a — Duplicated Logic

| # | Pattern | Files | Risk |
|---|---|---|---|
| 9-1 | Health polling ("wait for container healthy") | `lib/docker.sh:618-646`, `utilities/setup-storage.sh:1204-1246`, `utilities/restore-run.sh:1874-1880` | **Moderate.** "Healthy" semantics differ across copies; a change to one won't propagate. |
| 9-2 | `PROJECT_STATE_DIR` default fallback | `lib/storage.sh:110,469`, `startup.sh:259,288`, `utilities/setup-crowdsec.sh:441`, `utilities/setup-secrets.sh:506,777,786`, + more | **Low-Moderate.** If the default path ever changes, all sites must be updated. |
| 9-3 | `DATA_VOLUME_MOUNT` default fallback | `setup.sh:66`, `utilities/setup-env.sh:31,191,214,260`, `lib/storage.sh:112,201,408`, `utilities/setup-storage.sh:395,1573` | **Low-Moderate.** Same drift risk as 9-2. |
| 9-4 | `source lib/` boilerplate | `startup.sh:8-19`, `utilities/maintenance-run.sh:6-23`, `utilities/setup-env.sh:6-25`, `utilities/setup-crowdsec.sh:17-45` | **Minor.** Different guards/init/fallback behavior; should be unified. |

### 9b — Performance-Relevant Inefficiencies

| # | Pattern | File(s) | Impact |
|---|---|---|---|
| 9-5 | `$(cat file)` in health check hot path | `utilities/maintenance-health.sh:178,349,354` | Fork overhead on every 5-minute health check |
| 9-6 | Repeated `docker inspect` on same container | `utilities/maintenance-health.sh:310-323` | Multiple Docker API calls where one would suffice |
| 9-7 | Repeated `jq` on same JSON string | `lib/docker.sh:622-633` | Called from startup and health paths |

### 9c — Top 10 Longest Functions

| # | File | Function | Lines | Responsibility |
|---|---|---|---|---|
| 1 | `utilities/setup-systemd.sh:399-806` | `install_units` | ~407 | **Multiple concerns** — copies units, creates drop-ins, enables timers, validates |
| 2 | `lib/secrets.sh:771-992` | `generate_recovery_kit` | ~221 | **Multiple concerns** — generates, encrypts, validates, prints instructions |
| 3 | `utilities/setup-systemd.sh:870-1072` | `validate_installation` | ~202 | **Single** — comprehensive validation |
| 4 | `utilities/secrets-rotate.sh:129-309` | `do_rotate` | ~180 | **Multiple concerns** — backup, rotate, export, restart, verify |
| 5 | `setup.sh:230-395` | `show_post_install_summary` | ~165 | **Multiple concerns** — summary, status checks, recommendations |
| 6 | `utilities/setup-secrets.sh:1697-1855` | `_cmd_bootstrap` | ~158 | **Multiple concerns** — bootstrap, key gen, encryption, validation |
| 7 | `lib/crypto.sh:1276-1431` | `create_printable_key_backup` | ~155 | **Single** — generates printable backup |
| 8 | `utilities/backup-run.sh:437-586` | `sync_to_rclone` | ~150 | **Single** — remote sync |
| 9 | `utilities/setup-secrets.sh:1188-1332` | `create_breakglass_user` | ~144 | **Multiple concerns** — user creation, key gen, config |
| 10 | `utilities/backup-run.sh:829-957` | `perform_full_backup` | ~128 | **Single** — full backup creation |

---

## Part 10 — Usability

### Moderate

| # | Finding |
|---|---|
| 10-1 | **`make help` only partially separates dangerous targets.** Only `uninstall` is in the `⚠ DANGER ZONE` section (`Makefile:996-1008`). `clean-all` and `prune` remain in the normal `Cleanup` section (`Makefile:977-992`). Restore (which overwrites data) is also not flagged as dangerous. |
| 10-2 | **Uninstall dry-run is misleadingly labeled.** `Makefile:1007-1008` says `uninstall-dry-run: ## Show uninstall help (no dry-run mode available)` and just runs `--help`. However, `uninstall-vaultwarden.sh:27,39-41,88` explicitly supports `--dry-run`. The Makefile target description contradicts the script's capability. |
| 10-3 | **Backup "storage full" error messages are not actionable.** `backup-run.sh:273-275` → `"sqlite3 .backup failed for: $db_file"`; `backup-run.sh:802-805,936-939` → `"Encryption failed"` with stderr suppressed. Does not explain why (e.g., disk full) or what to do next. |
| 10-4 | **Health failure messages are too terse.** `maintenance-health.sh:323-328` → `"vaultwarden_app is unhealthy"`. No explanation of why or what to do next. |
| 10-5 | **No self-ban recovery guidance.** `dashboard.sh:401-417` prompts for IP to unban but on failure says only `"IP not found or cscli error."` Does not explain what happened, why, or how to recover if the admin banned themselves. |
| 10-6 | **Dashboard missing last backup result and timer schedule summary.** `dashboard.sh:223` shows last backup time but not the outcome (success/failure). Timer status is a menu action, not a summary widget. |

### Minor

| # | Finding |
|---|---|
| 10-7 | **Restore corruption messages only partially actionable.** `restore-run.sh:1722-1730` → `"Checksum MISMATCH — backup file may be corrupted or tampered."` Tells what happened but not what to do next (retry another backup, re-download, etc.). |
| 10-8 | **Maintenance lock messages lack next-step guidance.** `maintenance-run.sh:109,129` → `"Another operation is already running. Aborting."` Does not tell admin how to investigate or clear a stale lock. |
| 10-9 | **`make status` is brittle.** `Makefile:348-351` runs `docker compose ps` directly, which fails if no docker-compose.yml exists yet. |
| 10-10 | **CrowdSec uninstall over-deletes.** `uninstall-vaultwarden.sh:877-885` runs `rm -rf /etc/crowdsec` if the directory has content, despite comments saying unrelated content should be preserved. |

### Pass

- `make help` covers all 82 targets — none missing.
- `make status` target exists (`Makefile:348`).
- Uninstall offers to backup first (`uninstall-vaultwarden.sh:208-231`).
- Uninstall uses strong confirmation: `"Type 'UNINSTALL' to confirm"` (`uninstall-vaultwarden.sh:204-205`).
- CrowdSec metrics command is correct: `cscli metrics` (`dashboard.sh:427-428`).

---

## Prioritized Fix Backlog

| # | Severity | Part | File(s) | Finding | Effort |
|---|---|---|---|---|---|
| 1 | **Critical** | 6 / P1-#7 | `utilities/setup-crowdsec.sh` | CrowdSec bootstrap uses `curl \| bash` and unpinned `latest` versions | Medium |
| 2 | **Critical** | 5 / P1-#3 | `utilities/backup-run.sh` | Remote sidecar upload failures do not surface as partial-failure state | Low |
| 3 | **Critical** | 5 | `utilities/backup-run.sh` | Full/emergency backup silently includes `secrets/` directory (or docs are wrong about exclusion) | Low |
| 4 | **Critical** | 3 | `lib/email.sh` | SMTP password exposed in `curl` process argv | Low |
| 5 | **Critical** | 5, 8 | `docs/BACKUP-RESTORE.md`, `docs/DISASTER-RECOVERY.md` | Contradictory documentation about backup contents — junior admin will form wrong DR plan | Medium |
| 6 | **Moderate** | 3 | Multiple utilities | Lock paths differ across maintenance/health/backup — no single mutex | Medium |
| 7 | **Moderate** | 3 | `utilities/maintenance-health.sh`, `backup-run.sh` | Lock file `root:root 0660` permissions block non-root service users | Low |
| 8 | **Moderate** | 4 | `vaultwarden-db-backup.service`, `vaultwarden-full-backup.service` | Backup services lack `Requires=`/`Wants=` on health unit | Low |
| 9 | **Moderate** | 6 | `utilities/secrets-rotate.sh` | Secrets rotation is not atomic — services restart individually, no auto-rollback | Medium |
| 10 | **Moderate** | 6 | `utilities/setup-firewall.sh` | Cloudflare CIDR cache: no permissions, no TTL validation, no format validation | Medium |
| 11 | **Moderate** | 8 | `docs/OPERATIONS.md` | 6 inaccurate Make target / script behavior descriptions | Low |
| 12 | **Moderate** | 8 | `docs/SCRIPTS.md` | 5 wrong Make target behavior descriptions | Low |
| 13 | **Moderate** | 8 | `docs/DISASTER-RECOVERY.md` | 4 factual errors about backup contents and non-existent flags | Low |
| 14 | **Moderate** | 7 | `README.md` | No prominent "Start here" link; overloaded with content that belongs in docs | Low |
| 15 | **Moderate** | 10 | `Makefile` | `uninstall-dry-run` target description contradicts script's actual `--dry-run` support | Low |
| 16 | **Moderate** | 5 | `utilities/backup-run.sh` | Remote prune only runs via `rotate`, not during normal `run --rclone` | Low |
| 17 | **Moderate** | 5 | `utilities/pre-production-drill.sh` | Drill does not test full restore or validate restored service | Medium |
| 18 | **Moderate** | 10 | Multiple | Backup/health/restore error messages not actionable for junior admin | Medium |
| 19 | **Moderate** | 3 | `startup.sh`, 5 utility scripts | Missing EXIT and/or ERR trap declarations in entry-point scripts | Medium |
| 20 | **Moderate** | 4 | `vaultwarden-notify-failure.service` | Missing `DefaultDependencies=no` | Low |
| 21 | **Moderate** | 6 | `utilities/setup-crowdsec.sh` | Firewall bouncer enable failure silently ignored (`\|\| true`) | Low |
| 22 | **Moderate** | 10 | `Makefile` | `make help` does not comprehensively separate dangerous/destructive targets | Low |
| 23 | **Minor** | 8 | `docs/SECURITY.md` | Wrong CrowdSec bouncer service name (`cs-cloudflare-bouncer` → `crowdsec-cloudflare-bouncer`) ×2 | Low |
| 24 | **Minor** | 8 | `docs/DEPLOYMENT.md` | TLS prereq guidance says HTTP-01 but default is DNS-01 | Low |
| 25 | **Minor** | 8 | `docs/TROUBLESHOOTING.md` | Stale `--quick-verify` flag reference | Low |
| 26 | **Minor** | 3 | Multiple utilities | Lock FDs not explicitly closed in EXIT trap (works via process exit) | Low |
| 27 | **Minor** | 3 | `utilities/uninstall-vaultwarden.sh` | Unquoted `$(...)` in `for` loops for Docker volume/network listing | Low |
| 28 | **Minor** | 3 | `startup.sh` | Docker used before `command -v` prereq check | Low |
| 29 | **Minor** | 9 | 3 files | Health polling ("wait for container healthy") duplicated with divergent semantics | Low |
| 30 | **Minor** | 9 | Multiple | `PROJECT_STATE_DIR` / `DATA_VOLUME_MOUNT` default fallbacks scattered across 10+ files | Low |
| 31 | **Minor** | 10 | `utilities/uninstall-vaultwarden.sh` | CrowdSec uninstall `rm -rf /etc/crowdsec` can over-delete unrelated config | Low |
| 32 | **Minor** | 10 | `dashboard.sh` | Missing last backup result and timer schedule summary in dashboard overview | Low |

---

## Resolution Status

| Finding | Severity | Resolved In | Status |
|---------|----------|-------------|--------|
| C-1 CrowdSec bootstrap | Critical | PR #163 | ✅ Resolved |
| C-2 Sidecar partial-failure | Critical | PR #163 | ✅ Resolved |
| C-3 Secrets in backup | Critical | PR #163 | ✅ Resolved |
| C-4 SMTP argv exposure | Critical | PR #163 | ✅ Resolved |
| M-5/M-6 Lock infra | Moderate | This PR | ✅ Resolved (0660 with service group) |
| M-7 Systemd deps | Moderate | PR #163 | ✅ Resolved |
| M-8 Rotation atomicity | Moderate | N/A | ✅ Not applicable — secrets-rotate.sh (126 lines) contains no restart loop; the mapping exists but restart logic was never implemented |
| M-9 CIDR cache | Moderate | PR #163 | ✅ Resolved |
| M-14 dry-run target | Moderate | PR #163 | ✅ Resolved |
| M-15 Remote prune | Moderate | PR #163 | ✅ Resolved |
| M-16 Drill restore test | Moderate | This PR | ✅ Resolved (Phase A-4) |
| M-17 Error messages | Moderate | PR #163 | ✅ Resolved |
| M-18 ERR traps | Moderate | This PR | ✅ Resolved (moved after source calls) |
| M-19 DefaultDependencies | Moderate | PR #163 | ✅ Resolved |
| M-20 Bouncer enable | Moderate | PR #163 | ✅ Resolved |
| M-21 Makefile danger zone | Moderate | PR #163 | ✅ Resolved |
| m-25 Lock FD close | Minor | PR #163 | ✅ Resolved |
| m-26 Unquoted subshell | Minor | PR #163 | ✅ Resolved |
| m-27 Docker before prereq | Minor | PR #163 | ✅ Resolved |
| m-28 Health poll dedup | Minor | This PR | ✅ Resolved (Phase A-1) |
| m-29 Scattered defaults | Minor | This PR | ⚠️ Partial (3 high-risk files migrated; remaining deferred to follow-up) |
| m-30 CrowdSec over-delete | Minor | PR #163 | ✅ Resolved |
| m-31/m-32 Dashboard | Minor | This PR | ✅ Resolved (Phase A-3) |
| Docs (all 26 items) | Various | PR #163 | ✅ Resolved |
| COMMAND-REFERENCE.md | Infra | This PR | ✅ Resolved (Phase A-5) |
| Backup manifest array | Infra | This PR | ✅ Resolved (Phase A-6) |
| CHANGELOG.md | Infra | Manual | ⏳ Pending owner update |
