# VaultWarden-OCI V2 Test Strategy

Date: 2026-08-18
Revision: consolidated with the authoritative Codex contract and later SOPS/Age, rclone, and notification decisions.

> **Agent-execution precedence:** `reports/V2-CODEX-PROMPTS.md` is authoritative. This file explains the testing rationale and guardrails. If it conflicts with a phase prompt, the prompt contract wins and this file should be corrected.

## Objective

V2 tests exist to protect the small number of behaviors that can compromise security, availability, recoverability, or operator truthfulness.

Testing is not a parallel implementation of the product. V2 intentionally rejects the V1 pattern where a large amount of test code becomes coupled to private implementation shape and consumes a disproportionate share of change effort.

## Why V2 changes the testing architecture

The audited V1 `tests/` tree is approximately 1.18 MB across 30 tracked files and is roughly 61% of the byte size of the audited first-party shell/Make implementation set used for comparison. That is only a rough maintenance-footprint signal, not an LOC or engineering-effort metric.

The more important finding is architectural coupling. Large V1 cases commonly:

- grep for exact private source strings;
- assert implementation order;
- extract private Bash functions with `awk`/`sed`;
- build synthetic harnesses around private state;
- duplicate complex mocked control flows.

Those tests make legitimate refactoring expensive without necessarily increasing confidence in user-visible behavior.

V2 does not port that test architecture.

## Three validation layers only

### 1. Focused unit tests

Use for deterministic Python logic such as:

- TOML/config/manifest parsing;
- architecture normalization;
- pure policy/classification functions;
- Cloudflare CIDR validation/staleness decisions;
- notification HTTP result classification and fallback eligibility;
- backup manifest/checksum/retention decisions;
- version resolution policy;
- safe result/redaction behavior.

Unit tests should be fast, isolated, and ordinary pytest tests.

### 2. Small integration tests

Use for boundaries where the filesystem/process behavior matters:

- real temporary files/directories and permissions where practical;
- subprocess wrapper behavior;
- `fcntl.flock` contention;
- SOPS/Age orchestration at the external command boundary;
- Compose/runtime rendering or lifecycle boundaries;
- rclone argv/result behavior at the external command boundary;
- backup/restore using real temporary SQLite/files/archives;
- systemd unit rendering/installed command targets;
- small HTTP/SMTP boundary tests only where they add confidence beyond deterministic classification tests.

Prefer real temporary artifacts over large mock state machines.

### 3. Disposable real-host release acceptance

Use release acceptance to verify what cannot be proven economically in unit/integration tests:

- clean Ubuntu 24.04 install;
- amd64/arm64 behavior where environments are available;
- Docker/Compose and installed filesystem/permissions;
- SOPS/Age secret materialization without leakage;
- Vaultwarden + Caddy health;
- Cloudflare ingress and fail-closed rule establishment;
- CrowdSec/bouncer integration;
- backup -> rclone publication -> remote verification -> download -> restore;
- HTTPS operational notification delivery and representative SMTP transient fallback;
- systemd lifecycle/timers;
- pinned update flow.

Acceptance is a release gate, not a reason to recreate a massive per-PR stateful controller.

## Permanent PR CI

Keep permanent PR CI deliberately small:

1. quality/lint/static repository checks;
2. unit tests;
3. small integration tests.

Do not put full destructive host acceptance on every ordinary PR unless later evidence shows that the cost/benefit changed.

## Prohibited test patterns

Do not add permanent tests whose primary assertion is:

- an exact private source string exists;
- a private line appears before/after another private line;
- a private helper has a specific textual implementation;
- an internal function can be extracted from source and executed in a synthetic harness;
- human-facing prose matches exactly when a stable ID/JSON field could be tested instead;
- a third-party tool behaves according to its own documented internals;
- every file touched has a dedicated test.

Do not add:

- a custom test runner/inventory/mode registry;
- a coverage percentage gate;
- broad test matrices without a concrete risk;
- a pytest plugin ecosystem without demonstrated need.

## Test ownership principle

One behavior should normally have one best permanent test level.

Examples:

- architecture mapping: unit;
- lock contention: small integration;
- backup corruption refusal: integration with real temporary artifacts;
- Cloudflare packet path on a real host: release acceptance;
- notification response classification: unit;
- real provider delivery: release acceptance or explicit manual/release validation, not duplicated across unit/integration suites.

Do not duplicate the same behavior at every layer for comfort.

## Risk-weighted focus

### Backup/restore/rclone

This area deserves disproportionate testing because a false success can destroy recoverability.

High-value permanent tests include:

- consistent snapshot/manifest construction;
- checksum/corruption rejection;
- wrong-key/decryption failure before live mutation;
- restore preflight ordering at a behavioral boundary;
- incomplete candidate not reported as valid;
- rclone publication command uses non-destructive copy/copyto-style semantics;
- remote verification is required before reporting offsite success;
- retention/pruning is separate from publication;
- restore/download staging does not mutate live state before validation.

Avoid testing rclone's internal provider implementations.

### SOPS + Age

Protect project-owned behavior only:

- required secret keys/schema validation;
- correct external command invocation without shell interpolation;
- operational key/runtime file permissions;
- plaintext not written to persistent normal config/loggable structures;
- offline recovery material is not silently persisted as the server's operational private key.

Do not re-test SOPS/age cryptographic algorithms.

### Operational notifications

The critical V2 behavior is failure classification and safe fallback, not protocol emulation.

High-value tests:

- API success stops without SMTP;
- DNS/network timeout is classified transient;
- representative `429`/`5xx` becomes fallback-eligible only after the bounded retry policy;
- representative `400`/`401`/`403` remains visible and is not silently masked by SMTP;
- TLS certificate/hostname validation failure is not treated as a transparent fallback condition;
- SMTP fallback uses the configured secure mode through a stable mocked boundary;
- secret-bearing values never appear in result/log/exception structures;
- both transports failing yields a stable safe diagnostic result for status/doctor.

Do not build a fake MTA, persistent queue test harness, or generic provider conformance suite.

### Cloudflare/CrowdSec/firewall

Unit-test parsing/policy decisions, integration-test external command boundaries, and reserve actual packet-path behavior for disposable-host acceptance. Do not introduce a multi-backend matrix.

### `vwctl doctor`

Test:

- stable check IDs;
- PASS/WARN/FAIL/SKIP classification;
- JSON schema/shape;
- exit policy;
- secret-free output.

Do not freeze exact human prose.

## Size/design guardrails

These are review signals, not CI quotas:

- By beta, first-party test code should aim to remain well below production implementation size. Around 35% of first-party implementation LOC is a **warning threshold for design review**, not a target and not a hard gate.
- A single test module approaching roughly 400 lines should trigger a design review: is it covering too many responsibilities, mocking too much, or testing implementation shape?
- A new helper/framework added only to support tests should be challenged: could the product boundary be tested more directly instead?

The goal is maintainability and confidence, not optimizing a metric.

## Required PR validation statement

Every agent/task PR should state:

1. behavior changed;
2. smallest validation sufficient;
3. highest-value permanent test layer;
4. duplicate tests intentionally not added;
5. tests/validation actually run;
6. validation not run and why;
7. out-of-scope follow-ups discovered.

This discipline is part of the V2 agent contract and is repeated in `V2-CODEX-PROMPTS.md` so testing scope does not silently grow phase by phase.