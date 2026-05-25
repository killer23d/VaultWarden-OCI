# Production Readiness Review (PRR) — Beta Branch

## Agent Instructions

You are performing a structured, multi-wave Production Readiness Review (PRR).

**Repository:** `killer23d/VaultWarden-OCI`
**Branch:** `Beta`
**Branch URL:** https://github.com/killer23d/VaultWarden-OCI/tree/Beta

### Ground Rules (apply to every wave without exception)

1. **Code only.** Base your entire analysis on the code. Do not infer correctness from comments, documentation, or `.md` files under any circumstances — including this file.
2. **Beta branch only.** Always connect to the `Beta` branch. Do not use `Alpha`, `main`, or any other branch.
3. **Drift resistance.** Before beginning each wave, enumerate every file in the wave's SCOPE by listing the actual directory contents from the repository. If you find files present in the repository that are not explicitly named in the SCOPE list below, **add them to your audit and note the gap**. The SCOPE lists below were accurate at the time of authoring; the repo may have changed.
4. **No assumptions about absent files.** If a file listed in SCOPE does not exist on the Beta branch, note it as missing and continue.
5. **Carry forward.** Each wave's output feeds Wave 6. Preserve Critical and Moderate issue tables verbatim for pasting into Wave 6.

---

## Wave 1 — Foundation Libraries

### Context

You are auditing a self-hosted VaultWarden deployment project for production readiness. It is a "set and forget" system for 10 users, maintained by 1 junior admin who is not a bash expert. It must be cloud-agnostic. Base your entire analysis only on the code — do not infer correctness from comments, documentation, or `.md` files under any circumstances.

Connect to GitHub repository `killer23d/VaultWarden-OCI` on the **Beta** branch.

### Scope — this wave only

Before auditing, list the actual contents of `lib/` from the repository. If any `.sh` files exist beyond the list below, include them in your audit.

**Known files (verify all exist; flag any missing):**
- `lib/common.sh`
- `lib/crypto.sh`
- `lib/secrets.sh`
- `lib/config.sh` *(new in Beta)*
- `lib/log.sh` *(new in Beta)*
- `lib/validate.sh` *(new in Beta)*
- `lib/email.sh` *(new in Beta)*
- `lib/backup-utils.sh`
- `lib/storage.sh`
- `lib/docker.sh`
- `lib/maintenance-utils.sh` *(new in Beta)*

> **Note:** `lib/backup-utils.sh`, `lib/storage.sh`, and `lib/docker.sh` are also covered in detail in Waves 2 and 3. Audit them for shell correctness here; defer deep functional analysis to those waves.

### 1. Shell Correctness & Safety — all lib/ files

- Is `set -euo pipefail` present at the top of each file? If absent, can a failed command silently continue execution?
- Are all variables quoted to handle paths with spaces or special characters?
- Are external commands (`openssl`, `gpg`, `jq`, `curl`, etc.) checked for existence with `command -v` before use?
- Is `eval` used anywhere? If so, is the input sanitized before being passed to it?
- Do any subshells or pipes swallow exit codes silently (e.g., `cmd | other` where `cmd` failure is hidden)?
- Are there any `|| true` patterns that suppress real errors?

### 2. Secrets & Cryptography — `lib/crypto.sh` and `lib/secrets.sh`

- Are secret values ever written to `/tmp`, temp files, or any log output — even partially or in debug mode?
- Are secrets ever passed as command-line arguments that would be visible in `ps aux`?
- What key derivation function (KDF) is used? Is it appropriate for a password manager context — i.e., PBKDF2, bcrypt, or argon2? A raw SHA hash is not acceptable here.
- Are IVs or nonces generated freshly per encryption operation, or is there any reuse?
- Are encrypted outputs authenticated (e.g., AES-GCM or AES-CBC + HMAC) or just encrypted without integrity verification?
- Are there any hardcoded keys, salts, or IVs anywhere in the code?
- Are temporary files used during crypto operations created with `mktemp` and mode `0600`? Are they securely wiped on exit?

### 3. Library Sourcing Safety — `lib/common.sh` and `lib/log.sh`

- Does `common.sh` export functions and variables safely when sourced by multiple parent scripts in the same shell session?
- Are there global variable names that could collide with environment variables a caller may already have set?
- Does `lib/log.sh` (or `common.sh` if it owns logging) define a consistent logging interface — timestamps, severity levels (INFO, WARN, ERROR), and a log file path — that all other lib files also use consistently? Or do individual lib files implement their own separate logging?
- Are there functions that silently return success even on failure to avoid breaking callers?
- Are there any functions defined in more than one lib file that do similar things under different names (duplicate logic)?
- Does `lib/config.sh` validate required configuration keys and fail loudly on missing or malformed values?
- Does `lib/validate.sh` cover all inputs used by crypto and secrets operations?
- Does `lib/email.sh` handle SMTP credential exposure — are credentials ever logged or passed as CLI arguments?

