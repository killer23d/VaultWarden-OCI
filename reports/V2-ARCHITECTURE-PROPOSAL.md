# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-18
Revision: consolidated after V2 branch creation and later secrets/rclone/notification decisions.

> **Agent-execution precedence:** `reports/V2-CODEX-PROMPTS.md` is the authoritative V2 agent execution contract. This document explains the target architecture. If wording here conflicts with the prompt contract, the prompt contract wins and this document should be corrected.

## 1. Design objective

V2 is a greenfield fresh-install security appliance for a small team, not a compatibility release of V1.

Optimize for:

1. clear security boundaries;
2. junior-admin diagnosability;
3. small project-owned code surface;
4. reproducible production installs;
5. straightforward verified recovery;
6. amd64/arm64 portability on Ubuntu 24.04;
7. low ongoing test and maintenance cost.

The design should delegate specialized work to mature tools rather than recreate them inside the project.

## 2. Fixed product boundary

V2 beta supports:

- Ubuntu 24.04 LTS Noble;
- amd64 and arm64;
- cloud-provider-neutral runtime;
- OCI A1 Flex as a reference deployment only;
- Cloudflare-first production ingress;
- CrowdSec;
- Vaultwarden + Caddy containers;
- SOPS + Age secrets;
- rclone offsite recovery workflows;
- one operational HTTPS email API plus SMTP transient fallback;
- one normal encrypted V2 recovery format;
- systemd lifecycle/timers;
- explicit pinned updates and dev/test-only `--use-latest`.

V2 beta does not implement:

- V1 migration/import/archive compatibility;
- V1 command/layout compatibility;
- Kubernetes, Swarm, HA, or distributed coordination;
- generic cloud, firewall, storage, notification, or secrets-provider frameworks;
- a dashboard/TUI;
- a Postfix sidecar/local MTA requirement;
- a project-built durable notification queue;
- multiple public backup tiers;
- a custom test runner;
- unattended auto-update daemons.

## 3. Language architecture

### Python owns structured logic

Use Ubuntu 24.04's Python 3.12 and prefer the standard library at runtime.

Python owns:

- `vwctl` CLI parsing/dispatch;
- TOML config and versions parsing;
- validation and normalized errors;
- subprocess execution without shell interpolation;
- architecture mapping;
- `fcntl.flock` mutation locking;
- status and doctor JSON;
- SOPS/Age orchestration;
- HTTPS notification delivery and SMTP fallback;
- backup metadata, retention decisions, rclone orchestration;
- restore preflight/promotion;
- Cloudflare CIDR validation;
- structured systemd/template generation where useful.

Do not introduce a framework, dependency injection system, plugin registry, ORM, async framework, daemon, generic provider layer, or internal workflow engine.

### Bash is minimal glue

Bash is acceptable for:

- the smallest bootstrap needed before `vwctl` is installed;
- very small host glue where shell is materially clearer;
- container entrypoint behavior required by upstream images.

If a shell file begins owning config parsing, state machines, complex locks, structured data, retries, or broad mocks, move that logic to Python instead.

### Dependencies

Runtime starts stdlib-first. Development may use pytest, ruff, and ShellCheck. Add any new runtime dependency only for a demonstrated requirement.

## 4. Installed filesystem contract

```text
/opt/vaultwarden-oci/
  releases/<release>/
  current -> releases/<release>/

/etc/vaultwarden-oci/
  config.toml
  age-key.txt

/var/lib/vaultwarden-oci/
  data/
  caddy/
  backups/
  state/                 # only small project state that is truly persistent

/run/vaultwarden-oci/
  secrets/
  transient/
  lock
```

The SOPS-encrypted secrets document should live in the persistent root-owned state chosen by the implementation contract, with one canonical path and no duplicate operator-editable representation. The prompt contract currently requires one structured SOPS-encrypted document; Phase 0/3 ADRs should lock its exact installed path before runtime implementation.

A dedicated data volume, if used, mounts at the existing persistent-state root rather than introducing a second configurable application root.

## 5. Configuration model

