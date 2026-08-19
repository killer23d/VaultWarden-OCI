# VaultWarden-OCI V2 Implementation Roadmap

Date: 2026-08-18
Revision: post-rescan roadmap with explicit scope controls for Codex/agent work.

## Implementation rule

V2 should be built as a sequence of small, reviewable PRs against a dedicated long-lived `v2` branch. V1 `main` remains reference material while V2 is being built.

Each phase has an explicit **definition of done** and **non-goals**. A coding agent must not implement later phases because doing so appears convenient.

The most important process change from V1 is this:

> Do not make every discovered edge case permanent code and permanent test machinery. Record out-of-scope findings and decide them deliberately in the next phase.

---

# Phase 0 — freeze the V2 contract before code

## Goal

Create the V2 product/agent contract so Codex is not instructed to preserve V1 architecture.

## Deliverables

- create long-lived `v2` branch from the agreed starting point;
- replace/update `AGENTS.md` for V2 development;
- create a concise V2 product boundary;
- create ADRs for:
  - Python-first hybrid language boundary;
  - one config authority;
  - Cloudflare-only beta ingress + Docker iptables packet path;
  - direct SMTP/no Postfix for beta;
  - one V2 recovery format/no V1 compatibility;
  - test simplicity budget;
- establish a tiny developer tool configuration for `pytest`/`ruff` if accepted.

## Definition of done

A coding agent reading only the V2 branch instructions cannot reasonably conclude that it should port the V1 Makefile, dashboard, migration engine, Postfix queue, three backup tiers, custom test runner or operation-guard architecture.

## Non-goals

- no runtime code;
- no Compose stack;
- no installer;
- no feature porting;
- no mass deletion of V1 files on `main`.

---

# Phase 1 — minimal `vwctl` foundation

## Goal

Build the smallest Python application skeleton that proves the language/config/test model.

## Deliverables

- `python3 -m vwctl` / installed `vwctl` entrypoint;
- `vwctl --version` and `vwctl --help`;
- `config.toml` parser/validator using `tomllib`;
- `versions.toml` parser/validator;
- architecture resolver for `amd64` and `arm64`;
- small normalized subprocess helper;
- one global mutation lock using `fcntl.flock`;
- initial read-only `vwctl doctor` with host/platform/config checks;
- minimal test setup.

## Required tests

Only tests for:

- valid/invalid TOML configuration;
- valid/invalid versions manifest;
- amd64/arm64 mapping and unsupported architecture failure;
- lock contention;
- command error normalization;
- stable `doctor --json` result shape for the implemented checks.

## Definition of done

All functionality runs without Docker or root mutation. The test suite is small enough to understand in one reading.

## Non-goals

- no installation mutation;
- no Docker Compose generation;
- no SOPS/Age;
- no Cloudflare/CrowdSec;
- no backup/restore;
- no systemd;
- no update command;
- no generic command/plugin registry.

---

# Phase 2 — installer and immutable release layout

## Goal

Install V2 predictably onto a clean Ubuntu 24.04 host without building application behavior into the bootstrap script.

## Deliverables

- minimal `bootstrap.sh` or equivalent root entrypoint;
- host validation for Ubuntu 24.04 and amd64/arm64;
- installation under `/opt/vaultwarden-oci/releases/<version>`;
- `/opt/vaultwarden-oci/current` symlink;
- `/etc/vaultwarden-oci` and `/var/lib/vaultwarden-oci` creation with explicit ownership/modes;
- initial config installation/edit workflow;
- safe dedicated-volume initialization only if it fits cleanly in this phase;
- installed `vwctl` executes from the immutable release.

## Required tests

- path/render logic as Python tests;
- installer dry-run/plan output on fixtures;
- one disposable Ubuntu host smoke install, preferably manual/on-demand rather than a permanent complex mock harness.

## Definition of done

A clean host can install the V2 CLI/config layout and remove/reinstall it without repository-to-runtime synchronization machinery.

## Non-goals

- no V1 migration;
- no running Vaultwarden yet;
- no live disk migration;
- no systemd timers;
- no recovery formats;
- no alternate distro support.

---

# Phase 3 — core runtime: Vaultwarden + Caddy + secrets

## Goal

Bring up the minimal application securely.

## Deliverables

