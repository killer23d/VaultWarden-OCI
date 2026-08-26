# VaultWarden-OCI V2 — PR-Specific Standalone Review Prompts

Date: 2026-08-19
Status: reviewer utility; not an implementation source of truth.

## How to use

These prompts are for a **separate review agent** after a V2 PR is ready for review.

- Expand the prompt matching the PR/phase.
- Copy the **entire fenced block** into a fresh review-agent session.
- For Phase 0–8/corrective prompts, replace only `<PR_URL>`.
- The current design/report PR prompt already contains PR #333 and can be pasted as-is.
- No `<ORIGINAL_PROMPT>` is required: each review prompt embeds the expected phase outcome and review criteria.
- The review agent reviews only. It must not push commits, edit the PR, resolve threads, or merge unless a human explicitly asks afterward.
- `reports/CODEX-PROMPTS.md` remains the authoritative implementation-agent contract.
- These prompts are **reviewer mirrors, not a second normative specification**. The reviewer must read the applicable authoritative phase prompt from `V2-CODEX-PROMPTS.md`. If any detail here differs, the authoritative implementation prompt wins and the stale review prompt is itself a finding.

Every review must inspect current PR metadata/diff, current CI/check status, and existing review threads before returning a merge verdict.

---

<details>
<summary><strong>Review Prompt — Current V2 design/report PR #333</strong></summary>

```text
Review PR https://github.com/killer23d/VaultWarden-OCI/pull/333.

PURPOSE
This is the V2 greenfield design/report PR targeting `v2`. It is documentation/design only. It establishes the authoritative standalone Codex prompts plus supporting architecture/audit/test/review documents before Phase 0 implementation.

REVIEW MODE
- Review only. Do not modify files, push commits, update the PR, resolve threads, or merge it.
- Be skeptical but proportional. Do not invent enterprise requirements.
- Treat the reports as architecture because they steer future independent Codex sessions.

GATHER EVIDENCE
1. Read PR metadata, base/head refs, description, changed-file list, complete diff, current CI/check status, reviews/comments/threads.
2. Read all five reports completely:
   - `reports/CODEX-PROMPTS.md`
   - `reports/V2-ARCHITECTURE-PROPOSAL.md`
   - `reports/V2-AUDIT.md`
   - `reports/TEST-STRATEGY.md`
   - `reports/REVIEW-PROMPTS.md`
3. Inspect V1/main only where needed to verify audit evidence.
4. Search for stale requirements: one selected email provider, five-provider list, direct-SMTP-only operational mail, Postfix preservation, V1 migration compatibility, host-firewall-bouncer beta requirement, deleted-report precedence, or conflicting source-of-truth rules.

AUTHORITATIVE EXPECTATIONS
- `V2-CODEX-PROMPTS.md` is the implementation-agent source of truth.
- Phase 0–8 and corrective prompts are standalone copy/paste blocks.
- Every Phase N > 0 explicitly verifies Phase N-1 is present; a fresh pasted session must not depend on the top-of-file sequencing prose.
- Ordinary phase agents cannot edit the authoritative prompt contract.
- Root `AGENTS.md` becomes a concise V2 map in Phase 0, not another architecture authority.
- Greenfield: no V1 state/archive/backup-format/migration/command/runtime-layout compatibility.
- Ubuntu 24.04 LTS; amd64 + arm64; cloud-neutral runtime; OCI A1 Flex reference only.
- Python 3.12 stdlib-first structured logic; Bash minimal glue.
- Prefer fewer cohesive first-party files without a numeric file-count quota.
- One `vwctl`, one operator-editable TOML config authority, one `versions.toml`.
- SOPS + Age with root-only operational identity, separate offline recovery material, volatile decrypted secrets.
- rclone first-class: local verify -> copy/copyto publication -> remote verify -> success; pruning separate.
- Vaultwarden mail uses direct authenticated SMTP.
- Operational API built-ins: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`; `cyberpanel` is an alias only.
- Phase 6 uses one immutable source-controlled non-secret `email-providers.toml` so routine provider changes are data edits, not library rewrites.
- Canonical provider-template message fields are exactly: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- Catalog/operator config cannot inject arbitrary endpoints/auth/headers/payload/success/retry behavior; no executable template language/dynamic plugin system.
- Authorization-bearing requests do not silently follow unsafe cross-host redirects.
- CyberPersons current baseline: 429 and 503 transient/retryable; 500 `send_failed` is not transient/fallback-eligible by HTTP status alone. Body `retry_after` is not required unless current official docs define usable delay semantics/units.
- SMTP fallback is only for clearly transient API failure after bounded retry; no blanket all-5xx fallback, Postfix, local MTA, or durable queue.
- Cloudflare-only origin Caddy ingress uses one Docker bridge/iptables path with validated ranges, bounded last-known-good state, fail closed.
- CrowdSec beta uses one Cloudflare remediation scope for proxied web clients. A CrowdSec host firewall bouncer is not a beta requirement.
- One encrypted V2 recovery format + offline recovery material.
- Exact production pins; `--use-latest` development/testing only.
- Three validation layers: focused unit, small integration, disposable-host release acceptance; no custom V1-style test runner or coverage quota.

