# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-19
Status: V2 target architecture supporting the authoritative Codex prompts.

> **Authority:** `reports/V2-CODEX-PROMPTS.md` is the agent execution contract. This file describes the target architecture and rationale. If this file and a pasted implementation prompt conflict, the implementation agent follows the pasted prompt and reports the stale supporting text.

## 1. Product objective

V2 is a greenfield, fresh-install Vaultwarden appliance for a small team of roughly 10 users and a junior administrator. It is not a compatibility release of V1.

Optimize for:

1. clear security boundaries;
2. predictable recovery;
3. junior-admin diagnosability;
4. a small project-owned code and file surface;
5. reproducible production installs;
6. Ubuntu 24.04 LTS on amd64 and arm64;
7. low ongoing test and maintenance cost.

The governing design rule is: **delegate specialized work to mature tools, and keep project code focused on orchestration, validation, diagnostics, and safe state transitions.**

## 2. Supported beta boundary

V2 beta supports:

- Ubuntu 24.04 LTS Noble;
- amd64 and arm64;
- cloud-provider-neutral runtime;
- OCI A1 Flex as a reference deployment only;
- Cloudflare-first production ingress;
- CrowdSec for proxied web-client detection/remediation through Cloudflare;
- Vaultwarden + Caddy containers;
- Python 3.12 stdlib-first project logic;
- SOPS + Age secrets;
- rclone offsite recovery workflows;
- Vaultwarden direct authenticated SMTP;
- built-in HTTPS operational-email providers: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, and `cyberpersons` (CyberPanel Email / CyberPersons), with `cyberpanel` as an alias to the same definition;
- one source-controlled non-secret provider catalog, `email-providers.toml`;
- direct authenticated SMTP fallback for clearly transient operational-email API failures after bounded retry;
- one encrypted V2 recovery format plus separate offline recovery material;
- systemd lifecycle/timers;
- exact production version pins and development/test-only `--use-latest`.

V2 beta intentionally does **not** support:

- V1 state, archive, backup-format, migration, command, or runtime-layout compatibility;
- Kubernetes, Swarm, HA, or distributed coordination;
- generic cloud, storage, notification, secrets, or firewall provider frameworks;
- runtime-loaded notification plugins, arbitrary provider code, or Python entry-point discovery;
- arbitrary operator overrides of provider endpoints/authentication/payload templates;
- a CrowdSec host firewall bouncer or a second CrowdSec enforcement plane in beta;
- a dashboard/TUI;
- a mandatory Postfix/local-MTA container;
- a project-built durable notification queue;
- multiple public backup tiers;
- a custom test runner/inventory;
- unattended auto-update daemons.

## 3. Language and file-surface model

### Python owns structured logic

Use Ubuntu 24.04's Python 3.12 and prefer the standard library at runtime. Python owns structured/stateful behavior such as:

- `vwctl` CLI parsing and dispatch;
- TOML config/version/provider-catalog parsing and validation;
- normalized errors and subprocess execution;
- architecture mapping;
- `fcntl.flock` mutation locking;
- status/doctor JSON;
- SOPS/Age orchestration;
- notification provider-template rendering, HTTPS/SMTP delivery, and failure classification;
- backup metadata, recovery validation, retention decisions, and rclone orchestration;
- restore preflight/promotion;
- Cloudflare CIDR policy;
- structured systemd/template generation where useful.

Do not introduce a framework, dependency-injection system, dynamic plugin registry, ORM, event bus, workflow engine, daemon, generic provider SDK, or speculative extension architecture.

### Bash is minimal glue

Bash is acceptable only for:

- the smallest bootstrap needed before `vwctl` is installed;
- very small host glue where shell is materially clearer;
- container entrypoint behavior required by an upstream image.

If shell begins owning config parsing, structured data, state machines, retry policy, complex locking, or broad mocks, that logic belongs in Python.

### Prefer fewer cohesive files

Reducing first-party file count is a **design preference, not a quota**.

- Reuse an existing owning file when a new behavior naturally belongs there.
- Avoid one-function modules, one-action wrapper scripts, duplicate config fragments, empty placeholders, and future-facing extension files.
- Delete obsolete V1 surfaces on the V2 branch when they are no longer required.
- `email-providers.toml` is a deliberate single-file resource because it replaces repeated provider constants/request definitions and avoids one source module per provider.
- Do not game the preference by creating giant catch-all files or mixing unrelated responsibilities. Security boundaries, readability, and testability take priority.

