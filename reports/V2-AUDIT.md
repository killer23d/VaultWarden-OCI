# VaultWarden-OCI V2 Greenfield Audit

Date: 2026-08-19
Audit snapshot: `main` at `16dc4c82a57234f8de8b54aa709a8ef32831f4e6`
Status: historical/evidence report for the V2 redesign.

> **Authority:** `reports/V2-CODEX-PROMPTS.md` controls agent execution. `reports/V2-ARCHITECTURE-PROPOSAL.md` describes the current target design. This audit explains why V2 is intentionally different from V1.

## Executive conclusion

V1 contains substantial security and operational engineering, but its implementation accumulated enough shell code, public surfaces, compatibility behavior, state synchronization, recovery variants, email-queue machinery, and implementation-coupled testing that further incremental evolution would carry much of that complexity into V2.

V2 should therefore be a **greenfield implementation, not a mechanical refactor**. Preserve important security/recovery properties; do not preserve V1 implementation shape simply because it exists.

The long-lived V2 development branch is `v2`. V1 `main` remains useful as historical/security reference while V2 is built.

## Audit assumptions

The redesign assumes:

- fresh install; no V1 data/state/archive migration requirement;
- Ubuntu 24.04 LTS Noble only;
- amd64 and arm64 first-class targets;
- small-team/junior-admin operation;
- cloud-provider-neutral runtime;
- OCI A1 Flex reference deployment only;
- Cloudflare-first production ingress;
- CrowdSec retained;
- `--use-latest` retained for development/testing only;
- reducing ongoing maintenance/test cost is an explicit design objective.

## 1. Project code surface became too fragmented and too stateful for shell

Examples from the audited V1 tree include approximately:

- `lib/secrets.sh` ~98 KB;
- `lib/migrate.sh` ~91 KB;
- `utilities/backup-run.sh` ~100 KB;
- `utilities/restore-run.sh` ~157 KB;
- `utilities/setup-secrets.sh` ~119 KB;
- `utilities/setup-crowdsec.sh` ~102 KB;
- `maintenance-health.sh` ~58 KB;
- `dashboard.sh` ~43 KB;
- a very broad Makefile/operator surface.

The issue is not that Bash is inherently unsafe. The issue is that structured application behavior—configuration, state machines, retries, manifests, locking, diagnostics, recovery orchestration—has grown beyond the point where shell is the cheapest owner to reason about and test.

**V2 implication:** Python 3.12 stdlib-first for structured logic; Bash only minimal bootstrap/host/container glue.

## 2. V1 instruction files would cause an agent to recreate V1

The V1 root `AGENTS.md` correctly protects V1 behavior, but those instructions conflict with the greenfield V2 objective. They preserve Bash-oriented architecture, Postfix/queue behavior, multiple backup tiers, current operation/test machinery, and compatibility surfaces.

**V2 implication:** Phase 0 must replace V1-oriented agent instructions before runtime code is generated. Root `AGENTS.md` should become a concise map to the authoritative standalone phase prompts, not a second architecture manual.

## 3. Test architecture is a major maintenance multiplier

The tracked V1 `tests/` tree is approximately 1.18 MB across 30 files. Against the audited first-party shell/Make implementation set (~1.94 MB), that is roughly 61% by byte size. This is only a maintenance-footprint signal—not LOC, complexity, or engineering effort—but it matches the observed development burden.

More importantly, many large tests are coupled to private implementation shape. Common patterns include:

- grep assertions against exact private source strings;
- source-order assertions;
- extracting private Bash functions with `awk`/`sed`;
- synthetic harnesses around private state;
- large mocks that reproduce internal control flow.

The canonical test runner also became a product of its own: logical/physical inventories, modes, timeouts, fixture rewrites, compatibility handling, and registry validation. Real-host acceptance similarly accumulated controller/checkpoint behavior.

**V2 implication:** do not port the V1 test corpus or custom runner. Use focused unit tests, small integration tests, and disposable-host release acceptance. Test public risk, not private source layout.

## 4. Configuration and runtime state have too many authorities

V1 devotes substantial logic to parsing, validating, synchronizing, and reconciling environment/config/install state.

**V2 implication:** one installed operator-editable non-secret TOML config, one source-controlled versions manifest, one structured SOPS-encrypted secrets document, one operational Age identity, volatile decrypted runtime secrets, immutable installed application releases, and only narrowly scoped source-controlled release metadata where it materially reduces code complexity. `email-providers.toml` is such release metadata; it is not a second operator config authority.

