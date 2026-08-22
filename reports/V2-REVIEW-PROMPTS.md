# VaultWarden-OCI — Standalone Stabilization Review Prompts

Date: 2026-08-22
Status: reviewer utility; the implementation prompts are authoritative.

## How to use

Use one complete fenced block for the matching PR/workstream. Replace only `<PR_URL>`.

The review agent must inspect the current PR metadata, base/head refs, complete diff, current CI/check state, and existing review threads. It reviews only unless a human explicitly asks it to make changes later.

`reports/V2-CODEX-PROMPTS.md` is the authoritative implementation contract until Workstream 6 performs the approved release-neutral rename to `reports/CODEX-PROMPTS.md`. These reviewer prompts are mirrors, not a second specification. If a reviewer prompt differs from the authoritative implementation block, the implementation block wins and the reviewer should flag this file as stale.

Review proportionately for a small-team appliance. Do not invent enterprise requirements, but do not excuse security, recoverability, storage, or operator-truthfulness defects as simplification.

---

<details>
<summary><strong>Review Prompt — Contract synchronization PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Contract Synchronization / Workstream 0.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 0 block in `reports/V2-CODEX-PROMPTS.md`; it is authoritative.
- This PR should be documentation/contract only.

GATHER
1. PR metadata/base/head/full diff/CI/review threads.
2. Before/after root `AGENTS.md`, product boundary, durable decisions, README and relevant operator docs changed by the PR.
3. Current implementation only as needed to determine whether documentation became knowingly false.

EXPECTED OUTCOME
The durable docs must now consistently describe:
- small-team/junior-admin appliance target;
- Ubuntu 24.04 amd64/arm64, cloud-neutral;
- hard separate-storage production invariant: persistent application state never supported on the boot/root filesystem;
- supported `setup.sh` blank-VM workflow, with interactive/`--auto`/explicit `--use-latest` semantics;
- `dashboard.sh` as supported day-2 UX while `vwctl` remains mutation authority;
- V1 UI/UX as design reference, V1 backend architecture not a compatibility target;
- Caddy custom xcaddy build, Cloudflare trusted-proxy module, and distinct host Cloudflare-only origin firewall;
- lightweight admin defense in depth;
- password-protected verified recovery-kit ZIP distinct from `.vwrec`;
- guided restore plus automation CLI forms;
- safe project update, automatic update checks but no default unattended apply;
- host Ubuntu package updates separate from application rollback claims;
- administrator-manual documentation direction;
- release-neutral final naming goal;
- current notification-provider behavior preserved, including current CyberPersons status-only classification.

CHECK
1. Search for stale claims that production boot-volume installs are supported.
2. Search for stale "no dashboard/TUI" requirements.
3. Search for stale claims that `--use-latest` is development/testing-only.
4. Confirm Caddy trusted-proxy handling is not described as a replacement for the host origin firewall.
5. Confirm the docs do not reintroduce V1 Postfix, multiple backup tiers, Make orchestration, migration compatibility, or a generic framework.
6. Confirm CyberPersons wording matches the current catalog/implementation unless this PR explicitly includes independently justified current-doc verification.
7. Confirm no production runtime code was changed.
8. Assess whether the docs remain concise authorities rather than multiplying ADRs/reports.

OUTPUT
Start with exactly one verdict:
- SAFE TO MERGE
- NEEDS CHANGES
- NOT READY / INCOMPLETE

Then: Blockers, Important findings, Cross-document conflicts, Scope/complexity assessment, Validation/CI, What I did not verify.

End exactly:
"Does this PR establish one clear, small-team product contract for the remaining implementation work?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Guided setup and dedicated storage PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 1: guided setup, dependencies, dedicated storage, and first-run configuration.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 1 implementation prompt; it is authoritative.

PREREQUISITE
Verify Contract Synchronization is already on the PR base. Missing/stale durable contract is a blocker.

CORE PRODUCT INVARIANT
Production application state must be on a separate filesystem/volume from `/`. The installer may not silently fall back to the boot/root filesystem.