REVIEW QUESTIONS
1. Are all five reports internally consistent?
2. Are all Phase 0–8 implementation prompts and the corrective prompt genuinely standalone?
3. Does every Phase N > 0 explicitly require Phase N-1?
4. Is the canonical provider-message vocabulary identical wherever it is repeated?
5. Is CyberPersons 500 correctly kept out of status-only transient fallback?
6. Does retry-delay handling stay narrowly bounded rather than becoming JSONPath/expression infrastructure?
7. Is CrowdSec clearly one beta remediation scope rather than two ambiguous mandatory bouncers?
8. Could a fresh agent accidentally reintroduce V1 Postfix, migration/archive compatibility, dashboard/TUI, backup tiers, generic provider plugins, multiple firewall backends, or source-coupled test architecture?
9. Does `email-providers.toml` reduce future provider maintenance without becoming a credential-exfiltration or arbitrary-HTTP mechanism?
10. Is the design proportionate for roughly 10 users and a junior administrator?
11. Does the PR remain documentation/design only?

OUTPUT
Start with exactly one verdict:
- SAFE TO MERGE
- NEEDS CHANGES
- NOT READY / INCOMPLETE

Then provide:
1. Blockers
2. Important findings
3. Minor findings
4. Cross-document conflicts/stale wording
5. Agent-overengineering risks
6. Small-team/complexity assessment
7. Validation/CI
8. What I did not verify

For each finding, identify the affected file/section and observable downstream risk.

End by answering exactly:
"Are these V2 reports complete, accurate, internally consistent, fit for a small team, and safe to merge into `v2` as the architecture/agent contract?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 0 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 0.

REVIEW MODE
- Review only; do not modify or merge.
- Read the Phase 0 block in `reports/CODEX-PROMPTS.md`; it is authoritative if this reviewer summary ever differs.

GATHER
- PR metadata/base/head/diff/CI/review threads.
- Root `AGENTS.md` before/after.
- V2 product/decision documents created or changed.

EXPECTED PHASE 0 OUTCOME
- Documentation/contract only; no production runtime code, Compose, installer, provider catalog implementation, or CI redesign.
- Root `AGENTS.md` is a concise V2 map pointing agents to the authoritative standalone prompts and durable decisions.
- Greenfield/no-V1-compatibility boundary is explicit.
- Python-first/Bash-minimal boundary is recorded.
- One operator TOML config authority, one versions authority, SOPS/Age operational/offline recovery model, canonical encrypted-secret path, one V2 recovery format, rclone non-destructive publication, bounded tests are recorded.
- Edge decision: Cloudflare-only origin ingress on one Docker iptables path; CrowdSec web remediation through Cloudflare only in beta; no host firewall bouncer requirement.
- Notification decision: six canonical providers, `cyberpanel` alias, one future `email-providers.toml`, exact canonical message fields `from_email|from_name|from_header|to_email|subject|text`, transient-only SMTP fallback, CyberPersons 500 non-transient-by-status, no Postfix/queue/dynamic plugin framework.
- Decision docs are consolidated rather than one ADR file per bullet unless separation has a real ownership reason.

CHECK
1. Did Phase 0 remove V1-oriented agent instructions that would recreate V1?
2. Are architecture decisions complete enough for Phase 1 without implementing later phases?
3. Did it create unnecessary ADR/index/template tooling or too many documents?
4. Are secret/config authorities singular and unambiguous?
5. Are notification/CrowdSec decisions consistent with the authoritative prompt?
6. Was the large V1 suite avoided unless repository enforcement required it?

OUTPUT
Verdict: SAFE TO MERGE / NEEDS CHANGES / NOT READY / INCOMPLETE.
Then: Blockers, Important findings, Scope compliance, Contract consistency, File-surface assessment, Validation/CI, What I did not verify.

