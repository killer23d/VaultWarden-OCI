# VaultWarden-OCI V2 — Authoritative Standalone Codex Prompts

Date: 2026-08-19
Status: authoritative V2 agent execution contract.

## How to use this file

Each prompt below is deliberately **standalone**. Expand one section, copy the entire fenced block, and paste it into a fresh Codex session.

- Use one prompt per Codex session.
- Run phases in order unless a human explicitly changes the plan.
- Phase work normally starts from current `v2` and lands back into `v2` through review.
- Do not paste a shared preamble from elsewhere; every block already contains the durable V2 contract it needs.

### Authority

For an implementation session:

1. explicit human instructions supplied with that task;
2. the complete standalone prompt pasted from this file;
3. root `AGENTS.md` and V2 decisions/architecture as repository context.

If supporting documentation conflicts with the pasted prompt, follow the pasted prompt and report the stale document.

**Ordinary phase/corrective agents must not edit `reports/CODEX-PROMPTS.md`.** Changing the agent contract is a separate human-authorized architecture/documentation task.

Supporting reports:

- `reports/V2-AUDIT.md` — evidence/reasons for the greenfield redesign;
- `reports/V2-ARCHITECTURE-PROPOSAL.md` — target architecture, documentation model, and phase sequence;
- `reports/TEST-STRATEGY.md` — testing rationale and guardrails;
- `reports/REVIEW-PROMPTS.md` — standalone prompts for a separate PR-review agent; not an implementation authority.

A reviewer prompt is a mirror, not a second specification. If a future reviewer prompt contradicts this file, this file wins and the review prompt should be corrected.

---

<details>
<summary><strong>Prompt 0 — Contract reset and durable decisions</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 0: contract reset and durable decisions

AUTHORITY / WORKFLOW
- This pasted prompt is authoritative for this session unless the human explicitly overrides it.
- Work on the assigned branch/worktree based on current `v2`.
- Do not merge your own PR unless explicitly instructed.
- Implement Phase 0 only. No production runtime code.
- Do not edit `reports/CODEX-PROMPTS.md`.
- Report useful out-of-scope ideas instead of implementing them.

PRE-FLIGHT
1. Inspect the current branch/repository before creating files.
2. Read existing root `AGENTS.md` and identify V1 instructions that conflict with V2.
3. Read `reports/V2-AUDIT.md`, `reports/V2-ARCHITECTURE-PROPOSAL.md`, and `reports/TEST-STRATEGY.md`.
4. Reuse existing V2 product/architecture docs; do not create parallel authorities.
5. If a human-approved V2 decision conflicts with this prompt, stop and report it rather than silently changing architecture.

NON-NEGOTIABLE V2 CONTRACT
- Greenfield fresh install for roughly 10 users and a junior administrator.
- Ubuntu 24.04 LTS Noble only; tested amd64 and arm64.
- Runtime cloud-provider neutral; OCI A1 Flex reference only.
- Cloudflare-first production ingress; CrowdSec retained for proxied web-client remediation through Cloudflare.
- No V1 project-state, backup-format, migration, command-alias, runtime-layout, or compatibility requirement.
- Python 3.12 stdlib-first for structured logic; Bash only minimal bootstrap/host/container glue where materially simpler.
- No runtime third-party Python dependency without a concrete requirement.
- One public operator CLI: `vwctl`.
- One installed operator-editable non-secret config authority: `/etc/vaultwarden-oci/config.toml`.
- One source-controlled version authority: `versions.toml`.
- SOPS + Age: one structured encrypted secrets document, root-only operational Age identity, separate offline recovery material/recipient, volatile decrypted runtime secrets only. No project cryptography/KMS/secrets-provider framework.
- rclone first-class: verified local recovery point -> copy/copyto-style publication -> remote verification -> success; pruning/deletion separate. No destructive sync as normal publication and no storage-provider framework.
- Vaultwarden application mail uses direct authenticated SMTP.
- Operational notifications support canonical built-ins `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`; `cyberpanel` is only an alias to `cyberpersons`.
- Provider transport metadata lives in one source-controlled non-secret `email-providers.toml` shipped with the immutable release. It is not operator-editable config and never contains credentials.
- Provider-template canonical message fields are exactly: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- Routine provider endpoint/auth/request/success/retry changes must be catalog edits plus focused tests/docs rather than notification-library rewrites.
- Operator config may select a built-in/alias and declared non-secret options; it may not supply arbitrary provider endpoints, auth modes, headers, payload templates, success rules, or retry rules.
- After a small bounded API retry, authenticated SMTP fallback is used only for clearly transient failures supported by network semantics or current provider documentation. There is no blanket "all 5xx are transient" rule.
- No Postfix/local MTA, durable queue, spool, dead-letter system, dynamic provider loading, arbitrary HTTP scripting, Python entry points, or provider SDK.
- CyberPersons baseline: 429 and 503 are currently transient/retryable; 500 `send_failed` is not transient by status alone and must not be silently SMTP-masked.
- One encrypted V2 recovery format plus separate offline recovery material; no V1 archive reader or public db/full/emergency tier model.
- No dashboard/TUI in beta; operator surfaces are `vwctl status`, `vwctl doctor`, and logs.
- Beta origin security uses one Cloudflare-proxied Caddy + Docker bridge/iptables path with validated Cloudflare ranges, bounded last-known-good state, and fail-closed behavior. No second firewall backend.
- CrowdSec beta remediation is through one current supported Cloudflare remediation component for proxied web decisions. Do not make a CrowdSec host firewall bouncer a beta requirement.
- Production versions are exact pins. `--use-latest` is development/testing-only and resolves once to exact recorded values for a run.
- No framework, dynamic plugin/provider registry, ORM, daemon, database, event bus, workflow engine, generic transaction framework, distributed lock, HA/Kubernetes/Swarm abstraction, or speculative extension architecture.

