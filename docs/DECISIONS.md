# VaultWarden-OCI durable decisions

Status: accepted durable product and implementation decisions.

This file complements `docs/PROJECT-BOUNDARY.md`. It intentionally consolidates the durable contract rather than creating one ADR per bullet. Historical audit reports remain evidence and rationale, not competing product authority.

## 1. Product and compatibility boundary

**Decision:** VaultWarden-OCI is a fresh-install small-team appliance for roughly 10 users, operated by a junior administrator on Ubuntu 24.04 LTS. `amd64` and `arm64` are supported/tested targets and the runtime remains cloud-provider neutral.

The earlier product is intentionally retained as a **UI/UX, security, and behavioral design reference**. Its backend architecture is **not** a compatibility target. Do not recreate Make orchestration, Postfix/queue machinery, multiple backup tiers, migration/archive compatibility, broad helper libraries, broad repair commands, generic Docker cleanup, or the old implementation/test shape merely because they existed before.

## 2. Language and ownership boundary

**Decision:** Python 3.12 standard-library-first owns structured logic. Bash is limited to thin bootstrap, supported interactive UI, host/container glue, or cases where shell is materially simpler.

Python owns configuration/version parsing, CLI dispatch, normalized subprocess execution, validation, locking, diagnostics, SOPS/Age orchestration, notification catalog/transport orchestration and failure classification, recovery metadata/orchestration, rclone orchestration, update transactions, and Cloudflare origin policy.

`vwctl` is the implementation and mutation authority. `setup.sh` and `dashboard.sh` are supported human interfaces and may orchestrate `vwctl`, but must not become independent mutation implementations.

Do not introduce frameworks, dynamic plugin/provider registries, ORMs, daemons, databases, event buses, workflow engines, generic transaction frameworks, distributed locks, Kubernetes/Swarm/HA layers, storage abstractions, updater daemons, or new monitoring stacks without a new explicit product decision.

## 3. Production storage invariant

**Decision:** Production persistent application state must reside on a dedicated storage filesystem/volume separate from the boot/root filesystem. A root-only production host is unsupported.

The setup/install path must validate this before accepting a production installation. Persistent application/recovery state must not silently fall back to root when the dedicated storage is unavailable. Host startup must fail safely rather than starting the application against the wrong filesystem.

The exact mount path/device mechanics are implementation details, but there is only one supported production invariant: persistent application state is on dedicated storage.

## 4. Configuration, secrets, and release authorities

**Decision:** There is one installed operator-editable non-secret configuration authority under `/etc/vaultwarden-oci`, one structured encrypted SOPS secret document, and one source-controlled exact version manifest.

Current canonical authorities are:

```text
/etc/vaultwarden-oci/config.toml
/etc/vaultwarden-oci/secrets.sops.yaml
versions.toml
```

`email-providers.toml` is immutable source-controlled release metadata, not a second operator-editable config authority. Operators may select supported provider IDs/options through normal config but may not define arbitrary endpoints, auth modes, headers, payload templates, success rules, retry rules, or general HTTP behavior.

Do not create a repository `.env` -> installed env -> generated env synchronization chain or another operator-editable representation of the same configuration.

## 5. First-run setup and `--use-latest`

**Decision:** The normal first-run experience is `setup.sh`.

It must:

1. validate Ubuntu/architecture and dedicated production storage;
2. install required dependencies;
3. install the appliance;
4. prepopulate normal configuration from operator inputs;
5. assist creation/custody of secrets and recovery material;
6. leave an explicit config/secrets -> start path with truthful success/failure guidance.

`setup.sh` supports interactive operation, `--auto`, and an independent explicit `--use-latest` override. `--auto` does not imply `--use-latest` and means automatic installation steps, not necessarily a fully headless recovery-custody workflow.

When setup is attached to an interactive terminal and no `--offline-recipient` was supplied, both normal interactive setup and terminal-driven `--auto` may generate the separate offline Age identity only in root-owned volatile storage, pass only its public recipient into the installation owner, and require the existing verified recovery-kit handoff before deleting the private identity. For this generated-custody path, setup completes and validates the external runtime config/SOPS credentials needed for a truthful complete initial kit and authenticated SMTP delivery before the kit is published or email is offered. The recovery-kit passphrase and final custody acknowledgement remain interactive security boundaries even when the install steps use `--auto`.

A fully headless `--auto` run has no safe private-key handoff channel, so it must require an existing public `--offline-recipient` and fail before storage provisioning or other installation mutation when that custody input is missing. An explicitly supplied recipient is authoritative and must never be silently replaced by a generated recipient.