### 4. Cross-Library Consistency

- Does `lib/crypto.sh` call logging functions from `lib/common.sh` or `lib/log.sh`, or does it implement its own?
- Does `lib/secrets.sh` call logging functions from `lib/common.sh` or `lib/log.sh`, or does it implement its own?
- Are there naming inconsistencies — the same concept referred to by different variable or function names across the lib files?

### 5. Error Handling & Trap Handlers

- Does every function have explicit return code checks or a trap?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, and `TERM` signals in each file?
- If a function fails, does it produce an actionable plain-English error message, or just exit with a numeric code?

### Output Format

**Critical Issues** — table: `File | Line | Issue | Why It Matters | Suggested Fix`
**Moderate Issues** — same table format
**Minor Issues** — bulleted list
**What This Wave Passed** — briefly note what looked solid

---

## Wave 2 — Backup & Restore Pipeline

### Context

Production readiness audit. "Set and forget", 10 users, 1 junior admin, cloud-agnostic. Code only — never use `.md` files as evidence.

Connect to `killer23d/VaultWarden-OCI` on the **Beta** branch.

### Scope — this wave only

Before auditing, list the actual contents of `utilities/` and the root directory from the repository. If any backup- or restore-related files exist beyond the list below, include them.

**Known files (verify all exist; flag any missing):**
- `backup.sh` *(root — thin wrapper, check what it delegates to)*
- `restore.sh` *(root — thin wrapper, check what it delegates to)*
- `lib/backup-utils.sh`
- `lib/storage.sh`
- `utilities/backup-run.sh` *(new in Beta — likely the substantive backup implementation)*
- `utilities/restore-run.sh` *(new in Beta — likely the substantive restore implementation)*
- `utilities/setup-storage.sh` *(new in Beta — storage configuration)*

> **Note:** If `backup.sh` and `restore.sh` are thin wrappers that delegate to `utilities/backup-run.sh` and `utilities/restore-run.sh`, audit the utility files as the primary subjects and the wrappers for correct delegation.

### 1. Shell Correctness & Safety — all files in scope

- Is `set -euo pipefail` present at the top of each file?
- Are all variables quoted?
- Are external commands checked with `command -v` before use?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, and `TERM` in each file?
- Are there any `|| true` patterns suppressing real errors?

### 2. Backup Completeness & Correctness

- What backup formats and archive structures does the backup pipeline produce? List every output path and filename pattern it can generate.
- Does the restore pipeline handle every format and path that the backup pipeline can produce, including edge cases like interrupted backups or partial archives?
- Does the backup pipeline produce a checksum or GPG signature for each backup? Does the restore pipeline verify it **before** beginning restoration — not after?
- Can the backup produce an empty or zero-byte archive without detecting and reporting it as a failure?
- Are the VaultWarden database, attachments, and config all captured together atomically — or can a backup contain a newer DB with older attachments?

### 3. Concurrency & Locking

- Is there a lockfile or mutex preventing backup and restore from running simultaneously?
- If two backup jobs are triggered at the same time (e.g., cron or systemd timer overlap), is the second safely skipped or does it corrupt the first?
- Does the lock get released cleanly if the script is killed mid-run via `SIGTERM` or `SIGKILL`?

### 4. Failure State & Cleanup

- If backup fails mid-run, does it clean up partial archives, or do they accumulate on disk?
- If a backup upload to remote storage fails, is the local copy retained as a fallback?
- If restore fails mid-restore, is the previous working state preserved — or is the system left in a broken half-restored state?
- Does `lib/backup-utils.sh` have cleanup for partial operations on `EXIT`, `ERR`, `INT`, and `TERM`?

### 5. Retention & Rotation

- Are backup retention limits enforced consistently in both local and remote storage paths?
- Is there any risk of unbounded disk growth if rotation logic fails silently?
- Are old backups deleted only after new ones are confirmed valid?

### 6. Cloud-Agnostic Storage — `lib/storage.sh` and `utilities/setup-storage.sh`

