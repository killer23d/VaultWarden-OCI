# VaultWarden-OCI V2 — Authoritative Standalone Codex Prompts

Date: 2026-08-18
Status: authoritative V2 agent execution contract.

## How to use this file

Each prompt below is deliberately **standalone**. Expand one section, copy the entire fenced block, and paste it into a fresh Codex session.

- Use one prompt per Codex session.
- Run phases in order unless a human explicitly changes the plan.
- Phase work normally starts from current `v2` and lands back into `v2` through review.
- Do not paste a shared preamble from elsewhere in this file; every block already contains the durable V2 contract.

### Authority

For an implementation session:

1. explicit human instructions supplied with that task;
2. the complete standalone prompt pasted from this file;
3. root `AGENTS.md` and V2 decisions/architecture as repository context.

If supporting documentation conflicts with the pasted prompt, follow the pasted prompt and report the stale document.

**Ordinary phase/corrective agents must not edit `reports/V2-CODEX-PROMPTS.md`.** Changing the agent contract is a separate human-authorized architecture/documentation task.

The durable supporting reports are intentionally limited to:

- `reports/V2-AUDIT.md` — evidence and reasons for the greenfield redesign;
- `reports/V2-ARCHITECTURE-PROPOSAL.md` — target architecture, documentation model, and phase sequence;
- `reports/V2-TEST-STRATEGY.md` — testing rationale and guardrails.

---

<details>
<summary><strong>Prompt 0 — Contract reset and decisions</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 0: contract reset and durable decisions

AUTHORITY / WORKFLOW
- This pasted prompt is the authoritative implementation contract for this session unless the human gives an explicit override.
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 0 only. No production runtime code.
- Do not edit `reports/V2-CODEX-PROMPTS.md`; changing the agent contract requires a separate human-authorized task.
- Report useful out-of-scope ideas instead of implementing them.

PRE-FLIGHT
1. Inspect the current branch and repository before creating files.
2. Read the existing root `AGENTS.md` and identify V1 instructions that conflict with V2.
3. Read:
   - `reports/V2-AUDIT.md`
   - `reports/V2-ARCHITECTURE-PROPOSAL.md`
   - `reports/V2-TEST-STRATEGY.md`
4. Reuse existing V2 architecture/product documents if they already exist. Do not create parallel documents for the same authority.
5. If the repository already contains a human-approved V2 decision that differs from this prompt, stop and report the conflict rather than silently rewriting architecture.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield fresh-install release for roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only; tested amd64 and arm64.
- Cloud-provider-neutral runtime; OCI A1 Flex is reference deployment only.
- Production ingress is Cloudflare-first; CrowdSec remains required.
- No V1 project-state, backup-format, migration, command-alias, runtime-layout, or compatibility requirement.
- Python 3.12 stdlib-first for structured logic; Bash only minimal bootstrap/host/container glue where materially simpler.
- No runtime third-party Python dependency without a concrete requirement.
- One public operator CLI: `vwctl`.
- One installed non-secret config authority: `/etc/vaultwarden-oci/config.toml`.
- One source-controlled version authority: `versions.toml`.
- Keep SOPS + Age: one structured encrypted secrets document, root-only operational Age identity, separate offline recovery material/recipient, volatile decrypted runtime secrets only. No project cryptography/KMS/secrets-provider framework.
- Keep rclone first-class: verified local recovery point -> copy/copyto-style publication -> remote verification -> success; pruning/deletion is separate. No destructive sync as normal publication and no storage-provider framework.
- Vaultwarden application mail uses direct authenticated SMTP.
- Project operational notifications use exactly one concrete HTTPS email API primary plus authenticated SMTP fallback only for clearly transient primary failures after a small bounded retry. No Postfix/local MTA requirement, durable queue, spool, dead-letter system, or notification-provider registry.
- Representative API auth/config/permanent failures (for example 400/401/403) and TLS certificate/hostname validation failures remain visible rather than being silently masked by SMTP.
- One encrypted V2 recovery format plus separate offline recovery material; no V1 archive reader or public db/full/emergency tier model.
- No dashboard/TUI in beta; operator surfaces are `vwctl status`, `vwctl doctor`, and logs.
- Beta edge supports one Cloudflare-proxied Caddy + Docker bridge/iptables packet path with validated Cloudflare ranges, bounded last-known-good state, and fail-closed behavior. No second firewall backend.
- Production versions are exact pins. `--use-latest` is development/testing-only and resolves once to exact recorded values for a run.
- No framework, plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, HA/Kubernetes/Swarm abstraction, or speculative extension architecture.

FILE-SURFACE RULE
- Prefer fewer cohesive first-party files when responsibilities remain clear.
- Before creating a file, ask whether an existing owner can absorb the behavior cleanly.
- Avoid one-function modules, one-action wrapper scripts, duplicate config fragments, empty placeholders, and future-facing files.
- File reduction is a preference, not a quota. Do not create giant mixed-responsibility files or weaken security/readability/testability just to reduce count.
- For architecture decisions, record the required decisions in the **fewest durable documents that remain clear**. Do not create one ADR file per bullet by default.