End: "Is this Phase 0 PR complete and safe to merge before Phase 1 starts?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 1 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 1.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 1 prompt in `reports/CODEX-PROMPTS.md`.

PREREQUISITE CHECK
- Verify Phase 0 is already present on the PR base: V2 `AGENTS.md`, product boundary, and durable decisions. Missing Phase 0 is a blocker; Phase 1 must not recreate it implicitly.

EXPECTED PHASE 1 OUTCOME
- Small Python 3.12 stdlib-first `vwctl` foundation only.
- Help/version, config validation, versions output, read-only doctor skeleton.
- Exact architecture normalization for amd64/x86_64 and arm64/aarch64 with clear unsupported failure.
- One argv-array subprocess helper; no shell interpolation.
- One global `fcntl.flock` mutation primitive; read-only commands do not take it.
- Stable doctor IDs + PASS/WARN/FAIL/SKIP + JSON shape.
- No Docker/root install/SOPS execution/email/rclone/firewall/backup/systemd/update implementation.
- No speculative later-phase modules, plugin registries, or wrapper proliferation.

CHECK
- Is runtime stdlib-only unless a concrete dependency is justified?
- Are TOML/version errors safe and understandable?
- Is lock contention tested with real temporary resources?
- Are tests behavior-based and small?
- Did the PR create more files/modules than the ownership model needs?

OUTPUT
Verdict, Blockers, Important findings, Prompt coverage, Small-team/file assessment, Tests/CI, What I did not verify.

End: "Is this Phase 1 PR complete, minimal, and safe to merge before Phase 2?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 2 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 2.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 2 prompt.

PREREQUISITE CHECK
- Verify Phase 1 is on the base: `vwctl`, config/versions parsing, architecture mapping, subprocess helper, doctor skeleton, and global lock. Missing Phase 1 is a blocker.

EXPECTED PHASE 2 OUTCOME
- Clean Ubuntu 24.04 amd64/arm64 bootstrap + immutable installed application layout.
- One minimal bootstrap; structured install behavior remains Python-owned.
- `/opt/vaultwarden-oci/releases/<release>/` + `current`, `/etc/vaultwarden-oci/config.toml`, Phase 0 Age/secrets paths, required `/var/lib` state and `/run` volatile state.
- Installed release layout can carry immutable resources such as future `email-providers.toml` without making them operator config.
- Re-run safety and fail-visible ownership/path conflicts.
- Only minimal lifecycle-addressing systemd integration; permanent timers remain Phase 6.
- No runtime containers, secrets decryption, edge/CrowdSec, recovery/rclone, notifications/catalog, or updates.

CHECK
- Are permissions/ownership centralized and safe?
- Is bootstrap thin rather than another shell application?
- Is same-release idempotency behavior real?
- Did it create unnecessary scripts/wrappers/path constants?
- Are focused path/permission/temp-root tests sufficient?

OUTPUT
Verdict, Blockers, Important findings, Prompt coverage, Install/security assessment, File/test assessment, Validation/CI, What I did not verify.

End: "Is this Phase 2 PR a safe, minimal installed foundation for Phase 3?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 3 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 3.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 3 prompt.

PREREQUISITE CHECK
- Verify Phase 2 installed layout, config path, canonical secrets/Age paths, and installed `vwctl` are already present. Missing Phase 2 is a blocker.

EXPECTED PHASE 3 OUTCOME
- Compose/runtime contains Vaultwarden + Caddy only.
- Useful container hardening retained where compatible.
- One SOPS-encrypted structured secret document, root-only operational Age identity, separate offline recovery recipient/material, volatile-only plaintext materialization.
- Secrets do not leak to ordinary TOML, argv, logs, or persistent temporary files.
- `vwctl start|stop|restart|status|logs` owns lifecycle.
- Vaultwarden application mail uses direct authenticated SMTP; no Postfix.
- Caddy reverse proxy/DNS-01 setup only; Phase 4 owns ingress/CrowdSec enforcement.
- No project notification API/catalog, backup/rclone, or update work.

CHECK
- Are secrets actually absent from persistent/operator-readable surfaces?
- Are Compose capabilities/users/read-only/tmpfs/log/health constraints sensible?
- Is lifecycle truthful on failure?
- Did the PR avoid carrying V1 Postfix/queue architecture forward?
- Are tests at config/render/materialization/lifecycle boundaries rather than private source layout?

OUTPUT
Verdict, Blockers, Security findings, Prompt coverage, Complexity/file assessment, Validation/CI, What I did not verify.