FILE-SURFACE RULE
- Prefer fewer cohesive first-party files when responsibilities remain clear.
- Before creating a file, ask whether an existing owner can absorb the behavior cleanly.
- Avoid one-function modules, one-action wrapper scripts, duplicate config fragments, empty placeholders, and future-facing files.
- `email-providers.toml` is a deliberate single-file resource because it replaces provider constants/templates that would otherwise be repeated in Python or split across provider modules.
- File reduction is a preference, not a quota. Do not create giant mixed-responsibility files or weaken security/readability/testability just to reduce count.
- Record architecture decisions in the fewest durable documents that remain clear; do not create one ADR file per bullet by default.

TEST RULE
- Tests protect security, availability, recoverability, and operator truthfulness.
- Three layers only: focused unit, small integration, disposable real-host release acceptance.
- No private source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, custom runner/inventory, or coverage-percentage gate.
- This phase is documentation-only; do not modify the V1 functional test corpus.

GOAL
Replace V1-oriented agent instructions with a concise V2 repository map and record the minimum durable decisions required before runtime coding.

IMPLEMENT
1. Rewrite root `AGENTS.md` as a concise map, not an architecture manual. It must identify V2 as greenfield, state V1 is security/behavior reference only, point to the standalone prompts/decision docs, summarize Python-first/Bash-minimal ownership, and warn against speculative abstractions/file proliferation/later-phase work.
2. Keep/add one concise V2 product-boundary document if needed.
3. Record these durable decisions, grouping related items into the fewest clear decision/ADR documents:
   - Python-first hybrid boundary;
   - one operator TOML non-secret config authority + one versions manifest;
   - SOPS + Age operational/offline recovery identities and one canonical encrypted-secret path;
   - Cloudflare-only beta origin ingress on one Docker iptables packet path;
   - CrowdSec web remediation through Cloudflare only in beta; no host firewall bouncer requirement;
   - operational notifications: six canonical built-ins, `cyberpanel` alias, common `email_api_token`, static `email-providers.toml`, exact canonical message fields, transient-only SMTP fallback, no Postfix/custom queue/dynamic plugins;
   - CyberPersons `429`/`503` transient baseline and `500 send_failed` non-transient-by-status baseline, subject to Phase 6 re-verification;
   - future provider/settings changes update the closed catalog first and Python only for a genuinely new transport capability;
   - rclone copy-style publication + remote verification + separate pruning;
   - one V2 recovery format + offline recovery material + no V1 compatibility;
   - bounded three-layer testing.
4. Do not create runtime `email-providers.toml` in this documentation-only phase; Phase 6 implements it.
5. Do not add ADR tooling/generators/frameworks.

ALLOWED SCOPE
- `AGENTS.md`
- V2 product/decision/ADR documentation
- links needed to connect those documents
- no production code, Compose, installer, provider-catalog implementation, or CI redesign

VALIDATION
- Markdown/link/basic repository checks only.
- Do not run the large V1 suite merely because docs changed unless repository enforcement makes it unavoidable; report what ran.

DEFINITION OF DONE
A new agent entering `v2` sees a short `AGENTS.md`, can locate the standalone prompts/durable decisions immediately, and is no longer instructed to recreate V1 architecture.

FINAL RESPONSE
- Summarize contract/decision changes.
- List exact validation run and validation not run.
- List files created/deleted/changed and justify each new file.
- State whether decision documentation was consolidated rather than split unnecessarily.
- List unresolved product decisions without inventing answers.
```

</details>

---

<details>
<summary><strong>Prompt 1 — Minimal Python foundation</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 1: minimal Python foundation

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 1 only; report later-phase ideas rather than implementing them.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md` and the Phase 0 product/decision documents.
2. Verify Phase 0 is present: V2 `AGENTS.md`, product boundary, and durable decisions. If not, stop and report the missing prerequisite.
3. Inspect existing files before choosing package/module layout; reuse a clear owner where possible.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64, small-team/junior-admin, cloud-neutral/OCI-reference, Cloudflare-first/CrowdSec, no V1 compatibility.
- Python 3.12 stdlib-first; Bash minimal glue; no runtime third-party dependency without explicit need.
- One `vwctl`, one `/etc/vaultwarden-oci/config.toml`, one `versions.toml`, no dashboard/TUI.
- SOPS + Age remains the secret mechanism; rclone remains first-class with verified copy-style publication + separate prune.
- Vaultwarden direct SMTP. Operational notifications later use one static `email-providers.toml` with six canonical built-ins including CyberPersons, exact canonical message fields, and transient-only authenticated SMTP fallback. No Postfix/custom durable queue/dynamic provider framework.
- CrowdSec beta remediation is through Cloudflare for proxied web clients; no host firewall bouncer requirement.
- One V2 recovery format + offline recovery material; one Cloudflare/Docker-iptables beta origin path; exact production pins; `--use-latest` dev/test only.
- No framework/plugin registry/ORM/daemon/database/event bus/workflow engine/generic transaction/distributed-lock/cloud/storage/notification/firewall abstraction.

FILE / TEST RULE
- Prefer fewer cohesive files; no one-function modules, thin wrapper scripts, duplicate fragments, or empty future modules; do not game file count with giant catch-alls.
- Three test layers only; add only tests for changed behavior at stable/public boundaries; no source-string/order tests, private-function extraction, custom runner/inventory, or coverage gate.

GOAL
Create the smallest practical Python 3.12 foundation for `vwctl` without Docker or root mutation.

IMPLEMENT
1. Minimal Python package/entrypoint for `vwctl`.
2. Implement only `vwctl --help`, `--version`, `config validate --file PATH` (or equally small explicit form), `versions`, and `doctor [--json]` with host/architecture/config/version-file checks only.
3. Use stdlib `argparse`, `tomllib`, `json`, `pathlib`, `subprocess`, `fcntl` as appropriate.
4. Add one `versions.toml` containing exact values required now.
5. Normalize amd64/x86_64 and arm64/aarch64; unsupported architectures fail clearly.
6. Add one small subprocess helper accepting argv arrays and normalizing success/nonzero/not-found without shell interpolation.
7. Add one global mutation-lock primitive using `fcntl.flock`; do not attach it to read-only commands.
8. Define stable doctor check IDs and PASS/WARN/FAIL/SKIP; human prose is not API-stable.
9. Do not pre-create notification/provider-catalog or other later-phase modules.

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
- HTTP/email/provider catalog/rclone
- Cloudflare/CrowdSec/firewall implementation
- backup/restore
- systemd/update implementation
- command/plugin registries