TEST RULE
- Tests protect security, availability, recoverability, and operator truthfulness.
- Three layers only: focused unit tests, small integration tests, disposable real-host release acceptance.
- No private source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, custom test runner/inventory, or coverage-percentage gate.
- This phase is documentation-only; do not modify the V1 functional test corpus.

GOAL
Replace V1-oriented agent instructions with a concise V2 repository map and record the minimum durable product/architecture decisions required before runtime coding.

IMPLEMENT
1. Rewrite root `AGENTS.md` as a concise map, not an architecture manual. It must:
   - identify V2 as greenfield;
   - state V1 is security/behavior reference only, not compatibility API;
   - state that the applicable standalone prompt from `reports/V2-CODEX-PROMPTS.md` controls phase execution;
   - point to the V2 product/decision documents;
   - summarize Python-first/Bash-minimal ownership;
   - warn against speculative abstractions, file proliferation, and implementing later phases early.
2. Keep/add one concise V2 product-boundary document if needed.
3. Record these durable decisions, grouping related decisions into the fewest clear decision/ADR documents rather than automatically creating eight separate files:
   - Python-first hybrid language boundary;
   - one TOML non-secret configuration authority and one versions manifest;
   - SOPS + Age structured secrets with operational and offline recovery identities;
   - Cloudflare-only beta ingress using one supported Docker iptables packet path;
   - operational notifications: one concrete HTTPS API primary + authenticated SMTP transient fallback, no Postfix/custom queue/provider framework;
   - rclone first-class with copy-style publication, remote verification, and separate pruning;
   - one V2 recovery format + offline recovery material + no V1 compatibility;
   - bounded three-layer testing.
4. For operational notifications, name the concrete HTTPS provider only if the human/repository already selected it. Otherwise record that provider choice as OPEN and explicitly block Phase 6 from inventing a generic provider abstraction. Do not guess.
5. Lock one canonical installed path for the structured SOPS-encrypted secrets document if the existing V2 decisions have not already done so. Do not create a second secret authority.
6. Do not add ADR tooling, generators, templates, or indexes unless an index materially improves navigation of multiple existing decision files.

ALLOWED SCOPE
- `AGENTS.md`
- V2 product/decision/ADR documentation
- links needed to connect those documents
- no production code, Compose, installer, or CI redesign

VALIDATION
- Markdown/link/basic repository checks only.
- Do not run the large V1 suite merely because docs changed unless repository enforcement makes it unavoidable; report what ran.

DEFINITION OF DONE
A new agent entering `v2` sees a short `AGENTS.md`, can locate the standalone phase prompts and durable decisions immediately, and is no longer instructed to recreate V1 architecture.

FINAL RESPONSE
- Summarize the contract/decision changes.
- List exact validation run and validation not run.
- List files created/deleted/changed and justify each new file.
- State whether decision documentation was consolidated rather than split unnecessarily.
- List unresolved product decisions (especially the concrete notification API provider) without inventing answers.
```

</details>

---

<details>
<summary><strong>Prompt 1 — Minimal Python foundation</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 1: minimal Python foundation

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work on the assigned branch/worktree based on current `v2`; do not merge your own PR unless instructed.
- Implement Phase 1 only; report later-phase ideas rather than implementing them.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md` and the V2 product/decision documents created in Phase 0.
2. Inspect existing files before choosing module/package layout. Reuse a clear owner rather than assuming new files are needed.
3. Verify Phase 0 is present: V2 `AGENTS.md`, product boundary, and required decisions. If not, stop and report the missing prerequisite.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS, amd64 + arm64, small-team/junior-admin product; cloud-neutral runtime, OCI reference only, Cloudflare-first/CrowdSec.
- No V1 state/backup/migration/command/layout compatibility.
- Python 3.12 stdlib-first; Bash minimal glue; no runtime third-party dependency without explicit need.
- One `vwctl`, one `/etc/vaultwarden-oci/config.toml`, one `versions.toml`, no dashboard/TUI.
- SOPS + Age remains the secret mechanism; rclone remains first-class with non-destructive copy-style publication + separate prune.
- Vaultwarden direct SMTP; project notifications later use one concrete HTTPS API + transient-only authenticated SMTP fallback; no Postfix/custom durable queue/provider registry.
- One V2 recovery format + offline recovery material; one Cloudflare/Docker-iptables beta ingress path; exact production pins; `--use-latest` dev/test only.
- No framework/plugin registry/ORM/daemon/database/event bus/workflow engine/generic transaction/distributed-lock/cloud/storage/notification/firewall abstraction.

FILE-SURFACE RULE
- Prefer fewer cohesive files; extend an existing owner where responsibility remains clear.
- No one-function modules, thin wrapper scripts, duplicate config fragments, or empty future modules.
- Do not game file count with giant catch-all modules.