Use `/etc/vaultwarden-oci/config.toml` as the only installed non-secret configuration authority. Python `tomllib` reads it.

Illustrative categories:

```toml
[site]
domain = "vault.example.com"
timezone = "UTC"

[cloudflare]
proxy_enabled = true

[vaultwarden.smtp]
host = "smtp.example.com"
port = 587
security = "starttls"
username = "vaultwarden@example.com"
from_address = "vaultwarden@example.com"

[notifications]
enabled = true
# Concrete HTTPS API provider is selected by ADR before Phase 6.

[notifications.smtp_fallback]
host = "smtp.example.com"
port = 587
security = "starttls"
username = "ops@example.com"
from_address = "ops@example.com"

[backup]
rclone_remote = "remote:vaultwarden"
retention_days = 30
```

Secrets such as passwords/tokens do not belong in TOML.

Normal config operations should be a small set such as `vwctl config show|validate|edit`, with validated replacement of the one file.

## 6. Secrets: SOPS + Age stays

Retain SOPS + Age because it gives structured encrypted secrets without requiring a cloud KMS or always-on secrets service.

V2 contract:

- one structured SOPS-encrypted secrets document;
- one root-only operational Age private identity on the host;
- offline recovery material/recipient whose private recovery key is not persisted on the server;
- decrypted runtime material only under a root-owned volatile directory;
- project code validates/orchestrates but does not implement cryptography;
- no secrets-provider/KMS abstraction.

Expected secret classes may include:

- Vaultwarden admin secret/token/hash;
- Cloudflare DNS/API material;
- CrowdSec/Cloudflare integration credentials;
- Vaultwarden SMTP password;
- operational notification HTTPS API token;
- operational SMTP fallback password;
- optional Vaultwarden push credentials;
- rclone credentials if the deployment does not keep them in a separately root-protected rclone configuration.

Never place plaintext secrets in TOML, process arguments, ordinary logs, persistent temporary files, or notification diagnostic state.

## 7. Core runtime

Normal Compose stack starts with only:

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

## 8. Operational notifications

Operational notifications are separate from Vaultwarden application mail.

Target flow:

```text
vwctl/systemd task
      |
      v
one concrete HTTPS email API
      |
      | clearly transient failure after small bounded retry
      v
direct authenticated SMTP fallback
```

The concrete HTTPS API provider must be named in a Phase 0 ADR before Phase 6 implementation. Do not hide an undecided provider behind a generic provider interface.

Fallback classification:

- eligible examples: DNS/network timeout, HTTP 429 after bounded retry, service-side 5xx, and other conditions explicitly documented as transient by the selected provider;
- normally not eligible: representative 400/401/403, malformed request/config, permanent rejection;
- TLS certificate/hostname validation failure is a security/configuration failure and must remain visible, not be silently masked by SMTP success.

SMTP uses a normal validating SSL context with implicit TLS or required STARTTLS + authentication. No plaintext downgrade.

If both transports fail, preserve only a small secret-free result such as event id/time, transport attempts, outcome/category, and safe diagnostic text so `vwctl status`/`doctor` can expose the failure.

Do not build:

- Postfix/local MTA;
- spool files;
- a persistent queue;
- retry scheduler;
- dead-letter processing;
- generic notification provider registry.

## 9. rclone stays first-class

rclone remains a deliberate V2 dependency for cloud-neutral offsite backup/recovery. It avoids project-owned storage-provider APIs.

Small wrapper responsibilities:

- prerequisite/config diagnostics;
- connectivity test;
- upload/publication;
- remote listing;
- remote verification;
- download/staging for restore;
- explicit retention/pruning;
- status/doctor visibility.

Normal publication is:

```text
create recovery point
-> verify local
-> rclone copy/copyto-style publication
-> verify required remote cohort
-> report offsite success
```

Remote deletion is a separate explicit retention/pruning operation. Normal publication must not use destructive sync semantics that can remove remote recovery points just because a local file disappeared.

Do not build a generic storage/provider framework around rclone.

## 10. Diagnostics

`vwctl doctor` is read-only by default and emits stable check IDs with PASS/WARN/FAIL/SKIP plus optional JSON.