FINAL RESPONSE
- State behavior changed, smallest sufficient validation/highest-value layer, exact validation run/not run, new files and why each was necessary, and out-of-scope follow-ups.
```

</details>

---

<details>
<summary><strong>Prompt 2 — Bootstrap and immutable installed layout</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 2: bootstrap and immutable installed layout

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless the human explicitly overrides it.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 2 only; do not start runtime containers or later features.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 decisions, and the Phase 1 implementation.
2. Verify Phase 1 is present: `vwctl`, config/versions parsing, architecture mapping, subprocess helper, doctor skeleton, and global lock primitive. If not, stop and report the missing prerequisite.
3. Inspect installer/path owners before creating scripts/modules.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 LTS amd64/arm64; cloud-neutral/OCI-reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash only the smallest bootstrap/host glue.
- One `vwctl`, one operator TOML config, one versions manifest.
- SOPS + Age, rclone, direct Vaultwarden SMTP, later static provider catalog + transient SMTP fallback, one recovery format, one Docker-iptables origin model, and exact production pins remain fixed boundaries.
- CrowdSec beta remediation is through Cloudflare only; no host firewall bouncer requirement.
- No Postfix/custom queue/dynamic provider framework/dashboard/migration engine/speculative extension architecture.

FILE / TEST RULE
- Prefer one small bootstrap plus cohesive Python ownership over a script per install sub-step; centralize path/permission constants.
- Focused unit + small integration + release acceptance only; test path/permission/idempotency behavior, not private source layout.

GOAL
Install the V2 application/config/state layout safely on a clean Ubuntu 24.04 host without starting Vaultwarden.

IMPLEMENT
1. Add one minimal root bootstrap; prefer thin Bash for pre-install checks delegating structured work to Python.
2. Validate Ubuntu 24.04 and amd64/arm64.
3. Create only paths needed now: `/opt/vaultwarden-oci/releases/<release>/`, `/opt/vaultwarden-oci/current`, `/etc/vaultwarden-oci/config.toml`, Phase 0 Age-key/secrets paths, required `/var/lib/vaultwarden-oci/` state, and `/run/vaultwarden-oci/` volatile state.
4. Install the current Python app immutably and expose the stable `vwctl` path. The immutable release layout must be able to carry source-controlled resources later, including `email-providers.toml`, without making them operator config.
5. Create only users/groups/directories with demonstrated need.
6. Add only minimal systemd integration needed for installed application/lifecycle addressing; permanent timers belong to Phase 6.
7. Same-release/same-config re-run is safe; incompatible ownership/state fails clearly.

VALIDATION
- focused path/permission/rendering tests
- small temp-root integration where practical
- disposable Ubuntu 24.04 install smoke check if supported by the environment

NON-GOALS
- starting Vaultwarden/Caddy
- runtime secret decryption
- edge/CrowdSec implementation
- backup/rclone/restore
- operational notifications/provider catalog
- update engine/V1 migration

FINAL RESPONSE
- State installed-layout behavior, exact validation run/not run, files created/deleted with rationale, avoided wrapper proliferation, and later-phase follow-ups.
```

</details>

---

<details>
<summary><strong>Prompt 3 — Vaultwarden + Caddy core, SOPS/Age, and Vaultwarden SMTP</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 3: core runtime and secrets

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless the human explicitly overrides it.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 3 only. Phase 4 owns edge/CrowdSec, Phase 5 recovery/rclone, Phase 6 project notifications/systemd automation.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 decisions, and the Phase 2 installed-layout/foundation code.
2. Verify Phase 2 is present: immutable installed application layout, config path, Age/secrets paths, and stable `vwctl` installation. If not, stop and report the missing prerequisite.
3. Inspect runtime/config/secrets owners before creating files.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 amd64/arm64, cloud-neutral/OCI-reference, Cloudflare-first/CrowdSec, no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; one CLI/operator-config/versions authority; no dashboard/TUI.
- SOPS + Age: one structured encrypted document, root-only operational identity, offline recovery material, volatile plaintext only; no secrets/KMS framework.
- rclone later remains first-class with non-destructive publication + separate prune.
- Vaultwarden application mail is direct authenticated SMTP. Project notification delivery/provider catalog is Phase 6; no Postfix/custom queue/dynamic provider registry.
- CrowdSec beta remediation is Phase 4 and uses Cloudflare for proxied web decisions, not a host firewall bouncer.
- One V2 recovery format; one Cloudflare/Docker-iptables origin path; exact production pins; `--use-latest` dev/test only.

FILE / TEST RULE
- Prefer one clear runtime owner and one clear secrets owner; avoid adapter/wrapper layers and duplicate Compose/config fragments.
- Three test layers only; mock SOPS/Age at stable external-command boundaries and test project-owned materialization/security behavior.

GOAL
Run Vaultwarden behind Caddy using V2 config/secrets, with Vaultwarden direct SMTP, without Phase 4 edge enforcement or Phase 6 project notification delivery.

IMPLEMENT
1. Minimal Compose/runtime definition containing Vaultwarden + Caddy only.
2. Preserve useful hardening where compatible: explicit users, `cap_drop: ALL` plus only demonstrated additions, no-new-privileges, read-only roots/tmpfs where practical, bounded logs, health checks, reasonable PID/memory limits.
3. Implement SOPS + Age orchestration using canonical Phase 0 paths: validate one encrypted document, root-only operational identity, offline recovery recipient/material, volatile-only decryption, required-key validation, no plaintext in TOML/argv/logs/persistent temp files.
4. Implement `vwctl start|stop|restart|status|logs`.
5. Configure Vaultwarden direct authenticated SMTP. Do not add Postfix.
6. Configure Caddy for the reverse-proxy/DNS-01 path required by the Cloudflare-first design; Phase 4 owns host ingress enforcement/CrowdSec.
7. Add doctor checks only for behavior introduced now.

