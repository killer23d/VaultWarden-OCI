# VaultWarden-OCI V2 Implementation Roadmap

Date: 2026-08-18
Revision: consolidated after creation of the `v2` branch and later SOPS/Age, rclone, and notification decisions.

> **Agent-execution precedence:** `reports/V2-CODEX-PROMPTS.md` is authoritative. This roadmap explains sequencing and intent. If it conflicts with a phase prompt, the prompt file wins and this roadmap should be corrected.

## Implementation rule

Build V2 as a sequence of small, reviewable PRs targeting the long-lived `v2` branch. V1 `main` remains historical/security reference while V2 is developed.

Run one Codex phase at a time. Do not combine phases to reduce PR count. Split a phase if the diff becomes difficult to review.

The goal is not to recreate every V1 mechanism in Python. Preserve important security/recovery properties while deliberately removing compatibility, duplicated authorities, frameworks, and test scaffolding.

## Cross-phase product constraints

Every phase inherits these boundaries:

- greenfield fresh install; no V1 migration/archive/runtime compatibility;
- Ubuntu 24.04 LTS, amd64 + arm64;
- Python 3.12 stdlib-first structured logic; Bash minimal glue;
- one `vwctl` public operator CLI;
- one installed TOML non-secret config authority;
- one `versions.toml` authority;
- SOPS + Age retained with small orchestration;
- Cloudflare-first ingress and CrowdSec retained;
- rclone retained first-class for offsite recovery;
- Vaultwarden uses direct authenticated SMTP;
- operational notifications use one concrete HTTPS email API primary + SMTP transient fallback;
- no Postfix/custom durable queue;
- no generic provider/plugin frameworks;
- one normal V2 recovery format plus offline recovery material;
- no dashboard/TUI in beta;
- deliberately small three-layer testing.

## Phase 0 — agent/product contract reset

**Purpose:** remove V1 architectural instructions before code generation begins.

Deliverables:

- rewrite root `AGENTS.md` as a concise V2 map;
- make it point to `reports/V2-CODEX-PROMPTS.md` as the authoritative agent execution contract;
- add/update a concise V2 product boundary;
- add short ADRs for:
  - Python-first hybrid boundary;
  - one TOML configuration authority;
  - SOPS + Age operational/offline recovery identities;
  - single Cloudflare/Docker-iptables ingress model;
  - notification transport: one concrete HTTPS API + SMTP transient fallback, no queue/Postfix;
  - rclone copy-style publication + separate retention;
  - one V2 recovery format/no V1 compatibility;
  - bounded three-layer testing.

The notification ADR must name the concrete HTTPS provider before Phase 6. If not yet selected, mark it OPEN; do not solve uncertainty with a generic provider framework.

**No runtime code in this phase.**

Exit criterion: a new agent on `v2` no longer receives instructions to preserve V1 Bash/Postfix/backup-tier/test architecture.

## Phase 1 — minimal Python foundation

Deliver:

- smallest practical `vwctl` package/entrypoint;
- help/version;
- TOML config validation;
- versions display/parsing;
- read-only doctor skeleton with stable check IDs + JSON;
- architecture normalization for amd64/arm64;
- one subprocess wrapper using argv arrays;
- one global `fcntl.flock` mutation lock primitive.

Tests stay focused on those deterministic behaviors using ordinary pytest discovery.

No Docker/root/SOPS/rclone/email/firewall/backup/systemd/update work.

## Phase 2 — bootstrap and immutable installed layout

Deliver:

- minimal root bootstrap, preferably thin Bash delegating structured work to Python;
- Ubuntu 24.04 + architecture prerequisites;
- immutable `/opt/vaultwarden-oci/releases/<release>` layout with `current` symlink;
- `/etc/vaultwarden-oci/config.toml` and root-only Age identity location;
- persistent `/var/lib/vaultwarden-oci` state layout;
- volatile `/run/vaultwarden-oci` layout;
- only minimal systemd/install integration required to expose the installed application.

No runtime containers, secret decryption, rclone, edge security, or notifications yet.

## Phase 3 — Vaultwarden + Caddy core and secrets

Deliver:

- hardened two-container Vaultwarden + Caddy Compose/runtime;
- SOPS + Age orchestration with one structured encrypted document;
- operational Age key root-only; offline recovery recipient/material defined;
- volatile-only decrypted runtime material;
- `vwctl start|stop|restart|status|logs`;
- Vaultwarden direct authenticated SMTP for application email;
- relevant doctor checks.

Do **not** implement Postfix or the operational HTTPS notification module in this phase.

## Phase 4 — Cloudflare ingress and CrowdSec

Deliver:

- Cloudflare IPv4/IPv6 retrieval + validation;
- last-known-good cache with bounded age;
- one small Docker iptables ingress path for Cloudflare-published Caddy;
- fail-closed policy when no safe rule set is available;
- upstream-oriented CrowdSec installation/configuration;
- host/edge bouncer integration appropriate to the supported path;
- operator diagnostics.

No nftables/multi-firewall abstraction and no direct/non-Cloudflare beta ingress mode.

## Phase 5 — backup, restore, rclone, offline recovery

Deliver one V2 recovery product:

- consistent SQLite snapshot;
- V2 format manifest/checksums;
- encryption before publication;
- verification before success;
- atomic-enough local publication;
- V2-only restore with preflight/staging/promotion/health gates;
- offline recovery material separate from the server's operational Age private key.

rclone is first-class in this phase. Support only the small capabilities needed for:

- configuration/diagnostics;
- remote connectivity;
- upload/publication;
- remote listing/verification;
- download/staging;
- explicit retention/pruning.

Normal offsite publication sequence:

`create -> verify local -> rclone copy/copyto -> verify remote -> success`

Retention/deletion is separate. Do not use destructive `sync` semantics as normal publication.

This phase receives the strongest permanent test attention because recoverability is a core safety property.

## Phase 6 — systemd automation and operational notifications

Precondition: the Phase 0 notification ADR names one concrete HTTPS email API provider. If not, resolve that product decision before coding; do not implement a generic provider interface.

Deliver:

- small systemd lifecycle/health/backup/maintenance automation set;
- one small notification module used by project/systemd operations;
- primary operational delivery through the selected HTTPS API;
- small bounded API retry;
- direct authenticated SMTP fallback only for clearly transient delivery-path failures;
- no silent masking of representative 400/401/403, malformed configuration/permanent rejection, or TLS certificate/hostname validation failures;
- safe last-result state surfaced by status/doctor;
- no Postfix, spool, durable queue, retry scheduler, dead-letter processing, or notification provider registry.

Permanent tests should focus on deterministic failure classification/fallback and secret-free diagnostics, not full protocol simulation.

## Phase 7 — versions and explicit update flow

Deliver:

- exact pinned production versions from one `versions.toml`;
- centralized amd64/arm64 artifact/image mapping;
- development/testing `--use-latest` that resolves once, freezes exact results for the run, and records them;
- `vwctl update check|apply` with recovery/health/staged-release activation safeguards;
- no unattended update daemon.

## Phase 8 — documentation, real-host acceptance, V2 cleanup

Deliver the small documentation model:

- `README.md`
- `docs/INSTALL.md`
- `docs/OPERATIONS.md`
- `docs/SECURITY.md`
- `docs/RECOVERY.md`
- `docs/DEVELOPMENT.md`

Use `vwctl --help` as the executable command reference rather than generating a giant command manual.

Release acceptance should exercise installed behavior on disposable Ubuntu 24.04 amd64 and arm64 where available, including:

- clean install;
- runtime/doctor;
- SOPS/Age secret materialization;
- Cloudflare/CrowdSec edge behavior;
- backup -> rclone publication -> remote verification -> download -> restore;
- HTTPS operational notification success and representative SMTP transient fallback;
- systemd automation;
- pinned update flow.

Then remove obsolete V1 production/docs/tests from the V2 branch when they are no longer build/runtime inputs. Rely on git history/`main` for historical reference rather than shipping V1 compatibility code.

## PR sizing/agent discipline

For each phase PR, require the agent to state:

1. behavior changed;
2. smallest validation sufficient;
3. highest-value permanent test layer;
4. duplicate tests intentionally not added;
5. validation actually run;
6. validation not run;
7. out-of-scope follow-ups discovered but not implemented.

A phase that starts producing frameworks, multiple backends/providers, large synthetic tests, or extensive V1 compatibility is outside the V2 roadmap even if each local change appears reasonable.