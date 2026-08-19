# VaultWarden-OCI V2 — PR-Specific Standalone Review Prompts

Date: 2026-08-19
Status: reviewer utility; not an implementation source of truth.

## How to use

These prompts are for a **separate review agent** after a V2 PR is ready for review.

- Expand the prompt matching the PR/phase.
- Copy the **entire fenced block** into a fresh review-agent session.
- For Phase 0–8/corrective prompts, replace only `<PR_URL>`.
- The current design/report PR prompt already contains PR #333 and can be pasted as-is.
- No `<ORIGINAL_PROMPT>` is required: each review prompt embeds the expected phase scope and review criteria.
- The review agent reviews only. It must not push commits, edit the PR, resolve threads, or merge unless a human explicitly asks afterward.
- `reports/V2-CODEX-PROMPTS.md` remains the authoritative implementation-agent contract. These review prompts are intentionally phase-specific mirrors for independent verification.

---

<details>
<summary><strong>Review Prompt — Current V2 design/report PR #333</strong></summary>

```text
Review PR https://github.com/killer23d/VaultWarden-OCI/pull/333.

PURPOSE OF THIS PR
This is the V2 greenfield design/report PR targeting branch `v2`. It is documentation/design only. It establishes the authoritative Codex execution contract and supporting architecture/audit/test/review documents before Phase 0 implementation begins.

REVIEW MODE
- Review only. Do not modify code/files, push commits, update the PR, resolve threads, or merge it.
- Be skeptical but proportional. Do not invent enterprise requirements or implementation work that is outside this documentation/design PR.
- Treat documentation as architecture because these files will steer later independent Codex sessions.

GATHER EVIDENCE FIRST
1. Read PR metadata, base/head refs, changed-file list, complete diff, description, review submissions/threads/comments, and current CI/check status.
2. Read every changed report completely, not only patch hunks:
   - `reports/V2-CODEX-PROMPTS.md`
   - `reports/V2-ARCHITECTURE-PROPOSAL.md`
   - `reports/V2-AUDIT.md`
   - `reports/V2-TEST-STRATEGY.md`
   - `reports/V2-REVIEW-PROMPTS.md`
3. Inspect `main`/V1 files only where needed to verify claims made by the audit or provider carry-forward decisions.
4. Search the reports for stale/superseded wording, especially old "one selected provider", "five providers", direct-SMTP-only, Postfix preservation, deleted-report precedence, V1 migration compatibility, or contradictory source-of-truth rules.

AUTHORITATIVE DESIGN EXPECTATIONS
- `V2-CODEX-PROMPTS.md` is explicitly the implementation-agent source of truth.
- Phase 0–8 and corrective implementation prompts are standalone copy/paste blocks.
- Ordinary phase agents are not allowed to rewrite the authoritative prompt contract.
- Root `AGENTS.md` is intended to become a concise map in Phase 0, not a second architecture authority.
- Greenfield V2: no V1 state/archive/backup-format/migration/command/runtime-layout compatibility requirement.
- Ubuntu 24.04 LTS; amd64 + arm64; cloud-neutral runtime; OCI A1 Flex reference only.
- Python 3.12 stdlib-first structured logic; Bash minimal glue.
- Prefer fewer cohesive first-party files without a numeric file-count target.
- One `vwctl`, one operator-editable TOML config authority, one `versions.toml`.
- SOPS + Age retained with root-only operational identity, separate offline recovery material, and volatile decrypted secret material.
- rclone first-class: local verify -> copy/copyto-style publication -> remote verification -> success; pruning separate; no destructive sync as normal publication.
- Vaultwarden application mail uses direct authenticated SMTP.
- Operational notification built-ins are canonical `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`; `cyberpanel` is only an alias to the `cyberpersons` definition.
- Phase 6 uses one source-controlled immutable `email-providers.toml` catalog so routine endpoint/auth/request/success/retry changes are catalog edits rather than notification-library rewrites.
- The provider catalog is closed and non-secret: no arbitrary operator endpoints/auth/headers/templates, `eval`, Jinja, Python expressions, shell expansion, dynamic imports, Python entry points, provider SDK, or general HTTP workflow language.
- Authorization-bearing requests must not silently follow unsafe cross-host redirects.
- CyberPanel Email/CyberPersons baseline is grounded in official docs but must be re-verified during Phase 6 implementation.
- SMTP fallback is direct authenticated TLS SMTP and only for clearly transient API failures after bounded retry; no Postfix/local MTA/custom durable queue.
- Cloudflare-first/CrowdSec beta edge uses one Docker bridge/iptables packet path with validated Cloudflare ranges, bounded last-known-good state, and fail-closed behavior.
- One encrypted V2 recovery format plus offline recovery material.
- Exact production version pins; `--use-latest` development/testing only.
- Three validation layers only: focused unit, small integration, disposable-host release acceptance; no custom V1-style runner or coverage quota.

REVIEW QUESTIONS
1. Are the five report files internally consistent and non-duplicative enough to maintain?
2. Are every Phase 0–8 implementation prompt and corrective prompt genuinely standalone/copy-paste-ready?
3. Does each phase have a clear prerequisite, scope, non-goals, tests, file-surface rule, and final-response requirement?
4. Could a fresh agent accidentally reintroduce V1 Postfix, migration/archive compatibility, dashboard/TUI, multiple backup tiers, generic provider/plugin frameworks, multiple firewall backends, or V1 source-coupled test architecture because of ambiguous wording?
5. Is the `email-providers.toml` design maintainable without becoming a second operator config authority or an arbitrary credential-exfiltration mechanism?
6. Is CyberPanel/CyberPersons represented consistently across prompts, architecture, tests, reviewer instructions, and PR description?
7. Does the design fit a small team of about 10 users and a junior administrator, or has documentation/architecture become unnecessarily elaborate?
8. Are file/test reduction preferences clear without becoming gameable quotas?
9. Are there any OPEN decisions that should block Phase 0 or later work but are currently hidden?
10. Does the PR remain documentation/design only, with no accidental runtime implementation?

MERGE READINESS
- Check current CI, unresolved review threads, and known failures.
- Do not return `SAFE TO MERGE` while required CI is still pending or failing; use `NOT READY / INCOMPLETE` if the content looks good but required evidence is unfinished.

OUTPUT FORMAT
Start with exactly one verdict:
- SAFE TO MERGE
- NEEDS CHANGES
- NOT READY / INCOMPLETE

Then provide:
1. `Blockers`
2. `Important findings`
3. `Minor findings`
4. `Cross-document conflicts / stale wording`
5. `Agent-overengineering risks`
6. `Small-team / complexity assessment`
7. `Validation / CI`
8. `What I did not verify`

For each finding, cite the affected file/section and explain the concrete downstream risk to a later Codex session.

End by answering explicitly:
"Are these V2 reports complete, accurate, internally consistent, fit for a small team, and safe to merge into `v2` as the architecture/agent contract?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 0 PR: contract reset and durable decisions</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 0: contract reset and durable decisions.

REVIEW MODE
- Review only. Do not modify, push, update, resolve, or merge the PR.
- Phase 0 is documentation/agent-contract work only. Production runtime code is out of scope.

GATHER EVIDENCE
1. Read PR metadata/base/head, full changed-file list/diff, description, review threads/comments, and CI/check status.
2. Read the complete Phase 0 block in `reports/V2-CODEX-PROMPTS.md`, root `AGENTS.md` from base and head, and every V2 product/decision document changed by the PR.
3. Inspect surrounding repository files only where necessary to detect duplicate authorities or accidental runtime changes.

PHASE 0 MUST DELIVER
- Replace V1-oriented root `AGENTS.md` with a concise V2 map, not a second architecture manual.
- Make it explicit that V2 is greenfield and V1 is security/behavior reference only, not compatibility API.
- Point agents to the authoritative standalone Codex prompts and durable V2 decisions.
- Record the Python-first/Bash-minimal language boundary.
- Record one operator-editable TOML config authority and one source-controlled `versions.toml` authority.
- Record SOPS + Age operational/offline recovery identities and one canonical encrypted-secrets-document path.
- Record Cloudflare-only beta ingress on one Docker iptables packet path.
- Record operational email contract: six canonical built-ins `mailersend|sendgrid|mailgun|postmark|resend|cyberpersons`, `cyberpanel` alias, common `email_api_token` model, future static `email-providers.toml`, bounded transient-only direct SMTP fallback, no Postfix/custom queue/dynamic plugin framework.
- Record that provider catalog is maintainer-editable release data, while operator config cannot arbitrarily replace endpoints/auth/payload templates.
- Record rclone copy-style publication + remote verification + separate pruning.
- Record one V2 recovery format + offline recovery material + no V1 compatibility.
- Record bounded three-layer testing.
- Group decisions into the fewest durable documents that remain clear rather than one ADR file per bullet.

PHASE 0 MUST NOT
- Add production Python/Bash runtime implementation, Compose changes, provider catalog implementation, installer redesign, or later-phase features.
- Create ADR tooling/generators/frameworks.
- Preserve V1 Postfix, backup tiers, dashboard, migration, command aliases, or test architecture as requirements.
- Create unnecessary decision-document/file proliferation.

REVIEW QUESTIONS
- Is `AGENTS.md` short enough to act as a map and clear enough that a fresh agent will follow V2 instead of V1?
- Are there competing config/secrets/version authorities?
- Is the provider-catalog boundary recorded without implementing it early?
- Is the canonical SOPS path actually locked down rather than left ambiguous?
- Did the PR accidentally split architecture decisions across too many files?
- Did Phase 0 stay documentation-only?
- Are Markdown/link/basic checks sufficient and honestly reported instead of running/expanding the V1 suite unnecessarily?

MERGE READINESS
- Required docs/links must be coherent and CI/checks complete as required by the repo.
- Pending required CI means `NOT READY / INCOMPLETE`, not `SAFE TO MERGE`.

OUTPUT
Start with exactly one verdict: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Blockers, Important findings, Minor findings, Phase-0 requirement coverage, Scope violations, File-surface assessment, Validation/CI, What I did not verify.

End by answering:
"Does this PR completely reset the repository contract for V2, without implementing runtime work or preserving V1 architecture by accident, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 1 PR: minimal Python foundation</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 1: minimal Python foundation.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Judge only the Phase 1 foundation; later Docker, secrets execution, email, rclone, firewall, recovery, systemd, and update work is out of scope.

GATHER EVIDENCE
1. Read PR metadata, complete diff, changed files, comments/threads, CI/checks.
2. Read root `AGENTS.md`, Phase 0 decisions, and the complete Phase 1 block in `reports/V2-CODEX-PROMPTS.md`.
3. Inspect relevant base/head package/config/version/test files around the diff.

PHASE 1 MUST DELIVER
- Small Python 3.12 stdlib-first `vwctl` foundation.
- Only the intended initial surface: `vwctl --help`, `--version`, small explicit config validation, `versions`, and read-only `doctor [--json]` checks for host/architecture/config/version-file concerns.
- One `versions.toml` containing exact values needed now.
- amd64/x86_64 and arm64/aarch64 normalization with clear unsupported-architecture failure.
- One small subprocess helper taking argv arrays, no shell interpolation, normalizing success/nonzero/not-found.
- One global mutation-lock primitive using `fcntl.flock`; no lock on read-only commands.
- Stable doctor IDs and PASS/WARN/FAIL/SKIP with stable JSON shape; human prose not treated as API.
- No pre-created later-phase modules.

EXPECTED TESTS
- valid/invalid config TOML
- valid/invalid versions manifest
- architecture normalization/unsupported architecture
- subprocess success/nonzero/not-found
- real-temp lock contention
- doctor JSON shape/check IDs implemented now

REVIEW QUESTIONS
- Is the package/module layout the smallest cohesive ownership model, or did the PR create one-function modules/wrappers/future placeholders?
- Is config parsing stdlib/TOML based and singular rather than reviving `.env` synchronization?
- Are subprocess calls safe and free of command-string interpolation?
- Is locking minimal and correct?
- Are doctor IDs/JSON stable while prose remains flexible?
- Are tests behavior-focused rather than source-string/private-function tests?
- Did the PR accidentally implement Docker/root mutation/SOPS execution/email/rclone/edge/recovery/systemd/update work?
- Did it add runtime third-party dependencies without a concrete requirement?

OUTPUT
Verdict first: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Blockers, Important findings, Minor findings, Phase-1 requirement coverage, Scope creep, File/test-surface assessment, Validation/CI, What I did not verify.

End by answering:
"Is this the smallest safe Python foundation for later V2 work, complete for Phase 1 and safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 2 PR: bootstrap and immutable installed layout</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 2: bootstrap and immutable installed layout.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Phase 2 installs V2 layout/code safely but does not start Vaultwarden/Caddy or implement later runtime features.

GATHER EVIDENCE
1. Read PR metadata/diff/changed files/review threads/CI.
2. Read root `AGENTS.md`, Phase 0 decisions, Phase 1 implementation, and the complete Phase 2 Codex prompt.
3. Inspect installer/path/permission owners in base and head.

PHASE 2 MUST DELIVER
- Minimal root bootstrap, with Bash only where pre-install/host glue is materially simpler and structured logic delegated to Python.
- Validate Ubuntu 24.04 and amd64/arm64.
- Create only required installed/state/runtime paths, including immutable `/opt/vaultwarden-oci/releases/<release>/`, stable `/opt/vaultwarden-oci/current`, `/etc/vaultwarden-oci/config.toml`, canonical Age/secrets paths, required `/var/lib/vaultwarden-oci/` state, and `/run/vaultwarden-oci/` volatile state.
- Install the current Python app immutably and expose the intended stable `vwctl` path.
- Installed release layout must be able to carry source-controlled resources later, including `email-providers.toml`, without making them operator config.
- Create only users/groups/directories with demonstrated need.
- Same-release/same-config rerun is safe; incompatible pre-existing ownership/state fails clearly.
- Only minimal systemd integration needed for installed application/lifecycle addressing; permanent timers wait until Phase 6.
- Centralized path/permission policy rather than duplicated constants.

EXPECTED VALIDATION
- focused path/permission/rendering tests
- small temp-root integration where practical
- disposable Ubuntu 24.04 install smoke check when environment supports it

REVIEW QUESTIONS
- Are root-owned paths and permissions safe and explicit?
- Can rerun overwrite or adopt unsafe/incompatible pre-existing state?
- Is immutable-release/current-symlink handling coherent?
- Are scripts/wrappers proliferating unnecessarily?
- Is `config.toml` still the one operator config authority?
- Did the PR accidentally start containers, decrypt secrets, implement provider catalog/email, edge/CrowdSec, backup/rclone/restore, updates, or V1 migration?
- Are tests focused on installed behavior rather than source layout?

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-2 requirement coverage, Permission/idempotency assessment, Scope creep, File/test-surface assessment, Validation/CI, What I did not verify.

End by answering:
"Does this PR establish a safe, minimal, idempotent V2 installed layout without starting later-phase runtime work, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 3 PR: Vaultwarden + Caddy, SOPS/Age, Vaultwarden SMTP</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 3: core runtime, SOPS/Age, and Vaultwarden direct SMTP.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Phase 3 owns Vaultwarden+Caddy core, secrets orchestration, lifecycle commands, and Vaultwarden direct SMTP. Phase 4 edge enforcement, Phase 5 recovery/rclone, and Phase 6 operational notification catalog/systemd automation are out of scope.

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, durable decisions, Phase 2 installed layout, and complete Phase 3 prompt.
3. Inspect Compose/runtime/config/secrets paths and relevant tests in base/head.

PHASE 3 MUST DELIVER
- Minimal Compose/runtime with Vaultwarden + Caddy only.
- Useful hardening where compatible: explicit users, `cap_drop: ALL` plus demonstrated additions only, no-new-privileges, read-only roots/tmpfs where practical, bounded logs, health checks, reasonable PID/memory limits.
- SOPS + Age using the canonical Phase 0 paths: one encrypted structured document, root-only operational identity, separate offline recovery recipient/material, volatile-only plaintext, required-key validation.
- No plaintext secrets in TOML, argv, ordinary logs, exceptions, or persistent temp files.
- `vwctl start|stop|restart|status|logs` for the core stack.
- Vaultwarden application mail uses direct authenticated SMTP; no Postfix.
- Caddy reverse-proxy/DNS-01 path needed by Cloudflare-first architecture, but no Phase 4 host ingress enforcement/CrowdSec implementation yet.
- Doctor checks only for behavior introduced now.

EXPECTED TESTS
- config-to-runtime rendering/validation
- SOPS/Age orchestration at stable subprocess boundary
- plaintext-secret non-leakage
- representative lifecycle/status integration behavior

REVIEW QUESTIONS
- Does secret material remain volatile and root-protected?
- Are SOPS/Age treated as trusted external tools rather than reimplemented cryptography/frameworks?
- Does Compose hardening actually work, or are constraints copied blindly from V1?
- Is Vaultwarden SMTP direct and securely configured, without Postfix or operational-email work creeping in?
- Are lifecycle/status commands truthful and cohesive?
- Did the PR accidentally implement `email-providers.toml`, operational API fallback, Cloudflare CIDR enforcement, CrowdSec setup, backup/rclone/restore, or updates?
- Did file/module count grow beyond clear runtime/secrets ownership?

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-3 requirement coverage, Secret-handling assessment, Runtime/hardening assessment, Scope creep, File/test-surface assessment, Validation/CI, What I did not verify.

End by answering:
"Does this PR safely establish the V2 core runtime and secrets boundary with direct Vaultwarden SMTP, without leaking secrets or implementing later phases, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 4 PR: Cloudflare ingress and CrowdSec</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 4: Cloudflare ingress and CrowdSec.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Phase 4 supports exactly one beta production edge path. Do not reward extra firewall/provider modes as "flexibility".

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, edge decisions, Phase 3 runtime/Caddy implementation, and complete Phase 4 prompt.
3. Inspect packet-path/firewall/CrowdSec code around changed owners.

PHASE 4 MUST DELIVER
- Cloudflare IPv4/IPv6 retrieval with strict parsing/validation.
- Last-known-good range persistence with bounded staleness.
- One small project-owned Docker iptables ingress path allowing published Caddy HTTPS only from validated Cloudflare ranges.
- Fail closed when no safe current/last-known-good policy exists.
- No claim that ordinary UFW `INPUT` alone protects Docker-published Caddy ports.
- CrowdSec retained using upstream installation/integration where practical; project owns only needed acquisitions/config/credentials/bouncer integration/lifecycle/diagnostics.
- `vwctl`/doctor behavior sufficient for a junior admin to diagnose edge health.

EXPECTED TESTS
- CIDR parsing/validation/staleness
- deterministic policy/rule decisions for the one supported backend
- fail-closed decisions
- minimal external-command integration
- actual packet path reserved for disposable-host/release acceptance

PHASE 4 MUST NOT
- Add nftables or a second firewall backend.
- Add direct/non-Cloudflare beta ingress.
- Add generic firewall/provider abstraction or cloud security-group API integration.
- Port the V1 CrowdSec installer wholesale.
- Implement recovery/rclone, notification, or update work.

REVIEW QUESTIONS
- Does the actual Docker packet path match the claimed security model?
- Can stale/invalid Cloudflare ranges accidentally fail open?
- Are IPv4 and IPv6 both handled correctly?
- Is the project owning too much CrowdSec lifecycle instead of delegating upstream?
- Are diagnostics truthful without becoming a dashboard/repair framework?
- Is the implementation one cohesive edge owner rather than one wrapper per command/action?

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-4 requirement coverage, Packet-path/fail-closed assessment, CrowdSec ownership assessment, Scope creep, Test/validation assessment, CI, What I did not verify.

End by answering:
"Does this PR implement the single supported Cloudflare/CrowdSec beta edge accurately and fail closed on the real Docker packet path, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 5 PR: backup, restore, rclone, offline recovery</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 5: backup, restore, rclone, and offline recovery.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Recoverability is the highest-risk area; require evidence, but do not ask for V1 compatibility or multiple backup products.

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, recovery/rclone/SOPS decisions, current storage/runtime implementation, and complete Phase 5 prompt.
3. Inspect all changed backup/restore/manifest/rclone code and relevant tests completely.

PHASE 5 MUST DELIVER
- Exactly one normal encrypted V2 recovery format.
- `vwctl backup` creates a consistent SQLite snapshot, required persistent app/config material, V2 format/version metadata/checksums, encrypts before publication, and verifies before success.
- Operational Age private key is excluded from normal recovery artifacts; offline private recovery material is not persisted on the server.
- Incomplete local candidates are never reported valid.
- Small rclone owner for diagnostics/connectivity/publication/listing/remote verification/download-staging/explicit pruning.
- Offsite success sequence: local verification -> `copy`/`copyto`-style publication -> remote verification -> success.
- Retention/pruning/deletion is separate; normal publication never uses destructive `rclone sync` semantics.
- `vwctl restore` is V2-only: decrypt/validate/check/stage before live mutation, validate space/target, stop services only after preflight, promote through a small explicit transaction boundary, restore permissions, and health-gate any requested start.
- `status`/`doctor` exposes last verified local/offsite recovery state without secrets.

EXPECTED TESTS
- representative real-temp SQLite backup/restore
- corruption/wrong-key/incomplete-manifest/preflight failure
- rclone argv/result classification
- proof normal publication does not request destructive sync
- remote verification before success
- explicit pruning decisions

REVIEW QUESTIONS
- Can backup report success before consistency/encryption/integrity/remote verification is established?
- Can restore mutate live state before all feasible validation/preflight completes?
- Can a wrong key/corrupt manifest/archive partially damage live state?
- Are file permissions/temporary staging/atomic publication boundaries safe?
- Is the operational Age key accidentally captured?
- Does rclone remain a delegated tool rather than a storage-provider abstraction?
- Did the PR add V1 archive readers, db/full/emergency tiers, replication daemons, generic transactions/workflows, or notification/system redesign?
- Is test attention high enough for recovery without recreating V1's test architecture?

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-5 requirement coverage, Backup integrity assessment, Restore preflight/promotion assessment, rclone non-destructive assessment, Offline-key assessment, Test/CI evidence, Complexity/file-surface assessment, What I did not verify.

End by answering:
"Would I trust this PR to create and restore a real V2 recovery point without false-success or destructive-publication hazards, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 6 PR: systemd and catalog-driven operational notifications</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 6: systemd automation and catalog-driven operational notifications.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- This phase must be maintainable when email-provider settings change, but must not become a runtime plugin system or arbitrary HTTP scripting engine.

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, notification decisions, architecture/test reports, complete Phase 6 prompt, current config/secrets/status/doctor/systemd owners, and the new `email-providers.toml` completely.
3. Inspect implementation/tests around HTTP rendering, redirects, retries/classification, SMTP, systemd units, and provider-catalog validation.
4. Verify the PR states which current official provider documentation it checked. Spot-check current official documentation for any materially security-sensitive or questionable provider setting rather than trusting copied V1 values.

PHASE 6 MUST DELIVER
- Only permanent lifecycle/health/backup/maintenance systemd units/timers actually needed, executing installed immutable code/config rather than arbitrary checkout paths.
- One source-controlled non-secret immutable-release `email-providers.toml` containing canonical built-ins:
  `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`.
- `cyberpanel` is an alias to the same `cyberpersons` definition, not duplicate provider data.
- Operator selects provider/alias in `/etc/vaultwarden-oci/config.toml`; operator config cannot arbitrarily override endpoint/auth/header/payload/success/retry semantics.
- Common SOPS `email_api_token` unless a provider's current requirements demonstrably need another secret; provider catalog contains no credentials.
- Closed catalog schema sufficient for supported providers: HTTPS endpoint with declared substitutions, closed auth modes/headers, JSON/form encoding, fixed canonical message placeholders (`from_email`, `from_name`, `to_email`, `subject`, `text`), optional simple success-field check, documented retry statuses/Retry-After handling, declared non-secret options.
- Strict validation rejects duplicate IDs/aliases, unknown fields/auth/encoding/placeholders/options/substitutions, invalid success/retry rules, and non-HTTPS endpoints.
- Templates are data, not code: no `eval`, Jinja, Python expressions, shell expansion, dynamic imports, provider classes/modules merely for symmetry, provider SDK, or general HTTP workflow language.
- Structured serialization prevents message data from becoming template/code syntax.
- Authorization-bearing POSTs do not silently follow unsafe cross-host redirects.
- One cohesive notification owner validates/loads catalog, normalizes message fields, renders request, sends using Python stdlib HTTPS with normal CA/hostname validation, interprets success rule, and applies shared bounded retry/fallback classification.
- API success stops; SMTP is used only after bounded retry for clearly transient conditions. Configuration/auth/permanent/security failures remain visible and are not silently masked.
- Direct SMTP uses normal certificate/hostname validation with implicit TLS or required STARTTLS + authentication; no plaintext downgrade.
- If fallback SMTP is not configured, doctor reports it unavailable.
- No Postfix/local MTA/spool/persistent retry queue/dead-letter system.
- Small secret-free last-delivery state only; no full provider response bodies or secrets persisted.
- Documentation explains catalog maintenance and operator setup.

CYBERPANEL/CYBERPERSONS MUST BE VERIFIED
At minimum, confirm current official docs at implementation/review time for:
- canonical V2 ID `cyberpersons`; alias `cyberpanel`;
- `POST https://platform.cyberpersons.com/email/v1/send` if still current;
- Bearer API-key authentication and send permission requirements;
- required V2 plain-text fields `from`, `to`, `subject`, `text`;
- accepted-send semantics (currently designed as HTTP 202 plus `success: true`);
- current retryable/permanent status categories;
- optional SMTP fallback settings if documented, with SMTP credentials separate from API key.
If current official docs differ from the design baseline, the implementation should follow current docs and explicitly document the intentional change.

