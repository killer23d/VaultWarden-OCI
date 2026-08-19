# VaultWarden-OCI V2 Implementation Roadmap

Date: 2026-08-18

## Purpose

This roadmap converts the V2 audit into an implementation sequence suitable for a small team. It assumes a greenfield V2: no V1 project-state migration, no user/data carryover, and no requirement to preserve V1 command or internal API compatibility.

The priority is to reduce concepts before writing replacement code.

---

# 1. Keep / simplify / replace / remove

## Keep

These V1 ideas should survive V2 substantially intact at the policy level:

- Ubuntu 24.04 LTS supported-host contract;
- amd64 and arm64 as tested architectures;
- cloud-provider-neutral runtime;
- Cloudflare-first DNS/proxy/WAF path;
- CrowdSec with edge-aware enforcement;
- Caddy as the TLS/reverse-proxy endpoint;
- SOPS + Age for persistent encrypted secrets;
- decoded secrets only in volatile runtime storage;
- root-operated production administration;
- least-privilege container configuration;
- verified encrypted backups;
- restore verification before destructive mutation;
- stable mounted-volume protection;
- fail-closed behavior for ambiguous security/storage state;
- SHA-pinned GitHub Actions and checksum verification;
- explicit `--use-latest` development/testing support.

## Simplify

- configuration authority: three locations -> one installed config file;
- command surface: Make targets + root scripts + utilities -> `vwctl`;
- systemd automation: many jobs -> a small core set;
- backup model: three operator tiers -> routine recovery backup + offline recovery kit;
- CrowdSec provisioning: procedural setup surface -> declarative edge module;
- health: multiple overlapping entrypoints -> `health` + `doctor`;
- documentation: broad implementation-oriented library -> five operator docs + development doc;
- version handling: scattered constants -> central versions manifest/resolver.

## Replace

- large structured Bash subsystems -> tested Python modules where structured data/state is involved;
- checkout-driven runtime -> installed immutable application release;
- environment files parsed by shell execution -> non-executable validated configuration parser;
- bespoke installed-script synchronization -> stable installed `vwctl` release;
- scattered version/latest decisions -> one version resolver;
- normal admin Makefile -> developer-only Makefile/tasks.

## Remove unless a demonstrated requirement appears

- all V1 migration/import compatibility;
- V1 volume-migration compatibility workflows;
- mandatory Postfix sidecar and queue-management subsystem;
- multiple firewall backend support;
- duplicate config/runtime authorities;
- public implementation helper scripts;
- generated giant command-reference as a primary operator document;
- legacy aliases whose only purpose is V1 CLI compatibility;
- backup modes that differ mainly because of historical recovery design rather than a V2 user need.

---

# 2. Phase 0 — Freeze V2 product contract

Before implementation, write a one-page ADR/product boundary and do not reopen these decisions casually.

Required decisions:

1. V2 fresh install only; V1 migration is out of scope.
2. Ubuntu 24.04 LTS only for V2.x unless deliberately expanded later.
3. amd64 and arm64 are the release-gated CPU targets.
4. Cloudflare mode is the default production path.
5. Direct/non-proxied mode is advanced and explicit.
6. Caddy is the supported reverse proxy.
7. CrowdSec remains part of the supported security profile.
8. SOPS/Age remains the secrets mechanism.
9. `--use-latest` remains development/test-only.
10. One installed CLI is the public admin interface.
11. One persistent non-secret config authority.
12. Postfix is removed from the mandatory architecture unless evidence requires it.
13. V2 does not provision cloud infrastructure.

**Exit criterion:** no replacement code is written until this boundary is accepted.

---

# 3. Phase 1 — Skeleton and state contract

Build the smallest installable application before implementing Cloudflare/CrowdSec/backup sophistication.

Deliverables:

```text
install.sh
src/vwctl/
config/config.env.example
config/compose.yaml
config/systemd/
versions.yaml
docs/INSTALL.md
docs/DEVELOPMENT.md
```

Implement:

- host OS validation;
- architecture detection;
- state path creation;
- `/etc/vaultwarden-oci/config.env` parser/validator;
- installed release under `/opt/vaultwarden-oci/<version>`;
- `/opt/vaultwarden-oci/current` atomic pointer;
- `vwctl --version`;
- `vwctl config validate`;
- `vwctl versions`.

Do not implement migration code.

**Tests:** Ubuntu version parsing, amd64/arm64 mapping, config parser validation, installed path ownership/modes.

---

# 4. Phase 2 — Minimal Vaultwarden + Caddy runtime

Implement only the core application path.

Deliverables:

- Vaultwarden service;
- Caddy service;
- runtime secret directory creation;
- systemd main service;
- `vwctl start|stop|restart|status|logs`;
- health checks.

Default networking:

- Vaultwarden has no published host port;
- Caddy is the only public application service;
- default Cloudflare profile publishes 443 only;
- local Caddy health endpoint remains loopback-only;
- application/root filesystem restrictions asserted by tests.

