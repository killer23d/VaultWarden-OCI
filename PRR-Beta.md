# Beta Production Readiness Review Prompt

## Purpose and classification

This is a **Production Readiness Review (PRR)** with an **SRE operational-readiness, security, disaster-recovery, and release-engineering lens**.

A PRR is the correct primary classification because the required outcome is a pre-production **go / conditional-go / no-go decision**. SRE practices are part of the review: reliability, observability, automated operations, failure recovery, capacity, SLOs, alerting, and safe change management.

---

## Assignment

Perform a complete, evidence-driven production readiness audit of:

- **Repository:** `killer23d/VaultWarden-OCI`
- **Branch:** `Beta`
- **Branch URL:** `https://github.com/killer23d/VaultWarden-OCI/tree/Beta`
- **Prompt authoring baseline:** `44358e309f33102d04e1c291012101babeba2608`
- **Target deployment:** a self-hosted Vaultwarden instance for approximately 10 users
- **Primary operator:** one junior administrator who is not a Bash expert
- **Platform goal:** generic Ubuntu hosts, with provider-specific guidance kept optional

Audit the **actual current `Beta` branch**, even if it has advanced beyond the prompt authoring baseline. Record the exact audited commit SHA in the report.

Write all results to one file at the repository root:

```text
PRR-Beta-Findings.md
```

Do not create separate wave reports. Do not require the operator to paste findings between phases. Complete the audit end to end and produce one deduplicated final report.

---

## Non-negotiable rules

1. **Audit `Beta` only.**
   - Fetch the latest remote references.
   - Check out `Beta`.
   - Verify that `HEAD` matches `origin/Beta` before starting.
   - Do not use `main`, `Alpha`, `A1`, or another branch as evidence of current behavior.

2. **Record the audit baseline.**
   Include:
   - `git rev-parse HEAD`
   - audit date and time in UTC
   - whether the worktree was clean at the start
   - operating system and architecture used for validation
   - versions of Bash, Docker/Compose, ShellCheck, `systemd-analyze`, `yq`, `sops`, and `age` when available

3. **Inventory dynamically; do not trust a static file list.**
   - Start with `git ls-files`.
   - Enumerate all tracked source, configuration, workflow, test, documentation, service, timer, container, and template files.
   - Identify generated artifacts and their authoritative sources.
   - Include any files added after this prompt was authored.
   - Note important runtime files that are intentionally generated or ignored, but do not inspect real secret values.

4. **Implementation is primary evidence.**
   - Use executable code, configuration, service definitions, tests, and generated artifacts as the primary evidence.
   - Treat comments, README files, and documentation as claims that must be verified against implementation.
   - Documentation may be audited for correctness and usability, but it is not proof that a control works.

5. **Do not expose secrets.**
   - Never print, copy, decrypt, quote, or include actual secret values in the report.
   - Do not commit generated secrets, plaintext recovery kits, `.env`, SOPS plaintext, Age private keys, Docker secret material, tokens, credentials, or production data.
   - Inspect schemas, permissions, code paths, placeholder handling, and encrypted metadata without disclosing sensitive content.

6. **Do not change product behavior.**
   - The only repository file you may create or replace is `PRR-Beta-Findings.md`.
   - Do not fix findings during the audit.
   - Do not reformat source files.
   - Do not regenerate committed documentation in place unless you immediately restore it and preserve a clean tree.
   - Before writing the report, verify that no source file was modified by validation commands.

7. **Use safe validation only.**
   Do not run commands that can:
   - format, mount, unmount, migrate, or erase block devices
   - alter `/etc/fstab`
   - change firewall rules
   - install or remove systemd units
   - rotate or decrypt real secrets
   - delete backups or source data
   - restore over live data
   - change DNS, Cloudflare, CrowdSec, or provider configuration
   - start, stop, or mutate an existing production deployment

   Use temporary directories, synthetic fixtures, disposable containers, or a disposable VM where execution is necessary. If a required production-only test cannot be performed safely, mark it **Not Executed** and define the exact manual go-live test.

