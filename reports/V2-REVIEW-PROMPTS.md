# VaultWarden-OCI V2 — Standalone PR Review Prompts

Date: 2026-08-19
Status: reviewer utility; not an implementation source of truth.

## How to use

These prompts are for a **separate review agent** after an implementation/design PR is ready for review.

- Copy one complete fenced block into a fresh agent session.
- Replace `<PR_URL>` and `<ORIGINAL_PROMPT>`.
- The review agent reviews only. It must not push commits, edit the PR, merge it, or broaden the implementation unless the human explicitly asks afterward.
- `reports/V2-CODEX-PROMPTS.md` remains the authoritative V2 implementation contract. This file tells a reviewer how to audit a PR against that contract.

---

<details>
<summary><strong>Review Prompt A — Normal V2 phase / feature PR</strong></summary>

```text
Review PR <PR_URL>.

Original Prompt:
<ORIGINAL_PROMPT>

REVIEW MODE
- Review only. Do not modify code, push commits, update the PR, or merge it.
- Be skeptical but proportional. Do not invent work merely to produce findings.
- Judge the PR against the original prompt, current `v2` contract, and actual repository state—not hypothetical enterprise requirements.

FIRST, GATHER EVIDENCE
1. Read PR metadata, base/head refs, description, changed-file list, and complete diff.
2. Read existing review comments/threads and current CI/check status.
3. Read root `AGENTS.md` and `reports/V2-CODEX-PROMPTS.md`; identify the applicable phase/corrective contract.
4. Inspect surrounding base/head files when the diff alone is insufficient to understand ownership, security, or behavior.
5. If the original prompt conflicts with the authoritative V2 contract, call that out explicitly instead of silently choosing one.

REVIEW QUESTIONS
A. Completeness
- Did the PR implement every required behavior from the original prompt?
- Did it omit required validation, docs, config, permissions, failure handling, or operator diagnostics?
- Did it accidentally implement later-phase/non-goal work?

B. Correctness and safety
- Are failure paths correct and fail-closed where required?
- Are secrets kept out of ordinary config, provider catalog, argv, logs, exception text, and persistent temporary files?
- Are subprocess calls structured safely without shell interpolation where Python owns them?
- Are file ownership/permissions, locking, atomic replacement/publication, and state transitions safe for the changed behavior?
- For backup/restore: is recoverability real, verified before success, and protected against premature live mutation?
- For rclone: is normal publication non-destructive (`copy`/`copyto` style), remote verification required before offsite success, and pruning separate?
- For notifications: are supported built-in HTTPS providers handled through the source-controlled `email-providers.toml` catalog rather than repeated hard-coded library branches where catalog data is sufficient?
- Does the catalog include canonical `cyberpersons` / CyberPanel Email support, with `cyberpanel` only an alias to the same definition?
- Are provider endpoints HTTPS, provider templates closed/validated, credentials excluded from the catalog, and arbitrary operator endpoint/auth/header/payload overrides rejected?
- Are auth-bearing API requests protected from unsafe cross-host redirects?
- Is transient-only SMTP fallback correctly classified, TLS validation preserved, and no durable queue/dynamic plugin framework introduced?
- For Cloudflare/Docker ingress: does the supported iptables path really fail closed rather than relying on ordinary UFW INPUT assumptions?

C. Fit for this product
- Is the implementation suitable for roughly 10 users and a junior administrator?
- Is it understandable through `vwctl status`, `vwctl doctor`, and useful errors?
- Is there unnecessary framework/plugin/provider/compatibility/generalization work?
- Could the same behavior be owned by fewer cohesive files without making a giant mixed-responsibility file?
- Did the PR introduce thin wrappers, one-function modules, duplicate config authorities, one source module per provider, or speculative placeholders?

D. Tests and maintenance cost
- Are tests focused on security, availability, recoverability, or operator truthfulness?
- Are they at the smallest/highest-value layer?
- Do tests assert observable behavior rather than private source strings/order or duplicated state machines?
- For provider catalog changes, do focused tests cover catalog validation, rendering/auth shape, success/retry classification, redaction, and operator override restrictions without creating a generic provider conformance framework?
- Is important behavior untested?
- Conversely, did the PR add redundant/expensive tests that add little confidence?
- Do not request a coverage quota, custom test runner, or broad matrix without a concrete risk.

E. Scope and V1 influence
- Did the implementation copy V1 architecture when only a security property was needed?
- Did it reintroduce V1 migration/archive compatibility, Postfix queue machinery, dashboard/TUI, multiple backup tiers, or other rejected V2 surfaces?
- Did it preserve a V1 behavior only because it existed, rather than because V2 requires it?

F. Merge readiness
- Is CI complete and relevant?
- Are there unresolved review threads or known failures?
- Is the PR small/cohesive enough to review confidently?
- Is missing validation acceptable to defer to release acceptance, or required before merge?

OUTPUT FORMAT
Start with exactly one verdict:
- SAFE TO MERGE
- NEEDS CHANGES
- NOT READY / INCOMPLETE

Then provide:
1. `Blockers` — only issues that make merge unsafe/incomplete. Use `None` if none.
2. `Important findings` — concrete correctness/security/maintainability issues worth fixing before or soon after merge.
3. `Minor findings` — optional cleanups; do not inflate nits.
4. `Prompt coverage` — required items implemented, missing, and out-of-scope additions.
5. `Small-team / complexity assessment` — whether the design is appropriately simple and whether file/test surface grew unnecessarily.
6. `Validation / CI` — what ran, what failed/passed, and important validation not performed.
7. `What I did not verify` — explicit uncertainty rather than guessing.

For every finding, identify the affected file/area and explain the observable risk. Prefer evidence from the diff/current repository over stylistic preference.

Final question to answer explicitly:
"Is this PR complete, accurate, fit for a small team, and safe to merge?"
```