EXPECTED TESTS
- catalog schema, duplicates, unknown fields, HTTPS, placeholders, aliases
- operator config cannot override endpoint/auth/payload arbitrarily
- one focused catalog-render/auth/success test per canonical provider
- `cyberpanel -> cyberpersons` alias without duplicated matrix
- current CyberPanel success/retry classification
- Mailgun region/domain if supported
- API success prevents SMTP
- representative transient failures trigger SMTP only after bounded retry
- representative config/auth/security failures remain visible
- cross-host redirect safety
- SMTP TLS/auth stable boundary
- secret redaction/result shape
- minimal systemd target/rendering validation

MAINTAINABILITY REVIEW
- A routine provider endpoint/auth/request/success/retry change should usually require changing one catalog block + focused tests/docs, not Python library rewrites.
- Python should change only for a genuinely new transport capability that cannot safely fit the closed schema.
- Do not accept one Python module/class per provider as an unnecessary regression.
- Also do not accept an over-general schema that permits arbitrary HTTP requests or credential exfiltration.

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-6 requirement coverage, Provider-catalog maintainability assessment, Catalog security assessment, CyberPanel verification, Fallback/classification assessment, systemd assessment, Tests/CI, Complexity/file-surface assessment, What I did not verify.

End by answering:
"Does this PR provide a secure, maintainable provider catalog—including CyberPanel/CyberPersons—so routine provider setting changes avoid library rewrites without creating an unsafe plugin/HTTP engine, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 7 PR: reproducible versions and explicit updates</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 7: reproducible versions and explicit updates.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- Phase 7 must preserve existing runtime/recovery/edge/notification architecture and add no unattended updater or generic component framework.

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, version/update decisions, complete Phase 7 prompt, `versions.toml`, recovery/update/runtime owners, and immutable-release layout.
3. Inspect remote-release lookup code/tests and activation/rollback behavior.