TEST RULE
- Three layers only: focused unit, small integration, disposable-host acceptance.
- Add only tests needed for behavior changed now; prefer stable/public boundaries.
- No exact private source/order tests, private-function extraction, prose freezing, custom runner/inventory, or coverage gate.
- Prefer real temp files over large mocks; mock stable external boundaries only.

GOAL
Create the smallest practical Python 3.12 foundation for `vwctl` without Docker or root mutation.

IMPLEMENT
1. Minimal Python package/entrypoint for `vwctl`.
2. Implement only:
   - `vwctl --help`
   - `vwctl --version`
   - `vwctl config validate --file PATH` (or an equally small explicit form)
   - `vwctl versions`
   - `vwctl doctor [--json]` with host/architecture/config/version-file checks only.
3. Use stdlib `argparse`, `tomllib`, `json`, `pathlib`, `subprocess`, `fcntl` as appropriate.
4. Add one `versions.toml` containing exact values required by this phase only.
5. Normalize amd64/x86_64 and arm64/aarch64; unsupported architectures fail clearly.
6. Add one small subprocess helper accepting argv arrays and normalizing success/nonzero/not-found without shell interpolation.
7. Add one global mutation-lock primitive using `fcntl.flock`; do not attach it to read-only commands.
8. Define stable doctor check IDs and PASS/WARN/FAIL/SKIP. Human prose is not API-stable; JSON shape/check IDs are.
9. Do not pre-create modules for later phases.

TESTS REQUIRED
- valid/invalid config TOML
- valid/invalid versions manifest
- architecture normalization/unsupported architecture
- subprocess success/nonzero/not-found
- real-temp lock contention
- doctor JSON shape/check IDs implemented now

NON-GOALS
- Docker/Compose/root installer work
- SOPS/Age execution
- HTTP/email/rclone
- Cloudflare/CrowdSec/firewall
- backup/restore
- systemd/update implementation
- command/plugin registries

FINAL RESPONSE
- State behavior changed.
- State smallest sufficient validation and highest-value test layer.
- List exact validation run/not run.
- List new files and why each was necessary; note where existing owners were reused.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 2 — Bootstrap and installed layout</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 2: bootstrap and immutable installed layout

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 2 only; do not start runtime containers or later features.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 product/decision docs, and inspect the Phase 1 implementation.
2. Verify the Phase 1 `vwctl` foundation, config/versions parsing, architecture mapping, subprocess helper, doctor skeleton, and lock primitive exist. If prerequisites are missing, stop and report them.
3. Inspect existing installer/path owners before creating scripts/modules.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS, amd64 + arm64, small-team product; cloud-neutral, OCI reference only; Cloudflare-first/CrowdSec.
- No V1 compatibility surfaces.
- Python 3.12 stdlib structured logic; Bash only the smallest bootstrap/host glue; no runtime third-party dependency without explicit need.
- One `vwctl`, one `/etc/vaultwarden-oci/config.toml`, one `versions.toml`.
- SOPS + Age, rclone, direct Vaultwarden SMTP, later HTTPS-notification+SMTP fallback, one recovery format, one Docker-iptables edge model, exact production pins remain fixed boundaries.
- No dashboard/TUI, Postfix/custom queue, provider/plugin/framework architecture, migration engine, or speculative extension points.

FILE-SURFACE RULE
- Prefer one small bootstrap plus cohesive Python ownership over a script for every install sub-step.
- Reuse existing owners; avoid wrapper proliferation and duplicate path/config constants.
- File count is not a quota; keep security/ownership boundaries clear.

TEST RULE
- Focused unit + small integration + release acceptance only.
- Test path/permission/idempotency behavior, not source strings or private helper layout.

GOAL
Install the V2 application/config/state layout safely on a clean Ubuntu 24.04 host without starting Vaultwarden.

IMPLEMENT
1. Add one minimal root bootstrap; prefer thin Bash for pre-install checks that delegates structured work to Python.
2. Validate Ubuntu 24.04 and amd64/arm64.
3. Create only the installed paths needed now:
   - `/opt/vaultwarden-oci/releases/<release>/`
   - `/opt/vaultwarden-oci/current`
   - `/etc/vaultwarden-oci/config.toml`
   - the Phase 0 operational Age-key path/permissions
   - `/var/lib/vaultwarden-oci/` state directories actually required
   - `/run/vaultwarden-oci/` volatile state.
4. Install the current V2 Python application immutably under the release directory and expose the intended stable `vwctl` path.
5. Create only users/groups/directories with a demonstrated need.
6. Add only minimal systemd integration needed for installed application/lifecycle addressing; permanent timers belong to Phase 6.
7. Same-release/same-config re-run is safe; incompatible pre-existing ownership/state fails clearly.
8. Keep path constants/permission policy centralized rather than duplicated across shell/Python/templates.

