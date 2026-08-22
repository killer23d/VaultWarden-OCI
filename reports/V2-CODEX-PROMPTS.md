# VaultWarden-OCI — Authoritative Stabilization Codex Prompts

Date: 2026-08-22
Status: authoritative implementation-agent contract for the remaining greenfield stabilization work.

## How to use this file

Each fenced prompt below is intentionally standalone. Copy one complete prompt into a fresh Codex session. Run them in order unless a human explicitly changes the plan.

These workstreams target the current `v2` implementation and are based on a fresh audit of current `v2` plus the useful operator/security behavior in `main`. The human-approved contract in each prompt supersedes older V2/beta/phase wording in supporting reports or docs when they conflict. Current executable behavior must still be inspected before editing.

For implementation sessions, authority is:

1. explicit human instructions supplied with the task;
2. the complete standalone prompt copied from this file;
3. current root `AGENTS.md` and current product/decision docs where they do not conflict with the prompt;
4. older reports as historical rationale only.

Ordinary implementation agents must not edit this prompt file. Workstream 6 is expressly allowed to perform the final release-neutral report/file renames described in that prompt without changing the substance of the approved contract.

## Approved product direction

The target is a small, security-first Vaultwarden appliance for roughly ten users and a junior administrator. It should feel appliance-like: blank supported VM -> guided setup -> edit/complete secrets and config -> start -> day-to-day operations through a clear color-coded dashboard, with automated health/backup/update checks afterward.

The redesign keeps the lean implementation principles already established: Python 3.12 standard-library-first for structured logic; Bash only where shell is materially simpler; one mutation authority (`vwctl`); one operator-editable non-secret config; SOPS + Age; one encrypted application recovery format; rclone; systemd; Cloudflare-first ingress; CrowdSec Cloudflare remediation; no Postfix, durable mail queue, Kubernetes/HA, provider framework, storage framework, workflow engine, generic transaction framework, or compatibility layer.

**V1 UI/UX is a design reference to preserve where it is good. V1 backend architecture is not a compatibility target.** Reuse the proven visual language, prompts, menu ergonomics, storage safety ideas, recovery-kit handoff, and operator convenience without re-importing Makefile orchestration, the large Bash helper graph, Postfix, multiple backup tiers, or duplicated implementation paths.

---

<details>
<summary><strong>Prompt 0 — Synchronize the durable contract</strong></summary>

