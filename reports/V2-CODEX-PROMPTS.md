# VaultWarden-OCI V2 — Authoritative Codex Prompts

Date: 2026-08-18
Revision: consolidated after V2 branch creation and later SOPS/Age, rclone, notification, and file-surface decisions.

## Authority and precedence

This file is the **authoritative V2 agent execution contract**.

For V2 work:

1. A human's explicit task instruction is highest priority.
2. The applicable phase/corrective prompt copied from this file is the authoritative repository implementation contract for that task.
3. Root `AGENTS.md` should be a concise map that directs agents here and records only durable working rules; it must not become a second competing architecture specification.
4. ADRs and the other `reports/V2-*.md` files provide rationale and supporting detail. Keep them consistent with this file. If a conflict is found, follow this file for agent execution and report/correct the stale supporting document rather than silently choosing the broader interpretation.

Durable product or architecture changes should be written back into this file so later agents do not infer policy from conversational history.

## How to use

- The long-lived V2 development branch is `v2`.
- Run **one phase prompt at a time** after the preceding phase is reviewed and merged into `v2`.
- Phase 0 runs first. Do not start Phase 1 until the V2 agent/product contract is reviewed.
- A phase may be split into smaller PRs if the diff becomes difficult to review. Do not combine phases merely to reduce PR count.
- If an agent discovers a useful out-of-scope improvement, record it in the final summary instead of implementing it.
- The agent works only in its assigned branch/worktree. It does not merge its own PR unless explicitly instructed by the surrounding workflow.

---

# Common V2 contract

Every V2 phase and corrective task inherits the following rules unless the human task explicitly changes them.

