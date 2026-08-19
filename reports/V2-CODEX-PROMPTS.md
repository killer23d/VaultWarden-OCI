# VaultWarden-OCI V2 — Authoritative Standalone Codex Prompts

Date: 2026-08-18
Revision: standalone copy/paste format after V2 branch creation and later SOPS/Age, rclone, notification, and file-surface decisions.

## Authority and usage

This file is the **authoritative V2 agent execution contract**.

Each phase below is intentionally **self-contained and repetitive**. Open the phase you want, copy the entire fenced block, and paste it into a fresh Codex session. **Do not combine multiple phase prompts in one Codex session.** You should not need to scroll to a shared contract elsewhere in this file.

Precedence for V2 work:

1. A human's explicit task instruction is highest priority.
2. The complete phase/corrective prompt pasted from this file is the authoritative implementation contract for that session.
3. Root `AGENTS.md` is a concise repository map and durable working guide; it must not become a second competing architecture specification.
4. ADRs and other `reports/V2-*.md` files provide rationale/supporting detail. If they conflict with the pasted prompt, follow the pasted prompt and report the stale supporting document.

The long-lived development branch is `v2`. Phase work should normally happen on a task branch based on current `v2`, then be reviewed and merged into `v2`. Phase 0 comes first; phases proceed in order unless a human explicitly changes the plan.

---