Avoid chains of repository `.env` -> installed env -> generated env and duplicate operator-editable authorities.

## 5. Secret handling is worth keeping, but the surrounding framework is not

SOPS + Age remains a strong fit for the V2 goals: structured encrypted secrets, offline recovery, cloud neutrality, and no always-on secrets service.

The V1 lesson is to keep the cryptographic responsibility external and shrink project orchestration.

**V2 implication:** retain SOPS + Age, but do not rebuild a custom secrets manager, KMS abstraction, schema framework, or cryptography layer around it.

## 6. Email: keep useful API coverage, remove Postfix/queue complexity, move changing provider details out of code

V1's Postfix sidecar brings mutable queue state, capabilities, inspection/mutation commands, health logic, retry/dead-letter concerns, tests, and documentation. That is disproportionate to the V2 beta requirement.

The V1 HTTP API work itself is useful. V1 `docs/EMAIL.md` documents these public provider identifiers:

- `mailersend`;
- `sendgrid`;
- `mailgun`;
- `postmark`;
- `resend`.

V1 `lib/email.sh` also contains a `cyberpersons` driver pointing at `https://platform.cyberpersons.com/email/v1/send`. It was not listed in the V1 public email docs or `.env.example`, so the earlier audit correctly treated it as undocumented rather than automatically supported.

That product decision has now changed explicitly for V2: **CyberPanel Email / CyberPersons is a supported V2 built-in.** Current official CyberPanel Email documentation verified on 2026-08-19 confirms the service and endpoint are active and documents:

- `POST https://platform.cyberpersons.com/email/v1/send`;
- recommended Bearer API-key authentication;
- API keys with `can_send` permission and optional domain/IP restrictions;
- JSON `from`, `to`, `subject`, and `html` or `text` message fields;
- HTTP `202` plus `success: true` on accepted send;
- `429` rate-limit responses and `500`/`503` service failures as retry candidates;
- `400` invalid-request and `403` domain/account/permission failures as configuration/permanent failures;
- separate SMTP credentials at `mail.cyberpersons.com:587` with required STARTTLS.

V2 should use canonical provider ID `cyberpersons` and accept `cyberpanel` as an alias to the same definition, not maintain two copies.

The actual V2 product still has two mail use cases:

- Vaultwarden application mail;
- project operational notifications.

**V2 implication:** Vaultwarden uses direct authenticated SMTP. Project operational notifications support six explicit built-ins: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, and `cyberpersons`/`cyberpanel` alias. The operator selects one and supplies the API token/configuration. Direct authenticated SMTP is the bounded fallback for clearly transient API failures. Do not recreate Postfix/local queue machinery.

### Provider-maintenance lesson

Hard-coding every provider endpoint/header/body/success/retry detail into Python would make routine upstream API changes unnecessarily expensive. At the same time, allowing arbitrary operator-defined endpoints/authentication would turn a convenience feature into a credential-exfiltration risk and a generic HTTP framework.

**V2 implication:** put the six built-in definitions in one source-controlled, non-secret `email-providers.toml` shipped with the immutable release.

The catalog should carry only the closed metadata the six supported providers actually need: HTTPS endpoint/template, closed auth mode, JSON/form request template using a fixed canonical message-field set, success rule, provider-documented retry statuses, aliases, and declared non-secret provider options. Secrets remain in SOPS; ordinary operator config can select a built-in and allowed options but cannot replace endpoint/auth/payload definitions arbitrarily.

Routine endpoint/auth/request/success/retry changes should therefore be **catalog edits plus focused tests/docs**, not a notification-library rewrite. Python changes are justified only when a provider introduces a genuinely new transport capability that the closed catalog cannot represent safely.

This static catalog is not a dynamic provider registry: no `eval`, arbitrary template language, entry-point discovery, dynamic imports, provider SDK, or arbitrary user-supplied provider code.

## 7. rclone is useful delegation, not overengineering

Unlike several V1 subsystems, rclone reduces project complexity by providing provider-neutral remote storage behavior without project-owned object-storage APIs.

The risk is destructive synchronization semantics, not rclone itself.

**V2 implication:** keep rclone first-class. Publish only verified recovery points using non-destructive copy/copyto-style semantics, verify remote presence before success, and make deletion/pruning a separate explicit operation.

## 8. Backup/recovery accumulated compatibility products instead of one recovery contract