## 4. Runtime authorities and filesystem

V2 has one clear authority for each class of state:

```text
/opt/vaultwarden-oci/
  releases/<release>/       immutable application release, including provider catalog
  current -> releases/...   active release

/etc/vaultwarden-oci/
  config.toml               sole installed operator-editable non-secret config
  age-key.txt               root-only operational Age private identity

/var/lib/vaultwarden-oci/
  data/                     Vaultwarden persistent data
  caddy/                    Caddy persistent state
  backups/                  encrypted local V2 recovery points
  state/                    only small persistent project state that is truly needed

/run/vaultwarden-oci/
  secrets/                  decrypted ephemeral secret material
  transient/                other bounded volatile state
  lock                      global mutating lock
```

Use one source-controlled `versions.toml` for production component versions.

Use one source-controlled `email-providers.toml` for built-in operational-email transport definitions. It is **project/release data, not a second operator configuration authority**. Maintainers edit it in source and ship it with the immutable application release. Operators select a provider and allowed provider-specific options through `/etc/vaultwarden-oci/config.toml`.

Phase 0/3 must establish one canonical installed path for the structured SOPS-encrypted secrets document. There must never be two operator-editable representations of the same secret/config state.

If a dedicated data volume is used, mount the persistent-state root at the same runtime path instead of creating a second configurable application root.

## 5. Operator interface and diagnostics

Expose one public production CLI: `vwctl`.

Expected public surface remains intentionally small:

```text
vwctl install
vwctl start|stop|restart|status
vwctl logs [SERVICE]
vwctl doctor [--json]
vwctl config show|validate|edit
vwctl secrets edit|rotate|check
vwctl backup
vwctl restore
vwctl update check|apply
vwctl versions
```

Only add nested component troubleshooting commands when an operator need is demonstrated.

`vwctl doctor` is read-only by default and emits stable check IDs with PASS/WARN/FAIL/SKIP plus optional JSON. Human prose is not an API. Do not turn doctor into a broad automatic-repair framework.

## 6. Secrets: SOPS + Age

Keep SOPS + Age. The improvement over V1 is smaller project-owned orchestration, not a different cryptosystem.

Contract:

- one structured SOPS-encrypted secrets document;
- one operational Age private identity stored root-only on the host;
- separate offline recovery material/recipient whose private recovery key is not persisted on the server;
- decrypted runtime material only in a root-owned volatile directory;
- SOPS and Age remain external cryptographic tools;
- no project-built cryptography, secrets server, cloud-KMS abstraction, or secrets-provider registry.

Secrets may include Vaultwarden admin material, Cloudflare/CrowdSec credentials, SMTP credentials, `email_api_token`, and rclone credentials when not kept in a separately root-protected rclone configuration.

Never place plaintext secrets in `config.toml`, `email-providers.toml`, process arguments, normal logs, persistent temporary files, or notification diagnostic state.

## 7. Core runtime

The normal Compose stack contains only:

1. Vaultwarden;
2. Caddy.

Retain useful container hardening where compatible:

- explicit users;
- `cap_drop: ALL` plus only demonstrated additions;
- no-new-privileges;
- read-only root filesystems where practical;
- tmpfs for transient paths;
- bounded logs;
- health checks;
- reasonable memory/PID limits.

Vaultwarden application email uses Vaultwarden's own direct authenticated SMTP support. No Postfix container is required.

## 8. Project operational notifications

Project notifications are separate from Vaultwarden application mail.

```text
vwctl/systemd operation
        |
        v
operator-selected built-in HTTPS provider
        |
        | clearly transient failure after bounded retry
        v
direct authenticated SMTP fallback
```

### Built-in provider set

Canonical provider IDs are:

```text
mailersend
sendgrid
mailgun
postmark
resend
cyberpersons
```

`cyberpanel` is an alias resolving to the single `cyberpersons` definition. Do not duplicate its provider block.

The operator selects one provider in `config.toml` and supplies credentials through SOPS. Use common secret `email_api_token` where supported. Mailgun may additionally require declared non-secret region/domain settings.

### Canonical message context

Provider templates use exactly this canonical message vocabulary:

```text
from_email
from_name
from_header
to_email
subject
text
```

