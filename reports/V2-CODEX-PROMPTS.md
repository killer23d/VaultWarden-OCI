# VaultWarden-OCI V2 — Bounded Codex Prompts

Date: 2026-08-18

## Purpose

These prompts are intended to be run **one phase at a time**, after the previous phase is reviewed and merged into the V2 development branch.

They deliberately constrain scope. V1 grew complex partly because reasonable local improvements accumulated into permanent frameworks, compatibility layers, tests and documentation. These prompts instruct the coding agent to complete one narrow contract and stop.

## How to use these prompts

- Create/use a dedicated long-lived `v2` development branch for V2 work.
- Run Phase 0 first. Do not start Phase 1 until the V2 agent/product contract is reviewed.
- Give Codex one phase prompt, not the entire roadmap as an implementation request.
- A phase may be split into smaller PRs if the diff becomes difficult to review. Do not combine phases to reduce PR count.
- If Codex discovers an out-of-scope improvement, require it to record the suggestion in its final summary rather than implement it.
- The agent should work in the branch/worktree assigned to it; it should not merge into `main` or `v2` itself unless the surrounding workflow explicitly owns that action.

The phase prompts below are intentionally repetitive so each can be copied independently.

---

# Common V2 constraints for every prompt

Every phase below includes these principles. If a future prompt is rewritten, preserve them.

```text
PRODUCT BOUNDARY
- This is VaultWarden-OCI V2, a greenfield fresh-install release for a small team of roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only.
- Tested CPU architectures: amd64 and arm64.
- Runtime is cloud-provider neutral. OCI A1 Flex is a reference target, not a runtime dependency.
- Cloudflare-first production edge and CrowdSec remain required V2 security components.
- V2 has no requirement to import V1 project state, V1 backups, V1 migration state, V1 command aliases, or V1 runtime layouts.

ENGINEERING BOUNDARY
- Python 3.12 standard library is the preferred runtime implementation language for structured logic.
- Bash is allowed only for small bootstrap/host/container glue where shell is materially simpler.
- Do not introduce runtime third-party Python dependencies without an explicit requirement in this task.
- Development-only pytest and ruff are allowed.
- Do not introduce a framework, plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, Kubernetes/Swarm/HA abstraction, generic cloud abstraction, or generic firewall backend abstraction.
- Do not port V1 code by default. Read V1 only to understand security properties or behavior explicitly required by this task.
- Prefer deleting a requirement to abstracting it.

OPERATOR BOUNDARY
- One public operator CLI: vwctl.
- One installed non-secret config authority: /etc/vaultwarden-oci/config.toml.
- One source-controlled production versions manifest.
- SOPS + Age remain the secret mechanism.
- No mandatory Postfix/local SMTP queue in V2 beta; use direct authenticated SMTP.
- No dashboard/TUI in V2 beta.
- No V1 migration feature.
- No three-tier public backup model; V2 will have one normal recovery format plus offline recovery material.

TEST BOUNDARY
- Add only tests required to protect behavior changed by this task.
- Prefer behavioral tests at public/stable module boundaries.
- Do not add tests that grep for exact private implementation strings, extract private functions with awk/sed, or duplicate production state machines.
- Do not build a custom test runner or test inventory.
- Do not add a coverage-percentage gate.
- Do not add a permanent test solely because a file was touched.
- Use real temporary files/SQLite where cheaper and clearer than elaborate mocks.
- Mock only stable external boundaries such as subprocess, HTTP, SMTP or filesystem metadata.

SCOPE DISCIPLINE
- Change only files necessary for this phase and its tests/docs.
- Do not implement later phases opportunistically.
- Do not create empty modules or abstractions for future phases.
- Do not perform unrelated V1 cleanup.
- If completing the requested phase requires changing one of these product boundaries, stop and report the conflict instead of silently widening scope.
- Finish with a concise summary of changes, exact tests/validation run, and out-of-scope follow-ups discovered.
```

---

# Prompt 0 — V2 contract reset

Use this first, before runtime implementation.