CHECK INSTALL/STORAGE
1. Does setup identify the filesystem/device backing `/` and reject it as application storage, including parent/child block-device relationships?
2. Does interactive setup show plausible separate storage and require an explicit choice/confirmation rather than guessing?
3. If no acceptable separate storage exists, does setup exit cleanly before installing usable application state on root?
4. Does `--auto` refuse to guess/adopt/format storage without explicit selection/acknowledgement?
5. Are existing ext4/xfs adoption and blank-device formatting separately and explicitly confirmed?
6. Are unknown filesystem/signature cases fail-closed?
7. Is persistent mount identity stable (UUID/by-id where practical) and protected by a small project identity marker?
8. Do runtime/start/backup/restore/update paths have a reusable dedicated-storage readiness gate rather than setup-only validation?
9. Does boot/restart safety account for Docker `restart: unless-stopped`, so a missing mount cannot make Docker create the application data path on the boot filesystem? Verify the mount guard/order dependency is real and fail-closed.
10. Is boot-to-data migration absent, as appropriate for greenfield?

CHECK SETUP UX
- Supported entry point is `setup.sh`, not a manual dependency cookbook.
- Ubuntu 24.04 and amd64/arm64 validation is clear.
- Dependencies actually used by the product are installed and verified, including Docker/Compose, SOPS, Age, rclone and AES-ZIP tooling.
- `--domain`, `--url`, and `--email` safely prepopulate/normalize the canonical config without creating duplicate authorities.
- `--auto` and `--use-latest` are independent.
- Default install uses tested exact pins.
- `--use-latest` resolves once and records exact immutable values; no floating `latest` remains.
- Partial/interrupted setup is safely rerunnable/idempotent.
- Missing external Cloudflare/SMTP/API credentials are reported as configuration-required state rather than a misleading dependency-install failure.
- V1-style color/progress/error readability is preserved without contaminating non-TTY/machine output.
- Secrets are not exposed in argv/logs/history.

COMPLEXITY CHECK
Confirm the PR did not create a storage framework, package-manager abstraction, migration engine, workflow engine, or one shell script per setup step. Prefer one thin setup entry point plus cohesive existing Python owners.

TEST/ACCEPTANCE
Require focused tests for root-volume rejection, boot-device rejection, mount identity, Docker boot guard, destructive confirmations, auto-mode failure, input prepopulation, idempotency, latest freezing, and secret redaction. Distinguish mocks/temp-root tests from real Ubuntu + second-volume validation.

OUTPUT
Verdict, Blockers, Storage safety findings, Setup/UX findings, Complexity/file assessment, Tests/CI, Real-host validation, What I did not verify.

End exactly:
"Would this installer safely take a blank supported VM to an installed appliance without ever permitting production state to fall back onto the boot volume?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Custom Caddy and edge hardening PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 2: custom Caddy, trusted proxies, origin protection, and admin defense.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 2 implementation prompt.
- Independently check current Caddy/module compatibility where a finding depends on upstream behavior.

PREREQUISITE
Verify Workstream 1 dedicated-storage/setup behavior is already on the base.

EXPECTED CADDY BUILD
- Exact-pinned xcaddy build includes Cloudflare DNS, the main-proven Cloudflare trusted-proxy/real-IP module, its combined-IP-ranges helper, and Caddy rate limiting.
- Addon refs and architecture-specific images are exact/frozen in the single version authority.
- No generic plugin registry.

CRITICAL CONTROL SEPARATION
1. Caddy trusted proxies should use the Cloudflare module/current supported equivalent, not V2-generated static CIDRs.
2. Code whose only purpose was rendering Caddy static trusted-proxy ranges should be removed/simplified.
3. The host-level Docker `DOCKER-USER` Cloudflare-source allowlist must remain. It prevents direct origin access and is NOT redundant with Caddy client-IP trust.
4. Current/fresh last-known-good Cloudflare range validation/fail-closed behavior for that host firewall remains sound.
5. CrowdSec Cloudflare remediation stays separate; no host CrowdSec firewall bouncer/second backend appears.