VALIDATION
- focused unit tests for path/permission/rendering decisions
- small temp-root integration tests where practical
- disposable Ubuntu 24.04 install smoke check if the environment supports it

NON-GOALS
- starting Vaultwarden/Caddy
- runtime secret decryption
- Cloudflare/CrowdSec/firewall
- backup/rclone/restore
- operational notifications
- update engine
- V1 migration

FINAL RESPONSE
- State installed-layout behavior changed.
- List exact validation run/not run.
- List files created/deleted and justify each new file.
- Call out avoided wrapper/script proliferation.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 3 — Vaultwarden + Caddy core and secrets</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 3: core runtime, SOPS/Age, and Vaultwarden SMTP

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 3 only. Phase 4 owns edge enforcement/CrowdSec; Phase 5 recovery/rclone; Phase 6 project notifications/systemd automation.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 decisions, and inspect the installed-layout/foundation code.
2. Verify Phase 2 installed paths and canonical SOPS/Age paths are established. If not, stop and report missing prerequisites.
3. Inspect existing runtime/config/secrets owners before creating files.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; no runtime third-party dependency without explicit need.
- One `vwctl`, one TOML config, one versions manifest, no dashboard/TUI.
- SOPS + Age: one structured encrypted document, root-only operational identity, offline recovery material, volatile plaintext only; no secrets/KMS framework.
- rclone stays first-class later; non-destructive publication + separate prune.
- Vaultwarden application mail is direct authenticated SMTP. Project operational notification delivery is Phase 6; no Postfix/custom queue/provider registry.
- One V2 recovery format; one Cloudflare/Docker-iptables edge model; exact production pins; `--use-latest` dev/test only.
- No framework/plugin/provider/ORM/daemon/database/event-bus/workflow/generic transaction/distributed-lock abstractions.

FILE-SURFACE RULE
- Prefer one clear runtime owner and one clear secrets owner; do not create adapter/wrapper layers without a real security/ownership boundary.
- Keep Compose/template/config ownership obvious and avoid duplicate fragments.

TEST RULE
- Three layers only; tests protect behavior/security, not private source layout.
- Mock SOPS/Age only at stable external-command boundaries; use real temp files for project-owned materialization behavior where safe.

GOAL
Run Vaultwarden behind Caddy using the V2 config/secrets contract, with Vaultwarden direct SMTP, but without Phase 4 edge enforcement or Phase 6 project notification delivery.

IMPLEMENT
1. Minimal Compose/runtime definition with Vaultwarden + Caddy only.
2. Preserve useful hardening where compatible: explicit users, `cap_drop: ALL` plus only demonstrated additions, no-new-privileges, read-only roots/tmpfs where practical, bounded logs, health checks, reasonable PID/memory limits.
3. Implement SOPS + Age orchestration using the canonical Phase 0 paths:
   - validate one structured encrypted secrets document;
   - operational Age identity root-only;
   - offline recovery recipient/material contract;
   - decrypt only to root-owned volatile runtime files;
   - validate required secret keys before start;
   - never put plaintext secrets in TOML, argv, ordinary logs, or persistent temp files.
4. Implement `vwctl start|stop|restart|status|logs` for the two-container stack.
5. Configure Vaultwarden application mail with direct authenticated SMTP. Do not add Postfix.
6. Configure Caddy for the reverse-proxy/DNS-01 path needed by the Cloudflare-first design; Phase 4 owns host ingress enforcement/CrowdSec.
7. Add doctor checks only for behavior introduced now.

TESTS REQUIRED
- config-to-runtime rendering/validation
- SOPS/Age orchestration at stable subprocess boundary
- plaintext-secret non-leakage to persistent config/argv/loggable state
- representative lifecycle/status integration behavior

NON-GOALS
- project operational HTTPS API/SMTP fallback module
- Postfix/mail queue
- Cloudflare CIDR firewall enforcement/CrowdSec setup
- backup/restore/rclone
- update engine

FINAL RESPONSE
- State runtime/security behavior changed.
- List exact validation run/not run.
- List new files and justify ownership/security separation.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 4 — Cloudflare ingress and CrowdSec</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 4: Cloudflare ingress and CrowdSec

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 4 only; do not expand into recovery, notifications, updates, or generic firewall support.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, edge decision(s), and inspect the current Caddy/runtime implementation.
2. Verify Phase 3 Caddy/runtime is present. If not, stop and report the missing prerequisite.
3. Inspect current host/network helpers before creating new files.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral/OCI reference; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal host glue.
- One CLI/config/versions authority; SOPS/Age, rclone, direct Vaultwarden SMTP, later HTTPS+SMTP project notifications, one V2 recovery format remain fixed.
- Beta production ingress is exactly Cloudflare-proxied Caddy on one Docker bridge + iptables packet-filter path.
- Cloudflare ranges are strictly validated, cached last-known-good with bounded staleness, and fail closed when no safe policy exists.
- CrowdSec remains required, using upstream installation/integration where practical.
- No nftables/second firewall backend, generic firewall/provider abstraction, cloud security-group API integration, dashboard, or framework/plugin registry.

