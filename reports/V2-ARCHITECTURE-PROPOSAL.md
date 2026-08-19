# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-19
Status: V2 target architecture supporting the authoritative Codex prompts.

> **Authority:** `reports/V2-CODEX-PROMPTS.md` is the agent execution contract. This file describes the target architecture and rationale. If they conflict, implementation agents follow the pasted Codex prompt and report the inconsistency.

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
- CrowdSec;
- Vaultwarden + Caddy containers;
- Python 3.12 stdlib-first project logic;
- SOPS + Age secrets;
- rclone offsite recovery workflows;
- Vaultwarden direct authenticated SMTP;
- built-in HTTPS operational-email providers: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, and `cyberpersons` (CyberPanel Email / CyberPersons; accept `cyberpanel` as an alias to the same built-in definition);
- one source-controlled, non-secret provider catalog (`email-providers.toml`) so provider transport settings can be maintained without rewriting the notification library;
- direct authenticated SMTP fallback for clearly transient operational-email API failures;
- one encrypted V2 recovery format plus separate offline recovery material;
- systemd lifecycle/timers;
- exact production version pins and dev/test-only `--use-latest`.

V2 beta intentionally does **not** support:

- V1 state, archive, backup-format, migration, command, or runtime-layout compatibility;
- Kubernetes, Swarm, HA, or distributed coordination;
- generic cloud, storage, notification, secrets, or firewall provider frameworks;
- runtime-loaded notification plugins, arbitrary user-supplied provider code, or Python entry-point discovery;
- arbitrary operator overrides of provider API endpoints/authentication that could redirect secrets;
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
- `email-providers.toml` is a deliberate single-file exception because it replaces repeated provider constants/request definitions in Python and makes provider maintenance data-driven.
- Do not game the preference by creating giant catch-all files or mixing unrelated responsibilities. Security boundaries, readability, and testability take priority.

## 4. Runtime authorities and filesystem

V2 should have one clear authority for each class of state:

```text
/opt/vaultwarden-oci/
  releases/<release>/       immutable installed application release, including provider catalog
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

Use one source-controlled `email-providers.toml` for built-in operational-email transport definitions. It is **project/release data, not a second operator configuration authority**. The maintainer edits it in source and ships the changed catalog with an immutable release; ordinary operators select a provider and allowed provider-specific options through `/etc/vaultwarden-oci/config.toml`.

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

Secrets may include Vaultwarden admin material, Cloudflare/CrowdSec credentials, SMTP credentials, the operational `email_api_token`, and rclone credentials when not kept in a separately root-protected rclone configuration.

Never place plaintext secrets in `config.toml`, `email-providers.toml`, process arguments, normal logs, persistent temporary files, or notification diagnostic state.

## 7. Core runtime

The normal Compose stack starts with only:

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

The beta flow is:

```text
vwctl/systemd operation
        |
        v
operator-selected built-in HTTPS provider
        |
        | clearly transient failure after small bounded retry
        v
direct authenticated SMTP fallback
```

### Built-in provider set

V2 supports these explicit built-ins:

```text
mailersend
sendgrid
mailgun
postmark
resend
cyberpersons   # CyberPanel Email / platform.cyberpersons.com
```

Accept `cyberpanel` as an alias resolving to the same `cyberpersons` provider definition; do not maintain duplicate settings for the alias.

The operator selects one provider in `config.toml` and supplies credentials through the V2 secrets mechanism. Use one common `email_api_token` where the provider supports a single API key. Mailgun may additionally require non-secret region/domain settings.

### CyberPanel Email / CyberPersons current contract

The current official CyberPanel Email documentation (verified 2026-08-19) specifies:

- REST send endpoint: `POST https://platform.cyberpersons.com/email/v1/send`;
- recommended API authentication: `Authorization: Bearer <API key>`;
- API key should have `can_send` permission and may be restricted by domain/IP;
- JSON request requires `from`, `to`, `subject`, and at least one of `html` or `text`; V2 operational alerts may use the plain-text form;
- successful submission: HTTP `202` with JSON `success: true` and a `data.message_id`;
- documented non-transient examples: HTTP `400` invalid request and HTTP `403` domain/account/permission failures;
- documented transient candidates: HTTP `429` rate limit (with retry information), `500` send failure, and `503` service unavailable;
- CyberPanel's SMTP delivery service, if chosen for SMTP fallback, is `mail.cyberpersons.com:587` with required STARTTLS and authenticated SMTP credentials generated separately from the API key.