PHASE 7 MUST DELIVER
- `versions.toml` remains the sole source-controlled component-version authority.
- Centralized amd64/arm64 artifact/image resolution.
- Production install/update uses exact pins only.
- `--use-latest` is dev/test-only, resolves once at run start, freezes exact values/digests where available, records exact set, and does not scatter live-latest checks.
- `vwctl update check|apply` safely validates current state; creates/verifies recovery according to policy; stages immutable release; pulls/builds exact pinned runtime components; switches `current`; restarts; health/doctor gates; rolls back application-release activation where safe before incompatible state change.
- Application code and matching source-controlled resources such as `email-providers.toml` activate as one coherent immutable release; no mixed-version provider catalog.
- No unattended updater daemon.

EXPECTED TESTS
- versions parsing/resolution/architecture mapping
- `--use-latest` resolves once/freezes exact values
- representative activation/failure/rollback decisions
- app release and provider catalog/resources activate coherently
- smallest stable remote-release lookup boundary

REVIEW QUESTIONS
- Can production ever run a floating `latest` value?
- Can different update substeps independently resolve "latest" and drift?
- Can `current` point to a partially staged or mismatched release/catalog?
- Does update require/verify recovery appropriately before risky mutation?
- Is rollback overpromised across incompatible data changes?
- Did the PR create per-component resolver files/classes or a generic update-provider framework unnecessarily?
- Did it redesign recovery/notification/edge systems instead of using existing interfaces?