TESTS REQUIRED
- config-to-runtime rendering/validation
- SOPS/Age orchestration at stable subprocess boundary
- plaintext-secret non-leakage
- representative lifecycle/status integration behavior

NON-GOALS
- project operational HTTP API/SMTP fallback or provider catalog
- Postfix/mail queue
- Cloudflare CIDR enforcement/CrowdSec setup
- backup/restore/rclone/update

FINAL RESPONSE
- State runtime/security behavior, exact validation run/not run, new files and ownership/security rationale, and later-phase follow-ups.
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
- Implement Phase 4 only; no recovery, notifications, updates, or generic firewall expansion.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 edge decisions, and the current Caddy/runtime implementation.
2. Verify Phase 3 is present: Vaultwarden+Caddy runtime, V2 secrets materialization, lifecycle commands, and direct Vaultwarden SMTP. If not, stop and report the missing prerequisite.
3. Inspect current host/network helpers before creating files.
4. Verify current upstream CrowdSec documentation for the chosen Cloudflare remediation component before implementation; do not blindly port V1 installer behavior.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 amd64/arm64; cloud-neutral/OCI-reference; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal host glue; one CLI/operator-config/versions authority.
- SOPS/Age, rclone, direct Vaultwarden SMTP, later static provider catalog + transient SMTP fallback, and one recovery format remain fixed.
- Beta origin ingress is exactly Cloudflare-proxied Caddy on one Docker bridge + iptables packet-filter path.
- Cloudflare ranges are strictly validated, cached last-known-good with bounded staleness, and fail closed when no safe policy exists.
- CrowdSec beta has one remediation scope for proxied web clients: Cloudflare. Do not make a host firewall bouncer a beta requirement.
- The project-owned iptables origin allowlist is separate from CrowdSec decisions: it allows Caddy ingress only from validated Cloudflare ranges.
- SSH/other host-visible services remain protected by documented provider firewall/security-group and host firewall policy, not by a new CrowdSec firewall-bouncer requirement.
- No nftables/second firewall backend, generic firewall/provider abstraction, cloud security-group API, dashboard, or framework/plugin registry.

FILE / TEST RULE
- Prefer one cohesive edge-policy owner plus minimal project-specific CrowdSec glue; do not wrap every upstream action.
- Unit-test CIDR/policy/staleness, small integration at command boundaries, real packet/remediation path in disposable-host acceptance; no multi-backend or multi-bouncer matrix.

GOAL
Establish the one supported beta edge: fail-closed Cloudflare-only origin ingress plus CrowdSec remediation of proxied web-client decisions at Cloudflare.

IMPLEMENT
1. Cloudflare IPv4/IPv6 retrieval, strict validation, last-known-good persistence, bounded staleness.
2. One small project-owned Docker iptables ingress path allowing published Caddy HTTPS only from validated Cloudflare ranges.
3. Fail closed if no safe current/last-known-good policy exists.
4. Do not claim ordinary UFW `INPUT` alone protects Docker-published Caddy ports.
5. Install/configure the CrowdSec Security Engine using current upstream guidance and only the product-specific web acquisitions/config required.
6. Configure one current supported CrowdSec Cloudflare remediation integration for the proxied web decision flow.
7. Do not install/configure a CrowdSec host firewall bouncer as part of beta.
8. Add `vwctl`/doctor behavior needed to diagnose Cloudflare CIDR policy, CrowdSec engine health, and Cloudflare remediation health without creating another dashboard.

TESTS REQUIRED
- CIDR parsing/validation/staleness
- deterministic policy/rule decisions for one supported iptables path
- fail-closed behavior
- minimal external-command integration
- Cloudflare remediation configuration/health at the project-owned boundary
- disposable-host acceptance for real origin packet path and representative CrowdSec->Cloudflare remediation when environment supports it

NON-GOALS
- CrowdSec host firewall bouncer
- nftables/multiple firewall backends
- direct/non-Cloudflare beta ingress
- cloud firewall API
- wholesale V1 CrowdSec installer port
- backup/rclone/notifications/update

FINAL RESPONSE
- State edge/security behavior, exact validation run/not run, files created/deleted with rationale, exact CrowdSec remediation component/docs used, and later-phase follow-ups.
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
- Implement Phase 5 only; do not implement Phase 6 notifications/systemd or Phase 7 updates except by calling existing interfaces.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, recovery/rclone/secrets decisions, and current runtime/storage layout.
2. Verify **Phase 4 is present**, including the Phase 3 runtime/secrets it depends on: Cloudflare origin policy, CrowdSec Cloudflare remediation integration, and relevant doctor/status ownership must already exist. If Phase 4 is missing, stop and report the prerequisite instead of implementing it here.
3. Inspect existing data/manifest/subprocess owners before creating recovery files.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 amd64/arm64; cloud-neutral/OCI-reference; no V1 state/archive/backup/migration compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; one CLI/operator-TOML/versions authority; no dashboard/TUI.
- SOPS + Age fixed; operational Age private key never in ordinary recovery artifacts; offline private recovery material not persisted on server.
- Exactly one normal encrypted V2 recovery format; no db/full/emergency public tiers.
- rclone first-class: create -> verify local -> copy/copyto-style publish -> verify remote -> success; pruning/deletion separate; no destructive sync as normal publication/provider framework.
- Existing edge/mail/version boundaries unchanged; operational notifications later use static source-controlled provider metadata, not a dynamic plugin framework.
- No generic transaction/workflow/backup-plugin framework or background replication daemon.

FILE / TEST RULE
- Keep recovery ownership cohesive; avoid one wrapper module per archive/manifest/rclone action; clear security/promotion boundaries beat an artificial file target.
- Recoverability gets disproportionate focused testing but still only unit + small integration + disposable-host acceptance; prefer real temp SQLite/files/archives.