- Does `lib/storage.sh` hard-code any OCI-specific storage endpoints, namespaces, or CLI commands (`oci` CLI)?
- Does `utilities/setup-storage.sh` hard-code any OCI-specific configuration, endpoints, or assumptions?
- Is the storage backend abstracted so it can be swapped to S3-compatible, local filesystem, or SFTP without modifying `backup.sh` or `restore.sh`?
- Are storage credentials handled securely — never logged, never passed as CLI arguments visible in `ps aux`?
- Does the storage layer validate that a remote upload actually succeeded — not just that the command exited 0?

### Output Format

**Critical Issues** — table: `File | Line | Issue | Why It Matters | Suggested Fix`
**Moderate Issues** — same table format
**Minor Issues** — bulleted list
**What This Wave Passed**

---

## Wave 3 — Setup, Startup & Runtime

### Context

Production readiness audit. "Set and forget", 10 users, 1 junior admin, cloud-agnostic. Code only — never use `.md` files as evidence.

Connect to `killer23d/VaultWarden-OCI` on the **Beta** branch.

### Scope — this wave only

Before auditing, list the actual contents of the `systemd/` directory and `utilities/` for setup-related files. Add any files found beyond the list below.

**Known files (verify all exist; flag any missing):**

Shell scripts:
- `setup.sh`
- `startup.sh`
- `lib/docker.sh`
- `utilities/setup-system.sh` *(new in Beta)*
- `utilities/setup-env.sh` *(new in Beta)*
- `utilities/setup-secrets.sh` *(new in Beta)*
- `utilities/setup-systemd.sh` *(new in Beta)*
- `utilities/setup-firewall.sh` *(new in Beta — replaces `utilities/setup-iptables.sh` from Alpha)*
- `utilities/setup-crowdsec.sh` *(new in Beta)*
- `utilities/smoke-test.sh` *(new in Beta)*
- `utilities/pre-production-drill.sh` *(new in Beta)*

Systemd units:
- `systemd/vaultwarden-health.service`
- `systemd/vaultwarden-health.timer`
- `systemd/vaultwarden-notify-failure.service`
- `systemd/vaultwarden-dns-update.service`
- `systemd/vaultwarden-dns-update.timer`
- `systemd/vaultwarden-firewall-update.service`
- `systemd/vaultwarden-firewall-update.timer`
- `systemd/vaultwarden-iptables.service`
- `systemd/vaultwarden-maintenance.service`
- `systemd/vaultwarden-maintenance.timer`
- `systemd/vaultwarden-db-backup.service`
- `systemd/vaultwarden-db-backup.timer`
- `systemd/vaultwarden-full-backup.service`
- `systemd/vaultwarden-full-backup.timer`

### 1. Shell Correctness & Safety — all shell scripts in scope

- Is `set -euo pipefail` present at the top of each file?
- Are all variables quoted?
- Are external commands checked with `command -v` before use?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, and `TERM`?

### 2. Idempotency — `setup.sh` and `utilities/setup-*.sh`

- Can each setup script be safely re-run on an already-configured system without data loss, duplicate Docker volumes, duplicate networks, or overwriting existing secrets?
- Do they check for existing state before creating resources — directories, networks, volumes, users, secrets?
- If re-run after a partial failure, do they resume safely or fail on already-created resources?
- Are there any operations that are destructive on re-run without an explicit warning?
- Does `utilities/setup-systemd.sh` safely handle already-installed unit files?
- Does `utilities/setup-firewall.sh` safely handle already-configured firewall rules?
- Does `utilities/setup-crowdsec.sh` safely handle an already-running CrowdSec instance?

### 3. Docker & Container Reliability — `lib/docker.sh`, `startup.sh`

- Does `startup.sh` handle the Docker daemon being unavailable?
- Are Docker volume mounts validated for existence before containers start?
- Are container health checks verified — not just running status, but actual `healthy` per `HEALTHCHECK` — before declaring VaultWarden ready?
- Is there retry logic with backoff for container start failures?
- Are image tags pinned (e.g., `vaultwarden/server:1.32.0`) or floating (`latest`)? Floating tags break reproducibility.
- Does `lib/docker.sh` distinguish between `running` and `healthy`?
- If VaultWarden's container crashes after startup, is it detected or does `startup.sh` exit successfully without knowing?

### 4. Cloud-Agnostic Compliance — setup scripts, `startup.sh`, `lib/docker.sh`

- Are there any hard-coded OCI metadata endpoint references (e.g., `169.254.169.254`), OCI CLI calls (`oci`), or OCI-specific filesystem paths (e.g., `/dev/oracleoci/`)?
- Does `setup.sh` or any `utilities/setup-*.sh` make assumptions about OS, instance shape, or block device layout specific to OCI?
- Are network interface names or IP detection methods generic rather than OCI VNIC-specific?
- Does `utilities/setup-firewall.sh` check whether `iptables` or `nftables` is available rather than assuming one?

