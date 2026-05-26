# Final Pre-Production Audit — VaultWarden-OCI Beta Branch
# Audit ID: AUDIT-BETA-FINAL-01

## Repository
- **Repo:** `killer23d/VaultWarden-OCI`
- **Branch:** `Beta`  
- **Branch URL:** https://github.com/killer23d/VaultWarden-OCI/tree/Beta
- **Commit to audit:** read live from Beta HEAD
- **Scale:** ~30,000 lines across ~92 tracked files
- **Prior audit:** `PRR-Beta-Findings.md` (on Beta branch) — all 9 prioritized
  fixes from that report have been applied. You must re-verify each one.

## Target Profile (never forget this context)
- **Users:** 10 people sharing one VaultWarden instance
- **Admin:** 1 junior admin — not a bash expert, not a sysadmin by training
- **Operating model:** "set and forget" — once deployed, the system must
  self-maintain, self-alert, and be operable via `make` commands and the docs
  without reading source code
- **Infrastructure:** cloud-agnostic (must work on any Linux host, not just OCI)

## Your Mandate
This is the **final audit before production**. You are not looking for things
to improve — you are looking for things that will **break, mislead, or
endanger the junior admin**. Every finding must meet this bar:
> "A junior admin following this code or documentation, without any prior
> context, would either fail silently, destroy data, lock themselves out, or
> reach a broken state."

Findings that do not meet this bar are **Minor** and must be labelled as such.
Do not inflate severity.

---

## Audit Anchor

Before beginning Part 0, read the HEAD commit SHA of the Beta branch and
record it at the top of your findings document. Every finding is relative
to this SHA. If the branch advances during your audit session, note it and
flag any files that may have changed.

Format: `Commit audited: <SHA> (<short message>)`

---

## Part 0 — File Inventory & Drift Check

Before auditing any section:

1. List the ACTUAL contents of every directory by reading the repository
   directly. Do not rely on the expected file list below to determine what
   exists — the repository is the ground truth.

2. The expected file list is a HINT, not a contract. Compare actual contents
   against it in both directions:
   - Files in the expected list but ABSENT from the repo → flag as [MISSING]
   - Files in the repo but NOT in the expected list → flag as [NEW — UNAUDITED]
     and assign them to the most relevant audit Part automatically.

3. If any directory cannot be read, STOP and report the failure. Do not
   proceed with assumptions about what the directory contains.

### Expected Files

**Root:** `.env.example`, `.gitattributes`, `.gitignore`, `CHANGELOG.md`,
`Makefile`, `PRR-Beta-Findings.md`, `PRR-Beta.md`, `README.md`, `RUNBOOK.md`,
`VERSION`, `backup.sh`, `dashboard.sh`,
`docker-compose.override.dev.yml.example`, `docker-compose.yml.example`,
`edit-secrets.sh`, `maintenance.sh`, `restore.sh`, `setup.sh`, `startup.sh`

**lib/:** `backup-utils.sh`, `common.sh`, `config.sh`, `crypto.sh`,
`docker.sh`, `email.sh`, `log.sh`, `maintenance-utils.sh`, `secrets.sh`,
`storage.sh`, `validate.sh`

**utilities/:** `README.md`, `backup-run.sh`, `maintenance-db-maint.sh`,
`maintenance-email.sh`, `maintenance-health.sh`, `maintenance-run.sh`,
`maintenance-update-dns.sh`, `maintenance-update-firewall.sh`,
`maintenance-update.sh`, `pre-production-drill.sh`, `restore-run.sh`,
`secrets-edit.sh`, `secrets-export-recovery-kit.sh`, `secrets-list.sh`,
`secrets-rotate.sh`, `secrets-view.sh`, `setup-crowdsec.sh`, `setup-env.sh`,
`setup-firewall.sh`, `setup-secrets.sh`, `setup-storage.sh`, `setup-system.sh`,
`setup-systemd.sh`, `smoke-test.sh`, `uninstall-vaultwarden.sh`

**caddy/:** `Caddyfile`, `Caddyfile.degraded`, `Dockerfile`, `entrypoint.sh`

**crowdsec/:** `acquis.yaml`, `profiles.yaml`,
`crowdsec-cloudflare-bouncer.yaml.example`

