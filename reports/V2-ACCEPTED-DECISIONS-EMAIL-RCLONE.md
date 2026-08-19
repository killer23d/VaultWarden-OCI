# VaultWarden-OCI V2 — Accepted Decisions: Secrets, rclone, and Notifications

Date: 2026-08-18

## Status and precedence

This document records decisions accepted after the second V2 rescan.

Where earlier V2 reports or Codex prompts use broader or older wording such as “direct SMTP only,” this decision record takes precedence for V2 implementation until the main reports/prompts are consolidated on the V2 development branch.

These decisions do **not** reintroduce the V1 Postfix/email-queue architecture.

---

# 1. Keep SOPS + Age

## Decision

Retain SOPS + Age as the V2 persistent secret mechanism.

For this small-team appliance, SOPS + Age remains a good fit because it provides encrypted structured secrets without a cloud KMS, external secrets server, or provider-specific dependency.

V2 should simplify the code around SOPS/Age rather than replace it.

## V2 contract

- one SOPS-encrypted secrets file;
- one operational Age private identity stored root-only on the server;
- one optional/offline recovery Age identity whose private key is never persisted on the server;
- decrypted runtime secret material only under a volatile root-owned runtime directory;
- Python owns structured validation/orchestration where practical;
- SOPS and Age remain external cryptographic tools rather than libraries reimplemented by this project.

Do not create another secrets manager, encryption abstraction, or provider-specific KMS layer for beta.

---

# 2. Keep rclone as a first-class V2 capability

## Decision

rclone remains a supported and important V2 component for offsite backup and recovery workflows.

It is not considered part of the V1 overengineering problem. It prevents the project from having to implement cloud/object-storage provider APIs itself and supports the cloud-neutral product boundary.

## Required V2 rclone capabilities

Keep a small project-owned wrapper for:

- configuration/prerequisite diagnostics;
- remote connectivity test;
- upload of verified recovery points;
- remote recovery-point listing;
- download/staging for restore;
- verification that required remote recovery artifacts exist;
- explicit retention/pruning;
- `vwctl status` / `vwctl doctor` visibility for configured offsite backup state.

Do not build a generic storage-provider/plugin framework around rclone.

## Publication safety

Prefer a publication flow based on non-destructive copy semantics rather than using synchronization as the normal upload primitive:

1. create candidate recovery point locally;
2. verify local database/archive/encryption/integrity;
3. publish the verified recovery point to the configured rclone destination using `rclone copy`/`copyto`-style semantics;
4. verify the required remote recovery cohort is present;
5. only then report offsite publication success;
6. perform deletion through a separate explicit retention/pruning operation.

Normal publication must not implicitly delete remote recovery points merely because a local file disappeared.

The project should not use remote `sync` as the default backup-publication operation where its deletion semantics could remove recovery data unintentionally.

---

# 3. Operational notifications: HTTPS API primary, SMTP failover

## Decision

V2 operational notifications use:

```text
vwctl / systemd task
        |
        v
HTTPS provider API  (primary)
        |
        | transient delivery failure only
        v
direct authenticated SMTP  (fallback)
```

Vaultwarden application email remains direct authenticated SMTP from Vaultwarden itself.

There is no mandatory Postfix container and no project-built durable mail queue in V2 beta.

## Why

This provides better machine-readable error handling and diagnostics for normal operational notifications while retaining SMTP as a second transport when the API path is temporarily unavailable.

It avoids the V1 cost of:

- a Postfix sidecar;
- mutable Postfix runtime state;
- additional container capabilities;
- queue inspection/mutation commands;
- queue health/state management;
- queue retry/dead-letter logic;
- large queue-specific tests and documentation.

## Scope constraint

Do **not** create a generic notification/provider/plugin framework.

For beta support exactly:

- one configured HTTPS email API implementation/contract;
- one configured authenticated SMTP fallback;
- one small notification module used by `vwctl`/systemd operations.

A second API provider or generic provider registry requires a demonstrated deployment requirement and a separate architecture decision.

---

# 4. Notification transport behavior

## 4.1 Primary API attempt

The notification module should attempt the configured HTTPS API first.

Use Python's HTTPS facilities with normal CA and hostname verification. API credentials must not be placed in shell command arguments or normal logs.

Return a structured transport result containing at least:

- transport (`api` or `smtp`);
- outcome;
- stable reason/category;
- safe diagnostic message;
- timestamp/event identifier as needed.

Do not retain full secret-bearing request/response bodies in diagnostic state.

## 4.2 When SMTP fallback is allowed

SMTP fallback is intended for **transient delivery-path failure**, for example:

- DNS/network/connectivity failure;
- connection timeout;
- TLS connection failure not caused by an intentionally unsupported/insecure local configuration;
- HTTP `429` after a small bounded retry policy;
- HTTP `5xx` responses;
- other clearly transient provider/service-unavailable conditions.

