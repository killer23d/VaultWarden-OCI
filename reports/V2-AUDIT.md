# VaultWarden-OCI V2 Greenfield Audit

Date: 2026-08-18

## Executive conclusion

V1 has a strong security mindset and unusually good defensive handling for a small-team shell-based appliance. The project is not suffering from a lack of controls. Its largest V2 risk is **complexity accumulation**: many individually defensible mechanisms now interact across large Bash libraries, utility scripts, systemd units, generated documentation, recovery workflows, and multiple copies of runtime state.

For V2, do **not** incrementally refactor V1 in place. Use V1 as the behavioral/security specification, then build a smaller greenfield implementation around a deliberately reduced contract.

The recommended direction is:

1. keep Ubuntu 24.04 LTS as the supported host baseline;
2. keep amd64 and arm64 as first-class architectures;
3. keep the runtime cloud-provider neutral;
4. retain `--use-latest` only as an explicit development/test override;
5. keep Cloudflare, Caddy, CrowdSec, SOPS/Age, encrypted backups, and systemd where they provide clear security or operational value;
6. remove migration compatibility and historical data-shape compatibility from V2;
7. drastically shrink the public command surface and the number of authoritative configuration/state locations;
8. prefer standard Ubuntu/Docker/systemd primitives over bespoke orchestration code;
9. make every production dependency/version source explicit and centrally resolvable;
10. preserve V1's fail-closed philosophy while deleting mechanisms whose main purpose was compatibility with V1 history.

## Scope reviewed

The audit covered the repository tree and the major runtime boundaries, including:

- `setup.sh`, `startup.sh`, `maintenance.sh`, `recover.sh`, backup/restore entrypoints;
- `lib/` architecture, especially configuration, Docker, firewall, secrets, crypto, storage, operations, and runtime permission ownership;
- `utilities/` setup, maintenance, backup, restore, health, CrowdSec, systemd, and administrative workflows;
- production and development Compose definitions;
- Caddy and CrowdSec configuration;
- systemd services/timers;
- GitHub Actions and the Bash test corpus;
- README, architecture, deployment, security, operations, recovery, configuration, command reference, project-boundary, and related documentation;
- version pinning and the `--use-latest` contract.

V1 already documents Ubuntu 24.04 Noble, amd64/arm64, cloud-neutral operation, and a non-production `--use-latest` policy. V2 should promote these from documented policy into a simpler architecture contract.

---

# 1. What V1 gets right

## 1.1 Security posture

Retain the following principles:

- fail closed when host, storage, firewall, recovery identity, or restore state is ambiguous;
- root-owned production administration rather than making Docker-group membership the operating model;
- secrets encrypted at rest with SOPS/Age and materialized transiently for containers;
- explicit least-privilege container settings (`cap_drop`, minimal `cap_add`, `no-new-privileges`, read-only roots where compatible);
- Cloudflare-first edge filtering;
- CrowdSec enforcement at an edge-aware point rather than pretending the proxied client is visible directly at the origin;
- encrypted, integrity-checked recovery artifacts;
- explicit verification before destructive restore/recovery boundaries;
- non-zero failure when a required check did not actually complete;
- SHA-pinned GitHub Actions and checksum-verified downloaded tools.

These are high-value controls and fit the project's scope.

## 1.2 Supported-host clarity

`utilities/setup-system.sh` explicitly validates Ubuntu 24.04/Noble and `amd64|arm64`, maps upstream assets by architecture, and fails unsupported hosts rather than guessing. That is a good contract for V2.

## 1.3 Cloud neutrality

The runtime already avoids hard dependence on OCI device aliases or OCI APIs. The design allows OCI, AWS, Azure, GCP, private virtualization, or physical hosts as long as the Ubuntu/network/storage prerequisites are satisfied. Keep this direction and remove remaining provider-oriented naming from the product identity/documentation where practical.

## 1.4 Supply-chain discipline

The canonical GitHub workflow pins `actions/checkout` by commit SHA and checksum-verifies yq/SOPS binaries. Preserve this approach and extend it consistently to every non-APT binary/source used by setup.