OUTPUT
Verdict first, then: Blockers, Important findings, Minor findings, Phase-7 requirement coverage, Reproducibility assessment, Activation/rollback assessment, Release-resource coherence assessment, Scope/complexity assessment, Tests/CI, What I did not verify.

End by answering:
"Does this PR keep production versions reproducible and updates explicit/safe, with code and provider catalog activating as one release, and is it safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 8 PR: beta docs, acceptance, and V2 cleanup</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 8: beta documentation, release acceptance, and V1 cleanup.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- This is final beta consolidation/readiness work, not an invitation to add new enterprise/product features.

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, complete Phase 8 prompt, current architecture/test strategy, final V2 docs, current `v2` tree, and release/host acceptance evidence.
3. Identify obsolete V1 runtime/docs/tests that remain and determine whether they are still real build/runtime inputs.

FINAL BETA CONTRACT TO VERIFY
- Ubuntu 24.04 LTS; amd64 + arm64; cloud-neutral/OCI-reference; Cloudflare-first/CrowdSec; no V1 compatibility.
- Python 3.12 stdlib structured logic; Bash minimal glue.
- One `vwctl`, one operator TOML config, one `versions.toml`, no dashboard/TUI.
- SOPS + Age operational/offline recovery model; volatile plaintext only.
- rclone local verify -> copy/copyto -> remote verify -> success; separate prune; no destructive sync/provider framework.
- Vaultwarden direct authenticated SMTP.
- Operational notifications: canonical six provider definitions in one immutable `email-providers.toml`, `cyberpanel` aliasing `cyberpersons`, common API-token model unless current provider requires otherwise, direct authenticated SMTP transient fallback, no Postfix/MTA/durable queue/dynamic plugin system.
- Routine provider metadata changes are catalog edits + focused tests/docs; operator config cannot redirect credentials to arbitrary endpoints/auth/payloads.
- Cloudflare/Docker-iptables fail-closed ingress + CrowdSec; no second firewall backend.
- One encrypted V2 recovery format + offline recovery material; no V1 reader/migration.
- Exact production pins; `--use-latest` dev/test only and resolved once.
- No speculative framework/plugin/compatibility architecture.