```text
PRODUCT BOUNDARY
- VaultWarden-OCI V2 is a greenfield fresh-install release for a small team of roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only.
- First-class tested CPU architectures: amd64 and arm64.
- Runtime is cloud-provider neutral. OCI A1 Flex is a reference deployment, not a runtime dependency.
- Production ingress is Cloudflare-first; CrowdSec remains required.
- V2 has no requirement to import V1 project state, V1 backups, V1 migration state, V1 command aliases, V1 runtime layouts, or V1 compatibility behavior.

LANGUAGE, FILE-SURFACE, AND COMPLEXITY BOUNDARY
- Python 3.12 standard library is the preferred runtime implementation language for structured application logic.
- Bash is allowed only for small bootstrap/host/container glue where shell is materially simpler.
- Do not introduce runtime third-party Python dependencies without an explicit requirement in the current task.
- Development-only pytest and ruff are allowed; ShellCheck is allowed for remaining shell.
- Prefer fewer, cohesive first-party files when responsibilities remain clear. Before creating a new module/script/config fragment, first consider whether the behavior naturally belongs in an existing owning file.
- Do not split small behaviors into one-function modules, one-purpose wrapper scripts, duplicate config fragments, or speculative future-facing files merely for architectural neatness.
- File-count reduction is a preference, not a quota. Do not merge unrelated responsibilities, create giant catch-all modules, or weaken readability/testability/security merely to reduce the number of files.
- When a V2 implementation replaces a V1 product surface on the V2 branch, prefer deleting obsolete files over retaining wrappers, aliases, empty placeholders, or compatibility shims unless the current phase explicitly requires them.
- Do not introduce a framework, plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, Kubernetes/Swarm/HA abstraction, generic cloud abstraction, generic storage-provider abstraction, generic notification-provider abstraction, or generic firewall-backend abstraction.
- Do not port V1 code by default. Read V1 only to understand security properties or behavior explicitly required by the current task.
- Prefer deleting a requirement to abstracting it.

OPERATOR BOUNDARY
- One public production CLI: vwctl.
- One installed non-secret configuration authority: /etc/vaultwarden-oci/config.toml.
- One source-controlled production versions manifest: versions.toml.
- No dashboard/TUI in beta; use vwctl status and vwctl doctor.
- No V1 migration feature or V1 archive reader.
- One normal encrypted V2 recovery format plus offline recovery material.

SECRETS BOUNDARY
- Keep SOPS + Age.
- Use one structured SOPS-encrypted secrets document.
- Use one root-only operational Age private identity on the server.
- Support offline recovery material/recipient whose private recovery key is not persisted on the server.
- Decrypted runtime secret material exists only in a root-owned volatile runtime location.
- SOPS and Age are external cryptographic tools; do not reimplement cryptography or build another secrets-manager/KMS abstraction.

RCLONE BOUNDARY
- rclone remains a first-class V2 offsite backup/recovery capability.
- Project code owns only a small wrapper for diagnostics, connectivity, publication, listing, download/staging, verification, and explicit retention/pruning.
- Normal backup publication is: create -> verify local -> rclone copy/copyto -> verify remote -> report success.
- Normal publication must not use destructive sync semantics that can delete remote recovery points merely because local files disappeared.
- Remote deletion/retention is a separate explicit operation.
- Do not build a storage-provider plugin framework around rclone.

EMAIL/NOTIFICATION BOUNDARY
- Vaultwarden application email uses Vaultwarden's direct authenticated SMTP support.
- Project operational notifications use one concrete HTTPS email API as the primary transport.
- After a small bounded API retry, direct authenticated SMTP may be used as fallback for clearly transient delivery-path failures such as network/DNS timeout, HTTP 429, and service-side 5xx conditions.
- Authentication/configuration/permanent request failures such as representative 400/401/403 remain visible and should normally not be masked by SMTP success.
- TLS certificate or hostname validation failure is a security/configuration failure, not a silent fallback condition.
- SMTP uses normal certificate and hostname validation with implicit TLS or required STARTTLS plus authentication.
- API tokens and SMTP credentials never appear in argv, normal logs, exception text, or debug transcripts.
- If both transports fail, record a small secret-free diagnostic result visible to status/doctor.
- No mandatory Postfix container, no local MTA requirement, no project-built durable queue, spool, retry scheduler, or dead-letter system.
- Do not build a generic notification/provider framework. Beta supports exactly one concrete HTTPS API integration plus one SMTP fallback path.
- The concrete HTTPS API provider must be named by an ADR before Phase 6 implementation. If no provider has been selected, Phase 6 must stop and report that missing product decision rather than invent a generic provider abstraction.

EDGE BOUNDARY
- Beta production ingress is Cloudflare-proxied HTTPS with Caddy.
- Support one Docker Engine bridge + iptables packet-filter path for published Caddy ingress.
- Own one small project ingress chain/allowlist behavior for Cloudflare IPv4/IPv6 ranges with a last-known-good cache and bounded staleness.
- Fail closed when a safe Cloudflare ingress policy cannot be established.
- Do not implement multiple firewall backends in beta.

VERSION BOUNDARY
- Production uses exact source-controlled pins.
- --use-latest remains development/testing-only.
- --use-latest resolves to exact versions at the start of a run and records that exact resolved set; it never creates a floating production state.

TEST BOUNDARY
- Tests exist only to protect security, availability, recoverability, and operator truthfulness.
- Use only three validation layers: focused unit tests, small integration tests, and disposable real-host release acceptance.
- Add only tests required for behavior changed by the current task.
- Prefer public/stable behavioral boundaries.
- Do not add tests that grep exact private source strings, assert private implementation order, extract private functions with awk/sed, freeze human prose, or duplicate production state machines.
- Do not build a custom test runner or inventory.
- Do not add a coverage-percentage gate.
- Use real temporary files/SQLite/archives where cheaper and clearer than elaborate mocks.
- Mock only stable external boundaries such as subprocess, HTTP, SMTP, rclone, SOPS/Age, or filesystem metadata.
- One behavior should normally have one best-level permanent test, not copies at every layer.

SCOPE DISCIPLINE
- Change only files necessary for the current phase and its focused tests/docs.
- Do not implement later phases opportunistically.
- Do not create empty modules, provider registries, extension points, or abstractions for future phases.
- Do not perform unrelated V1 cleanup.
- If the requested work requires changing a Common V2 boundary, stop and report the conflict rather than silently widening scope.
- Finish with a concise summary: behavior changed, smallest validation sufficient, highest-value test layer, tests/validation actually run, validation not run, and out-of-scope follow-ups discovered.
```