**Exit criterion:** fresh Ubuntu 24.04 host can install, start, restart, and report health without CrowdSec or backup automation enabled yet.

---

# 5. Phase 3 — Secrets

Implement SOPS/Age cleanly before external credentials proliferate.

Deliverables:

- operational Age key generation/install;
- encrypted `secrets.yaml`;
- small profile-aware secret schema;
- `vwctl secrets edit`;
- `vwctl secrets rotate KEY`;
- `vwctl secrets check`;
- transient `/run/vaultwarden-oci/secrets` materialization;
- secret cleanup on failure/stop where appropriate.

Security tests:

- no plaintext secret in config output;
- no plaintext secret in normal logs;
- strict key/file modes;
- runtime secret directory is volatile/private;
- failed decrypt prevents start;
- backup payload excludes decoded runtime secrets.

---

# 6. Phase 4 — Cloudflare edge and firewall

Implement the default production boundary as one cohesive feature rather than independent setup scripts.

Deliverables:

- Cloudflare DNS token integration for Caddy DNS-01;
- validated Cloudflare CIDR fetch/cache;
- one supported Docker/Ubuntu firewall contract;
- public Caddy start gated on valid ingress policy;
- `vwctl edge status`;
- `vwctl edge refresh`;
- `doctor` checks for CIDR age/firewall/listener mismatch.

Security tests:

- empty/invalid CIDR response cannot replace last-known-good policy;
- stale cache beyond limit causes safe degraded/failure behavior;
- Caddy cannot remain publicly exposed if the required ingress gate cannot be established;
- direct mode cannot be entered accidentally by missing Cloudflare configuration.

---

# 7. Phase 5 — CrowdSec

Add CrowdSec after the edge/network model is stable.

Deliverables:

- upstream-supported CrowdSec host installation;
- minimal project acquisition/parsers/profile config;
- Cloudflare Worker/KV bouncer configuration for proxied-client enforcement;
- host firewall bouncer only where its signals are meaningful;
- `vwctl crowdsec status`;
- `vwctl crowdsec test`;
- `doctor` integration.

Avoid exposing Worker/KV internals as routine admin commands.

**Exit criterion:** a synthetic decision can be traced from detection to expected edge enforcement without manual file editing.

---

# 8. Phase 6 — Email

Start with direct SMTP.

Deliverables:

- Vaultwarden authenticated SMTP configuration;
- operational notification sender using the same configured relay;
- `vwctl mail test` or equivalent diagnostic folded into `doctor`;
- TLS/auth validation.

Do not add Postfix unless testing or production experience proves direct SMTP is insufficient.

If Postfix becomes necessary, introduce it as a separately reviewed optional profile with its own explicit complexity/security justification.

---

# 9. Phase 7 — Backup and recovery

Implement one normal recovery artifact plus offline key custody.

Deliverables:

- consistent SQLite snapshot;
- application state archive;
- manifest with hashes/schema/version metadata;
- Age encryption;
- local retention;
- optional rclone remote copy;
- `vwctl backup` and `vwctl backup status`;
- offline recovery-kit export;
- `vwctl restore`;
- post-restore permission and health verification.

Critical tests:

- corrupt archive rejected before service stop;
- insufficient disk rejected before destructive boundary;
- failed backup never displaces last known good recovery point;
- decoded secrets excluded;
- restore into empty state root reproduces synthetic data;
- missing wrong Age identity fails safely;
- services remain stopped when requested;
- post-start failed health returns failure rather than success language.

No V1 archive support.

---

# 10. Phase 8 — Automation and maintenance

Only after the manual operations work reliably should they be scheduled.

Recommended timers:

- health;
- backup;
- routine maintenance;
- edge CIDR refresh only if it cannot be safely included in maintenance.

Deliverables:

- hardened systemd units;
- randomized delay where appropriate;
- consistent exit handling;
- notification on real failure;
- contention behavior if a global operation lock is retained.

Prefer one simple lock around mutually exclusive destructive/mutating operations. Do not recreate a complex operation-management framework unless testing proves it is needed.

---

# 11. Phase 9 — `doctor` and operator UX

Treat `doctor` as a release feature, not polish.

`vwctl doctor` should be the first command support asks a junior admin to run.

It should verify and summarize:

- host/CPU support;
- effective installed release;
- production vs latest-resolved version policy;
- config and secrets;
- Docker/Compose;
- storage/mount;
- containers;
- listeners;
- Cloudflare/firewall;
- CrowdSec;
- SMTP;
- timers;
- disk capacity;
- backup freshness.

Every failed/degraded check should include one suggested remediation command or documentation pointer.

Support JSON output for issue reports and automated checking, but redact sensitive fields.

---

# 12. Phase 10 — Update lifecycle

Do not implement `update` as `git pull && rerun setup`.

Deliverables:

- `vwctl update --check`;
- verified release acquisition;
- exact version resolution from `versions.yaml`;
- pre-update backup;
- install into new immutable release directory;
- config compatibility validation;
- atomic `current` switch;
- restart and health gate;
- code-release rollback pointer when startup fails before a data schema commit.

`--use-latest` may be accepted only on explicitly development/test update paths and must record exact resolved versions.

---

# 13. Documentation rewrite plan

Write docs alongside the feature, not after the implementation.

## V2 operator docs

### `README.md`

Only:

- purpose;
- supported boundary;
- architecture diagram;
- prerequisite summary;
- install link;
- everyday commands;
- support/security warning.

### `docs/INSTALL.md`

One golden Cloudflare path first. Advanced direct mode later.

### `docs/OPERATIONS.md`

- status/doctor;
- start/restart;
- logs;
- users/invitation-related admin boundaries where project-relevant;
- config/secrets edits;
- updates;
- timers;
- routine troubleshooting.

### `docs/SECURITY.md`

- threat/trust model;
- Cloudflare origin boundary;
- CrowdSec role;
- secrets/key custody;
- root/Docker privilege model;
- backup trust boundary;
- supply-chain policy.

### `docs/RECOVERY.md`

- backup meaning;
- recovery-key custody;
- restore;
- replacement host;
- periodic restore drill.

### `docs/DEVELOPMENT.md`

- development setup;
- architecture source tree;
- tests;
- version pin updates;
- `--use-latest`;
- release process.

Remove V1-specific migration, volume migration, installed-script split-brain, and historical backup-tier explanations from V2 documentation.

---

# 14. CI/release gates

Every PR:

- lint/static checks;
- unit tests;
- config/schema tests;
- Compose generation validation;
- security-policy assertions;
- docs links/CLI drift checks;
- amd64 and arm64 resolver/asset tests.

Scheduled/release CI:

- current Ubuntu 24.04 fresh-host integration;
- container multi-architecture manifest validation;
- backup/restore integration;
- CrowdSec/edge integration where credentials/test environment permit;
- latest-upstream compatibility probe using `--use-latest` without modifying production pins.

This scheduled latest probe is an ideal use of the retained `--use-latest` contract: detect upstream incompatibility without silently advancing production.

---

# 15. Suggested pull-request sequence for implementation

Keep V2 PRs intentionally small.

1. `v2: define product boundary and ADRs`
2. `v2: add vwctl skeleton and config parser`
3. `v2: centralize version resolver and architecture assets`
4. `v2: install immutable runtime and systemd service`
5. `v2: add minimal Vaultwarden/Caddy compose`
6. `v2: add SOPS/Age secret materialization`
7. `v2: add Cloudflare ingress/firewall gate`
8. `v2: add CrowdSec edge enforcement`
9. `v2: add direct SMTP notifications`
10. `v2: add backup/restore`
11. `v2: add maintenance timers`
12. `v2: add doctor and support bundle`
13. `v2: add verified update lifecycle`
14. `v2: finalize docs and release gates`

Avoid a single PR that rewrites the entire repository; that would make security review harder even though the release itself is greenfield.

---

# 16. Definition of done for V2.0

V2.0 is ready when:

- a clean Ubuntu 24.04 amd64 host passes install/start/health;
- a clean Ubuntu 24.04 arm64 host passes the same release gate;
- OCI A1 Flex is demonstrated as a reference deployment without OCI-specific runtime code;
- a non-OCI Ubuntu host passes the same deployment flow;
- Cloudflare default mode exposes only the intended origin surface;
- CrowdSec decision enforcement is demonstrably effective at the edge;
- all persistent secrets are encrypted and runtime plaintext is volatile;
- routine SMTP works without a mandatory local MTA;
- backup to local/offsite storage succeeds and verifies;
- a fresh-host restore from the V2 backup + offline recovery identity is tested;
- `doctor` provides useful remediation from deliberately broken states;
- normal production uses exact versions;
- `--use-latest` is visibly development/test-only and records exact resolved versions;
- upgrade/update performs a pre-update backup and health-gated release switch;
- uninstall leaves data intact by default;
- operator documentation contains one obvious golden path;
- normal junior-admin operations require `vwctl`, not knowledge of internal scripts.

---

# 17. Highest-value first cuts

If the team wants the biggest maintainability wins early, make these cuts before porting anything else:

1. **Delete V1 migration as a V2 requirement.**
2. **Remove repository `.env` as runtime state.**
3. **Remove `/opt` script-copy synchronization in favor of immutable releases.**
4. **Replace Make/utility public interfaces with `vwctl`.**
5. **Centralize every production version pin.**
6. **Challenge/remove mandatory Postfix.**
7. **Reduce backup concepts.**
8. **Choose one firewall contract.**
9. **Do not port large V1 tests until the corresponding V2 behavior exists.**
10. **Write the golden-path docs first enough that a junior admin can validate the architecture before implementation grows.**

Those decisions will prevent V2 from becoming V1 with renamed directories.