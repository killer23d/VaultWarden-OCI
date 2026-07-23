# VaultWarden-OCI Final Production Readiness Report

## 1. Audit Metadata

| Field | Value |
|---|---|
| Repository | `killer23d/VaultWarden-OCI` |
| Branch | `delta` |
| Full audited SHA | `6a7d9e70954c6b05bda25e7b9089b39715965ba8` |
| Short SHA | `6a7d9e70954c` |
| Commit date | `2026-07-23T21:38:29Z` |
| Commit subject | `Remove the sonnet second-pass delta report as all findings have been addressed and the document is no longer needed. The production readiness status is now confirmed as Green following the remediation in PR #216.` |
| Audit start date | 2026-07-23 |
| Audit completion date | 2026-07-23 |
| Reviewer | OpenAI Codex, primary audit agent; no subagents used |
| Environment | macOS 26.5.2 (25F84), arm64; GNU Bash 5.3.15 |
| Network availability | Browser access available. Shell network was sandbox-restricted; approved read-only GitHub API queries succeeded. |
| Available tools | Git, Bash 5.3.15, ShellCheck 0.11.0, yq 4.53.3, jq 1.7.1, Docker client 29.6.2, gh 2.96.0, curl, tar, SQLite, OpenSSL |
| Material unavailable tools/capabilities | Ubuntu/systemd host, Docker Compose plugin, `systemd-analyze`, `actionlint`, `flock`, `zstd`, `age`, `sops`, `rclone`, Python PyYAML |
| Initial working-tree status | Clean: `## delta...origin/delta` |
| Final working-tree status | Clean after the requested report-only commit; the report-authoring drift gate contained only this report. |
| Branch-drift check | Passed before report commit: `HEAD` remained the full audited SHA. |
| Report path | `reports/PRODUCTION-READINESS-delta-2026-07-23-6a7d9e70954c.md` |
| Report-only statement | The audit made no production-code, test, workflow, generated-document, configuration, or secret changes. Only this report was added. Proposed patches below were not applied. |

All line references identify the audited tree at `6a7d9e70954c6b05bda25e7b9089b39715965ba8`, not the later report commit.

## 2. Executive Decision

| Decision field | Result |
|---|---|
| Repository readiness | **NO-GO** |
| Production-host acceptance | **NOT VERIFIED** |
| Production claim | **NOT PRODUCTION-READY** for the documented Ubuntu 24.04 Noble amd64/arm64 production path |
| Overall RAG status | **Red** |
| Readiness score | **3.0 / 10** (raw weighted score 6.0; capped by the P0) |
| Confidence in score | High |
| P0 count | 1 |
| P1 count | 1 |
| P2 count | 2 |
| P3 count | 1 |
| Release blockers | PRR-001 and PRR-002 |

Mandatory conditions are to remove secret material from command output without losing the one-time credential handoff, make mandatory setup failures fail the install, resolve or explicitly accept the two bounded P2 risks, obtain green validation on the remediation SHA, and complete the production-host checklist on authorized Noble hosts.

Top three risks:

1. Golden-path setup and supported key workflows print a private Age key or credential material to command output, which unattended setup, terminal capture, or logs can retain.
2. `setup.sh install` converts required UFW and automatic secrets-configuration failures into warnings and returns success.
3. A plaintext recovery kit can be swept into a nominally key-free full backup, and startup briefly makes non-Caddy log files world-readable before container repair.

Top three strengths:

1. Backup tiers are deliberately distinct and required verification/offsite cohort failures are not reported as full success.
2. Full/emergency restore uses staged extraction, archive validation, explicit promotion, rollback boundaries, permission repair, and truthful post-commit health handling.
3. Mutating workflows broadly use the shared `flock` operation guard with verified ownership metadata and explicit contention semantics.

Maintainer-facing explanation: the repository has unusually strong recovery and concurrency foundations, but a password-manager appliance cannot ship while its supported first-install/key workflows disclose secrets through output or while required setup phases can fail without failing the command.

The numeric score is explanatory only and does not override the release blockers.

## 3. Supported Boundary and Audit Assumptions

### Documented requirements

- Ubuntu 24.04 LTS Noble only, on amd64 or arm64.
- systemd, Docker Engine, and the Docker Compose plugin.
- Cloudflare DNS/proxy/WAF, Caddy DNS-01 TLS, Vaultwarden, the Postfix sidecar, CrowdSec plus host and Cloudflare Workers bouncers.
- SOPS plus Age, rclone/offsite support, and systemd automation.
- Root-operated lifecycle for a small team of about ten users and one primary operator.
- Three backup tiers: `db`, `full`, and `emergency`.

### Implementation-derived assumptions

- Repository `.env` is the authoring/bootstrap surface; installed and persistent environments become runtime authorities.
- `/etc/vaultwarden/age-key.txt` is the normal operational Age private key; `/run/vaultwarden-oci/secrets` is transient plaintext runtime state.
- `flock` state, not metadata-file existence, is authoritative for operation ownership.
- The Cloudflare-origin UFW policy and Workers/KV bouncer are required parts of the public production security boundary.
- The installed systemd runtime under `/opt/vaultwarden-scripts` must be refreshed after relevant repository updates.

### External prerequisites

- Correct Cloudflare DNS, proxy, Full (Strict) TLS, WAF/Worker route, API-token permissions, KV resources, and fail-open route setting.
- A functional upstream SMTP relay and correct sender policy.
- An operator-controlled offsite rclone remote.
- Sufficient boot/data-volume and restore-staging capacity.
- Working NTP/time, DNS, package repositories, GitHub/container registries, and Docker Hub/GHCR access.

### Auditor assumptions

- The current executable tree and repository instructions outrank deleted historical reports.
- No production secrets exist in the checkout; no secret values were requested or inspected.
- Public GitHub data for the repository and upstream releases is authoritative for the source/date claimed.

### Unverified host facts

- No authorized Ubuntu Noble host, block device, Cloudflare account, SMTP relay, rclone remote, mailbox, real systemd installation, or production-like restore target was supplied.
- Real amd64/arm64 install, boot, restart, timer, package interruption, disk pressure, network failure, email receipt, offsite delivery, and recovery duration remain unverified.

## 4. Decision Criteria

- **NO-GO** applies because a confirmed P0 exists, a supported golden-path operation credibly discloses secrets, and required setup failure can be reported as command success.
- **GO WITH CONDITIONS** would require no confirmed release blocker, bounded residual defects with safe workarounds, and measurable external/host conditions.
- **GO** would require no confirmed blocker, green applicable validation, coherent public contracts, convincing backup/restore evidence, and no unresolved issue undermining the claim.
- Production-host acceptance is **VERIFIED** only after the complete supported path passes on authorized representative Noble hardware/VMs; **NOT VERIFIED** applies when that evidence has not been collected but a bounded acceptance path remains; **BLOCKED** applies when a known impediment prevents the acceptance program from proceeding.
- Host acceptance is **NOT VERIFIED** here because no authorized representative host was supplied. It is not `BLOCKED` because the checklist can proceed after remediation.

## 5. Scope, Method, and Limitations

### Scope and method

The audit:

- read `AGENTS.md`, `docs/PROJECT-BOUNDARY.md`, the supplied audit brief, primary operator docs, architecture/recovery/security/email/storage docs, and generated command references where relevant;
- traced setup, environment, secrets, lifecycle, operation guards, storage, backup, restore/recovery, systemd installation, networking/firewall, CrowdSec, email, health/alerts, update, migration, uninstall, Compose, tests, and CI;
- searched every caller/public surface for confirmed contracts before classifying findings;
- ran Bash syntax and strict ShellCheck across tracked shell sources;
- attempted the canonical suites and recorded the precise environment-dependent stopping points;
- inspected public CI for the exact SHA and the immediately preceding code-changing PR SHA;
- checked current upstream release status and targeted advisories from primary GitHub release pages and the NVD where applicable;
- used a synthetic, non-secret function probe to confirm that `show_post_install_summary auto` emits every supplied secret marker.

### Meaningful reviewed surfaces

- Top level: `setup.sh`, `startup.sh`, `maintenance.sh`, `backup.sh`, `restore.sh`, `recover.sh`, `edit-secrets.sh`, `dashboard.sh`, `Makefile`, `.env.example`, `docker-compose.yml.example`, `.sops.yaml`, `secrets-schema.yaml`.
- Canonical libraries: `lib/defaults.sh`, `lib/config.sh`, `lib/common.sh`, `lib/operations.sh`, `lib/storage.sh`, `lib/migrate.sh`, `lib/crypto.sh`, `lib/schema.sh`, `lib/secrets.sh`, `lib/backup-utils.sh`, `lib/runtime-permissions.sh`, `lib/email.sh`, `lib/health-alerts.sh`, `lib/docker.sh`.
- Owning utilities: setup, firewall, systemd, CrowdSec, secret, backup, restore, maintenance, update, storage, permission, smoke-test, drill, and uninstall utilities.
- `systemd/`, `caddy/`, `crowdsec/`, `.github/workflows/doc-drift.yml`, and all permanent case-file names under `tests/suites/`.
- Primary documentation listed in Appendix B.

### Limitations and skipped validation

- The audit environment was macOS, not the supported Ubuntu host.
- Docker was only a client installation; `docker compose --env-file` failed with `unknown flag: --env-file`, so local Compose rendering was not available.
- The canonical suite was not green locally: it stopped on GNU `stat` assumptions; targeted suites later stopped on absent PyYAML, `flock`, and `zstd`.
- No systemd unit verification, package mutation, firewall mutation, block-device mutation, backup/restore against live data, email send, Cloudflare change, rclone write, or destructive fault injection was performed.
- `actionlint` and `systemd-analyze` were unavailable.
- Exact-head GitHub CI had zero runs. The immediately preceding code-changing PR head had seven successful jobs, which is strong but not exact-SHA evidence.

## 6. Threat and Trust-Boundary Summary

| Boundary | Sensitive asset | Existing control | Failure consequence | Status |
|---|---|---|---|---|
| Operator terminal/process output | Age private key, admin credentials, recovery kit | root execution, xtrace suppression, some mode-0600 files | Console/journal/transcript disclosure enables vault/admin or backup compromise | **Red — PRR-001** |
| SOPS ciphertext ↔ operational Age key | All production credentials | root-owned 0600 key, SOPS policy, key health/rotation | Lost key makes secrets/backups unusable; leaked key decrypts them | Amber pending host custody proof |
| Repository/persistent/installed environments | Runtime identity, paths, non-secret policy | ordered loader, sync/validation utilities, drift reporting | Split-brain configuration or stale automation | Green statically; host unverified |
| Internet ↔ Cloudflare ↔ origin | Public vault and admin surface | proxy, DNS-01, UFW Cloudflare CIDRs, Caddy, Workers/KV | Origin bypass or edge-control bypass | **Red — PRR-002 plus host tests** |
| Container ↔ host filesystem | Vault data, logs, Caddy keys/config | bind mounts, non-root users, caps, read-only FS, permission helpers | local disclosure/corruption | Amber — PRR-004 |
| Backup archive ↔ offsite remote | recovery points and companion metadata | Age encryption, checksums, metadata cohorts, rclone status | unusable or unexpectedly secrets-bearing recovery point | Amber — PRR-003 |
| Restore staging ↔ live state | database, config, keys, permissions | traversal checks, staged extraction, promotion/rollback, start policy | data loss or mixed recovery identity | Green statically; destructive host proof pending |
| systemd checkout ↔ installed runtime | automated scripts, env, key, units | copy manifest, mode checks, timer validation | stale or silently failing automation | Green statically; host unverified |
| Health/alerts ↔ operator | truthful service/backup/security state | explicit exit taxonomy, incident locks/cooldowns, OnFailure | silent incident or alert flood | Green statically; mailbox proof pending |
| Package/release sources ↔ root installer | executable code and images | pins, checksums for yq/SOPS, Docker key fingerprint, signed apt | supply-chain root compromise | Amber; advisory hardening remains |

## 7. Production Readiness Scorecard

