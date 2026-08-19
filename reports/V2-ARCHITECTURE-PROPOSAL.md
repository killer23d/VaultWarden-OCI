# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-18
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
- one concrete HTTPS email API for project operational notifications, with authenticated SMTP fallback for clearly transient primary failures;
- one encrypted V2 recovery format plus separate offline recovery material;
- systemd lifecycle/timers;
- exact production version pins and dev/test-only `--use-latest`.

V2 beta intentionally does **not** support:

- V1 state, archive, backup-format, migration, command, or runtime-layout compatibility;
- Kubernetes, Swarm, HA, or distributed coordination;
- generic cloud, storage, notification, secrets, or firewall provider frameworks;
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
- TOML config/version parsing and validation;
- normalized errors and subprocess execution;
- architecture mapping;
- `fcntl.flock` mutation locking;
- status/doctor JSON;
- SOPS/Age orchestration;
- notification HTTPS/SMTP delivery classification;
- backup metadata, recovery validation, retention decisions, and rclone orchestration;
- restore preflight/promotion;
- Cloudflare CIDR policy;
- structured systemd/template generation where useful.

Do not introduce a framework, dependency-injection system, plugin registry, ORM, event bus, workflow engine, daemon, generic provider layer, or speculative extension architecture.

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
- Do not game the preference by creating giant catch-all files or mixing unrelated responsibilities. Security boundaries, readability, and testability take priority.

## 4. Runtime authorities and filesystem

V2 should have one clear authority for each class of state:

```text
/opt/vaultwarden-oci/
  releases/<release>/       immutable installed application release
  current -> releases/...   active release

/etc/vaultwarden-oci/
  config.toml               sole installed non-secret config
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
- no project-built cryptography, secrets server, cloud-KMS abstraction, or provider registry.

Secrets may include Vaultwarden admin material, Cloudflare/CrowdSec credentials, SMTP credentials, the operational notification API token, and rclone credentials when not kept in a separately root-protected rclone configuration.

Never place plaintext secrets in `config.toml`, process arguments, normal logs, persistent temporary files, or notification diagnostic state.

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

```text
vwctl/systemd operation
        |
        v
one concrete HTTPS email API
        |
        | clearly transient failure after small bounded retry
        v
direct authenticated SMTP fallback
```

The concrete HTTPS provider must be named by ADR before Phase 6. If it is still undecided, Phase 6 stops for that product decision; it must not hide uncertainty behind a generic provider interface.

Fallback is appropriate for clearly transient delivery-path failure such as network/DNS timeout, HTTP `429` after bounded retry, service-side `5xx`, and only other conditions explicitly documented as transient by the selected provider.

Representative `400`/`401`/`403`, malformed configuration/request, permanent rejection, unsupported provider behavior, and TLS certificate/hostname validation failure remain visible and are not silently masked by SMTP success.

SMTP uses normal certificate/hostname validation with implicit TLS or required STARTTLS plus authentication. No plaintext downgrade.

If both transports fail, persist only a small secret-free result for `status`/`doctor`: transport attempts, outcome/category, safe diagnostic text, and event/time identifiers as useful.

Do not build Postfix/local MTA state, spool files, persistent retry scheduling, dead-letter handling, or a provider registry.

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

Backup/restore deserves disproportionate attention. Notification tests focus on deterministic failure classification and safe fallback; rclone tests focus on project-owned argv/result behavior and non-destructive publication intent.

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

## 14. Delivery sequence

The detailed, copy/paste-ready execution contract is `reports/V2-CODEX-PROMPTS.md`. The intended order is:

0. reset `AGENTS.md`, product boundary, and ADRs;
1. minimal Python/`vwctl` foundation;
2. bootstrap and immutable installed layout;
3. Vaultwarden + Caddy core, SOPS/Age, Vaultwarden SMTP;
4. Cloudflare ingress + CrowdSec;
5. one recovery format + rclone + offline recovery;
6. systemd automation + selected HTTPS notification API + transient SMTP fallback;
7. pinned versions + explicit updates + dev/test `--use-latest`;
8. beta docs, disposable-host acceptance, and V1 cleanup on the V2 branch.

Run one phase at a time. Split a phase if reviewability requires it; never combine phases merely to reduce PR count.

## 15. Architecture review rule

When a task appears to need a new abstraction, first ask whether V2 can support one concrete implementation instead. For this product, a narrow well-tested path is normally safer and cheaper than a generalized framework.

When a task appears to need a new file, first ask whether an existing owner can absorb the behavior cleanly. Fewer files are preferred when natural, but clear ownership and security boundaries win over a numeric count.