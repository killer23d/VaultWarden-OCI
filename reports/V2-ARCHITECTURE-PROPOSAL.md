# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-18
Revision: post-rescan architecture.

## 1. Design objective

V2 is a **fresh-install security appliance for a small team**, not a compatibility release of V1.

The design should optimize for:

1. clear security boundaries;
2. junior-admin diagnosability;
3. small code surface;
4. reproducible production installs;
5. straightforward recovery;
6. amd64/arm64 portability on Ubuntu 24.04;
7. low ongoing test and maintenance cost.

The architecture should deliberately reject features that require disproportionate framework code.

## 2. Non-goals

V2 beta should not implement:

- V1 migration or import compatibility;
- V1 backup/archive compatibility;
- Kubernetes, Swarm or HA;
- a generic cloud-provider layer;
- a generic firewall backend abstraction;
- a plugin/provider registry;
- a database for operation metadata;
- an interactive dashboard/TUI;
- a local SMTP queue/Postfix sidecar;
- multiple public backup tiers;
- a custom test runner;
- a generated exhaustive command-reference document;
- auto-update daemons;
- support outside Ubuntu 24.04 LTS, amd64 and arm64.

These can be revisited only from demonstrated operator need.

---

# 3. Language architecture

## 3.1 Python is the V2 application language

Use Ubuntu 24.04's Python 3.12 as the primary implementation language.

Runtime Python should use the **standard library by default**. This keeps installation simple and avoids packaging a dependency graph for a small appliance.

Python should own structured or stateful logic:

- CLI parsing and command dispatch;
- TOML configuration and version manifests;
- validation and normalized error reporting;
- subprocess execution;
- platform/architecture mapping;
- global mutation lock;
- status and diagnostics;
- SOPS/Age orchestration;
- backup manifest/retention/selection logic;
- restore preflight and promotion control;
- Cloudflare CIDR parsing/validation;
- systemd installation/rendering where structured generation is useful;
- machine-readable JSON output.

Do not introduce an application framework, dependency-injection layer, plugin architecture, ORM, async framework or daemon merely because Python is available.

## 3.2 Bash is host glue, not the application framework

Bash remains acceptable for:

- one minimal bootstrap/installer entrypoint before `vwctl` is installed;
- very small host glue where shell is clearer than Python;
- Caddy/container entrypoint behavior required by an upstream image.

A shell file that begins accumulating configuration parsing, transactions, data structures, complex locks or broad mocks is a signal that the logic belongs in Python.

## 3.3 Development dependencies

Development may use:

- `pytest` for tests;
- `ruff` for Python lint/format checks;
- ShellCheck for the small remaining shell surface.

Start with no pytest plugins and no runtime third-party Python packages. Add one only after a concrete need is documented.

---

# 4. Proposed filesystem contract

Keep installed code, configuration, persistent state and runtime secrets clearly separated.

```text
/opt/vaultwarden-oci/
  releases/<version>/       # immutable installed application release
  current -> releases/...   # active release symlink

/etc/vaultwarden-oci/
  config.toml               # one non-secret runtime authority
  age-key.txt               # operational Age private identity, root-only
  secrets.json              # SOPS-encrypted secret values

/var/lib/vaultwarden-oci/
  data/                     # Vaultwarden persistent application data
  caddy/                    # Caddy persistent state
  backups/                  # encrypted V2 recovery artifacts
  logs/                     # only project-owned logs that are not journal/container logs

/run/vaultwarden-oci/
  secrets/                  # decrypted ephemeral secret files
  lock                      # global mutating operation lock
  transient/                # temporary runtime state if required
```

If a dedicated data volume is used, mount the persistent state root at `/var/lib/vaultwarden-oci` rather than introducing a second project-state path. The mount itself changes; the application paths do not.

This removes V1's repository `.env` -> persistent `install.env` -> installed environment synchronization chain.

---

# 5. Configuration model

## 5.1 One non-secret authority

Use `/etc/vaultwarden-oci/config.toml` as the sole installed non-secret configuration.

Python's `tomllib` reads it without a runtime dependency.

Example categories:

```toml
[site]
domain = "vault.example.com"
timezone = "UTC"

[cloudflare]
proxy_enabled = true

[email]
host = "smtp.example.com"
port = 587
security = "starttls"
username = "vaultwarden@example.com"
from_address = "vaultwarden@example.com"

[backup]
remote = "remote:vaultwarden"
retention_days = 30

[storage]
mode = "boot"  # or "volume"
device = ""
```

This example is illustrative, not a requirement to expose every upstream Vaultwarden option. Keep the supported V2 configuration deliberately small. Advanced Vaultwarden environment overrides should not be added until there is a real product need.

## 5.2 Configuration lifecycle

Normal commands:

```text
vwctl config show
vwctl config validate
vwctl config edit
```

`config edit` should edit one file and validate it before replacing the live copy. It should not create another persistent representation.

Compose environment can be produced in memory for the subprocess invocation or rendered into a root-owned volatile/runtime file. It must not become a second operator-editable authority.

---

# 6. Secret model

Keep SOPS + Age, but simplify representation.

Recommended files:

```text
/etc/vaultwarden-oci/age-key.txt    0600 root:root
/etc/vaultwarden-oci/secrets.json   0600 root:root, SOPS encrypted
/run/vaultwarden-oci/secrets/       0700 root:root
```

Use SOPS JSON so Python can inspect structure using `json` and V2 can remove production `yq` and PyYAML requirements.

Only secrets used by the supported profile belong in the schema. Expected initial values are likely:

- Vaultwarden admin token/hash;
- Caddy Cloudflare DNS token;
- CrowdSec Cloudflare credentials required by the selected upstream integration;
- SMTP password;
- optional Vaultwarden push credentials;
- optional offsite-backup credentials if not delegated to a separately protected rclone config.

Do not implement a general secret-provider framework.

Decrypted Compose secret source files are recreated under `/run` before startup and removed/overwritten as appropriate. Never put plaintext secret values in the TOML config, process arguments or ordinary logs.

---

# 7. Version model and `--use-latest`

Use one source-controlled `versions.toml` in the release source.

Example shape:

```toml
vaultwarden = "1.x.y"
caddy = "2.x.y"
crowdsec = "1.x.y"
sops = "3.x.y"
# additional exact pins only for components actually owned by V2
```

The version module is the only owner of upstream version resolution.

## Production

`vwctl install` and normal update paths use exact source-controlled pins.

## Development/testing

`--use-latest` remains supported and means:

1. explicitly opt into non-production resolution;
2. resolve current compatible upstream releases/tags;
3. convert them immediately into exact resolved versions;
4. record the resolved set in a run artifact/log;
5. use those exact values for that run.

Do not spread `if use_latest` branches across installers, Compose templates and component setup scripts.

Suggested interfaces:

```text
vwctl versions
vwctl versions check
vwctl install --use-latest
```

No background auto-updater is required.

---

# 8. Operator CLI

V2 should expose one public production command: `vwctl`.

Initial command budget:

```text
vwctl install
vwctl start
vwctl stop
vwctl restart
vwctl status
vwctl doctor [--json]
vwctl logs [SERVICE]
vwctl config {show,validate,edit}
vwctl secrets {edit,rotate,check}
vwctl backup
vwctl restore
vwctl update {check,apply}
vwctl versions
```

CrowdSec-specific troubleshooting can be nested only if required:

```text
vwctl crowdsec status
vwctl crowdsec test
```

Avoid exposing every internal helper as an operator command.

Makefile targets, if retained, are developer conveniences such as `make test`, `make lint`, and `make compose-check`; Make is not an operator API.

---

# 9. Diagnostics as a first-class product surface

`vwctl doctor` replaces much of the current health/dashboard troubleshooting surface.

It should be read-only by default and return stable check IDs plus a simple state:

```text
PASS
WARN
FAIL
SKIP
```

Candidate checks:

- supported Ubuntu version and architecture;
- required binaries;
- configuration validity;
- age key and SOPS decryptability;
- Docker daemon/Compose availability;
- expected containers and health states;
- local Vaultwarden `/alive`;
- external HTTPS path through Cloudflare;
- Caddy certificate/runtime status;
- firewall ingress contract;
- CrowdSec service and edge-bouncer status;
- SMTP connectivity/authentication without sending unless explicitly requested;
- backup age and last verified recovery point;
- storage free space and expected mount identity;
- systemd units/timers.

`--json` should expose stable IDs and values so diagnostics can be tested without locking exact human prose.

Do not initially combine `doctor` with automatic repair. A future `vwctl repair` can be introduced only for a small set of deterministic repairs after production evidence.

---

# 10. Concurrency

V2 starts with one global mutating lock implemented in Python using `fcntl.flock()`.

Mutating commands such as install/update/backup/restore/config replacement/secrets rotation take the lock. Read-only commands such as status/doctor/logs do not.

Requirements:

- non-blocking or bounded-wait behavior is explicit;
- lock contention gets one defined exit code and clear owner/action message where safely available;
- child commands do not inherit the lock descriptor;
- lock metadata is diagnostic only, not authority.

Do not implement operation-specific locks, a separate lock-holder process, process-state database or distributed locking in beta.

---

# 11. Core containers

The normal V2 Compose stack should start with only:

1. Vaultwarden;
2. Caddy.

Retain valuable V1 hardening:

- explicit users;
- `cap_drop: ALL` plus only necessary additions;
- `no-new-privileges`;
- read-only root filesystems where compatible;
- tmpfs for transient writable paths;
- bounded logs;
- health checks;
- reasonable memory/PID limits.

Do not duplicate the same resource limit through multiple Compose syntaxes unless both are proven active/necessary for the supported Docker Compose path.

## Email

Use Vaultwarden's direct authenticated SMTP support. Operational notifications use Python `smtplib` through the same relay.

No Postfix container or local queue tooling in V2 beta.

## Networks

Avoid fixed RFC1918 subnets unless a technical requirement proves they are necessary.

Use the fewest networks needed to preserve isolation:

- private backend path between Caddy and Vaultwarden;
- explicit outbound capability where Vaultwarden/Caddy require it.

Do not make network names/subnets part of normal operator configuration.

---

# 12. Cloudflare ingress and host firewall

V2 beta should support **one production ingress model**: Cloudflare-proxied HTTPS with Caddy DNS-01.

That means:

- Caddy publishes TCP `443` only by default;
- TCP `80` is not published for the Cloudflare DNS-01 golden path;
- Cloudflare SSL mode is Full (Strict);
- host/provider ingress is restricted to Cloudflare address ranges where enforceable;
- origin cannot silently become generally reachable if Cloudflare CIDR refresh fails.

Because Docker-published ports do not behave like ordinary UFW `INPUT` traffic, V2 must not pretend UFW alone protects a published Caddy port.

For beta, explicitly support:

- Docker Engine bridge networking;
- Docker's iptables packet-filter backend;
- one very small project-owned ingress chain in the Docker packet path;
- validated Cloudflare IPv4/IPv6 sets;
- last-known-good cache with bounded age;
- fail-closed behavior when no safe policy can be established.

Do not support an nftables alternative in the same beta implementation. Do not create a generic firewall abstraction.

Provider firewall/security-group configuration remains an installation prerequisite and documentation concern, not a cloud API integration.

---

# 13. CrowdSec

Keep CrowdSec, but rely on upstream installation/integration where possible.

Intended model:

- CrowdSec runs on the host;
- acquisitions cover SSH and Caddy/Vaultwarden logs as appropriate;
- host firewall bouncer is useful for host-visible attacks such as SSH;
- Cloudflare Worker bouncer handles real proxied web-client enforcement at the edge.

V2 project code should own only:

- required project acquisition/profile config;
- secure credential handoff;
- selected bouncer configuration;
- status/test diagnostics;
- minimal lifecycle integration.

Do not port the V1 CrowdSec installer wholesale before checking current supported upstream installation paths.

---

# 14. Backup and recovery

V2 should expose one normal backup concept:

```text
vwctl backup
```