```text
You are preparing the repository for the greenfield VaultWarden-OCI V2 implementation.

This task intentionally changes the repository-level architecture instructions for the V2 development branch. Where the existing V1 AGENTS.md tells you to preserve V1 mechanisms (Bash-first architecture, Postfix, three backup tiers, existing operation-guard/test architecture, installed-runtime synchronization, compatibility surfaces), the V2 requirements in this task take precedence.

Read first:
- reports/V2-AUDIT.md
- reports/V2-ARCHITECTURE-PROPOSAL.md
- reports/V2-IMPLEMENTATION-ROADMAP.md
- reports/V2-TEST-STRATEGY.md
- reports/V2-DOCUMENTATION-AUDIT.md

Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Reset the repository instructions and design contract for V2. Do not implement runtime features.

IMPLEMENT
1. Rewrite the root AGENTS.md for the V2 branch so it is concise and explicitly states:
   - V2 is greenfield; V1 is behavioral/security reference only, not compatibility API.
   - Python 3.12 stdlib owns structured application logic.
   - Bash is only small bootstrap/host glue.
   - one vwctl CLI, one config authority, one versions manifest.
   - Cloudflare-first/CrowdSec/SOPS-Age security properties remain.
   - no Postfix/dashboard/migration/V1 backup compatibility/three public backup tiers in beta.
   - no framework/plugin architecture or speculative abstractions.
   - bounded testing policy from V2-TEST-STRATEGY.md.
   - phase prompts are scope boundaries; later phases must not be implemented early.
2. Add a concise V2 product-boundary document under docs/ or architecture/.
3. Add short ADRs for exactly these decisions:
   - Python-first hybrid language boundary.
   - one installed TOML configuration authority.
   - Cloudflare-only beta ingress using one supported Docker iptables packet path.
   - direct authenticated SMTP/no mandatory Postfix for beta.
   - one V2 recovery format and no V1 data/archive migration compatibility.
   - bounded three-layer test strategy.
4. If needed, add a small index linking these ADRs. Do not build an ADR framework/tool.

ALLOWED SCOPE
- AGENTS.md
- new/revised V2 architecture/product-boundary/ADR documents
- no production source files

TESTS/VALIDATION
- Markdown/basic repository checks only.
- Do not run or modify the large V1 functional test suite merely because docs changed, unless the current branch enforcement makes it unavoidable; report what was run.

NON-GOALS
- no src/vwctl code
- no Compose changes
- no installer
- no deletion/refactor of V1 production code
- no CI redesign yet

DEFINITION OF DONE
A new Codex task on the V2 branch should no longer be instructed to recreate V1 architecture.
```

---

# Prompt 1 — minimal Python foundation

```text
Implement Phase 1 of VaultWarden-OCI V2 only.

Read and obey the V2 AGENTS.md, product boundary, relevant ADRs, reports/V2-ARCHITECTURE-PROPOSAL.md and reports/V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Create the minimal Python foundation for vwctl without Docker/root mutation.

IMPLEMENT
1. Create the smallest practical Python package/entrypoint for `vwctl`.
2. Implement:
   - `vwctl --help`
   - `vwctl --version`
   - `vwctl config validate --file PATH` (or an equally small explicit validation form)
   - `vwctl versions`
   - `vwctl doctor [--json]` with only host/architecture/config/version-file checks.
3. Use Python stdlib `argparse`, `tomllib`, `json`, `pathlib`, `subprocess` as appropriate.
4. Add one production `versions.toml` with exact placeholder/current pins required only by this foundation. Do not add components not yet used.
5. Implement explicit architecture normalization for amd64/x86_64 and arm64/aarch64. Unknown architectures fail clearly.
6. Implement one small subprocess helper that takes argv arrays and returns/raises normalized project errors without shell interpolation.
7. Implement one global mutating lock primitive with `fcntl.flock`, but do not yet attach it to commands that do not mutate.
8. Define stable doctor check IDs and PASS/WARN/FAIL/SKIP states. Human prose need not be API-stable; JSON shape/check IDs should be.

TESTS REQUIRED
- config TOML valid/invalid fixtures
- versions TOML valid/invalid fixtures
- amd64/arm64 mapping + unsupported architecture
- subprocess success/nonzero/not-found behavior
- lock contention with real temporary lock files
- doctor JSON shape/check IDs for the checks implemented

TEST LIMIT
Do not create more test infrastructure than ordinary pytest discovery. No custom runner, modes or inventory.

ALLOWED SCOPE
- new V2 Python source/package files
- pyproject/test config only as needed for pytest/ruff/package metadata
- versions.toml
- focused tests
- DEVELOPMENT documentation only if commands need to be recorded

NON-GOALS
- no Docker or Compose mutations
- no installer
- no root filesystem writes
- no SOPS/Age
- no firewall/Cloudflare/CrowdSec
- no backup/restore
- no systemd
- no update implementation
- no generic command registry/plugin system

DEFINITION OF DONE
The new CLI foundation works as an ordinary user, all focused tests pass, and the implementation is small enough to review without consulting V1 libraries.
```