| Domain | Status | Static evidence | Runtime evidence | Release gate | Notes |
|---|---|---|---|---|---|
| Supported platform and initial installation | Red | Noble/arch detection fails closed, but setup swallows required failures | Predecessor CI green; no real install | Yes | PRR-002 |
| Configuration ownership and drift | Green | Canonical defaults/loader/sync/installed-env order traced | Mocked CI only | Conditional | Installed drift must be host-tested |
| Secrets, credentials, key custody | Red | SOPS/Age transactions are strong; output disclosure is explicit in code | Synthetic secret-marker probe reproduced output | Yes | PRR-001 |
| Administrative access/account safety | Amber | Argon2id/bcrypt, Caddy CIDR/basic auth, break-glass lifecycle | No live admin/login test | Conditional | Cloudflare/admin acceptance required |
| Privilege/filesystem boundaries | Amber | Root mutation and known-path repair are broadly enforced | Local permissions suite stopped on macOS `stat` | Conditional | PRR-004 |
| Lifecycle, health, truthful state | Amber | Critical readiness and health results propagate; warnings distinguished | Predecessor operations CI green | Conditional | Host/reboot/outage tests pending |
| Concurrency/interruption | Green | Shared global/specific locks, verified PID identity, TERM/KILL policy | Operations case passed locally; Linux-only portions skipped | Conditional | Real `flock`/systemd contention pending |
| Backup/offsite | Amber | Verified SQLite snapshots, tier separation, cohort-aware remote results | Predecessor data-protection CI green; no live archive | Conditional | PRR-003 and remote proof |
| Restore/disaster recovery | Green | Safe selection/preflight/staging/promotion/rollback/start policy | Predecessor data-protection CI green; no destructive host run | Conditional | Replacement-host drill required |
| Effective recovery objectives | Amber | Effective schedules/retention derivable | Duration and achieved RPO/RTO unmeasured | Conditional | Maintainer acceptance required |
| Storage/capacity/exhaustion | Green | Device ownership, boot-device refusal, sentinel, mount checks | No real block device/disk-full run | Conditional | Host testing required |
| Update/migration/rollback | Amber | Pre-update DB backup, image cohort rollback, resumable storage migration | Mocked CI only | Conditional | DB compatibility and real rollback pending |
| Network/TLS/edge/time | Red | Correct intended architecture, but setup can succeed without UFW | None | Yes | PRR-002 |
| Email/failure notification | Amber | Postfix-first route, secure HTTP payload handling, incident state | Email tests green in predecessor CI; no mailbox receipt | Conditional | PRR-005 low severity; provider proof required |
| Containers/Compose | Amber | non-root Caddy/Vaultwarden, cap drops, read-only FS, limits | Predecessor Compose CI green; local unavailable | Conditional | Mutable tags/digest evidence should be captured |
| systemd/installed runtime | Green | hardened units, explicit copies, six-timer validation, exit 75 semantics | Predecessor systemd tests green; no real systemd | Conditional | Install/enable/reboot proof required |
| External dependencies/supply chain | Amber | important pins/checksums exist; current releases mostly aligned | External-source verification only | Conditional | SOPS is one patch behind; digest/action pinning advisory |
| Diagnostics/supportability | Green | smoke test treats skip as failure; bounded diagnostics and status tools | No live incident exercise | Conditional | Redaction must be verified |
| Tests/CI | Amber | canonical inventory, strict ShellCheck, four suites | Seven green predecessor jobs; zero exact-head jobs; local partial | Conditional | Remediation head must be fully green |
| Documentation/operator contract | Amber | broad current docs and generated command reference | Doc-drift predecessor job green | Conditional | Output and setup-success text must change with fixes |
| Junior-operator handoff/decommissioning | Amber | guided ops, test reset, uninstall verification, recovery docs | No novice-run rehearsal | Conditional | Secret display/false success are material traps |

### Weighted readiness score

| Weighted domain | Weight | Score / 10 | Deduction basis |
|---|---:|---:|---|
| Backup, restore, disaster recovery | 25% | 8.0 | Strong static/mocked behavior; no live recovery; PRR-003 |
| Secrets, access, security boundaries | 20% | 2.0 | PRR-001 P0 and PRR-004; strong underlying SOPS/permission controls |
| Lifecycle, updates, rollback | 15% | 7.5 | Coherent code/tests; real host/failure rollback absent |
| Platform, systemd, installed runtime | 10% | 7.0 | Strong fail-closed mapping and validator; no Noble/systemd execution |
| Network, TLS, email, external dependencies | 10% | 4.5 | PRR-002 and no live Cloudflare/mail proof |
| Junior-operator usability/handoff | 10% | 5.5 | Clear docs overall; secret output and false setup success are severe traps |
| Tests, CI, documentation truthfulness | 10% | 8.0 | Seven green predecessor jobs and local static passes; exact SHA has no runs |

Raw weighted score: **6.0 / 10**. Applied P0 cap: **3.0 / 10**.

## 8. Recovery Characteristics

| Characteristic | Effective behavior at audited SHA |
|---|---|
| Database-backup data-loss window | Scheduled daily at 04:00 with up to 60 seconds randomized delay. With `Persistent=false`, a missed run is not caught up at boot and the effective gap can extend toward two schedule intervals until the next successful run. |
| Full-backup data-loss/config window | Scheduled Sunday at 03:00 with up to 300 seconds randomized delay. With `Persistent=false`, a missed run waits until the next Sunday and the gap can approach two weekly intervals. |
| Retention | Defaults are DB 14 days, full 30 days, emergency 90 days. Retention preserves the newest parseable archive and fails safe for unparseable primary names. |
| Offsite behavior | Scheduled DB/full units request `--rclone --full-verification`. Requested remote skip/failure is not full success; restore-critical metadata travels as a cohort. Emergency offsite behavior is operator/config dependent. |
| Replacement-host prerequisites | Correct repository commit from DR manifest, recovered state/backup cohort, matching Age/offline identity or emergency protection, Noble amd64/arm64 host, storage identity/sentinel, SOPS/Age/rclone/tooling, Cloudflare/mail credentials, and installed runtime refresh. |
| Recovery duration | Unmeasured. Restore scripts have bounded individual timeouts, but no measured RTO exists for representative data sizes, image pulls, DNS/TLS, key acknowledgement, or remote transfer. |
| Recovery objectives | No explicit maintainer-approved RPO/RTO/SLO was found. Schedules and timeouts are implementation facts, not accepted objectives. |
| Maintainer acceptance required | Explicitly accept the daily/weekly missed-run behavior and retention, define maximum tolerable data loss and recovery duration, then record achieved drill measurements. |

## 9. Release Blockers

1. **PRR-001:** supported first-install and key-lifecycle paths emit private key or credential material to command output.
2. **PRR-002:** required UFW and automatic secrets-configuration failures are converted to warnings, allowing `setup.sh install --auto` to return success.

## 10. Mandatory Production Conditions

| ID | Condition | Why required | Completion evidence | Owner |
|---|---|---|---|---|
| C-01 | Implement PRR-001 without losing the one-time credential/recovery handoff | Prevent secret retention in unattended logs, consoles, transcripts, and journals | Focused tests prove synthetic secret markers never appear on stdout/stderr; secure 0600 handoff artifact and cleanup behavior verified on Noble | Secrets/setup/restore maintainers |
| C-02 | Implement PRR-002 | A security-critical setup failure must fail the install | Behavioral setup test returns nonzero for UFW or auto-secrets failure and does not print completion | Setup/firewall/secrets maintainers |
| C-03 | Resolve PRR-003 by moving/excluding recovery-kit artifacts, or explicitly accept and document the narrower risk | Preserve truthful `full` tier key-custody semantics | Behavioral archive listing proves no recovery-kit artifact is present in `full`; metadata remains `emergency_contains_key_material=false` only when true | Backup/secrets maintainers |
| C-04 | Resolve PRR-004 or prove no failure path can leave log files readable by other local users | Avoid bounded local log disclosure | Mode/owner behavioral test plus failed-start host test show dirs 0750/files 0640 | Lifecycle/permissions maintainers |
| C-05 | Run complete CI on the final remediation SHA | Local host could not execute the canonical suite completely | Compose, doc drift, ShellCheck, foundation, security, operations, and data-protection all green on the exact remediation SHA | Maintainer/CI |
| C-06 | Complete authorized Noble amd64 and arm64 acceptance, including restore and reboot | Static/mocked evidence does not verify the supported matrix | Signed checklist evidence from Section 14, with no required skip | Release owner |
| C-07 | Prove one complete local and remote recovery cohort and a replacement-host recovery | Backup existence is not recovery evidence | Archive metadata/checksum, remote listings, restore logs, `/alive`, permission checks, and achieved recovery duration | Operator/release owner |
| C-08 | Validate Cloudflare, CrowdSec/Workers, SMTP/Postfix, alert receipt, time, and credential revocation | These external controls are outside repository-only proof | Redacted screenshots/status/output specified in Appendix E | Operator |
| C-09 | Define and accept RPO/RTO and missed-timer policy | The implementation has schedules but no accepted objective | Maintainer decision recording max data loss, max restore time, and `Persistent=false` acceptance/change | Maintainer |

## 11. Detailed Findings

### PRR-001 — Supported setup and key-lifecycle commands disclose private key or credential material through output

- Audited SHA: `6a7d9e70954c6b05bda25e7b9089b39715965ba8`
- Severity: P0 / Critical
- Release gate: Yes
- Confidence: High
- Classification: Confirmed security defect
- Domain: Secrets, credentials, and key custody
- Affected supported path: `sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto`; interactive setup summary; recovery-kit export; `sudo make key-rotate`; full/emergency restore with Age-key rotation

#### Evidence

- `setup.sh:316-364`, `setup.sh:596-636`
- `lib/secrets.sh:1031-1049`, `lib/secrets.sh:1408-1440`
- `utilities/key-rotate.sh:247-270`, `utilities/key-rotate.sh:486-519`
- `utilities/restore-run.sh:1418-1505`, `utilities/restore-run.sh:3095-3097`
- `README.md:67-70`
- Symbol: `show_post_install_summary`, `auto_generate_secret_field`, `_ork_generate_and_secure`, `_display_rotated_age_key_summary`, `_display_new_key`
- Exact excerpt: `printf '%s%s%s\n' "${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"`; `cat "$output_file"`; `echo "  ${priv_key_line:-<could not read key>}"`.
- Corroborating evidence: the README golden path advertises `setup.sh install --auto`; non-TTY `press_enter_to_continue` does not provide a confidentiality boundary; key rotation/restore already write a mode-0600 recovery file under `/root`, so printing the key is not required for custody.
- Validation result: a synthetic function probe supplied four non-secret markers to the setup summary. Captured output contained the private-key, admin, Caddy, and backup markers once each. No production value was read.

#### Execution or failure trace

1. A junior operator runs the documented `sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto`, possibly through cloud-init, a provider console, SSH recording, `tee`, or redirected automation.
2. Setup bootstraps an Age key and auto-generates admin credentials into root-only temporary files.
3. `show_post_install_summary auto` reads the Age private-key file and plaintext credential captures.
4. It prints them to file descriptor 1. In a non-TTY context the pause does not prevent capture.
5. The setup transcript now contains material that can decrypt SOPS/backups or access the admin surfaces.
6. Equivalent explicit output occurs when supported key rotation/restore prints the new private key; recovery export writes the complete kit with `cat`.

#### Expected contract

`AGENTS.md` requires that normal logs not print secret values and that private-key material remain under restrictive custody. The audit brief explicitly prohibits exposure through command output. The project already supports mode-0600 root recovery artifacts and off-host custody, so a secret-bearing transcript is not necessary.

#### Observed behavior

Current functions explicitly read and print the private key or complete plaintext credential document. Xtrace suppression prevents one leak vector but does not prevent the deliberate output.

#### Small-team production impact

A small deployment is likely to retain setup output in a cloud console, SSH transcript, terminal scrollback, shell automation log, support bundle, or ticket. Disclosure of the operational Age key plus ciphertext can expose all managed secrets and future backups; disclosure of admin credentials enables privileged application access. Rotation after disclosure is operationally expensive and old backups remain sensitive to the old key.

#### Proposed remediation

Use a secure artifact handoff, never a secret-bearing stdout/stderr handoff:

1. Auto setup must atomically write the generated one-time credentials and operational Age key to a root-owned `0600` bootstrap bundle under `/root`, fail if that bundle cannot be created, and print only its path and deletion instructions.
2. Direct auto secret generation must require or create the same secure output artifact; it must not print generated values to `/dev/tty`.
3. Recovery export should print only the protected file path and wait for acknowledgement while the root operator copies it; remove `cat`.
4. Rotation/restore should show the public recipient and existing mode-0600 recovery-kit path, never the private line.
5. Update setup, security, recovery, and generated command-reference contracts together.

#### Proposed production patch

**PROPOSED — NOT APPLIED.**

Design sketch requiring implementation verification.