```text
TASK: VaultWarden-OCI — synchronize the durable product contract before further implementation

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- This is documentation/contract work only. Do not implement runtime features in this task.
- Do not edit `reports/V2-CODEX-PROMPTS.md` or `reports/V2-REVIEW-PROMPTS.md`.
- Existing V2 docs contain now-superseded statements. The approved contract below is intentional and must replace those stale statements.

PRE-FLIGHT
1. Confirm the exact current branch/head and read root `AGENTS.md`.
2. Read current `docs/PROJECT-BOUNDARY.md`, `docs/V2-DECISIONS.md`, README, INSTALL/OPERATIONS/SECURITY/RECOVERY docs, and the current implementation owners they describe.
3. Inspect `main` only as a behavior/UX/security reference where needed; do not port its architecture.
4. Keep the durable documentation set small. Prefer updating existing authorities over creating new ADRs/reports.

APPROVED PRODUCT CONTRACT
- Small-team appliance: roughly 10 users, junior-admin operable, mostly set-and-forget.
- Ubuntu 24.04 LTS only; amd64 and arm64 supported/tested; cloud-provider neutral.
- Production persistent application state MUST live on a separate storage filesystem/volume, never the boot/root filesystem. A root-only host is not a supported production install.
- The normal first-run experience is `setup.sh`: validate host/storage, install dependencies, install the appliance, prepopulate config from operator inputs, assist secrets/recovery custody, then leave an explicit config/secrets -> start path.
- `setup.sh` supports interactive mode, `--auto`, and an independent explicit `--use-latest` override. `--use-latest` resolves once to exact immutable values; it must never leave floating `latest` state.
- V1 color-coded/AMTM-style operator UX is intentionally retained as the visual/interaction reference.
- `dashboard.sh` is a supported day-2 human interface. `vwctl` remains the implementation/mutation authority. One implementation authority does not mean one user interface.
- Python 3.12 stdlib-first owns structured config/state/validation/update/recovery logic. Bash remains thin bootstrap/UI/host glue where materially simpler.
- One operator-editable non-secret config authority under `/etc/vaultwarden-oci`; one encrypted SOPS secret document; one source-controlled exact version manifest.
- SOPS + Age remains the secret mechanism. The operational Age private key is root-only. The separate offline recovery identity is not persistently stored on the server.
- A password-protected recovery-kit ZIP is a separate credential-handoff artifact from the normal `.vwrec` application recovery point.
- Caddy remains an xcaddy custom build. Carry forward the useful main modules: Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP support, combined Cloudflare IP ranges, and Caddy rate limiting, all exact-pinned.
- Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. Do not keep a second generated static trusted-proxy CIDR block in Caddy.
- Host-level origin protection is a different control: retain one small fail-closed Docker `DOCKER-USER` path that allows published HTTPS only from validated Cloudflare source ranges. The Caddy trusted-proxy module does NOT replace this origin firewall.
- CrowdSec continues to remediate proxied web-client decisions through Cloudflare. No CrowdSec host firewall bouncer is required.
- Preserve lightweight `/admin` defense in depth: Vaultwarden admin token plus Caddy-side rate limiting and one simple outer authentication gate. Avoid an enterprise identity stack or multiple redundant gates.
- Vaultwarden application mail remains direct authenticated SMTP.
- Existing closed operational-notification provider catalog remains; do not redesign it. For CyberPersons, current code/catalog treats only documented status-only transient cases as retry/fallback eligible; HTTP 429 account-wide quota/rate-limit and HTTP 500 `send_failed` are not transient by status alone. Preserve current verified behavior unless current official provider documentation justifies a focused change.
- One encrypted `.vwrec` application recovery format; no public db/full/emergency tier model and no V1 archive compatibility.
- Recovery restore has a guided V1-style local/remote picker for humans while retaining explicit noninteractive CLI forms for automation.
- Recovery kit: AES-256 ZIP, passphrase entered/confirmed interactively, independent of stored credentials, never argv/env/file/email, fully verified before email is attempted.
- Normal project updates are safe and operator-driven: discover a stable project release, stage/download/build before downtime, verify a pre-update recovery point, activate immutable release, health-gate, and roll back coherently when safe.
- Automated update CHECK/notification is desirable; unattended application update APPLY is not the default.
- Ubuntu host package updates are a separate workflow; application recovery cannot pretend to roll back apt/kernel changes. Never auto-reboot.
- Documentation is an administrator user manual first, with exact steps, expected success, and recovery/troubleshooting guidance.
- Final product/repository surfaces must be release-neutral: do not leave product-generation/branch-stage names such as `V1`, `V2`, `beta`, or phase labels in normal runtime/docs/file names. Preserve genuine technical schema/archive format version numbers.

DESIGN DISCIPLINE
- Favor the smallest coherent owner and fewest clear files.
- Do not recreate V1 Make-based orchestration, Postfix, backup tiers, broad helper libraries, generic Docker cleanup, migration compatibility, or broad repair commands.
- Do not add Kubernetes/Swarm/HA, a plugin/provider framework, storage abstraction, updater daemon, workflow engine, ORM/database, event bus, generic transaction framework, distributed locks, or new monitoring stack.
- V1 UX/security behavior can be copied conceptually; V1 implementation shape is not a requirement.

IMPLEMENT
1. Update root `AGENTS.md` and the smallest set of current durable product/decision docs so they no longer tell future agents to reject the approved dashboard, dedicated-storage, supported `--use-latest`, Caddy-module, setup/recovery-kit, or update workflows.
2. Correct stale CyberPersons retry/fallback wording to match the current catalog/implementation unless current official docs were deliberately re-verified and a different change is separately justified.
3. Record the dedicated-storage invariant and the distinction between Caddy trusted-proxy handling and host-level Cloudflare-only origin filtering.
4. Record the principle: "V1 UI/UX is a design reference; V1 backend architecture is not a compatibility target."
5. Keep naming cleanup itself for Workstream 6; this task may document the required end state without mass-renaming files.

VALIDATION
- Inspect complete doc diff and cross-links.
- Search updated durable docs for contradictory claims such as "no dashboard", boot-volume production support, or `--use-latest` being development-only.
- No broad runtime test suite is required for a docs-only task unless repository enforcement requires it.

DEFINITION OF DONE
A fresh coding agent can read the current durable docs and arrive at the same approved product contract above without needing chat history or historical reports.

FINAL RESPONSE
- Summarize contract corrections.
- List exact files changed and why.
- State validation run/not run.
- Identify any unresolved contradiction instead of silently inventing a new product decision.
```

</details>

---

<details>
<summary><strong>Prompt 1 — Guided setup, dependencies, dedicated storage, and first-run configuration</strong></summary>