Do not assume the API and SMTP credentials are interchangeable. The generic V2 SMTP fallback remains independently configured and may use CyberPanel SMTP or another authenticated SMTP service.

### Editable provider catalog

Provider details that commonly change must live in **one source-controlled non-secret catalog**: `email-providers.toml`.

The catalog is shipped as immutable release data and is maintainable without rewriting the notification library. It should contain only what the six built-ins actually need, using a closed schema such as:

- canonical provider ID and optional aliases/display name;
- final HTTPS POST endpoint or narrowly constrained endpoint template;
- closed authentication mode (for example bearer token, fixed token header, or basic auth with token) and required fixed non-secret auth metadata;
- request encoding: JSON or form;
- a declarative request template built from a closed canonical message field set such as `from_email`, `from_name`, `from_header`, `to`, `subject`, and `text`;
- accepted success status codes and, only when needed, one small JSON success-field/value check;
- provider-documented retryable HTTP statuses and whether `Retry-After` is honored;
- declared provider-specific non-secret options, defaults, allowed values, and endpoint substitutions where genuinely required;
- the SOPS secret key name used for the credential when it differs from the common `email_api_token` model.

The exact TOML schema should be the **smallest schema capable of representing these six providers**, not a general HTTP workflow language.

Security constraints for the catalog:

- credentials/secrets never appear in the catalog;
- provider endpoints must be HTTPS and validated;
- operator `config.toml` may select a built-in ID/alias and declared non-secret options, but may not supply arbitrary endpoint/auth/header/payload overrides;
- unknown provider IDs, aliases, auth modes, encodings, template placeholders, or undeclared endpoint substitutions fail validation;
- request templates use a closed placeholder set and ordinary serialization; no `eval`, Jinja, Python expressions, shell expansion, or arbitrary code;
- authorization-bearing POST requests do not silently follow cross-host redirects; provider endpoints are expected to be final endpoints;
- secret-bearing response bodies are never persisted, and diagnostics remain bounded/redacted.

**Maintenance rule:** if a provider changes only endpoint, auth metadata, request template, success rule, retry statuses, or declared non-secret settings, maintainers should update that provider block in `email-providers.toml` plus focused tests/docs. Python library changes are required only when a provider introduces a genuinely new transport capability not representable by the existing closed catalog schema.

This is intentionally a **static provider catalog**, not a runtime plugin framework.

### Fallback policy

Fallback is appropriate for clearly transient delivery-path failure such as network/DNS timeout, provider-documented rate limiting after bounded retry, and provider-documented service-side transient errors.

Representative `400`/`401`/`403`, malformed configuration/request, permanent rejection, unsupported provider behavior, and TLS certificate/hostname validation failure remain visible and are not silently masked by SMTP success.

SMTP uses normal certificate/hostname validation with implicit TLS or required STARTTLS plus authentication. No plaintext downgrade.

The SMTP fallback may reuse the same upstream authenticated SMTP configuration used by Vaultwarden when that is the operator's chosen deployment. If API delivery is configured but SMTP fallback credentials are not, `doctor` must report that fallback is unavailable rather than pretending redundancy exists.

If both transports fail, persist only a small secret-free result for `status`/`doctor`: transport attempts, outcome/category, safe diagnostic text, and event/time identifiers as useful.

Do not build Postfix/local MTA state, spool files, persistent retry scheduling, dead-letter handling, dynamic plugin loading, or a provider SDK.

### Future provider/update workflow

Adding a future provider or adjusting an existing provider should follow this order:

1. verify the provider's current official API documentation;
2. update/add one explicit provider block in `email-providers.toml` using the existing closed schema if possible;
3. add only declared non-secret operator settings required by that provider;
4. add focused catalog-rendering/success/retry/redaction tests;
5. update operator documentation;
6. change Python only if the provider genuinely requires a transport feature the current closed schema cannot represent.

Do not respond to ordinary endpoint/payload changes by creating provider classes, one module per provider, entry-point discovery, dynamic imports, a provider package hierarchy, or a generic plugin SDK.

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

Remote deletion is a separate explicit retention/pruning operation. Normal publication must not use destructive `rclone sync` semantics that can remove remote recovery points merely because a local file disappeared.

Expose one normal V2 recovery product. A recovery point contains a consistent SQLite snapshot, required persistent app/config material, a format-versioned manifest and checksums, and encryption before publication. The operational Age private key is excluded from ordinary backup artifacts; offline recovery material is separate.