**systemd/:** `vaultwarden-db-backup.service`, `vaultwarden-db-backup.timer`,
`vaultwarden-dns-update.service`, `vaultwarden-dns-update.timer`,
`vaultwarden-firewall-update.service`, `vaultwarden-firewall-update.timer`,
`vaultwarden-full-backup.service`, `vaultwarden-full-backup.timer`,
`vaultwarden-health.service`, `vaultwarden-health.timer`,
`vaultwarden-iptables.service`, `vaultwarden-maintenance.service`,
`vaultwarden-maintenance.timer`, `vaultwarden-notify-failure.service`

**docs/:** `ADVANCED-CUSTOMIZATION.md`, `API.md`, `BACKUP-RESTORE.md`,
`BOOTSTRAP_KEY_RECOVERY.md`, `CONFIGURATION.md`, `DEPLOYMENT.md`,
`DISASTER-RECOVERY.md`, `EMAIL.md`, `MIGRATION.md`, `OPERATIONS.md`,
`SCRIPTS.md`, `SECURITY.md`, `TROUBLESHOOTING.md`, `VOLUME-MIGRATION.md`

---

## Evidence Standard (applies to every finding and every Pass verdict)

Every finding must include a direct quote of the relevant code line(s),
not just a file:line reference. A Pass verdict on any PRR re-verification
item requires quoting the exact line that implements the fix.

Acceptable evidence:
  setup-systemd.sh:247  →  SERVICE_USER="$(id -un "${resolved_uid}")"

Unacceptable evidence:
  setup-systemd.sh:247  →  "dynamic user resolution confirmed"

If you cannot locate the implementing line, the verdict is FAIL, not Pass.

---

## Hallucination Prevention

This audit will be used to make a production go/no-go decision. False
positives (reporting a bug that does not exist) waste time. False negatives
(reporting a fix as confirmed when it is not) can cause production failures.

If you are uncertain whether a fix is present, report it as UNCERTAIN with
the closest relevant code you found, and explain what you expected to see
vs. what you actually found. Do not guess.

Never write "appears to be fixed", "likely correct", or "should work" in
a Pass verdict. Only write Pass when you have quoted the implementing code.

---

## Part 1 — PRR Fix Re-Verification

The following 9 fixes were mandated by `PRR-Beta-Findings.md`. For each one,
confirm it is **actually implemented** in the current code with a file + line
citation. A fix is **NOT verified** if it is only mentioned in a comment or
documented but not implemented.

| # | PRR Fix | Pass/Fail | Evidence (file:line) |
|---|---|---|---|
| 1 | Maintenance/backup/health lock moved from `/tmp/.vw_maintenance.lock` to `/run/lock/` path using `flock` on an open FD | | |
| 2 | `User=ubuntu`/`Group=ubuntu` removed from all systemd unit files; `setup-systemd.sh` no longer falls back to `ubuntu` hardcode | | |
| 3 | Remote `.meta`/`.sha256` sidecar upload failures surface as partial-failure state (not silently swallowed with `\|\| true`) | | |
| 4 | Remote retention pruning added to mirror local backup retention policy | | |
| 5 | Cloudflare CIDR fetch changed from fail-open (broadening rules on failure) to cached/fail-closed behavior | | |
| 6 | `.env` mutations in `lib/config.sh` use atomic temp-file + `mv` pattern | | |
| 7 | CrowdSec bootstrap no longer uses live `curl \| bash` / `latest` installers; versions are pinned | | |
| 8 | Full-backup / full-restore scope gap explicitly documented in `docs/BACKUP-RESTORE.md` | | |
| 9 | Minimum TLS version set explicitly in both `caddy/Caddyfile` and `caddy/Caddyfile.degraded` | | |

Any fix marked **Fail** becomes a **Critical** finding in the relevant Part
below and is treated as unresolved.

---

## Part 2 — Command, Subcommand & Argument Validity

This is the most important new section in this audit. A wrong command name is
caught by shellcheck; a right command name with a wrong flag or subcommand is
**not** caught by shellcheck and will only fail at runtime — often silently.

### Methodology
Read every `.sh` file in `lib/`, `utilities/`, and the root. For every
external command invocation, verify:

1. **The subcommand/verb exists** — e.g., `rclone deletefile` vs `rclone
   deletefile` (does this subcommand exist in rclone?)
2. **Every flag is valid for that subcommand** — e.g., `docker inspect
   --format` is valid; `docker inspect --template` is not
3. **Required positional arguments are present** — e.g., `systemctl enable`
   requires a unit name
4. **Mutually exclusive flags are not combined**
5. **Deprecated flags that have been removed** — e.g., `docker-compose`
   (v1 CLI) vs `docker compose` (v2 plugin); `iptables --insert` vs
   `iptables -I`

### Commands to validate exhaustively (check every call site)

| Command | Validate these specifically |
|---|---|
| `docker` | `inspect --format`, `compose up/down/pull`, `exec`, `logs --tail`, `ps --filter`, `stats --no-stream`, `volume ls --filter`, `network ls` |
| `docker compose` | `up -d`, `down --volumes`, `pull`, `exec`, `ps --format`, `logs`, `config` |
| `systemctl` | `is-active`, `is-enabled`, `enable --now`, `disable --now`, `daemon-reload`, `restart`, `status`, `show -p` |
| `rclone` | ALL subcommands used — `copy`, `sync`, `ls`, `lsf`, `delete`, `deletefile`, `purge`, `about`, `size` — verify each exists and flags are valid for that subcommand |
| `cscli` | ALL subcommands — `decisions add`, `decisions delete`, `decisions list`, `alerts list`, `bouncers list`, `machines list`, `metrics`, `hub update`, `collections install` — verify CrowdSec v1.x CLI syntax |
| `openssl` | `enc`, `dgst`, `rand`, `pkeyutl`, `genrsa`, `req` — verify cipher names, flag names (`-aes-256-cbc` vs `-aes256`), `-pbkdf2` availability |
| `age` / `age-keygen` | verify flag syntax for the version of age expected |
| `sops` | `--decrypt`, `--encrypt`, `--rotate`, `--in-place`, `--config` — verify against sops v3.x syntax |
| `iptables` / `ip6tables` | `-A`, `-I`, `-D`, `-F`, `-P`, `--dport`, `-m state`, `-m conntrack`, `-j` targets |
| `curl` | `--fail-with-body` (added in curl 7.76; check if older fallback is needed), `--retry`, `--connect-timeout`, `--max-time`, `-H`, `-o`, `-s`, `-L` |
| `jq` | filter syntax validity — `.foo.bar`, `select()`, `has()`, `keys`, `to_entries`, `from_entries`, `@base64d` |
| `sqlite3` | pragma syntax, `.backup` command syntax |
| `make` | any self-referential `$(MAKE)` sub-invocations |
| `netfilter-persistent` | `save`, `reload` — not `restart` which is not a valid action |
| `nc` / `ncat` | flag differences between BSD netcat, GNU netcat, and ncat |

### Output format for this section

**Command Validity Failures** — table:
`File | Line | Command | Invalid Usage | Correct Usage | Severity`

Severity:
- **Critical** = will fail at runtime, breaks a core operation (backup,
  restore, lock, health check)
- **Moderate** = will fail at runtime, breaks a secondary operation
- **Minor** = syntactically valid but non-portable or deprecated

---

## Part 3 — Shell Script Safety & Correctness

### 3a — Structural Safety (all `.sh` files)

For each file, verify:
- `set -euo pipefail` present at top (or justified absence documented)
- All variable expansions quoted — `"${VAR}"` not `$VAR` in contexts where
  word-splitting can occur
- No `|| true` suppressing a genuinely fatal error (distinguish from
  intentional soft-fail with logged warning)
- Trap handlers for `EXIT` and `ERR` present in all entry-point scripts
  (not required in lib files that are only sourced)
- `command -v` checks for external tools before first use
- No use of `eval` on unvalidated input

### 3b — Locking & Concurrency (post-PRR verification)

Verify the flock-based locking is implemented correctly:
- Is the lock acquired on an **open file descriptor** (e.g.,
  `exec 9>/run/lock/vw.lock && flock -n 9`) rather than `flock path command`
  (which can lose the lock when the subcommand exits)?
- Is the FD closed / lock released in the `EXIT` trap, not just at
  script end?