- Intended invariant: no private key, generated credential, recovery-kit content, or equivalent secret marker may reach stdout, stderr, `/dev/tty`, journald, or a subprocess argument. A supported workflow must still provide a verifiable one-time handoff.
- Owning components: `show_post_install_summary` and phase 6 in `setup.sh`; `auto_generate_secret_field`, `_ork_generate_and_secure`, and `offer_recovery_kit_export` in `lib/secrets.sh`; `_display_rotated_age_key_summary` in `utilities/key-rotate.sh`; `_display_new_key` in `utilities/restore-run.sh`.
- Expected callers: the documented auto and interactive setup paths, direct secrets configuration/export, key rotation, and full/emergency restore with key rotation.
- Required implementation: first introduce one reviewed helper that writes supplied sensitive files through a same-directory restrictive temporary file and atomically installs a root-owned `0600` bundle under `/root`. It must accept file descriptors or file paths rather than secret argument/environment values, reject symlinks/non-root ownership, register `EXIT`/`INT`/`TERM` cleanup before the first write, and return nonzero if custody cannot be committed. Then remove every deliberate content print identified above and emit only the public recipient, protected path, mode/owner verification, copy/delete instructions, and acknowledgement status. Key rotation and restore must reuse their existing root-only kit rather than create a second artifact.
- Failure behavior: if the protected handoff cannot be created, setup/rotation/restore must fail before completion text; it must not fall back to displaying the secret. Interrupted writes must leave no eligible bundle.
- Required caller/document updates: setup and recovery help, README, Deployment, Security, Backup/Restore, Disaster Recovery, bootstrap-recovery documentation, and the owning command-reference generator must describe the protected path and required off-host copy/deletion.
- Implementation verification: inspect the final helper and all callers together for secret-in-argv/environment, symlink, overwrite, signal, ownership, and cleanup behavior before accepting an executable patch.

#### Proposed regression coverage

**PROPOSED — NOT APPLIED.**

Exact test design for `tests/suites/security/case-secrets.bash`, `tests/suites/security/case-security-privileges.bash`, and the closest data-protection restore case:

1. Invoke every affected supported summary/display path with separate synthetic markers in root-only fixture files; capture stdout and stderr separately and assert no marker appears.
2. Assert the committed handoff contains every marker, is a regular non-symlink file, is owned by root, and has mode `0600`.
3. Run no-TTY/EOF, `INT`, and `TERM` cases; assert no marker output and no incomplete artifact.
4. Make the destination unwritable or a symlink; assert a nonzero result, no success text, no secret output, and no fallback display.
5. Verify setup, export, key rotation, and full/emergency restore each print only the expected public recipient/path instructions.
6. Test successful acknowledgement and supported final deletion/cleanup guidance without reading real secrets.

#### Validation

```bash
bash -n setup.sh utilities/key-rotate.sh utilities/restore-run.sh lib/secrets.sh
shellcheck -x --severity=warning \
  setup.sh utilities/key-rotate.sh utilities/restore-run.sh lib/secrets.sh
./tests/run-tests.sh security
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
```

Expected: all commands exit 0; synthetic markers exist only in protected handoff fixtures, never captured output; no incomplete bundle remains after fault injection.

#### Residual risk and limitations

A mode-0600 root file is still highly sensitive and provider snapshots can retain it. The operator must move it off-host, verify it, delete it, and rotate credentials if any previous transcript may contain them. Terminal-emulator recording of paths/public recipients remains acceptable; secret contents do not.

### PRR-002 — First install reports success after required firewall or automatic secrets configuration fails

- Audited SHA: `6a7d9e70954c6b05bda25e7b9089b39715965ba8`
- Severity: P1 / High
- Release gate: Yes
- Confidence: High
- Classification: Confirmed code defect
- Domain: Initial installation, network security, truthful completion
- Affected supported path: documented `sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto`

#### Evidence

- `setup.sh:523-557`, `setup.sh:603-638`
- `docs/DEPLOYMENT.md:40-46`
- `README.md:67-70`
- Symbol: `main`, `_phase_failed`
- Exact excerpt: UFW ends with `|| log_warn "UFW firewall setup had a non-fatal issue — review output above"`; auto secret configuration uses `if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}"; then` followed by `log_warn`; `main` then reaches `return 0`.
- Corroborating evidence: phases 1–4 use `_phase_failed` and fail the command. Deployment docs say the same auto install configures the host firewall and encrypted secret state.
- Validation result: structural control-flow trace. Destructive host execution was correctly not attempted on macOS.

#### Execution or failure trace

1. Operator runs the advertised auto install.
2. UFW CIDR retrieval/rule application fails, or automatic admin/secrets configuration fails.
3. `setup.sh` converts the nonzero child status to a warning.
4. The post-install summary runs and `main` returns 0.
5. Automation or a junior operator interprets zero as completed setup even though Cloudflare-origin restriction or usable admin secret state is absent.

#### Expected contract

Security-critical supported setup phases must return nonzero on real failure. The Cloudflare-only origin boundary is part of the documented production path, and setup completion text/exit status must be truthful.

#### Observed behavior

The exact required child failures are swallowed. The separate iptables phase is explicitly best effort; this finding gates only the documented UFW phase and auto secrets configuration.

#### Small-team production impact

The origin can remain reachable outside the intended Cloudflare path, bypassing WAF/Workers enforcement, or the installation can lack usable administrative credentials. A junior operator may proceed because the command succeeded and the summary looks complete.

#### Proposed remediation

Use the existing `_phase_failed` mechanism for UFW and auto-secrets failures. Keep truly optional iptables remediation explicitly warning-only, but state that distinction in the summary. Do not print final completion after either required failure.

#### Proposed production patch

**PROPOSED — NOT APPLIED.**

```diff
diff --git a/setup.sh b/setup.sh
--- a/setup.sh
+++ b/setup.sh
@@
-    "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase ufw \
-        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" \
-        || log_warn "UFW firewall setup had a non-fatal issue — review output above"
+    "${SCRIPT_DIR}/utilities/setup-firewall.sh" --phase ufw \
+        "${_auto[@]}" "${_dry[@]}" "${_force[@]}" \
+        || _phase_failed 5 "UFW firewall setup" \
+            "The Cloudflare-origin allowlist was not installed." \
+            "Re-run: sudo ./utilities/setup-firewall.sh --phase ufw"
@@
-        if ! "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}"; then
-            log_warn "Secrets auto-configuration encountered issues — run 'sudo make edit-env', then retry with 'sudo ./setup.sh secrets'"
-        fi
+        "${SCRIPT_DIR}/utilities/setup-secrets.sh" configure "${secrets_args[@]}" \
+            || _phase_failed 6 "Secrets configuration" \
+                "Required automatic secret configuration did not commit." \
+                "Re-run: sudo ./setup.sh secrets"
```

#### Proposed regression coverage

Target `tests/suites/security/case-security-privileges.bash`:

**PROPOSED — NOT APPLIED.**

Design sketch requiring implementation verification.

1. Add a sibling subshell test beside the existing `check_setup_force_acknowledgement` isolated `GUARD_ROOT` fixture, copying the current `setup.sh` and only its required libraries.
2. Make the real setup parser and `main` execute with `VW_TEST_MODE=true`, a successful synthetic operation guard, no TTY, and executable phase stubs that append their phase name/arguments to a call log. All stubs return 0 by default.
3. In case A, make only `utilities/setup-firewall.sh --phase ufw` return 1. Assert setup returns nonzero, emits the phase-5 `_phase_failed` diagnosis, never invokes iptables or phase 6, and never calls `show_post_install_summary`.
4. In case B, let phases 1–5 pass and make only `utilities/setup-secrets.sh configure` return 1. Assert setup returns nonzero, emits the phase-6 diagnosis, and never calls `show_post_install_summary`.
5. Add a success control in which every stub returns 0 and the final-summary sentinel is reached once.
6. Keep all stubs inside the temporary copied tree so no package, UFW, key, filesystem, or host mutation occurs.

#### Validation

```bash
bash -n setup.sh tests/suites/security/case-security-privileges.bash
shellcheck -x --severity=warning setup.sh \
  tests/suites/security/case-security-privileges.bash
./tests/run-tests.sh security
./tests/run-tests.sh all
```

On a disposable Noble host, additionally force the UFW helper to return a controlled nonzero before mutation and confirm setup returns nonzero and leaves the prior rules unchanged.

#### Residual risk and limitations

UFW success does not prove provider firewall, proxy, IPv6, or Worker correctness. Those remain host/account acceptance items. Rerun semantics must remain idempotent after the now-fatal partial setup.

### PRR-003 — A concurrent or abandoned plaintext recovery kit can enter a nominally key-free full backup

- Audited SHA: `6a7d9e70954c6b05bda25e7b9089b39715965ba8`
- Severity: P2 / Medium
- Release gate: Conditional
- Confidence: High
- Classification: Confirmed security defect
- Domain: Backup tier integrity and secret custody
- Affected supported path: standalone `sudo ./utilities/secrets-export-recovery-kit.sh` overlapping `full` backup, or a recovery-kit file surviving in the project root

#### Evidence

- `utilities/secrets-export-recovery-kit.sh:56-68`, `utilities/secrets-export-recovery-kit.sh:129-152`
- `lib/secrets.sh:1465-1505`
- `utilities/backup-run.sh:1279-1323`
- `docs/BACKUP-RESTORE.md:16-21`
- `tests/suites/data-protection/case-backup.bash:27-40`
- Symbol: `offer_recovery_kit_export`, `perform_full_backup`
- Exact excerpt: `recovery_file="./recovery-kit-$(date +%s).txt"` and `tar_sources+=("${SCRIPT_DIR#/}")`; no recovery-kit pattern appears in `_BACKUP_EXCLUDES`.
- Corroborating evidence: the standalone export does not source/acquire `lib/operations.sh`; the current backup test checks direct Age-key exclusions but not equivalent recovery-kit artifacts.
- Validation result: confirmed by source-to-sink archive-argument trace. No production archive was opened.

#### Execution or failure trace

1. Operator starts the supported standalone recovery-kit export.
2. The library writes a mode-0600 plaintext file containing the operational Age private key and all credentials in the project root, potentially for up to 30 minutes.
3. A scheduled or manual full backup acquires its own guard, but export holds no global guard.
4. Full backup archives the project root and does not exclude `recovery-kit-*.txt`.
5. Metadata continues to describe the full tier as not containing key material.

#### Expected contract

The documented `full` tier excludes the live operational private key; only `emergency` is clone-grade key-bearing material. Equivalent private-key containers must follow the same exclusion contract.

#### Observed behavior

The primary key path is excluded but a project-root recovery kit containing the same key and all credentials is not. The resulting archive remains Age-encrypted, so this is not equivalent to plaintext remote disclosure, but its decrypted contents and metadata violate the tier boundary.

#### Small-team production impact

An operator can decrypt a `full` archive for inspection or recovery believing it contains ciphertext/config but no live key, then expose a plaintext kit in staging or copied tar contents. Key-retirement, sharing, and incident-response decisions based on metadata become unreliable.

#### Proposed remediation

Write the durable no-TTY handoff under `/root`, never inside either archive source. Add defense-in-depth exclusions for legacy/abandoned recovery-kit names under project/state roots. Serialize export with the shared global operation guard if it continues to create any archive-visible sensitive artifact.

#### Proposed production patch

**PROPOSED — NOT APPLIED.**

```diff
diff --git a/lib/secrets.sh b/lib/secrets.sh
--- a/lib/secrets.sh
+++ b/lib/secrets.sh
@@ offer_recovery_kit_export() {
-    recovery_file="./recovery-kit-$(date +%s).txt"
+    recovery_file="/root/vaultwarden-recovery-kit-$(date +%s).txt"
diff --git a/utilities/secrets-export-recovery-kit.sh b/utilities/secrets-export-recovery-kit.sh
--- a/utilities/secrets-export-recovery-kit.sh
+++ b/utilities/secrets-export-recovery-kit.sh
@@
 source "${PROJECT_ROOT}/lib/common.sh"
+source "${PROJECT_ROOT}/lib/operations.sh"
@@ main() {
+    operation_acquire \
+        --id recovery-kit-export \
+        --label "Recovery kit export" \
+        --specific-lock /run/lock/vaultwarden-recovery-kit.lock \
+        --non-interactive fail || exit $?
+    trap 'rc=$?; operation_release "$rc"; perform_cleanup; exit "$rc"' EXIT
diff --git a/utilities/backup-run.sh b/utilities/backup-run.sh
--- a/utilities/backup-run.sh
+++ b/utilities/backup-run.sh
@@
     tar_excludes+=(
+        "--exclude=${SCRIPT_DIR#/}/recovery-kit-*.txt"
+        "--exclude=${SCRIPT_DIR#/}/vaultwarden-recovery-kit-*"
+        "--exclude=${state_dir#/}/recovery-kit-*.txt"
+        "--exclude=${state_dir#/}/vaultwarden-recovery-kit-*"
         "--exclude=${state_dir#/}/.pre-restore-*"
```

Update `utilities/secrets-export-recovery-kit.sh --help`, `docs/BACKUP-RESTORE.md`, `docs/SECURITY.md`, and the generated command reference to describe the `/root` handoff and deletion.

#### Proposed regression coverage

Target `tests/suites/data-protection/case-backup.bash` and `tests/suites/security/case-secrets.bash`:

**PROPOSED — NOT APPLIED.**

Design sketch requiring implementation verification.