DOCUMENTATION MUST COVER
- install/prerequisites
- normal operations/status/doctor/logs
- security/Cloudflare/CrowdSec/SOPS+Age
- one recovery/rclone/offline-recovery workflow
- built-in HTTPS provider configuration + transient SMTP fallback
- CyberPanel/CyberPersons setup: canonical/alias naming, API-key/send permission, verified sending domain, SOPS token, separately configured SMTP credentials if using CyberPanel SMTP fallback; current official settings rechecked
- provider-catalog maintainer workflow: routine endpoint/auth/request/success/retry changes edit catalog + focused tests/docs; Python only for genuinely new capability
- version/update model
- developer/test/release workflow
- `vwctl --help` as executable command reference rather than giant generated manual

ACCEPTANCE EVIDENCE SHOULD COVER AT LEAST
- clean install/layout
- start/status/doctor
- SOPS/Age materialization without leakage
- Cloudflare fail-closed path + CrowdSec
- backup -> rclone publish -> remote verify -> download -> restore
- one configured built-in API success + representative transient SMTP fallback
- provider-catalog validation/security
- systemd units/timers
- pinned update path
- amd64/arm64 where environments are available, with gaps explicitly stated

CLEANUP REVIEW
- Remove obsolete V1 migration/archive compatibility, dashboard/TUI, Postfix queue tooling, multiple backup-tier product surfaces, obsolete aliases/wrappers/placeholders, and V1 test architecture when no longer required.
- Do not preserve old files just for history; `main`/git history is the reference.
- Prefer consolidation/deletion naturally without giant mixed-responsibility files.