ADMIN SECURITY
- Vaultwarden admin token remains required when admin is enabled.
- `/admin*` gets real-client-IP rate limiting plus one simple Caddy-side outer authentication gate.
- Sensitive auth/token endpoints get appropriate bounded rate limiting.
- Caddy Basic Auth credentials/hashes are handled without plaintext appearing in ordinary config, persistent generated files, argv, or logs.
- No Cloudflare Access requirement, fixed admin source-IP requirement, or enterprise identity stack is introduced.
- Security headers/request limits are small and compatible rather than a blind full V1 Caddyfile port.

TESTS
Look for rendered-addon/pin tests, trusted-proxy-module behavior, retained origin firewall/fail-closed tests, admin/auth route configuration, secret leakage coverage, Caddy validation, and unchanged CrowdSec remediation behavior. Real packet-path validation belongs in disposable-host acceptance when available.

OUTPUT
Verdict, Blockers, Caddy/module findings, Origin-firewall findings, Admin-security findings, Scope/complexity assessment, Tests/CI, What I did not verify.

End exactly:
"Does this PR reduce duplicate Cloudflare trusted-proxy code without weakening direct-origin or admin protection?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Recovery kit and guided restore PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 3: recovery kit, recovery inventory/verification, and guided restore.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 3 implementation prompt.

PREREQUISITE
Verify Workstream 2 is already on the base and current `.vwrec` recovery behavior remains intact.

KEEP TWO ARTIFACTS DISTINCT
- `.vwrec`: normal application/data/config recovery point, Age-encrypted, operational Age private key excluded.
- recovery-kit ZIP: credential/custody handoff, AES-256 password-protected, may contain key/credential material needed for disaster recovery.

CHECK APPLICATION RECOVERY UX
1. Is there a stable local/remote recovery inventory and verify path without adding a recovery database/index framework?
2. Does TTY restore present a clear numbered V1-style local/remote picker and explicit preflight/confirmation?
3. Are noninteractive `--file`/remote/identity forms preserved?
4. Are checksum/decryption/free-space/storage prerequisites proven before service stop/live mutation?
5. Does missing/wrong dedicated storage block restore before promotion, with no boot-volume fallback?

CHECK RECOVERY KIT
- Includes canonical useful config, server operational Age identity, current managed secret values, and admin/Caddy credentials where configured.
- Initial setup may generate offline recovery identity only in protected transient custody, include it in the verified encrypted kit, record only its public recipient in server config/SOPS policy, then remove the private host copy after successful handoff.
- A later "complete" export cannot fabricate the same offline identity; it requires/proves the matching supplied offline identity or clearly states the kit is incomplete/refuses the label.
- Offline private key is not persisted as ordinary server state.

AES-ZIP / EMAIL SECURITY
Verify the V1-proven properties were preserved:
- independent interactively entered/confirmed passphrase, minimum 16 chars;
- passphrase absent from argv, env, files, logs, email subject/body, project secrets;
- Ubuntu `7zz` AES-256 ZIP, not ZipCrypto;
- exact intended member list;
- archive verification with correct passphrase;
- deliberate wrong passphrase rejected;
- empty/no passphrase rejected;
- email is attempted only AFTER all encryption/integrity/password tests pass;
- attachment uses the existing direct authenticated SMTP path rather than inventing provider attachment APIs;
- safe bounded cleanup of plaintext/temp ZIPs.

COMPLEXITY
Reject V1 backup-tier compatibility, recovery database/state-machine framework, provider-specific attachment infrastructure, or duplicate restore logic in shell/UI.

TESTS
Require focused recovery-list/verify/guided-select/cancel/storage-preflight tests, credential-label/redaction tests, offline-key transient-custody tests, AES-ZIP positive/negative tests, and proof that email cannot precede verification.

OUTPUT
Verdict, Blockers, `.vwrec` findings, Recovery-kit/custody findings, Guided-restore findings, Secret/passphrase findings, Complexity/test assessment, Validation/CI, What I did not verify.

End exactly:
"Could a junior admin safely choose and restore a recovery point, and does the recovery-kit handoff remain both complete and cryptographically verified without weakening offline-key custody?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Safe update/upgrade workflow PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 4: safe project updates, explicit use-latest, and separate host upgrades.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 4 implementation prompt.