- Do ALL of the following acquire the SAME lock path:
  `utilities/maintenance-run.sh`,
  `utilities/maintenance-db-maint.sh`,
  `systemd/vaultwarden-health.service` (via its ExecStart script),
  `systemd/vaultwarden-db-backup.service` (via its ExecStart script),
  `systemd/vaultwarden-full-backup.service` (via its ExecStart script)?
- Can a non-root user running a maintenance script and a systemd service
  running as the service user both acquire the same lock (i.e., are
  permissions on `/run/lock/` compatible)?

### 3c — Secret Exposure Paths

For every script that handles secrets (any file sourcing `lib/secrets.sh` or
`lib/crypto.sh`):
- Are secrets ever passed as positional arguments to external commands
  (visible in `ps aux`)?
- Are secrets ever written to a log file (check all `log_*` call sites near
  secret-handling code)?
- Are temp files containing secrets created with `mktemp` and mode `0600`?
  Are they cleaned up in the `EXIT` trap?
- Does `utilities/secrets-view.sh` output to stdout only, never to a file
  or log?

### 3d — Atomic Write Verification (post-PRR)

Confirm the atomic `.env` update is implemented correctly:
- Is the temp file created in the **same directory** as the target `.env`
  file (required for atomic `mv` on a single filesystem)?
- Is `chmod` called to match the original file's permissions before `mv`?
- If `mktemp` is used, is the default `0600` permission acceptable, or does
  the `.env` file need to be readable by the Docker daemon user?

---

## Part 4 — Systemd Units Complete Audit

For all 14 files in `systemd/`:

### 4a — Hardening Directives Consistency
For every `.service` file, record which of these are present:
`PrivateTmp=`, `ProtectSystem=`, `NoNewPrivileges=`, `ProtectHome=`,
`RestrictSUIDSGID=`, `CapabilityBoundingSet=`, `AmbientCapabilities=`

Produce a matrix table. Flag any service that is missing directives that
all others have, with a justification check (does it genuinely need the
capability?).

### 4b — Dependency Chain Correctness
- Do backup services (`vaultwarden-db-backup.service`,
  `vaultwarden-full-backup.service`) declare `After=` and `Requires=` or
  `Wants=` on the VaultWarden container being healthy — not just running?
- Does `vaultwarden-maintenance.service` declare a conflict with
  backup services to prevent simultaneous execution, OR does it rely
  solely on the flock lock?
- Does `vaultwarden-notify-failure.service` have `DefaultDependencies=no`
  to prevent it from being blocked during shutdown?

### 4c — Timer Schedule Overlap Risk
List every timer's `OnCalendar=` schedule and `RandomizedDelaySec=`.
Calculate worst-case overlap: if timer A fires at its latest possible time
(nominal + RandomizedDelaySec) and the service runs at its maximum expected
duration, can it still be running when timer B fires at its earliest?

### 4d — Service Identity Verification (post-PRR)
Confirm that NO service unit contains `User=ubuntu` or `Group=ubuntu`.
Confirm that `ExecCondition=` lines (if used for identity checks) reference
a real script path that exists on the Beta branch.

---

## Part 5 — Backup & Restore Pipeline Integrity

### 5a — Backup Completeness
- What exactly does a **DB backup** archive? List every file/path included.
- What exactly does a **full backup** archive? List every file/path included
  and every file/path **explicitly excluded**.
- Can the excluded files from a full backup be independently recovered from
  the recovery kit? Is this documented clearly in `docs/BACKUP-RESTORE.md`?

### 5b — Restore Fidelity
- Does `utilities/restore-run.sh` restore EXACTLY what `utilities/backup-run.sh`
  archives — no more, no less?
- After a full restore from a full backup + recovery kit, can VaultWarden
  start successfully without any manual intervention beyond following
  `docs/DISASTER-RECOVERY.md`?
- Is there any post-restore step that the restore script does NOT perform
  automatically but the admin must do manually? Are these steps clearly
  listed at the END of the restore script output AND in the docs?

### 5c — Remote Storage Lifecycle (post-PRR)
- Is remote retention pruning implemented? What is the prune strategy
  (count-based, age-based, or both)?
- Is the prune applied to ALL remote backends (not just the primary)?
- Is there a test or dry-run mode for the remote prune that a junior admin
  can run safely?

