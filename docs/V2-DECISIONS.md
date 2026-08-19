# VaultWarden-OCI V2 durable decisions

Status: accepted Phase 0 decisions for V2 implementation.

This file records the minimum durable implementation decisions needed before runtime coding. It complements the concise product boundary in `docs/PROJECT-BOUNDARY.md` and the rationale in `reports/V2-ARCHITECTURE-PROPOSAL.md`; it is intentionally one consolidated decision record rather than one ADR file per bullet.

If this file conflicts with the complete task prompt copied from `reports/V2-CODEX-PROMPTS.md`, the task prompt controls that implementation session and the conflict must be reported.

## 1. Language and ownership boundary

**Decision:** Python 3.12 standard-library-first owns structured logic. Bash is limited to the smallest bootstrap, host/container glue, or another case where shell is materially simpler.

Python owns configuration/version parsing, CLI dispatch, normalized subprocess execution, validation, locking, diagnostics, SOPS/Age orchestration, notification catalog/transport orchestration and failure classification, recovery metadata/orchestration, rclone orchestration, and Cloudflare origin policy.

A runtime third-party Python dependency requires a concrete need. Do not introduce frameworks, dynamic plugin/provider registries, ORMs, daemons, databases, event buses, workflow engines, generic transaction frameworks, distributed locks, or speculative extension layers.

## 2. Configuration, release metadata, and version authorities

**Decision:** V2 has exactly one installed operator-editable non-secret configuration authority and one source-controlled version authority:

```text
/etc/vaultwarden-oci/config.toml
versions.toml
```

Do not create a repository `.env` -> installed env -> generated env synchronization chain or another operator-editable representation of the same configuration.

Source-controlled immutable application metadata is not an operator-editable configuration authority. In Phase 6, operational notification transport definitions live in one source-controlled `email-providers.toml` shipped with the immutable application release. Operators select a supported provider/alias and declared non-secret options through `config.toml`; they do not edit the release catalog in place as normal configuration.

Production consumes exact version pins. Development/testing-only `--use-latest` resolves once at the start of a run, records the exact resolved values, and passes only those fixed values downstream for that run.

## 3. Secrets and Age identities

**Decision:** SOPS + Age remains the V2 secrets mechanism with one structured encrypted document and separate operational/offline identities.

Canonical installed paths are:

```text
/etc/vaultwarden-oci/secrets.sops.yaml   encrypted structured secrets document
/etc/vaultwarden-oci/age-key.txt         root-only operational Age private identity
/run/vaultwarden-oci/secrets/            root-owned volatile decrypted runtime material
```

The encrypted document may contain the operational service credentials required by V2, including Cloudflare/CrowdSec, SMTP, operational notification API credentials, and other product secrets. Plaintext secrets do not belong in `config.toml`, `email-providers.toml`, argv, ordinary logs, or persistent temporary files.

Offline recovery uses a separate Age recipient/private recovery identity. The offline recovery private key is not persisted on the server. The operational Age private key is not included in ordinary recovery artifacts.

SOPS and Age provide cryptography. V2 does not add project cryptography, a KMS abstraction, a secrets-provider framework, or a second secrets authority.

## 4. Cloudflare origin security and CrowdSec

**Decision:** V2 beta supports one production ingress model only: Cloudflare-proxied Caddy through Docker bridge networking and the Docker iptables packet path.

The project owns one small origin allowlist path using strictly validated Cloudflare IPv4/IPv6 ranges. A bounded last-known-good Cloudflare range state may be used; if neither current nor acceptably fresh last-known-good policy is safe, origin ingress fails closed.

CrowdSec is retained for proxied web-client remediation through one current supported Cloudflare remediation component. The CrowdSec Security Engine may consume the product's proxied web signals, but a CrowdSec host firewall bouncer is **not** a V2 beta requirement. Host-visible services such as SSH remain under documented provider firewall/security-group and host firewall policy.

The origin iptables allowlist and CrowdSec Cloudflare remediation are distinct controls. Do not turn the origin allowlist into a second CrowdSec decision plane or silently add host-firewall CrowdSec remediation.