End: "Is this Phase 3 runtime/secrets PR safe to merge before edge enforcement is added?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 4 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 4.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 4 prompt and current upstream CrowdSec docs relevant to the implemented Cloudflare remediation component.

PREREQUISITE CHECK
- Verify Phase 3 Vaultwarden+Caddy runtime, secrets materialization, lifecycle commands, and direct Vaultwarden SMTP are on the base. Missing Phase 3 is a blocker.

EXPECTED PHASE 4 OUTCOME
- One beta origin path: Cloudflare-proxied Caddy + Docker bridge + iptables.
- Strict Cloudflare IPv4/IPv6 validation, last-known-good cache with bounded staleness, fail closed if no safe policy.
- Project-owned packet policy correctly accounts for Docker; it does not pretend ordinary UFW INPUT alone protects published Caddy ports.
- CrowdSec Security Engine consumes required proxied web signals.
- Exactly one CrowdSec beta remediation scope: a current supported Cloudflare remediation integration for proxied web-client decisions.
- **No CrowdSec host firewall bouncer is required/installed by this phase.** SSH/host services remain under provider firewall/security-group + host firewall policy.
- Project-owned Cloudflare-source iptables allowlist and CrowdSec Cloudflare decisions are distinct controls, not overlapping bouncers.
- No nftables/second backend/direct-ingress/cloud-firewall API/general firewall framework.

CHECK
1. Does origin fail closed on absent/expired unsafe Cloudflare CIDRs?
2. Does the Docker packet path actually protect the published port?
3. Is CrowdSec Cloudflare remediation configured according to current upstream behavior?
4. Did the PR accidentally install/configure the host firewall bouncer or create a second remediation plane?
5. Is CrowdSec integration narrow rather than a wholesale V1 installer port?
6. Are real packet/remediation behaviors reserved for disposable-host acceptance where appropriate?

OUTPUT
Verdict, Blockers, Packet-path findings, CrowdSec findings, Scope/complexity assessment, Tests/CI, What I did not verify.

End: "Does this Phase 4 PR provide one clear fail-closed origin path and one clear CrowdSec web-remediation path without unnecessary enforcement planes?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 5 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 5.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 5 prompt.

PREREQUISITE CHECK
- Verify **Phase 4 is already present on the base**, including the Phase 3 runtime it depends on. Missing Phase 4 is a blocker; the Phase 5 PR must not silently implement edge/CrowdSec work.

EXPECTED PHASE 5 OUTCOME
- One encrypted V2 recovery format; no V1 reader/migration and no db/full/emergency public tier model.
- Consistent SQLite snapshot + required persistent state + versioned manifest/checksums + encryption + verification before success.
- Operational Age private key excluded; offline private recovery material not persisted on server.
- Incomplete local candidates never reported valid.
- rclone is first-class but small: diagnostics/connectivity/publication/list/verify/download/stage/prune.
- Offsite success = local verify -> copy/copyto-style publication -> remote verify.
- `rclone sync` is not normal publication; pruning/deletion separate.
- Restore validates/decrypts/checks/free-space/stages before live mutation; services stop only after successful preflight; promotion is a small explicit transaction boundary.
- No notification/systemd/update expansion.

CHECK
- Could backup ever report success before local or remote verification?
- Could restore mutate live state before all safe preflight checks?
- Are corruption/wrong-key/incomplete-manifest paths covered with real temp artifacts?
- Are rclone commands non-destructive in normal publication?
- Is recovery ownership cohesive rather than a wrapper/module explosion?

OUTPUT
Verdict, Blockers, Recoverability findings, rclone findings, Prompt coverage, File/test assessment, Validation/CI, What I did not verify.

End: "Would I trust the recovery points produced by this Phase 5 PR before Phase 6 automation begins?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 6 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 6.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 6 prompt completely. It wins if this reviewer mirror ever differs.
- Independently verify current official API documentation for provider-specific findings that affect merge safety.

PREREQUISITE CHECK
- Verify **Phase 5 is already present**: V2 backup/restore and rclone interfaces required by timers. Missing Phase 5 is a blocker.

EXPECTED PHASE 6 OUTCOME
- Small systemd automation surface using installed immutable code/config.
- One source-controlled non-secret immutable `email-providers.toml` for canonical `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, `cyberpersons`; `cyberpanel` alias only.
- One cohesive catalog renderer/notification owner, not a source module/class per provider.
- Operator config selects provider/alias + declared non-secret options; SOPS supplies credentials.
- Canonical provider-template message context is **exactly**:
  `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- Routine endpoint/auth/request/success/retry changes stay catalog-only when the closed schema can represent them.