```text
TASK: VaultWarden-OCI — build the supported blank-VM setup and dedicated-storage first-run path

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement setup/storage/first-run configuration only. Do not implement the dashboard, recovery-kit email UI, or new update workflow here unless a tiny existing interface must be wired.
- Do not edit the authoritative prompt reports.

PRE-FLIGHT
1. Read root `AGENTS.md` and current durable decisions after Contract Synchronization.
2. Inspect current `bootstrap-v2.sh`, `vaultwarden_oci/install.py`, runtime path ownership, systemd units, and all current callers/tests.
3. Inspect `main` `setup.sh`, `utilities/setup-storage.sh`, and storage helpers only for proven UX/safety properties. Do not port their helper-library structure or boot-volume mode.
4. Identify the boot/root mount and existing non-root filesystems using read-only host tools before project mutation.

HARD STORAGE CONTRACT
- Production application state may NOT live on the boot/root filesystem.
- Setup must prove that the canonical VaultWarden-OCI state location is backed by a separate filesystem/device from `/` before the stack is considered installable/startable.
- Prefer a simple canonical state mount (for example the existing `/var/lib/vaultwarden-oci` state root backed by the selected dedicated filesystem) rather than introducing a configurable storage-root abstraction throughout the codebase.
- Interactive setup lists plausible separate mounted filesystems/block devices with useful size/device/mount information and asks the operator to select/confirm.
- If no acceptable separate volume/filesystem can be found, explain the requirement and exit without silently falling back to root storage.
- `--auto` never authorizes guessing a disk, adopting unknown data, or formatting. Noninteractive setup must receive an unambiguous safe storage selection (for example `--data-device`/`--data-mount`) or fail clearly.
- Never auto-select the boot disk or a parent/child device that contains the boot/root filesystem.
- Existing ext4/xfs adoption requires explicit operator confirmation unless a deliberately named noninteractive acknowledgement is supplied. Unknown filesystem types fail closed.
- A blank device may be formatted only behind an explicit destructive acknowledgement; do not make `--auto` imply permission to format.
- Use stable UUID/by-id identity for persistent mounts where available and keep a small project ownership/identity marker so the wrong filesystem cannot be silently accepted later.
- Runtime/start/backup/restore/update must fail closed when the required dedicated mount is absent or has the wrong identity.
- Because Docker may restart `restart: unless-stopped` containers independently of `vwctl`, install one small boot-time mount guard/order dependency so Docker cannot recreate application paths on the boot volume when the dedicated mount is missing. Reuse the useful V1 mount-guard principle without its broader storage/migration machinery.
- No boot-to-data migration feature is needed: this is a greenfield fresh-install product.

SETUP UX CONTRACT
The supported first-run command is `setup.sh`, not a manual dependency cookbook.

Support an operator form equivalent to:
  sudo ./setup.sh install --domain DOMAIN --url https://vault.DOMAIN --email ADMIN_EMAIL [OPTIONS]

Required behavior:
- validate Ubuntu 24.04 and amd64/arm64;
- perform the dedicated-storage preflight early;
- install required Ubuntu dependencies, Docker Engine/Compose from the supported source, SOPS, Age, rclone, 7zip, and other actually-used tools;
- verify installed dependencies before continuing;
- install the immutable application and systemd integration;
- generate the operational Age identity safely if absent;
- generate/prepopulate the canonical operator config from `--domain`, `--url`, and `--email` as appropriate;
- if URL and another field are logically redundant, normalize/validate them rather than creating a duplicate configuration authority merely to echo CLI inputs;
- create a valid encrypted-secrets starting point or launch a guided secret editor without exposing plaintext in argv/logs/history;
- leave clear next actions: complete external credentials/config -> validate/doctor -> start;
- be safe to re-run after an interrupted/partial setup and skip/prove completed work rather than forcing a VM rebuild.

OPTIONS
- `--auto`: noninteractive for safe locally-generatable/defaultable choices; generates local credentials where appropriate but must not invent external Cloudflare/SMTP/API credentials or destructive disk consent.
- `--use-latest`: independent explicit override. Resolve currently available supported component versions exactly once, freeze exact versions/image digests/xcaddy addon refs for the install, record them, and install that exact set. Never persist floating `latest` tags.
- normal/default path uses repository-tested exact pins.
- preserve useful `--dry-run` and explicit storage-selection options if they remain simple and truthful.

OUTPUT / UX
- Carry forward V1's proven color language and phase/progress clarity: green success, yellow warning, red failure, cyan information, blue hint/action, magenta rollback, readable headers.
- Disable color automatically for non-TTY/JSON; support `NO_COLOR` or one equally simple conventional override.
- Never let color escape sequences contaminate machine-readable output.
- Failures identify the failed step and the exact safe next action; do not print a misleading final success summary after partial failure.

SCOPE / OWNERSHIP
- Prefer one thin `setup.sh` bootstrap/orchestrator over many one-action shell scripts.
- Structured storage/config/version/install state remains Python-owned where practical.
- Do not introduce a storage framework, disk inventory database, migration engine, generic package manager abstraction, or setup workflow engine.

TESTS REQUIRED
- root-only/boot-volume host is rejected;
- boot device cannot be selected as data device;
- a valid separate mounted filesystem/device is accepted;
- missing/wrong mount identity fails closed;
- Docker boot guard prevents state-path fallback onto root when the mount is absent;
- interactive/no-volume and noninteractive/no-selection fail safely;
- existing-filesystem and blank-format destructive acknowledgements are enforced;
- `--auto` does not authorize disk guessing/formatting;
- domain/url/email normalization/prepopulation;
- setup idempotent/restartable behavior at a stable temp-root/mock command boundary;
- default pinned install versus `--use-latest` exact freeze;
- no plaintext-secret leakage in args/logs.

DISPOSABLE-HOST VALIDATION
When environment access permits, validate a clean Ubuntu 24.04 install with a real second volume. Explicitly report if real block-device/Docker/systemd validation was not available.

FINAL RESPONSE
- State the final blank-VM workflow.
- State exactly how dedicated storage is proven and guarded at boot.
- List validation run/not run and files changed/new with ownership rationale.
- Call out anything intentionally left for later workstreams.
```

</details>

---

<details>
<summary><strong>Prompt 2 — Custom Caddy, trusted proxies, origin protection, and admin defense</strong></summary>