A backup is a complete encrypted V2 recovery point. Internally it should include a verified consistent SQLite snapshot and the persistent application/configuration material that is appropriate for recovery, excluding the operational private key.

Separately provide an offline recovery kit that contains the information/operator identity needed to recover the encrypted state.

Do not expose `db/full/emergency` as three permanent public products in V2 beta.

## Backup requirements

- consistent SQLite snapshot;
- manifest with V2 format version and checksums;
- encryption before publication/offsite transfer;
- verification before success;
- atomic publication;
- simple retention;
- optional rclone transfer after local verification;
- no plaintext secret/key staging on persistent storage.

## Restore requirements

- V2 format only;
- validate archive/manifest/decryption before live mutation;
- validate free space and target storage before service stop;
- take one optional/preconfigured safety snapshot if useful without reintroducing backup tiers;
- stop the stack;
- stage extracted state;
- promote using a small, explicit transaction boundary;
- restore permissions;
- leave services stopped or start according to an explicit flag/prompt;
- if started, require successful health before reporting success.

No V1 format detection or compatibility adapters.

---

# 15. Storage

Support two installation choices while keeping one runtime path:

- boot volume;
- dedicated mounted volume.

The dedicated volume is mounted at `/var/lib/vaultwarden-oci`; do not relocate project state to a second configurable root.

Installation may create a small ownership marker on a volume it initializes. It must fail closed before formatting/mounting a device that is not clearly authorized.

No live V1 boot-to-block migration workflow in beta. A V2 operator who later wants to move state should use documented offline backup/restore onto a fresh target rather than a bespoke migration state machine.

---

# 16. systemd

Keep systemd as the only scheduler/lifecycle manager.

Target unit budget:

- `vaultwarden-oci.service` — startup/lifecycle gate;
- `vaultwarden-oci-health.timer` + service;
- `vaultwarden-oci-backup.timer` + service;
- `vaultwarden-oci-maintenance.timer` + service.

A separate edge-refresh timer should exist only if Cloudflare CIDR refresh cannot safely be included in maintenance/health without weakening ingress freshness.

Units execute `/opt/vaultwarden-oci/current/...` and consume the installed config directly. They never execute an arbitrary git checkout.

No repository-to-`/opt` synchronization validator is required because releases are installed immutably.

---

# 17. Update/release model

An update is an explicit operator action:

```text
vwctl update check
vwctl update apply
```

Suggested safe flow:

1. validate current health;
2. create/verify recovery point according to policy;
3. stage a new immutable application release;
4. pull/build exact pinned container versions;
5. switch `current` to the new release;
6. restart;
7. run `doctor`/health gate;
8. roll back the application release symlink if application-code activation fails before state/schema changes.

Avoid adding self-update agents or unattended container updates.

---

# 18. Test architecture

The runtime architecture and test architecture must be designed together.

V2 uses three validation layers only:

1. Python unit tests for deterministic logic;
2. small integration tests for subprocess/filesystem/Compose/security boundaries;
3. disposable real-host acceptance for release candidates.

No custom test inventory, source-text mirror suites or issue-specific permanent tests.

See `V2-TEST-STRATEGY.md`.

---

# 19. Suggested source layout

Do not create empty modules for future phases. Let modules appear as functionality is implemented.

A likely mature layout is:

```text
src/vwctl/
  __main__.py
  cli.py
  config.py
  versions.py
  runtime.py
  security.py
  recovery.py
  doctor.py

templates/
  compose.yaml
  Caddyfile
  systemd/
bootstrap.sh
versions.toml
tests/
```

This is a ceiling, not a requirement. A phase should not create a module until it owns real behavior.

---

# 20. Architecture acceptance test

Before adding any V2 mechanism, ask:

1. Does a junior admin need to understand this to recover the service?
2. Does it protect a concrete security/data property?
3. Can Ubuntu, Docker, systemd, SOPS/Age, Caddy, Cloudflare or CrowdSec already do it safely?
4. Will implementing it create a second source of truth?
5. How many permanent tests and docs will this require?
6. Can a simpler design delete the need entirely?

If the answer points toward more framework than product value, do not add it.