---

# Prompt 2 — installer and immutable runtime layout

```text
Implement Phase 2 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, ADRs, V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Install the V2 application/config/state layout safely on a clean Ubuntu 24.04 host. Do not start Vaultwarden yet.

IMPLEMENT
1. Add a minimal root bootstrap/installer. Prefer a small Bash bootstrap that validates prerequisites and delegates structured work to Python; do not build a Bash application framework.
2. Validate exactly:
   - Ubuntu 24.04 LTS Noble
   - amd64 or arm64
   - root for mutation
3. Install an immutable application release under `/opt/vaultwarden-oci/releases/<version>` and activate `/opt/vaultwarden-oci/current`.
4. Create:
   - `/etc/vaultwarden-oci/config.toml`
   - `/var/lib/vaultwarden-oci`
   with explicit safe ownership/modes.
5. Add the minimal `vwctl install` orchestration needed for this phase, or let bootstrap call a narrowly scoped internal install command.
6. Add `vwctl config edit/show/validate` only to the degree needed to maintain the single config authority. Validate a staged edit before atomic replacement.
7. If dedicated-volume initialization can be implemented without a migration abstraction, support fresh empty-device/known-filesystem setup mounted at `/var/lib/vaultwarden-oci`. If it cannot remain small, leave volume setup out and document it as a Phase-2 follow-up decision rather than inventing a framework.
8. Do not create repository `.env`, install.env or `/etc/.../vaultwarden.env` synchronization layers.

TESTS REQUIRED
- install plan/path/mode logic in temporary directories
- root/host contract functions using fixtures/mocks at OS metadata boundaries
- config atomic replacement behavior
- dry-run/plan behavior if implemented
- one small disposable Ubuntu installation smoke validation if the environment permits; otherwise document that it remains a release-host check

NON-GOALS
- no Docker stack startup
- no V1 migration or import
- no online disk migration
- no systemd timers
- no backup/restore
- no Cloudflare/CrowdSec
- no extra distro/CPU support

DEFINITION OF DONE
A clean supported host can install the V2 CLI and canonical config/state directories with no repo-to-runtime synchronization concept.
```

---

# Prompt 3 — Vaultwarden + Caddy + SOPS/Age core runtime

```text
Implement Phase 3 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, ADRs, V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Run the minimal secure application: Vaultwarden behind Caddy, with SOPS/Age secrets and direct authenticated SMTP. Do not implement the production Cloudflare firewall/CrowdSec automation yet.

IMPLEMENT
1. Add one production Compose template containing only Vaultwarden and Caddy.
2. Preserve high-value container hardening where supported:
   - explicit user identities where practical
   - cap_drop ALL and only required cap_add
   - no-new-privileges
   - read-only root where compatible
   - tmpfs for transient writable paths
   - health checks
   - bounded logs
   - reasonable memory/PID limits
3. Add Caddy DNS-01 build/config inputs for Cloudflare. Production default ultimately publishes 443 only; do not add a direct HTTP-01 mode.
4. Implement operational Age key creation/storage and one SOPS-encrypted JSON secrets file.
5. Materialize only required decrypted secret files under `/run/vaultwarden-oci/secrets` with restrictive permissions before Compose startup.
6. Implement:
   - `vwctl start`
   - `vwctl stop`
   - `vwctl restart`
   - `vwctl status`
   - `vwctl logs [service]`
7. Configure Vaultwarden to use direct authenticated SMTP from config/secrets. Do not add Postfix.
8. Extend `vwctl doctor` with SOPS/Age, Docker/Compose, container and local Vaultwarden liveness checks.
9. Keep Compose rendering/config environment derived from the single TOML config; do not introduce another persistent operator-editable env file.

TESTS REQUIRED
- valid Compose render passes `docker compose config --quiet` where Docker Compose is available
- expected two-service composition and key hardening properties via parsed/rendered behavior, not a large grep suite
- secret materialization modes and cleanup
- sentinel secret values absent from normal generated/log output
- SOPS failure prevents successful secret/start flow
- status/doctor representative subprocess results

NON-GOALS
- no Postfix or local email queue
- no dashboard
- no CrowdSec installation
- no production iptables ingress chain yet
- no backup/restore
- no systemd automation
- no generic secrets provider/plugin architecture

DEFINITION OF DONE
On an isolated/disposable supported host, the two-container stack can start with SOPS/Age-protected secrets and direct SMTP configuration, and `vwctl doctor` explains basic runtime state.
```