---

# Prompt 0 — V2 contract reset

Run this first on a branch based on `v2`. Do not implement runtime code.

```text
You are preparing VaultWarden-OCI for greenfield V2 implementation.

The existing root AGENTS.md was written for V1 maintenance and contains requirements that intentionally conflict with V2. The current task prompt and reports/V2-CODEX-PROMPTS.md take precedence for this task.

Read first:
- reports/V2-CODEX-PROMPTS.md (authoritative)
- reports/V2-AUDIT.md
- reports/V2-ARCHITECTURE-PROPOSAL.md
- reports/V2-IMPLEMENTATION-ROADMAP.md
- reports/V2-TEST-STRATEGY.md
- reports/V2-DOCUMENTATION-AUDIT.md
- reports/V2-ACCEPTED-DECISIONS-EMAIL-RCLONE.md

GOAL
Reset repository instructions and record the minimal V2 product decisions. No production runtime implementation.

IMPLEMENT
1. Rewrite root AGENTS.md into a concise V2 map. It must:
   - state that reports/V2-CODEX-PROMPTS.md is the authoritative V2 agent execution contract;
   - tell agents to use the applicable phase/corrective prompt from that file;
   - state V2 is greenfield and V1 is security/behavior reference only, not compatibility API;
   - state Python 3.12 stdlib owns structured logic and Bash is minimal glue;
   - state one vwctl CLI, one TOML config authority, one versions manifest;
   - point to the small set of ADRs/product docs instead of duplicating them;
   - state later phases must not be implemented early;
   - remain short enough to act as a map, not a second architecture manual.
2. Add/update a concise V2 product-boundary document.
3. Add short ADRs for exactly these durable decisions:
   - Python-first hybrid language boundary;
   - one installed TOML non-secret configuration authority;
   - SOPS + Age structured secrets with operational and offline recovery identities;
   - Cloudflare-only beta ingress using one supported Docker iptables packet path;
   - operational notifications: one concrete HTTPS API primary + direct authenticated SMTP transient-failure fallback, no Postfix/custom queue;
   - rclone first-class with copy-style publication and separate retention/pruning;
   - one V2 recovery format, offline recovery material, no V1 migration/archive compatibility;
   - bounded three-layer test strategy.
4. For the notification ADR, name the concrete HTTPS email API provider intended for Phase 6. If the repository/user has not selected one, record the decision as OPEN and clearly state that Phase 6 may not invent a generic provider abstraction; do not guess a provider.
5. If useful, add one small ADR index. Do not build ADR tooling/frameworks.

ALLOWED SCOPE
- AGENTS.md
- V2 product-boundary/ADR documents
- documentation links required for those documents
- no production source files

VALIDATION
- Markdown/basic repository checks only.
- Do not modify the V1 functional test corpus.
- Do not run the large V1 suite merely because documentation changed unless branch enforcement makes it unavoidable; report what ran.

NON-GOALS
- no Python runtime code
- no Compose changes
- no installer
- no CI redesign
- no V1 cleanup/refactor

DEFINITION OF DONE
A new agent entering the V2 branch sees a short AGENTS.md that sends it to reports/V2-CODEX-PROMPTS.md and no longer instructs it to preserve the V1 architecture.
```

---

# Prompt 1 — minimal Python foundation