- production Compose template with Vaultwarden + Caddy only;
- Cloudflare DNS-01 Caddy build/config inputs;
- SOPS/Age initialization;
- SOPS-encrypted JSON secrets;
- transient decrypted secret files under `/run/vaultwarden-oci/secrets`;
- `vwctl start|stop|restart|status|logs`;
- direct Vaultwarden SMTP configuration;
- `doctor` checks for Compose, containers, `/alive`, SOPS decryptability and file permissions.

## Required tests

- Compose render/config validation;
- secret materialization permission and cleanup behavior;
- proof that secret values do not appear in generated ordinary config/log output;
- subprocess failure mapping;
- status/doctor behavior with mocked command outputs at process boundaries;
- one disposable-host/application smoke test.

## Definition of done

A fresh V2 host can securely start Vaultwarden behind Caddy, with direct SMTP configuration and no Postfix sidecar.

## Non-goals

- no CrowdSec automation yet;
- no host ingress chain yet beyond what is necessary for isolated development validation;
- no backup/restore;
- no dashboard;
- no push-provider abstraction;
- no email queue tooling.

---

# Phase 4 — Cloudflare ingress + CrowdSec security

## Goal

Make the Cloudflare-first production boundary safe and diagnosable.

## Deliverables

- Cloudflare CIDR fetch/parse/validate/cache;
- one supported Docker iptables ingress-chain implementation;
- allow only Cloudflare ranges to published Caddy 443;
- fail-closed behavior when safe ingress cannot be established;
- provider-firewall prerequisite documented but not automated;
- CrowdSec host installation/integration using current upstream-supported mechanisms where practical;
- project-specific acquisitions/profiles only;
- Cloudflare Worker bouncer integration using the chosen supported upstream path;
- `vwctl crowdsec status/test` only if `doctor` alone is insufficient;
- `doctor` verifies firewall and CrowdSec/edge state.

## Required tests

- Cloudflare CIDR parser and cache-expiry behavior;
- generated iptables rules from deterministic fixtures;
- fail-closed command behavior on fetch/validation failure;
- no tests of iptables' own semantics beyond the project's generated contract;
- focused CrowdSec config rendering/diagnostic tests;
- disposable-host ingress acceptance.

## Definition of done

The normal production origin is not generally reachable on 443 and the diagnostic command can explain whether Cloudflare/CrowdSec enforcement is healthy.

## Non-goals

- no nftables backend;
- no generic firewall abstraction;
- no direct/non-Cloudflare production mode;
- no Cloudflare API framework;
- no bespoke replacement for the upstream CrowdSec installer.

---

# Phase 5 — one backup and restore model

## Goal

Implement a simple, verified V2 recovery contract.

## Deliverables

- `vwctl backup`;
- verified SQLite snapshot;
- one V2 manifest format;
- encrypted complete recovery artifact that excludes the live operational private key;
- optional rclone offsite transfer;
- simple retention by verified recovery point;
- offline recovery-kit export;
- `vwctl restore` for V2-format backups only;
- preflight before service stop;
- staged extraction/promotion;
- permission restoration;
- explicit start policy and post-start health gate.

## Required tests

Focus on invariants that can lose data:

- backup snapshot failure prevents publication;
- manifest/checksum/decryption failure prevents restore mutation;
- archive traversal/unsafe member rejection;
- insufficient target space/layout fails before service stop;
- promotion failure is non-zero and leaves clear recovery state;
- restored permissions are correct;
- successful restore followed by health is reported truthfully;
- retention does not delete the newest valid recovery point before a replacement is verified.

Use real temporary files/SQLite where cheap. Mock only external process/network boundaries.

## Definition of done

A disposable host can create a recovery point and restore it onto fresh V2 state using the offline recovery material.

## Non-goals

- no V1 backup formats;
- no `db/full/emergency` public modes;
- no live volume migration;
- no generic transaction framework;
- no backup database/catalog.

---

# Phase 6 — systemd automation and notifications

## Goal

Make the appliance set-and-forget without recreating V1's automation surface.

## Deliverables

- lifecycle/startup systemd service;
- backup timer/service;
- health/doctor timer/service;
- maintenance timer/service;
- optional edge-refresh timer only if technically required;
- failure/routine notification through direct SMTP using Python `smtplib`;
- `vwctl status` shows timers and last outcomes.

## Required tests

- deterministic unit rendering and command arguments;
- `systemd-analyze verify` where available;
- notification message construction and SMTP error handling without duplicating SMTP protocol tests;
- on disposable Ubuntu, install/enable/run timers and confirm expected commands/exit status.