1. Extend `check_backup_architecture_policy` with source-structure assertions for all four explicit project/state exclusion arguments; this protects the dispatch contract.
2. Extend the existing full-archive functional harness in `check_backup_preflight_and_metadata_safety`: create project-root and state-root files named `recovery-kit-synthetic.txt` and `vaultwarden-recovery-kit-synthetic.txt`, run the real tar-argument construction with its existing external-command stubs, list the scratch archive, and fail if either basename is present.
3. In the security suite, run the standalone export against fixture secrets and overridden temporary operations paths. Assert the durable path is outside both archive roots, is a regular non-symlink file, has mode `0600`, and contains only synthetic markers.
4. Hold the real shared global guard in a first subprocess, invoke export in a second noninteractive subprocess, and assert the documented contention status with no recovery file created.
5. Send `TERM` during generation and assert operation metadata is released and every incomplete fixture is removed.

#### Validation

```bash
bash -n lib/secrets.sh utilities/secrets-export-recovery-kit.sh \
  utilities/backup-run.sh
shellcheck -x --severity=warning lib/secrets.sh \
  utilities/secrets-export-recovery-kit.sh utilities/backup-run.sh
./tests/run-tests.sh security
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
```

Expected: the behavioral archive listing contains neither current nor legacy kit patterns; interrupted export cleans incomplete output; export and backup cannot overlap.

#### Residual risk and limitations

Full backups still contain SOPS ciphertext and sensitive configuration by design and require strong offsite custody. `/root` may be included in whole-VM/provider snapshots; the operator must delete the handoff after verified off-host storage.

### PRR-004 — Startup temporarily changes non-Caddy log files to world-readable mode

- Audited SHA: `6a7d9e70954c6b05bda25e7b9089b39715965ba8`
- Severity: P2 / Medium
- Release gate: Conditional
- Confidence: High
- Classification: Confirmed security defect
- Domain: Privilege and filesystem boundaries
- Affected supported path: every supported foreground/systemd startup before `init-permissions` completes, especially a startup that fails before container repair

#### Evidence

- `startup.sh:369-405`
- `docker-compose.yml.example:49-64`
- `lib/runtime-permissions.sh:80-104`
- `tests/suites/foundation/case-permissions.bash:224-259`
- Symbol: `prepare_log_directories`
- Exact excerpt: `_maybe_sudo chmod -R 755 "${project_state_dir}/logs" 2>/dev/null || true`.
- Corroborating evidence: Compose and runtime-permission owners specify directory `0750` and file `0640`; startup repairs only Caddy immediately. Existing focused tests exercise Caddy, not Vaultwarden/non-Caddy logs in this startup function.
- Validation result: direct mode semantics are unambiguous: recursive `0755` makes existing regular files readable/executable by all local users until later repair.

#### Execution or failure trace

1. Supported startup calls `prepare_log_directories`.
2. It recursively owns all log content as `PUID:PGID` and applies `0755` to directories and files.
3. It immediately restores Caddy paths only.
4. Compose normally starts `init-permissions`, which later applies `0750`/`0640`.
5. If image pull, Compose creation, init startup, or another intervening step fails, Vaultwarden/non-Caddy files remain `0755`.

#### Expected contract

Known runtime-permission owners consistently define log directories as `0750` and log files as `0640`. Logs can contain email addresses, IP addresses, request metadata, or operational error context and should not be readable by unrelated local users.

#### Observed behavior

Startup creates a bounded but real world-readable window and a persistent failure state. The eventual successful init repair does not invalidate the earlier mode change.

#### Small-team production impact

On a single-purpose VM the number of local users may be small, which bounds exposure. Break-glass, support, monitoring, or compromised low-privilege accounts can nevertheless read historical application logs after a failed start.

#### Proposed remediation

Set directory and file modes separately in startup, matching the canonical runtime-permission helper. Preserve the immediate Caddy ownership correction.

#### Proposed production patch

**PROPOSED — NOT APPLIED.**

```diff
diff --git a/startup.sh b/startup.sh
--- a/startup.sh
+++ b/startup.sh
@@ prepare_log_directories() {
     _maybe_sudo chown -R "${puid}:${pgid}" "${project_state_dir}/logs" 2>/dev/null || true
-    _maybe_sudo chmod -R 755 "${project_state_dir}/logs" 2>/dev/null || true
+    _maybe_sudo find "${project_state_dir}/logs" -type d -exec chmod 750 {} + \
+      || { log_error "Failed to secure log directories"; return 1; }
+    _maybe_sudo find "${project_state_dir}/logs" -type f -exec chmod 640 {} + \
+      || { log_error "Failed to secure log files"; return 1; }
```

#### Proposed regression coverage

Target `tests/suites/foundation/case-permissions.bash`:

**PROPOSED — NOT APPLIED.**

Design sketch requiring implementation verification.

1. Add a new subshell case beside `check_caddy_log_permission_helper`.
2. Extract the current `prepare_log_directories` function from `startup.sh` with a brace-depth extractor defined completely in the test. Stub logging and `get_config_value`; make `_maybe_sudo` execute only against the temporary fixture; make `ensure_caddy_log_permissions` return success after recording its path.
3. Define `_VW_DEFAULT_LOG_SERVICES`, `_VW_DEFAULT_STATE_DIR`, PUID, PGID, and `DRY_RUN=false` in the fixture. Create existing service directories at `0777` and log files at `0666`.
4. Invoke the extracted production function. Using the repository’s portable `_common_stat_mode`, assert every service directory is `0750`, every regular file is `0640`, and the Caddy helper received the exact Caddy path.
5. Make the stubbed `find` fail for the directory pass and then the file pass; each invocation must return nonzero rather than report success.
6. Add a dry-run control proving the fixture remains untouched.

#### Validation

```bash
bash -n startup.sh tests/suites/foundation/case-permissions.bash
shellcheck -x --severity=warning startup.sh \
  tests/suites/foundation/case-permissions.bash
./tests/run-tests.sh foundation
./tests/run-tests.sh operations
./tests/run-tests.sh all
```

On Noble, stop after `prepare_log_directories` in a disposable fixture or force a controlled pre-Compose failure and confirm every existing log remains `0640` under `0750`.

#### Residual risk and limitations

Log content still requires application-level redaction and retention controls. Docker JSON logs and journald have separate permissions/retention and must be checked during host acceptance.

### PRR-005 — Supported `EMAIL_MODE=direct` is omitted from startup’s valid-mode contract

- Audited SHA: `6a7d9e70954c6b05bda25e7b9089b39715965ba8`
- Severity: P3 / Low
- Release gate: No
- Confidence: High
- Classification: Confirmed code defect
- Domain: Email configuration and operator truthfulness
- Affected supported path: startup with documented `EMAIL_MODE=direct`

#### Evidence

- `lib/defaults.sh:47-54`
- `startup.sh:187-223`
- `lib/email.sh:677-683`
- `tests/suites/security/case-email.bash:70-82`
- `docs/EMAIL.md:108-118`
- Symbol: `_VW_DEFAULT_EMAIL_MODES`, `check_email_config_consistency`, `send_email`
- Exact excerpt: defaults list `auto api smtp host`; email routing accepts `auto api smtp direct host`.
- Corroborating evidence: tests prove direct delivery behavior, but no test covers startup warning output.
- Validation result: static contract comparison.

#### Execution or failure trace

The operator selects the supported direct mode. Email routing correctly uses direct SMTP, but startup falls through to the unknown-mode warning and omits the intended `smtp_password` preflight.

#### Expected contract

One canonical list and the startup checker should recognize every mode accepted by `lib/email.sh` and documented to operators.

#### Observed behavior

Direct delivery works, but startup reports a false configuration warning and does not perform the direct-mode password-file check.

#### Small-team production impact

This does not stop service or email by itself. It creates alert fatigue and removes an early actionable warning for a missing SMTP password.

#### Proposed remediation

Add `direct` to the canonical defaults and treat `direct|host` like the direct SMTP credential path, retaining the deprecation warning for `host` at send time.

#### Proposed production patch

**PROPOSED — NOT APPLIED.**

```diff
diff --git a/lib/defaults.sh b/lib/defaults.sh
--- a/lib/defaults.sh
+++ b/lib/defaults.sh
@@
     api
     smtp
+    direct
     host
diff --git a/startup.sh b/startup.sh
--- a/startup.sh
+++ b/startup.sh
@@
-    smtp)
+    smtp|direct|host)
      local pw_file="${secrets_dir}/smtp_password"
      if [[ ! -f "$pw_file" ]] || [[ ! -s "$pw_file" ]]; then
-        log_warn "EMAIL_MODE=smtp is set but '${pw_file}' is absent or empty."
+        log_warn "EMAIL_MODE=${email_mode} is set but '${pw_file}' is absent or empty."
         log_warn "  SMTP relay authentication will fail on first send."
         log_warn "  Fix: ./utilities/secrets-rotate.sh smtp_password"
       fi
       ;;
-    auto|host)
+    auto)
       ;;
```

#### Proposed regression coverage

**PROPOSED — NOT APPLIED.**

Add a startup consistency probe to `tests/suites/security/case-email.bash`: `direct` must not produce “not recognised,” must warn when `smtp_password` is absent, and must be quiet when it is nonempty.

#### Validation

```bash
bash -n lib/defaults.sh startup.sh tests/suites/security/case-email.bash
shellcheck -x --severity=warning lib/defaults.sh startup.sh \
  tests/suites/security/case-email.bash
./tests/run-tests.sh security
./tests/run-tests.sh all
```

#### Residual risk and limitations

Successful configuration preflight does not prove SMTP authentication, TLS policy, relay acceptance, queue durability, or mailbox receipt.

## 12. Non-Defect Items

### 12.1 Automated coverage gaps

- No permanent test protects the “no secret marker on stdout/stderr” contract across setup, export, rotation, and restore.
- Backup tests exclude direct Age-key paths but do not behaviorally prove recovery-kit aliases are absent.
- Permission coverage focuses on Caddy and does not exercise `prepare_log_directories` for historical Vaultwarden files.
- No setup orchestration test proves a failing required child phase prevents the final summary.
- Real Linux `flock`, `/proc` identity, systemd sandboxing, block devices, firewall, and destructive restore behavior necessarily require host acceptance in addition to mocks.

These gaps corroborate but do not create the confirmed defects.

### 12.2 Documentation drift

- `docker-compose.yml.example:2` still says the core flow ends in `fail2ban`; executable/docs use CrowdSec.
- Setup summary describes an auto-generated “backup passphrase” although that secret is retired from the active schema.
- Recovery-export help says the output is tmpfs-backed while the library first writes a project-root persistent copy.
- Documentation affected by PRR-001/002 must be changed with the executable contract, not pre-emptively.

### 12.3 CI and process gaps

- The exact audited SHA had **zero** check runs and zero workflow runs.
- The immediately preceding code-changing PR head `141f0d238488c8df43c72ab29ab6a9f56c95d696` had seven successful jobs: Compose, doc drift, ShellCheck, and all four functional suites. The audited commit only deleted historical reports, so this is relevant but not exact-SHA proof.
- `.github/workflows/doc-drift.yml` triggers only on `pull_request`; direct candidate-branch commits receive no validation.
- Third-party Actions use mutable major tags (`actions/checkout@v4`, `actions/upload-artifact@v4`) rather than immutable commit SHAs.
- `reports/**` is not a path trigger, which is reasonable for report-only changes but should be explicit in release evidence.

### 12.4 Production-host acceptance items

Every item in Section 14 remains unexecuted. High-value gates are clean-host setup, UFW/origin bypass, both architectures, six timers after reboot, all backup tiers, remote cohorts, full/emergency restore, replacement-host recovery, update rollback, disk pressure, and real alert receipt.

### 12.5 External prerequisites

Cloudflare account/zone/token policy, Worker/KV route configuration, provider ingress, SMTP relay and sender authorization, offsite rclone storage, NTP, external DNS, registries, and provider volume semantics are not controlled solely by this repository.

### 12.6 Advisory hardening opportunities

- Pin Compose images by digest or record/verify expected digests at release time; semantic tags can otherwise move when startup pulls.
- Require a checksum asset and preferably signed provenance before executing the Cloudflare Workers bouncer release’s bundled `install.sh`; do not continue unverified when a checksum URL is absent.
- Verify the SOPS checksum file’s Sigstore bundle, not only a checksum downloaded from the same release channel.
- Consider immutable commit pins for GitHub Actions.
- BusyBox 1.36.1 has known `awk`/`tar` advisories. The init container does not invoke those applets in the reviewed command, so no exploitable supported path was confirmed, but image refresh/SBOM scanning should remain part of release maintenance.

### 12.7 Accepted design trade-offs

- Root-operated production lifecycle.
- Three intentionally different backup tiers.
- Postfix’s default transient queue.
- Cloudflare Worker request-limit failure mode set fail-open for availability.
- `Persistent=false` calendar timers avoid unsafe catch-up on recovered/not-ready hosts, at the cost of a longer missed-run window.
- Expected lock contention can be clean exit 75 for scheduled jobs; real failures remain failures.
- Email is not the only incident signal.