```text
Implement V2 Phase 1 only.

Read root AGENTS.md, then reports/V2-CODEX-PROMPTS.md and the Phase 1 prompt. Read supporting ADRs only as needed.

GOAL
Create the smallest practical Python 3.12 foundation for vwctl without Docker/root mutation.

IMPLEMENT
1. Minimal Python package/entrypoint for vwctl.
2. Commands:
   - vwctl --help
   - vwctl --version
   - vwctl config validate --file PATH (or equally small explicit form)
   - vwctl versions
   - vwctl doctor [--json] with host/architecture/config/version-file checks only.
3. Use stdlib argparse, tomllib, json, pathlib, subprocess, fcntl as appropriate.
4. Add one versions.toml with exact values needed by this phase only.
5. Normalize amd64/x86_64 and arm64/aarch64; fail clearly on unsupported architecture.
6. Add one small subprocess helper that accepts argv arrays and normalizes success/nonzero/not-found behavior without shell interpolation.
7. Add one global mutation lock primitive using fcntl.flock, not yet attached to read-only commands.
8. Define stable doctor check IDs and PASS/WARN/FAIL/SKIP states. Human prose is not API-stable; JSON shape/check IDs are.

TESTS REQUIRED
- valid/invalid TOML fixtures
- versions manifest valid/invalid behavior
- architecture mapping and unsupported architecture
- subprocess success/nonzero/not-found
- lock contention using real temporary files
- doctor JSON shape/check IDs implemented in this phase

TEST LIMIT
Ordinary pytest discovery only. No custom runner, inventory, coverage gate, plugins, or large fixture framework.

NON-GOALS
- no Docker/Compose mutation
- no installer/root writes
- no SOPS/Age execution
- no HTTP/email/rclone
- no Cloudflare/CrowdSec/firewall
- no backup/restore
- no systemd/update implementation
- no plugin/command registry
```

---

# Prompt 2 — bootstrap and installed layout

```text
Implement V2 Phase 2 only.

GOAL
Install the V2 application/config/state layout safely on a clean Ubuntu 24.04 host. Do not start Vaultwarden yet.

IMPLEMENT
1. A minimal root bootstrap. Prefer a small Bash entrypoint that validates basic prerequisites and delegates structured work to Python; do not build a Bash framework.
2. Validate Ubuntu 24.04 and supported amd64/arm64 architecture.
3. Create the installed layout:
   - /opt/vaultwarden-oci/releases/<release>/
   - /opt/vaultwarden-oci/current symlink
   - /etc/vaultwarden-oci/config.toml
   - /etc/vaultwarden-oci/age-key.txt location/permissions contract
   - /var/lib/vaultwarden-oci/{data,backups,...as actually required}
   - /run/vaultwarden-oci for volatile state.
4. Install the current V2 Python application immutably under the release directory and expose vwctl through the intended stable path.
5. Create only directories/users/groups actually required by the current design.
6. Add minimal systemd integration needed to make the installed CLI/layout addressable, but do not implement later timers/services.
7. Installation is safe to re-run for the same release/configuration and fails clearly on incompatible pre-existing ownership/state.

TESTS/VALIDATION
- focused unit tests for path/permission/rendering logic
- small integration tests against temporary roots where practical
- one disposable Ubuntu 24.04 installation smoke validation if the phase environment supports it

NON-GOALS
- no Vaultwarden/Caddy start
- no secrets decryption
- no Cloudflare/CrowdSec/firewall
- no rclone backup/restore
- no operational notifications
- no update engine
- no V1 migration
```

---

# Prompt 3 — core Vaultwarden/Caddy runtime and secrets

```text
Implement V2 Phase 3 only.

GOAL
Run Vaultwarden behind Caddy using the V2 config/secrets contract, without implementing edge firewall/CrowdSec or operational notification delivery yet.

IMPLEMENT
1. Minimal Compose/runtime definition for Vaultwarden + Caddy only.
2. Preserve useful container hardening: explicit users where feasible, cap_drop ALL plus only demonstrated additions, no-new-privileges, read-only roots/tmpfs where compatible, bounded logs, health checks, reasonable resource/PID limits.
3. Implement SOPS + Age orchestration:
   - one structured SOPS-encrypted secrets document;
   - root-only operational Age identity;
   - offline recovery recipient/material contract;
   - decrypt only to root-owned volatile runtime files;
   - validate required secret keys before start;
   - never place plaintext secrets in config.toml, argv, ordinary logs, or persistent temp files.
4. Implement vwctl start/stop/restart/status/logs for the two-container stack.
5. Configure Vaultwarden application email through Vaultwarden's direct authenticated SMTP support. Do not add Postfix.
6. Caddy provides the reverse-proxy path needed for the Cloudflare-first design, but Phase 4 owns host ingress enforcement and CrowdSec.
7. Add doctor checks only for the runtime behaviors introduced here.

TESTS REQUIRED
- focused config-to-runtime rendering/validation behavior
- SOPS/Age orchestration boundary with subprocess mocked only at the external command boundary
- no plaintext-secret leakage to generated persistent config/argv/loggable structures
- representative lifecycle/status behavior at the smallest useful integration level

NON-GOALS
- no operational HTTPS API/SMTP fallback module yet
- no Postfix or mail queue
- no Cloudflare CIDR firewall enforcement
- no CrowdSec setup
- no backup/restore/rclone
- no update engine
```