V1 supports multiple backup/recovery tiers and migration/compatibility behavior. That expands code, tests, docs, and operator choices.

Because V2 is greenfield, V1 archive readers and migration machinery are unnecessary product surface.

**V2 implication:** one encrypted V2 recovery-point format plus separate offline recovery material. Restore validates/decrypts/checks/stages before live mutation and health-gates any requested restart. No V1 reader or permanent db/full/emergency public tier model.

## 9. Locking and operation state are more complex than the V2 concurrency requirement

V1 contains process identity, lock-holder, metadata, and operation-specific concurrency machinery.

**V2 implication:** begin with one global mutating `fcntl.flock` lock. Read-only commands do not take it. Do not add per-operation/distributed locking until a demonstrated need exists.

## 10. Dashboard/health duplicated operator surfaces

The dashboard and large health subsystem create another UI/API/testing surface.

**V2 implication:** no beta dashboard/TUI. Make `vwctl status`, read-only `vwctl doctor [--json]`, and ordinary system/container logs the operator surfaces. Do not turn doctor into a repair framework.

## 11. Docker ingress requires a precise packet-path contract

Docker-published ports are not governed like ordinary UFW `INPUT` traffic. A design that says "UFW protects 443" without accounting for Docker's packet path is misleading.

**V2 implication:** support one explicit beta model: Cloudflare-proxied Caddy, Docker bridge networking, Docker iptables packet filtering, one small project-owned ingress path, validated Cloudflare IPv4/IPv6 ranges, bounded last-known-good state, and fail-closed behavior. Do not implement multiple firewall backends in beta.

## 12. CrowdSec should be integrated, not reimplemented

CrowdSec remains useful, but the large V1 setup surface shows the cost of owning too much of an upstream product's installation lifecycle.

**V2 implication:** prefer current upstream installation/integration and own only project-specific acquisitions/config, credentials, selected bouncers, lifecycle hooks, and diagnostics.

## 13. Version resolution should have one owner

Scattered version checks and "latest" branches increase drift and make production state less reproducible.

**V2 implication:** one `versions.toml`; production exact pins; `--use-latest` resolves once for a development/test run, freezes exact values, records them, and passes only those exact values downstream.

## 14. Documentation complexity mirrors product complexity

V1 documentation is thorough, but it must explain many scripts, Make targets, backup tiers, migration paths, Postfix queue behavior, dashboard flows, synchronization rules, and compatibility surfaces.

**V2 implication:** shrink the supported product first. Keep a small operator/developer documentation set and use `vwctl --help` plus stable doctor JSON/check IDs as executable references instead of maintaining giant generated/reference documents. Developer docs should explain how to safely maintain the provider catalog so ordinary upstream email API changes do not require library surgery.

## 15. File proliferation is a symptom worth watching

V1 complexity is not only line count; it is also the number of public scripts, helpers, wrappers, config fragments, tests, and duplicated ownership boundaries an operator/maintainer must understand.

**V2 implication:** prefer fewer cohesive first-party files when natural. Do not create one-function modules or wrapper scripts for architectural neatness. A single provider catalog is preferable to one module/file per email provider. This is not a file-count quota: clear responsibility, security isolation, and readability are more important than an artificially low number.

## Highest-risk ways to recreate V1 complexity

1. treating V1 implementation shape as a compatibility requirement;
2. turning the static built-in email catalog into arbitrary runtime plugins or a general HTTP engine;
3. hard-coding routine provider metadata back into many Python functions so every endpoint/settings change becomes a library rewrite;
4. letting agents add frameworks/queues for hypothetical future flexibility;
5. coupling tests to private source structure again;
6. multiplying operator-editable config/state authorities;
7. using destructive remote synchronization as ordinary backup publication;
8. hiding notification configuration/security failures behind unconditional SMTP fallback;
9. supporting several ingress/firewall modes before the golden path is stable;
10. keeping V1 migration/archive compatibility despite the greenfield decision;
11. adding a new file/module/script for every small behavior instead of preserving cohesive ownership;
12. allowing supporting reports or `AGENTS.md` to become competing sources of truth.

## Recommendation

Merge the design reports into `v2`, then run **Prompt 0 only**. Review its concise `AGENTS.md`, product boundary, and durable decisions before Phase 1 runtime work begins.

The audit has served its purpose if later agents preserve V1's important security/recovery properties without importing the machinery that made those properties expensive to evolve.