### 12.8 Unverified questions

- What RPO and RTO will the maintainer accept?
- What are representative database/attachment sizes and restore-staging capacity?
- Are provider ingress rules Cloudflare-only for both IPv4 and IPv6?
- Are previous setup/rotation/restore transcripts retained, requiring immediate key/credential rotation?
- Are all current full backups free of project-root recovery-kit artifacts?
- Does the installed runtime match this SHA on existing hosts?
- Are both bouncers and the Worker route actually enforcing locally generated decisions?

## 13. Positive Controls and Clean Areas

| Control reviewed | Evidence at audited SHA | Result |
|---|---|---|
| Supported host detection | `utilities/setup-system.sh:82-140` rejects non-Ubuntu, non-24.04, missing/inconsistent Noble codename, and unknown architecture | Clean |
| Download architecture mapping | setup and CrowdSec helpers explicitly map amd64/arm64 and fail unknown values | Clean |
| Docker repository trust | `utilities/setup-system.sh:446-517` verifies the Docker signing-key fingerprint before apt use | Clean |
| yq/SOPS pinning | yq has repository-owned per-architecture hashes; SOPS binary hash is checked; explicit latest mode is separate | Clean with provenance hardening opportunity |
| Environment authority | `lib/config.sh` and `docs/ARCHITECTURE.md` align repository, persistent, and installed order plus explicit caller overrides | Clean |
| Operational Age/offline distinction | schema, crypto, recovery, and docs preserve operational versus offline key custody; recovery generates a new operational key | Clean aside from output finding |
| Shared operation guards | `lib/operations.sh`, backup, restore, setup, update, migration, and systemd callers align on kernel lock authority and exit 75 where documented | Clean |
| Backup SQLite consistency | `utilities/backup-run.sh` creates and integrity-checks a staged snapshot; full/emergency replace live DB/WAL/SHM with that snapshot | Clean |
| Backup truthfulness | required verification failure removes eligibility; requested rclone skip/failure is distinct; metadata is restore-critical cohort state | Clean aside from recovery-kit alias |
| Retention safety | newest parseable recovery point is preserved; unparseable primary names fail safe | Clean |
| Restore preflight/staging | selected archive tools, keys, space, traversal, contents, storage, and start policy are checked before controlled mutation | Clean statically |
| Restore transaction | explicit staged promotion, pre-restore snapshot, rollback, commit boundary, permission repair, and post-commit failure truth | Clean statically |
| Storage safety | boot-device refusal, stable explicit selection, format authorization, mount/sentinel checks, resumable state | Clean statically |
| Update rollback | pre-update DB backup, image-ID cohort snapshot, partial-pull rollback, no restart on complete pull failure | Clean statically |
| Compose isolation | Vaultwarden/Caddy non-root, cap drops, read-only filesystems where compatible, tmpfs, loopback admin/SMTP bindings, resource bounds | Clean statically |
| Installed systemd runtime | explicit `/opt` copies, environment/key modes, unit hardening, state-dir drop-ins, six-timer validator | Clean statically |
| Health truth | unavailable critical probes are not green; smoke-test `SKIP` is non-ready; startup propagates critical readiness/health failures | Clean statically |
| Health incident serialization | incident/cooldown state uses locks and bounded summaries; local operations case passed before later missing-tool stop | Clean |
| Email secret transport | API token/payload avoid argv; recovery attachment uses independent GPG protection; Postfix is loopback-only | Clean statically |
| CI organization | one canonical suite inventory, four matrix suites, strict ShellCheck, Compose and doc drift; predecessor run had seven green jobs | Clean structure; exact-head gap noted |

## 14. Production-Host Acceptance Checklist

This checklist is a procedure, not executed evidence. Use only authorized disposable Ubuntu 24.04 LTS hosts and synthetic/nonproduction vault data. Take a provider snapshot before every destructive or fault-injection group. Never capture secret values: redact environment, token, key, recovery-kit, SMTP auth, and decrypted output. “Capture” means command, UTC timestamps, exit code, bounded non-secret output, and relevant journal/container log references. A row passes only when its stated criterion is met without an unexplained skip.

### Platform

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Ubuntu 24.04 amd64 | Fresh amd64 Noble VM | `cat /etc/os-release; dpkg --print-architecture; sudo ./utilities/setup-system.sh --dry-run --skip-deps` | Noble/amd64 accepted; dry run plans supported packages | OS release, architecture, exit, setup preflight lines | Destroy VM or retain for next tests | Pass only on exit 0 and exact Noble/amd64 detection |
| Ubuntu 24.04 arm64 | Fresh arm64 Noble VM | Same commands as amd64 row | Noble/arm64 accepted and arm64 assets selected | Same plus selected yq/SOPS/Workers assets | Destroy VM or retain | Pass only on exit 0 and no amd64 fallback |
| Unsupported platform rejection | Disposable Debian/Ubuntu 22.04 or test override fixture | `VAULTWARDEN_OS_RELEASE_FILE=/tmp/unsupported-os-release VAULTWARDEN_TEST_ARCH_HELPERS=1 bash utilities/setup-system.sh supported-host amd64` using a root-owned fixture containing non-Noble values | Nonzero before mutation with explicit unsupported reason | Fixture contents, exit, error; no secret data | Delete fixture | Pass on clear nonzero and no package/storage mutation |
| Clean-host dependencies | Fresh supported VM with no project packages added | `sudo ./utilities/setup-system.sh`; then `docker compose version; age --version; sops --version; yq --version; command -v flock zstd rclone` | Required pinned/repository-compatible tools present; Docker active | Package versions, Docker status, command paths | Revert snapshot if host not retained | Pass if all required commands work and yq/SOPS versions match policy |
| Interrupted package installation recovery | Provider console and pre-setup snapshot | Start normal setup; power-cycle the disposable VM during package installation rather than killing apt/dpkg. After boot: `sudo systemctl is-system-running --wait; sudo dpkg --audit; sudo dpkg --configure -a; sudo apt-get -f install; sudo ./setup.sh install --domain vault-test.example --email admin@example.test --auto` | Package manager recovers; operation metadata is conservative; rerun is idempotent | Before/after dpkg audit, setup exit, operations status | Revert/destroy VM | Pass if no corrupt dpkg state and rerun completes or fails with actionable nonzero |

### Installation

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| First-time setup | Clean supported host; test domain/account credentials; PRR-001/002 remediated | `sudo ./setup.sh install --domain vault-test.example --email admin@example.test --auto` | Six required phases complete; no secret in captured output; secure handoff path only | Redacted transcript, exit, phase lines, handoff file mode/owner (not content) | Move synthetic handoff off-host then securely delete; revert host | Pass on exit 0, all required phases, no marker/secret output |
| Generated-file permissions | Completed setup; set `TEST_STATE_DIR` to the configured non-secret state path | `sudo utilities/repair-permissions.sh --check; sudo find /etc/vaultwarden "$TEST_STATE_DIR/config" "$TEST_STATE_DIR/secrets" -maxdepth 2 -printf '%m %u:%g %p\n'` | Private dirs/files match 0700/0600 policy; runtime paths match owners | Permission listing with filenames only | None | Pass if checker exits 0 and no private file is group/other readable |
| Placeholder detection | Fresh setup with one deliberately synthetic placeholder via supported fixture | `sudo ./utilities/secrets-list.sh; sudo ./utilities/smoke-test.sh` | Readiness refuses required placeholders without printing values | Exit/status and field names only | Rotate fixture through `sudo ./edit-secrets.sh rotate <field>` | Pass if placeholder blocks readiness and rotation clears it |
| Setup rerun | Successful initial setup and snapshot | Repeat exact setup command without `--force`, then with documented confirmation only if needed | Existing state protected; rerun is idempotent or asks explicit confirmation | Exit, prompts, diff of non-secret config paths | Revert if forced test changes state | Pass if no silent overwrite/key replacement and state remains decryptable |
| Partial setup recovery | Snapshot; inject controlled failure in phase 3/4/5 | Run setup to failure, `sudo make operations`, correct fixture, rerun same command | Nonzero at fault, no false completion, safe resume via rerun | Phase/exit/operations metadata and final success | Remove fault fixture | Pass if partial state is safe and rerun does not require manual destructive cleanup |
| Root enforcement | Non-root user without Docker group reliance | `./setup.sh install --domain vault-test.example --email admin@example.test --auto` | Fails before meaningful mutation with sudo guidance | Exit/output and before/after path inventory | None | Pass on nonzero and no root-owned/project mutation |
| Noninteractive setup | PRR-001/002 fixed; no controlling TTY | `sudo -n bash -c './setup.sh install --domain vault-test.example --email admin@example.test --auto </dev/null >setup.out 2>setup.err'` | Bounded completion or actionable nonzero; no prompt hang or secret marker | Exit, duration, redacted output, file modes | Securely delete output and handoff; revert snapshot | Pass if deterministic, no secret output, and required failure is nonzero |
| EOF and signal interruption | Snapshot at each phase | EOF: run noninteractive without answers. Signal: from a second root console `systemctl kill -s TERM --kill-who=main <transient-setup-scope>` | EOF fails safe; TERM exits 143; locks/temp plaintext cleaned; package manager not killed by conflict logic | Exit, `make operations`, temp/lock inventory, dpkg status | Let package manager settle; revert snapshot | Pass if no success, no orphan plaintext, and rerun is safe |

### Runtime

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Compose render | Generated environment with synthetic secrets | `sudo docker compose --env-file .env -f docker-compose.yml config --quiet` and example render using `.env.example` | Both valid; no unsupported/missing interpolation | Compose version and exits; do not capture rendered secrets | None | Pass if exit 0 |
| Image pull/build | Registry access | `sudo docker compose pull; sudo docker compose build --pull caddy; sudo docker compose images; for image_id in $(sudo docker compose images -q); do sudo docker image inspect "$image_id" --format '{{json .RepoDigests}}'; done` | All images available; Caddy modules build for host arch | Image names, IDs/digests, build exit | Prune only test images after host disposal | Pass if no mutable/partial cohort and required digests recorded |
| Initial startup | Setup complete; external tokens set | `sudo make up` | Critical Vaultwarden/Caddy healthy; Postfix status explicit; startup exit truthful | Exit, `docker compose ps`, bounded logs | `sudo make down` if ending test | Pass on exit 0 and critical health |
| `/alive` verification | Stack up; test DNS | `curl -fsS --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive"` and external `curl -fsS "https://$DOMAIN/alive"` | Local SNI and external proxied path return alive | HTTP status/timing/cert subject, no cookies | None | Pass if both return expected body/status |
| Restart | Healthy stack | `sudo make restart; sudo make health` | Guarded restart returns healthy without secret loss | Exits, operations phases, ps/health | None | Pass if health green and no stale lock |
| Reboot | Healthy stack and enabled timers | `sudo systemctl reboot`; after reconnect: `systemctl status vaultwarden-startup.service; sudo make health; sudo ./setup.sh systemd validate` | Mount ordering, secret recreation, containers, timers recover | Boot ID/time, unit status, health, validator | None | Pass if no skipped required check |
| Unhealthy-container handling | Snapshot; safe test container only | `sudo docker stop vaultwarden_app; sudo systemctl start vaultwarden-health.service; sudo make health` | Health reports failure and fix policy acts only as documented; alert fires | Service exit, journal, container state, alert receipt | `sudo make up` | Pass if no false green and recovery/alert is truthful |
| Docker restart | Healthy stack | `sudo systemctl restart docker; sudo systemctl start vaultwarden-startup.service; sudo make health` | Containers reconcile without stale secrets/network state | Docker/startup journals and health | None | Pass if healthy and no manual bare Compose workaround |
| Network outage | Provider console; upstream egress rule that preserves SSH/console | Temporarily deny DNS/HTTPS egress at provider test firewall; run `sudo make restart` and `sudo ./maintenance.sh health`; restore egress and retry | Pull/DNS/TLS checks fail or warn exactly as owned; no false readiness; recovery succeeds | Exits, warnings, health before/after | Restore provider egress | Pass if outage is truthful and recovery needs no state surgery |
| Disk-full simulation | Disposable loopback filesystem mounted as test `PROJECT_STATE_DIR` | Create a fixed-size loop file, `mkfs.ext4` that file, mount under `/mnt/vw-test-full`, point a disposable test env there, fill with `fallocate`, run health/backup | Capacity warnings/failures occur before corrupt promotion; old recovery points retained | `df`, exits, logs, archive inventory | Unmount and delete loop file; restore env | Pass if nonzero is truthful and live data/old backups remain valid |
| Installed-runtime drift | Installed systemd runtime, then alter one disposable `/opt` copy | `sudo ./setup.sh systemd validate`; modify only a test copy; rerun validate; `sudo ./setup.sh systemd install --enable-now; sudo ./setup.sh systemd validate` | Drift detected, reinstall repairs it | Validator before/drift/after | Restore from installer | Pass if stale runtime cannot validate |