### 5. Pre-Production Validation — `utilities/smoke-test.sh` and `utilities/pre-production-drill.sh`

- Does `utilities/smoke-test.sh` test VaultWarden's actual HTTP endpoint, not just container process existence?
- Does `utilities/pre-production-drill.sh` perform a full backup → restore → verify cycle and report pass/fail clearly?
- Are both scripts safe to run without modifying production data or state?
- Do both scripts exit with a non-zero code on failure, making them usable in CI/CD pipelines?

### 6. Systemd — all 14 unit and timer files

- Do all service units that can fail have `OnFailure=vaultwarden-notify-failure.service`? List any that are missing it.
- Do all timer units have `Persistent=true` so missed runs are caught up on next boot?
- Do the backup timers (`vaultwarden-db-backup.timer`, `vaultwarden-full-backup.timer`) and `vaultwarden-maintenance.timer` have schedules that cannot overlap? Is there a locking mechanism if they can?
- Does `vaultwarden-health.timer` fire frequently enough (e.g., every 5 minutes) and does `vaultwarden-health.service` test VaultWarden's actual HTTP endpoint — not just whether the container process exists?
- Does `vaultwarden-dns-update.service` handle failure gracefully — does it notify on failure and does its timer retry?
- Does `vaultwarden-iptables.service` conflict with or duplicate `utilities/setup-firewall.sh`? Which is authoritative?
- Do all service units set `Restart=on-failure` with a `RestartSec`? Do timer-triggered services correctly use `Type=oneshot`?
- Are `After=` and `Requires=` dependency chains correct — particularly that backup services depend on VaultWarden being healthy, not just running?
- Are all `ExecStart=` paths absolute?
- Is `TimeoutStartSec` set to a reasonable value for expected startup time?
- Does `vaultwarden-maintenance.service` prevent users from hitting VaultWarden mid-maintenance?

### Output Format

**Critical Issues** — table: `File | Line | Issue | Why It Matters | Suggested Fix`
**Moderate Issues** — same table format
**Minor Issues** — bulleted list
**What This Wave Passed**

---

## Wave 4 — Security, Secrets & Network

### Context

Production readiness audit. "Set and forget", 10 users, 1 junior admin, cloud-agnostic. Code only — never use `.md` files as evidence.

Connect to `killer23d/VaultWarden-OCI` on the **Beta** branch.

### Scope — this wave only

Before auditing, list the actual contents of `utilities/` (secrets-related files), `crowdsec/`, and root-level security scripts. Add any files found beyond the list below.

> **IMPORTANT — Beta architecture change:** The Beta branch has **replaced `fail2ban/`** with **CrowdSec** (`crowdsec/` directory and `utilities/setup-crowdsec.sh`). There is no `fail2ban/` directory on the Beta branch. All intrusion detection questions below must be applied to CrowdSec. If `fail2ban/` files are somehow present, flag them as stale/conflicting artifacts.

**Known files (verify all exist; flag any missing):**

Secrets management (new Beta structure):
- `utilities/secrets-edit.sh` *(replaces `edit-secrets.sh` from Alpha)*
- `utilities/secrets-rotate.sh` *(new in Beta)*
- `utilities/secrets-view.sh` *(new in Beta)*
- `utilities/secrets-list.sh` *(new in Beta)*
- `utilities/secrets-export-recovery-kit.sh` *(new in Beta)*
- `utilities/setup-secrets.sh` *(new in Beta — initial secrets setup)*

Network security:
- `utilities/setup-firewall.sh` *(new in Beta — replaces `utilities/setup-iptables.sh`)*

CrowdSec (replaces fail2ban):
- `crowdsec/acquis.yaml`
- `crowdsec/profiles.yaml`
- `crowdsec/crowdsec-cloudflare-bouncer.yaml.example`

### 1. Shell Correctness & Safety — all shell scripts in scope

- Is `set -euo pipefail` present in each shell script?
- Are all variables quoted?
- Are external commands checked with `command -v` before use?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, and `TERM` in each?

### 2. Secrets Editing & Management — `utilities/secrets-edit.sh` and `utilities/secrets-rotate.sh`