`from_header` is derived safely from `from_name` and `from_email`; it is not a second operator-entered identity. Provider request templates map these canonical values to provider-specific request field names such as `from` or `to`.

Do not introduce alternate synonyms such as canonical `to` versus `to_email` in different documents or code paths.

### CyberPanel Email / CyberPersons baseline

Current official CyberPanel Email documentation, verified 2026-08-19, specifies:

- send endpoint: `POST https://platform.cyberpersons.com/email/v1/send`;
- recommended authentication: `Authorization: Bearer <API key>`;
- API key requires `can_send` for sending and may be restricted by domain/IP;
- request supports `from`, `to`, `subject`, and at least one of `html` or `text`; V2 operational alerts use plain text;
- accepted submission: HTTP `202` with JSON `success: true` and a message identifier;
- HTTP `400` is invalid request; documented HTTP `403` cases are domain/account/permission failures;
- HTTP `429 rate_limit_exceeded` is transient/retryable after bounded retry;
- HTTP `503 service_unavailable` is explicitly temporary and transient/retryable;
- HTTP `500 send_failed` is **not transient by status alone**. Provider troubleshooting says causes can include recipient rejection, invalid recipient, or a blocklisted domain. V2 therefore fails it visibly and does not SMTP-fallback merely because the HTTP status is 500. A future implementation may only classify a more specific 500 condition as transient if then-current official provider documentation clearly supports that distinction;
- CyberPanel SMTP, if chosen for the generic fallback, is `mail.cyberpersons.com:587` with required STARTTLS and separate generated SMTP credentials.

The current API documentation says a 429 response includes a JSON `retry_after` field, but the documentation reviewed for this architecture does not define enough delay semantics to make parsing that field a V2 requirement. **A fixed small bounded retry schedule is acceptable for CyberPersons 429.** If implementation-time official documentation clearly defines a numeric retry delay and its units, the closed catalog may use the narrow retry-delay capability described below.

Do not assume API and SMTP credentials are interchangeable.

### Editable provider catalog

`email-providers.toml` is one source-controlled, non-secret, immutable-release resource. It contains only closed metadata actually needed by the supported built-ins.

The schema may represent:

- canonical provider ID, aliases, display name;
- final HTTPS POST endpoint or narrowly constrained endpoint template;
- one closed authentication mode from the finite modes needed by the six built-ins;
- JSON or form request encoding;
- declarative request template using only the six canonical message fields above;
- accepted success status codes;
- at most one simple top-level JSON success-field/value check when HTTP status alone is insufficient;
- provider-documented retryable HTTP status codes;
- ordinary bounded handling of the standard HTTP `Retry-After` header when present and valid;
- **optionally**, one named top-level JSON retry-delay field with one explicitly declared fixed unit, but only when official provider documentation defines that field and unit. No JSONPath, expressions, nested response language, or provider-specific response scripting;
- declared provider-specific non-secret options/defaults/allowed values and narrowly constrained endpoint substitutions;
- credential secret-key name only if a supported built-in cannot use common `email_api_token`.

If a body retry-delay field is absent, malformed, undocumented, or has unclear units, ignore it and use the common fixed bounded retry schedule. Clamp any accepted provider-supplied delay to the project's small global maximum; provider input never creates an unbounded sleep.

The exact TOML schema must be the **smallest schema capable of representing the six providers**, not a general HTTP workflow language.

### Catalog security boundary

- Catalog contains no secret values.
- Endpoints are HTTPS and validated.
- Operator `config.toml` may select a built-in ID/alias and declared non-secret options only; it may not replace endpoint/auth/header/payload/success/retry definitions.
- Reject duplicate IDs/aliases, unknown auth modes/encodings/template placeholders, undeclared substitutions/options, invalid success/retry rules, and unsupported fields.
- Request templates are data, not code: no `eval`, Jinja, Python expressions, shell expansion, dynamic imports, or arbitrary scripting.
- Render with ordinary structured serialization so message values cannot become template/code syntax.
- Authorization-bearing POST requests do not silently follow cross-host redirects. Unexpected redirects fail unless a same-origin behavior is explicitly verified and safely implemented.
- Do not persist full provider response bodies; diagnostics are bounded and redacted.
- The catalog is not a plugin registry. Do not create one provider class/module per built-in merely for symmetry.

### Fallback policy

Fallback occurs only after the small bounded API retry policy and only for a failure classified as clearly transient by network semantics or current provider documentation.