### Edge and security

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| DNS-01 certificate issuance | Test zone/token and proxied hostname | Start Caddy with empty test cert state; `docker compose logs -f caddy` until issuance; `openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN"` | Valid certificate issued via DNS-01 without opening an alternate challenge path | Redacted Caddy lines, cert chain/dates | Remove test DNS record/host after suite | Pass if trusted cert and token absent from logs |
| Certificate renewal | Disposable copied Caddy state or short-lived staging cert | Use Caddy staging CA/test cert lifecycle; trigger documented reload/restart and observe renewal | Renewal succeeds without permission drift/outage | Old/new serial/dates, Caddy log, `/alive` | Restore production CA setting/test state | Pass if cert changes and service stays healthy |
| Cloudflare proxy | Proxied test record | `dig +short "$DOMAIN"; curl -sSI "https://$DOMAIN/alive"` | DNS resolves Cloudflare; response traverses proxy | DNS answers, CF headers, status | None | Pass if proxy enabled and origin not exposed by DNS |
| Origin bypass attempt | External authorized probe and origin IP | `curl -vk --resolve "$DOMAIN:443:$ORIGIN_IP" "https://$DOMAIN/alive"` from a non-Cloudflare IP | Connection blocked at provider/UFW boundary | Client timeout/refusal plus UFW counters | None | Pass only if direct origin cannot reach 80/443 |
| Firewall behavior | Setup complete | `sudo ufw status numbered; sudo iptables-save; sudo ./maintenance.sh update-firewall` | SSH policy retained; web only Cloudflare CIDRs; update transactional | Rules/counters and update exit | None | Pass if no broad 80/443 allow and update is idempotent |
| IPv4 and IPv6 | Dual-stack test host/zone | `curl -4` and `curl -6` proxied `/alive`; repeat authorized origin-bypass probes; inspect `ufw status`/`ip6tables-save` | Both families follow same proxy/origin policy or IPv6 is explicitly disabled upstream | Results/rules for both families | None | Pass if no IPv6 bypass |
| CrowdSec decision | Safe test source IP not used for administration | `sudo cscli decisions add --ip "$TEST_IP" --duration 5m; sudo cscli decisions list; sudo cscli decisions delete --ip "$TEST_IP"` | Decision appears, syncs, and deletes/expires | cscli output and both bouncer logs | Delete decision | Pass if lifecycle visible and admin remains reachable |
| Cloudflare edge enforcement | Prior safe decision and Worker route | Request from controlled `$TEST_IP`; inspect Workers/KV dashboard/log and HTTP result | Edge blocks decision while unrelated source remains allowed | Redacted Worker/KV evidence and HTTP statuses | Delete decision/KV key if needed | Pass if real-client edge block is proven |
| API-token failure | Snapshot; substitute revoked/least-privilege test token through SOPS rotation | Run DNS/firewall/Worker apply and health | Clear nonzero/degraded state; previous working config not destroyed | Exits, health, redacted API error | Restore valid token via rotate/apply | Pass if failure is safe and no token leaks |
| System-clock failure/warning | Disposable clone with provider console | `sudo timedatectl set-ntp false; sudo date -s '10 minutes ago'; sudo make health`; restore: `sudo timedatectl set-ntp true` | TLS/time check fails or warns; no false green | `timedatectl`, health result | Restore NTP and verify sync | Pass if skew is detected and recovery clears it |

### Email and alerts

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Vaultwarden outbound email | Test mailbox/user and Postfix route | Trigger a Vaultwarden test invite/password-hint-safe message; inspect `docker compose logs --tail=100 postfix` | Message accepted and received with correct From | Message ID, timestamps, redacted log, mailbox header screenshot | Delete test message/user | Pass only on mailbox receipt |
| Postfix delivery | Configured relay | `sudo ./maintenance.sh test-email --verbose` | Sidecar accepts, upstream relay delivers via TLS/auth | Route metadata, Postfix queue/log, receipt | Delete message | Pass on receipt and empty/expected queue |
| Configured fallback route | Test API provider failure and valid SMTP fallback | Temporarily use a revoked test API token with `EMAIL_MODE=auto`; run test email | API failure is reported, then Postfix/direct fallback succeeds exactly once | Route trace without tokens, one received message | Restore API token | Pass if one delivery and explicit fallback |
| systemd failure notification | Test unit failure, alert route configured | `sudo systemctl start vaultwarden-notify-failure@synthetic-test.service` or approved failing test service | One correctly addressed notification | Journal, message ID, mailbox receipt | Remove synthetic unit/state | Pass if receipt and no secret data |
| Notification-provider failure | Revoked test credentials/no egress | Trigger controlled service failure | Primary operation remains failed; notification failure is visible, not converted to success | Unit result, notifier journal | Restore provider/egress | Pass if incident failure remains truthful |
| Cooldown behavior | Healthy alert state dir; synthetic repeated fault | Trigger same health failure twice within cooldown, then recover | One initial alert, no flood, one recovery summary | Incident ID, timestamps, message count | Restore healthy state; ensure snapshot removed | Pass if count/state matches contract |
| Alert recipient correctness | All alert types configured | Trigger email test, health failure, and unit failure | All reach current `ADMIN_EMAIL`, no stale recipient | Redacted headers/screenshots | Delete messages | Pass if every route uses intended recipient |

### Backup

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Database backup | Healthy synthetic DB | `sudo ./backup.sh run db --full-verification` | Encrypted DB archive, metadata/checksum, SQLite verification | Exit, filenames, metadata excluding secrets, sizes | Retain for restore tests | Pass if verifier selects it and integrity is `ok` |
| Full backup | Healthy synthetic project/state | `sudo ./backup.sh run full --full-verification` | Verified encrypted full archive with staged DB and no live key/recovery kit | Exit, metadata, safe archive member listing after authorized decrypt | Retain | Pass if tier contract and verification hold |
| Emergency backup | Independent passphrase/recipient prepared | `sudo ./backup.sh run emergency --full-verification` | Independently protected clone-grade capsule, truthful metadata | Exit, metadata/protection mode, safe listing | Retain securely | Pass if operational key alone is insufficient where independent protection is required |
| Local verification | Three retained tiers | `sudo ./backup.sh verify; sudo ./backup.sh list` | Canonical latest selection and every selected cohort validate | Verifier/list output | None | Pass if no archive/sidecar mismatch |
| Remote cohort verification | Test rclone remote | Run each required tier with `--rclone`, then `rclone lsf "$REMOTE"` and remote verify/inspect | Primary plus restore-critical companion metadata present and usable | Remote listing, checksums, exits | Retain for remote restore | Pass if complete cohort exists |
| Retention | Synthetic timestamped old/new cohorts in disposable backup dir | `sudo ./backup.sh rotate --keep <small-test-value>` | Newest parseable retained; cohorts removed together; unparseable primary preserved | Before/after listing and exit | Delete synthetic fixtures | Pass if safety contract holds |
| Failed remote transfer | Rclone test remote made read-only/unreachable | `sudo ./backup.sh run db --rclone` | Local valid backup retained; command reports remote failure, not complete offsite success | Exit, local/remote listings, logs | Restore remote | Pass if nonzero/distinct status and no local prune |
| Interrupted backup | Disposable large test state | Start `systemctl start vaultwarden-full-backup.service`; send TERM to the service with `systemctl kill -s TERM`; inspect | Exit nonzero/terminated; temp/partial archive not eligible; old backups retained | Journal, directory listing, operation status | Remove ineligible temp through supported cleanup | Pass if no false success/corrupt candidate |
| Insufficient disk space | Dedicated small loopback backup directory | Fill until below required workspace; run full backup | Preflight or write fails nonzero; no verified sidecars for partial | `df`, exit, listing | Unmount/delete loop file | Pass if no valid-looking partial and no retention |
| Backup-status accuracy | Exercise success, remote failure, and interrupted cases | `sudo make backup-status; sudo ./backup.sh list` after each | Status distinguishes local success, remote failure, stale/missing, and interrupted | Status snapshots | Restore healthy final backup | Pass if state matches actual artifacts |

### Restore

All restore rows require a disposable target or provider snapshot and synthetic data. Never run them on the only production copy.

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Database restore | Verified DB backup; changed synthetic record | `sudo ./restore.sh latest db --no-start`; integrity check; `sudo make up` | Selected DB restored, WAL/SHM handled, health passes | Pre/post synthetic record, SQLite `ok`, logs | Restore baseline snapshot | Pass if exact data and `/alive` recover |
| Full restore | Verified full cohort | `sudo ./restore.sh latest full --start-policy manual`; inspect; `sudo make up` | Staged project/state promotion, permissions, optional key policy, health | Plan, commit boundary, permission check, `/alive` | Revert/retain for follow-ons | Pass if coherent state and no script/secrets over-restore |
| Emergency restore | Verified independently sealed emergency cohort | `sudo ./restore.sh latest emergency --start-policy manual` with test protection | Clone-grade material restored, rekey policy truthful, no auto-start before acknowledgement | Protection mode, key path/mode only, commit log | Securely delete test handoff; revert | Pass if independent protection required and resulting state decrypts |
| Remote restore | Remote cohort; empty local index | `sudo ./restore.sh inspect --remote; sudo ./restore.sh interactive --remote --start-policy manual` | Remote discovery/download/cohort validation works without local index | Remote listing, selected metadata, download checksum, restore log | Remove downloaded scratch | Pass if correct candidate restored |
| Incorrect passphrase | Emergency test archive | Supply deliberately wrong synthetic passphrase | Fails before service stop/live mutation | Exit, preflight log, service state | None | Pass on nonzero and unchanged live state |
| Missing sidecar | Copy test archive without `.meta` into isolated backup dir | `sudo ./restore.sh inspect` selecting it | Candidate rejected before mutation | Exit/error and service state | Delete fixture | Pass if no dispatch guess/default |
| Corrupted archive | Flip bytes in a copy, never canonical archive | Run inspect/restore preflight | Checksum/decrypt/archive validation fails before stop | Exit and checksum error | Delete corrupt copy | Pass if live state unchanged |
| Path-traversal rejection | Synthetic tar with `../`/absolute member built in scratch | Run the owning archive-validation/inspect path against it | Rejected before extraction | Member list, validator exit | Delete fixture | Pass if nothing created outside staging |
| Insufficient staging space | Dedicated small staging loopback filesystem | Fill near capacity and select large full archive | Space preflight refuses before stop | `df`, plan, exit, container state | Unmount/delete loop | Pass if services remain running and state unchanged |
| Rollback after controlled failure | Snapshot; fail permission/promotion step using supported test hook/fixture | Run full restore | Pre-commit failure restores old state; no mixed identity; no success | Old/new hashes (non-secret), rollback log, services | Remove fixture/revert | Pass if old coherent state restored |
| Replacement-host recovery | New supported VM; recovered state and offline test identity | Checkout exact manifest commit; run documented `recover.sh`; install runtime; start manually | New operational key generated, offline private key not persisted, `/alive` passes | Commit/manifest IDs, key recipient only, logs, health | Securely delete supplied offline identity from host | Pass if complete recovery without persisting offline key |
| Recovery without original local index | New VM with only remote archive cohort and recovery material | Discover via `restore.sh inspect --remote`/documented recovery path | Restore does not depend on old local backup index | Remote inventory and plan | Remove scratch | Pass if correct candidate selected safely |
| Correct permission repair | Completed full/emergency restore; set `TEST_STATE_DIR` to the configured non-secret state path | `sudo utilities/repair-permissions.sh --check; sudo find /etc/vaultwarden "$TEST_STATE_DIR" -xdev -printf '%m %u:%g %p\n'` | Root, PUID:PGID, Caddy 2000:2000, 0750/0640 contracts hold | Permission listing, checker exit | None | Pass if zero drift |
| Post-restore `/alive` | Restored stack started | Local SNI and external `/alive` curls plus `sudo make health` | Both paths and health succeed | Status/timing/health | None | Pass if no skip/failure |
| Operator-controlled startup policy | Repeat restore on snapshots with `manual`, `ask`, `auto`; include EOF | Observe services and exit at each gate | Manual stays stopped; ask requires explicit yes; EOF fails safe; auto only after commit | Service state and prompt/exit | Revert between cases | Pass if no unintended start |