No nftables/second firewall backend or generic firewall/cloud-provider abstraction is part of beta.

## 5. Operational notification delivery and provider catalog

**Decision:** Vaultwarden application mail and project operational notifications are separate concerns.

Vaultwarden application mail uses direct authenticated SMTP.

Project operational notifications support exactly these canonical built-in HTTPS provider IDs in beta:

```text
mailersend
sendgrid
mailgun
postmark
resend
cyberpersons
```

`cyberpanel` is accepted only as an alias that resolves to the same `cyberpersons` provider definition. It is not a separate transport definition.

The operator selects one supported provider or alias in `config.toml`; Phase 0 does not choose a vendor for everyone. Provider IDs outside the six canonical built-ins and the `cyberpanel` alias are rejected.

The common encrypted API credential is the SOPS secret `email_api_token` unless a current provider requirement demonstrably requires a documented exception. Mailgun may additionally require declared non-secret region/domain configuration.

### Closed source-controlled provider catalog

Phase 6 will add exactly one source-controlled non-secret `email-providers.toml` shipped with the immutable application release. Phase 0 records its contract but does **not** create the runtime catalog file.

The catalog is maintainer-editable source/release metadata, not a second operator-editable configuration authority, not a credential store, and not a runtime plugin registry. It owns the closed built-in transport metadata needed for the supported providers, using the smallest schema that can represent those providers safely.

Provider request templates use exactly this canonical message vocabulary:

```text
from_email
from_name
from_header
to_email
subject
text
```

`from_header` is derived safely from `from_name` and `from_email`; the catalog maps the canonical values to provider-specific request fields. Do not introduce alternate canonical synonyms such as `to` in place of `to_email`.

Routine provider endpoint, authentication, request-shape, success-rule, or retry-policy updates should be maintainable by editing the catalog plus focused tests and documentation. The notification Python owner should change only when a provider requires a genuinely new transport capability that cannot be represented safely by the existing closed catalog model.

Operator `config.toml` may select a canonical provider or accepted alias and supply only declared non-secret options. It may not supply arbitrary provider endpoints, authentication modes, headers, payload templates, success rules, retry rules, or general HTTP scripting. Secrets remain in the SOPS document rather than the catalog or operator TOML.

This design deliberately keeps provider definitions in one file rather than repeating constants/templates in Python or splitting one provider per module. It does not create dynamic loading, arbitrary imports, Python entry points, a provider package hierarchy, a provider SDK, or a generic provider registry.

### Delivery and fallback policy

Primary HTTPS delivery uses a small bounded API retry. Authenticated SMTP fallback is eligible only for a failure clearly classified as transient by network semantics or current provider documentation.

There is **no blanket all-`5xx`-is-transient rule**. A provider status is retry/fallback eligible only when the common network semantics or the provider's current official documentation supports that classification. Ambiguous delivery failures remain visible.

Representative `400`/`401`/`403` responses, malformed configuration/request, permanent rejection, ambiguous semantic delivery failures, unsupported provider behavior, and TLS certificate/hostname validation failures remain visible and are not silently converted into success through SMTP fallback.

### CyberPersons baseline

The Phase 0 baseline for CyberPersons, subject to Phase 6 re-verification against then-current official documentation, is:

- HTTP `429 rate_limit_exceeded` is transient/retryable under the bounded API retry policy;
- HTTP `503 service_unavailable` is transient/retryable;
- HTTP `500 send_failed` is **not transient by status alone** and must not trigger SMTP fallback merely because it is HTTP 500; documented causes can include recipient rejection or other non-transient delivery conditions;
- documented `400` and `403` cases remain visible rather than being SMTP-masked.

A future implementation may classify a more specific failure as transient only when then-current official documentation clearly supports that distinction. Phase 6 must re-verify the provider contract before coding.

There is no Postfix/local-MTA requirement, spool, durable queue, persistent retry scheduler, dead-letter system, dynamic provider loading, arbitrary HTTP scripting, Python entry-point mechanism, provider SDK, or generic notification registry.

### Provider catalog maintenance checklist