GOAL
Provide one safe encrypted V2 recovery format, first-class offsite rclone publication, and V2-only restore.

IMPLEMENT
1. `vwctl backup` creates one complete recovery point: consistent SQLite snapshot, required persistent app/config material, V2 format metadata/checksums, encryption before publication, verification before success.
2. Exclude operational Age private key; offline recovery material must be testable without persisting its private key on server.
3. Local publication must ensure incomplete candidates are never reported valid.
4. Small rclone owner for config/prerequisite diagnostics, connectivity, publication, remote listing/verification, download/staging, explicit pruning.
5. Offsite success requires local verification -> copy/copyto-style publication -> remote verification.
6. Retention/deletion separate; no `rclone sync` as normal publication.
7. `vwctl restore` V2-only: stage/decrypt/validate manifest/checksums before live mutation, validate free space/target, stop services only after preflight, stage, promote through a small explicit transaction boundary, restore permissions, health-gate any requested start.
8. `status`/`doctor` exposes last verified local/offsite recovery state without secrets.

TESTS REQUIRED
- representative real-temp SQLite backup/restore
- corruption/wrong-key/incomplete-manifest/preflight failure
- rclone argv/result classification
- prove no destructive sync in normal publication
- remote verification before success + explicit pruning decisions

NON-GOALS
- V1 reader/migration
- multiple public backup tiers
- storage-provider framework/background replication
- notification/system redesign
- Phase 4 edge/CrowdSec implementation

FINAL RESPONSE
- State recovery behavior/security properties, smallest sufficient/highest-value validation, exact validation run/not run, files created/deleted with rationale, and later-phase follow-ups.
```

</details>

---

<details>
<summary><strong>Prompt 6 — Systemd automation and operational notifications</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 6: systemd automation and catalog-driven operational notifications

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 6 only; no durable queue, dynamic provider framework, or update engine.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, notification decision(s), architecture/test reports, current config/secrets/status/doctor/systemd ownership, and V1 `docs/EMAIL.md` + `lib/email.sh` only as behavioral reference.
2. Verify **Phase 5 is present**: V2 backup/restore and rclone interfaces required by timers must already exist. If not, stop and report the missing prerequisite rather than implementing recovery here.
3. Inspect existing owners before creating notification/systemd files.
4. Verify current official API documentation for every built-in provider before implementation: endpoint/region, authentication, request shape, successful-response semantics, rate-limit/retry behavior, redirects, and documented permanent/transient errors. Do not blindly copy V1 details if upstream changed.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 amd64/arm64; cloud-neutral/OCI-reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; one CLI/operator-config/versions authority; SOPS + Age supplies secrets; rclone/recovery unchanged.
- Vaultwarden application mail continues direct authenticated SMTP.
- Canonical operational HTTPS provider IDs are exactly: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`.
- Accept `cyberpanel` only as an alias to canonical `cyberpersons`; one catalog definition.
- Operator selects provider/alias in `/etc/vaultwarden-oci/config.toml`; provider transport mechanics are release data, not arbitrary operator config.
- Use common SOPS secret `email_api_token` unless current official provider requirements force a documented exception. Mailgun may use declared non-secret region/domain settings.
- Provider definitions live in one source-controlled non-secret `email-providers.toml`, shipped inside the immutable application release.
- Routine endpoint/auth/request/success/retry/settings changes are catalog edits plus focused tests/docs, not library rewrites.
- Unknown provider IDs/aliases fail validation.
- After small bounded retry, direct authenticated SMTP fallback is used only for clearly transient failures documented by the provider or caused by network/DNS/connectivity timeout. There is no blanket all-5xx fallback rule.
- Representative auth/config/permanent/ambiguous failures and TLS certificate/hostname validation failure remain visible and are not silently masked by SMTP.
- SMTP requires normal certificate/hostname verification with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
- If SMTP fallback is not configured, `doctor` reports fallback unavailable; do not pretend redundancy exists.
- API/SMTP secrets never appear in provider catalog, argv, normal logs, exception text, or debug transcripts.
- No Postfix/local MTA, spool, persistent retry scheduler/queue, dead-letter system, arbitrary provider code, Python entry points, dynamic imports, provider package/SDK, or general HTTP workflow engine.
- systemd is the only scheduler/lifecycle manager.

CANONICAL MESSAGE CONTEXT
The provider-template fields are **exactly**:
- `from_email`
- `from_name`
- `from_header`
- `to_email`
- `subject`
- `text`

`from_header` is safely derived from `from_name` + `from_email`. Provider templates map these canonical values to external provider field names. Do not add a competing canonical `to` name or other synonyms.

CYBERPANEL EMAIL / CYBERPERSONS BASELINE
Official CyberPanel Email documentation was verified on 2026-08-19; re-verify it at implementation time:
- canonical V2 ID: `cyberpersons`; alias: `cyberpanel`;
- endpoint: `POST https://platform.cyberpersons.com/email/v1/send`;
- recommended authentication: `Authorization: Bearer <API key>`;
- API key must permit sending (`can_send`); provider may restrict key by domain/IP;
- V2 plain-text request maps canonical values to provider `from`, `to`, `subject`, `text`;
- accepted send: HTTP `202` and JSON `success: true`;
- HTTP `429 rate_limit_exceeded` is transient/retryable after bounded retry;
- HTTP `503 service_unavailable` is explicitly temporary and transient/retryable;
- HTTP `500 send_failed` is **not transient by status alone**. It can represent recipient rejection, invalid recipient, or blocklisted-domain/reputation failures. Do not retry/fallback merely because it is 500;
- HTTP `400` and documented `403` cases are visible configuration/permanent failures;
- CyberPanel SMTP fallback, if selected: `mail.cyberpersons.com:587`, required STARTTLS, separate authenticated SMTP credentials.

The current docs say a 429 response includes JSON `retry_after`, but the reviewed docs do not define sufficient delay semantics/units to require parsing it. A common fixed small bounded retry schedule is valid. Only consume a provider body retry delay if current official docs clearly specify a numeric delay and unit and the closed catalog declares that narrow capability.