```text
TASK: VaultWarden-OCI — simplify and harden the custom Caddy/Cloudflare edge without duplicating controls

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Implement only the Caddy/edge/admin-security changes described here.
- Do not edit the authoritative prompt reports.

PRE-FLIGHT
1. Read current durable decisions and verify Workstream 1 dedicated-storage/setup behavior is present on the base.
2. Inspect current `runtime.py`, `edge.py`, version resolution, Caddy render/build path, secrets, doctor checks, and tests.
3. Inspect `main` `caddy/Dockerfile` and Caddyfile as a security/UX reference, not as code to copy wholesale.
4. Verify current upstream/module compatibility for the exact Caddy version before changing addon pins.

CADDY BUILD CONTRACT
Caddy remains an exact-pinned xcaddy build containing the useful module set already proven in main:
- `caddy-dns/cloudflare`;
- the Cloudflare trusted-proxy/real-client-IP module used by main;
- the combined-IP-ranges helper used by that trusted-proxy path;
- Caddy rate limiting.

Record exact addon versions/commit refs alongside the other component pins in the single version authority. The builder/runtime images remain exact-digest pinned for the target architecture. Do not add a generic Caddy plugin registry.

TRUSTED PROXY VS ORIGIN FIREWALL
- Configure Caddy to use the Cloudflare trusted-proxy module (`trusted_proxies cloudflare` or the current supported equivalent) and `CF-Connecting-IP` so per-client rate limits/logs use the real visitor IP.
- Remove V2 code whose only job is generating a static Caddy trusted-proxy CIDR block from fetched Cloudflare ranges. Do not maintain the same trusted-proxy list twice.
- Retain the small project-owned Docker `DOCKER-USER` Cloudflare-source allowlist/fail-closed path because it performs a different job: preventing direct origin TCP/443 access that bypasses Cloudflare.
- Keep strict validation/bounded last-known-good logic needed by that host firewall. Do not remove it merely because Caddy knows trusted proxies.
- Keep CrowdSec Cloudflare remediation separate from the origin allowlist; no host CrowdSec firewall bouncer or second firewall backend.

ADMIN / AUTH PROTECTION
- Vaultwarden `ADMIN_TOKEN` remains required when the admin page is enabled.
- Add Caddy-side rate limiting for `/admin*` and sensitive auth/token endpoints using the trusted real client IP.
- Add one simple outer authentication gate for `/admin*`, following the V1 Basic Auth UX/security concept without importing the whole V1 Caddyfile.
- Store any Basic Auth source credential in SOPS, not ordinary config. Derive/materialize only the hash needed by Caddy and never place plaintext in argv, logs, generated persistent config, or shell history. If the selected Caddy command cannot safely receive the plaintext, use a safe stdin/volatile-file boundary or report the limitation rather than weakening secret handling.
- Preserve only security headers/request limits demonstrably useful and compatible with current Vaultwarden. Avoid a giant policy block copied from V1.
- Do not require Cloudflare Access, a fixed source-IP admin allowlist, or another identity product as part of the baseline.

OUTPUT / DIAGNOSTICS
- Use the shared V1-inspired color/status conventions established by setup.
- Doctor/status should distinguish: trusted-proxy configuration, origin firewall, Caddy health, admin protection, and CrowdSec remediation without conflating them.

TESTS REQUIRED
- rendered Caddy build includes all exact-pinned required addons;
- Caddy trusted proxy uses the module rather than generated static CIDRs;
- host origin rule still fails closed and allows only validated Cloudflare sources;
- direct-origin protection is not accidentally removed by trusted-proxy refactor;
- real-client-IP-based rate-limit configuration for admin/auth routes;
- admin route requires both configured Vaultwarden token capability and outer gate when enabled;
- Basic Auth plaintext does not leak to persistent render/argv/logs;
- representative Caddy config validation;
- existing CrowdSec Cloudflare remediation remains intact.

NON-GOALS
- Cloudflare Access integration;
- multiple ingress/firewall backends;
- a Caddy plugin framework;
- full V1 Caddyfile port;
- setup/dashboard/recovery/update feature expansion.

FINAL RESPONSE
- Explain what code was removed because Caddy now owns trusted-proxy CIDRs and what host-origin code intentionally remains.
- List exact xcaddy addon pins and validation performed.
- Describe `/admin` protection and secret handling.
- List exact tests/host validation run and not run.
```

</details>

---

<details>
<summary><strong>Prompt 3 — Recovery kit, inventory, verification, and guided restore</strong></summary>