### Updates

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Update with no change | Current pinned images | `sudo ./maintenance.sh update --images` | Pre-update DB backup succeeds; unchanged cohort remains healthy | Image IDs before/after, backup, health | None | Pass if no unnecessary rollback/failure |
| Normal update | Test pin with known compatible newer image in branch fixture | Run documented update, then health/smoke | Cohort updates together and remains healthy | IDs/digests, backup, update log, health | Restore pins/snapshot | Pass on green health and data compatibility |
| Failed image pull | Block one synthetic registry/image | `sudo ./maintenance.sh update --images` | Complete failure leaves old images and does not restart; partial failure rolls pulled tags back | IDs before/after, exit, logs | Restore registry access | Pass if no split cohort |
| Unhealthy updated service | Controlled bad healthcheck image in disposable fixture | Run update | Update/start reports failure; rollback/manual guidance truthful | Image IDs, health, exit | Revert snapshot | Pass if unhealthy state is not success |
| Rollback | Prior image layers preserved | Trigger partial/bad update and execute owned rollback path | Previous cohesive tags/IDs restored | Before/after IDs and health | None | Pass if prior service/data works |
| Database migration compatibility | Representative DB backup and version pair | Snapshot; update Vaultwarden; verify DB/login; attempt supported rollback only if upstream-compatible, otherwise restore pre-update DB with old image | Migration boundary understood; no unsupported old-image/new-DB combination | Versions, DB backup, migration/restore results | Revert snapshot | Pass if declared rollback method works |
| Installed systemd runtime refresh | Repository changed relative to `/opt` | `sudo ./setup.sh systemd validate` (expect drift); `sudo ./setup.sh systemd install --enable-now`; validate again | Drift detected then repaired; six timers ready | Both validator outputs | None | Pass if second validation green |
| Reboot after update | Successful update/runtime refresh | `sudo reboot`; then startup status, health, systemd validate, timers | Updated stack survives reboot | Boot ID, units, health | None | Pass if all required checks green |

### Decommissioning

| Item | Prerequisite | Exact safe command or procedure | Expected result | Evidence to capture | Cleanup | Pass/fail criterion |
|---|---|---|---|---|---|---|
| Uninstall dry run | Disposable installed host | `sudo ./utilities/uninstall-vaultwarden.sh run --dry-run` | Exact managed targets listed; no mutation | Output and before/after inventory | None | Pass if inventory unchanged |
| Explicit preservation decisions | Verified recovery kit/backups; test reset or uninstall prompt | Run without acknowledgement, then with documented `--i-have-saved-my-recovery-kit` only after evidence | Refuses absent acknowledgement; stated preserve/delete choices are explicit | Exit/prompts | Continue only on disposable host | Pass if no implicit destructive default |
| Backup preservation | Local/remote test cohorts | Record hashes/listings; uninstall; recheck retained locations/remote | Behavior matches selected preservation policy | Before/after inventory | Delete test remote after suite | Pass if preserved cohorts remain verifiable |
| systemd cleanup | Installed units/timers/runtime | Authorized uninstall; `systemctl list-unit-files 'vaultwarden-*'; sudo find /opt/vaultwarden-scripts /etc/vaultwarden -xdev -maxdepth 3 -print 2>/dev/null` | Managed units/timers/copies removed as documented | Residual inventory | Remove only documented synthetic leftovers | Pass if verifier reports no managed residual |
| Firewall cleanup | Captured preinstall firewall baseline | Authorized uninstall; compare `ufw status`/`iptables-save` | Project rules removed; unrelated rules retained | Before/after diff | Restore baseline if needed | Pass if no over-deletion or project residual |
| Credential-revocation checklist | Test Cloudflare/SMTP/rclone/Worker credentials | Revoke tokens/keys in provider dashboards; delete Worker/KV resources/route and DNS record as intended; verify APIs reject old tokens | All project external credentials unusable and resources deliberately retired | Redacted screenshots/API 401/403 and resource list | Delete test account resources | Pass if every credential/resource has an owner and verified disposition |
| Attached-volume handling | Test data volume with sentinel and verified backup | Stop stack; uninstall preserving volume; detach only after `findmnt`, `lsblk -f`, sentinel, backup verification | Volume is not formatted/deleted implicitly; disposition explicit | Device ID, mount/sentinel, detach event | Reattach/destroy test volume deliberately | Pass if no ambiguous or unintended volume mutation |

## 15. Prioritized Remediation Plan

### 15.1 Must fix before production

| Finding/Item | Owner subsystem | Complexity | Regression coverage | Host validation | Dependency |
|---|---|---|---|---|---|
| PRR-001 secure credential handoff/no output | Setup, secrets, key rotation, restore | Medium | Security plus data-protection output/fault tests | No-TTY setup, rotate, full/emergency restore | Agree on root-only artifact lifecycle |
| PRR-002 required phase failure propagation | Setup, firewall, secrets | Small | Stubbed setup orchestration failures | Controlled UFW/secrets failure on Noble | PRR-001 changes may touch phase 6 |
| PRR-003 recovery-kit archive exclusion/location | Secrets, backup, operations | Small | Behavioral archive listing and contention | Concurrent export/full backup | PRR-001 handoff design |
| PRR-004 secure startup log modes | Startup, permissions | Small | Behavioral mode/owner fixture | Controlled failed startup | None |

### 15.2 Must validate on a production-like host

| Finding/Item | Owner subsystem | Complexity | Regression coverage | Host validation | Dependency |
|---|---|---|---|---|---|
| C-05 exact remediation CI | CI | Small | All canonical jobs | Not applicable | Final remediation SHA |
| C-06 Noble amd64/arm64 acceptance | Setup/runtime | Large | Existing suites supplement | Complete Section 14 platform/runtime | Remediation merged |
| C-07 backup/remote/restore/recovery drill | Data protection | Large | Data-protection suite | All tiers plus replacement host | Test remote and offline identity |
| C-08 Cloudflare/CrowdSec/mail/alerts | Edge/email | Medium | Existing mocks | Real test accounts/mailbox | Valid scoped credentials |
| C-09 RPO/RTO acceptance | Maintainer/operations | Small | Not applicable | Measure drill duration/data loss | C-07 |

### 15.3 Safe follow-up improvements

| Finding/Item | Owner subsystem | Complexity | Regression coverage | Host validation | Dependency |
|---|---|---|---|---|---|
| PRR-005 direct email preflight | Email/startup | Small | Focused security case | One direct SMTP test | None |
| Remove stale Fail2Ban/backup-passphrase text | Docs/Compose/setup summary | Small | Doc drift/source assertions | None | PRR-001 |
| Immutable Actions/image/provenance pinning | CI/supply chain | Medium | CI invariant | Image pull/build | Version policy |
| Add `push` validation for candidate branches | CI/process | Small | Workflow syntax | Observe exact-head run | Branch policy |

### 15.4 Accepted risks and trade-offs

| Finding/Item | Owner subsystem | Complexity | Regression coverage | Host validation | Dependency |
|---|---|---|---|---|---|
| Postfix transient queue | Operator | Not applicable | Existing docs/tests | Mail outage exercise | Maintainer acceptance |
| Worker fail-open limit mode | Operator/edge | Not applicable | Not repository-testable | Dashboard and quota failure test | Maintainer acceptance |
| Nonpersistent timers/missed-run windows | systemd/operator | Not applicable | Timer structure | Reboot/missed-run observation | C-09 |
| Root-operated lifecycle | Maintainer | Not applicable | Privilege suite | Root operator rehearsal | Continued scope |

## 16. Decision Register

| ID | Decision | Type | Evidence | Maintainer action |
|---|---|---|---|---|
| PRR-001 | Secret-bearing output is a release blocker | Fix | Explicit output sinks and synthetic reproduction | Implement secure handoff and rotate any possibly exposed generation |
| PRR-002 | Required setup failure must fail command | Fix | Setup control-flow trace | Apply failure propagation and regression test |
| PRR-003 | Full tier must exclude equivalent key containers | Fix | Export path plus backup tar sources/excludes | Move/exclude/serialize; test archive listing |
| PRR-004 | Startup must not widen existing log modes | Fix | Recursive 0755 versus canonical 0750/0640 | Apply split modes and host-test failure path |
| PRR-005 | `direct` startup warning is low severity | Defer | Defaults/routing mismatch | Fix with next email/startup change |
| CI-01 | Exact SHA has no CI evidence | Validate | GitHub API returned zero runs/checks | Require green exact remediation SHA |
| HOST-01 | Host acceptance is not verified | Validate | No authorized Noble host supplied | Execute Section 14 |
| RPO-01 | Recovery objectives are absent | Accept | Derived schedule only | Define/accept RPO/RTO |
| TRADE-01 | Root operation remains supported model | Accept | Boundary/docs/code | No redesign |
| TRADE-02 | Three backup tiers remain distinct | Accept | Backup/restore contracts | Preserve distinction |
| TRADE-03 | Postfix queue is transient | Accept | Email/CrowdSec docs | Accept or deliberately redesign later |
| TRADE-04 | Worker quota failure is fail-open | Accept | CrowdSec docs | Verify dashboard and accept |
| ADV-01 | Improve immutable/provenance pinning | Defer | Tags/same-channel checks | Schedule bounded supply-chain hardening |
| EXT-01 | Cloudflare/mail/rclone are external gates | Validate | External architecture | Collect Appendix E evidence |

Every unresolved item is represented above.

## 17. Validation Results

| Command or check | Result | Evidence type | Relevant output | Limitation |
|---|---|---|---|---|
| Initial `git status --short --branch` | Pass | Static | `## delta...origin/delta` | Local checkout only |
| `git ls-files -z '*.sh' '*.bash' \| xargs -0 -n 1 bash -n` | Pass | Behavioral | No output; exit 0 | Syntax only |
| `git ls-files -z '*.sh' '*.bash' \| xargs -0 shellcheck -x --severity=warning` | Pass | Static | No output; exit 0 | ShellCheck does not execute |
| `./tests/run-tests.sh all` | Partial | Behavioral/mocked behavioral | Architecture, runner contracts, config-env passed; permissions stopped at macOS `/usr/bin/stat: illegal option -- c` | Unsupported macOS/GNU-stat mismatch; later cases not run |
| `./tests/run-tests.sh security` | Partial | Mocked behavioral | Initial checks passed; stopped with `No module named yaml` and conditional-collect failure | Python PyYAML unavailable |
| `./tests/run-tests.sh operations` | Partial | Behavioral/mocked behavioral | Operation-guard case passed; health-alerts stopped because `flock` was absent | Linux `/proc` portions skipped; no `flock` |
| `./tests/run-tests.sh data-protection` | Partial | Mocked behavioral | Backup case stopped when tar could not launch `zstd --no-progress -T0 -3` | `zstd` unavailable |
| `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` | Skipped | Behavioral | Docker returned `unknown flag: --env-file` | Docker Compose plugin unavailable; predecessor CI job passed |
| `systemd-analyze verify systemd/*.service systemd/*.timer` | Skipped | Static/host acceptance | `systemd-analyze` absent | macOS, no systemd |
| `actionlint .github/workflows/doc-drift.yml` | Skipped | Static | `actionlint` absent | Workflow YAML inspected manually and by predecessor CI |
| Exact-SHA GitHub check-runs/actions API | Pass | External-source verification | `total_count: 0` for both | Confirms absence, not code quality |
| Predecessor PR SHA `141f0d238488c8df43c72ab29ab6a9f56c95d696` check-runs API | Pass | External-source verification | Seven completed/success jobs: four suites, ShellCheck, Compose, doc drift | Not exact audited SHA; later commit deleted reports only |
| Synthetic setup-summary output probe | Pass | Behavioral | Each supplied non-secret marker appeared once in captured output | Function-level probe, not a real install |
| Setup firewall/secrets failure trace | Pass | Structural | Required child failures feed warnings; `main` reaches `return 0` | Real UFW mutation prohibited locally |
| Recovery-kit-to-full-backup trace | Pass | Structural | Project-root kit is under tar source and absent from exclusions | No real secret/archive opened |
| Startup log-mode trace | Pass | Structural | Recursive `0755` precedes later Compose `0750`/`0640` repair | Host timing not measured |
| Email direct-mode comparison | Pass | Static | Routing accepts `direct`; canonical startup list omits it | No SMTP send |
| Upstream release/advisory inventory | Pass | External-source verification | Major pins current except SOPS one patch behind; targeted applicable notes recorded | Not a full transitive SBOM scan |
| Final audited-SHA drift check | Pass | Static | `git rev-parse HEAD` remained `6a7d9e70954c6b05bda25e7b9089b39715965ba8` before requested report commit | Report commit intentionally advances branch afterward |
| Final report-only diff/hygiene checks | Pass | Static | Only this report added; `git diff --check` clean | Commit/push delivery is outside audited SHA |

No local canonical-suite failure was classified as a repository defect solely because the stopping cause was an unavailable or incompatible macOS tool. Confirmed findings use independent current-tree evidence.

## 18. Final Recommendation