---

# Prompt 4 — Cloudflare ingress and CrowdSec

```text
Implement Phase 4 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, ingress ADR, V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Implement exactly one secure production ingress model: Cloudflare-proxied HTTPS to Caddy, with CrowdSec host/edge enforcement.

IMPORTANT NETWORK CONSTRAINT
Docker-published ports are not protected like ordinary UFW INPUT traffic. For V2 beta, support one documented Docker iptables packet-filter backend and one small project-owned ingress chain. Do not add nftables support or a generic firewall abstraction.

IMPLEMENT
1. Fetch Cloudflare IPv4/IPv6 CIDR lists through a small Python module.
2. Strictly validate addresses/prefixes with stdlib `ipaddress`.
3. Persist a root-owned last-known-good cache with timestamp and bounded maximum age.
4. Generate/apply one deterministic project-owned iptables ingress chain in the Docker packet path so Caddy's published TCP 443 is accepted only from valid Cloudflare ranges and established traffic as required.
5. On inability to establish a safe supported policy, fail closed before/while allowing public Caddy exposure. Reuse the simplest safe lifecycle boundary; do not add a firewall daemon.
6. Do not publish TCP 80 in the Cloudflare DNS-01 production profile.
7. Treat provider firewall/security-group configuration as an external prerequisite and document it; do not add OCI/AWS/Azure APIs.
8. Integrate CrowdSec on the host using current supported upstream installation methods where practical.
9. Own only VaultWarden-specific acquisitions/profiles/config and the chosen Cloudflare Worker bouncer credential/config integration.
10. Before porting any V1 CrowdSec setup logic, compare it with the current upstream-recommended Worker bouncer installer/config path and implement the smaller supported approach.
11. Extend `vwctl doctor` with stable checks for Cloudflare CIDR freshness, ingress-chain state, CrowdSec service and Worker-bouncer state.
12. Add `vwctl crowdsec status/test` only if it provides information that cannot fit cleanly in doctor/status.

TESTS REQUIRED
- CIDR valid/malformed/empty data
- cache freshness/expiry
- deterministic project rule rendering
- safe failure when no fresh/valid policy is available
- focused project-owned CrowdSec config rendering/diagnostic interpretation
- no unit test of iptables/Docker/Cloudflare/CrowdSec internals
- real packet-path behavior remains a disposable-host acceptance scenario

NON-GOALS
- no nftables backend
- no direct/non-Cloudflare production mode
- no Cloudflare Tunnel mode in this phase
- no generic firewall/provider abstraction
- no custom CrowdSec installer framework
- no backup/restore/systemd redesign

DEFINITION OF DONE
A production-mode V2 host has one understandable Cloudflare-only origin ingress contract and doctor can say why the firewall/CrowdSec edge is healthy or not.
```

---

# Prompt 5 — one V2 backup/restore contract

```text
Implement Phase 5 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, recovery ADR, V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Implement one simple, encrypted, verified V2 recovery format and fresh-host restore. Do not implement V1 compatibility.

IMPLEMENT BACKUP
1. `vwctl backup` creates a consistent verified SQLite snapshot.
2. Build one V2 recovery payload/manifest with an explicit format version.
3. Include only state/config needed for V2 recovery; exclude transient decrypted secrets and the live operational Age private key.
4. Encrypt before final publication/offsite transfer.
5. Verify integrity/decryptability before declaring success.
6. Publish atomically so incomplete candidates are not normal restore choices.
7. Implement simple retention that never discards the newest valid recovery point before a newer verified one exists.
8. Support optional rclone offsite upload after local verification; do not build an offsite provider abstraction.
9. Provide an offline recovery-kit export with separately protected operational/recovery material required for fresh-host recovery.

IMPLEMENT RESTORE
10. `vwctl restore` accepts V2 format only.
11. Verify manifest, path safety, checksum/integrity and decryption before stopping services.
12. Verify target storage/capacity before destructive mutation.
13. Stage extracted data away from live state.
14. Stop the stack only after preflight succeeds.
15. Promote with a small explicit local transaction/rollback boundary; do not invent a generic transaction framework.
16. Restore required ownership/modes.
17. Use an explicit start policy. If started, require application health success before reporting restore success.
18. Provide clear non-zero failure and operator guidance for incomplete promotion/start.

TESTS REQUIRED
Use real temp files/SQLite/archive data where cheap.
- snapshot failure prevents publication
- verification failure prevents success/retention/offsite progression as appropriate
- path traversal/unsafe archive member rejection
- manifest/checksum/decryption failure before mutation
- insufficient capacity/layout before service stop
- staged promotion behavior
- permission restoration
- health-gated success
- retention protects latest valid recovery point

NON-GOALS
- no V1 backup detection/readers
- no db/full/emergency public modes
- no V1 migration
- no backup database/catalog
- no generic transaction/state-machine framework
- no second encryption system beyond SOPS/Age/selected recovery sealing contract

DEFINITION OF DONE
A disposable fresh V2 installation can create a verified recovery point and recover it using documented offline recovery material, with tests focused on data-loss boundaries rather than implementation strings.
```