Restore supports V2 format only and validates/decrypts/checks/stages before live mutation. It validates free space/target state, stops services only after preflight, promotes through a small explicit transaction boundary, restores permissions, and health-gates any requested restart.

## 10. Cloudflare ingress and CrowdSec

V2 beta supports exactly one production ingress model: Cloudflare-proxied HTTPS with Caddy.

- Docker Engine bridge networking;
- Docker iptables packet-filter backend;
- one small project-owned ingress chain/allowlist path;
- strictly validated Cloudflare IPv4/IPv6 ranges;
- last-known-good cache with bounded staleness;
- fail closed when no safe policy can be established;
- do not claim UFW `INPUT` alone secures Docker-published Caddy ports;
- no nftables/second firewall backend in beta.

Provider security-group/firewall setup is a documented prerequisite, not a cloud API integration.

Keep CrowdSec, but prefer current upstream installation/integration and own only product-specific acquisitions/config, secure credentials, selected bouncer integration, lifecycle hooks, and diagnostics. Do not port the V1 installer wholesale.

## 11. Concurrency, systemd, and updates

Start with one global mutating lock using `fcntl.flock()`. Read-only status/doctor/logs do not take it. Do not add per-operation/distributed locking without demonstrated need.

Use systemd as the only scheduler/lifecycle manager. Keep permanent units/timers limited to lifecycle plus the health, backup, and maintenance automation actually required.

Use one source-controlled `versions.toml`.

- Production install/update uses exact pins.
- `--use-latest` is development/testing-only: resolve once, freeze exact versions/digests for the run, record them, and pass only exact values downstream.
- Updates are explicit operator actions and should validate health, create/verify recovery according to policy, stage an immutable release, activate, restart, and health/doctor gate.
- No unattended update daemon.

## 12. Test architecture

Use only three validation layers:

1. focused unit tests for deterministic logic;
2. small integration tests for filesystem/subprocess/Compose/security boundaries;
3. disposable real-host acceptance as a release gate.

Tests protect security, availability, recoverability, and operator truthfulness—not private source layout. Avoid source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, custom runners/inventories, and coverage quotas.

Backup/restore deserves disproportionate attention. Notification tests focus on provider-catalog validation/rendering, deterministic failure classification, safe SMTP fallback, and secret redaction; they do not become a generic provider conformance suite. rclone tests focus on project-owned argv/result behavior and non-destructive publication intent.

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

Developer documentation should explain how to update `email-providers.toml` safely when a provider changes and when a Python change is actually justified.

## 14. Delivery sequence

The detailed, copy/paste-ready execution contract is `reports/V2-CODEX-PROMPTS.md`. The intended order is:

0. reset `AGENTS.md`, product boundary, and durable decisions including the six-provider catalog/config model;
1. minimal Python/`vwctl` foundation;
2. bootstrap and immutable installed layout;
3. Vaultwarden + Caddy core, SOPS/Age, Vaultwarden SMTP;
4. Cloudflare ingress + CrowdSec;
5. one recovery format + rclone + offline recovery;
6. systemd automation + `email-providers.toml` + six built-in HTTPS providers + transient SMTP fallback;
7. pinned versions + explicit updates + dev/test `--use-latest`;
8. beta docs, disposable-host acceptance, and V1 cleanup on the V2 branch.

Run one phase at a time. Split a phase if reviewability requires it; never combine phases merely to reduce PR count.

## 15. Review workflow

`reports/V2-REVIEW-PROMPTS.md` contains standalone prompts intended for a **separate review agent**. Review prompts do not supersede implementation prompts; they tell the reviewer how to audit a PR for completeness, correctness, small-team fit, complexity, validation, and merge safety.

The review agent should not modify or merge the PR unless a human explicitly turns the review into a follow-up implementation task.

## 16. Architecture review rule

When a task appears to need a new abstraction, first ask whether V2 can support a small explicit implementation instead. For this product, a narrow well-tested path is normally safer and cheaper than a generalized framework.

When a provider changes ordinary endpoint/auth/request/success metadata, change the provider catalog rather than the library. When a provider requires a truly new capability, extend the closed catalog schema only as far as the supported built-in set requires; do not generalize into an arbitrary HTTP engine.

When a task appears to need a new file, first ask whether an existing owner can absorb the behavior cleanly. Fewer files are preferred when natural, but clear ownership and security boundaries win over a numeric count.