EMAIL PROVIDER CATALOG REQUIREMENT
Create exactly one source-controlled `email-providers.toml` for all six canonical built-ins. Keep the schema closed to capabilities actually required.

Allowed catalog concepts:
- canonical ID, aliases, display name;
- final HTTPS POST endpoint or narrowly constrained endpoint template;
- finite auth mode needed by current built-ins (for example bearer, fixed token header, or basic auth using the secret token) plus fixed non-secret auth metadata;
- request encoding: JSON or form;
- declarative request template using only the exact canonical message fields above;
- accepted success status codes;
- at most one simple top-level JSON success-field/value check when status alone is insufficient;
- provider-documented retryable HTTP statuses;
- bounded standard HTTP `Retry-After` header handling;
- optionally one named top-level numeric JSON retry-delay field plus one fixed declared unit, but only when current official docs define it; no JSONPath/nested expressions;
- declared provider-specific non-secret options/defaults/allowed values and narrowly constrained endpoint substitutions;
- credential secret-key name only if a built-in cannot use `email_api_token`.

If a body retry-delay field is absent, malformed, undocumented, or has unclear units, ignore it and use the common fixed bounded retry schedule. Clamp accepted provider-supplied delays to a small global maximum.

CATALOG SECURITY BOUNDARY
- Catalog contains no secret values.
- All provider endpoints are HTTPS and validated.
- `config.toml` may select provider/alias and declared non-secret options only. It cannot override endpoint, auth mode/header, payload template, success rule, or retry classification arbitrarily.
- Reject duplicate IDs/aliases, unknown auth modes/encodings/placeholders, undeclared substitutions/options, invalid success/retry rules, and unsupported fields.
- Request templates are data, not code: no `eval`, Jinja, Python expressions, shell expansion, dynamic imports, or arbitrary template scripting.
- Render through structured serialization so message values cannot become code/template syntax.
- Authorization-bearing POST requests must not silently follow cross-host redirects. Unexpected redirects fail unless same-origin behavior is explicitly verified and safely implemented.
- Do not persist full provider response bodies; diagnostics are bounded/redacted.
- The catalog is not a plugin registry. Do not create one provider class/module per built-in for symmetry.

MAINTENANCE RULE
When a provider changes or a future provider is approved:
1. verify current official provider docs;
2. edit/add one provider block in `email-providers.toml` using the existing closed schema if possible;
3. add only declared non-secret operator fields truly required;
4. update focused catalog-render/auth/success/retry/redaction tests;
5. update operator/developer docs;
6. change Python only if a genuinely new transport capability cannot be represented safely by the closed schema.

FILE-SURFACE RULE
- Prefer one cohesive notification/catalog-renderer owner rather than one module/class per provider/transport/status/retry condition.
- `email-providers.toml` is the one provider-definition file.
- Keep permanent unit/timer count small; call `vwctl` directly rather than creating a wrapper script per timer.

TEST RULE
- Three layers only; test deterministic catalog validation/rendering/classification/fallback at stable HTTP/SMTP boundaries.
- One focused catalog render/auth/success-rule test per canonical built-in plus shared catalog-security/classifier/fallback tests is normally sufficient.
- Test alias resolution (`cyberpanel` -> `cyberpersons`) without duplicating the provider matrix.
- Do not build protocol simulators, fake MTAs, provider conformance frameworks, or tests at every layer.

GOAL
Add a small systemd automation surface and maintainable catalog-driven operational HTTPS email delivery with safe transient SMTP fallback, without Postfix or a custom durable queue.

IMPLEMENT
1. Add only permanent lifecycle/health/backup/maintenance units/timers actually needed.
2. Units execute installed immutable release/current path and installed config, never an arbitrary git checkout.
3. Add `email-providers.toml` containing the six verified canonical definitions and `cyberpanel` alias.
4. Implement one small notification owner that validates/loads the catalog, normalizes the exact canonical message context, renders the selected request, sends via Python stdlib HTTPS with normal CA/hostname validation, interprets the success rule, and applies shared bounded retry/fallback classification.
5. Keep authentication handling to the finite modes required by the built-ins. Do not create provider-specific classes/functions unless behavior genuinely cannot be expressed in the catalog.
6. Implement direct SMTP fallback with `ssl.create_default_context()` semantics and implicit TLS or required STARTTLS + authentication.
7. Return/persist only small secret-free state: configured/used transport, outcome, stable category/reason, event/time identifier, safe diagnostic text.
8. If API and SMTP both fail, expose failure through `status`/`doctor`; do not persist full message bodies or secret-bearing responses.
9. Add config validation/doctor checks for catalog validity, supported provider/alias, required API token, declared provider options, SMTP fallback availability, and last safe delivery result.
10. Document provider-catalog maintenance and CyberPanel/CyberPersons API + optional SMTP setup without requiring Python edits for ordinary metadata changes.

TESTS REQUIRED
- catalog schema/duplicate/unknown-field/HTTPS/placeholder/alias validation
- exact canonical message-field vocabulary
- operator config cannot override endpoint/auth/payload/success/retry arbitrarily
- each canonical built-in: provider selection + catalog-rendered authentication/request/success rule at project boundary
- `cyberpanel` alias resolves to `cyberpersons` without duplicate definition
- CyberPersons: 202+`success:true`; 429 bounded retry; 503 transient; 500 `send_failed` non-fallback by status; 400/403 visible
- fixed bounded retry is acceptable when CyberPersons body `retry_after` lacks documented usable unit semantics
- body retry-delay capability rejects missing unit/unknown field/malformed values and clamps accepted values
- Mailgun region/domain validation if supported
- API success stops without SMTP
- representative transient cases trigger SMTP only after bounded retry
- representative config/auth/security/ambiguous failures do not get masked
- cross-host redirect safety for auth-bearing requests
- SMTP TLS/auth behavior at stable mocked boundary
- secret redaction/result shape
- minimal systemd target/rendering validation