## Definition of done

A junior admin can understand scheduled responsibilities from `systemctl list-timers` and `vwctl status`, without installed-copy synchronization logic.

## Non-goals

- no second scheduler;
- no incident database;
- no complex alert-recovery state machine;
- no Postfix queue;
- no dashboard.

---

# Phase 7 — update/version workflow

## Goal

Make production updates reproducible while retaining the user's `--use-latest` development path.

## Deliverables

- `vwctl versions`;
- `vwctl update check`;
- explicit `vwctl update apply` using production pins;
- `--use-latest` resolution for development/testing only;
- exact resolved-version record for latest-mode runs;
- immutable new release staging and activation;
- basic rollback of application release activation when appropriate;
- amd64/arm64 asset/image validation.

## Required tests

- pinned resolution;
- latest resolver using mocked HTTP responses;
- arm64/amd64 asset mapping;
- no unsupported architecture fallback;
- update plan without mutation;
- activation/rollback path using temporary release directories;
- Compose manifest/platform checks where practical.

## Definition of done

Production never accidentally floats to `latest`, while developers can intentionally test current upstream releases and know exactly what was resolved.

## Non-goals

- no auto-update daemon;
- no unattended production upgrade;
- no generic package manager;
- no support for arbitrary architectures.

---

# Phase 8 — documentation, release acceptance and beta hardening

## Goal

Finish the V2 beta by proving the golden path and deleting provisional complexity.

## Deliverables

- minimal operator documentation set;
- one clean-host install guide;
- operations/doctor guide;
- security model;
- recovery guide;
- development/maintainer guide;
- disposable real-host acceptance on Ubuntu 24.04 amd64 and arm64 where infrastructure permits;
- beta checklist for install -> configure -> secure edge -> backup -> restore -> update -> uninstall/reinstall;
- remove dead helpers, temporary flags and test scaffolding found during phases 1-7.

## Definition of done

A junior admin can deploy and recover without reading implementation code, and a maintainer can understand the entire test suite without reverse-engineering a custom runner.

## Non-goals

- no feature expansion during hardening;
- no dashboard/TUI;
- no extra compatibility aliases;
- no new advanced modes before beta feedback.

---

# Keep / simplify / replace / remove matrix

## Keep the property

- Ubuntu 24.04-only production support;
- amd64/arm64 explicit mapping;
- Cloudflare-first origin protection;
- Caddy;
- CrowdSec;
- SOPS/Age;
- root-operated production mutation;
- encrypted verified recovery;
- fail-closed storage/restore behavior;
- systemd automation;
- pinned/checksummed supply chain;
- explicit `--use-latest` testing override.

## Simplify

- container networks;
- firewall ownership;
- systemd units;
- backup concept;
- config options;
- secret schema;
- health/diagnostics;
- update flow;
- documentation;
- CI.

## Replace

- broad Bash application logic -> focused Python standard-library modules;
- Make/operator scripts -> `vwctl`;
- `.env`/install.env/installed-env chain -> one TOML config;
- yq + embedded PyYAML schema validation -> TOML/JSON + Python stdlib;
- Bash lock-holder/process identity system -> one Python `flock` lock;
- Postfix sidecar -> direct SMTP + Python notifications;
- three backup tiers -> one normal recovery format + offline recovery kit;
- huge health/dashboard surfaces -> `status` + `doctor`;
- custom Bash test runner -> pytest + direct integration tests.

## Remove from beta

- migration pipeline;
- V1 state/archive compatibility;
- dashboard;
- email queue administration;
- generated command-reference document;
- multiple firewall backends;
- direct/non-Cloudflare production modes;
- custom test inventories and source-shape regression suites.

---

# Scope-control rules for every implementation PR

Every PR/prompt should state all of the following:

1. **Files/areas allowed to change.**
2. **Observable behavior to implement.**
3. **Tests required and nothing broader.**
4. **Explicit non-goals.**
5. **No V1 compatibility unless named.**
6. **No framework/abstraction for hypothetical future work.**
7. **Do not create empty modules for later phases.**
8. **Do not implement later-phase TODOs.**
9. **If a requested design conflicts with a security boundary, stop and document the conflict rather than silently widening scope.**
10. **Finish by reporting exact tests run and unresolved decisions.**

The copy/paste-ready prompts are in `V2-CODEX-PROMPTS.md`.