Frontend decisions about recipient presence, `--auto`, and `--use-latest` must use the authoritative setup CLI grammar/parser. Do not infer value-option presence from exact raw argv tokens in a way that can disagree with supported split, equals, or parser-accepted long-option forms.

`--use-latest` is a supported explicit operator choice, not a development-only feature. It resolves each remote version/image boundary once, freezes exact immutable values/digests, and records/uses only those values. It must never leave floating `latest` state behind.

Normal production releases remain exact and immutable after resolution.

## 6. Day-2 operator interface

**Decision:** `dashboard.sh` is a supported human day-2 interface, using the useful color-coded/AMTM-style interaction conventions of the earlier product as its visual/interaction reference.

The dashboard may display health/state and guide operations, but mutations must delegate to `vwctl`. One implementation authority does not mean one user interface.

`vwctl status`, `vwctl doctor [--json]`, logs, and explicit CLI forms remain first-class for automation and troubleshooting.

## 7. SOPS + Age and recovery identity custody

**Decision:** SOPS + Age remains the secret mechanism with one structured encrypted document and separate operational/offline identities.

The operational Age private key is root-only on the server. The separate offline recovery private identity is never persistent server state. It normally remains off-host; the supported first-run terminal custody flow may hold a newly generated offline identity only in root-owned volatile storage until the verified recovery-kit handoff completes. After successful handoff, that transient host-side private identity must be removed. If handoff fails or is not acknowledged, setup must report the retained volatile identity truthfully so the operator can secure that exact identity before reboot.

Plaintext secrets do not belong in operator TOML, release metadata, argv, ordinary logs, or persistent temporary files.

SOPS/Age provide cryptography. Do not add project cryptography, a KMS abstraction, a secrets-provider framework, or a second secrets authority.

## 8. Recovery kit versus application recovery

**Decision:** The password-protected recovery-kit ZIP is a separate credential-handoff artifact from the normal `.vwrec` application recovery point.

Recovery-kit rules:

- AES-256 encrypted ZIP;
- passphrase entered and confirmed interactively;
- passphrase independent of stored project credentials;
- passphrase never supplied via argv, environment variable, file, or email;
- encrypted ZIP fully verified before email is attempted;
- email failure must not be represented as successful handoff;
- setup-generated custody completes/validates required external runtime credentials before publishing the initial complete kit, so SMTP delivery is actually available and the kit is not frozen before those credentials exist;
- first-run generated custody includes the matching offline recovery private identity plus the operational identity and current generated/SOPS-managed credential values;
- a setup-generated offline identity is removed from host-side volatile storage only after successful handoff.

Application recovery remains one encrypted `.vwrec` format. There is no public `db`/`full`/`emergency` tier model and no compatibility reader for the earlier archive format.

Human restore has a guided local/remote picker in the useful style of the earlier product while explicit noninteractive CLI forms remain for automation.

## 9. Caddy build and real-client-IP ownership

**Decision:** Caddy remains an exact-pinned xcaddy custom build carrying the useful modules from the earlier product:

- Cloudflare DNS;
- Cloudflare trusted-proxy/real-client-IP support;
- combined Cloudflare IP ranges;
- Caddy rate limiting.

Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. Do not also generate a static Cloudflare CIDR list for `trusted_proxies` in Caddy.

Caddy-side rate limiting is used for lightweight abuse controls including `/admin` and selected authentication/API paths.

## 10. Cloudflare origin security and CrowdSec

**Decision:** Real-client-IP trust and origin network filtering are separate controls.

The project owns one small fail-closed Docker `DOCKER-USER` origin-filter path using strictly validated Cloudflare IPv4/IPv6 source ranges. A bounded last-known-good policy may be used. If neither current nor acceptably fresh last-known-good policy is safe, published HTTPS ingress fails closed.

The Caddy trusted-proxy module does **not** replace this host-level origin protection.

CrowdSec remediates proxied web-client decisions through Cloudflare. A CrowdSec host firewall bouncer is not required. The origin filter and CrowdSec Cloudflare remediation are separate decision planes.

Do not add a second firewall backend or generic firewall/cloud-provider abstraction.

## 11. `/admin` defense in depth

**Decision:** Preserve a small, understandable `/admin` defense-in-depth stack:

1. Vaultwarden admin token;
2. Caddy-side rate limiting;
3. one simple outer authentication gate.

Do not add an enterprise identity stack or multiple redundant outer gates.

## 12. Mail and operational notification catalog

**Decision:** Vaultwarden application mail and project operational notifications are separate concerns.

Vaultwarden application mail uses direct authenticated SMTP.