</details>

---

<details>
<summary><strong>Review Prompt B — Architecture / documentation / agent-contract PR</strong></summary>

```text
Review PR <PR_URL>.

Original Prompt:
<ORIGINAL_PROMPT>

REVIEW MODE
- Review only. Do not edit the branch/PR or merge it.
- Treat documentation as product architecture when it controls future agents.
- `reports/V2-CODEX-PROMPTS.md` is the implementation source of truth; supporting reports should not contradict it.

GATHER EVIDENCE
1. Read PR metadata, complete diff, changed files, review threads, and CI status.
2. Read every changed report/instruction file completely, not just patch hunks.
3. Check root `AGENTS.md`/branch context if relevant.
4. Search for stale references to deleted reports, old V1 requirements, superseded notification behavior, or conflicting precedence rules.

REVIEW FOR
- Internal consistency across prompts, architecture, audit, test strategy, reviewer prompts, and PR description.
- Standalone copy/paste usability of every Codex phase prompt.
- Correct phase sequencing and prerequisites.
- Greenfield boundary: no V1 migration/archive/runtime compatibility requirement.
- Python 3.12 stdlib-first + minimal Bash.
- Fewer cohesive files as a preference, not a numeric quota.
- One `vwctl`, one operator-editable TOML config authority, one `versions.toml`.
- SOPS + Age with operational + offline recovery identities.
- rclone first-class, verified copy-style publication, separate prune.
- Operational notifications: six explicit built-ins `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`; `cyberpanel` alias resolves to the same CyberPanel Email definition.
- `email-providers.toml` is source-controlled immutable release metadata, not a second operator config authority and not a secret store.
- Routine provider endpoint/auth/request/success/retry changes are catalog edits plus focused tests/docs rather than full library rewrites.
- Catalog schema is closed to the needs of supported providers: HTTPS endpoints, closed auth modes, JSON/form request templates using a fixed canonical field set, small success rule, retry statuses, declared non-secret provider options.
- Ordinary operator config cannot inject arbitrary endpoint/auth/header/payload values that could exfiltrate `email_api_token`.
- No `eval`, Jinja, arbitrary scripting, cross-host auth redirects, dynamic provider loading, Python entry points, provider SDK, or generic HTTP workflow engine.
- CyberPanel current baseline is grounded in official docs and re-verification is required at Phase 6: `POST https://platform.cyberpersons.com/email/v1/send`, Bearer API key with send permission, `202` + `success:true`, currently documented `429/500/503` transient candidates, and separate SMTP credentials if using `mail.cyberpersons.com:587` STARTTLS fallback.
- Direct authenticated SMTP fallback remains transient-only; no Postfix/custom durable queue.
- Cloudflare-first/CrowdSec one-path beta edge.
- One V2 recovery format.
- Small risk-based test architecture; no V1-style source-coupled test burden.
- Ordinary implementation agents cannot silently rewrite the authoritative prompt contract.