---

# Prompt 4 — Cloudflare ingress and CrowdSec

```text
Implement V2 Phase 4 only.

GOAL
Establish the single supported beta production edge: Cloudflare-proxied Caddy with fail-closed Docker iptables ingress and CrowdSec integration.

IMPLEMENT
1. Cloudflare IPv4/IPv6 retrieval, strict parsing/validation, last-known-good storage, and bounded staleness.
2. One small project-owned Docker iptables ingress chain/path that allows the published Caddy HTTPS port only from validated Cloudflare ranges for the supported beta path.
3. Fail closed if no safe current/last-known-good policy is available.
4. Do not pretend ordinary UFW INPUT rules alone protect Docker-published Caddy ports. UFW may still protect normal host services such as SSH where applicable.
5. Retain CrowdSec using current upstream installation/integration paths where possible:
   - host agent/acquisitions needed by this product;
   - host firewall bouncer for host-visible traffic where appropriate;
   - Cloudflare edge/Worker bouncer integration for proxied web-client enforcement;
   - minimal project-owned config/credentials/doctor checks.
6. Add vwctl/doctor status/test behavior needed to explain edge health to a junior admin.

TESTS REQUIRED
- CIDR parsing/validation/staleness logic
- deterministic rule rendering/update decisions without requiring a second firewall backend
- fail-closed decision behavior
- minimal integration around external command boundaries

NON-GOALS
- no nftables alternative
- no generic firewall abstraction
- no direct/non-Cloudflare production ingress mode
- no cloud security-group API integration
- no wholesale port of the V1 CrowdSec installer
```

---

# Prompt 5 — backup, restore, rclone, and offline recovery

```text
Implement V2 Phase 5 only.

GOAL
Provide one safe encrypted V2 recovery format, offsite rclone publication, and restore. No V1 compatibility.

IMPLEMENT
1. vwctl backup creates one complete V2 recovery point with:
   - a consistent SQLite snapshot;
   - required persistent application/configuration material;
   - manifest containing V2 format version, metadata, and checksums;
   - encryption before publication;
   - verification before success.
2. Operational Age private key is excluded from ordinary backup artifacts. Offline recovery material/recipient must be documented and testable without persisting its private key on the server.
3. Local publication is atomic enough that incomplete candidates are never reported as valid recovery points.
4. Keep rclone first-class with a small wrapper for:
   - configuration/prerequisite diagnostics;
   - connectivity test;
   - upload/publication;
   - remote listing;
   - remote verification;
   - download/staging for restore;
   - explicit retention/pruning.
5. Normal offsite publication order is exactly:
   create -> verify local -> rclone copy/copyto-style publication -> verify required remote cohort -> report success.
6. Remote retention/deletion is a separate explicit operation. Do not use rclone sync as normal publication where deletion semantics could remove recovery points because local files disappeared.
7. vwctl restore supports V2 format only and must:
   - stage/decrypt/validate manifest/checksums before live mutation;
   - validate free space and target storage;
   - stop services only after preflight succeeds;
   - stage extracted state;
   - promote with a small explicit transaction boundary;
   - restore permissions;
   - start only according to explicit policy/flag and require health before claiming success.
8. status/doctor shows last verified local/offsite recovery state without exposing secrets.

TESTS REQUIRED
- disproportionate attention is appropriate here because recoverability is a core safety property
- real temporary SQLite/files/archives for representative backup/restore paths
- corruption/wrong-key/incomplete-manifest/preflight failure behavior
- rclone command construction/result classification at its stable boundary
- prove normal publication does not request destructive sync semantics
- representative remote verification and explicit prune decision behavior

NON-GOALS
- no db/full/emergency public tier system
- no V1 backup reader or migration
- no generic storage-provider framework
- no background replication daemon
```

