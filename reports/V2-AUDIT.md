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

**V2 implication:** retain SOPS + Age, but do not rebuild a custom secrets manager, KMS abstraction, schema framework, or cryptography layer around it.

## 6. Email: keep useful API coverage, remove Postfix/queue complexity, and move changing provider metadata out of code

V1's Postfix sidecar brings mutable queue state, capabilities, inspection/mutation commands, health logic, retry/dead-letter concerns, tests, and documentation. That is disproportionate to the V2 beta requirement.

V1's HTTP API work is useful. V1 `docs/EMAIL.md` documents:

- `mailersend`;
- `sendgrid`;
- `mailgun`;
- `postmark`;
- `resend`.

V1 `lib/email.sh` additionally contains a `cyberpersons` driver. CyberPanel Email / CyberPersons is now an **explicitly approved V2 built-in**, with `cyberpanel` accepted only as an alias to the same definition.

Current official CyberPanel Email documentation verified on 2026-08-19 supports the current baseline:

- `POST https://platform.cyberpersons.com/email/v1/send`;
- recommended Bearer API-key authentication;
- `can_send` permission with optional domain/IP restrictions;
- request fields including `from`, `to`, `subject`, and `html` or `text`;
- HTTP `202` plus `success: true` for an accepted send;
- HTTP `429 rate_limit_exceeded`, whose response includes a `retry_after` field;
- HTTP `503 service_unavailable`, documented as a temporary infrastructure condition;
- HTTP `500 send_failed`, whose troubleshooting causes include recipient rejection, invalid recipients, and blocklisted domains;
- separate SMTP credentials at `mail.cyberpersons.com:587` with required STARTTLS.

The earlier report wording that grouped CyberPersons `500` with clearly transient failures was too broad. **V2 must not classify CyberPersons HTTP 500 as transient by status alone.** It remains visible and does not trigger SMTP fallback merely because it is a 500. CyberPersons `429` and `503` are the currently documented retryable/transient statuses for the V2 baseline; implementation must re-verify current provider documentation before coding.

The current docs say 429 includes `retry_after` but the reviewed material does not define enough delay semantics to require parsing it. A fixed small bounded retry schedule is acceptable. A future implementation may consume a provider body delay only through a narrowly bounded catalog capability when official docs define the field and units clearly.

The V2 product has two mail use cases:

- Vaultwarden application mail;
- project operational notifications.

**V2 implication:** Vaultwarden uses direct authenticated SMTP. Project notifications support six explicit built-ins through one static source-controlled `email-providers.toml`; the operator selects a provider and supplies credentials through SOPS. Direct authenticated SMTP is the fallback only for failures clearly classified as transient after bounded retry. Do not recreate Postfix/local queue machinery.

### Provider-maintenance lesson

Hard-coding provider endpoint/header/body/success/retry details into separate Python drivers makes routine upstream changes unnecessarily expensive. Allowing arbitrary operator-defined endpoints/authentication creates the opposite problem: a credential-exfiltration surface and a generic HTTP engine.

**V2 implication:** keep one closed source-controlled provider catalog shipped with the immutable release.

The canonical provider-template message context is exactly:

```text
from_email
from_name
from_header
to_email
subject
text
```

Provider templates map those values to the provider's external field names. Supporting/reviewer documents must not invent alternate canonical names.

Routine endpoint/auth/request/success/retry changes should be **catalog edits plus focused tests/docs**, not a notification-library rewrite. Python changes are justified only when a provider introduces a genuinely new transport capability that the closed catalog cannot safely represent.

The static catalog is not a dynamic provider registry: no `eval`, arbitrary template language, entry-point discovery, dynamic imports, provider SDK, or arbitrary user-supplied provider code.

## 7. rclone is useful delegation, not overengineering

rclone reduces project complexity by providing provider-neutral remote storage behavior without project-owned object-storage APIs. The risk is destructive synchronization semantics, not rclone itself.

**V2 implication:** keep rclone first-class. Publish only verified recovery points using non-destructive copy/copyto-style semantics, verify remote presence before success, and make deletion/pruning a separate explicit operation.

## 8. Backup/recovery accumulated compatibility products instead of one recovery contract

V1 supports multiple backup/recovery tiers and migration/compatibility behavior. That expands code, tests, docs, and operator choices.

**V2 implication:** one encrypted V2 recovery-point format plus separate offline recovery material. Restore validates/decrypts/checks/stages before live mutation and health-gates any requested restart. No V1 reader or permanent db/full/emergency public tier model.

## 9. Locking and operation state are more complex than the V2 concurrency requirement

V1 contains process identity, lock-holder, metadata, and operation-specific concurrency machinery.

**V2 implication:** begin with one global mutating `fcntl.flock` lock. Read-only commands do not take it. Do not add per-operation/distributed locking until a demonstrated need exists.