Also ask whether the report set itself is too large or duplicative. Do not preserve a report solely because it already exists.

OUTPUT
Start with one verdict: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Blockers, Important findings, Minor findings, Cross-document conflicts, Missing decisions, Agent-overengineering risks, Validation/CI, and What I did not verify.

End by answering:
"Will these documents reliably steer separate Codex sessions toward a small, secure, maintainable V2 without hidden contradictory instructions?"
```

</details>

---

<details>
<summary><strong>Review Prompt C — Corrective / bug-fix PR</strong></summary>

```text
Review PR <PR_URL>.

Original Prompt:
<ORIGINAL_PROMPT>

REVIEW MODE
- Review only; do not modify or merge the PR.
- The expected change is intentionally narrow.

CHECK
1. Confirm the observable bug and stable/public boundary affected.
2. Confirm the PR changes the smallest correct owner and addresses the root cause.
3. Check that the fix does not become an unrelated refactor/framework/compatibility expansion.
4. Verify a regression test was added only if there was a real coverage gap and that it tests behavior, not private source layout.
5. Check security/recovery/secret-handling implications of the specific fix.
6. For email-provider fixes, ask first whether `email-providers.toml` is the correct owner. A routine provider settings change should not trigger a notification-library rewrite.
7. Verify current CI and relevant focused validation.
8. Flag new files unless there is a clear ownership/security reason they could not live in an existing cohesive owner.

OUTPUT
Verdict: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Blockers, Root-cause assessment, Regression-test assessment, Scope-creep assessment, Validation/CI, and What I did not verify.

End by answering:
"Does this PR fix the reported bug completely with the smallest safe change?"
```

</details>

---

<details>
<summary><strong>Review Prompt D — Phase 8 / beta release readiness</strong></summary>

```text
Review PR <PR_URL> for V2 beta/release readiness.

Original Prompt:
<ORIGINAL_PROMPT>

REVIEW MODE
- Review only. Do not modify or merge the PR.
- This is a release-readiness review, not an invitation to add enterprise features.

GATHER
- PR metadata/diff/threads/CI.
- Current `v2` tree and root `AGENTS.md`.
- `reports/V2-CODEX-PROMPTS.md`, architecture, and test strategy.
- Release/host acceptance evidence and docs changed by the PR.

VERIFY END TO END
- Clean Ubuntu 24.04 install model is coherent for amd64 + arm64.
- `vwctl` is the single practical operator surface; status/doctor/logs are truthful.
- Config/version/secret authorities are singular and documented.
- SOPS + Age operational/offline recovery model is usable and secret-safe.
- Vaultwarden + Caddy hardening and Cloudflare/CrowdSec edge are coherent and fail closed where promised.
- Recovery creates a verified encrypted V2 point, publishes with non-destructive rclone semantics, verifies remote state, downloads/stages safely, and restores only after preflight.
- Operational HTTPS selection supports the six built-ins including CyberPanel Email/CyberPersons; `cyberpanel` is an alias, not a duplicated definition.
- `email-providers.toml` is safely maintainable: changing normal provider metadata does not require a library rewrite, but operators cannot use it/config to redirect secrets to arbitrary endpoints.
- Provider catalog validation is strict and the release contains no dynamic plugin/HTTP-script mechanism.
- Direct authenticated SMTP fallback is transient-only and no local durable queue exists.
- systemd automation invokes installed immutable code/config.
- Production versions are exact; `--use-latest` cannot silently create floating production state.
- Obsolete V1 migration/dashboard/Postfix queue/test architecture is absent from the V2 product surface.
- Documentation is enough for a junior admin and a maintainer updating provider settings without source-code archaeology.
- Permanent tests are proportional; destructive/full-host checks are release acceptance rather than a giant per-PR framework.

OUTPUT
Verdict: `SAFE TO MERGE`, `NEEDS CHANGES`, or `NOT READY / INCOMPLETE`.
Then: Release blockers, Security/recovery findings, Operator usability findings, Complexity/file/test-surface findings, Acceptance/CI evidence, Deferred post-beta items that are genuinely safe to defer, and What I did not verify.

End by answering:
"Would I trust this V2 beta for a small team of about 10 users, and is it safe to merge/release within the documented scope?"
```

</details>