PREREQUISITE
Verify Workstream 3 recovery inventory/verification/guided restore is already on the base.

RECOMMENDED PROJECT UPDATE
- `vwctl update check` discovers the latest stable non-draft/non-prerelease VaultWarden-OCI release; normal admin does not need a candidate checkout.
- `update apply` consumes the coherent project release and exact tested pins/resources.
- Any `--source` path remaining is explicitly developer/test-oriented, not normal admin UX.

USE-LATEST
- Supported explicit operator override, not dev-only.
- Resolves Vaultwarden, Caddy, every required xcaddy addon ref, and architecture-specific image digests exactly once.
- Records one immutable snapshot; no floating `latest` tags or repeated remote resolution.
- Shows concise warning/confirmation that tested project pins are bypassed.
- Does not grow into a generic component plugin framework.

TRANSACTION SAFETY
1. Candidate metadata/content validation, pulls and custom Caddy build occur while current runtime is still healthy where practical.
2. Candidate Compose/Caddy/render validation occurs before downtime.
3. Current config/secrets/dedicated-storage/status/doctor and disk-space preflight are clean.
4. A mandatory verified pre-update `.vwrec` recovery point is recorded before mutation.
5. Mutation lock, immutable release switch/systemd update, activation and health gates are coherent.
6. Resolved-version state is committed only after candidate passes.

ROLLBACK
- Before candidate runtime can mutate persistent state: previous release/systemd resources are automatically restored and previous runtime health is proven.
- After candidate Vaultwarden may have started/migrated DB: old code is NEVER blindly started against possibly-new state.
- Interactive failure offers coherent rollback using the recorded pre-update recovery point plus previous immutable code OR safely leaves service stopped for troubleshooting.
- Noninteractive failure does not silently perform a destructive data restore unless an explicit documented rollback behavior was chosen before the run.
- Dedicated-storage state is revalidated during rollback.

AUTOMATION
- Small systemd update-CHECK timer only; it does not auto-apply.
- Minimal secret-free availability/check state feeds status/dashboard and optional existing notification owner.
- No updater daemon.

HOST UPGRADES
- Ubuntu package check/apply is clearly separate.
- May make a recovery point first, but never claims `.vwrec` can undo apt/kernel changes.
- Reports reboot-required state and never auto-reboots.
- No apt rollback/snapshot subsystem.

TESTS
Require stable-release selection/network behavior, release coherence, use-latest single freeze, pre-downtime staging ordering/behavior, mandatory recovery gate, pre-start rollback, post-start refusal to fake downgrade, coherent recovery rollback planning, noninteractive safety, check-only timer, host-upgrade truthfulness, and storage gating.

OUTPUT
Verdict, Blockers, Release-discovery/version findings, Transaction findings, Rollback findings, Automation findings, Host-upgrade findings, Complexity/test assessment, Validation/CI, What I did not verify.

End exactly:
"Is this update workflow safe enough for a small production appliance without pretending database or host-package rollback is simpler than it is?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Dashboard and day-2 QoL PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 5: V1-style dashboard and day-2 QoL.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 5 implementation prompt.

PREREQUISITE
Verify Workstream 4 update interfaces exist on the base.

PRIMARY DESIGN TEST
The dashboard is a supported human interface, but `vwctl`/existing Python owners remain the implementation and dangerous-mutation authority. Look hard for duplicated logic.

EXPECTED UI
- Installed `dashboard.sh` entry point works without requiring the source checkout.
- Recognizable V1/AMTM-style color, header, numbered menus, shortcuts and command-result screens are retained where practical.
- No curses/web UI framework.
- Non-TTY/JSON outputs remain uncolored/machine-safe.

MAIN SCREEN SHOULD TRUTHFULLY COVER
Vaultwarden/Caddy, doctor, dedicated storage/usage, local/offsite recovery age, rclone, CrowdSec/Cloudflare, timers, notification state, version/update availability, admin protection, reboot-required state.