- Catalog schema remains closed: HTTPS endpoint/template, finite auth modes, JSON/form request template using canonical fields, success status + at most one simple top-level success check, documented retry statuses, bounded standard Retry-After, and only a narrowly declared top-level numeric body retry-delay field + fixed unit when official docs support it.
- No arbitrary operator endpoints/auth/headers/payload/success/retry definitions; no `eval`, Jinja, Python expressions, dynamic imports, provider SDK, or general HTTP response/workflow language.
- Authorization-bearing requests do not silently follow cross-host redirects.
- API retry is small/bounded; SMTP fallback only for clearly transient failures after retry.
- No blanket all-5xx fallback.
- Direct SMTP uses validated TLS/STARTTLS + auth; no plaintext downgrade; no Postfix/local MTA/durable queue.

CYBERPERSONS REVIEW BASELINE
Re-verify against current official docs. The design baseline currently expects:
- endpoint `POST https://platform.cyberpersons.com/email/v1/send`;
- Bearer API key with `can_send`;
- mapping canonical values to provider `from`, `to`, `subject`, `text`;
- accepted HTTP 202 + JSON `success:true`;
- HTTP 429 transient/retryable after bounded retry;
- HTTP 503 service_unavailable transient/retryable;
- HTTP 500 send_failed **not transient/fallback-eligible by status alone**;
- 400/403 configuration/permanent cases visible;
- current docs mention JSON `retry_after` on 429, but if usable units/semantics are not documented, fixed bounded retry is acceptable and no general response-expression system should be added;
- optional CyberPanel SMTP is `mail.cyberpersons.com:587` STARTTLS with credentials separate from the API key.

CHECK
1. Does the implemented catalog use the exact canonical field vocabulary, including `to_email` rather than an alternate canonical `to`?
2. Can routine provider settings change without rewriting Python?
3. Is the catalog strict enough that operator config cannot exfiltrate `email_api_token` to an arbitrary host?
4. Is cross-host redirect behavior safe?
5. Are only provider-documented transient statuses fallback-eligible?
6. Specifically, can CyberPersons HTTP 500 accidentally trigger SMTP fallback? If yes, blocker.
7. Is 429 retry bounded without inventing a generic JSONPath/expression system?
8. Does `doctor` truthfully report invalid catalog/provider/credential/fallback states?
9. Are systemd units few, justified, and directly invoking installed `vwctl` rather than wrapper scripts?
10. Are tests focused: one provider render/auth/success check per built-in + shared catalog/security/classifier/fallback behavior rather than a provider conformance framework?

OUTPUT
Verdict, Blockers, Provider-catalog findings, CyberPersons classification findings, Secret/TLS/redirect findings, Systemd findings, Complexity/file/test assessment, Validation/CI, What I did not verify.

End: "Is this Phase 6 PR maintainable when provider settings change, secure against credential redirection, and safe to merge without masking permanent email failures?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 7 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 7.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 7 prompt.

PREREQUISITE CHECK
- Verify **Phase 6 is already present**, including systemd automation, notification owner, and immutable-release `email-providers.toml`. Also verify Phase 5 recovery still exists for update preflight. Missing Phase 6 is a blocker; this PR must not invent notification/catalog work.

EXPECTED PHASE 7 OUTCOME
- `versions.toml` remains the sole source-controlled component-version authority.
- amd64/arm64 artifact/image resolution centralized.
- Production install/update uses exact pins.
- `--use-latest` is dev/test-only, resolves once, freezes exact values/digests, records them, and never creates floating production state.
- Explicit `vwctl update check|apply`: validate current state -> verified recovery according to policy -> stage immutable release -> exact runtime components -> switch current -> restart -> health/doctor gate -> safe application-release rollback where possible.
- Application code and matching `email-providers.toml`/release resources activate as one release; no split-brain catalog.
- No unattended updater or generic component/provider framework.

CHECK
- Can `--use-latest` leak into production state?
- Is resolution performed once rather than scattered?
- Does update preflight really use the existing recovery contract?
- Can code/catalog resources from different releases become active together?
- Are rollback boundaries truthful and safe?
- Did the PR introduce per-component resolver-file proliferation?

OUTPUT
Verdict, Blockers, Reproducibility findings, Update/rollback findings, Prompt coverage, Complexity/test assessment, Validation/CI, What I did not verify.