8. **Do not confuse missing evidence with a proven defect.**
   Classify each result as one of:
   - **Confirmed defect**
   - **Control gap**
   - **Unverified production behavior**
   - **Documentation mismatch**
   - **Hardening recommendation**

9. **No style-only findings.**
   Do not report comment density, formatting preferences, function length, naming taste, or minor shell style unless there is a concrete reliability, security, recovery, maintainability, or operator-safety impact.

10. **Continue without asking for routine confirmation.**
    Complete all safe analysis and tests available in the environment. State limitations clearly in the final report.

---

## Current architecture areas that must be verified

The following describes the current Beta design at prompt-authoring time. Treat it as a starting map, not as guaranteed truth. Verify every item against the current tree and report drift.

### Operator entry points

Inspect the root wrappers and administration interface, including current equivalents of:

- `setup.sh`
- `startup.sh`
- `backup.sh`
- `restore.sh`
- `maintenance.sh`
- `dashboard.sh`
- `edit-secrets.sh`
- `Makefile`

Trace each user-facing command to the real implementation. Verify that wrappers preserve exit codes, arguments, privilege requirements, working-directory assumptions, and actionable errors.

### Core libraries

Inventory all files under `lib/`, including the current implementations for:

- common utilities, logging, defaults, configuration, and validation
- Docker and Compose helpers
- secrets and cryptography
- schema-driven secret management
- backup and storage handling
- maintenance and email
- data-volume migration

Pay particular attention to current files such as `lib/schema.sh` and `lib/migrate.sh`, which were not covered by the original A1-era prompt.

### Secrets architecture

Verify the complete schema-driven secrets lifecycle involving current equivalents of:

- `secrets-schema.yaml`
- `lib/schema.sh`
- `lib/crypto.sh`
- `lib/secrets.sh`
- `utilities/setup-secrets.sh`
- `utilities/secrets-edit.sh`
- `utilities/secrets-rotate.sh`
- secret listing, viewing, testing, recovery-kit, and key-management commands
- SOPS + Age encrypted storage
- materialization into Docker secret files

### Container and network architecture

Verify the generated production Compose topology and templates, including:

- permissions initialization
- Vaultwarden
- custom Caddy build
- optional or required Postfix relay behavior
- Docker secrets
- persistent bind mounts under `PROJECT_STATE_DIR`
- internal and external bridge networks
- published host ports
- health checks
- container users, capabilities, read-only filesystems, tmpfs, swap handling, resource limits, and logging

### Caddy and ingress

Verify the custom Caddy build and configuration, including current plugins for:

- Cloudflare DNS challenge
- trusted Cloudflare client-IP extraction
- Cloudflare IP-range handling
- rate limiting

Audit both normal and degraded configurations, direct and Cloudflare-proxied modes, `/admin` protection, TLS, security headers, real-client-IP trust, WebSockets, health endpoints, and failover behavior.

### CrowdSec and edge blocking

Verify the current CrowdSec deployment and all supported bouncer paths, including current equivalents of:

- `crowdsec/acquis.yaml`
- `crowdsec/profiles.yaml`
- Cloudflare Worker bouncer configuration
- firewall bouncer configuration
- `utilities/setup-crowdsec.sh`

Do not assume the filenames or architecture from the A1 prompt remain valid.

### Storage, backup, restore, and migration

Verify:

- local and remote backup backends
- encryption, manifests, checksums, retention, and upload verification
- DB-only and full backups
- restore preflight, rollback, and failure recovery
- concurrency locks across backup, restore, maintenance, health, and migration
- separate data-volume provisioning and identity checks
- boot-volume to block-volume and reverse migration behavior
- migration resume, abort, verification, source retention/deletion, fstab handling, systemd drop-ins, and Docker startup ordering

### Automation and systemd

Inventory the actual `systemd/` directory and the install logic. Verify:

- all services and timers actually installed
- runtime users and groups
- environment and Age-key access
- hardening directives
- `OnFailure=` behavior
- timer schedules and persistence choices
- overlap and lock behavior
- copied-script drift under `/opt/vaultwarden-scripts`
- path and `ReadWritePaths=` consistency after storage migration
- enablement, daemon reload, validation, and removal behavior

### CI, tests, and generated documentation

Inventory:

- all files under `.github/workflows/`
- all files under `tests/`
- all repository test targets
- documentation generators such as the command-reference generator

Verify that workflows trigger on the branches and events their jobs expect, actions and downloaded tools are pinned appropriately, checksums are validated, permissions are minimal, and CI covers the production-critical code paths.

---

## Audit phases

Perform every phase. Findings should be collected continuously and deduplicated by root cause before the report is written.

## Phase 1 — Repository inventory and architecture map

1. Enumerate the complete tracked file tree.
2. Group files by responsibility:
   - operator entry points
   - libraries
   - setup and provisioning
   - runtime and maintenance
   - secrets and cryptography
   - backup, restore, storage, and migration
   - Caddy, CrowdSec, firewall, and networking
   - Compose and container build files
   - systemd
   - tests and CI
   - documentation
3. Build an execution-flow map from each public command to sourced libraries, generated files, privileged operations, services, and external systems.
4. Identify duplicate or competing control paths, stale compatibility paths, dead wrappers, generated-file drift risks, and authoritative-source ambiguity.
5. Record files or subsystems that cannot be meaningfully audited in the available environment.

## Phase 2 — Release integrity, reproducibility, and supply chain

Audit:

- image tags and whether immutable digests are used where appropriate
- Caddy builder/runtime version synchronization
- versions of `xcaddy` modules and whether plugin source is reproducibly pinned
- downloaded binaries, package repositories, checksums, signatures, and provenance
- GitHub Actions pinning and permissions
- `latest`, unpinned release endpoints, and operator-controlled update modes
- architecture-specific download selection for `amd64`, `arm64`, and other supported architectures
- generated artifacts and drift checks
- update, health validation, rollback, and recovery after a bad image or dependency release
- compatibility of current pins with current upstream releases and security advisories

For current-version and vulnerability claims, verify against authoritative upstream release notes, advisories, or registries. Cite the source and access date. Do not label a dependency outdated or vulnerable from memory alone. If external access is unavailable, mark dependency freshness as unverified.

## Phase 3 — Shell correctness, privilege boundaries, and filesystem safety

Across all executable and sourced shell files, check contextually for:

- correct shebang and Bash assumptions
- `set -euo pipefail` behavior, including where sourced libraries intentionally omit it
- quoting, word splitting, globbing, arrays, pipelines, process substitution, and exit-code propagation
- `eval`, indirect expansion, generated commands, and injection from `.env`, YAML, filenames, domains, paths, device names, service names, and user input
- unsafe `source` of untrusted files
- command availability and version assumptions
- trap composition and cleanup across sourced libraries
- `mktemp`, permissions, umask, symlink and hard-link attacks, predictable paths, and TOCTOU races
- root versus non-root execution
- `sudo`, `SUDO_USER`, service-user detection, ownership, supplementary groups, and privilege transitions
- idempotency and resumability after partial failure
- destructive actions and confirmation bypasses
- lock acquisition, ownership, stale-lock handling, descriptor lifetime, and cross-user behavior
- log files and state files remaining available when source/target paths move

Do not mechanically require every sourced library to install its own traps or strict mode. Judge safety in the real calling context.

## Phase 4 — Secrets, cryptography, and credential lifecycle

Trace every secret from collection to storage, materialization, use, rotation, recovery, and deletion.

Verify:

- SOPS and Age initialization and key custody
- permissions and ownership of encrypted files, Age private keys, Docker secret files, temp files, state files, and recovery kits
- no plaintext leakage through logs, shell history, process arguments, environment dumps, command traces, errors, backups, or generated documentation
- schema parser safety and schema/code consistency
- allowed schema values, unknown fields, duplicate keys, missing keys, conditional groups, service mappings, and schema-version handling
- placeholder detection before startup
- correct Argon2id and bcrypt handling without accidental double hashing or plaintext persistence
- strong generation of backup passphrases and other generated values
- atomic secret edits and rotations
- dependent service restart order, health validation, and rollback when rotation fails
- token scope and least privilege for Cloudflare, email, push, and other providers
- safe viewing/listing commands and terminal exposure
- recovery-kit warnings, completeness, storage guidance, and deletion behavior
- recoverability if the Age key is lost but encrypted secrets remain
- behavior if a secret is malformed, empty, stale, or still a placeholder

## Phase 5 — Setup, configuration, and deployment safety

Audit the full first-install and re-run path.

Verify:

- documented and implemented CLI forms match
- `--auto`, `--use-latest`, `--force`, `--dry-run`, data-device options, and subcommands have safe and consistent semantics
- setup is idempotent after success and resumable after interruption
- existing data, secrets, Compose files, and configuration are not overwritten unexpectedly
- `.env.example`, config loaders, defaults, validators, Compose variables, systemd environment generation, and documentation are consistent
- required versus optional values are enforced correctly for each selected mode
- domain, email, CIDR, UID/GID, path, device, version, schedule, and provider inputs are validated before privileged use
- Ubuntu and architecture assumptions are explicit and tested
- data-volume formatting requires unmistakable authorization and cannot target the OS disk
- mount identity, sentinel files, filesystem type, `/etc/fstab`, `nofail`, `RequiresMountsFor=`, and Docker ordering prevent silent writes to the boot volume
- generated `docker-compose.yml` is deterministic and does not silently retain stale template content
- startup waits for meaningful health, not just process existence
- startup failure diagnostics preserve the original non-zero result
- degraded mode activation and recovery are explicit, observable, and safe

## Phase 6 — Containers, ingress, firewall, and network security

Audit the real packet path from the internet to Vaultwarden and all outbound paths.

Verify:

- published ports and host binding scope
- Docker's interaction with UFW, nftables, iptables, and the `DOCKER-USER` chain
- provider firewall responsibilities versus host firewall responsibilities
- IPv4 and IPv6 parity
- Cloudflare-only restrictions when proxy mode is selected
- direct `acme_http` mode behavior without Cloudflare
- resistance to spoofed `CF-Connecting-IP` or other trusted proxy headers
- current Cloudflare IP range updates and failure behavior
- admin endpoint access controls and safe defaults
- TLS protocol/cipher policy, certificate issuance, renewal, and failure handling
- HTTP-to-HTTPS behavior
- HSTS and other security headers without breaking Vaultwarden clients
- WebSocket and push behavior
- Caddy normal/degraded config equivalence for security controls
- rate limiting correctness and bypass paths
- CrowdSec log acquisition, parser/scenario installation, decisions, profiles, allowlists, and remediation
- Cloudflare Worker and firewall bouncer setup, token handling, version pinning, restart, and health validation
- protection when Cloudflare is unavailable or intentionally not used
- internal network isolation and necessary egress only
- Postfix host-port exposure and relay restrictions
- container users, capabilities, `no-new-privileges`, read-only filesystems, tmpfs, secret mounts, health checks, resource limits, swap behavior, and log rotation
- whether the Docker daemon remains the dominant host-level trust boundary and whether that risk is documented

## Phase 7 — Backup, restore, storage, migration, and disaster recovery

Treat this as a release-gating area.

### Backup

Verify:

- SQLite consistency and handling of WAL/SHM files
- consistency between DB, attachments, config, and secret-related recovery material
- archive completeness and non-zero validation
- encryption before remote transfer
- authenticated integrity, checksums, manifests, and verification order
- filenames, paths, permissions, temporary artifacts, and cleanup
- local fallback when remote upload fails
- atomic remote upload or equivalent partial-object protection
- backend-specific success verification
- retention safety and behavior when a new backup is invalid
- disk-space checks and full-disk behavior
- concurrency with restore, maintenance, health remediation, update, and migration

### Restore

Verify:

- preflight checks before stopping or replacing data
- backup discovery and unambiguous selection
- decryption and integrity verification before destructive changes
- service stop/start ordering
- rollback or preservation of the last working state
- permissions and ownership restoration
- database and HTTP-level post-restore validation
- behavior after interruption at every destructive stage
- rejection of unsupported, partial, stale, or malicious archives
- path traversal, symlink, special-file, and archive-bomb defenses

### Remote storage

For every supported backend, verify:

- command construction and credential handling
- timeout, retry, backoff, and error classification
- upload, list, download, delete, and retention parity
- validation of object identity, size, checksum, and destination
- portability and absence of mandatory OCI-specific behavior

### Data-volume migration

Verify both migration directions and every subcommand:

- preflight source and target identity
- boot-device exclusion
- filesystem and mount safety
- lock behavior
- service quiescing
- SQLite hot-file detection
- copy exclusions
- size and content verification
- state-file integrity and injection resistance
- resume after every step
- abort semantics
- source rename/delete safety
- fstab and sentinel handling
- environment and systemd drop-in updates
- Docker startup ordering after reboot
- rollback when validation fails
- log availability if the source path is renamed or deleted

### Recovery objectives

Determine whether the project defines and can demonstrate:

- an RPO
- an RTO
- backup success monitoring
- periodic restore testing
- off-host and off-provider copies
- Age-key and recovery-kit custody
- recovery from total host loss

An untested restore path must be listed as an **unverified production behavior** and normally blocks an unconditional Ready verdict.

## Phase 8 — systemd automation and unattended operation

For every service, timer, drop-in, and installer path, verify:

- unit syntax with `systemd-analyze verify` where available
- absolute and current `ExecStart=` paths
- correct runtime user/group and supplementary group access
- environment-file and Age-key readability without over-broad permissions
- `ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, capability controls, namespace controls, and write-path allowances appropriate to each job
- privileged exceptions are minimal and justified
- services do not depend on an interactive shell environment
- `OnFailure=` works for the real failure modes
- failure notification does not recurse or create alert storms
- timers have valid schedules, randomized delay where useful, and intentional `Persistent=` semantics
- backup, maintenance, health repair, DNS update, firewall update, restore, and migration cannot race destructively
- lock files survive expected users and service contexts
- missed jobs, reboot, long downtime, and clock changes are handled safely
- installed copies under `/opt` cannot silently drift from the repository
- install, update, validate, status, and removal operations are idempotent
- data-volume migration updates every path embedded in units or drop-ins
- logs and exit statuses remain useful to a junior administrator

## Phase 9 — Email, notifications, monitoring, and observability

Verify:

- all email delivery modes and provider selection
- API-token and SMTP-password handling
- Postfix relay restrictions and TLS behavior
- notification failure isolation from backup, maintenance, health, and startup outcomes
- accurate subject/body severity and actionable remediation
- alert deduplication and storm prevention
- test-email behavior without leaking credentials
- dashboard and Makefile status commands reflect actual health
- container health, HTTP health, backup age, timer state, disk capacity, CrowdSec state, certificate health, and degraded mode are visible
- logs have rotation, bounded growth, stable paths, safe permissions, and no secret leakage
- failures are visible without requiring the administrator to inspect multiple unrelated locations
- the system can detect silent backup failure, a stopped timer, a missing data-volume mount, and a stale installed script copy

Assess whether concrete SLIs/SLOs exist. At minimum discuss availability, backup freshness, restore success, alert delivery, and storage capacity. Missing formal SLOs may be a control gap rather than a software defect, but must be included in production sign-off.

## Phase 10 — CI, tests, and validation coverage

Inventory all available test and CI paths, then verify:

- workflow trigger events match job conditions
- `Beta` receives the checks required before production use
- workflow permissions are minimal
- third-party actions are commit-pinned where appropriate
- downloaded tools use pinned versions and verified checksums
- ShellCheck follows sourced files correctly
- syntax, schema, Compose, systemd, and generated-document checks are present
- tests cover supported architectures and reject unsupported ones
- tests cover destructive confirmation boundaries, locks, interrupted operations, placeholder secrets, schema errors, backup corruption, restore rollback, migration resume/abort, and Cloudflare/direct ingress modes
- tests do not require or mutate production credentials or infrastructure
- generated documentation can be reproduced deterministically
- the current CI suite would catch a breaking change in a production-critical path

Clearly distinguish tests that exist from behaviors they actually validate. A passing shallow test is not evidence for an untested failure path.

## Phase 11 — Documentation and junior-admin usability

Read all current documentation and cross-check it against implementation.

Verify:

- there is one clear install path and one clear day-2 operations path
- command names, paths, flags, defaults, versions, schedules, and service names are current
- CrowdSec, Cloudflare, firewall, Postfix, secrets schema, storage migration, backup, restore, and systemd architecture are described accurately
- destructive steps have warnings, prerequisites, expected output, validation, rollback, and stop conditions
- provider-specific guidance is clearly separated from generic requirements
- direct versus Cloudflare-proxied modes are unambiguous
- recovery documentation works under stress and does not assume access to a lost key or failed host
- the command reference and any generated docs match their authoritative sources
- stale links, stale script names, stale bouncer names, and contradictory instructions are listed
- a junior admin can determine whether the system is healthy, when the last valid backup completed, how to test restore, how to unban themselves, and when not to proceed

Documentation errors that could cause data loss, lockout, secret exposure, or an insecure deployment are release blockers even when the code is correct.

## Phase 12 — Failure-mode and threat-model review

Trace at least these scenarios end to end:

1. Cloudflare outage or expired/revoked token
2. Direct traffic reaching the host while proxy-header trust is enabled
3. Caddy compromised while Vaultwarden remains healthy
4. Vaultwarden compromised and attempting lateral movement or unrestricted egress
5. Docker daemon or Docker-group account compromise
6. CrowdSec unavailable, misconfigured, or banning the administrator
7. Postfix relay unavailable or abused
8. Full boot disk, full data volume, or inode exhaustion
9. Separate data volume missing at boot
10. Backup target unavailable for multiple scheduled runs
11. Corrupt or truncated backup selected for restore
12. Restore interrupted after old data is moved but before validation
13. Migration interrupted at each state transition
14. Age private key lost or unreadable
15. SOPS file corrupt or schema version unsupported
16. Secret rotation succeeds in storage but dependent service restart fails
17. Partial setup followed by a re-run with different options
18. Bad container image update with failed rollback
19. Timer installed but no longer scheduled
20. Notification channel unavailable during a critical failure
21. Upstream dependency or plugin supply-chain compromise
22. Administrator runs a destructive command from the wrong working directory

For each scenario, state:

- preventive control
- detection signal
- automated response
- manual recovery path
- residual risk
- whether the behavior was tested, statically verified, or remains unverified

---

## Required safe validation

Run as many of the following as the environment safely permits. Record the exact command, result, and limitation.

### Repository integrity

```bash
git status --short
git rev-parse HEAD
git rev-parse origin/Beta
git ls-files
```

### Shell parsing and linting

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x --severity=warning
```

Use a safe fallback if `xargs` behavior or command length requires batching.

### Repository tests

Discover the actual test interface before running it:

```bash
make help
make test
```

Also run individual non-destructive tests under `tests/` when they are not already included. Do not assume `make test` covers every file.

### YAML and schema parsing

Validate all tracked YAML files with the appropriate parser where available. At minimum parse:

- `secrets-schema.yaml`
- `.github/workflows/*.yml`
- `crowdsec/*.yaml` and examples
- Compose templates

Validate schema enums, duplicate secret keys, required fields, referenced auto-functions, and referenced services against implementation.

### Compose validation

Use a temporary directory and synthetic placeholder values. Do not use real `.env` or secrets.

Validate the current generated/template Compose configuration with the installed Compose implementation. Record warnings about ignored or Swarm-only fields.

### systemd validation