FILE-SURFACE RULE
- Prefer one cohesive edge-policy owner and minimal project-specific CrowdSec glue; do not make one script/module per iptables/CrowdSec action.
- Do not wrap upstream commands merely to create architectural symmetry.

TEST RULE
- Unit-test CIDR/policy/staleness decisions; small integration at external-command boundaries; real packet-path behavior belongs to disposable-host acceptance.
- No giant mocked firewall state machine or multi-backend matrix.

GOAL
Establish the one supported beta production edge: Cloudflare-proxied Caddy with fail-closed Docker iptables ingress and CrowdSec integration.

IMPLEMENT
1. Cloudflare IPv4/IPv6 retrieval, strict parsing/validation, last-known-good persistence, bounded staleness.
2. One small project-owned Docker iptables ingress chain/path allowing published Caddy HTTPS only from validated Cloudflare ranges for the supported path.
3. Fail closed if no safe current/last-known-good policy is available.
4. Do not claim ordinary UFW `INPUT` alone protects Docker-published Caddy ports; UFW may still protect normal host services such as SSH.
5. Use current upstream CrowdSec paths where possible for:
   - required host agent/acquisitions;
   - host firewall bouncer for host-visible traffic where appropriate;
   - Cloudflare edge/Worker bouncer for proxied web-client enforcement;
   - minimal project-owned config/credentials/status/test integration.
6. Add `vwctl`/doctor behavior needed for a junior admin to diagnose edge health.

TESTS REQUIRED
- CIDR parsing/validation/staleness
- deterministic policy/rule decisions for the one supported backend
- fail-closed decision behavior
- minimal external-command integration

NON-GOALS
- nftables or multiple firewall backends
- direct/non-Cloudflare beta ingress
- cloud firewall/security-group API
- wholesale V1 CrowdSec installer port
- backup/rclone/notifications/update work

FINAL RESPONSE
- State edge/security behavior changed.
- List exact validation run/not run.
- List files created/deleted and justify any new edge/CrowdSec file.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 5 — Backup, restore, rclone, and offline recovery</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 5: recovery and rclone

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 5 only; do not implement Phase 6 notification/systemd or Phase 7 update features except where an existing interface must be called.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, recovery/rclone/secrets decisions, and inspect current runtime/storage layout.
2. Verify Phase 3 runtime/secrets exists and Phase 4 changes do not alter recovery assumptions. If recovery prerequisites are missing, stop and report them.
3. Inspect existing data/manifest/subprocess owners before creating recovery files.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral/OCI reference; no V1 state/archive/backup/migration compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue.
- One `vwctl`, one TOML config, one versions manifest, no dashboard/TUI.
- SOPS + Age remains fixed; the operational Age private key is never included in ordinary recovery artifacts; offline recovery private material is not persisted on the server.
- Exactly one normal encrypted V2 recovery format; no db/full/emergency public tier system.
- rclone is first-class: create -> verify local -> copy/copyto-style publish -> verify remote -> success; pruning/deletion is separate; no destructive sync as normal publication and no storage-provider framework.
- Existing edge/mail/version boundaries remain unchanged; no Postfix/custom queue/provider registry.
- No generic transaction framework, workflow engine, backup plugin registry, compatibility layer, or background replication daemon.

FILE-SURFACE RULE
- Keep recovery ownership cohesive. Backup/restore/manifest/rclone logic may share a domain owner where clear; do not create one wrapper module per archive/manifest/rclone action.
- Clear security/promotion boundaries beat an artificial file-count target.

TEST RULE
- Recoverability justifies disproportionate focused testing, but still only unit + small integration + disposable-host acceptance.
- Prefer real temporary SQLite/files/archives; mock rclone/SOPS/Age only at stable external-command boundaries.
- No private-source assertions/custom runner/coverage quota/duplicate tests at every layer.

GOAL
Provide one safe encrypted V2 recovery format, first-class offsite rclone publication, and V2-only restore.

IMPLEMENT
1. `vwctl backup` creates one complete recovery point containing:
   - a consistent SQLite snapshot;
   - required persistent app/config material;
   - V2 format version, metadata, and checksums;
   - encryption before publication;
   - verification before success.
2. Exclude the operational Age private key. Offline recovery material must be testable without persisting its private recovery key on the server.
3. Local publication must be atomic enough that incomplete candidates are never reported valid.
4. Keep a small rclone wrapper for config/prerequisite diagnostics, connectivity, publication, remote listing/verification, download/staging, and explicit pruning.
5. Offsite success requires: local verification -> copy/copyto-style publication -> remote cohort verification.
6. Retention/deletion is separate; do not use `rclone sync` as normal publication.
7. `vwctl restore` supports V2 format only and must:
   - stage/decrypt/validate manifest/checksums before live mutation;
   - validate free space and target storage;
   - stop services only after preflight succeeds;
   - stage extracted state;
   - promote through a small explicit transaction boundary, not a generic framework;
   - restore permissions;
   - start only according to explicit policy/flag and health-gate success.