A provider addition or provider-settings change is an explicit developer change to the closed catalog and existing notification owner:

1. add or update one canonical provider definition or accepted alias in `email-providers.toml`;
2. verify current official endpoint/region, authentication, request, success, rate-limit, and transient-failure behavior;
3. keep only the minimum non-secret provider metadata/options required by the supported transport;
4. keep request templates within the exact canonical message-field set above;
5. keep API credentials in SOPS, using `email_api_token` unless a current provider requirement demonstrably requires another documented secret;
6. update focused tests for catalog validation, alias resolution where applicable, request/auth shape, success, transient/permanent classification, and secret redaction;
7. update operator/developer documentation;
8. change Python only when a genuinely new transport capability cannot be represented safely by the existing catalog contract.

This checklist is not a runtime plugin mechanism.

## 6. Recovery publication and rclone

**Decision:** V2 exposes one normal encrypted recovery format and treats rclone as the first-class cloud-neutral publication/retrieval tool.

Normal offsite publication is:

```text
create candidate recovery point
-> verify required local contents/integrity/encryption
-> rclone copy/copyto-style publication
-> verify the required remote recovery point/cohort
-> report offsite success
```

Normal publication must not use destructive `rclone sync` semantics. Retention/pruning/deletion is a separate explicit operation and must not be a hidden side effect of publication.

Restore supports the V2 format only. It validates/decrypts/checks/stages before live mutation and uses a small explicit promotion boundary. There is no V1 archive reader or public `db`/`full`/`emergency` recovery-tier model.

Offline recovery material remains separate from the encrypted recovery point; the operational Age private key is excluded from ordinary recovery artifacts.

No storage-provider framework or background replication daemon is introduced.

## 7. Testing boundary

**Decision:** V2 has exactly three permanent validation layers:

1. focused unit tests for deterministic logic;
2. small integration tests for filesystem/subprocess/security/process boundaries;
3. disposable real-host Ubuntu 24.04 release acceptance.

Tests protect security, availability, recoverability, and operator truthfulness. Do not add permanent private source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, a custom runner/inventory/mode registry, or a coverage-percentage gate.

One behavior should normally have one best permanent test level. Full/destructive host acceptance is a release gate, not default per-PR machinery.

For operational notifications, focused tests should protect the closed catalog contract, the exact canonical message-field vocabulary, canonical/alias resolution, request construction, documented transient/permanent classification, fallback behavior, and secret redaction without becoming a dynamic-provider conformance framework.

For the edge, permanent tests must preserve the distinction between project-owned Cloudflare source-range origin policy and CrowdSec Cloudflare web remediation; beta tests must not require a CrowdSec host firewall bouncer.

## 8. V1 relationship and phase discipline

**Decision:** V2 is greenfield. V1 may be inspected to preserve a useful security property or understand observed behavior, but its project state, runtime layout, public command aliases, migration machinery, backup formats/tiers, Postfix queue, dashboard/TUI, provider framework ideas, test harnesses, and file/module boundaries are not compatibility requirements.

Implementation proceeds by the phases in `reports/V2-CODEX-PROMPTS.md`. Do not implement later-phase functionality opportunistically; report it as a follow-up instead.

## Decisions intentionally deferred to implementation phases

Phase 0 fixes the product boundaries above but does not invent implementation details that are not yet required. Later phases still need to select/verify, within these boundaries:

- the exact bounded staleness duration for Cloudflare last-known-good ranges;
- exact notification retry counts/backoff within the required small bounded policy;
- the exact `email-providers.toml` schema/field names beyond the fixed canonical message-field vocabulary, and current official endpoint/auth/request/success/transient details for each supported provider at Phase 6 implementation time;
- whether any current supported provider demonstrably requires an API secret in addition to or instead of `email_api_token`;
- exact recovery manifest/archive layout and retention defaults;
- exact rclone configuration custody when an operator does not use encrypted project secrets for it;
- detailed `vwctl` command grammar beyond the phase-specific prompts;
- exact systemd timer schedules and release-acceptance environment mechanics.

Those are implementation/product-detail decisions for their assigned phases, not permission to widen the durable V2 architecture.