- Is `HISTFILE=/dev/null` or equivalent set to prevent secret values from appearing in shell history?
- Are temp files for editing created with `mktemp` at mode `0600`?
- Does `secrets-edit.sh` prevent editor swap files (`.swp`, `.swo`, `~` backup files) from being written to readable locations?
- After editing, are temp files securely wiped (`shred` or `rm -P`) rather than just `rm`?
- If the editor exits non-zero (user aborted), are changes safely discarded?
- Does `secrets-rotate.sh` rotate secrets atomically — i.e., does it update all dependent services before removing the old secret, avoiding a window where services have mismatched credentials?
- Does `secrets-rotate.sh` create a backup of existing secrets before rotation?
- Does `utilities/secrets-export-recovery-kit.sh` encrypt the exported kit? What format? Is it safe to store or email?
- Does `utilities/secrets-view.sh` avoid writing viewed secrets to any log or temp file?
- Does `utilities/setup-secrets.sh` check for existing secrets before overwriting them?

### 3. Network Security — `utilities/setup-firewall.sh`

- Do the rules persist across reboots via `iptables-save`, `netfilter-persistent`, or equivalent?
- Is the default policy `DROP` or `REJECT` for `INPUT` and `FORWARD` chains, with explicit `ACCEPT` rules only for needed ports?
- Are rules applied in a safe order — no risk of locking out SSH if the script fails midway?
- Does the script check whether `iptables` or `nftables` is available rather than assuming one?
- Is IPv6 (`ip6tables`) handled, or only IPv4?
- Is there any OCI-specific IP range or interface assumption hard-coded?

### 4. CrowdSec Configuration — `crowdsec/acquis.yaml`, `crowdsec/profiles.yaml`, `crowdsec/crowdsec-cloudflare-bouncer.yaml.example`