---

# Prompt 6 — systemd automation and direct notifications

```text
Implement Phase 6 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Add the minimum systemd automation required for set-and-forget operation.

IMPLEMENT
1. Install a lifecycle/startup service that invokes the immutable `/opt/vaultwarden-oci/current` release.
2. Add exactly these scheduled responsibilities unless a documented technical need proves otherwise:
   - backup timer/service
   - health/doctor timer/service
   - maintenance timer/service
3. Add a separate edge-refresh timer only if the Phase-4 Cloudflare CIDR freshness requirement cannot be met safely through maintenance/health/startup. Prefer not to add it.
4. Keep systemd as the only scheduler.
5. Use unit sandbox/hardening directives that are compatible with the exact command's required writes/network access.
6. Send operational notifications directly through the configured SMTP relay using Python stdlib `smtplib`.
7. Do not add Postfix, a local queue, provider HTTP APIs, or a complex incident-state database.
8. Extend `vwctl status`/`doctor` to show timer enablement, last run and failure state.

TESTS REQUIRED
- deterministic systemd unit rendering
- `systemd-analyze verify` when available
- timer command grammar points at installed vwctl
- SMTP message construction and representative auth/network failure handling using a stable SMTP test boundary
- disposable-host unit enable/run checks belong to release acceptance

NON-GOALS
- no second scheduler
- no dashboard
- no alert recovery state machine
- no Postfix/email queue
- no unrelated update work

DEFINITION OF DONE
An operator can understand all scheduled V2 responsibilities from a short unit list and `vwctl status`, and failures are directly visible/notify without another mail subsystem.
```

---

# Prompt 7 — update/version workflow and `--use-latest`

```text
Implement Phase 7 of VaultWarden-OCI V2 only.

Read and obey V2 AGENTS.md, version architecture in V2-ARCHITECTURE-PROPOSAL.md and V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Implement reproducible production version/update behavior and the explicit development-only `--use-latest` escape hatch.

IMPLEMENT
1. Make `versions.toml` the only source-controlled production pin authority.
2. Implement `vwctl versions` showing effective exact versions.
3. Implement `vwctl update check` without mutation.
4. Implement explicit `vwctl update apply`:
   - preflight health/config
   - ensure required recovery point per current policy
   - stage immutable new application release
   - pull/build exact pinned images/components
   - activate release
   - restart and run health gate
   - provide a narrow application-release rollback when safe and when no incompatible persistent-state change has crossed the boundary
5. Implement `--use-latest` only on explicitly documented development/test install/version-resolution surfaces.
6. Latest mode must:
   - print/record non-production mode
   - resolve newest compatible stable upstream versions
   - convert to exact versions immediately
   - record the resolved set for reproducibility
   - never write floating `latest` into the normal production pins file
7. Keep all latest-resolution policy in the version module; do not add component-specific latest branches throughout the codebase.
8. Validate amd64 and arm64 upstream assets/manifests for owned downloadable components.

TESTS REQUIRED
- exact production pin resolution
- mocked latest HTTP responses and failure states
- amd64/arm64 asset mapping
- unsupported architecture failure
- update plan without mutation
- immutable release activation/rollback using temporary directories
- proof production path never silently floats

NON-GOALS
- no unattended auto-update daemon
- no cron/update scheduler
- no generic package manager
- no arbitrary architecture support
- no feature upgrades unrelated to version/update flow

DEFINITION OF DONE
Production updates are exact and reproducible, while developers retain a clearly non-production latest test mode with an exact resolution record.
```