Run `systemd-analyze verify` against tracked service and timer units where available. If repository paths require substitution, validate copies in a temporary directory and document the substitutions.

### Generated documentation drift

Run generators in a temporary copy or restore all generated files afterward. Compare generated output with committed output.

### Static consistency checks

Check at minimum:

- variables consumed versus `.env.example`
- Compose secret names versus schema/materialization
- schema service mappings versus real Compose services
- Makefile targets versus scripts and docs
- systemd `ExecStart=` paths versus installed-copy layout
- timer lists versus actual unit files
- lock paths and owners across all callers
- image/plugin/tool version variables versus their use sites
- documentation commands and flags versus `--help` output

### Optional disposable integration tests

In a clean disposable VM or container host, when available:

- generate configuration using synthetic credentials
- render Compose config
- start the stack without public DNS exposure
- verify health checks
- verify clean stop/start
- create a synthetic vault dataset
- perform backup, corruption rejection, restore, and post-restore verification
- exercise migration on loopback devices only
- verify systemd units in a disposable VM

Never perform these tests against a real production host or real user data.

---

## Severity and release-gate rubric

### Blocker

A credible path to data loss, unrecoverable secret loss, public exposure, authentication bypass, destructive device selection, unsafe restore/migration, or a deployment that cannot be operated or recovered safely. Also use Blocker when a mandatory go-live control is absent and no compensating control exists.

**Release rule:** any open Blocker means **Not Ready**.

### Critical

A high-likelihood or high-impact security, availability, integrity, or recovery failure that can affect the whole service or all users, including a broken backup/restore control, privilege escalation, secret disclosure, or ingress bypass.

**Release rule:** any open Critical normally means **Not Ready**.

### High

A material reliability, security, operations, or maintainability problem that should be fixed before production, but has a documented temporary workaround or narrower impact.

**Release rule:** open High findings require **Conditionally Ready** at best, with explicit owner, workaround, and acceptance.

### Medium

A real weakness with limited immediate impact, lower likelihood, or a robust workaround. Schedule it and define validation, but it may not block a small controlled launch.

### Low

Minor hardening, clarity, coverage, or operator-experience improvement with a concrete benefit.

### Informational

Verified positive control, design note, limitation, or accepted residual risk. Do not inflate informational observations into findings.

Also assign a confidence level: **High / Medium / Low**.

---

## Finding quality requirements

Every finding must include:

- **ID**
- **Severity**
- **Confidence**
- **Type**: confirmed defect / control gap / unverified behavior / documentation mismatch / hardening recommendation
- **Category**
- **Affected file(s) and exact line(s)**
- **Evidence**: concise code/config/test evidence
- **Failure mode or attack path**
- **Why it matters for this deployment**
- **Reproduction or verification steps** that are safe and specific
- **Recommended remediation** with enough detail to implement
- **Release gate**: blocks production / conditional acceptance / post-launch
- **Fix validation**: exact test or observation that proves the issue resolved

Rules:

- Cite the primary implementation location, not only a documentation line.
- When several files share one root cause, create one finding with all affected locations.
- Do not duplicate a finding across categories.
- Do not report hypothetical attacks without a plausible input path and impact.
- Do not claim a command succeeds or fails unless it was executed or the conclusion follows directly from code.
- Label inferences explicitly.
- Include relevant positive controls so the report is balanced and useful.

---

## Required output: `PRR-Beta-Findings.md`

Use this exact structure.

# Production Readiness Review — Beta

## 1. Audit metadata

- Repository and branch
- Audited commit SHA
- Prompt-authoring baseline and whether Beta advanced
- Audit date/time UTC
- Auditor/tooling environment
- Initial worktree status
- Scope limitations

## 2. Executive decision

Include:

- **Verdict:** `NOT READY` / `CONDITIONALLY READY` / `READY`
- 5–8 sentence executive summary for a non-technical administrator
- count of findings by severity
- the three largest risks
- whether backup restore was actually demonstrated
- whether production dependency freshness was externally verified

Verdict rules:

- **NOT READY:** any open Blocker or Critical; or a core install/start/backup/restore path is demonstrably broken.
- **CONDITIONALLY READY:** no Blocker/Critical, but one or more High findings, unverified recovery controls, or manual production gates remain.
- **READY:** no Blocker/Critical/High findings; all mandatory acceptance gates pass; backup and restore are demonstrated safely; remaining risks are Medium/Low and explicitly accepted.

Do not award READY merely because static analysis passes.

## 3. Architecture and trust-boundary summary

Describe the verified current architecture, privilege boundaries, data locations, secret flow, ingress/egress paths, external dependencies, generated artifacts, and unattended jobs. Note any drift from the architecture described in this prompt.

## 4. Validation evidence

Table:

| Check | Command or Method | Result | Evidence / Limitation |
|---|---|---|---|

Include every test attempted, including failures, skips, and unavailable tools.

## 5. Release blockers

Table:

| ID | Severity | Finding | Affected Area | Required Before Production |
|---|---|---|---|---|

If none, state `No Blocker or Critical findings.`

## 6. Prioritized findings

Order by severity, then exploitability/likelihood, blast radius, and recovery difficulty. Use one complete subsection per finding with all fields required above.

## 7. Positive controls verified

List controls that are implemented correctly and the evidence supporting them. Examples may include non-root containers, secret files, pinned versions, checksum validation, locks, rollback, hardening, or tests—but only when verified.

## 8. Failure-mode matrix

Table:

| Scenario | Prevention | Detection | Automated Response | Manual Recovery | Tested / Verified / Unknown | Residual Risk |
|---|---|---|---|---|---|---|

Cover every scenario required in Phase 12.

## 9. SRE operational readiness

Assess:

- availability signal and target
- backup freshness signal and target
- RPO and RTO
- alerting and notification dependency
- capacity and disk monitoring
- change/update safety
- rollback
- runbook quality
- on-call feasibility for one junior admin
- toil and manual recurring work

Clearly distinguish repository controls from deployment-specific controls that must be configured on the real host or provider.

## 10. Production acceptance checklist

Table:

| Gate | Status: Pass / Fail / Not Executed | Evidence | Owner Action |
|---|---|---|---|

Include at minimum:

- clean install on supported Ubuntu/architecture
- idempotent setup re-run
- Compose render and container health
- public ingress restricted as intended
- `/admin` access restriction
- Cloudflare/direct-mode behavior
- CrowdSec decision and remediation path
- email alert delivery
- timer installation and next-run visibility
- backup creation and remote verification
- corrupt backup rejection
- restore into a disposable environment
- post-restore application verification
- data-volume missing-at-boot protection
- migration resume and rollback
- Age-key/recovery-kit offline custody
- full-disk alerting
- update failure and rollback
- documentation walkthrough by the intended junior admin

## 11. Manual live-environment tests still required

For every item that could not be safely executed, provide:

- exact purpose
- prerequisites
- exact command or procedure
- expected result
- abort condition
- rollback procedure
- evidence to retain for sign-off

## 12. Prioritized remediation plan

Numbered list in implementation order. Group fixes by root cause and dependency. For each item include:

- finding IDs addressed
- expected risk reduction
- files likely involved
- validation required

## 13. Residual risk and sign-off

State:

- risks accepted for a 10-user deployment
- risks that require provider/host configuration outside the repository
- explicit conditions attached to a conditional verdict
- final recommendation to the owner in plain English

---

## Completion checks

Before finishing:

1. Confirm all tracked files were assigned to an audit area or explicitly excluded with a reason.
2. Confirm all tests and commands are represented in the validation evidence table.
3. Confirm every Blocker, Critical, and High issue appears in the release-blocker or conditional-gate sections.
4. Confirm duplicate findings were merged by root cause.
5. Confirm no actual secret values appear in the report.
6. Confirm no repository source files were modified.
7. Write or replace only `PRR-Beta-Findings.md`.
8. Run:

```bash
git status --short
```

The only intended new or modified file at completion is:

```text
PRR-Beta-Findings.md
```