```text
TASK: VaultWarden-OCI — add the small-team credential recovery kit and guided restore UX

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Keep the existing one-format `.vwrec` recovery architecture. This task adds credential-handoff and human restore UX; it does not restore V1 backup tiers.
- Do not edit the authoritative prompt reports.

PRE-FLIGHT
1. Verify Workstream 2 is present and inspect current `recovery.py`, secrets/SOPS custody, rclone behavior, notification SMTP owner, CLI, and tests.
2. Inspect main recovery-kit export and interactive restore only for proven UX/security behavior.
3. Preserve the distinction between an application recovery point (`.vwrec`) and a credential recovery kit (password-protected ZIP).

APPLICATION RECOVERY CONTRACT
- Keep one encrypted `.vwrec` format containing the coherent application/config state already owned by V2.
- The normal artifact continues to exclude the operational Age private key.
- Add a stable recovery inventory/verification surface, for example `vwctl recovery list` and `vwctl recovery verify`, using the existing recovery owner rather than a second index/database.
- Inventory should make local/remote recovery points easy to understand: date/time, size, location, and verification state when known.
- Human `vwctl restore` in a TTY should offer a V1-style guided flow: choose local or remote, display numbered recovery points, choose one, run preflight, show what will change, explicitly confirm, then restore.
- Preserve explicit `--file` / remote-object / identity options for automation and scripted disaster recovery.
- All knowable validation/decryption/checksum/space/storage-mount prerequisites occur before service stop/live mutation.
- Restore may never promote data onto the boot volume when the required dedicated storage mount/identity is absent.

RECOVERY-KIT CONTRACT
Provide a supported command such as `vwctl recovery-kit export`, also reachable from setup and later the dashboard.

The kit is a credential/admin handoff, not a normal backup. It should contain the information required to reconstruct access/custody, including:
- canonical non-secret configuration useful during rebuild;
- server-held operational Age private identity;
- all current SOPS-managed credential values, including Vaultwarden admin and Caddy admin credentials where configured;
- the offline recovery private identity when producing a complete initial/disaster-recovery kit.

Preserve offline custody:
- Initial guided setup may generate the offline recovery identity in a root-only volatile/sensitive workspace, put its public recipient into config/SOPS policy, include the private identity in the verified encrypted recovery-kit ZIP, and remove the host-side private copy after successful handoff.
- Later complete recovery-kit export must not pretend it can recreate the same offline identity. Require the operator to provide the matching offline identity file for inclusion/validation, or clearly refuse to label the kit complete.
- Never persist the offline private identity as ordinary server state.

ZIP / EMAIL SECURITY
Carry forward the proven V1 behavior:
1. Build the plaintext recovery document only in protected root-owned temporary/publication space and never print its contents.
2. Prompt interactively for an independent recovery-kit ZIP passphrase and confirmation; require at least 16 characters.
3. The passphrase must not appear in argv, environment variables, temp files, subject/body, logs, or project secrets.
4. Use Ubuntu's supported `7zip`/`7zz` AES-256 ZIP capability; setup installs this dependency.
5. Before email, verify all of the following: ZIP container, AES-256 (not ZipCrypto), exact intended member set, correct passphrase succeeds, deliberately wrong passphrase fails, empty/no passphrase fails, archive test succeeds.
6. Only after all verification passes may the operator be offered email delivery.
7. Send the verified ZIP through the existing direct authenticated SMTP attachment path so provider-specific HTTP attachment APIs are not invented.
8. Do not include the passphrase in the email. Keep protected local plaintext/ZIP cleanup bounded and fail visibly if cleanup/publication cannot be made safe.

UX
- Preserve V1-style colors, clear numbered choices, safe explicit confirmation, and readable summaries.
- Avoid multiple nearly identical scripts; `vwctl`/existing Python owners perform the real work. A tiny shell entry point is acceptable only if it materially improves operator use.

TESTS REQUIRED
- recovery list/local and mocked-remote ordering/presentation;
- recovery verify detects corruption/wrong identity/incomplete artifact without mutation;
- guided selection chooses the intended recovery point and cancellation is safe;
- dedicated-storage preflight blocks restore when mount missing/wrong;
- recovery kit includes required credential labels without printing values;
- offline identity is transient during setup and absent from persistent server state after successful handoff;
- later complete export requires/proves matching offline identity;
- ZIP AES-256/member/correct-password/wrong-password/no-password verification;
- email is never attempted before ZIP verification;
- passphrase/secret redaction across argv/logs/errors.

NON-GOALS
- V1 archive reader;
- db/full/emergency public backup tiers;
- provider-specific attachment APIs;
- a recovery database/state machine/framework;
- dashboard implementation (later workstream only calls these public interfaces).

FINAL RESPONSE
- Explain `.vwrec` versus recovery-kit responsibilities.
- Describe exactly what the recovery kit contains and how offline identity custody remains off-host.
- Show the normal guided restore flow.
- List validation run/not run and any real restore test not available.
```

</details>

---

<details>
<summary><strong>Prompt 4 — Safe project updates, explicit use-latest, and separate host upgrades</strong></summary>