## 1.5 Recovery seriousness

V1 treats backup and restore as first-class engineering rather than an afterthought. V2 should retain tested database backup, disaster recovery, offline recovery identity, and restore verification, but implement fewer backup modes and less transaction machinery.

---

# 2. Primary architectural finding: V1 is too large for its product scope

The repository is a small-team appliance but contains many large shell components. Examples include very large modules for secrets, migration, operations, backup/restore, health, systemd setup, and CrowdSec setup, plus a large Bash test suite and generated command reference.

This creates four maintainability problems:

1. **The source language is doing application-framework work.** Bash is now implementing schemas, transactions, locks, state publication, recovery protocols, dependency resolution, templating, health aggregation, and UI behavior.
2. **The number of contracts is too high.** Repository state, persistent state, installed systemd state, transient state, backup metadata, DR manifests, storage sentinels, operation metadata, and generated runtime assets each have their own rules.
3. **Testing cost tracks implementation complexity.** V1 has extensive tests because the runtime is complex; preserving all those mechanisms would force V2 to keep paying that cost.
4. **Junior-admin cognitive load is hidden by commands.** A simple `make` command may trigger several layers of shell/runtime authority that are difficult to debug without understanding project internals.

### V2 decision

Treat V1 behavior as reference material, not as code to mechanically clean up. Re-implement the golden path with a significantly smaller architecture.

---

# 3. Configuration and state

## Finding V2-CFG-01 — Three configuration authorities are too many

V1 separates:

- repository `.env` authoring state;
- `${PROJECT_STATE_DIR}/config/install.env` persistent runtime state;
- `/etc/vaultwarden/vaultwarden.env` installed systemd state.

The model is internally coherent, but it creates synchronization, validation, split-brain detection, installation, restore, and documentation complexity.

### Recommendation

V2 should have **one persistent non-secret configuration authority** outside the checkout, for example:

`/etc/vaultwarden-oci/config.env`

The checkout should contain only `config.env.example`. systemd and Compose should consume the same installed file. The repository is source code, not a configuration database.

This removes an entire class of `sync-env`, installed-runtime drift, and repository-vs-runtime behavior.

## Finding V2-CFG-02 — Central defaults are good but still too distributed

`lib/defaults.sh` is the right idea, but version pins are also embedded in Compose, setup-system, workflows, and documentation.

### Recommendation

Create one source-controlled versions file, e.g. `versions.env` or `versions.yaml`, containing all production pins:

- Vaultwarden
- Caddy
- Postfix image
- CrowdSec/bouncers
- SOPS
- yq
- any downloadable helper

All setup/render/update/test code reads this file.

`--use-latest` should switch the resolver policy, not create separate version logic throughout the codebase.

---

# 4. `--use-latest`

## Finding V2-VER-01 — Retain the flag, simplify its meaning

V1 intentionally keeps `--use-latest`, but semantics vary: some image fields become literal `latest`, SOPS may be resolved dynamically, while Caddy/yq remain pinned.

This is understandable historically but awkward as a greenfield contract.

### V2 contract

`--use-latest` is **development/testing only** and should mean:

- resolve newest compatible upstream versions at invocation time;
- never silently become the normal production state;
- print a conspicuous non-production warning;
- record the resolved versions in a generated lock/report so a test is reproducible after the fact;
- do not use literal floating tags in the normal production lock file;
- Caddy/xcaddy may still require a concrete resolved tag; the resolver should obtain one rather than special-casing it elsewhere.

Recommended commands:

- `vwctl install` — pinned production versions;
- `vwctl install --use-latest` — resolve latest compatible versions, development/test mode;
- `vwctl versions` — show effective versions and source;
- `vwctl update --check` — compare pins to available stable versions without applying them.

---

# 5. Host and CPU portability

## Finding V2-PORT-01 — Current supported architecture boundary is good

The current host setup explicitly maps amd64 and arm64 assets. Continue this.

### Recommendation