---

# Prompt 6 — systemd automation and operational notifications

```text
Implement V2 Phase 6 only.

GOAL
Add a small systemd automation surface and reliable-but-bounded operational notifications without Postfix or a custom queue.

PRECONDITION
Read the notification ADR created in Phase 0. It must name the one concrete HTTPS email API provider for beta. If it remains OPEN, stop and report the missing product decision. Do not invent a generic provider interface to avoid making the decision.

IMPLEMENT
1. Keep the permanent unit/timer set small. Add only units actually required for lifecycle, health, backup, and maintenance at this phase.
2. Units execute the installed immutable release/current path and installed config; never an arbitrary git checkout.
3. Implement one small operational notification module used by vwctl/systemd tasks:
   - primary: the one concrete HTTPS email API named by the ADR;
   - fallback: direct authenticated SMTP.
4. HTTPS uses normal CA/hostname validation. Keep API credentials out of argv/logs/exceptions.
5. Use a small bounded primary retry policy only.
6. SMTP fallback classification:
   - eligible: clearly transient network/DNS/timeouts, HTTP 429 after bounded retry, service-side 5xx, and only other conditions explicitly documented as transient by the selected provider;
   - not silently eligible: representative 400/401/403, malformed request/configuration, unsupported provider behavior, certificate/hostname validation failure.
7. SMTP uses ssl.create_default_context() semantics with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
8. Return/store a small structured safe result such as transport, outcome, stable reason/category, event identifier/time, and safe diagnostic text.
9. If API and SMTP both fail, expose the failure through status/doctor. Do not persist full message bodies or secret-bearing responses.
10. Do not build a mail spool, retry scheduler, dead-letter queue, local SMTP server, MTA, or Postfix container.

TESTS REQUIRED
- deterministic classification of API success/transient/auth/config/permanent/TLS-validation outcomes
- prove SMTP fallback occurs for representative transient cases and does not mask representative configuration/security failures
- SMTP TLS/auth call behavior at a stable mocked boundary; no protocol simulator unless truly necessary
- secret-redaction/result-shape behavior
- systemd unit rendering/command targets at the smallest useful level

NON-GOALS
- no provider registry
- no second HTTPS API provider
- no durable notification queue
- no Postfix
- no general job scheduler beyond systemd
```

---

# Prompt 7 — versions and explicit updates

```text
Implement V2 Phase 7 only.

GOAL
Provide reproducible pinned production versions, development/testing --use-latest resolution, and an explicit safe update path.

IMPLEMENT
1. versions.toml is the only source-controlled component-version authority.
2. Centralize architecture-aware artifact/image resolution for amd64/arm64.
3. Production install/update uses exact pins only.
4. --use-latest is explicitly non-production:
   - resolve compatible upstream versions once at start;
   - convert them to exact versions/digests where available;
   - record the exact resolved set for the run;
   - pass exact results downstream;
   - never scatter live-latest checks across component installers.
5. Implement vwctl update check/apply with a small safe flow:
   - validate current state;
   - create/verify recovery point according to policy;
   - stage new immutable application release;
   - pull/build exact pinned runtime components;
   - switch current symlink;
   - restart and health/doctor gate;
   - roll back application release activation where safe before incompatible state changes.
6. No unattended auto-update daemon.

TESTS REQUIRED
- versions parsing/resolution/architecture mapping
- --use-latest resolves once and freezes exact values for the run
- representative update activation/failure decisions
- no network-heavy permanent tests of third-party release services beyond the smallest stable boundary
```