```text
TASK: VaultWarden-OCI — complete the appliance-style safe update/upgrade workflow

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Build on the current immutable-release updater; do not replace it with a generic deployment framework.
- Do not edit the authoritative prompt reports.

PRE-FLIGHT
1. Verify Workstream 3 recovery interfaces are present.
2. Inspect current `update.py`, `update_cli.py`, `update_versions.py`, immutable release installer, systemd ownership, runtime activation, and current tests.
3. Preserve current V2 safety behavior that refuses a fake old-code rollback after candidate runtime may have changed persistent state.
4. Inspect main update UX only for useful operator messages/preflight ideas; do not combine its apt/image transaction model into one rollback claim.

THREE DISTINCT OPERATIONS
A. Recommended project update
- `vwctl update check` discovers the newest non-draft/non-prerelease stable VaultWarden-OCI release from the project's trusted GitHub repository, compares it with the installed immutable release, and displays exact project/component changes without mutation.
- `vwctl update apply` downloads/stages that project release and uses the release's tested exact pins/resources.
- Normal administration must not require manually cloning/checking out a candidate and passing `--source`; keep a source override only as an explicit developer/test path if still useful.

B. Explicit `--use-latest`
- Supported, deliberate operator override for setup/update; not development-only.
- Resolve currently available supported upstream component versions once at the beginning, including Vaultwarden, Caddy, all required xcaddy addon refs, and architecture-specific image digests.
- Freeze/record the exact resolved set and pass only that immutable snapshot downstream. Never leave floating `latest` tags.
- Display a concise yellow warning that these component versions bypass the project's tested release pins, then require explicit confirmation in interactive mode.
- Do not create a generic component plugin/resolver framework; extend the existing central version owner.

C. Ubuntu host packages
- Separate `host-upgrade check|apply` (or equally clear grammar) from the application update transaction.
- May create/verify an application recovery point first, but explicitly state that `.vwrec` cannot roll back apt/kernel/system package changes.
- Use normal Ubuntu package tooling conservatively; report reboot-required state; never auto-reboot.
- Do not implement package rollback/snapshot infrastructure.

PROJECT UPDATE TRANSACTION
Minimize downtime by preparing everything possible while the current stack remains healthy:
1. Acquire/validate candidate metadata and exact release content.
2. Validate current config/secrets/dedicated-storage state and current `status` + `doctor` baseline.
3. Verify sufficient disk space.
4. Pull exact runtime images and build the exact custom xcaddy image before downtime.
5. Validate candidate Compose/Caddy/rendered resources without activating them.
6. Create a mandatory verified pre-update `.vwrec` recovery point and record the exact artifact/digest.
7. Recheck current state and acquire the existing mutation lock.
8. Enter the short maintenance boundary, install/stage immutable release/systemd resources, atomically switch `current`, activate the candidate, then gate Vaultwarden, Caddy/HTTPS, origin/CrowdSec, and final doctor.
9. Commit the resolved-version state only after the activated release passes.

ROLLBACK CONTRACT
- If failure occurs before candidate runtime can change persistent application state, automatically restore the previous release symlink/systemd resources and prove the previous stack healthy.
- Once candidate Vaultwarden may have started/migrated the database, NEVER simply launch the previous Vaultwarden against possibly-new persistent state.
- In an interactive update failure after possible persistent-state change, present a clear guided choice: (1) coherent rollback using the verified pre-update `.vwrec` plus previous immutable application release, or (2) leave services/ingress safely stopped for troubleshooting. A coherent rollback restores both application data/config state and previous code.
- Noninteractive operation must not silently perform a destructive data restore. Unless an explicit documented rollback option was provided up front, fail safely, keep public service state truthful, and print the exact recovery command/artifact needed.
- Preserve all secret redaction and dedicated-storage checks during rollback.

AUTOMATION / NOTIFICATION
- Add one small systemd update-CHECK timer (daily or similarly modest cadence) using the existing scheduler model. It checks only; it does not auto-apply.
- Persist only minimal secret-free update availability/check state needed by status/dashboard.
- Use existing operational notification delivery to report a newly available project release or update-check failure when configured.
- No updater daemon or background polling service beyond the timer.

UX
- Color-coded preview shows current -> candidate project, Vaultwarden, Caddy, and xcaddy addon versions.
- `update apply` asks one clear confirmation after presenting plan/recovery behavior.
- Machine-readable modes stay clean/uncolored.

TESTS REQUIRED
- stable GitHub release selection ignores draft/prerelease and handles no-update/network failure truthfully;
- candidate project/resource coherence and exact pins;
- `--use-latest` resolves once and freezes all relevant component/addon/image values;
- pre-stage work occurs before runtime downtime in observable transaction behavior;
- mandatory verified pre-update recovery gates mutation;
- rollback before candidate start restores previous release;
- after possible persistent-state change, old code is not auto-started against new state;
- coherent recovery+previous-release rollback plan uses the recorded pre-update artifact;
- noninteractive failure does not silently restore data;
- update-check timer never applies updates;
- host-upgrade path never claims application rollback can undo OS packages and never auto-reboots;
- dedicated-storage absence blocks update/rollback before data mutation.

NON-GOALS
- unattended application auto-apply by default;
- blue/green deployment, replicas, HA, database migration framework;
- release-signing/PKI framework not already required by the project;
- updater daemon;
- apt rollback/snapshot manager.

FINAL RESPONSE
- Describe normal update, use-latest, rollback boundaries, automated checking, and host-upgrade separation.
- State exactly which expensive operations happen before downtime.
- List exact validation run/not run and any real destructive upgrade/rollback test unavailable.
```

</details>

---

<details>
<summary><strong>Prompt 5 — Day-2 QoL and V1-style dashboard</strong></summary>