Do not claim generic CPU agnosticism. State the contract precisely:

> CPU-neutral implementation with tested support for amd64 and arm64.

Other architectures can be added only when all upstream containers/binaries and CI coverage support them.

## Finding V2-PORT-02 — CI is amd64-only

The canonical GitHub workflow installs `yq_linux_amd64` and SOPS `linux.amd64`. This verifies the shell behavior on amd64 but does not prove the arm64 release path.

### Recommendation

V2 CI should include:

- architecture-independent unit/static tests on standard GitHub runners;
- explicit tests of the version/asset resolver for both amd64 and arm64;
- at least one periodic or release-gate arm64 integration run using a native/self-hosted/appropriate emulated environment if available;
- Compose image manifest checks for both target platforms.

---

# 6. Docker and network architecture

## Finding V2-NET-01 — Good isolation, excessive bespoke packet-path coupling

The production Compose model has meaningful hardening and network separation. However, the V1 firewall library introspects the running Docker daemon, requires Docker's iptables backend, requires `DOCKER-USER`, manages a custom `VW-CF-INGRESS` chain, validates existing Caddy bindings, and may stop Caddy to fail closed.

This is secure-minded but increases dependency on Docker's packet-filter implementation and makes host firewall behavior one of the most complex parts of the appliance.

### Recommendation

For V2 choose **one** documented firewall ownership model and test it deeply.

Preferred approach:

- Ubuntu 24.04;
- Docker Engine with its supported packet filtering;
- UFW for host-origin rules;
- a minimal deterministic Docker ingress policy owned by one small module;
- Cloudflare CIDR allow-listing only for public Caddy ports when proxy mode is enabled;
- SSH policy explicitly left as a host/operator prerequisite or handled by a small opt-in host-hardening module.

Avoid supporting parallel UFW/iptables/nftables modes in V2. If Docker's supported Ubuntu 24.04 networking requires a specific backend, state it as a prerequisite instead of building broad backend-detection logic.

## Finding V2-NET-02 — Fixed bridge subnets are fragile

V1 pins three bridge subnets (`172.21/28`, `172.22/28`, `172.23/28`). Determinism is useful for firewall rules, but fixed RFC1918 ranges can conflict with VPNs, corporate networks, or other Docker deployments.

### Recommendation

Either:

- remove fixed subnets unless technically required; or
- make one small configurable project subnet block with validation and derive networks from it.

Do not expose three independent subnet settings to a junior admin.

## Finding V2-NET-03 — Public port 80 should not be unconditional

Production Compose publishes both `80` and `443` even though the normal path is Cloudflare DNS-01.

### Recommendation

In the default Cloudflare DNS-01 profile publish only `443`. Enable `80` only for the explicit HTTP-01/direct profile.

---

# 7. Container architecture

## Finding V2-CTR-01 — Hardened defaults are good

Keep:

- non-root service identities where practical;
- `cap_drop: ALL` and minimal additions;
- `no-new-privileges`;
- read-only roots where upstream images support them;
- tmpfs for transient paths;
- health checks;
- bounded log rotation;
- resource limits appropriate to small instances.

## Finding V2-CTR-02 — Postfix sidecar costs disproportionate complexity

Postfix brings extra capabilities, mutable filesystem requirements, queue-management tooling, health logic, sender-domain logic, destructive queue operations, system documentation, and tests.

### Recommendation

For V2, challenge this dependency rather than automatically retaining it.

Preferred greenfield option: use Vaultwarden's direct authenticated SMTP support for application email, and have operational notifications call the same configured relay through a minimal sender library/tool.

Retain Postfix only if there is a demonstrated requirement that cannot be met reliably with direct SMTP. If retained, make it an optional profile, not a mandatory component.

This single decision can remove a large amount of code and documentation.

---

# 8. Cloudflare and CrowdSec

## Finding V2-EDGE-01 — Keep Cloudflare-first security

Cloudflare DNS/proxy/WAF plus origin restriction remains appropriate for this project.

