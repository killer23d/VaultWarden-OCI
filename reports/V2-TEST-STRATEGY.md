# VaultWarden-OCI V2 Test Strategy

Date: 2026-08-19
Status: supporting rationale/guardrails for the authoritative Codex prompts.

> **Authority:** `reports/V2-CODEX-PROMPTS.md` controls agent execution. This file explains why V2 deliberately uses a smaller test architecture.

## Objective

Tests protect four things:

1. security;
2. availability;
3. recoverability;
4. operator truthfulness.

Testing is not a parallel implementation of the product. A test that makes harmless internal refactoring expensive without protecting observable risk is probably at the wrong boundary.

## Why V2 changes the test model

The audited V1 `tests/` tree is approximately 1.18 MB across 30 tracked files—roughly 61% of the byte size of the audited first-party shell/Make implementation set used for comparison. That is only a maintenance-footprint signal, not an LOC or engineering-effort metric.

The stronger finding is architectural coupling. Large V1 cases commonly:

- grep exact private source strings;
- assert private source ordering;
- extract private Bash functions with `awk`/`sed`;
- construct synthetic harnesses around private state;
- duplicate mocked control flows.

V2 does not port that architecture.

## Three validation layers only

### 1. Focused unit tests

Use for deterministic project logic:

- TOML/config/provider-catalog/manifest parsing;
- architecture normalization;
- policy/classification functions;
- Cloudflare CIDR validation/staleness;
- notification provider-template rendering and response/fallback classification;
- backup manifest/checksum/retention decisions;
- version-resolution policy;
- safe result/redaction behavior.

Keep ordinary pytest discovery. No custom registry/modes.

### 2. Small integration tests

Use when filesystem/process behavior is part of the risk:

- real temporary files/directories and permissions;
- subprocess wrapper behavior;
- `fcntl.flock` contention;
- SOPS/Age orchestration at the external-command boundary;
- Compose/runtime rendering and small lifecycle boundaries;
- rclone argv/result behavior at the external-command boundary;
- backup/restore using real temporary SQLite/files/archives;
- systemd unit rendering/installed command targets;
- HTTP/SMTP boundary behavior only where deterministic catalog/classification tests are insufficient.

Prefer real temporary artifacts over large mock state machines.

### 3. Disposable real-host release acceptance

Reserve full-system behavior for a disposable Ubuntu 24.04 host/environment:

- clean install and installed filesystem/permissions;
- amd64/arm64 where environments are available;
- Docker/Compose runtime;
- SOPS/Age materialization without leakage;
- Vaultwarden + Caddy health;
- Cloudflare ingress/fail-closed behavior;
- CrowdSec/bouncer integration;
- backup -> rclone publication -> remote verification -> download -> restore;
- at least one configured built-in HTTPS operational provider + representative transient SMTP fallback;
- systemd units/timers;
- pinned update flow.

Acceptance is a release gate, not a reason to rebuild the V1 stateful acceptance controller on every PR.

## Permanent PR CI

Keep permanent PR CI small:

1. quality/lint/basic repository checks;
2. focused unit tests;
3. small integration tests.

Do not put destructive/full-host acceptance on every ordinary PR unless production evidence later changes the cost/benefit.

## Test ownership rule

**One behavior should normally have one best permanent test level.**

Examples:

- architecture mapping -> unit;
- lock contention -> small integration;
- backup corruption refusal -> integration with real artifacts;
- actual Cloudflare packet path -> release acceptance;
- provider-catalog validation/rendering -> unit;
- real provider delivery -> release/manual acceptance.

Do not duplicate the same behavior at several layers merely for comfort.

## Prohibited patterns

Do not add permanent tests whose main assertion is:

- exact private source text exists;
- one private line appears before/after another;
- a private helper has a specific textual implementation;
- a private function can be extracted from source and run in a synthetic harness;
- human prose matches exactly when stable IDs/JSON fields exist;
- a third-party tool behaves according to its own internals;
- every file touched has its own test.

Do not add:

- a custom test runner/inventory/mode registry;
- a coverage-percentage gate;
- broad matrices without a concrete risk;
- pytest plugins/frameworks without demonstrated need;
- helper modules solely to make tests convenient when the public boundary can be tested directly;
- a generic provider conformance framework or one test module per email provider merely for symmetry.

## Risk-weighted focus

### Backup / restore / rclone

This deserves the strongest permanent test attention because a false success can destroy recoverability.

High-value behavior includes:

- consistent snapshot/manifest construction;
- checksum/corruption rejection;
- wrong-key/decryption failure before live mutation;
- incomplete candidate not reported valid;
- preflight before live mutation;
- non-destructive rclone copy/copyto publication;
- remote verification required before offsite success;
- pruning separate from publication;
- remote download/staging does not mutate live state before validation.