NON-GOALS
- Postfix/local MTA/durable queue
- arbitrary operator-defined provider endpoints/auth/payloads
- dynamic provider/plugin framework, provider SDK, or generic HTTP workflow language
- one provider source module/class per built-in
- general scheduler beyond systemd
- update engine

FINAL RESPONSE
- State automation/notification behavior and catalog design.
- List exact official provider docs verified and any V1 behavior intentionally changed because upstream documentation differs.
- List exact validation run/not run.
- List files/units created and justify each; explicitly explain why `email-providers.toml` reduces future library edits without becoming an unsafe plugin mechanism.
- Report later-phase follow-ups without implementing them.
```

</details>

---

<details>
<summary><strong>Prompt 7 — Reproducible versions and explicit updates</strong></summary>

```text
TASK: VaultWarden-OCI V2 — Phase 7: reproducible versions and explicit updates

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement Phase 7 only; no unattended updater or generic component framework.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, version/update decisions, and inspect `versions.toml`, runtime, recovery, systemd, notification, and doctor owners.
2. Verify **Phase 6 is present**, including systemd automation, the notification owner, and the immutable-release `email-providers.toml` contract. Also verify the Phase 5 recovery path required for update preflight remains available. If Phase 6 is missing, stop and report it rather than implementing notification/systemd work here.
3. Reuse the existing version owner; do not create one resolver module per component by default.

DURABLE V2 CONTRACT
- Greenfield Ubuntu 24.04 amd64/arm64; cloud-neutral/OCI-reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; one `vwctl`, one operator TOML config, one `versions.toml`.
- Existing SOPS/Age, rclone/recovery, edge, CrowdSec Cloudflare remediation, and static provider-catalog + SMTP-fallback boundaries are fixed and must not be redesigned here.
- Immutable application releases include the matching source-controlled `email-providers.toml`; update activation must not mix application code with a provider catalog from another release.
- Production exact pins. `--use-latest` dev/test only: resolve once at run start, freeze exact values/digests where available, record exact set, pass only exact values downstream.
- No unattended updater daemon, provider/plugin registry, migration engine, workflow framework, or speculative component abstraction.

FILE / TEST RULE
- Centralize version resolution in one owner; avoid per-component resolver files unless logic is materially different/cohesive.
- Test version parsing/resolution/architecture mapping and update decisions; mock smallest stable remote-release boundary; no broad network-heavy tests/custom runner/coverage gate.

GOAL
Provide reproducible pinned production versions, dev/test-only `--use-latest`, and an explicit safe operator-driven update path.

IMPLEMENT
1. `versions.toml` is the sole source-controlled component-version authority.
2. Centralize amd64/arm64 artifact/image resolution.
3. Production install/update uses exact pins only.
4. `--use-latest` resolves once, freezes exact versions/digests, records them, and never scatters live-latest checks across installers/templates.
5. Implement `vwctl update check|apply`: validate current state; create/verify recovery according to policy; stage immutable release including matching provider catalog/resources; pull/build exact pinned runtime components; switch `current`; restart and health/doctor gate; roll back application-release activation where safe before incompatible state changes.
6. No unattended auto-update.

TESTS REQUIRED
- versions parsing/resolution/architecture mapping
- `--use-latest` resolves once/freezes exact values
- representative update activation/failure/rollback decisions
- application release and provider catalog/resources activate as one coherent release
- smallest stable remote-release lookup boundary

NON-GOALS
- unattended updates/generic update-provider framework
- Phase 6 notification/systemd implementation
- V1 migration machinery
- redesign of edge/recovery/notification systems