MENU COVERAGE
- Stack lifecycle.
- Diagnostics/logs/journal/sanitized support bundle.
- Backup/recovery/inventory/verify/guided restore.
- Security/CrowdSec decisions/unban/edge/admin status.
- Validated config/secrets edit and high-value rotation.
- Recovery-kit export/email.
- Email/notification test without Postfix queue.
- Recommended project update/use-latest/host package/reboot state.
- Automation/timers.

CHECK BACKEND BOUNDARIES
- Dashboard calls stable `vwctl`, systemd or journal interfaces.
- It does not implement its own locks, SOPS state machine, restore/update/backup transaction, Docker lifecycle, CrowdSec mutation logic, or storage checks.
- Any new `vwctl` command has genuine day-2 value and an existing cohesive owner.
- No Makefile is reintroduced as the day-2 API.
- No Postfix queue, old backup tiers, generic Docker prune, shell escape, generic "fix everything", or broad permission repair.

SUPPORT BUNDLE
If added, verify it is useful but excludes private Age identities, decrypted secrets, recovery-kit contents/passwords, auth headers/tokens, and other known secret material. Redaction should not depend on a blacklist that obviously misses the project's canonical secrets.

SET-AND-FORGET
Dashboard/status should expose stale/missing automation rather than simply green-checking existence: backup age, update-check age, failed timers, missing storage mount, notification failure, reboot required.

TESTS
Look for public menu/navigation/cancel behavior, correct owner invocation, warning-state truthfulness, support-bundle redaction, color/non-TTY behavior, and focused tests for any new public `vwctl` operations.

OUTPUT
Verdict, Blockers, UI/UX findings, Backend-duplication findings, Security/redaction findings, QoL completeness, Complexity/file assessment, Tests/CI, What I did not verify.

End exactly:
"Does this PR bring back V1's useful operator experience without bringing back V1's backend complexity?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Final manual/naming/acceptance PR</strong></summary>