- Does `crowdsec/acquis.yaml` reference log sources using paths or container names that are hard-coded to OCI-specific paths? Are the paths configurable?
- Does `crowdsec/acquis.yaml` cover VaultWarden's actual Docker log output — not just a generic log path?
- Does `crowdsec/profiles.yaml` define escalation thresholds appropriate for 10 legitimate users — not so aggressive that a user with a typo gets permanently banned?
- Is there an allowlist (equivalent to fail2ban's `ignoreip`) protecting the admin's IP from self-lockout?
- Does `crowdsec/crowdsec-cloudflare-bouncer.yaml.example` store the Cloudflare API token securely — never hard-coded in the file, never logged?
- Is the Cloudflare bouncer **optional** (configurable) or a hard dependency — would the deployment fail or be unprotected without Cloudflare?
- Does `utilities/setup-crowdsec.sh` handle the case where CrowdSec's API service is unavailable gracefully?
- Is there a fallback ban mechanism (e.g., `iptables` bouncer) if the Cloudflare bouncer is not configured?
- Does the CrowdSec setup correctly integrate with the Caddy reverse proxy for log acquisition?

### 5. CrowdSec vs. Fail2ban — Architecture Gap Check

Since Beta replaced fail2ban with CrowdSec, verify no fail2ban artifacts remain:
- Are there any references to fail2ban in shell scripts, systemd units, the Makefile, or compose files?
- Are there any systemd units for fail2ban that were not removed?
- Are `.env.example` or `docker-compose.yml.example` files still referencing fail2ban services or volumes?

### Output Format

**Critical Issues** — table: `File | Line | Issue | Why It Matters | Suggested Fix`
**Moderate Issues** — same table format
**Minor Issues** — bulleted list
**Cloud-Agnostic Gap Report for this wave** — table: `File | Line | Cloud-Specific Reference | Generic Alternative Exists?`
**What This Wave Passed**

---

## Wave 5 — Admin Experience, Caddy & Operational Completeness

### Context

Production readiness audit. "Set and forget", 10 users, 1 junior admin (not a bash expert), cloud-agnostic. Code only — never use `.md` files as evidence. Evaluate this wave through the lens of a non-technical admin who needs to operate this system confidently without fear of breaking things.

Connect to `killer23d/VaultWarden-OCI` on the **Beta** branch.

### Scope — this wave only

Before auditing, list the actual contents of the root directory and `utilities/` for admin-experience files. Add any files found beyond the list below.

**Known files (verify all exist; flag any missing):**

Admin experience:
- `Makefile`
- `maintenance.sh`
- `dashboard.sh` *(new in Beta)*
- `utilities/maintenance-run.sh` *(new in Beta)*
- `utilities/maintenance-update.sh` *(new in Beta)*
- `utilities/maintenance-health.sh` *(new in Beta)*
- `utilities/maintenance-email.sh` *(new in Beta)*
- `utilities/maintenance-db-maint.sh` *(new in Beta)*
- `utilities/uninstall-vaultwarden.sh`

Configuration:
- `.env.example`
- `docker-compose.yml.example`
- `docker-compose.override.dev.yml.example`

Caddy:
- `caddy/Caddyfile`
- `caddy/Caddyfile.degraded`
- `caddy/entrypoint.sh`
- `caddy/Dockerfile` *(new in Beta)*

### 1. Shell Correctness & Safety — all shell scripts in scope

- Is `set -euo pipefail` present in each?
- Are all variables quoted?
- Are external commands checked with `command -v` before use?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, and `TERM` in each?

### 2. Makefile as the Admin Control Panel

- Does a `help` target exist that lists and describes every available target in plain English?
- Are destructive targets (`uninstall`, `wipe`, `purge`, `rotate`) visually separated from routine targets and labelled with danger warnings in help output?
- Are target names self-explanatory without reading the recipe?
- Do targets provide feedback while running, or is the terminal silent until completion or failure?
- Is there a `make status` target showing: is VaultWarden running, when was the last backup, are there active CrowdSec bans?
- Are `.PHONY` declarations present for all non-file targets?
- Are there any OCI-specific assumptions in Makefile targets or variables?
- Do any Makefile targets expose dangerous operations without a confirmation step?
- Is there a `make schedule` or equivalent showing all automated tasks and when they run — so the admin understands what the system does on its own?

### 3. Dashboard — `dashboard.sh` *(new in Beta)*

- Does `dashboard.sh` expose any secret values in its output (terminal or log)?
- Does it show VaultWarden health status, last backup time, and CrowdSec ban status in a single view?
- If a dependency (Docker, CrowdSec, etc.) is unavailable, does it degrade gracefully rather than crash?
- Is its output human-readable without technical knowledge?
- Does it require root or special privileges? Is this necessary and documented?

### 4. Maintenance — `maintenance.sh` and `utilities/maintenance-*.sh`

- Does the maintenance pipeline print a plain-English description of every action as it runs — with timestamps?
- If a maintenance step fails, does it skip and continue with a clear warning, or abort the entire run?
- Are maintenance operations logged to a persistent file a junior admin can review afterward?
- Is there a `--dry-run` mode showing what would be done without doing it?
- Does the pipeline handle VaultWarden being offline during maintenance — skipping container-dependent steps gracefully?
- Is `maintenance.sh` a thin wrapper around `utilities/maintenance-run.sh`? If so, audit the utility as the primary subject.
- Does `utilities/maintenance-update.sh` verify the new image's health before completing the update — not just pulling and restarting?
- Does `utilities/maintenance-db-maint.sh` create a backup before running database operations?
- Does `utilities/maintenance-email.sh` handle SMTP failures gracefully without crashing the maintenance run?

### 5. Uninstall — `utilities/uninstall-vaultwarden.sh`

- Does it show an explicit list of what will be deleted before deleting anything?
- Is there a strong interactive confirmation prompt (e.g., `Type YES to confirm`) rather than just `[y/N]`?
- Is there a `--dry-run` flag showing what would be removed without removing it?
- Does it offer the admin an option to export or backup data before destruction?
- Are Docker volumes, networks, images, systemd units, CrowdSec configs, and firewall rules all cleanly removed, or are orphaned resources left behind?

### 6. Configuration — `.env.example`, `docker-compose.yml.example`, `docker-compose.override.dev.yml.example`

- Does every variable in `.env.example` have a plain-English comment explaining what it does, valid values, and whether it is required or optional?
- Are any variables consumed by setup or startup scripts missing from `.env.example`?
- Does `docker-compose.yml.example` contain OCI-specific volume driver, network, or logging configuration that would fail on non-OCI infrastructure?
- Are image tags pinned or floating (`latest`) in the compose files?
- Does `docker-compose.override.dev.yml.example` contain settings that could accidentally be applied in production?
- Does `docker-compose.yml.example` include a CrowdSec service definition, or is CrowdSec deployed separately? Is this consistent with `utilities/setup-crowdsec.sh`?

### 7. Caddy Reverse Proxy — `caddy/Caddyfile`, `caddy/Caddyfile.degraded`, `caddy/entrypoint.sh`, `caddy/Dockerfile`

**`caddy/Dockerfile`** *(new in Beta)*:
- Does it use a pinned Caddy base image tag or `latest`?
- Does it add any custom plugins? If so, are they from trusted sources?
- Does the build expose any secrets or credentials in `ENV` or `ARG` layers?

**`caddy/entrypoint.sh`**:
- Is `set -euo pipefail` present?
- Are all variables quoted and external commands checked?
- Are trap handlers set for `EXIT`, `ERR`, `INT`, `TERM`?
- Does it log actions in plain English as it runs?

**`caddy/Caddyfile`**:
- Are TLS 1.0 and 1.1 explicitly disabled with a minimum of TLS 1.2 enforced?
- Are these security headers present: `X-Frame-Options SAMEORIGIN`, `X-Content-Type-Options nosniff`, `Strict-Transport-Security` with `includeSubDomains` and `preload`, `Referrer-Policy`, `Content-Security-Policy`?
- Is the domain name hard-coded or read from an environment variable — making it portable to any cloud or domain?
- Are there OCI-specific DNS challenge provider configurations for TLS certificate issuance?
- Does the config correctly proxy WebSocket connections required for VaultWarden's real-time sync?
- Is there a health-check endpoint that `vaultwarden-health.service` can probe?
- Is there any CrowdSec bouncer integration (e.g., Caddy CrowdSec plugin)? If so, is it correctly configured?

**`caddy/Caddyfile.degraded`**:
- What does degraded mode serve — a maintenance page, partial VaultWarden, or a static error? Is this clear from the code alone?
- What triggers the switch to `Caddyfile.degraded` — automatic health check failure or manual admin action? Is the mechanism in the code or scripts?
- Does `Caddyfile.degraded` still enforce HTTPS and all security headers, or do they silently drop when in degraded mode?
- Does degraded mode expose any internal paths or admin endpoints that the primary config blocks?
- Does the switch mechanism notify the admin that degraded mode was activated?

### 8. Timer Schedule Cross-Check

Across `vaultwarden-db-backup.timer`, `vaultwarden-full-backup.timer`, and `vaultwarden-maintenance.timer` (from Wave 3) — cross-check whether the `Makefile` or compose files expose or document these schedules to the admin. Can the junior admin tell when automated tasks will run without reading systemd unit files directly? Does `dashboard.sh` surface this information?

### Output Format

**Executive Summary** — 4–5 sentences written for a non-technical admin: is this safe to run unsupervised?
**Critical Issues** — table: `File | Line | Issue | Why It Matters | Suggested Fix`
**Moderate Issues** — same table format
**Minor Issues / UX Improvements** — bulleted list
**Cloud-Agnostic Gap Report** — table: `File | Line | Cloud-Specific Reference | Generic Alternative Exists?`
**Overall Production Readiness Verdict** — 🔴 Not Ready / 🟡 Conditionally Ready / 🟢 Ready with reasoning

---

## Wave 6 — Synthesis (Final Thread)

I have completed a 5-wave production readiness audit on a self-hosted VaultWarden deployment (`killer23d/VaultWarden-OCI`, **Beta** branch). This is a "set and forget" system for 10 users, maintained by 1 junior admin, and must be cloud-agnostic.

The Beta branch has been substantially refactored from Alpha:
- `fail2ban/` has been **replaced** by CrowdSec (`crowdsec/` + `utilities/setup-crowdsec.sh`)
- `utilities/` has been **expanded** from ~3 files to 25+ files with a modular setup and maintenance pipeline
- `lib/` has **new libraries**: `config.sh`, `log.sh`, `validate.sh`, `email.sh`, `maintenance-utils.sh`
- `dashboard.sh` is **new**
- `caddy/` now includes a `Dockerfile`

Below are the Critical and Moderate issues tables from all five waves. Perform the following:

1. Remove exact duplicates
2. Merge related issues that affect the same root cause
3. Rank all remaining issues by risk severity — highest risk first
4. For each issue retain: Wave number, File, Line, Issue summary, and Why it matters
5. Produce a **Prioritized Fix List** — numbered, in order, that the junior admin hands to Copilot Agent one item at a time
6. Produce a final **Production Readiness Verdict**: 🔴 Not Ready / 🟡 Conditionally Ready / 🟢 Ready with a 3-sentence explanation written for a non-technical admin
7. Produce a **Cloud-Agnostic Master Gap Table** consolidating all OCI and Cloudflare-specific dependencies found across all waves, noting whether a generic alternative already exists in the code
8. Produce a **Beta Architecture Change Risk Assessment**: for each major component replaced or restructured in Beta (CrowdSec replacing fail2ban, modular utilities pipeline, new lib files), note whether the replacement introduces new risks or leaves coverage gaps compared to Alpha

**[Paste Critical and Moderate tables from Waves 1–5 here before submitting this wave]**

---

## File Coverage Map (Beta Branch — as of authoring)

Use this as a checklist. If files exist in the repo that are **not** listed here, they must be assigned to a wave.

### Root
| File | Wave |
|---|---|
| `backup.sh` | 2 |
| `restore.sh` | 2 |
| `dashboard.sh` | 5 |
| `edit-secrets.sh` | ⚠️ Verify — may be absent on Beta; replaced by `utilities/secrets-edit.sh` |
| `maintenance.sh` | 5 |
| `setup.sh` | 3 |
| `startup.sh` | 3 |
| `.env.example` | 5 |
| `docker-compose.yml.example` | 5 |
| `docker-compose.override.dev.yml.example` | 5 |
| `Makefile` | 5 |
| `VERSION` | N/A |
| `CHANGELOG.md` | Excluded (docs) |
| `README.md` | Excluded (docs) |
| `RUNBOOK.md` | Excluded (docs) |
| `.gitignore` | N/A |
| `.gitattributes` | N/A |

### `lib/`
| File | Wave |
|---|---|
| `lib/common.sh` | 1 |
| `lib/crypto.sh` | 1 |
| `lib/secrets.sh` | 1 |
| `lib/config.sh` | 1 |
| `lib/log.sh` | 1 |
| `lib/validate.sh` | 1 |
| `lib/email.sh` | 1 |
| `lib/backup-utils.sh` | 1 (shell safety), 2 (functional) |
| `lib/storage.sh` | 1 (shell safety), 2 (functional) |
| `lib/docker.sh` | 1 (shell safety), 3 (functional) |
| `lib/maintenance-utils.sh` | 1 (shell safety), 5 (functional) |

### `caddy/`
| File | Wave |
|---|---|
| `caddy/Caddyfile` | 5 |
| `caddy/Caddyfile.degraded` | 5 |
| `caddy/entrypoint.sh` | 5 |
| `caddy/Dockerfile` | 5 |

### `crowdsec/`
| File | Wave |
|---|---|
| `crowdsec/acquis.yaml` | 4 |
| `crowdsec/profiles.yaml` | 4 |
| `crowdsec/crowdsec-cloudflare-bouncer.yaml.example` | 4 |

### `systemd/`
| File | Wave |
|---|---|
| `systemd/vaultwarden-health.service` | 3 |
| `systemd/vaultwarden-health.timer` | 3 |
| `systemd/vaultwarden-notify-failure.service` | 3 |
| `systemd/vaultwarden-dns-update.service` | 3 |
| `systemd/vaultwarden-dns-update.timer` | 3 |
| `systemd/vaultwarden-firewall-update.service` | 3 |
| `systemd/vaultwarden-firewall-update.timer` | 3 |
| `systemd/vaultwarden-iptables.service` | 3 |
| `systemd/vaultwarden-maintenance.service` | 3 |
| `systemd/vaultwarden-maintenance.timer` | 3 |
| `systemd/vaultwarden-db-backup.service` | 3 |
| `systemd/vaultwarden-db-backup.timer` | 3 |
| `systemd/vaultwarden-full-backup.service` | 3 |
| `systemd/vaultwarden-full-backup.timer` | 3 |

### `utilities/`
| File | Wave |
|---|---|
| `utilities/backup-run.sh` | 2 |
| `utilities/restore-run.sh` | 2 |
| `utilities/setup-storage.sh` | 2 |
| `utilities/setup-system.sh` | 3 |
| `utilities/setup-env.sh` | 3 |
| `utilities/setup-secrets.sh` | 3, 4 |
| `utilities/setup-systemd.sh` | 3 |
| `utilities/setup-firewall.sh` | 3, 4 |
| `utilities/setup-crowdsec.sh` | 3, 4 |
| `utilities/smoke-test.sh` | 3 |
| `utilities/pre-production-drill.sh` | 3 |
| `utilities/secrets-edit.sh` | 4 |
| `utilities/secrets-rotate.sh` | 4 |
| `utilities/secrets-view.sh` | 4 |
| `utilities/secrets-list.sh` | 4 |
| `utilities/secrets-export-recovery-kit.sh` | 4 |
| `utilities/maintenance-run.sh` | 5 |
| `utilities/maintenance-update.sh` | 5 |
| `utilities/maintenance-health.sh` | 5 |
| `utilities/maintenance-email.sh` | 5 |
| `utilities/maintenance-db-maint.sh` | 5 |
| `utilities/maintenance-update-dns.sh` | 5 |
| `utilities/maintenance-update-firewall.sh` | 5 |
| `utilities/uninstall-vaultwarden.sh` | 5 |

### `docs/`
Excluded — contains only `.md` files. Do not audit.

---

*This PRR document was generated for the Beta branch (`0f8abaf`) of `killer23d/VaultWarden-OCI`. If the branch has advanced since authoring, the drift-resistance instructions in each wave's Scope section govern.*