V2 should make two modes explicit:

- `cloudflare` (default/production): proxied DNS, DNS-01, Cloudflare origin allow-list, CrowdSec edge enforcement;
- `direct` (advanced): no Cloudflare proxy dependency, alternate TLS/firewall behavior.

Do not accumulate more modes.

## Finding V2-EDGE-02 — CrowdSec setup should be declarative

V1's CrowdSec integration is powerful but setup/worker tooling is large.

### Recommendation

V2 should keep CrowdSec but reduce custom orchestration:

- install from a supported upstream repository/package path;
- keep project-owned acquisitions/profiles small;
- isolate Cloudflare Workers bouncer provisioning into a single optional `edge` module;
- generate config from a small template plus validated inputs;
- provide `vwctl crowdsec status` and `vwctl crowdsec test` instead of exposing internals as normal admin workflow.

---

# 9. Secrets

## Finding V2-SEC-01 — SOPS/Age model should remain

The persistent encrypted secret model and transient runtime materialization are strong.

### Recommendation

Keep one encrypted secrets file under `/etc/vaultwarden-oci/` or `/var/lib/vaultwarden-oci/`, an operational Age key under `/etc/vaultwarden-oci/`, and decoded files only under `/run/vaultwarden-oci/`.

## Finding V2-SEC-02 — The schema system is too ambitious for Bash

V1 has a sizable secret-schema and secret-management subsystem. The security intent is correct; the implementation complexity is high.

### Recommendation

V2 should define a much smaller schema with only the secrets required by enabled profiles. A typed helper written in Python 3 (already present on Ubuntu) is preferable to implementing schema transforms and structured validation in large Bash libraries.

Python is recommended only for structured configuration/secrets/metadata logic; shell can remain the thin orchestration layer.

---

# 10. Backup and restore

## Finding V2-DR-01 — Three backup tiers are more than the greenfield product needs

The current `db`, `full`, and `emergency` model is carefully designed, but it creates large backup/restore implementations and extensive operator documentation.

### Recommendation

V2 should use two concepts:

1. **automatic backup** — encrypted complete application recovery set, suitable for routine restore;
2. **offline recovery kit** — separately protected Age identity/configuration material required to rebuild a host.

Database-only snapshots can remain an implementation optimization, not a separate user-facing backup product.

Eliminate V1 migration/import compatibility from V2. V2 begins with fresh state by design.

## Finding V2-DR-02 — Keep restore verification, simplify the transaction

Retain:

- integrity verification before mutation;
- disk-space preflight;
- service stop before state replacement;
- atomic/staged promotion where practical;
- permission repair;
- explicit start/no-start behavior;
- post-start health verification.

Remove transaction code that exists mainly to support historical V1 state layouts, migrations, multiple archive generations/formats, and legacy aliases.

---

# 11. systemd

## Finding V2-SD-01 — systemd is the right primitive, but there are too many units

V1 uses multiple services/timers for backups, health, maintenance, DNS, firewall, startup, notifications, etc. This is robust but creates installed-runtime copying, validation, timer ownership, failure notification, and docs complexity.

### Recommendation

Reduce to approximately:

- `vaultwarden-oci.service` — stack lifecycle/startup gate;
- `vaultwarden-oci-health.timer`;
- `vaultwarden-oci-backup.timer`;
- `vaultwarden-oci-maintenance.timer`;
- optional `vaultwarden-oci-edge-refresh.timer` only if Cloudflare CIDR refresh cannot be folded into maintenance safely.

Use systemd directly from an installed immutable application directory. Do not maintain a second manually synchronized `/opt/vaultwarden-scripts` copy of arbitrary checkout state.

Install a release to `/opt/vaultwarden-oci/<version>/` with a `/opt/vaultwarden-oci/current` symlink, or package/install the tool into `/usr/local/lib/vaultwarden-oci`. systemd always points at the installed release.

---

# 12. Command surface and junior-admin UX

## Finding V2-UX-01 — Make + wrapper scripts + utilities is too broad