- Repository verdict: **NO-GO** at `6a7d9e70954c6b05bda25e7b9089b39715965ba8`.
- Production-host verdict: **NOT VERIFIED**.
- Production claim: **NOT PRODUCTION-READY** for the documented Ubuntu 24.04 Noble amd64/arm64 deployment.
- Release blockers: PRR-001 secret-bearing command output and PRR-002 false-success setup handling.
- Mandatory conditions: C-01 through C-09 in Section 10.
- Accepted residual risks: root operation, three backup tiers, transient Postfix queue, Worker fail-open limit mode, and nonpersistent timers only after explicit maintainer acceptance.
- Exact next action: implement PRR-001 and PRR-002 first, include their focused regressions, then resolve PRR-003/004, run the full exact-SHA CI set, and execute the Section 14 host checklist before making any production-ready claim.

## Appendix A. Evidence Index

| ID | Immutable evidence |
|---|---|
| PRR-001 | `setup.sh:316-364,596-636`; `lib/secrets.sh:1031-1049,1408-1440`; `utilities/key-rotate.sh:247-270,486-519`; `utilities/restore-run.sh:1418-1505,3095-3097`; `README.md:67-70` |
| PRR-002 | `setup.sh:523-557,603-638`; `docs/DEPLOYMENT.md:40-46`; `README.md:67-70` |
| PRR-003 | `utilities/secrets-export-recovery-kit.sh:56-68,129-152`; `lib/secrets.sh:1465-1505`; `utilities/backup-run.sh:1279-1323`; `docs/BACKUP-RESTORE.md:16-21`; `tests/suites/data-protection/case-backup.bash:27-40` |
| PRR-004 | `startup.sh:369-405`; `docker-compose.yml.example:49-64`; `lib/runtime-permissions.sh:80-104`; `tests/suites/foundation/case-permissions.bash:224-259` |
| PRR-005 | `lib/defaults.sh:47-54`; `startup.sh:187-223`; `lib/email.sh:677-683`; `tests/suites/security/case-email.bash:70-82`; `docs/EMAIL.md:108-118` |
| C-05/CI-01 | `.github/workflows/doc-drift.yml:1-257`; GitHub API exact SHA zero runs; predecessor run `https://github.com/killer23d/VaultWarden-OCI/actions/runs/29984760099` |
| C-06/HOST-01 | `docs/PROJECT-BOUNDARY.md`; `utilities/setup-system.sh:82-140`; Section 14 |
| C-07 | `utilities/backup-run.sh`; `lib/backup-utils.sh`; `utilities/restore-run.sh`; `recover.sh`; `docs/BACKUP-RESTORE.md`; `docs/DISASTER-RECOVERY.md` |
| C-08/EXT-01 | `utilities/setup-firewall.sh`; `utilities/setup-crowdsec.sh`; `lib/email.sh`; `systemd/`; `docs/CROWDSEC.md`; `docs/EMAIL.md` |
| C-09/RPO-01 | `systemd/vaultwarden-db-backup.timer`; `systemd/vaultwarden-full-backup.timer`; `lib/defaults.sh`; `.env.example` |
| Positive operation guard | `lib/operations.sh`; `tests/suites/operations/case-operations.bash` |
| Positive restore transaction | `utilities/restore-run.sh:1718-1764,2560-2638,3070-3153`; `recover.sh`; `lib/runtime-permissions.sh` |
| Positive installed runtime | `utilities/setup-systemd.sh`; `systemd/`; `tests/suites/foundation/case-systemd.bash` |

All repository evidence in this table is at the full audited SHA.

## Appendix B. Files Reviewed

Meaningfully reviewed:

- Repository instructions/boundary: `AGENTS.md`, `docs/PROJECT-BOUNDARY.md`.
- Entrypoints/operator surfaces: `setup.sh`, `startup.sh`, `maintenance.sh`, `backup.sh`, `restore.sh`, `recover.sh`, `edit-secrets.sh`, `dashboard.sh`, `Makefile`.
- Runtime/config: `.env.example`, `docker-compose.yml.example`, `.sops.yaml`, `secrets-schema.yaml`, `lib/defaults.sh`, `lib/config.sh`, `lib/common.sh`, `lib/docker.sh`.
- Security/secrets/email: `lib/crypto.sh`, `lib/schema.sh`, `lib/secrets.sh`, `lib/email.sh`, `lib/health-alerts.sh`, relevant `utilities/secrets-*.sh`, `utilities/setup-secrets.sh`, `utilities/key-rotate.sh`, `utilities/maintenance-email.sh`.
- Operations/storage/data protection: `lib/operations.sh`, `lib/storage.sh`, `lib/migrate.sh`, `lib/backup-utils.sh`, `lib/runtime-permissions.sh`, `utilities/backup-run.sh`, `utilities/restore-run.sh`, `utilities/setup-storage.sh`, `utilities/maintenance-update.sh`, `utilities/safe-restart.sh`, `utilities/uninstall-vaultwarden.sh`.
- Host/edge/automation: `utilities/setup-system.sh`, `utilities/setup-env.sh`, `utilities/setup-firewall.sh`, `utilities/setup-crowdsec.sh`, `utilities/setup-systemd.sh`, `utilities/smoke-test.sh`, `utilities/pre-production-drill.sh`, `systemd/`, `caddy/`, `crowdsec/`.
- Tests/CI: `tests/run-tests.sh`, `tests/test-architecture.sh`, every permanent `tests/suites/*/case-*.bash` filename and the closest case bodies for each traced contract, `.github/workflows/doc-drift.yml`.
- Primary docs: `README.md`, `RUNBOOK.md`, `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, `docs/CONFIGURATION.md`, `docs/SECURITY.md`, `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `docs/EMAIL.md`, `docs/CROWDSEC.md`, `docs/BACKUP-RESTORE.md`, `docs/DISASTER-RECOVERY.md`, `docs/BOOTSTRAP_KEY_RECOVERY.md`, `docs/RECOVERY-CARD.md`, `docs/RESTORE-RUNTIME-PERMISSIONS.md`, `docs/VOLUME-MIGRATION.md`, `docs/MIGRATION.md`, `docs/SCRIPTS.md`, and relevant `docs/COMMAND-REFERENCE.md` sections.

This was a broad production-path audit, not a claim that every line of every repository file was manually reviewed.

## Appendix C. External Dependency and Advisory Inventory

Source date for every row: **2026-07-23**.

| Component | Repository version/tag/digest | Current upstream status | Source date | Applicability |
|---|---|---|---|---|
| Vaultwarden | `1.36.0` tag, no digest pinned | Latest upstream release; release contains the current security fixes for listed SSO/enumeration/SSRF advisories | 2026-07-23 | Applicable and current |
| Caddy | `2.11.4`, custom build | Latest upstream release; 2.11 security fixes precede this pin | 2026-07-23 | Applicable and current |
| caddy-dns/cloudflare | `v0.2.4` | Explicit module tag | 2026-07-23 | Applicable to DNS-01; transitive scan not run |
| caddy-cloudflare-ip | commit `f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5` | Immutable commit pin | 2026-07-23 | Applicable to real-IP trust |
| caddy-combine-ip-ranges | `v0.0.1` | Explicit tag | 2026-07-23 | Applicable to trusted proxy ranges |
| caddy-ratelimit | `v0.1.0` | Explicit tag | 2026-07-23 | Applicable to rate limiting |
| boky/postfix | `5.1.0` tag | Latest upstream release | 2026-07-23 | Applicable and current |
| BusyBox | `1.36.1` tag | Older than 1.37.x; NVD lists CVE-2023-42365 (`awk`) and CVE-2025-46394 (`tar`) affecting this line | 2026-07-23 | Reviewed init command uses neither applet; no supported exploit path confirmed; refresh/scan advised |
| CrowdSec | `1.7.8` | Latest upstream release | 2026-07-23 | Applicable and current |
| CrowdSec firewall bouncer | `0.0.34` | Latest upstream release | 2026-07-23 | Applicable and current |
| CrowdSec Cloudflare Worker bouncer | `v0.0.18` | Latest upstream release | 2026-07-23 | Applicable and current |
| SOPS | `v3.13.2` | Upstream `v3.13.3` released 2026-07-23; changelog reviewed, no repository-applicable security fix identified | 2026-07-23 | One patch behind; evaluate routine upgrade |
| yq | `v4.53.3` with per-arch hash | Latest upstream release | 2026-07-23 | Applicable and current |
| GitHub Actions checkout | `actions/checkout@v4` | Supported major tag, mutable reference | 2026-07-23 | CI supply-chain hardening opportunity |
| GitHub Actions artifact upload | `actions/upload-artifact@v4` | Supported major tag, mutable reference | 2026-07-23 | CI supply-chain hardening opportunity |

Primary sources checked:

- `https://github.com/dani-garcia/vaultwarden/releases`
- `https://github.com/caddyserver/caddy/releases`
- `https://github.com/crowdsecurity/crowdsec`
- `https://github.com/crowdsecurity/cs-firewall-bouncer`
- `https://github.com/crowdsecurity/cs-cloudflare-worker-bouncer/releases`
- `https://github.com/bokysan/docker-postfix/releases`
- `https://github.com/getsops/sops/releases`
- `https://github.com/mikefarah/yq/releases`
- `https://nvd.nist.gov/vuln/detail/CVE-2023-42365`
- `https://nvd.nist.gov/vuln/detail/CVE-2025-46394`

This is a targeted direct-dependency review, not a complete image/SBOM/transitive package scan.

## Appendix D. Proposed Patch Index

| Finding | Target production file(s) | Target test file(s) | Documentation/caller updates | Validation commands |
|---|---|---|---|---|
| PRR-001 | `setup.sh`, `lib/secrets.sh`, `utilities/key-rotate.sh`, `utilities/restore-run.sh`, recovery-export CLI | `tests/suites/security/case-secrets.bash`, `case-security-privileges.bash`, data-protection restore case | README, Deployment, Security, Backup/Restore, DR, bootstrap recovery, owning help/generator | Bash syntax, strict ShellCheck, security, data-protection, all |
| PRR-002 | `setup.sh` | `tests/suites/security/case-security-privileges.bash` | Setup/Deployment completion semantics | Bash syntax, strict ShellCheck, security, all, Noble controlled failure |
| PRR-003 | `lib/secrets.sh`, `utilities/secrets-export-recovery-kit.sh`, `utilities/backup-run.sh` | security secrets case, data-protection backup case | Recovery-export help, Backup/Restore, Security, generated reference | Bash syntax, strict ShellCheck, security, data-protection, all |
| PRR-004 | `startup.sh` | `tests/suites/foundation/case-permissions.bash` | None unless help mentions permissions | Bash syntax, strict ShellCheck, foundation, operations, all |
| PRR-005 | `lib/defaults.sh`, `startup.sh` | `tests/suites/security/case-email.bash` | Generated email mode text if affected | Bash syntax, strict ShellCheck, security, all |

No proposal in this appendix was applied by the audit.

## Appendix E. Host Evidence to Collect

Collect without secret values:

- Host identity: `/etc/os-release`, `dpkg --print-architecture`, kernel, Docker/Compose/tool versions, UTC/time-sync status.
- Exact repository SHA, branch, clean status, and installed-runtime validation output.
- Setup phase/exit transcript with secret-output redaction scan and mode/owner of the secure credential handoff path.
- `docker compose config --quiet` exit, image names/IDs/digests, `docker compose ps`, bounded health logs.
- Local-SNI and external `/alive` status/timing and certificate subject/issuer/expiry.
- Provider ingress screenshot, Cloudflare proxied-DNS/Full-Strict/Worker-route/fail-open screenshots, UFW/iptables rules, IPv4/IPv6 origin-bypass results.
- CrowdSec engine/bouncer status, safe test decision lifecycle, redacted Workers/KV enforcement evidence.
- Email route metadata, Postfix queue/log message IDs, and redacted mailbox header screenshots for application, health, unit-failure, recovery, and cooldown cases.
- For each backup tier: filenames, sizes, timestamps, metadata without secret values, checksum verification, SQLite result, local/remote cohort listing, retention before/after.
- Restore plans, selected archive/cohort identity, preflight result, service-stop boundary, promotion/rollback/commit lines, permission checks, `/alive`, and achieved duration.
- Replacement-host manifest SHA, storage identity/sentinel, public Age recipient only, proof the offline private identity was removed, installed runtime/timers, final smoke test.
- Update image IDs/digests before/after, pre-update DB backup evidence, partial-pull/rollback results, database version compatibility, post-reboot health.
- systemd unit/timer status, next-trigger output, relevant bounded journals, failure-notification receipt, and validator output.
- Capacity: `df`, `du` summaries for state/backups/staging, representative archive/restore duration, and disk-pressure test results.
- Decommissioning: dry-run plan, preservation acknowledgement, before/after managed residual inventory, firewall diff, remote backup disposition, external credential-revocation screenshots, and attached-volume disposition.

Do not collect decrypted SOPS output, private Age identities, recovery-kit contents, SMTP/API/Cloudflare tokens, emergency passphrases, cookies, session headers, vault exports, or backup plaintext.