## 10. Dashboard/health duplicated operator surfaces

The dashboard and large health subsystem create another UI/API/testing surface.

**V2 implication:** no beta dashboard/TUI. Make `vwctl status`, read-only `vwctl doctor [--json]`, and ordinary system/container logs the operator surfaces. Do not turn doctor into a repair framework.

## 11. Docker ingress requires a precise packet-path contract

Docker-published ports are not governed like ordinary UFW `INPUT` traffic. A design that says "UFW protects 443" without accounting for Docker's packet path is misleading.

**V2 implication:** support one explicit beta model: Cloudflare-proxied Caddy, Docker bridge networking, Docker iptables packet filtering, one small project-owned Cloudflare-source ingress path, validated Cloudflare IPv4/IPv6 ranges, bounded last-known-good state, and fail-closed behavior. Do not implement multiple firewall backends in beta.

## 12. CrowdSec should be integrated at one clear beta remediation scope

V1 uses both a firewall bouncer and a Cloudflare Workers bouncer. That makes sense for different traffic classes, but carrying both into V2 by default would create more installation, credentials, rules, diagnostics, and review surface than the stated beta product requires.

For a Cloudflare-fronted web application, the important web-client remediation point is Cloudflare; the local origin sees Cloudflare as the network peer. Separately, the project-owned iptables path must restrict Caddy origin ingress to validated Cloudflare ranges.

**V2 implication:** keep the CrowdSec Security Engine and use one current supported CrowdSec Cloudflare remediation integration for proxied web decisions. Do **not** make a CrowdSec host firewall bouncer a beta requirement. SSH/other host-visible services remain protected by provider firewall/security-group and host firewall policy. If future requirements add CrowdSec remediation for host services, make that a separate architecture decision rather than silently overlapping the web path.

## 13. Version resolution should have one owner

Scattered version checks and "latest" branches increase drift and make production state less reproducible.

**V2 implication:** one `versions.toml`; production exact pins; `--use-latest` resolves once for a development/test run, freezes exact values, records them, and passes only those exact values downstream.

## 14. Documentation complexity mirrors product complexity

V1 documentation is thorough, but it must explain many scripts, Make targets, backup tiers, migration paths, Postfix queue behavior, dashboard flows, synchronization rules, and compatibility surfaces.

**V2 implication:** shrink the supported product first. Keep a small operator/developer documentation set and use `vwctl --help` plus stable doctor JSON/check IDs as executable references. Developer docs should explain safe provider-catalog maintenance so ordinary upstream changes do not require library surgery.

## 15. Standalone phase prompts need explicit prerequisites

Because each implementation prompt is pasted into a fresh agent session, the top-level instruction to run phases in order is not enough by itself.

**V2 implication:** every Phase N prompt for N > 0 explicitly verifies Phase N-1 is present. If the immediate prerequisite is missing, the agent stops and reports it rather than implementing two phases at once. In particular, Phase 5 requires Phase 4, Phase 7 requires Phase 6, and Phase 8 requires Phase 7.

## 16. File proliferation is a symptom worth watching

V1 complexity is not only line count; it is also the number of public scripts, helpers, wrappers, config fragments, tests, and duplicated ownership boundaries a maintainer must understand.

**V2 implication:** prefer fewer cohesive first-party files when natural. Do not create one-function modules or wrapper scripts for architectural neatness. A single provider catalog is preferable to one module/file per email provider. This is not a file-count quota.

## Highest-risk ways to recreate V1 complexity

1. treating V1 implementation shape as a compatibility requirement;
2. turning the static built-in email catalog into arbitrary runtime plugins or a general HTTP engine;
3. hard-coding routine provider metadata into many Python functions;
4. treating ambiguous provider failures as transient and masking them with SMTP fallback;
5. letting agents add frameworks/queues for hypothetical future flexibility;
6. coupling tests to private source structure again;
7. multiplying operator-editable config/state authorities;
8. using destructive remote synchronization as ordinary backup publication;
9. supporting several ingress/firewall modes before the golden path is stable;
10. installing multiple CrowdSec remediation planes without a product requirement;
11. keeping V1 migration/archive compatibility despite the greenfield decision;
12. adding a new file/module/script for every small behavior;
13. allowing supporting reports, review prompts, or `AGENTS.md` to become competing sources of truth;
14. relying on unstated phase ordering instead of explicit standalone prerequisites.

## Recommendation

Merge the design reports into `v2` only after their independent review finds the implementation and reviewer contracts internally consistent. Then run **Prompt 0 only**. Review its concise `AGENTS.md`, product boundary, and durable decisions before Phase 1 runtime work begins.

The audit has served its purpose if later agents preserve V1's important security/recovery properties without importing the machinery that made those properties expensive to evolve.