The current project has root scripts, a large Makefile, many utility scripts, and a generated command reference. This is difficult to discover and easy to use inconsistently.

### Recommendation

V2 should expose one command: `vwctl`.

Target public surface:

```text
vwctl install
vwctl start
vwctl stop
vwctl restart
vwctl status
vwctl health
vwctl config edit
vwctl secrets edit
vwctl backup
vwctl restore
vwctl update --check
vwctl update
vwctl doctor
vwctl logs [service]
vwctl uninstall
```

Advanced implementation helpers should not be public API.

If a Makefile remains, it should be developer-only (`make test`, `make lint`, `make docs`) and not the production administrator interface.

## Finding V2-UX-02 — Add `doctor`

A junior admin benefits more from one comprehensive diagnostic command than from knowing which validation/setup/status tool owns each subsystem.

`vwctl doctor` should report:

- supported OS/architecture;
- required commands;
- effective version pins;
- config validity;
- secret decryptability without revealing values;
- Docker/Compose availability;
- container health;
- Cloudflare DNS/proxy expectations;
- firewall state;
- CrowdSec state;
- backup freshness and last verification;
- systemd timer state;
- disk space;
- actionable remediation commands.

---

# 13. Documentation

## Finding V2-DOC-01 — V1 documentation is comprehensive but too fragmented

The existing documentation is impressive, but a junior admin faces many documents covering architecture, operations, backup/restore, disaster recovery, secrets, scripts, generated commands, host acceptance, migration, volume migration, credential handoffs, etc.

### Recommendation

V2 should begin with five operator documents only:

1. `README.md` — what it is, support boundary, 10-minute overview;
2. `docs/INSTALL.md` — golden path only;
3. `docs/OPERATIONS.md` — normal admin tasks and `doctor`;
4. `docs/SECURITY.md` — threat model, trust boundaries, secrets, Cloudflare/CrowdSec;
5. `docs/RECOVERY.md` — backup, restore, fresh-host recovery.

Add `docs/DEVELOPMENT.md` for contributors, including `--use-latest`.

Architecture details needed only by maintainers belong in `docs/DEVELOPMENT.md` or code comments, not the junior-admin runbook.

Remove V1 migration documentation from the V2 branch because V2 is explicitly fresh-start.

## Finding V2-DOC-02 — Generate reference, not narrative

Generated docs are useful for exact CLI grammar, but should not be a huge operator-facing document. Generate `vwctl --help` and a compact CLI reference from the command implementation, while keeping workflows as hand-written task-oriented docs.

---

# 14. Testing and CI

## Finding V2-CI-01 — V1 test volume is evidence of complexity

The existing Bash suites cover many important failure boundaries, but several individual test files are very large. V2 should not carry them forward mechanically.

### Recommendation

Write a new V2 test pyramid:

- ShellCheck for shell;
- Ruff/pytest if Python is used;
- config/schema unit tests;
- version resolver tests for amd64/arm64;
- Compose `config` validation;
- security policy assertions (capabilities, ports, networks, read-only/root user rules);
- disposable Ubuntu 24.04 integration install test;
- backup/restore smoke test with synthetic state;
- release matrix checks for container multi-arch manifests;
- docs link/check command drift test.

CI should pin all actions by SHA and use checksummed downloaded binaries.

Add dependency/update automation only if it opens reviewable PRs and never changes production pins automatically.

---

# 15. Language and implementation recommendation

## Finding V2-CODE-01 — Keep Bash thin

Bash is excellent for small host orchestration but V1 uses it for structured application logic.

### Recommended V2 implementation split

**Bash:**

- bootstrap installer;
- invoke apt/systemctl/docker;
- thin compatibility glue.

**Python 3 standard library + minimal packaged dependencies:**

- `vwctl` CLI;
- config parsing/validation;
- architecture/version resolver;
- secret schema/materialization orchestration;
- structured health report;
- backup metadata/manifest validation;
- templating/rendering of Compose/systemd/config.