There is **no blanket “all 5xx are transient” rule**. Each provider block records only statuses current official documentation supports as transient. Ambiguous delivery failures remain visible.

Representative `400`/`401`/`403`, malformed configuration/request, permanent rejection, ambiguous semantic delivery failures, unsupported behavior, and TLS certificate/hostname validation failures remain visible and are not silently masked by SMTP success.

SMTP uses normal certificate/hostname validation with implicit TLS or required STARTTLS plus authentication. No plaintext downgrade.

The SMTP fallback may reuse the same upstream authenticated SMTP configuration used by Vaultwarden. If API delivery is configured but SMTP fallback credentials are not, `doctor` reports fallback unavailable rather than pretending redundancy exists.

If both transports fail, persist only a small secret-free result for `status`/`doctor`: transport attempts, outcome/category, safe diagnostic text, and event/time identifier as useful.

Do not build Postfix/local MTA state, spool files, persistent retry scheduling, dead-letter handling, dynamic provider loading, or a provider SDK.

### Provider update workflow

When a provider changes or a future provider is explicitly approved:

1. verify current official API documentation;
2. edit/add one provider block in `email-providers.toml` using the existing closed schema where possible;
3. add only declared non-secret operator settings genuinely required;
4. update focused catalog-render/success/retry/redaction tests;
5. update operator/developer documentation;
6. change Python only if a genuinely new transport capability cannot be represented safely by the current closed schema.

Do not respond to ordinary endpoint/payload/status changes by creating provider classes, one module per provider, entry-point discovery, dynamic imports, a provider package hierarchy, or a generic HTTP engine.

## 9. rclone and recovery

rclone remains first-class because it keeps offsite storage cloud-neutral without project-owned storage-provider APIs.

Small wrapper responsibilities:

- prerequisite/config diagnostics;
- remote connectivity;
- upload/publication;
- remote listing and verification;
- download/staging for restore;
- explicit retention/pruning;
- status/doctor visibility.

Normal offsite publication is:

```text
create candidate recovery point
-> verify local database/archive/encryption/integrity
-> rclone copy/copyto-style publication
-> verify required remote recovery cohort
-> report success
```

Remote deletion is a separate explicit retention/pruning operation. Normal publication must not use destructive `rclone sync` semantics.

Expose one normal V2 recovery product. A recovery point contains a consistent SQLite snapshot, required persistent app/config material, a format-versioned manifest and checksums, and encryption before publication. The operational Age private key is excluded from ordinary recovery artifacts; offline recovery material is separate.

Restore supports V2 format only and validates/decrypts/checks/stages before live mutation. It validates free space/target state, stops services only after preflight, promotes through a small explicit transaction boundary, restores permissions, and health-gates any requested restart.

## 10. Cloudflare ingress and CrowdSec

V2 beta supports exactly one production ingress model: Cloudflare-proxied HTTPS with Caddy.

Origin packet path:

- Docker Engine bridge networking;
- Docker iptables packet-filter backend;
- one small project-owned ingress chain/allowlist path;
- strictly validated Cloudflare IPv4/IPv6 ranges;
- last-known-good cache with bounded staleness;
- fail closed when no safe policy can be established;
- do not claim UFW `INPUT` alone secures Docker-published Caddy ports;
- no nftables/second firewall backend in beta.

Provider security-group/firewall setup is a documented prerequisite, not a cloud API integration.

### CrowdSec beta scope

CrowdSec remains required, but V2 beta uses **one CrowdSec remediation scope**:

- the CrowdSec Security Engine consumes the proxied web signals needed by the product;
- a current supported CrowdSec Cloudflare remediation component enforces relevant web-client decisions at Cloudflare, where the real client IP can be acted on before origin;
- the project-owned iptables path separately limits origin Caddy ingress to Cloudflare source ranges. It is an origin allowlist, not a second CrowdSec decision plane.

Do **not** install/configure a CrowdSec host firewall bouncer as a V2 beta requirement. Host services such as SSH remain protected by the documented provider firewall/security-group and host firewall policy. If future requirements explicitly add CrowdSec remediation for host-visible services, that is a separate architecture decision and must not silently make the firewall bouncer overlap the proxied web path.

Prefer current upstream CrowdSec installation/integration and own only product-specific acquisition/configuration, secure credentials, Cloudflare remediation integration, lifecycle hooks, and diagnostics. Do not port the V1 CrowdSec installer wholesale.