### 5d — Pre-Production Drill
Read `utilities/pre-production-drill.sh`:
- Does it perform a complete backup → restore → verify cycle?
- Does it test BOTH db-backup and full-backup paths?
- Does it verify the restored data is intact (not just that the scripts
  exited 0)?
- Does it clean up after itself without leaving test artifacts that
  could be confused with real backups?
- Does it produce a clear PASS/FAIL output with a non-zero exit on failure?

---

## Part 6 — Security Posture Audit

### 6a — Firewall Integrity (post-PRR)
- Is the Cloudflare CIDR cache stored in a file with restrictive permissions
  (not world-readable)?
- What is the cache TTL? Is it validated (not used if too stale)?
- Is the cached CIDR list validated for format before being loaded into
  iptables (prevent rule injection via malformed cache)?
- Is `setup-firewall.sh` safe to re-run — does it flush and rebuild rules
  atomically, or can a partial re-run leave the firewall in a mixed state?

### 6b — CrowdSec Completeness (post-PRR)
- Is an admin allowlist/whitelist created during `setup-crowdsec.sh`?
  If yes, what mechanism — IP-based whitelist in profiles or a CrowdSec
  whitelist file?
- Does the allowlist survive a CrowdSec restart and upgrade?
- Is the local `crowdsec-firewall-bouncer` configured and enabled, providing
  enforcement even if the Cloudflare bouncer is absent?
- Are the CrowdSec installer artifacts pinned to specific versions with
  checksum verification?

### 6c — Caddy TLS & Headers
- Confirm `min_version tls1.2` (or `tls1.3`) is present in both Caddyfiles.
- Confirm all five headers are present in BOTH `Caddyfile` and
  `Caddyfile.degraded`:
  `X-Frame-Options`, `X-Content-Type-Options`, `Strict-Transport-Security`,
  `Referrer-Policy`, `Content-Security-Policy`
- Does `Caddyfile.degraded` expose any route that the production
  `Caddyfile` does not expose (i.e., is degraded mode more permissive)?
- Does the Caddy Dockerfile use a pinned image tag or `latest`?

### 6d — Secrets Rotation Atomicity
Read `utilities/secrets-rotate.sh`:
- Is there a window during rotation where a service is running with the NEW
  secret while another dependent service still has the OLD secret?
- Is VaultWarden restarted with the new secret atomically (all-at-once) or
  service-by-service?
- If rotation fails mid-way, can the admin roll back to the pre-rotation
  state using the backup created before rotation?

---

## Part 7 — README Clarity Audit

The README must serve one purpose: give a junior admin **just enough** context
to understand what this project is, confirm their system meets prerequisites,
and reach the right starting doc within 5 minutes. It must NOT be a
full manual.

Evaluate `README.md` against these criteria:

### 7a — First Contact (30-second test)
Reading only the first screen (roughly the first 50 lines):
- Can the admin answer: "What does this project do and is it for me?"
- Can the admin answer: "What do I need before I start?"
- Can the admin answer: "What is the first command I run?"
- Is there a single prominent link to `docs/DEPLOYMENT.md` as the starting
  point?

### 7b — Right-sizing
- Does the README contain content that belongs in a `docs/` file instead
  (detailed configuration, troubleshooting steps, script reference)?
- Is there anything in `docs/` that belongs in the README instead
  (prerequisites, quick-start)?
- Flag every section that should be removed from README and replaced with
  a one-line link to the appropriate doc.

### 7c — Accuracy
- Do all script names, Make targets, and file paths mentioned in README
  match what actually exists on the Beta branch?
- Is the utility count accurate?
- Does README correctly describe the project as using CrowdSec (not fail2ban)?

---

## Part 8 — Documentation End-to-End Journey Audit

Audit the entire `docs/` directory as a **unified user manual**, not as
individual files. The question is: can a new junior admin go from zero to a
running, self-maintaining, secure VaultWarden instance by reading these docs
in order, without external help?

### 8a — Reading Order & Navigation
- Is there a clear recommended reading order? (README → DEPLOYMENT →
  CONFIGURATION → SECURITY → OPERATIONS → BACKUP-RESTORE → TROUBLESHOOTING)