End: "Is this Phase 7 update model reproducible and safe to merge before beta cleanup/docs?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Phase 8 PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI V2 Phase 8 / beta readiness.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative Phase 8 prompt.
- This is a beta-readiness review, not an invitation to add enterprise features.

PREREQUISITE CHECK
- Verify **Phase 7 is already present**, and therefore the Phase 6/5/4 surfaces it depends on are not being recreated inside this PR. Missing Phase 7 is a blocker.

VERIFY FINAL BETA CONTRACT
- Clean Ubuntu 24.04 install model coherent for amd64 + arm64.
- `vwctl` is the practical operator surface; status/doctor/logs truthful.
- Singular config/version/secret authorities.
- SOPS + Age operational/offline recovery safe and documented.
- Vaultwarden+Caddy hardening coherent.
- Cloudflare origin ingress fail closed; CrowdSec proxied web remediation uses the Cloudflare scope only; no accidental host firewall-bouncer beta requirement.
- Recovery creates/validates/encrypts one V2 format, publishes with non-destructive rclone semantics, verifies remote, downloads/stages safely, restores only after preflight.
- Operational provider selection supports six canonical built-ins including CyberPersons; `cyberpanel` aliases the same definition.
- `email-providers.toml` is safely maintainable without Python rewrites for ordinary metadata changes; operator config cannot redirect secrets to arbitrary endpoints.
- Canonical message context remains exactly `from_email|from_name|from_header|to_email|subject|text`.
- CyberPersons 500 is not masked by SMTP simply because it is 500; 429/503 behavior matches current verified provider docs.
- Direct SMTP fallback is transient-only, TLS-validating, no durable queue/Postfix.
- systemd invokes installed immutable code/resources.
- Production versions exact; `--use-latest` cannot create floating production state.
- Obsolete V1 migration/dashboard/Postfix queue/multiple backup tier/test-runner product surfaces removed from V2 when no longer needed.
- Documentation is sufficient for a junior admin and for a maintainer updating a provider block.
- Permanent tests are proportional; destructive/full-host validation is release acceptance rather than a giant per-PR controller.

CHECK ACCEPTANCE EVIDENCE
At minimum assess evidence for clean install/layout; start/status/doctor; SOPS/Age no-leak; Cloudflare fail-closed + CrowdSec Cloudflare remediation; backup->rclone publish->verify->download->restore; one provider API success + transient SMTP fallback; provider-catalog validation; systemd; pinned update. Clearly distinguish what was actually run from what remains unverified because environments were unavailable.

OUTPUT
Verdict, Release blockers, Security/recovery findings, Operator usability findings, Provider/CrowdSec findings, Complexity/file/test findings, Acceptance/CI evidence, Safe post-beta deferrals, What I did not verify.

End: "Would I trust this V2 beta for a small team of about 10 users, and is it safe to merge/release within the documented scope?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Corrective / bug-fix PR</strong></summary>

```text
Review PR <PR_URL> as one VaultWarden-OCI V2 corrective bug-fix PR.

REVIEW MODE
- Review only; do not modify or merge.
- Read the authoritative corrective prompt in `reports/CODEX-PROMPTS.md`.
- Expected scope is intentionally narrow.

CHECK
1. Confirm the observable bug and stable/public boundary affected.
2. Confirm the PR changes the smallest correct owner and addresses root cause.
3. Ensure it did not become an unrelated refactor/framework/compatibility/later-phase expansion.
4. Verify a regression test was added only for a real coverage gap and tests behavior, not private source layout.
5. Check specific security/recovery/secret implications.
6. For email-provider settings bugs, ask first whether `email-providers.toml` is the correct owner. Ordinary endpoint/auth/request/success/retry metadata changes should not trigger a Python-library rewrite.
7. Preserve exact canonical provider-template fields: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
8. Do not allow a provider bugfix to weaken transient-only SMTP fallback; CyberPersons 500 remains non-transient by status alone unless current official docs support an explicit contract change.
9. Do not allow a CrowdSec bugfix to add a host firewall bouncer or second remediation plane without a separate architecture decision.
10. Verify current CI and focused validation.
11. Flag new files unless there is a clear ownership/security reason an existing cohesive owner is insufficient.

OUTPUT
Verdict: SAFE TO MERGE / NEEDS CHANGES / NOT READY / INCOMPLETE.
Then: Blockers, Root-cause assessment, Regression-test assessment, Scope-creep assessment, Security/architecture preservation, Validation/CI, What I did not verify.

End: "Does this PR fix the reported bug completely with the smallest safe change?"
```

</details>