---

# Prompt 8 — beta documentation, acceptance, and V2 cleanup

```text
Implement V2 Phase 8 only.

GOAL
Make V2 understandable, testable on a clean Ubuntu 24.04 host, and free of V1 product surfaces on the V2 branch.

IMPLEMENT
1. Consolidate operator/developer documentation to the small V2 model:
   - README.md
   - docs/INSTALL.md
   - docs/OPERATIONS.md
   - docs/SECURITY.md
   - docs/RECOVERY.md
   - docs/DEVELOPMENT.md
   Use vwctl --help as the executable command reference rather than generating a giant command manual.
2. Ensure documentation reflects the authoritative prompt contract:
   - SOPS + Age structured secrets and offline recovery material;
   - rclone first-class copy-style publication + separate prune;
   - HTTPS operational API primary + transient SMTP fallback;
   - Vaultwarden direct SMTP;
   - no Postfix/custom queue;
   - Cloudflare-first/CrowdSec edge;
   - pinned production versions and dev/test-only --use-latest.
3. Create/retain a small release acceptance procedure for disposable Ubuntu 24.04 amd64 and arm64 environments where available. Exercise actual installed behavior rather than source-string assertions.
4. Acceptance should cover at least:
   - clean install and installed layout;
   - start/status/doctor;
   - Cloudflare ingress policy establishment/fail-closed behavior;
   - CrowdSec status/integration;
   - SOPS/Age secret materialization without leakage;
   - backup -> rclone publication -> remote verification -> download -> restore;
   - notification primary success and a representative transient SMTP fallback path without requiring a durable queue;
   - systemd timers/units;
   - pinned update path.
5. Remove V1 implementation/docs/tests from the V2 branch once no longer required as build/runtime inputs. If historical reference is useful, rely on git history/main rather than shipping a compatibility layer.
6. Prefer deleting superseded files and consolidating genuinely related V2 responsibilities where that reduces repository surface without creating catch-all modules or weakening clarity.
7. Keep permanent PR CI small: quality, unit, integration. Treat destructive/full host acceptance as a release gate rather than recreating a huge per-PR controller.

NON-GOALS
- no V1 compatibility layer
- no dashboard
- no generated exhaustive command reference
- no additional provider abstractions
- no test-runner framework
```

---

# Corrective PR prompt — use after phases are established

```text
Fix one observable V2 bug with the smallest owner change.

Read root AGENTS.md and reports/V2-CODEX-PROMPTS.md. The Common V2 contract remains authoritative.

1. State the observable bug and affected public/stable boundary.
2. Inspect V1 only if it can clarify a required security property; do not port its architecture.
3. Change the smallest owning module/config/template. Prefer modifying the existing cohesive owner rather than creating another file solely for the fix.
4. Add one highest-value behavioral regression test only if the existing suite does not already protect the behavior.
5. Do not use the bug as a reason to introduce a framework, provider registry, compatibility layer, generic abstraction, or unrelated refactor.
6. Run the smallest validation sufficient for confidence.
7. Final summary must state behavior changed, validation run/not run, and out-of-scope follow-ups without implementing them.
```

---

# Agent review checklist

Before accepting any V2 agent PR, verify:

- the work belongs to the requested phase;
- `reports/V2-CODEX-PROMPTS.md` was treated as authoritative;
- V1 implementation shape was not imported without necessity;
- no speculative framework/provider/compatibility layer appeared;
- new files were not created unnecessarily when an existing cohesive owner was appropriate;
- file-count reduction was treated as a preference rather than a quota, with no unrelated catch-all modules created to game the count;
- obsolete V2-branch files/wrappers were deleted when no longer needed instead of being retained as compatibility clutter;
- secrets never moved into ordinary config/argv/logs;
- rclone publication is non-destructive and pruning is separate;
- notification API/SMTP fallback follows the failure classification contract and does not recreate a queue;
- tests protect observable risk rather than source structure;
- the PR is small enough to understand and review;
- later-phase suggestions were reported, not implemented.