```text
TASK: VaultWarden-OCI — restore the proven V1 operator experience as a thin day-2 interface

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Verify Workstream 4 update interfaces are present.
- `vwctl` remains the implementation/mutation authority. The dashboard is an alternate human interface, not a second implementation.
- Do not edit the authoritative prompt reports.

PRE-FLIGHT
1. Inspect current `vwctl`, status/doctor JSON/human output, systemd timers, recovery/update/crowdsec/notification/config/secrets owners.
2. Inspect main `dashboard.sh` as the UI/UX reference: AMTM-style header, colors, numbered menus, shortcuts, clear command-result screens, press-Enter return flow.
3. Do NOT port its Makefile calls, Postfix queue, direct container mutation, old backup tiers, old helper libraries, or broad maintenance commands.

UX CONTRACT
- Ship a supported `dashboard.sh` entry point and make it available on an installed appliance without requiring the original git checkout (for example via the immutable current release plus a stable installed link).
- Preserve the recognizable V1 color/menu style and keyboard ergonomics where practical.
- Keep it dependency-light; no curses/TUI framework or web UI.
- A small cohesive Python presentation owner behind `dashboard.sh` is acceptable if it materially reduces brittle Bash parsing; do not add a UI framework. A Bash dashboard is also acceptable if it stays thin.
- Dashboard actions invoke stable `vwctl`/systemd/journal interfaces. It must not duplicate locks, backup/restore/update logic, SOPS editing, CrowdSec mutation, or Docker lifecycle code.

MAIN SCREEN
Show a concise at-a-glance view using stable read-only state:
- Vaultwarden and Caddy health;
- overall doctor state;
- dedicated storage mount/usage and disk warning;
- latest verified local and offsite recovery age/state;
- rclone state;
- CrowdSec/Cloudflare edge state;
- systemd timer state;
- notification state;
- installed version/update availability;
- admin protection state;
- reboot-required state when applicable.

MENUS / ACTIONS
Keep the menu surface small and task-oriented. At minimum provide easy access to:
- Stack: start, stop, restart, status.
- Diagnostics: doctor, service logs/journal, sanitized support bundle.
- Backup/Recovery: backup now, offsite backup, recovery inventory/verify, guided local/remote restore.
- Security: CrowdSec status/decisions, unban IP, edge status/refresh, admin protection status.
- Config & Secrets: validated config edit, SOPS secrets edit/validate, high-value credential rotation such as admin token/admin Basic Auth where already supported.
- Recovery Kit: export and optional verified encrypted email.
- Email/Notifications: test the configured operational route and direct SMTP fallback path as supported; no Postfix queue menu.
- Updates & Host: check/apply recommended project update, explicit use-latest, host package check/apply, reboot-required display.
- Automation: systemd timer status/schedules.

ADD ONLY MISSING PUBLIC OPERATIONS NEEDED BY THE DASHBOARD
Before putting logic in the dashboard, add/extend a small `vwctl` public command only when there is real day-2 value and no existing owner. High-value examples:
- stable `status --json` if needed for presentation;
- recovery inventory/verify (should already exist from Workstream 3);
- CrowdSec decision list/unban;
- config/secrets edit/validate helpers that validate before committing;
- notification/email test;
- sanitized `support-bundle` containing versions, doctor, service/systemd state, disk/storage, timers, and bounded redacted logs while excluding secret material;
- timer/update availability read-only status.

Do not add generic command registries, generic repair/fix-all, generic Docker prune, shell access, broad permission repair, or one utility script per menu item.

COLOR / OUTPUT CONTRACT
Use one consistent V1-inspired scheme across `vwctl`, setup, recovery/update flows, and dashboard:
- success green;
- warning yellow;
- failure red;
- info cyan;
- hint/action blue;
- rollback magenta;
- bold/inverted headers where helpful.
Disable colors for non-TTY/JSON and honor a simple `NO_COLOR`/equivalent convention.

SET-AND-FORGET QUALITY
- Status should make stale automation visible: backup age, update-check age, failed timers/notification state, missing mount, reboot required.
- Do not add a monitoring stack or database to achieve this; read existing state/systemd and persist only the small state already needed by owning workflows.

TESTS REQUIRED
- menu rendering/basic navigation/cancel behavior at the public UI boundary;
- dashboard mutations call the correct public owner and do not directly duplicate dangerous operations;
- Postfix/old backup tiers/Make orchestration are absent;
- storage/backup/update/admin warning states are truthful;
- support bundle excludes known secrets/private keys/passphrases and remains useful;
- color enabled only for TTY and absent in JSON/non-TTY;
- important `vwctl` additions have focused behavioral tests.

NON-GOALS
- web dashboard/curses framework;
- Makefile as day-2 API;
- Postfix queue;
- V1 helper-library port;
- generic Docker prune/fix-everything operations;
- duplicate restore/update/backup state machines in UI code.

FINAL RESPONSE
- Show the resulting menu hierarchy and main-screen information.
- List any `vwctl` commands added and why each was necessary.
- State how the dashboard remains thin.
- List validation run/not run and files added/removed with rationale.
```

</details>

---

<details>
<summary><strong>Prompt 6 — Administrator manual, release-neutral naming, cleanup, and final acceptance</strong></summary>