- Can the admin determine this order from the docs themselves without
  being told externally?
- Does each document end with a "next step" or "see also" link to the
  logical next document?
- Are there any dead-end documents — docs that a reader reaches but cannot
  navigate forward from?

### 8b — Day 0: Installation Journey
Following `docs/DEPLOYMENT.md` as written:
- Does the sequence of setup commands exactly match the scripts that exist
  on the Beta branch, in the correct order?
- Is there a prerequisite checklist (OS, Docker version, open ports,
  DNS configured, domain pointed)?
- Is there a "you are live" verification checklist at the end?
- If the admin follows ONLY this document, will VaultWarden be running,
  backed up, and monitored at the end?

### 8c — Day 1–30: Operations Journey
Following `docs/OPERATIONS.md`:
- Does it teach the admin what the system does automatically vs. what
  requires manual action?
- Does every `make` target mentioned exist in the actual `Makefile`?
- Are the `make health`, `make health-quick`, `make health-report`, and
  `make health-email` targets described with their **actual behavior** (fixed
  in last PRR — verify fix is reflected here)?
- Is there a "first 30 days" checklist?

### 8d — Emergency: Restore Journey
Following `docs/BACKUP-RESTORE.md` and `docs/DISASTER-RECOVERY.md`:
- Can the admin find the restore procedure without having to read more
  than one document?
- Is there a clear "STOP — read this before you do anything" warning at
  the top of the restore section?
- Does the procedure reference the correct scripts (`utilities/restore-run.sh`,
  not old `restore.sh` direct)?
- Is the age-key resolution order explained before any restore steps
  (the admin needs the key to decrypt the backup)?
- Is `docs/DISASTER-RECOVERY.md` consistent with `docs/BACKUP-RESTORE.md`,
  or do they give conflicting procedures?

### 8e — Accuracy Cross-Check (all docs)
For each `docs/*.md` file, verify every script path, Make target, and
command mentioned exists and is correct on the Beta branch.

Produce this table for every inaccuracy found:

| Document | Line | Documented | Actual | Type |
|---|---|---|---|---|

Types: `WRONG_PATH`, `WRONG_TARGET`, `WRONG_FLAG`, `MISSING_SCRIPT`,
`STALE_TERM` (e.g., "fail2ban"), `WRONG_BEHAVIOR`

### 8f — `docs/DISASTER-RECOVERY.md` (new doc — full audit)
This document was added after the original PRR. Audit it completely:
- Does it accurately describe the archive format (`.tar.zst.age`,
  `.tar.gz.age` legacy)?
- Does the age-key resolution priority table match what `lib/crypto.sh`
  actually implements?
- Is the post-recovery checklist accurate and complete?
- Does the troubleshooting table cover realistic failure scenarios
  (not just happy-path variations)?
- Is the `make key-path` target present in the Makefile and does it do
  what the doc says?

---

## Part 9 — Code Optimization & Redundancy

This section targets issues that affect maintainability at ~30k lines scale.
Only flag items where the redundancy creates **real maintenance risk** (a fix
to one copy that must be mirrored to 3 others will eventually drift).

### 9a — Duplicated Logic (threshold: same logic in 3+ files)
- Are there retry/backoff loop implementations in more than 2 files?
  Should they live in `lib/common.sh`?
- Are there "wait for container healthy" polling loops in more than 2 files?
- Are there identical default-value definitions for the same env variable
  scattered across files?
- Are there `source lib/` boilerplate blocks that differ slightly across
  entry-point scripts (e.g., one sources 6 libs, another sources 5 — is
  the missing one intentional)?

### 9b — Performance-Relevant Inefficiencies
Only flag patterns that are called frequently (in health checks, backup
progress loops, startup) or that create measurable overhead:
- `$(cat file)` inside loops (fork overhead) vs `< file read var`
- Multiple sequential `docker inspect` calls on the same container in the
  same function (should be one call, result cached)
- Multiple sequential `jq` calls on the same JSON string (should be one
  multi-field extraction)
- `grep | grep | sed | awk` chains that can be one `awk`
- `cat file | grep` (useless use of cat) — only flag if in a hot path

### 9c — Structural Complexity (functions > 150 lines)
List the top 10 longest functions in the codebase with their file, name,
and approximate line range. For each, state whether it has a single clear
responsibility or multiple distinct concerns that could be separated.