## 11. Concurrency, systemd, and updates

Start with one global mutating lock using `fcntl.flock()`. Read-only status/doctor/logs do not take it. Do not add per-operation/distributed locking without demonstrated need.

Use systemd as the only scheduler/lifecycle manager. Keep permanent units/timers limited to lifecycle plus health, backup, and maintenance automation actually required.

Use one source-controlled `versions.toml`.

- Production install/update uses exact pins.
- `--use-latest` is development/testing-only: resolve once, freeze exact versions/digests for the run, record them, and pass only exact values downstream.
- Updates are explicit operator actions and should validate health, create/verify recovery according to policy, stage an immutable release including matching release resources such as `email-providers.toml`, activate, restart, and health/doctor gate.
- No unattended update daemon.

## 12. Test architecture

Use only three validation layers:

1. focused unit tests for deterministic logic;
2. small integration tests for filesystem/subprocess/Compose/security boundaries;
3. disposable real-host acceptance as a release gate.

Tests protect security, availability, recoverability, and operator truthfulness—not private source layout. Avoid source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, custom runners/inventories, and coverage quotas.

Backup/restore deserves disproportionate attention. Notification tests focus on catalog validation/rendering, deterministic failure classification, safe SMTP fallback, redirect/secret safety, and CyberPersons `500` non-fallback behavior. CrowdSec acceptance verifies the Cloudflare remediation path without adding a firewall-bouncer matrix.

Detailed guardrails live in `reports/V2-TEST-STRATEGY.md`.

## 13. Documentation model

V2 documentation should shrink because the supported product surface shrinks.

Target operator/developer set:

- `README.md`
- `docs/INSTALL.md`
- `docs/OPERATIONS.md`
- `docs/SECURITY.md`
- `docs/RECOVERY.md`
- `docs/DEVELOPMENT.md`

This is a target, not a quota. Combine documents when responsibilities remain clear; do not create one document per internal module.

Use `vwctl --help` as executable command reference and stable doctor JSON/check IDs as machine-readable diagnostic truth. Do not recreate giant generated command-reference docs or grep-heavy documentation policy CI.

V2 docs must not preserve removed V1 migration, backup-tier, Postfix-queue, dashboard, compatibility-alias, or repository/runtime synchronization procedures.

## 14. Delivery sequence and prerequisite rule

The detailed, copy/paste-ready execution contract is `reports/V2-CODEX-PROMPTS.md`.

0. reset `AGENTS.md`, product boundary, and durable decisions;
1. minimal Python/`vwctl` foundation;
2. bootstrap and immutable installed layout;
3. Vaultwarden + Caddy core, SOPS/Age, Vaultwarden SMTP;
4. Cloudflare ingress + CrowdSec Cloudflare remediation;
5. one recovery format + rclone + offline recovery;
6. systemd automation + catalog-driven HTTPS notifications + transient SMTP fallback;
7. pinned versions + explicit updates + dev/test `--use-latest`;
8. beta docs, disposable-host acceptance, and V1 cleanup.

Every standalone Phase N prompt for N > 0 must explicitly verify that **Phase N-1 is present** before implementation. The phase prompt must not rely on the top-of-file sequencing prose being present in a fresh pasted session. If the immediate prerequisite is missing, the agent stops and reports it rather than implementing multiple phases at once.

Run one phase at a time. Split a phase if reviewability requires it; never combine phases merely to reduce PR count.

## 15. Review workflow

`reports/V2-REVIEW-PROMPTS.md` contains PR/phase-specific standalone prompts for a separate review agent. They are reviewer utilities, not an implementation authority.

Reviewer prompts should mirror expected outcomes without becoming a second normative specification. When a detail such as a canonical field name is repeated, it must match the authoritative implementation prompt exactly; if any future discrepancy appears, the implementation prompt wins and the reviewer reports the stale review text.

The review agent does not modify or merge the PR unless a human explicitly turns the review into a follow-up implementation task.

## 16. Architecture review rule

When a task appears to need a new abstraction, first ask whether V2 can support a small explicit implementation instead. For this product, a narrow well-tested path is normally safer and cheaper than a generalized framework.

When a task appears to need a new file, first ask whether an existing owner can absorb the behavior cleanly. Fewer files are preferred when natural, but clear ownership and security boundaries win over a numeric count.