8. `status`/`doctor` exposes last verified local/offsite recovery state without secrets.

TESTS REQUIRED
- representative real-temp SQLite backup/restore
- corruption, wrong-key, incomplete-manifest, and preflight-failure behavior
- rclone argv/result classification
- prove normal publication does not request destructive sync semantics
- remote verification before success and explicit pruning decisions

NON-GOALS
- V1 backup reader/migration
- multiple public backup tiers
- storage-provider framework
- background replication daemon
- notification queue/system redesign

FINAL RESPONSE
- State recovery behavior/security properties changed.
- State smallest sufficient validation and highest-value test layer.
- List exact validation run/not run.
- List files created/deleted and justify each new recovery/test file.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 6 — Systemd automation and operational notifications</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 6: systemd automation and operational notifications

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 6 only; no generic provider framework, durable queue, or update engine.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, the notification decision/ADR, and inspect current runtime/status/doctor/systemd ownership.
2. The decision/ADR must name exactly one concrete HTTPS email API provider for beta. If provider choice remains OPEN, STOP and report the missing human/product decision. Do not guess and do not create a generic interface to postpone the decision.
3. Verify Phase 5 recovery commands/interfaces needed by backup timers exist.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral/OCI reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; no runtime third-party dependency without explicit need.
- One CLI/config/versions authority; SOPS + Age supplies secrets; rclone/recovery behavior remains unchanged.
- Vaultwarden application mail continues direct authenticated SMTP.
- Project operational notifications use exactly one concrete HTTPS API primary plus direct authenticated SMTP fallback only for clearly transient primary failures after a small bounded retry.
- Representative transient cases: network/DNS timeout, 429 after bounded retry, service-side 5xx, and only other provider-documented transient conditions.
- Representative 400/401/403, malformed config/request, permanent rejection, unsupported behavior, and TLS certificate/hostname validation failures remain visible and are not silently masked by SMTP.
- SMTP requires normal certificate/hostname validation with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
- API/SMTP secrets never appear in argv, normal logs, exception text, or debug transcripts.
- No Postfix/local MTA, spool, persistent retry scheduler/queue, dead-letter system, second API provider, or provider registry.
- systemd is the only scheduler/lifecycle manager.

FILE-SURFACE RULE
- Prefer one cohesive notification owner rather than one module per transport/status/retry condition.
- Keep permanent unit/timer count small; add only units with a concrete lifecycle/health/backup/maintenance role.
- Do not create a wrapper script per timer when `vwctl` can own the operation directly.

TEST RULE
- Test deterministic classification/fallback at stable HTTP/SMTP boundaries; do not build protocol simulators or fake MTAs unless demonstrably necessary.
- Three layers only; no source-string tests/custom runner/coverage gate.

GOAL
Add a small systemd automation surface and bounded operational notification delivery without Postfix or a custom durable queue.

IMPLEMENT
1. Add only permanent lifecycle/health/backup/maintenance units/timers actually needed.
2. Units execute the installed immutable release/current path and installed config, never an arbitrary git checkout.
3. Implement one small notification owner:
   - primary = selected HTTPS API;
   - fallback = direct authenticated SMTP.
4. HTTPS uses normal CA/hostname validation and a small bounded retry policy only.
5. Apply the failure-classification contract above; do not turn every non-2xx into SMTP fallback.
6. SMTP uses `ssl.create_default_context()` semantics with implicit TLS or required STARTTLS + authentication.
7. Return/persist only small secret-free state: transport attempted/used, outcome, stable category/reason, event/time identifier, safe diagnostic text.
8. If both transports fail, expose failure through `status`/`doctor`; do not persist full message bodies or secret-bearing provider responses.
9. Do not add a mail spool, retry scheduler, dead-letter queue, SMTP server/MTA, Postfix, provider registry, or second HTTPS provider.

TESTS REQUIRED
- API success/transient/auth/config/permanent/TLS classification
- SMTP fallback for representative transient cases
- no SMTP masking for representative configuration/security failures
- SMTP TLS/auth behavior at stable mocked boundary
- secret redaction/result shape
- minimal systemd unit target/rendering validation

NON-GOALS
- second notification API/provider abstraction
- durable notification queue
- Postfix/local MTA
- general job scheduler beyond systemd
- update engine