Python 3 is already a supported Ubuntu 24.04 system component in the current project, and moving structured logic there improves testability and error handling without introducing a separate runtime platform such as Node.js/Go/Rust.

If the maintainers strongly prefer shell-only V2, then enforce a hard complexity budget: no library above roughly 500 lines, no public helper proliferation, and no structured data protocol more complex than simple key/value files.

---

# 16. Proposed V2 repository layout

```text
VaultWarden-OCI/
├── README.md
├── VERSION
├── versions.yaml
├── config/
│   ├── config.env.example
│   ├── compose.yaml
│   ├── caddy/
│   ├── crowdsec/
│   └── systemd/
├── src/vwctl/
│   ├── cli.py
│   ├── config.py
│   ├── versions.py
│   ├── system.py
│   ├── secrets.py
│   ├── edge.py
│   ├── backup.py
│   └── doctor.py
├── install.sh
├── tests/
└── docs/
    ├── INSTALL.md
    ├── OPERATIONS.md
    ├── SECURITY.md
    ├── RECOVERY.md
    └── DEVELOPMENT.md
```

Installed runtime:

```text
/etc/vaultwarden-oci/
  config.env
  age-key.txt
  secrets.yaml

/var/lib/vaultwarden-oci/
  data/
  caddy/
  backups/

/run/vaultwarden-oci/
  secrets/

/opt/vaultwarden-oci/current/
  application release files
```

One authority per concern.

---

# 17. V2 security baseline

V2 should not be considered ready until these are true:

- production pins are immutable and centralized;
- `--use-latest` is visibly non-production and records resolved versions;
- only required ports are published;
- Cloudflare mode restricts origin ingress to Cloudflare networks;
- direct mode is explicit and cannot be entered accidentally;
- containers drop capabilities and run non-root where upstream allows;
- persistent secrets are encrypted;
- decoded secrets live only in `/run`;
- no production secret values appear in normal logs/process arguments;
- restore verifies before mutation;
- backup verification failure cannot replace the last known good recovery point;
- operational commands fail when required checks did not run;
- `doctor` reports degraded/unknown separately from healthy;
- amd64 and arm64 version resolution are tested;
- every external binary download is versioned and integrity verified;
- GitHub Actions are SHA-pinned;
- uninstall never deletes application data without an explicit destructive acknowledgement.

---

# 18. Priority decisions before implementation

## P0 — Architecture decisions

1. Greenfield branch/codepath; no V1 migration compatibility.
2. One installed config authority.
3. One public CLI (`vwctl`).
4. Central versions file and resolver.
5. Thin Bash + Python CLI, unless shell-only complexity budget is explicitly chosen.
6. Two backup concepts instead of three user-facing tiers.
7. Decide whether Postfix is actually required.
8. One firewall/backend contract; no generalized firewall framework support.

## P1 — Security/runtime

1. Rebuild Compose from minimum services and ports.
2. Rebuild Cloudflare/CrowdSec integration declaratively.
3. Preserve SOPS/Age transient-secret design.
4. Reduce systemd units.
5. Implement `doctor`.
6. Add amd64/arm64 resolver/manifest CI.

## P2 — Operator experience

1. Five-document operator set.
2. Task-oriented errors with remediation.
3. `vwctl status`, `health`, and `doctor` produce consistent summaries.
4. Explicit production/development distinction for `--use-latest`.

---

# Final recommendation

V1 should be treated as a **well-defended prototype that has grown into a framework**. Its security lessons are valuable; its implementation shape should not be the template for V2.

The V2 design goal should be:

> A junior administrator can understand where configuration, secrets, data, backups, logs, services, and versions live without reading the source code.

And the maintainer goal should be:

> Each production concern has one authority, one normal path, and one diagnostic path.

If V2 achieves that while retaining Cloudflare-first origin protection, CrowdSec edge enforcement, least-privilege containers, SOPS/Age secrets, tested backups, explicit recovery, pinned releases, and Ubuntu 24.04 amd64/arm64 support, it will be materially safer to operate than V1 even if it contains fewer security mechanisms.