FINAL RESPONSE
- State version/update behavior, exact validation run/not run, files created/deleted with rationale, avoided resolver proliferation, and later-phase follow-ups.
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
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md`, V2 decisions, architecture, and test strategy.
2. Verify **Phase 7 is present**, including reproducible version/update behavior and the intact Phase 6/5/4 surfaces it depends on. If Phase 7 is missing, stop and report it rather than documenting or implementing missing features here.
3. Inspect the complete V2 implementation/docs before creating new docs/tests/scripts.
4. Identify obsolete V1 files no longer required as build/runtime inputs.

FINAL BETA CONTRACT
- Ubuntu 24.04 amd64/arm64, cloud-neutral/OCI-reference, Cloudflare-first/CrowdSec, no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue; one `vwctl`, one operator TOML config, one versions manifest, no dashboard/TUI.
- SOPS + Age operational/offline recovery identities; volatile plaintext only.
- rclone: local verify -> copy/copyto -> remote verify -> success; separate prune; no destructive sync/provider framework.
- Vaultwarden direct SMTP.
- Operational notifications: six canonical built-ins; `cyberpanel` aliases `cyberpersons`; one immutable `email-providers.toml`; exact canonical message fields `from_email|from_name|from_header|to_email|subject|text`; direct authenticated SMTP transient-only fallback; no Postfix/MTA/durable queue/dynamic plugin registry.
- CyberPersons `500 send_failed` is not SMTP-fallback eligible by status alone; 429/503 are the current transient baseline, subject to current-doc re-verification.
- Provider metadata commonly changed upstream is maintained in the closed catalog rather than repeated throughout Python. Operator config cannot redirect credentials to arbitrary endpoints/auth/payloads.
- Cloudflare/Docker-iptables origin ingress uses validated/bounded ranges + fail closed. CrowdSec web decisions are remediated through Cloudflare only in beta; no host firewall bouncer requirement.
- One encrypted V2 recovery format + offline recovery material; no V1 reader/migration.
- Exact production pins; `--use-latest` dev/test only, resolved once to exact recorded values.
- No speculative framework/plugin/compatibility architecture.

FILE / DOC / TEST RULE
- Prefer deletion/consolidation of obsolete V1 files, wrappers, aliases, placeholders, migration readers, dashboard files, Postfix queue tooling, and V1 test architecture once no longer required.
- Target docs are README + INSTALL/OPERATIONS/SECURITY/RECOVERY/DEVELOPMENT, but this is not a quota. Combine when clear; use `vwctl --help` as command reference.
- Permanent CI stays quality + unit + small integration; full/destructive host acceptance is a release gate, not a giant per-PR controller.

GOAL
Make V2 understandable, acceptance-tested on disposable Ubuntu 24.04, and free of obsolete V1 product surfaces on the V2 branch.

IMPLEMENT
1. Consolidate the smallest clear operator/developer documentation covering install, operations/status/doctor/logs, security, SOPS/Age/offline recovery, one recovery/rclone workflow, provider configuration + transient SMTP fallback, provider-catalog maintenance, Cloudflare/CrowdSec scope, versions/updates, and developer/test/release workflow.
2. Document CyberPanel Email/CyberPersons setup explicitly: canonical `cyberpersons` / `cyberpanel` alias, API-key `can_send`, verified sending domain, API token in SOPS, and independent SMTP credentials if CyberPanel SMTP is used for fallback. Re-check current official settings while writing final docs.
3. Developer docs explain: routine provider endpoint/auth/request/success/retry changes edit the provider catalog + focused tests/docs; Python changes only for a genuinely new transport capability.
4. Use `vwctl --help` for command reference and stable doctor IDs/JSON for diagnostic truth.
5. Create/retain a small disposable-host acceptance procedure for Ubuntu 24.04 amd64/arm64 where environments are available.
6. Acceptance covers at least clean install/layout; start/status/doctor; SOPS/Age no-leak materialization; Cloudflare origin fail-closed + CrowdSec Cloudflare remediation; backup -> rclone publish -> verify -> download -> restore; one configured built-in API success + representative transient SMTP fallback; provider-catalog validation; systemd; pinned update.
7. Remove V1 production/docs/tests from `v2` when no longer required; rely on `main`/git history.
8. Review first-party file surface and consolidate/delete naturally without giant mixed-responsibility owners.

NON-GOALS
- V1 compatibility/dashboard/generated command manual
- CrowdSec host firewall bouncer unless a later explicit architecture decision added host-service remediation
- arbitrary operator-defined provider endpoints/auth/payloads
- dynamic provider abstractions/plugin SDK/general HTTP scripting
- custom test-runner framework
- new post-beta product capabilities

FINAL RESPONSE
- Summarize beta docs/acceptance/cleanup, exact validation/acceptance run/not run, files deleted/consolidated/created with rationale, provider-catalog maintainability/security review, file-surface reduction, and post-beta ideas not implemented.
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
- Fix one observable bug only; do not turn it into a refactor/architecture rewrite/cleanup campaign/later-phase implementation.
- Do not edit `reports/CODEX-PROMPTS.md`.

PRE-FLIGHT
1. Read root `AGENTS.md` and applicable V2 decisions.
2. Reproduce/locate the observable failure at a stable/public boundary where practical.
3. Identify the smallest existing owner before creating any file.
4. For an email-provider settings bug, determine first whether `email-providers.toml` is the correct owner; ordinary endpoint/auth/request/success/retry updates should not trigger a Python-library rewrite.
5. Inspect V1 only if it clarifies a required security property; do not port V1 architecture.

DURABLE V2 CONTRACT
- Preserve current greenfield Ubuntu 24.04 amd64/arm64, cloud-neutral, Cloudflare/CrowdSec, one-CLI/operator-config/versions, SOPS/Age, rclone, static email-provider catalog + transient-SMTP-fallback, recovery, firewall, and exact-version boundaries.
- Preserve exact canonical provider-template fields: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- Preserve CyberPersons failure classification unless current official docs justify a deliberate contract change: 500 is not transient by status alone.
- Preserve CrowdSec beta web remediation through Cloudflare; do not add a host firewall bouncer as an incidental bugfix.
- No V1 compatibility/dashboard/Postfix/custom queue/dynamic provider registry/framework/migration engine/speculative extension point.
- Operator config cannot define arbitrary provider endpoints/auth/payloads; credentials remain in SOPS.
- Python 3.12 stdlib structured logic; Bash minimal glue.

FILE / TEST RULE
- Prefer changing the smallest existing owner; a new file requires clear ownership/security reason; no one-function helper/wrapper merely to avoid editing the owner.
- Add one highest-value behavioral regression test only if existing tests do not already protect the bug; no source-string/order/prose-freezing/custom-runner/coverage-gate patterns.

METHOD
1. State observable bug and affected stable boundary.
2. Identify root cause/smallest owner.
3. Make smallest coherent fix.
4. If an email provider changed only representable metadata, update its catalog block instead of provider-specific Python.
5. Do not create an abstraction merely because a few lines look similar.
6. Add one regression test only for a real coverage gap.
7. Run smallest validation sufficient.
8. If the fix requires changing a durable V2 boundary or materially expanding the provider-catalog capability set, stop and report the conflict rather than silently widening design.

FINAL RESPONSE
- State bug/root cause, smallest owner changed, exact validation run/not run, whether a file was added and why, whether a provider fix stayed catalog-only where appropriate, and out-of-scope follow-ups.
```

</details>

---

## Human review checklist

- Correct standalone prompt/phase was used.
- Agent did not edit the authoritative prompt file.
- For every Phase N > 0, Phase N-1 was verified before implementation.
- Work stayed inside phase/bug scope.
- V1 implementation shape was not imported without necessity.
- No speculative framework/compatibility/queue/dynamic-provider layer appeared.
- New files have clear ownership value; thin wrappers/one-function modules avoided.
- Secrets never moved into ordinary config/provider catalog/argv/logs.
- rclone publication remains non-destructive and pruning separate.
- Provider templates use exactly `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- CyberPersons 500 is not treated as transient/fallback-eligible merely because it is 500; 429/503 behavior matches implementation-time official docs.
- Provider retry-delay handling remains bounded and does not become a response-expression language.
- Cloudflare-only origin ingress remains fail-closed.
- CrowdSec beta web remediation uses the selected Cloudflare path; a host firewall bouncer was not added without a new explicit requirement.
- Tests protect observable risk rather than source layout.
- PR is small enough to understand/review; later-phase ideas were reported, not implemented.