---

## Part 10 — Junior Admin Usability Review

This section evaluates the system from the perspective of the target user —
a junior admin operating it alone.

### 10a — `make help` Quality
- Does `make help` output clearly distinguish routine targets from dangerous
  targets (backup, health, status) from destructive targets (uninstall,
  wipe, purge)?
- Are dangerous/destructive targets visually separated and labeled?
- Is every target in the Makefile covered by `make help`?
- Is there a `make status` target that answers "is everything OK right now?"

### 10b — Error Message Quality
Sample the error messages from the 5 most critical failure paths:
1. Backup fails because storage is full
2. Restore fails because backup is corrupted
3. VaultWarden container fails health check
4. CrowdSec bans the admin's own IP
5. Maintenance lock is held (another job is running)

For each: does the error message tell the admin **what happened, why, and
what to do next** in plain English?

### 10c — `dashboard.sh` Completeness
- Does `dashboard.sh` show: VaultWarden status, last backup time and
  result, active CrowdSec bans, timer schedule summary, disk usage?
- Is the CrowdSec metrics command fixed (PRR item — verify)?
- Does the dashboard degrade gracefully if Docker, CrowdSec, or any
  dependency is unavailable?

### 10d — `utilities/uninstall-vaultwarden.sh`
- Is there a `--dry-run` mode?
- Is there a `Type YES to confirm` prompt (not just `[y/N]`)?
- Does it offer to export/backup data before proceeding?
- Does it list every resource it will delete before deleting anything?
- After uninstall, are Docker volumes, networks, systemd units, CrowdSec
  configs, firewall rules, and `/etc/vaultwarden/` all cleanly removed?

---

## Output Instructions

Write all findings to a single Markdown file with this structure.
This file will be committed to the Beta branch as
`AUDIT-BETA-FINAL-01-Findings.md`.

```markdown
# AUDIT-BETA-FINAL-01 — Final Pre-Production Findings
**Repository:** killer23d/VaultWarden-OCI  
**Branch:** Beta  
**Audit Date:** [date]  
**Auditor:** Claude Opus 4.6  
**Commit audited:** [Beta HEAD SHA]  
**Prior PRR:** PRR-Beta-Findings.md (all 9 items — re-verified in Part 1)

***

## Overall Verdict

🔴 Not Ready / 🟡 Conditionally Ready / 🟢 Ready

[3 sentences written for a junior admin: is this safe to deploy?]

***

## Part 1 — PRR Re-Verification

[Table with Pass/Fail and evidence for all 9 items]
[Any Fail items are listed again as Critical findings in the relevant part]

***

## Part 2 — Command Validity

### Critical Failures
[Table: File | Line | Command | Invalid Usage | Correct Usage]

### Minor Issues
[Bulleted list]

***

## Part 3 — Shell Safety

### Critical
[Table]

### Moderate
[Table]

### Minor
[Bulleted list]

***

## Part 4 — Systemd Units

### Hardening Matrix
[Table: Unit | PrivateTmp | ProtectSystem | NoNewPrivileges | ProtectHome | RestrictSUIDSGID | Notes]

### Critical / Moderate
[Tables]

***

## Part 5 — Backup & Restore

[Findings]

***

## Part 6 — Security

[Findings]

***

## Part 7 — README

[Findings with specific line references]
[List of sections to trim from README with suggested doc targets]

***

## Part 8 — Documentation

### Accuracy Failures
[Table: Document | Line | Documented | Actual | Type]

### Reading Order Issues
[Bulleted list]

### Per-Document Health
[Table: Document | Accurate? | Junior-Admin-Followable? | Priority Issues]

***

## Part 9 — Optimization

[Findings — only those meeting the 3+ file threshold or hot-path standard]

***

## Part 10 — Usability

[Findings]

***

## Prioritized Fix Backlog

| # | Severity | Part | File(s) | Finding | Effort |
|---|---|---|---|---|---|

Effort: Low (<1h), Medium (half day), High (full day+)
Sort: Critical → Moderate → Minor; within tier: Low effort first.

This table is the direct input for Copilot Agent issue creation.
Each row must be self-contained enough to create a GitHub issue from.
```