FINAL RESPONSE
- State automation/notification behavior changed.
- List exact validation run/not run.
- List files/units created and justify each; explicitly note avoided queue/provider/wrapper infrastructure.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 7 — Versions and explicit updates</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 7: reproducible versions and explicit updates

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 7 only; no unattended updater or generic component framework.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, current version/update decisions, and inspect `versions.toml`, runtime, recovery, and doctor owners.
2. Verify the recovery path required for safe update preflight exists. If not, stop and report the missing prerequisite.
3. Reuse the existing version owner; do not create one resolver module per component by default.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral/OCI reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue.
- One `vwctl`, one TOML config, one source-controlled `versions.toml`.
- Existing SOPS/Age, rclone/recovery, edge, and notification boundaries are fixed and must not be redesigned here.
- Production uses exact source-controlled pins.
- `--use-latest` is development/testing-only: resolve once at run start, convert to exact versions/digests where available, record the exact set, and pass only exact values downstream. Never create floating production state.
- No unattended updater daemon, provider/plugin registry, migration engine, workflow framework, or speculative component abstraction.

FILE-SURFACE RULE
- Centralize version resolution in one clear owner; avoid per-component resolver files unless logic is materially different and cohesive.
- Reuse existing update/runtime/recovery interfaces; do not add wrapper layers solely for symmetry.

TEST RULE
- Focus on version parsing/resolution/architecture mapping and update activation decisions.
- Mock the smallest stable remote-release boundary; avoid network-heavy permanent tests of third-party services.
- Three layers only; no source-string tests/custom runner/coverage gate.

GOAL
Provide reproducible pinned production versions, dev/test-only `--use-latest`, and an explicit safe operator-driven update path.

IMPLEMENT
1. `versions.toml` is the only source-controlled component-version authority.
2. Centralize amd64/arm64 artifact/image resolution.
3. Production install/update uses exact pins only.
4. `--use-latest` resolves once, freezes exact values/digests, records them for the run, and never scatters live-latest checks across installers/templates.
5. Implement `vwctl update check|apply` with a small safe flow:
   - validate current state;
   - create/verify recovery according to policy;
   - stage a new immutable application release;
   - pull/build exact pinned runtime components;
   - switch `current` symlink;
   - restart and health/doctor gate;
   - roll back application-release activation where safe before incompatible state changes.
6. Do not add unattended auto-update behavior.

TESTS REQUIRED
- versions parsing/resolution/architecture mapping
- `--use-latest` resolves once and freezes exact values
- representative update activation/failure/rollback decisions
- smallest stable remote-release lookup boundary

NON-GOALS
- unattended updates
- generic update/provider framework
- V1 migration machinery
- redesign of edge/recovery/notification systems

FINAL RESPONSE
- State version/update behavior changed.
- List exact validation run/not run.
- List files created/deleted and justify any new version/update file.
- Note avoided per-component resolver/file proliferation.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 8 — Beta docs, acceptance, and V2 cleanup</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 8: beta documentation, acceptance, and cleanup

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Phase 8 consolidates, validates, documents, and removes obsolete V1 surfaces. It must not invent new product features.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, current V2 product/decision docs, `reports/V2-ARCHITECTURE-PROPOSAL.md`, and `reports/V2-TEST-STRATEGY.md`.
2. Inspect the complete V2 implementation and current documentation before creating new docs/tests/scripts.
3. Identify obsolete V1 files still present on `v2` that are no longer build/runtime inputs.
4. If a required prior-phase feature is incomplete, report it rather than papering over it with documentation or compatibility code.

NON-NEGOTIABLE FINAL BETA CONTRACT
- Ubuntu 24.04 LTS, amd64 + arm64, cloud-neutral/OCI-reference, Cloudflare-first/CrowdSec, no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue.
- One `vwctl`, one TOML config, one versions manifest, no dashboard/TUI.
- SOPS + Age structured secrets with operational + offline recovery identities and volatile plaintext only.
- rclone first-class: local verify -> copy/copyto -> remote verify -> success; separate prune; no destructive sync default/provider framework.
- Vaultwarden direct SMTP.
- Project notifications: one selected HTTPS API primary + authenticated SMTP transient fallback; configuration/security/permanent errors visible; no Postfix/MTA/durable queue/provider registry.
- One Cloudflare/Docker-iptables ingress model with validated/bounded Cloudflare ranges + fail closed; CrowdSec integrated; no second firewall backend.
- One encrypted V2 recovery format + offline recovery material; no V1 reader/migration.
- Exact production pins; `--use-latest` dev/test only, resolved once to exact recorded values.
- No speculative framework/plugin/compatibility architecture.

FILE/DOC SURFACE RULE
- Prefer deletion/consolidation of obsolete V1 files, wrappers, aliases, placeholders, migration readers, dashboard files, Postfix queue tooling, and V1 test architecture once no longer required.
- Target operator/developer docs are `README.md`, INSTALL, OPERATIONS, SECURITY, RECOVERY, DEVELOPMENT, but this is not a quota. Combine responsibilities when clear; do not create a doc per module.
- Use `vwctl --help` as executable command reference. Do not create a giant generated command manual.
- Do not create new cleanup wrappers merely to preserve old filenames.

TEST RULE
- Permanent PR CI remains small: quality + unit + small integration.
- Full/destructive host acceptance is a release gate, not a giant stateful per-PR controller.
- No source-string/order tests, private-function extraction, prose freezing, custom runner/inventory, or coverage quota.