---

# Prompt 8 — documentation, real-host acceptance, beta cleanup

```text
Implement Phase 8 of VaultWarden-OCI V2 only. This is a hardening/cleanup phase, not a feature phase.

Read and obey V2 AGENTS.md, reports/V2-DOCUMENTATION-AUDIT.md and reports/V2-TEST-STRATEGY.md.
Apply the Common V2 constraints from reports/V2-CODEX-PROMPTS.md.

GOAL
Prepare V2 beta for operator review by minimizing docs/tests and proving the complete golden path on disposable supported hosts.

IMPLEMENT DOCUMENTATION
1. Consolidate permanent operator docs to approximately:
   - README.md
   - docs/INSTALL.md
   - docs/OPERATIONS.md
   - docs/SECURITY.md
   - docs/RECOVERY.md
   - docs/DEVELOPMENT.md
2. Remove V2-branch documentation for features not present in beta: V1 migration, V1 backup tiers, Postfix queue, dashboard, alternate edge modes, generated command encyclopedia.
3. Make `vwctl --help` the exact CLI reference.

IMPLEMENT TEST/CI CLEANUP
4. Normal PR CI should be small: ruff, pytest, ShellCheck for remaining shell, Compose config validation and only narrowly justified static checks.
5. Remove temporary/mirrored/source-grep test machinery that is not protecting V2 behavior.
6. Do not create a custom test runner.

REAL-HOST ACCEPTANCE
7. Create the smallest practical release-gate procedure/script for disposable Ubuntu 24.04 hosts covering:
   - clean install
   - config/secrets
   - start + doctor
   - Cloudflare/CrowdSec edge on a dedicated test hostname
   - verified backup
   - fresh-state/fresh-host restore
   - doctor/application smoke after restore
   - explicit update
   - timer verification
   - uninstall/reinstall if still part of the beta contract
8. Prefer external VM recreation/disposal over implementing a persistent destructive acceptance state machine inside the project.
9. Exercise amd64 and arm64 where infrastructure permits. Do not encode OCI-specific runtime logic in the acceptance scenario.

CLEANUP
10. Delete dead V2 scaffolding, provisional flags, unused modules and compatibility helpers found during beta development.
11. Do not refactor working code merely for style/line-count reduction.

NON-GOALS
- no dashboard/TUI
- no Postfix
- no new edge mode
- no V1 migration/compatibility
- no new feature requested only during hardening

DEFINITION OF DONE
The V2 beta has a small understandable operator surface, a small understandable test suite, and a documented real-host proof of install -> secure runtime -> backup -> restore -> update.
```

---

# Prompt template for small corrective PRs during V2 development

Use this instead of telling Codex to "clean up" an area broadly.

```text
Fix only this V2 defect: <ONE SENTENCE DEFECT>.

Read V2 AGENTS.md and the relevant ADR/module documentation first.

IN SCOPE
- Observable incorrect behavior: <EXACT BEHAVIOR>
- Owning files/modules likely: <PATHS>
- Security/data invariant to preserve: <INVARIANT>

OUT OF SCOPE
- no refactor outside the owning boundary
- no compatibility code for V1
- no new abstraction/framework
- no new command/flag unless explicitly required
- no unrelated docs cleanup
- no additional feature discovered while working

TEST EXPECTATION
Add or change only the smallest behavioral test that would fail for this defect and pass after the fix. If an existing test already covers the invariant, do not add another. Do not assert exact private source strings.

VALIDATION
Run the focused test first, then the normal V2 PR validation appropriate to the changed files. Report exactly what ran.

If fixing this defect requires a product-boundary or ADR change, stop and explain the conflict instead of expanding scope.
```

---

# Prompt review checklist for the human maintainer

Before sending any future Codex prompt, verify:

- Can the requested behavior fit in one PR/review unit?
- Does the prompt list non-goals?
- Does it accidentally ask for a generic solution to a one-product problem?
- Does it preserve the no-V1-compatibility decision?
- Does it tell the agent what **not** to test?
- Does it prevent future-phase work?
- Does it point to one canonical configuration/secret/version owner?
- If the agent discovers more work, can that work be deferred instead of absorbed?

If not, narrow the prompt before starting the agent.