Use only a small bounded API retry policy. Do not introduce a retry scheduler or background queue.

## 4.3 When SMTP fallback should normally not hide the API failure

Configuration/authentication/request defects should normally fail visibly rather than silently becoming healthy because SMTP happened to work. Examples include representative HTTP `400`, `401`, and `403` failures.

The exact classification may be provider-specific, but the implementation must distinguish at least:

- transient delivery failure;
- authentication/configuration failure;
- permanent request rejection;
- successful acceptance.

If a future provider documents a specific status as safely failover-eligible, handle it explicitly rather than treating every non-2xx response as transient.

## 4.4 SMTP fallback security

Use Python `smtplib` with a normal validating SSL context.

Supported paths may be:

- implicit TLS (`SMTP_SSL`), or
- SMTP with required STARTTLS followed by authentication.

Requirements:

- certificate verification enabled;
- hostname verification enabled;
- no plaintext fallback when TLS is configured/required;
- bounded connect/read operation timeouts;
- credentials loaded from the V2 secret mechanism;
- no SMTP password or API token in argv, exception text, debug transcript, or ordinary logs;
- SMTP debug logging disabled in production.

Do not implement an SMTP server or spool.

---

# 5. No durable notification queue in beta

If both API and SMTP fail, the notification attempt fails truthfully.

V2 may preserve a **small diagnostic state record**, for example:

```text
notification event: backup-failed
notification result: FAILED
primary: api
primary reason: timeout
fallback: smtp
fallback reason: connection-refused
last_attempt: <timestamp>
```

This state exists for `vwctl status` / `vwctl doctor` visibility. It is not a message spool.

Do not store the complete email body unless a concrete operational requirement later justifies it.

Do not implement:

- persistent message queue files;
- queue locks;
- retry scheduling;
- dead-letter queues;
- queue inspection/delete/retry commands;
- an SMTP daemon.

If production experience proves durable local queueing is required, reconsider using a mature MTA such as Postfix rather than recreating an MTA in project code.

---

# 6. Failure semantics

Notification delivery is separate from the success of the operation being reported.

Examples:

- a verified backup may be `PASS` while notification is `FAIL`;
- an offsite rclone publication failure must not become backup-publication success merely because an alert was delivered;
- successful SMTP fallback should be reported as `smtp-fallback`, not as API success;
- failure of both transports must be visible in diagnostics and systemd task output/state as appropriate.

Do not make a successful notification mask the underlying operation failure.

Do not make a notification failure falsely report that a completed backup/maintenance operation itself failed unless the command contract explicitly defines notification delivery as required.

---

# 7. Provider redundancy boundary

Using API and SMTP endpoints from the same email provider protects mainly against API/protocol/path-specific failure; it does not guarantee independence from a provider-wide outage.

For the small-team beta scope, one provider with two transports is the preferred default because it avoids maintaining two provider accounts, credentials, sender-domain configurations, and failure semantics.

Supporting a second independent provider is an optional future reliability enhancement, not a beta requirement.

---

# 8. Tests required for this decision

Keep tests behavioral and small.

## Notification tests

Test representative cases:

- API success: SMTP is not attempted;
- API timeout/network failure: SMTP fallback is attempted;
- API `429`/representative `5xx`: bounded API retry/fallback behavior;
- API `401`/`403`: configuration/auth failure remains visible and is not silently masked by SMTP;
- SMTP fallback success is reported as `smtp-fallback`;
- both transports failing returns a truthful failure result;
- API token and SMTP password sentinel values never appear in logs/errors/process argv;
- SSL/TLS verification is not disabled;
- diagnostic state contains safe reason metadata but no full secret-bearing body.

Do not build an HTTP server framework or SMTP server framework just for tests. Mock the stable HTTP/SMTP boundaries or use very small disposable local test doubles where useful.

## rclone tests

Test project behavior, not rclone internals:

- correct argv generation without shell interpolation;
- failed copy/upload is not reported as published;
- remote verification failure is not reported as successful publication;
- normal upload path does not invoke destructive synchronization semantics;
- explicit retention is a separate operation;
- rclone credentials/config paths are not leaked in normal diagnostics where sensitive.

Real-host/release acceptance should prove one representative configured remote path and recovery download without attempting to certify every rclone backend.

---

# 9. Codex execution override

Until `reports/V2-CODEX-PROMPTS.md` is consolidated, apply this decision record to all V2 Codex phases.

In particular:

- Prompt 0 ADR wording should record **HTTPS API primary + authenticated SMTP transient-failure fallback; no Postfix/no durable project queue**, rather than “direct SMTP only.”
- Runtime/notification phases must implement the bounded two-transport contract above, not a generic provider framework.
- Backup/recovery phases must keep rclone as a first-class offsite/recovery capability and use non-destructive publication semantics with separate retention.
- The V2 `AGENTS.md` created in Phase 0 should reference this accepted decision.

When a phase prompt conflicts with this file, this file wins.