GOAL
Make V2 understandable, acceptance-tested on disposable Ubuntu 24.04, and free of obsolete V1 product surfaces on the V2 branch.

IMPLEMENT
1. Consolidate the smallest clear operator/developer documentation set covering:
   - install and prerequisites;
   - normal operations/status/doctor/logs;
   - security model including Cloudflare/CrowdSec and SOPS/Age;
   - one recovery/rclone workflow + offline recovery material;
   - HTTPS-primary/transient-SMTP-fallback notification behavior;
   - version/update model;
   - developer/test/release workflow.
2. Use `vwctl --help` for command reference and stable doctor IDs/JSON for diagnostic truth.
3. Create/retain a small disposable-host acceptance procedure for Ubuntu 24.04 amd64/arm64 where environments are available.
4. Acceptance covers at least:
   - clean install/layout;
   - start/status/doctor;
   - SOPS/Age materialization without leakage;
   - Cloudflare ingress/fail-closed + CrowdSec;
   - backup -> rclone publish -> remote verify -> download -> restore;
   - operational notification primary success + representative transient SMTP fallback;
   - systemd timers/units;
   - pinned update path.
5. Remove V1 production/docs/tests from `v2` when no longer required as build/runtime inputs; rely on `main`/git history for historical reference.
6. Review first-party file surface and consolidate/delete where natural without creating giant mixed-responsibility owners.

NON-GOALS
- V1 compatibility layer
- dashboard/TUI
- generated exhaustive command reference
- new provider abstractions
- custom test-runner framework
- new post-beta product capabilities

FINAL RESPONSE
- Summarize beta docs/acceptance/cleanup changes.
- List exact validation/acceptance run and not run.
- Report files deleted, consolidated, and newly created with rationale.
- Explicitly state whether first-party file surface was reduced where natural.
- Report post-beta ideas without implementing them.
```

</details>

---

<details>
<summary><strong>Corrective prompt — One observable V2 bug</strong></summary>

```text
TASK: VaultWarden-OCI V2 — corrective PR for one observable bug

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Fix one observable bug only. Do not turn the bugfix into a refactor, architecture rewrite, cleanup campaign, or later-phase implementation.
- Do not edit `reports/V2-CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md` and applicable V2 decisions.
2. Reproduce/locate the observable failure at a public/stable boundary where practical.
3. Identify the smallest existing owner before creating any file.
4. Inspect V1 only if it clarifies a required security property; do not port V1 architecture.

DURABLE V2 CONTRACT
- Preserve the existing greenfield Ubuntu 24.04 amd64/arm64, cloud-neutral, Cloudflare/CrowdSec, one-CLI/config/versions, SOPS/Age, rclone, notification, recovery, firewall, and exact-version boundaries.
- No V1 compatibility, dashboard, Postfix/custom queue, provider/plugin registry, framework, migration engine, or speculative extension point.
- Python 3.12 stdlib structured logic; Bash minimal glue.

FILE-SURFACE RULE
- Prefer changing the smallest existing owning file.
- A new file for a bugfix requires a clear ownership/security reason.
- Do not create a helper module for one function or a wrapper script to avoid editing the correct owner.
- Do not merge unrelated responsibilities merely to avoid a file.

TEST RULE
- Add one highest-value behavioral regression test only if existing tests do not already protect the bug.
- Prefer the stable/public boundary where the bug is observable.
- No source-string/order tests, private-function extraction, prose freezing, duplicated tests at several layers, custom runner/inventory, or coverage gate.

METHOD
1. State the observable bug and affected stable boundary.
2. Identify the root cause and smallest owner.
3. Make the smallest coherent fix.
4. Do not create an abstraction merely because a few lines now look similar.
5. Add one regression test only if there is a real coverage gap.
6. Run the smallest validation sufficient for confidence.
7. If the fix requires changing a durable V2 product/architecture boundary, STOP and report the conflict rather than silently widening the design.

FINAL RESPONSE
- State observable bug and root cause.
- State smallest owner changed.
- List exact validation run/not run.
- State whether a file was added; if yes, justify why an existing owner was insufficient.
- Report out-of-scope follow-ups without implementing them.
```

</details>

---

## Human review checklist

- Correct standalone prompt/phase was used.
- Agent did not edit the authoritative prompt file.
- Required previous phase was present before implementation started.
- Work stayed inside phase/bug scope.
- V1 implementation shape was not imported without necessity.
- No speculative framework/provider/compatibility/queue layer appeared.
- New files have clear ownership value; thin wrappers and one-function modules were avoided.
- File-count preference was not gamed with giant mixed-responsibility files.
- Secrets never moved into ordinary config/argv/logs.
- rclone publication remains non-destructive and pruning separate.
- Notification fallback follows the transient/security classification contract.
- Tests protect observable risk rather than source layout.
- PR is small enough to understand/review; later-phase ideas were reported, not implemented.