OUTPUT
Verdict first, then: Release blockers, Important findings, Minor findings, Final-contract coverage, Security/recovery findings, Operator usability, Provider-catalog/CyberPanel maintainability, V1 cleanup/file-surface assessment, Acceptance/CI evidence, Safe post-beta deferrals, What I did not verify.

End by answering:
"Would I trust this V2 beta for a small team of about 10 users, is the documentation/acceptance evidence sufficient, and is this PR safe to merge/release within the documented scope?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Corrective PR: one observable V2 bug</strong></summary>

```text
Review PR <PR_URL> as a VaultWarden-OCI V2 corrective PR for one observable bug.

REVIEW MODE
- Review only. Do not modify or merge the PR.
- The expected change is intentionally narrow. Do not reward unrelated cleanup/refactoring as "helpful".

GATHER EVIDENCE
1. Read metadata/diff/changed files/reviews/CI.
2. Read root `AGENTS.md`, applicable durable V2 decisions, and the complete corrective prompt in `reports/V2-CODEX-PROMPTS.md`.
3. Reproduce/understand the observable failure at the stable/public boundary where practical and inspect the smallest owning code around it.

CORRECTIVE CONTRACT
- Fix one observable bug and its root cause in the smallest correct owner.
- Preserve current V2 architecture: Ubuntu 24.04 amd64/arm64, one CLI/operator-config/versions authority, SOPS/Age, rclone, static provider catalog + transient SMTP fallback, recovery, edge, exact versions.
- No V1 compatibility/dashboard/Postfix/custom queue/dynamic provider registry/framework/migration engine/speculative extension point.
- Prefer an existing owner; a new file requires a clear ownership/security reason.
- Add one highest-value behavioral regression test only if there is a real coverage gap.
- No source-string/order/prose-freezing/private-helper/custom-runner/coverage-quota test patterns.

EMAIL-PROVIDER BUG RULE
- First determine whether `email-providers.toml` is the correct owner.
- If the provider changed only endpoint/auth/request/success/retry/options representable in the closed catalog, the fix should normally be catalog-only plus focused test/docs.
- Do not rewrite notification Python or add a provider class/module for routine metadata changes.
- Conversely, do not weaken catalog security or add arbitrary HTTP scripting merely to fit a new provider behavior.
- If a genuinely new transport capability is required, the PR should explicitly identify the durable architecture conflict rather than silently widening it.

REVIEW QUESTIONS
- Is the reported bug actually fixed at the observable boundary?
- Is the root cause addressed, not merely the symptom?
- Is this the smallest coherent change?
- Did the PR add unrelated refactoring/framework/file proliferation?
- Is the regression test at the right layer and non-duplicative?
- Are security/recovery/secret-handling implications covered?
- If a provider bug: did the fix stay catalog-only where appropriate, and are official provider settings verified?

OUTPUT
Verdict first: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Blockers, Root-cause assessment, Correctness assessment, Regression-test assessment, Scope-creep/file-surface assessment, Provider-catalog assessment if relevant, Validation/CI, What I did not verify.

End by answering:
"Does this PR completely fix the stated observable bug with the smallest safe change and without widening V2 architecture unnecessarily?"
```

</details>