```text
TASK: VaultWarden-OCI — final operator manual, release-neutral normalization, cleanup, and acceptance

AUTHORITY / WORKFLOW
- This pasted prompt controls this session unless explicitly overridden by the human.
- Work from current `v2`; do not merge your own PR unless instructed.
- Verify Workstream 5 dashboard/QoL behavior is present.
- This is a final normalization/documentation/acceptance pass. Do not invent new product architecture.
- Do not substantively rewrite the approved prompt contract. This task IS expressly allowed to rename V2-named prompt/report files to release-neutral names and update their references as part of the approved normalization.

PRE-FLIGHT
1. Inventory the complete current branch: root files, docs, reports, systemd, tests, Python identifiers/docstrings, README/help output, CI paths, and installed-layout file lists.
2. Search for product-generation/stage language and filenames: `V1`, `V2`, `v1`, `v2`, `beta`, obsolete `Phase N`, and branch-era names.
3. Distinguish true technical versioning from branding. Do not remove schema/archive format version numbers such as `.vwrec` format version 2 when they are real protocol/data-format compatibility markers.
4. Inspect current docs for administrator completeness before creating another document.

RELEASE-NEUTRAL NORMALIZATION
Perform a controlled rename/update, not a blind search/replace. Expected direction includes:
- `bootstrap-v2.sh` -> `setup.sh` if Workstream 1 has not already replaced it;
- `systemd-v2/` -> `systemd/`;
- `tests/v2/` -> normal `tests/` layout appropriate to the existing small three-layer strategy;
- `docs/V2-DECISIONS.md` -> `docs/DECISIONS.md`;
- `reports/V2-CODEX-PROMPTS.md` -> `reports/CODEX-PROMPTS.md`;
- `reports/V2-REVIEW-PROMPTS.md` -> `reports/REVIEW-PROMPTS.md`;
- `reports/V2-TEST-STRATEGY.md` -> `reports/TEST-STRATEGY.md` if retained;
- remove or promote useful content from superseded historical V2 audit/architecture reports rather than preserving stale branch-era documents solely for history (git history already exists);
- rename runtime identifiers such as `RuntimeErrorV2` and remove beta/phase labels from normal user-facing output, systemd descriptions, comments/docstrings, user-agent strings, and documentation where they are no longer technically meaningful.

Update every wired reference: installer release file lists, systemd source paths, tests/CI, docs links, AGENTS, update coherence checks, and any generated/help references. Preserve real immutable-release/data-format version values.

ADMINISTRATOR MANUAL CONTRACT
Rewrite/consolidate existing docs as a user manual for a junior admin. Prefer a small obvious set over many overlapping pages. README should be the entry point, with exact links/commands.

At minimum the manual must make these tasks easy:
1. What the appliance contains and why: Vaultwarden, custom Caddy, Cloudflare, CrowdSec, SOPS/Age, rclone, systemd, notification path.
2. Simple architecture diagram: Internet -> Cloudflare -> host 443 origin filter -> Caddy -> internal Vaultwarden, plus where CrowdSec acts.
3. Blank-VM installation with dedicated-storage requirement and examples for interactive, `--auto`, and `--use-latest` setup.
4. What `--domain`, `--url`, and `--email` mean and what setup prepopulates.
5. Config/secrets editing and validation without teaching the admin raw SOPS internals unless needed for recovery.
6. Start/stop/status/doctor/logs and `dashboard.sh` as the normal day-2 UI.
7. Caddy/admin protection and Cloudflare-only origin behavior.
8. Backup contents AND explicit exclusions in a table. Explain that normal `.vwrec` differs from the credential recovery-kit ZIP.
9. Same-host restore versus lost-server disaster recovery as separate step-by-step procedures, including the dedicated-volume prerequisite and required offline/recovery-kit material.
10. Guided local/remote restore and how to verify a recovery point without restoring.
11. Recovery-kit export/email, password custody, and how to extract the AES-256 ZIP on common platforms.
12. Recommended project update, explicit `--use-latest`, rollback behavior, automatic update checks, host package updates, and reboot-required handling.
13. CrowdSec/Cloudflare operations, notification/email tests, timers, and common troubleshooting.
14. A short "where things live" table for config, encrypted secrets, operational key, persistent data mount, backups, runtime transient state, installed release/current link.

Avoid a maintainer-first wall of architecture prose. For each operator procedure, state prerequisite, exact command/menu path, expected success, and what to do on failure.

FINAL ACCEPTANCE
Keep tests proportional: focused unit, small integration, disposable real-host release acceptance. Do not recreate V1's large custom test inventory.

Acceptance must cover, where environments are actually available:
- clean Ubuntu 24.04 install on amd64 and arm64;
- root-only/no-separate-storage install refusal;
- real dedicated volume mount, identity, boot guard, and restart safety;
- config/secrets setup and no plaintext leakage;
- custom xcaddy modules + Cloudflare trusted client IP + fail-closed origin;
- `/admin` protection and auth rate limiting;
- start/status/doctor/dashboard;
- backup -> verify -> rclone publish/verify -> guided restore on dedicated storage;
- complete recovery-kit AES-256 ZIP verification and SMTP email path;
- normal stable project update plus pre-update recovery and rollback boundary;
- explicit use-latest exact freeze;
- update-check timer and separate host-upgrade/reboot-required behavior;
- systemd timers and representative notification path.

Never claim an architecture/platform/destructive test passed when it was not run. Document unavailable real-host coverage honestly.

CLEANUP / COMPLEXITY PASS
- Remove superseded wrappers/files/docs/tests rather than leaving compatibility aliases without current value.
- Verify the dashboard does not duplicate backend logic.
- Verify setup has no boot-volume fallback.
- Verify no Postfix/queue, public backup tiers, V1 migration reader, generic plugin/storage/update framework, HA/Kubernetes, or giant repair command survived/reappeared.
- Prefer elegant ownership over line-count/file-count games.

FINAL RESPONSE
- Summarize release-neutral renames and deleted stale surfaces.
- Summarize the final administrator documentation map.
- Report exact unit/integration/real-host acceptance run and not run.
- List remaining known limitations appropriate for a small team.
- State whether the branch is ready to become the normal release/mainline product without V1/V2/beta naming leakage.
```

</details>

---

## Human merge/review guardrails

- Each workstream should be reviewable as one coherent product concern; do not combine unrelated cleanup.
- Every workstream after 0 verifies the previous required behavior is already on its base.
- Dedicated storage is a hard production invariant, including boot/restart safety; no silent root-volume fallback.
- V1 UI/UX may be carried forward; V1 implementation architecture is not.
- `vwctl` remains the dangerous-operation authority; dashboard/setup wrappers do not create parallel state machines.
- Caddy trusted-proxy module removes duplicate Caddy CIDR generation but does not remove the host origin firewall.
- Recovery-kit ZIP and `.vwrec` are distinct and both have explicit custody/security purposes.
- Updates stage expensive work before downtime and never fake a downgrade after possible database migration.
- `--use-latest` always freezes exact values for the run; no floating production state.
- Ubuntu package upgrades remain separate from application rollback claims.
- Current notification provider behavior is preserved unless a focused, documented provider change is required; CyberPersons 429/500 are not status-only transient fallback cases in the current catalog.
- Tests protect behavior/security/recoverability, not private source layout.
- Avoid speculative abstractions and file proliferation. For this small deployment, straightforward code and clear ownership are features.