Do not test rclone provider internals.

### SOPS + Age

Test only project-owned responsibilities:

- required secret/schema validation;
- safe external command invocation;
- key/runtime-file permissions;
- no plaintext leakage to normal persistent config/loggable state;
- offline recovery private material is not persisted as the operational host key.

Do not re-test cryptographic algorithms.

### Operational notifications and `email-providers.toml`

V2 beta supports these canonical built-in API providers:

- `mailersend`;
- `sendgrid`;
- `mailgun`;
- `postmark`;
- `resend`;
- `cyberpersons` (CyberPanel Email), with `cyberpanel` accepted only as an alias to the same catalog definition.

The important behavior is safe catalog validation/rendering/classification/fallback, not protocol emulation or a dynamic provider framework.

High-value permanent tests include:

- catalog parses and rejects duplicate IDs/aliases;
- `cyberpanel` resolves to the canonical `cyberpersons` definition rather than duplicating settings;
- unknown provider identifiers fail validation;
- endpoint must be HTTPS and endpoint templates may use only declared non-secret substitutions;
- operator config cannot inject arbitrary endpoint/auth/header/payload overrides;
- unknown auth modes, request encodings, placeholders, success checks, or undeclared provider options fail closed;
- request templates use only the closed canonical message-field set and never evaluate arbitrary code;
- authorization-bearing requests do not silently follow cross-host redirects;
- each built-in provider renders the expected authentication/request shape from the catalog at the project boundary;
- common `email_api_token` and any provider-specific secret never appear in argv/log/result/exception structures;
- Mailgun non-secret region/domain validation where supported;
- API success does not invoke SMTP;
- network/DNS timeout is transient;
- provider-documented retry statuses become fallback-eligible only according to bounded retry policy;
- representative `400`/`401`/`403` stays visible;
- provider-specific success parsing is tested only where HTTP status alone is insufficient;
- TLS certificate/hostname validation failure is not silently masked;
- SMTP uses the configured secure mode at a stable mocked boundary;
- both transports failing produces stable secret-free diagnostic state.

CyberPanel/CyberPersons current catalog behavior should additionally be represented by focused tests matching the verified official contract at implementation time: Bearer auth, `POST https://platform.cyberpersons.com/email/v1/send`, plain-text JSON message shape, HTTP `202` plus `success: true`, and the current documented retry/non-retry categories. If the official API changes before implementation, update the catalog and tests to the current verified contract rather than freezing this report as upstream truth.

Do **not** multiply every provider across every test layer. One focused catalog-render/auth/success-rule test per built-in provider plus shared classifier/fallback/security tests is normally enough. Real delivery against every commercial provider does not belong in ordinary PR CI.

A routine provider settings change should normally change `email-providers.toml` plus the smallest affected tests/docs, not production Python. Add Python tests/code only if the provider truly requires a new transport capability that the closed catalog schema cannot represent.

### Cloudflare / CrowdSec / firewall

Unit-test parsing/policy, integration-test external-command boundaries, and reserve actual packet-path behavior for disposable-host acceptance. No multi-backend matrix.

### `vwctl doctor`

Test stable check IDs, PASS/WARN/FAIL/SKIP classification, JSON shape, exit policy, and secret-free output. Do not freeze exact human prose.

For notifications, `doctor` should distinguish at least: configured built-in provider valid/invalid, API credential present/placeholder, SMTP fallback available/unavailable, provider catalog valid/invalid, and last safe delivery result.

## File-surface guardrail for tests

Test code should remain **obviously subordinate to the product**, not become a second architecture.

- Prefer adding a case to an existing cohesive test module over creating a new file for one small behavior.
- Do not create a test-helper layer that mirrors production modules one-for-one.
- Keep the six provider definitions in one catalog rather than six provider source modules and six matching test modules unless a real ownership boundary emerges.
- If a test module becomes difficult to understand, first ask whether the product boundary or test level is wrong before splitting it into more infrastructure.
- No numeric LOC/coverage/file-count target is authoritative. Metrics may trigger discussion, never design gaming.

## Required PR validation statement

Every V2 agent/task PR should state:

1. behavior changed;
2. smallest validation sufficient;
3. highest-value permanent test layer;
4. duplicate tests intentionally not added;
5. exact tests/validation actually run;
6. validation not run and why;
7. new test/support files created and why they were necessary;
8. out-of-scope follow-ups discovered.

This keeps validation proportional to risk instead of allowing test infrastructure to expand automatically with every implementation change.