<details>
<summary><strong>Prompt 0 — V2 contract reset (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 0: contract reset

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Do not rely on another phase prompt. Human instructions given with this task override this prompt; otherwise follow this prompt when repository documentation conflicts.

WORKFLOW
- Work on the assigned task branch/worktree based on the long-lived `v2` branch.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 0 only. Do not implement later phases opportunistically.
- If you discover a useful out-of-scope improvement, report it in the final summary instead of implementing it.

V2 PRODUCT BOUNDARY
- V2 is a greenfield fresh-install release for a small team of roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only.
- First-class tested architectures: amd64 and arm64.
- Runtime is cloud-provider neutral. OCI A1 Flex is a reference deployment, not a runtime dependency.
- Production ingress is Cloudflare-first and CrowdSec remains required.
- V2 has no requirement to import V1 project state, V1 backups, V1 migration state, V1 command aliases, V1 runtime layouts, or V1 compatibility behavior.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 standard library is preferred for structured application logic.
- Bash is only for small bootstrap/host/container glue where shell is materially simpler.
- Do not add runtime third-party Python dependencies without an explicit requirement.
- Development-only pytest and ruff are allowed; ShellCheck is allowed for remaining shell.
- Prefer fewer cohesive first-party files when responsibilities remain clear. Before creating a new module/script/config fragment, ask whether the behavior naturally belongs in an existing owning file.
- Do not split small behavior into one-function modules, one-purpose wrapper scripts, duplicate config fragments, or speculative future-facing files merely for architectural neatness.
- File-count reduction is a preference, not a quota. Do not create giant catch-all modules, mix unrelated responsibilities, or weaken readability/testability/security just to reduce file count.
- When V2 replaces a V1 product surface on the V2 branch, prefer eventual deletion over wrappers, aliases, empty placeholders, or compatibility shims unless a current requirement needs them.
- Do not introduce a framework, plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, Kubernetes/Swarm/HA abstraction, generic cloud abstraction, generic storage-provider abstraction, generic notification-provider abstraction, or generic firewall-backend abstraction.
- Do not port V1 code by default. Inspect V1 only for security properties or behavior explicitly required by this task.
- Prefer deleting a requirement to abstracting it.

OPERATOR / CONFIG BOUNDARY
- One public production CLI: `vwctl`.
- One installed non-secret configuration authority: `/etc/vaultwarden-oci/config.toml`.
- One source-controlled production versions manifest: `versions.toml`.
- No dashboard/TUI in beta; use `vwctl status` and `vwctl doctor`.
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
- rclone is a first-class V2 offsite backup/recovery capability.
- Project code owns only a small wrapper for diagnostics, connectivity, publication, listing, download/staging, verification, and explicit retention/pruning.
- Normal publication is: create -> verify local -> rclone copy/copyto -> verify remote -> report success.
- Normal publication must not use destructive sync semantics that can delete remote recovery points because local files disappeared.
- Remote retention/deletion is a separate explicit operation.
- Do not build a storage-provider plugin framework around rclone.

EMAIL / NOTIFICATION BOUNDARY
- Vaultwarden application email uses Vaultwarden's direct authenticated SMTP support.
- Project operational notifications use one concrete HTTPS email API as primary transport.
- After a small bounded API retry, direct authenticated SMTP may be fallback for clearly transient delivery failures such as network/DNS timeout, HTTP 429, and service-side 5xx.
- Authentication/configuration/permanent request failures such as representative 400/401/403 remain visible and normally must not be masked by SMTP success.
- TLS certificate/hostname validation failure is a security/configuration failure, not a silent failover condition.
- SMTP uses certificate and hostname validation with implicit TLS or required STARTTLS plus authentication.
- API tokens and SMTP credentials never appear in argv, normal logs, exception text, or debug transcripts.
- If both transports fail, preserve only a small secret-free diagnostic result visible to status/doctor.
- No mandatory Postfix container, local MTA, project-built durable queue, spool, retry scheduler, or dead-letter system.
- Do not build a generic notification/provider framework. Beta supports exactly one concrete HTTPS API integration plus one SMTP fallback path.
- The concrete HTTPS API provider must be named in an ADR before Phase 6. If not selected during this phase, record the decision as OPEN; do not guess a provider or create a generic abstraction to avoid the decision.

EDGE BOUNDARY
- Beta production ingress is Cloudflare-proxied HTTPS with Caddy.
- Support one Docker Engine bridge + iptables packet-filter path for published Caddy ingress.
- Own one small project ingress chain/allowlist behavior for Cloudflare IPv4/IPv6 ranges with last-known-good cache and bounded staleness.
- Fail closed when a safe Cloudflare ingress policy cannot be established.
- Do not implement multiple firewall backends in beta.

VERSION BOUNDARY
- Production uses exact source-controlled pins.
- `--use-latest` is development/testing-only.
- `--use-latest` resolves to exact versions at the start of a run and records the exact resolved set; it never creates floating production state.

TEST BOUNDARY
- Tests exist only to protect security, availability, recoverability, and operator truthfulness.
- Use only three validation layers: focused unit tests, small integration tests, disposable real-host release acceptance.
- Add only tests required for behavior changed by the current task.
- Prefer public/stable behavioral boundaries.
- Do not test exact private source strings/order, extract private functions with awk/sed, freeze human prose, or duplicate production state machines.
- Do not build a custom test runner/inventory or coverage-percentage gate.
- Use real temporary files/SQLite/archives when cheaper and clearer than elaborate mocks.
- Mock only stable external boundaries such as subprocess, HTTP, SMTP, rclone, SOPS/Age, or filesystem metadata.
- One behavior should normally have one best-level permanent test, not copies at every layer.

READ FOR CONTEXT
- `reports/V2-CODEX-PROMPTS.md` (this authoritative source file)
- `reports/V2-AUDIT.md`
- `reports/V2-ARCHITECTURE-PROPOSAL.md`
- `reports/V2-IMPLEMENTATION-ROADMAP.md`
- `reports/V2-TEST-STRATEGY.md`
- `reports/V2-DOCUMENTATION-AUDIT.md`
- `reports/V2-ACCEPTED-DECISIONS-EMAIL-RCLONE.md`

GOAL
Reset repository instructions and record the minimal V2 product/architecture decisions. Do not implement production runtime features.

IMPLEMENT
1. Rewrite root `AGENTS.md` into a concise V2 map. It must:
   - state `reports/V2-CODEX-PROMPTS.md` is the authoritative V2 agent execution contract;
   - tell agents to use the applicable complete phase/corrective prompt from that file;
   - state V2 is greenfield and V1 is security/behavior reference only, not compatibility API;
   - state Python 3.12 stdlib owns structured logic and Bash is minimal glue;
   - state one `vwctl` CLI, one TOML config authority, one versions manifest;
   - point to the small set of ADRs/product docs instead of duplicating them;
   - state later phases must not be implemented early;
   - remain short enough to be a map, not a second architecture manual.
2. Add/update one concise V2 product-boundary document.
3. Add short ADRs for exactly these durable decisions:
   - Python-first hybrid language boundary;
   - one installed TOML non-secret configuration authority;
   - SOPS + Age structured secrets with operational and offline recovery identities;
   - Cloudflare-only beta ingress using one supported Docker iptables packet path;
   - operational notifications: one concrete HTTPS API primary + authenticated SMTP transient-failure fallback, no Postfix/custom queue;
   - rclone first-class with copy-style publication and separate retention/pruning;
   - one V2 recovery format, offline recovery material, no V1 migration/archive compatibility;
   - bounded three-layer test strategy.
4. Notification ADR: name the concrete HTTPS email API provider if a human/repository decision already exists. Otherwise mark it OPEN and explicitly block Phase 6 from inventing a generic provider abstraction. Do not guess.
5. If useful, add one small ADR index. Do not build ADR tooling/frameworks.
6. Prefer a small number of durable documents. Do not create one file per minor rule when a cohesive ADR/product document can own related decisions without becoming ambiguous.

ALLOWED SCOPE
- `AGENTS.md`
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
- no later phase implementation

DEFINITION OF DONE
A new agent entering the V2 branch sees a short `AGENTS.md` that sends it to the authoritative standalone phase prompts, and the repository no longer tells V2 work to preserve V1 architecture.

FINAL RESPONSE REQUIRED
- Summarize behavior/doc contract changed.
- State the smallest validation sufficient and what was actually run.
- State validation not run.
- State whether any new files were created and why each was necessary.
- List out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 1 — Minimal Python foundation (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 1: minimal Python foundation

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 1 only. Do not implement later phases opportunistically.
- Report useful out-of-scope improvements instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield fresh-install release for roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only; tested amd64 and arm64.
- Cloud-provider-neutral runtime; OCI A1 Flex is reference only.
- Cloudflare-first production ingress and CrowdSec are required later phases.
- No V1 project-state, backup, migration, command, layout, or compatibility requirement.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib is preferred for structured application logic; Bash is minimal glue only.
- No runtime third-party Python dependencies unless explicitly required by this task. Dev-only pytest/ruff are allowed; ShellCheck for remaining shell.
- Prefer fewer cohesive first-party files. Reuse an existing owning module before creating another file when responsibility remains clear.
- Do not create one-function modules, wrapper scripts, duplicate config fragments, speculative extension points, or future placeholders.
- File-count reduction is a preference, not a quota: do not create giant catch-all modules or mix unrelated responsibilities merely to reduce files.
- Prefer deletion over V1 wrappers/aliases/shims when replacement cleanup belongs to the current phase; otherwise leave unrelated V1 cleanup for Phase 8.
- No framework, provider/plugin registry, ORM, daemon, database, event bus, workflow engine, generic transaction system, distributed lock, HA/Kubernetes/Swarm abstraction, generic cloud/storage/notification/firewall abstraction.
- Do not port V1 code by default; use it only to understand required security properties.

DURABLE V2 BOUNDARIES
- One public CLI: `vwctl`.
- One installed non-secret config authority: `/etc/vaultwarden-oci/config.toml`.
- One source-controlled versions authority: `versions.toml`.
- No dashboard/TUI; no V1 migration/archive reader; one normal V2 recovery format plus offline recovery material.
- Keep SOPS + Age: one structured encrypted secrets document, root-only operational Age identity, offline recovery identity/material, volatile decrypted runtime material only. Do not build a secrets/KMS abstraction.
- Keep rclone first-class for offsite backup/recovery. Publication is create -> verify local -> copy/copyto -> verify remote -> success; pruning/deletion is separate; no destructive sync as normal publication; no storage-provider framework.
- Vaultwarden mail is direct authenticated SMTP. Operational notifications later use one concrete HTTPS email API primary with authenticated SMTP fallback only for clearly transient failures after bounded retry. No Postfix, MTA, durable queue, spool, dead-letter system, or provider registry.
- Beta edge later supports Cloudflare-proxied Caddy through one Docker bridge + iptables ingress model with validated Cloudflare ranges, bounded last-known-good cache, and fail-closed behavior. No multiple firewall backends.
- Production versions are exact pins. `--use-latest` is dev/test only, resolves once to exact values, records them, and never creates floating production state.

TEST BOUNDARY
- Tests protect security, availability, recoverability, and operator truthfulness.
- Three layers only: focused unit, small integration, disposable real-host release acceptance.
- Add only tests needed for behavior changed in this phase; prefer public/stable boundaries.
- No exact-source-string/order tests, private-function extraction, prose freezing, duplicated state machines, custom runner/inventory, or coverage gate.
- Prefer real temp files over large mocks; mock only stable external boundaries.
- One behavior should normally have one best-level permanent test.

READ FOR CONTEXT
- root `AGENTS.md`
- relevant V2 ADRs/product boundary
- `reports/V2-CODEX-PROMPTS.md` if needed for provenance; this pasted block controls this session.

GOAL
Create the smallest practical Python 3.12 foundation for `vwctl` without Docker/root mutation.

IMPLEMENT
1. Create the minimal practical Python package/entrypoint for `vwctl`.
2. Implement only:
   - `vwctl --help`
   - `vwctl --version`
   - `vwctl config validate --file PATH` (or an equally small explicit form)
   - `vwctl versions`
   - `vwctl doctor [--json]` with host/architecture/config/version-file checks only.
3. Use stdlib `argparse`, `tomllib`, `json`, `pathlib`, `subprocess`, `fcntl` as appropriate.
4. Add one `versions.toml` containing exact values needed by this phase only.
5. Normalize amd64/x86_64 and arm64/aarch64; unsupported architecture fails clearly.
6. Add one small subprocess helper accepting argv arrays and normalizing success/nonzero/not-found without shell interpolation.
7. Add one global mutation-lock primitive using `fcntl.flock`; do not attach it to read-only commands.
8. Define stable doctor check IDs and PASS/WARN/FAIL/SKIP. Human prose is not API-stable; JSON shape/check IDs are.
9. Keep module count low: combine closely related foundation behavior when ownership remains clear; do not pre-create modules for later phases.

TESTS REQUIRED
- valid/invalid config TOML fixtures
- valid/invalid versions manifest behavior
- amd64/arm64 mapping + unsupported architecture
- subprocess success/nonzero/not-found
- lock contention using real temporary files
- doctor JSON shape/check IDs for checks implemented now

TEST LIMIT
Ordinary pytest discovery only. No plugins, custom runner, inventory, coverage gate, or large fixture framework.

NON-GOALS
- no Docker/Compose mutation
- no installer/root writes
- no SOPS/Age execution
- no HTTP/email/rclone
- no Cloudflare/CrowdSec/firewall
- no backup/restore
- no systemd/update implementation
- no command/plugin registry
- no empty future modules

FINAL RESPONSE REQUIRED
- State behavior changed.
- State smallest validation sufficient and highest-value test layer.
- List exact tests/validation run and validation not run.
- List new files and why each was necessary; note whether an existing file could have owned the behavior.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 2 — Bootstrap and installed layout (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 2: bootstrap and installed layout

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 2 only; do not start Vaultwarden or implement later-phase features.
- Report out-of-scope improvements instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield fresh-install release for a small team; Ubuntu 24.04 LTS Noble only; amd64 and arm64.
- Cloud-provider neutral; OCI A1 Flex reference only; Cloudflare-first + CrowdSec remain later security requirements.
- No V1 state/backup/migration/command/layout compatibility requirement.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib owns structured logic. Bash is only minimal bootstrap/host/container glue where materially simpler.
- No runtime third-party Python dependency without explicit need.
- Prefer fewer cohesive first-party files and reuse existing owning files where responsibility is clear.
- Do not create wrapper scripts for every action, one-function modules, duplicate config fragments, future placeholders, or speculative abstractions.
- File count is a preference, not a quota; do not create giant mixed-responsibility files to reduce count.
- No framework, plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction/distributed-lock/cloud/storage/notification/firewall abstractions.
- Do not port V1 architecture by default.

DURABLE V2 BOUNDARIES
- One CLI `vwctl`; one non-secret config `/etc/vaultwarden-oci/config.toml`; one `versions.toml`.
- No dashboard/TUI, V1 migration/archive reader, or multiple public backup tiers.
- Keep SOPS + Age with one structured encrypted document, root-only operational Age identity, offline recovery material, volatile decrypted secrets only.
- Keep rclone first-class with copy/copyto publication after local verification, remote verification before success, and separate pruning; no storage plugin layer.
- Vaultwarden direct authenticated SMTP. Operational notifications later: one concrete HTTPS API primary + authenticated SMTP transient fallback; no Postfix/custom queue/provider framework.
- Edge later: one Cloudflare-proxied Caddy + Docker bridge/iptables ingress model, bounded last-known-good Cloudflare ranges, fail closed; no multiple firewall backends.
- Production exact pins; `--use-latest` dev/test only and frozen to exact values per run.

TEST BOUNDARY
- Three layers only: focused unit, small integration, disposable real-host acceptance.
- Add only tests for behavior changed in this phase; no source-string/order tests, private-function extraction, prose freezing, custom runner/inventory, or coverage gate.
- Prefer temp roots/files over elaborate mocks.

READ FOR CONTEXT
- root `AGENTS.md`
- Phase 0 product boundary/ADRs
- current Phase 1 implementation

GOAL
Install the V2 application/config/state layout safely on a clean Ubuntu 24.04 host. Do not start Vaultwarden yet.

IMPLEMENT
1. Add one minimal root bootstrap. Prefer a small Bash entrypoint that checks basic prerequisites and delegates structured work to Python; do not build a Bash application framework.
2. Validate Ubuntu 24.04 and amd64/arm64.
3. Create the installed layout required now:
   - `/opt/vaultwarden-oci/releases/<release>/`
   - `/opt/vaultwarden-oci/current` symlink
   - `/etc/vaultwarden-oci/config.toml`
   - operational Age key location/permissions contract
   - `/var/lib/vaultwarden-oci/` state directories actually needed now
   - `/run/vaultwarden-oci/` volatile state.
4. Install the current V2 Python application immutably under the release directory and expose `vwctl` through the intended stable path.
5. Create only users/groups/directories actually required by the current design.
6. Add only minimal systemd integration needed to make the installed CLI/layout addressable; later timers/services belong to Phase 6.
7. Re-running installation for the same release/config must be safe; incompatible pre-existing ownership/state must fail clearly.
8. Keep installer/file surface compact. Do not create a script per installation sub-step when a cohesive Python owner or one bootstrap can handle it clearly.

TESTS / VALIDATION
- focused unit tests for path/permission/rendering decisions
- small integration tests against temporary roots where practical
- one disposable Ubuntu 24.04 installation smoke validation if environment supports it

NON-GOALS
- no Vaultwarden/Caddy start
- no secret decryption/runtime materialization
- no Cloudflare/CrowdSec/firewall
- no rclone backup/restore
- no operational notifications
- no update engine
- no V1 migration
- no broad systemd timer suite

FINAL RESPONSE REQUIRED
- State behavior changed and installation contract established.
- State smallest validation sufficient, exact validation run, and validation not run.
- List new files and justify each; call out avoided unnecessary wrappers/modules.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 3 — Core Vaultwarden/Caddy runtime and secrets (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 3: core runtime and secrets

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 3 only. Edge enforcement, rclone recovery, operational notifications, and updates belong to later phases.
- Report out-of-scope improvements rather than implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance for a small team; amd64 + arm64.
- Cloud-provider neutral; OCI A1 Flex reference only.
- Cloudflare-first production ingress and CrowdSec remain required, but Phase 4 owns their enforcement/integration.
- No V1 state/backup/migration/command/layout compatibility.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib owns structured logic; Bash only minimal host/container glue.
- No runtime third-party Python dependencies unless explicitly required.
- Prefer fewer cohesive files; extend an existing owning module when responsibility is clear rather than creating thin wrappers or one-function modules.
- Do not split Compose/config/secret behavior into speculative provider layers or future extension points.
- File-count reduction is not a quota; preserve clear security boundaries and readability.
- No framework, registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, HA/Kubernetes/Swarm, or generic cloud/storage/notification/firewall abstraction.
- V1 may be inspected only for required security properties; do not port its architecture wholesale.

DURABLE V2 BOUNDARIES
- One CLI `vwctl`; one non-secret config `/etc/vaultwarden-oci/config.toml`; one `versions.toml`.
- No dashboard/TUI or V1 migration/archive reader.
- SOPS + Age stays: one structured encrypted secrets document, root-only operational Age identity, offline recovery identity/material, decrypted runtime secrets only in root-owned volatile storage. No project crypto/KMS/secrets framework.
- rclone remains first-class later; copy/copyto publication after verification, separate pruning, no destructive sync/default storage framework.
- Vaultwarden application mail uses direct authenticated SMTP.
- Project operational notifications later use one concrete HTTPS API primary + direct authenticated SMTP fallback only for clearly transient failures after bounded retry. No Postfix, local MTA, durable queue/spool/dead-letter system, or provider registry.
- Edge later uses Cloudflare-proxied Caddy through one Docker bridge + iptables ingress model with validated/bounded Cloudflare ranges and fail-closed behavior.
- Production versions exact; `--use-latest` dev/test only and frozen per run.

TEST BOUNDARY
- Three layers only: focused unit, small integration, disposable real-host acceptance.
- Add only tests needed for changed behavior; prefer public/stable boundaries.
- No private source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, custom runner/inventory, or coverage gate.
- Mock subprocess only at stable external-command boundaries; prefer real temp files for secret-materialization paths where safe.

READ FOR CONTEXT
- root `AGENTS.md`
- Phase 0 ADRs/product boundary
- current installed-layout/runtime foundation

GOAL
Run Vaultwarden behind Caddy using the V2 config/secrets contract, without implementing host edge firewall/CrowdSec or project operational notification delivery yet.

IMPLEMENT
1. Minimal Compose/runtime definition containing Vaultwarden + Caddy only.
2. Preserve useful hardening where compatible: explicit users, `cap_drop: ALL` plus only demonstrated additions, no-new-privileges, read-only roots/tmpfs where practical, bounded logs, health checks, reasonable memory/PID limits.
3. Implement SOPS + Age orchestration:
   - one structured SOPS-encrypted secrets document;
   - one root-only operational Age identity;
   - offline recovery recipient/material contract;
   - decrypt only to root-owned volatile runtime files;
   - validate required secret keys before start;
   - never place plaintext secrets in `config.toml`, argv, ordinary logs, or persistent temporary files.
4. Implement `vwctl start|stop|restart|status|logs` for the two-container stack.
5. Configure Vaultwarden application email using Vaultwarden's direct authenticated SMTP support. Do not add Postfix.
6. Caddy provides the reverse-proxy/DNS-01 path needed for Cloudflare-first production, but Phase 4 owns host ingress enforcement and CrowdSec.
7. Add doctor checks only for runtime behavior introduced here.
8. Keep files cohesive: prefer one clear runtime owner and one clear secrets owner rather than layers of wrappers/adapters unless a security boundary requires separation.

TESTS REQUIRED
- focused config-to-runtime rendering/validation
- SOPS/Age orchestration with external commands mocked at their stable boundary
- prove plaintext secrets do not leak to persistent generated config, argv, or loggable structures
- representative lifecycle/status behavior at the smallest useful integration level

NON-GOALS
- no project operational HTTPS API/SMTP fallback module yet
- no Postfix/mail queue
- no Cloudflare CIDR firewall enforcement
- no CrowdSec setup
- no backup/restore/rclone
- no update engine

FINAL RESPONSE REQUIRED
- State runtime/security behavior changed.
- State smallest validation sufficient and exact tests/validation run/not run.
- List new files and justify each security/ownership boundary; note avoided unnecessary splits.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 4 — Cloudflare ingress and CrowdSec (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 4: Cloudflare ingress and CrowdSec

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 4 only. Do not expand into backup, notification, update, or generic firewall work.
- Report out-of-scope ideas rather than implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance, amd64 + arm64, small team/junior admin.
- Cloud-provider neutral; OCI A1 Flex reference only.
- Production beta ingress is Cloudflare-first and CrowdSec is required.
- No V1 migration/state/backup/command/layout compatibility.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib for structured logic; Bash only minimal host glue.
- Prefer fewer cohesive files. Extend existing edge/diagnostic owners instead of one script/module per rule operation.
- Do not create a generic firewall/provider abstraction, backend registry, rule DSL, or plugin model.
- File-count reduction is a preference, not a quota; do not mix unrelated security responsibilities just to reduce files.
- No framework, ORM, daemon, database, event bus, workflow engine, generic transaction/distributed-lock/cloud/storage/notification abstraction, Kubernetes/Swarm/HA.
- Do not port the large V1 firewall/CrowdSec architecture wholesale. Preserve security properties, not implementation shape.

DURABLE V2 BOUNDARIES
- One CLI `vwctl`; one config TOML; one versions manifest; no dashboard/TUI.
- SOPS + Age remains the secret mechanism with root-only operational identity and volatile decrypted material.
- rclone remains first-class later with copy-style publication + separate prune.
- Vaultwarden direct authenticated SMTP; project operational notification API+SMTP fallback later; no Postfix/custom queue/provider registry.
- Beta edge supports exactly one Docker Engine bridge + iptables packet-filter path for published Caddy ingress.
- Cloudflare IPv4/IPv6 policy uses validated data, a last-known-good cache with bounded staleness, and fail-closed behavior when no safe policy exists.
- Do not implement nftables or another firewall backend in beta.
- Production exact version pins; `--use-latest` dev/test only.

TEST BOUNDARY
- Three validation layers only: focused unit, small integration, disposable real-host acceptance.
- Tests protect observable security behavior, not exact source/rule text unless the rendered rule contract itself is the stable output.
- No custom runner/inventory or coverage gate; no huge mocked firewall state machine.

READ FOR CONTEXT
- root `AGENTS.md`
- Phase 0 edge ADR
- current Phase 3 Caddy/runtime behavior

GOAL
Establish the single supported beta production edge: Cloudflare-proxied Caddy with fail-closed Docker iptables ingress and CrowdSec integration.

IMPLEMENT
1. Cloudflare IPv4/IPv6 retrieval, strict parsing/validation, last-known-good persistence, and bounded staleness.
2. One small project-owned Docker iptables ingress chain/path that allows published Caddy HTTPS only from validated Cloudflare ranges for the supported beta model.
3. Fail closed if no safe current/last-known-good policy is available.
4. Do not claim ordinary UFW `INPUT` rules alone protect Docker-published Caddy ports. UFW may still protect normal host services such as SSH where appropriate.
5. Retain CrowdSec using current upstream installation/integration paths where possible:
   - host agent/acquisitions required by this product;
   - host firewall bouncer for host-visible traffic where appropriate;
   - Cloudflare edge/Worker bouncer for proxied web-client enforcement;
   - minimal project-owned config/credentials/status/test integration.
6. Add `vwctl`/doctor status/test behavior needed to explain edge health to a junior administrator.
7. Keep project-owned edge files minimal; do not create wrappers around every CrowdSec/upstream command.

TESTS REQUIRED
- CIDR parsing/validation/staleness
- deterministic ingress-policy/rule decisions for the one supported backend
- fail-closed behavior
- minimal integration at external command boundaries

NON-GOALS
- no nftables alternative
- no generic firewall abstraction
- no direct/non-Cloudflare production ingress mode
- no cloud security-group API integration
- no wholesale V1 CrowdSec installer port
- no backup/rclone/notification/update work

FINAL RESPONSE REQUIRED
- State security behavior changed.
- State smallest sufficient validation and exact tests/validation run/not run.
- List new files and justify each; identify any avoided backend/provider abstractions.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 5 — Backup, restore, rclone, offline recovery (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 5: backup, restore, rclone, and offline recovery

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 5 only. Do not implement notification/systemd/update features beyond what this recovery work strictly requires.
- Report out-of-scope improvements rather than implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance, amd64 + arm64, small team/junior admin.
- Cloud-provider neutral; OCI reference only; Cloudflare/CrowdSec security model remains.
- No V1 state, backup-format, migration, command, or runtime-layout compatibility.
- One normal V2 encrypted recovery format plus offline recovery material. Do not recreate V1 db/full/emergency public tiers.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib for structured recovery logic; Bash only tiny glue if materially clearer.
- Prefer fewer cohesive files. Backup/restore may share a recovery-domain owner when responsibilities remain clear; do not split every archive/manifest/rclone operation into wrapper modules.
- Do not create a generic storage/provider framework around rclone, a transaction framework, workflow engine, backup plugin registry, or compatibility layer.
- File-count reduction is not a quota; keep security-critical validation/promotion boundaries clear even if that requires a separate cohesive module.
- No runtime third-party Python dependency unless explicitly required.
- Inspect V1 only for recovery/security properties, not architecture to port.

DURABLE V2 BOUNDARIES
- One `vwctl`, one config TOML, one versions manifest, no dashboard/TUI.
- SOPS + Age: one structured encrypted secrets doc, root-only operational Age identity, offline recovery identity/material, volatile decrypted runtime secrets only. Do not put the operational private key in ordinary backup artifacts.
- rclone is first-class. Project wrapper remains small: diagnostics, connectivity, publication, listing, remote verification, download/staging, explicit pruning.
- Normal offsite publication: create -> verify local -> `rclone copy`/`copyto` style publication -> verify remote cohort -> report success.
- Remote deletion/pruning is a separate explicit operation. Normal publication must not use destructive `rclone sync` semantics that could delete recovery points because local files disappeared.
- Vaultwarden direct SMTP and later API+SMTP operational notifications remain unchanged; no Postfix/custom queue.
- Production exact pins; `--use-latest` dev/test only.

TEST BOUNDARY
- Recoverability is a core safety property, so this phase may receive disproportionate focused testing.
- Still use only three layers: unit, small integration, disposable host acceptance.
- Prefer real temporary SQLite databases/files/archives to elaborate mocks.
- Mock rclone/SOPS/Age only at stable external command boundaries.
- No private-source grep/order tests, extracted private functions, custom runner/inventory, or coverage quota.
- Avoid duplicate tests of the same behavior across layers.

READ FOR CONTEXT
- root `AGENTS.md`
- Phase 0 recovery/rclone/secrets ADRs
- current runtime/storage layout

GOAL
Provide one safe encrypted V2 recovery format, first-class offsite rclone publication, and V2-only restore.

IMPLEMENT
1. `vwctl backup` creates one complete V2 recovery point with:
   - consistent SQLite snapshot;
   - required persistent application/configuration material;
   - manifest containing V2 format version, metadata, and checksums;
   - encryption before publication;
   - verification before success.
2. Exclude the operational Age private key from ordinary recovery artifacts. Offline recovery material/recipient must be documented and testable without persisting its private recovery key on the server.
3. Local publication must be atomic enough that incomplete candidates are never reported as valid recovery points.
4. Keep rclone first-class with a small wrapper for configuration/prerequisite diagnostics, connectivity test, upload/publication, remote listing, remote verification, download/staging, and explicit retention/pruning.
5. Normal offsite publication order is exactly: create -> verify local -> copy/copyto-style publication -> verify required remote cohort -> report success.
6. Remote retention/deletion is separate. Do not use `rclone sync` as normal publication where deletion semantics could remove remote recovery points because local files disappeared.
7. `vwctl restore` supports V2 format only and must:
   - stage/decrypt/validate manifest/checksums before live mutation;
   - validate free space and target storage;
   - stop services only after preflight succeeds;
   - stage extracted state;
   - promote with a small explicit transaction boundary, not a generic framework;
   - restore permissions;
   - start only according to explicit policy/flag and require health before claiming success.
8. `status`/`doctor` shows last verified local/offsite recovery state without exposing secrets.
9. Keep the recovery file surface compact and understandable; no one-command wrapper file proliferation.

TESTS REQUIRED
- representative real-temp SQLite backup/restore paths
- corruption, wrong-key, incomplete-manifest, and preflight-failure behavior
- rclone command construction/result classification at stable boundary
- prove normal publication does not request destructive sync semantics
- representative remote verification + explicit prune decisions

NON-GOALS
- no db/full/emergency public tier model
- no V1 backup reader/migration
- no generic storage-provider framework
- no background replication daemon
- no durable notification queue

FINAL RESPONSE REQUIRED
- State recovery behavior changed and security properties protected.
- State smallest sufficient validation, highest-value test layer, exact validation run/not run.
- List new files and justify each; note where cohesive behavior was intentionally kept together.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 6 — Systemd automation and operational notifications (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 6: systemd automation and operational notifications

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 6 only. Do not introduce provider frameworks, durable queues, or update machinery.
- Report out-of-scope improvements instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance, amd64 + arm64, small team/junior admin.
- Cloud-provider neutral; OCI reference only; Cloudflare-first/CrowdSec remain.
- No V1 state/backup/migration/command/layout compatibility.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib for structured notification logic; Bash only minimal glue.
- Prefer fewer cohesive files. Use one small notification owner rather than one module per transport/status code/retry condition.
- Do not create a generic provider interface, plugin registry, delivery framework, local queue subsystem, job framework, or second scheduler.
- File-count reduction is a preference, not a quota; keep HTTPS and SMTP security boundaries readable even if separate functions/classes are warranted inside one cohesive module.
- No runtime third-party Python dependency unless explicitly required.
- No framework, ORM, daemon, database, event bus, workflow engine, generic transaction/distributed lock/cloud/storage/firewall abstraction.

DURABLE V2 BOUNDARIES
- One CLI `vwctl`, one config TOML, one versions manifest, no dashboard/TUI.
- SOPS + Age supplies notification secrets; secrets do not enter argv/logs/exceptions/debug transcripts.
- rclone recovery behavior remains first-class and unchanged.
- Vaultwarden application email uses Vaultwarden direct authenticated SMTP.
- Project operational notifications use exactly one concrete HTTPS email API as primary plus direct authenticated SMTP fallback only for clearly transient primary failures after a small bounded retry.
- Representative transient fallback cases: network/DNS timeout, HTTP 429 after bounded retry, service-side 5xx, plus only provider-documented transient cases.
- Representative 400/401/403, malformed request/configuration, permanent rejection, unsupported behavior, and TLS certificate/hostname validation failures remain visible and are not silently masked by SMTP success.
- SMTP uses normal certificate/hostname verification with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
- If both transports fail, store only a small secret-free diagnostic result visible through status/doctor.
- No Postfix container, local MTA, spool, persistent retry queue/scheduler, or dead-letter system.
- Beta supports one concrete HTTPS API integration; no second provider or provider registry.
- Production exact pins; `--use-latest` dev/test only.

TEST BOUNDARY
- Three layers only: focused unit, small integration, disposable host acceptance.
- Test deterministic classification and observable fallback behavior at stable boundaries.
- Mock HTTP and SMTP boundaries; do not build protocol simulators unless demonstrably necessary.
- No source-string/order tests, private-function extraction, custom runner/inventory, coverage gate, or duplicate transport tests at every layer.

READ FOR CONTEXT
- root `AGENTS.md`
- Phase 0 notification ADR
- current systemd/runtime/status/doctor design

PRECONDITION
The Phase 0 notification ADR must name the one concrete HTTPS email API provider for beta. If it remains OPEN, STOP and report the missing product decision. Do not guess a provider and do not invent a generic provider abstraction to avoid the decision.

GOAL
Add a small systemd automation surface and reliable-but-bounded project operational notifications without Postfix or a custom durable queue.

IMPLEMENT
1. Keep the permanent unit/timer set small. Add only units actually required for lifecycle, health, backup, and maintenance now.
2. Units execute the installed immutable release/current path and installed config; never an arbitrary git checkout.
3. Implement one small operational notification module used by `vwctl`/systemd tasks:
   - primary: the one concrete HTTPS email API named by the ADR;
   - fallback: direct authenticated SMTP.
4. HTTPS uses normal CA/hostname validation. Keep API credentials out of argv/logs/exceptions.
5. Use a small bounded primary retry policy only; no persistent scheduler.
6. SMTP fallback classification:
   - eligible: clearly transient network/DNS/timeouts, HTTP 429 after bounded retry, service-side 5xx, and only other provider-documented transient conditions;
   - not silently eligible: representative 400/401/403, malformed request/configuration, unsupported provider behavior, permanent rejection, certificate/hostname validation failure.
7. SMTP uses `ssl.create_default_context()` semantics with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
8. Return/store a small structured safe result such as transport, outcome, stable reason/category, event id/time, and safe diagnostic text.
9. If API and SMTP both fail, expose failure through status/doctor. Do not persist full message bodies or secret-bearing responses.
10. Do not build a mail spool, retry scheduler, dead-letter queue, SMTP server, MTA, Postfix container, provider registry, or second HTTPS provider.
11. Keep transport implementation cohesive; do not make one file for each HTTP status/retry rule/systemd notification type.

TESTS REQUIRED
- deterministic API success/transient/auth/config/permanent/TLS-validation classification
- prove SMTP fallback occurs for representative transient cases and does not mask representative configuration/security failures
- SMTP TLS/auth call behavior at stable mocked boundary
- secret-redaction/result-shape behavior
- minimal systemd unit rendering/command-target validation

NON-GOALS
- no provider registry
- no second HTTPS email API provider
- no durable notification queue
- no Postfix/local MTA
- no general job scheduler beyond systemd
- no update engine

FINAL RESPONSE REQUIRED
- State automation/notification behavior changed.
- State smallest sufficient validation and exact tests/validation run/not run.
- List new files and justify each; specifically explain why no provider/queue framework was added.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 7 — Versions and explicit updates (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 7: versions and explicit updates

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 7 only. Do not add unattended update daemons or generic component frameworks.
- Report out-of-scope improvements instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance, amd64 + arm64, small team/junior admin.
- Cloud-provider neutral; OCI reference only; Cloudflare/CrowdSec remain.
- No V1 migration/state/backup/command/layout compatibility.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib for structured version/update logic; Bash only minimal glue.
- Prefer fewer cohesive files. Centralize version resolution in one clear owner rather than one resolver file per component.
- Do not create generic component/provider/plugin registries, update frameworks, daemons, workflow engines, or abstraction layers for hypothetical future components.
- File-count reduction is a preference, not a quota; do not make a giant unrelated module merely to avoid a justified separation.
- No runtime third-party Python dependency unless explicitly required.
- Do not port V1 update/migration state machinery wholesale.

DURABLE V2 BOUNDARIES
- One `vwctl`, one non-secret config TOML, one source-controlled `versions.toml` authority.
- SOPS + Age, rclone, Cloudflare/CrowdSec, recovery, and notification boundaries remain as already implemented; do not redesign them here.
- Vaultwarden application SMTP and one concrete HTTPS operational notification API + transient SMTP fallback remain; no Postfix/custom queue/provider registry.
- Production uses exact source-controlled pins.
- `--use-latest` is development/testing-only: resolve compatible upstream versions once at run start, freeze exact values/digests where available, record that exact set, and pass exact values downstream. It must never create floating production state.

TEST BOUNDARY
- Three layers only: focused unit, small integration, disposable release acceptance.
- Test version parsing/resolution/architecture mapping and update decisions at stable boundaries.
- Avoid network-heavy permanent tests of third-party release services; mock the smallest stable remote boundary.
- No source-string/order tests, custom runner/inventory, or coverage gate.

READ FOR CONTEXT
- root `AGENTS.md`
- version/update ADR/product boundary if present
- current runtime/recovery/doctor implementation

GOAL
Provide reproducible pinned production versions, dev/test-only `--use-latest` resolution, and an explicit safe operator-driven update path.

IMPLEMENT
1. `versions.toml` is the only source-controlled component-version authority.
2. Centralize architecture-aware artifact/image resolution for amd64/arm64.
3. Production install/update uses exact pins only.
4. `--use-latest`:
   - explicitly non-production;
   - resolve compatible upstream versions once at the start;
   - convert immediately to exact versions/digests where available;
   - record the exact resolved set for the run;
   - pass only exact values downstream;
   - never scatter live-latest checks across component installers/templates.
5. Implement `vwctl update check|apply` with a small safe flow:
   - validate current state;
   - create/verify recovery point according to policy;
   - stage a new immutable application release;
   - pull/build exact pinned runtime components;
   - switch `current` symlink;
   - restart and health/doctor gate;
   - roll back application-release activation where safe before incompatible state changes.
6. Do not add an unattended auto-update daemon.
7. Keep component/version code compact; avoid per-component resolver modules unless a component truly has materially different stable logic.

TESTS REQUIRED
- versions parsing/resolution/architecture mapping
- prove `--use-latest` resolves once and freezes exact values for the run
- representative update activation/failure/rollback decisions
- smallest stable boundary for remote release lookup; no broad third-party API simulation

NON-GOALS
- no unattended updates
- no generic update/provider framework
- no migration engine
- no redesign of backup/edge/notification systems

FINAL RESPONSE REQUIRED
- State version/update behavior changed.
- State smallest sufficient validation and exact tests/validation run/not run.
- List new files and justify each; note avoided per-component file proliferation.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 8 — Beta docs, acceptance, and V2 cleanup (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 8: beta documentation, acceptance, and cleanup

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 8 only. This phase consolidates/docs/tests/removes obsolete V1 surfaces; it must not invent new product features.
- Report future ideas instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield fresh-install appliance for roughly 10 users/junior administrator.
- Ubuntu 24.04 LTS Noble only; amd64 + arm64.
- Cloud-provider neutral; OCI A1 Flex reference only.
- Cloudflare-first production ingress + CrowdSec.
- No V1 project-state, migration, backup-format, command, runtime-layout, or compatibility requirement.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib structured logic; Bash only minimal glue.
- Prefer fewer cohesive first-party files and documents. Delete obsolete V1 files on the V2 branch once they are no longer build/runtime inputs; rely on `main`/git history for historical reference.
- Prefer consolidation over wrapper/alias/placeholder retention, but do not combine unrelated responsibilities into giant catch-all files just to reduce count.
- Do not create generated exhaustive command docs, provider registries, compatibility shims, test frameworks, or extension-point placeholders.
- No framework, ORM, daemon, database, event bus, workflow engine, generic transaction/distributed-lock/cloud/storage/notification/firewall abstractions.

DURABLE V2 BOUNDARIES TO PRESERVE IN FINAL BETA
- One public CLI `vwctl`.
- One installed non-secret config `/etc/vaultwarden-oci/config.toml`.
- One source-controlled `versions.toml`.
- No dashboard/TUI; `vwctl status` + `vwctl doctor` are operator surfaces.
- SOPS + Age: one structured encrypted secrets document, root-only operational identity, offline recovery material/identity, volatile decrypted runtime secrets only; no secrets/KMS framework.
- rclone first-class: local verify -> copy/copyto -> remote verify -> success; separate explicit prune; no destructive sync default/provider framework.
- Vaultwarden application mail direct authenticated SMTP.
- Project operational notifications: one concrete HTTPS email API primary + direct authenticated SMTP fallback only for clearly transient failures after bounded retry; configuration/security/permanent failures remain visible; no Postfix/MTA/durable queue/provider registry.
- Cloudflare-proxied Caddy with one Docker bridge + iptables ingress model, validated Cloudflare ranges, bounded last-known-good cache, fail closed; CrowdSec integrated; no second firewall backend.
- One normal encrypted V2 recovery format + offline recovery material; no V1 reader/migration.
- Production exact pins; `--use-latest` dev/test only, resolved once to exact recorded values.

TEST BOUNDARY
- Permanent validation architecture has only three layers: focused unit, small integration, disposable real-host release acceptance.
- Permanent PR CI should remain small: quality, unit, integration.
- Full/destructive host acceptance is a release gate, not a giant per-PR controller.
- No source-string/order tests, private-function extraction, prose freezing, custom test runner/inventory, or coverage gate.
- One behavior normally has one best-level permanent test.

READ FOR CONTEXT
- root `AGENTS.md`
- authoritative V2 ADRs/product boundary
- current complete V2 implementation
- supporting V2 audit/architecture/test/docs reports

GOAL
Make V2 understandable, acceptance-tested on clean Ubuntu 24.04, and free of obsolete V1 product surfaces on the V2 branch.

IMPLEMENT
1. Consolidate operator/developer documentation to this small model unless an existing cohesive file makes one unnecessary:
   - `README.md`
   - `docs/INSTALL.md`
   - `docs/OPERATIONS.md`
   - `docs/SECURITY.md`
   - `docs/RECOVERY.md`
   - `docs/DEVELOPMENT.md`
   Prefer fewer documents if two responsibilities can be combined clearly without making a giant manual. Do not add more documents merely to mirror internal modules.
2. Use `vwctl --help` as executable command reference. Do not generate a giant command-reference file.
3. Ensure docs accurately describe:
   - SOPS + Age and offline recovery material;
   - rclone copy-style publication + separate prune;
   - HTTPS operational API primary + transient SMTP fallback;
   - Vaultwarden direct SMTP;
   - no Postfix/custom durable queue;
   - Cloudflare-first/CrowdSec edge;
   - pinned production versions and dev/test-only `--use-latest`.
4. Create/retain a small release acceptance procedure for disposable Ubuntu 24.04 amd64 and arm64 environments where available. Exercise installed behavior rather than source-string assertions.
5. Acceptance covers at least:
   - clean install + installed layout;
   - start/status/doctor;
   - Cloudflare ingress establishment/fail-closed behavior;
   - CrowdSec status/integration;
   - SOPS/Age materialization without leakage;
   - backup -> rclone publication -> remote verification -> download -> restore;
   - notification primary success + representative transient SMTP fallback without durable queue;
   - systemd units/timers;
   - pinned update path.
6. Remove obsolete V1 implementation/docs/tests from the V2 branch when no longer required as build/runtime inputs. Do not keep wrappers, aliases, empty placeholders, migration readers, dashboard files, Postfix queue tooling, or V1 test architecture for sentimental/historical reasons.
7. Review first-party file surface as part of beta readiness. Prefer deletion/consolidation where ownership remains clear, but do not pursue a numeric file-count target.
8. Keep permanent CI small; do not recreate the V1 acceptance controller as a large per-PR test framework.

NON-GOALS
- no V1 compatibility layer
- no dashboard/TUI
- no generated exhaustive command reference
- no additional provider abstractions
- no custom test-runner framework
- no new product capabilities unrelated to beta cleanup

FINAL RESPONSE REQUIRED
- Summarize beta cleanup/documentation/acceptance changes.
- State exact validation/acceptance run and what was not run.
- Report files deleted, consolidated, and newly created with rationale.
- Explicitly note whether file surface was reduced where natural without harming clear ownership.
- Report post-beta ideas without implementing them.
```

</details>

---

<details>
<summary><strong>Corrective PR prompt — One observable V2 bug (copy entire block)</strong></summary>

```text
TASK: VaultWarden-OCI V2 — corrective PR for one observable bug

This prompt is self-contained and is the authoritative implementation contract for this Codex session. Human instructions given with this task override it; otherwise follow this prompt if repository documentation conflicts.

WORKFLOW
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Fix one observable bug only. Do not turn the bugfix into a refactor, architecture rewrite, cleanup campaign, or later-phase implementation.
- Report unrelated improvements instead of implementing them.

V2 PRODUCT BOUNDARY
- Greenfield Ubuntu 24.04 LTS appliance for roughly 10 users/junior administrator; amd64 + arm64.
- Cloud-provider neutral; OCI reference only; Cloudflare-first + CrowdSec.
- No V1 state/backup/migration/command/layout compatibility requirement.

LANGUAGE / FILE-SURFACE / COMPLEXITY RULES
- Python 3.12 stdlib owns structured logic; Bash is minimal glue.
- Prefer changing the smallest existing owning file. Creating a new file for a bugfix requires a clear ownership/security reason.
- Do not create a helper module merely to hold one function or a wrapper script merely to avoid editing the correct owner.
- File-count reduction is a preference, not a quota; do not make unrelated code share a giant owner solely to avoid a file.
- No new framework, provider/plugin registry, ORM, daemon, database, event bus, workflow engine, generic transaction/distributed-lock/cloud/storage/notification/firewall abstraction, compatibility layer, or speculative extension point.
- Inspect V1 only if it clarifies a required security property; do not port V1 architecture.

DURABLE V2 BOUNDARIES
- One `vwctl`, one config TOML, one versions manifest, no dashboard/TUI, no V1 migration/archive reader.
- SOPS + Age structured secrets; operational key root-only; offline recovery material; volatile plaintext only; no secrets/KMS framework.
- rclone first-class with verify -> copy/copyto -> remote verify -> success and separate pruning; no destructive sync default/provider framework.
- Vaultwarden direct authenticated SMTP. Operational notifications: one concrete HTTPS API primary + transient-only SMTP fallback after bounded retry; config/security/permanent failures visible; no Postfix/MTA/durable queue/provider registry.
- Cloudflare-proxied Caddy through one Docker bridge + iptables model with validated/bounded Cloudflare ranges and fail-closed behavior; CrowdSec retained; no second firewall backend.
- One V2 recovery format + offline recovery material; no V1 backup reader.
- Production exact pins; `--use-latest` dev/test only and frozen per run.

TEST BOUNDARY
- Add one highest-value behavioral regression test only if existing tests do not already protect the bug.
- Prefer the public/stable boundary where the bug is observable.
- Do not add source-string/order tests, extract private functions, freeze prose, duplicate the behavior at several layers, add a custom runner/inventory, or introduce coverage gates.
- Use real temporary files/SQLite/archives when clearer than mocks; mock only stable external boundaries.

BUGFIX METHOD
1. State the observable bug and affected public/stable boundary before changing code.
2. Identify the smallest owning module/config/template.
3. Fix the root cause in that owner with the smallest coherent change.
4. Do not create a new abstraction merely because two lines now look similar.
5. Add one behavioral regression test only if there is a real coverage gap.
6. Run the smallest validation sufficient for confidence.
7. If the fix would require changing a durable V2 boundary above, STOP and report the conflict instead of silently widening architecture.

FINAL RESPONSE REQUIRED
- State the observable bug and root cause.
- State the smallest owner changed.
- State exact tests/validation run and validation not run.
- State whether any file was added; if yes, justify why an existing owner was insufficient.
- List out-of-scope follow-ups without implementing them.
```

</details>

---

## Human review checklist

This checklist is for the reviewer, not something that must be pasted into Codex because each standalone prompt already contains the relevant rules.

- The work belongs only to the requested phase/bug.
- The pasted standalone prompt was treated as authoritative.
- V1 implementation shape was not imported without necessity.
- No speculative framework/provider/compatibility layer appeared.
- New files have clear ownership value; thin wrappers/one-function modules/file proliferation were avoided.
- File-count preference was not gamed by creating giant mixed-responsibility files.
- Secrets never moved into ordinary config/argv/logs.
- rclone publication remains non-destructive and pruning remains separate.
- Notification API/SMTP fallback follows the failure-classification contract and does not recreate a queue.
- Tests protect observable risk rather than source structure.
- The PR is small enough to understand/review.
- Later-phase suggestions were reported, not implemented.
