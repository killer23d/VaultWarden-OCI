# VaultWarden-OCI V2 — Accepted Decisions: Secrets, rclone, and Notifications

Date: 2026-08-18
Revision: consolidated into the authoritative Codex contract.

## Status and precedence

This document records the rationale/history for decisions accepted after the V2 rescans.

**It is no longer an override document.** The implementation/source-of-truth contract for agents is `reports/V2-CODEX-PROMPTS.md`. These decisions have been incorporated there. If this document and the Codex prompt contract ever diverge, agents follow the prompt contract and this supporting document should be corrected.

These decisions intentionally do not reintroduce the V1 Postfix/email-queue architecture or a generic provider framework.

---

## 1. Keep SOPS + Age

### Decision

Retain SOPS + Age as the V2 persistent secret mechanism.

For this small-team appliance it provides structured encrypted secrets without requiring a cloud KMS, external secrets server, or provider-specific dependency. The V2 improvement is to simplify project-owned orchestration around SOPS/Age, not replace it.

### V2 contract

- one structured SOPS-encrypted secrets document;
- one operational Age private identity stored root-only on the server;
- offline recovery material/recipient whose private recovery key is not persisted on the server;
- decrypted runtime secret material only in a volatile root-owned runtime location;
- Python owns structured validation/orchestration where practical;
- SOPS and Age remain external cryptographic tools;
- no project-built secrets manager, KMS abstraction, or cryptographic implementation.

---

## 2. Keep rclone first-class

### Decision

rclone remains an important V2 component for offsite backup and recovery.

It supports the cloud-neutral product boundary and avoids project-owned object-storage/provider APIs. The project wrapper should remain small.

### Required capabilities

- prerequisite/config diagnostics;
- remote connectivity test;
- upload/publication of verified recovery points;
- remote recovery-point listing;
- remote verification;
- download/staging for restore;
- explicit retention/pruning;
- status/doctor visibility.

Do not build a generic storage-provider/plugin framework around rclone.

### Publication safety

Normal publication should be:

1. create candidate recovery point locally;
2. verify local database/archive/encryption/integrity;
3. publish the verified recovery point with `rclone copy`/`copyto`-style semantics;
4. verify the required remote recovery cohort exists;
5. only then report offsite publication success;
6. perform deletion through a separate explicit retention/pruning operation.

Normal publication must not use destructive synchronization semantics that can delete remote recovery points merely because a local file disappeared.

---

## 3. Operational notifications: HTTPS API primary, SMTP transient fallback

### Decision

Project operational notifications use:

```text
vwctl / systemd task
        |
        v
one concrete HTTPS email API  (primary)
        |
        | clearly transient failure after small bounded retry
        v
direct authenticated SMTP     (fallback)
```

Vaultwarden application email remains direct authenticated SMTP from Vaultwarden itself.

There is no mandatory Postfix container and no project-built durable notification queue in V2 beta.

The concrete HTTPS API provider must be named in the Phase 0 notification ADR before Phase 6. If it has not been selected, implementation must stop for that product decision rather than invent a generic provider abstraction.

### Why

The API path provides structured request/response status and clean machine-readable error handling for normal operational notifications. SMTP remains a second transport when the API delivery path is temporarily unavailable.

This avoids the V1 cost of:

- Postfix sidecar/state/capabilities;
- queue inspection and mutation commands;
- queue health/state management;
- persistent retry/dead-letter logic;
- queue-specific tests and documentation.

### Scope constraint

Beta supports exactly:

- one concrete HTTPS email API integration;
- one authenticated SMTP fallback;
- one small notification module used by `vwctl`/systemd operations.

A second API provider or provider registry requires a separate demonstrated need and architecture change.

---

## 4. Failure classification

### Primary API attempt

Use Python HTTPS facilities with normal CA and hostname verification. API credentials must not be placed in shell command arguments, ordinary logs, exception text, or persisted response bodies.

Return/store only small safe delivery information such as:

- transport attempted/used;
- outcome;
- stable reason/category;
- safe diagnostic message;
- event identifier/time when useful.

### SMTP fallback eligible

Fallback is intended for clearly transient delivery-path failure, such as:

- DNS/network/connectivity failure;
- connection timeout;
- HTTP `429` after the small bounded API retry policy;
- HTTP `5xx` service-side failures;
- another condition explicitly documented as transient by the selected API provider.

### Fail visibly instead of masking

The following should normally remain visible rather than being turned into apparent health because SMTP happened to work:

- representative HTTP `400`, `401`, `403`;
- malformed request or invalid configuration;
- permanent provider rejection;
- unsupported provider behavior;
- TLS certificate or hostname validation failure.

Certificate/hostname validation failure is treated as a security/configuration problem, not a transparent failover condition.

### SMTP security

Use a normal validating SSL context with:

- implicit TLS (`SMTP_SSL`), or
- required STARTTLS followed by authentication.

Requirements:

- certificate verification enabled;
- hostname verification enabled;
- no plaintext downgrade;
- bounded operation timeouts;
- credentials loaded from the V2 secret mechanism;
- no password/token in argv/logs/exceptions/debug transcripts;
- SMTP debug logging disabled in production.

---

## 5. No custom durable notification queue

If both transports fail, preserve a small safe failed-delivery result so `vwctl status` / `vwctl doctor` can report the condition.

Do not implement:

- message spool files;
- a persistent retry queue;
- queue locking;
- retry scheduling;
- dead-letter storage;
- an SMTP server/MTA.

If real production experience later proves a durable local mail queue is necessary, make that a separate architecture decision. Reconsidering a mature MTA would be preferable to implementing one badly inside `vwctl`.

---

## 6. Relationship to the V2 implementation phases

These decisions are now encoded in `V2-CODEX-PROMPTS.md`:

- Phase 0 records the SOPS/Age, rclone, and notification ADRs and selects the concrete HTTPS email API provider;
- Phase 3 implements SOPS/Age and Vaultwarden direct SMTP;
- Phase 5 implements backup/restore plus first-class rclone publication/verification/pruning;
- Phase 6 implements the selected HTTPS API primary transport plus SMTP transient fallback and safe delivery diagnostics;
- Phase 8 documents and accepts the complete behavior.

This file remains useful as rationale, but agents should not use it to override the phase contract.