```text
Review PR <PR_URL> as VaultWarden-OCI Workstream 6: administrator manual, release-neutral naming, cleanup, and final acceptance.

REVIEW MODE
- Review only; do not modify or merge.
- Read the complete Workstream 6 implementation prompt.
- This is a release-readiness review, not an invitation to add enterprise features.

PREREQUISITE
Verify Workstream 5 dashboard/day-2 UX is already on the base.

RELEASE-NEUTRAL NAMING
Search the complete resulting branch for product-generation/stage leakage: V1/V2/v1/v2/beta and obsolete Phase labels.
Expected controlled normalization includes runtime/docs/report/test/systemd/bootstrap names and internal user-facing identifiers. Confirm all wired references were updated: installer release lists, update coherence, systemd source paths, CI/tests, AGENTS/docs links, stable installed entry points.

Do NOT flag genuine technical version numbers such as schema/archive format version 2 merely because they contain a number. The goal is release-neutral product naming, not removal of protocol/version semantics.

REPORT CLEANUP
- Approved prompt/review files may be renamed to release-neutral names with content preserved.
- Superseded V2 audit/architecture history should be deleted or have any still-useful durable material promoted into live docs rather than remaining a competing authority.
- Git history is sufficient for obsolete design-history retention unless a current maintainer need is demonstrated.

ADMINISTRATOR MANUAL
Verify README/docs are an actual user manual for a junior admin, not a maintainer design dump. It should provide clear task-based procedures for:
- stack/component explanation and simple architecture diagram;
- blank-VM install with mandatory separate storage;
- setup `--domain`/`--url`/`--email`, `--auto`, `--use-latest`;
- config/secrets editing;
- dashboard and core `vwctl` operations;
- Caddy/Cloudflare/CrowdSec/admin protection;
- backup contents and exclusions table;
- `.vwrec` versus recovery-kit ZIP;
- same-host restore versus lost-server disaster recovery;
- recovery inventory/verify/guided restore;
- recovery-kit password/email/extraction;
- recommended project updates, use-latest, rollback, automated checks, host package upgrades/reboot state;
- timers, notification/email tests, troubleshooting;
- where important files/state live.

For each high-risk procedure, look for prerequisite, exact command/menu path, expected success and failure/recovery guidance.

FINAL PRODUCT CONTRACT TO VERIFY
- Ubuntu 24.04 amd64/arm64 small-team appliance.
- Dedicated storage mandatory and boot-safe; no root-volume fallback.
- One canonical config/secrets/version ownership model.
- SOPS/Age secret custody and offline identity separation.
- Custom exact-pinned xcaddy modules with Caddy Cloudflare trusted proxies plus distinct fail-closed host origin firewall.
- CrowdSec Cloudflare remediation only; no host bouncer requirement.
- Admin token + simple outer Caddy auth + rate limits.
- Direct Vaultwarden SMTP and closed operational notification catalog; no Postfix/queue.
- One `.vwrec` format and separate verified AES-256 recovery kit.
- Guided restore and thin dashboard.
- Safe stable project updates, explicit exact-frozen use-latest, check-only automation, separate host package workflow.
- No V1 migration compatibility, public backup tiers, Make orchestration, generic plugin/storage/update frameworks, HA/Kubernetes, or giant repair machinery.

ACCEPTANCE EVIDENCE
Assess actual evidence, not claims. Where environments exist, expect clean Ubuntu install, real second-volume and boot guard, no secret leak, Caddy modules/trusted client IP/origin fail-close, admin/auth protections, start/doctor/dashboard, backup->rclone->guided restore, complete recovery-kit AES-ZIP/email, stable update/rollback boundary, use-latest freeze, update-check timer, host-upgrade/reboot state, systemd/notification path, and amd64/arm64 coverage.

Missing real-host/destructive/architecture validation must be reported honestly; do not require fabrication or a giant CI emulator.

COMPLEXITY / CLEANUP
Confirm obsolete wrappers/docs/tests were deleted where safe and the final codebase remains elegant and understandable. Flag giant mixed-responsibility files, but do not demand file splitting for aesthetic reasons.

OUTPUT
Start with one verdict: SAFE TO MERGE / NEEDS CHANGES / NOT READY / INCOMPLETE.
Then: Release blockers, Naming/stale-surface findings, Admin-manual findings, Security/storage/recovery findings, Update/QoL findings, Complexity assessment, Acceptance/CI evidence, Safe deferrals, What I did not verify.

End exactly:
"Would I trust this release-neutral VaultWarden-OCI appliance for a small team of roughly ten users, and is it ready to become the normal mainline product?"
```

</details>

---

<details>
<summary><strong>Review Prompt — Narrow corrective PR</strong></summary>

```text
Review PR <PR_URL> as one narrow VaultWarden-OCI corrective PR after stabilization work has begun.

REVIEW MODE
- Review only; do not modify or merge.
- Read the applicable authoritative workstream/corrective requirements before judging architecture.

CHECK
1. Identify the observable failure/public boundary and prove the PR fixes the root cause in the smallest existing owner.
2. Reject unrelated refactors, framework creation, compatibility work, or opportunistic later-workstream implementation.
3. Preserve the hard dedicated-storage and boot-safety invariant.
4. Preserve one mutation authority: dashboard/setup UI does not gain independent dangerous logic.
5. Preserve Caddy trusted-proxy versus host-origin-firewall separation.
6. Preserve `.vwrec` versus recovery-kit custody boundaries and do not weaken ZIP verification/passphrase handling.
7. Preserve safe update rollback boundaries; never fake old-code rollback after possible DB migration.
8. For notification-provider metadata defects, determine first whether `email-providers.toml` is the owner; do not rewrite Python for an ordinary catalog correction.
9. Preserve current provider transient classification unless current official docs justify a focused contract change.
10. Add focused behavioral regression coverage only where there is a real gap; avoid source-string/prose tests.
11. New files require a clear ownership reason.
12. Report exact CI/validation evidence and what was not run.

OUTPUT
Verdict, Blockers, Root-cause assessment, Scope-creep assessment, Security/storage/recovery preservation, Regression-test assessment, Validation/CI, What I did not verify.

End exactly:
"Does this PR fix the reported defect completely with the smallest safe change and without weakening the appliance contract?"
```

</details>