Candidate checks include:

- Ubuntu/architecture;
- required binaries;
- config/versions validity;
- SOPS decryptability/Age identity permissions;
- Docker/Compose/runtime health;
- local Vaultwarden alive endpoint;
- external HTTPS through Cloudflare;
- Caddy runtime/certificate state;
- ingress policy freshness/fail-closed state;
- CrowdSec/bouncer state;
- Vaultwarden SMTP configuration/connectivity checks when explicitly safe;
- notification primary/fallback configuration and last safe delivery result;
- backup age and last verified local/offsite recovery point;
- rclone remote reachability when explicitly requested/appropriate;
- storage free space/mount identity;
- systemd units/timers.

Do not make doctor an automatic repair framework.

## 11. Concurrency

Start with one global mutating lock implemented with `fcntl.flock()`.

Mutating operations such as install/update/backup/restore/config replacement/secrets rotation take the lock. Read-only status/doctor/logs do not.

Do not add operation-specific/distributed locking until a demonstrated need exists.

## 12. Cloudflare ingress and firewall

V2 beta supports one production ingress model: Cloudflare-proxied HTTPS with Caddy.

- publish HTTPS only as required by the golden path;
- validate Cloudflare IPv4/IPv6 ranges;
- use one supported Docker Engine bridge + iptables packet path;
- own one small project ingress chain/allowlist behavior;
- keep last-known-good CIDRs with bounded staleness;
- fail closed when no safe policy can be established;
- do not claim UFW INPUT rules alone secure Docker-published ports;
- do not implement an nftables alternative/backend framework in beta.

Provider security-group/firewall setup remains documented prerequisite work, not a cloud API integration.

## 13. CrowdSec

Keep CrowdSec while relying on upstream installation/integration where practical.

Project-owned scope is limited to required acquisitions/config, secure credential handoff, selected bouncer integration, lifecycle hooks, and diagnostics.

Avoid porting the V1 CrowdSec installer wholesale.

## 14. Backup and restore

Expose one normal backup concept: `vwctl backup`.

A V2 recovery point includes a verified consistent SQLite snapshot plus appropriate persistent app/config material, a format-versioned manifest, checksums, encryption before publication, and verification before success.

The operational Age private key is excluded from ordinary backup artifacts. Offline recovery material is separate.

Restore is V2-format-only and performs preflight before service stop/live mutation: decryption, manifest/checksum validation, free-space/target checks, staging, explicit promotion, permission restoration, and health-gated optional restart.

No V1 archive detection/adapters and no permanent `db/full/emergency` public tier model.

## 15. systemd

Use systemd as lifecycle/scheduler. Keep the permanent unit/timer budget small: lifecycle plus only the health, backup, and maintenance timers actually needed.

Units execute the installed immutable release/current path and installed config, never a random git checkout.

Operational notification failures are observed state; systemd does not become a custom queue.

## 16. Versions and updates

Use one source-controlled `versions.toml`.

Production uses exact pins. `--use-latest` is development/testing-only, resolves compatible upstream versions once, converts them to exact values for the run, records them, and passes only those exact values downstream.

Updates are explicit (`vwctl update check|apply`) and should health-check, create/verify recovery according to policy, stage a new immutable release, activate, restart, and health/doctor gate. No unattended update daemon.

## 17. Test architecture

Use three layers only:

1. focused unit tests for deterministic logic;
2. small integration tests for filesystem/subprocess/Compose/security boundaries;
3. disposable real-host acceptance as a release gate.

Avoid source-string/order tests, private-function extraction, human-prose freezing, duplicated state machines, large custom runners, and coverage quotas.

Backup/restore deserves disproportionate attention. Notification testing should focus on deterministic failure classification and safe fallback behavior, not a protocol simulator. rclone testing should assert command/result behavior and non-destructive publication intent, not third-party internals.

## 18. Architecture review rule

When an implementation task seems to require a new abstraction, first ask whether V2 can support one concrete implementation instead. For this small-team product, a narrow well-tested path is normally safer and cheaper than a generalized framework.