Operational notifications retain the existing closed built-in HTTPS provider catalog. Canonical IDs remain:

```text
mailersend
sendgrid
mailgun
postmark
resend
cyberpersons
```

`cyberpanel` remains an alias of `cyberpersons`, not a separate transport definition.

The canonical provider-template message vocabulary remains exactly:

```text
from_email
from_name
from_header
to_email
subject
text
```

Routine provider endpoint/auth/request/success/retry changes belong in `email-providers.toml` plus focused tests/docs when the existing schema can represent them safely. Python changes are reserved for a genuinely new transport capability.

### Delivery and fallback policy

Primary HTTPS delivery uses a small bounded retry. Authenticated SMTP fallback is eligible only for failures clearly transient by network semantics or current official provider documentation.

There is no blanket all-`5xx`-is-transient rule. Permanent, authentication, TLS-validation, malformed request/configuration, and ambiguous delivery failures remain visible.

### CyberPersons current verified behavior

Preserve the current catalog/implementation behavior unless official provider documentation is deliberately re-verified for a focused change:

- HTTP `503 service_unavailable` is status-only transient/retry/fallback eligible;
- HTTP `429 rate_limit_exceeded` is **not** transient by status alone because current provider behavior covers account-wide minute/hour/day/month limits shared across API and SMTP credentials;
- HTTP `500 send_failed` is **not** transient by status alone and is not SMTP-fallback eligible merely because it is HTTP 500.

Do not reintroduce the older assumption that CyberPersons 429 is automatically transient.

There is no Postfix/local MTA, durable queue, spool, dead-letter system, persistent retry scheduler, dynamic provider loading, arbitrary HTTP scripting, provider SDK, or generic notification registry.

## 13. Recovery publication and restore

**Decision:** Normal offsite publication is:

```text
create candidate recovery point
-> verify required local contents/integrity/encryption
-> rclone copy/copyto-style publication
-> verify the required remote recovery point
-> report offsite success
```

Normal publication must not use destructive `rclone sync`. Retention/pruning/deletion is a separate explicit operation.

Restore validates/decrypts/checks/stages before live mutation and uses a small explicit promotion boundary. The offline recovery identity remains separate; the operational Age private key is excluded from ordinary recovery artifacts.

No storage-provider framework or background replication daemon is introduced.

## 14. Application updates

**Decision:** Normal application updates are safe, explicit, and operator-driven.

The intended flow is:

```text
discover a stable project release
-> resolve/stage/download/build before downtime
-> verify a pre-update recovery point
-> activate an immutable exact release
-> health-gate
-> roll back coherently when safe
```

Automatic update checking/notification is desirable. Unattended application update apply is not the default.

Rollback must respect persistent-state safety. If candidate runtime activation may have changed persistent state, do not blindly switch binaries backward and pretend that application state was rolled back; the verified pre-update recovery point is the downgrade boundary.

## 15. Ubuntu host package updates

**Decision:** Host package updates are a separate workflow from application updates.

Application recovery does not claim to roll back apt/kernel changes. The project may guide safe Ubuntu package maintenance, but it must never auto-reboot the host.

## 16. Testing boundary

**Decision:** Permanent validation has three layers:

1. focused unit tests;
2. small integration tests;
3. disposable real-host Ubuntu 24.04 release acceptance on `amd64` and `arm64` where environments are available.

Tests protect security, availability, recoverability, and operator truthfulness. Setup/custody coverage must protect the explicit-recipient boundary, supported CLI value forms, headless fail-closed-before-mutation behavior, and transient-key cleanup after handoff. Do not add permanent private source-string/order assertions, prose freezing, duplicated state machines, a custom test-runner product, or a coverage-percentage gate.

## 17. Documentation contract

**Decision:** Administrator documentation is a user manual first. It should provide exact steps, expected success, and recovery/troubleshooting guidance, while distinguishing current implementation limitations from approved product behavior.

The documentation must distinguish terminal-driven `--auto` from fully headless automation: the former may still require human recovery-kit custody when setup generates the offline identity; the latter must provide a pre-existing public recipient. Do not use “noninteractive” as shorthand for both custody modes when that would obscure this security boundary.

Keep the durable documentation set small. Update current authorities instead of creating a new ADR/report for every correction.

## 18. Release-neutral naming end state

**Decision:** Normal product/repository surfaces are release-neutral. Do not leave product-generation names, branch-stage names, preview labels, or implementation-stage labels in normal runtime/docs/file names. Genuine technical schema/archive format version numbers remain valid.

The repository follows this release-neutral end state; future changes must not reintroduce stage-era naming into normal product surfaces.

