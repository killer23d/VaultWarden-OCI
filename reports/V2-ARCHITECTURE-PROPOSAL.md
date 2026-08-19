# VaultWarden-OCI V2 Architecture Proposal

Date: 2026-08-18

## Design objective

V2 should be a fresh-install, security-first Vaultwarden appliance for small teams that remains easy for a junior administrator to operate.

The architecture should optimize for:

- Ubuntu 24.04 LTS;
- tested amd64 and arm64 support;
- cloud-provider-neutral host runtime;
- OCI A1 Flex as a reference deployment, not a runtime dependency;
- Cloudflare-first ingress and DNS;
- CrowdSec enforcement;
- reproducible production versions;
- explicit `--use-latest` development/test mode;
- minimal public command surface;
- one authority for each class of state;
- safe backup/recovery;
- low cognitive and maintenance cost.

V2 has no requirement to import or preserve V1 application/project state.

---

# 1. Architectural principles

## 1.1 One authority per concern

| Concern | V2 authority |
| --- | --- |
| Installed application | `/opt/vaultwarden-oci/current` |
| Non-secret configuration | `/etc/vaultwarden-oci/config.env` |
| Persistent encrypted secrets | `/etc/vaultwarden-oci/secrets.yaml` |
| Operational Age identity | `/etc/vaultwarden-oci/age-key.txt` |
| Application state | `/var/lib/vaultwarden-oci/` or configured mounted state root |
| Runtime decoded secrets | `/run/vaultwarden-oci/secrets/` |
| Production dependency pins | source-controlled `versions.yaml` |
| Service lifecycle | systemd + Docker Compose |
| Operator interface | `vwctl` |

No normal production workflow should depend on the Git checkout after installation.

## 1.2 Golden path first

The default production profile is:

```text
Internet
   |
Cloudflare DNS / Proxy / WAF / CrowdSec edge decision enforcement
   |
provider firewall/security group
   |
Ubuntu host firewall / Docker ingress gate
   |
Caddy :443
   |
Vaultwarden
```

Advanced alternatives must be explicit profiles, not hidden branches in the normal path.

## 1.3 Fail closed where security state matters

Failure or ambiguity in the following should block the relevant mutation:

- unsupported host/architecture;
- version resolution;
- secret decryption;
- storage identity;
- firewall reconciliation before public listener activation;
- backup verification;
- restore archive verification;
- destructive uninstall/data removal.

Operational diagnostics, however, should distinguish `healthy`, `degraded`, `unknown`, and `failed` rather than mapping every partial condition to a hard stop.

---

# 2. Recommended service topology

## Required production services

### Vaultwarden

- official upstream Vaultwarden container;
- pinned release in production;
- no public host port;
- non-root UID/GID;
- `cap_drop: ALL`;
- `no-new-privileges`;
- read-only root where upstream behavior permits;
- persistent `/data` only;
- transient `/tmp` and `/run` via tmpfs;
- health check on internal `/alive`;
- internal application network plus explicitly required egress.

### Caddy

- pinned Caddy + Cloudflare DNS module build;
- only public application listener;
- port `443` in default Cloudflare DNS-01 mode;
- port `80` enabled only by an explicit HTTP-01/direct profile;
- non-root UID/GID with `NET_BIND_SERVICE` only if required;
- read-only root plus persistent Caddy state and logs;
- Cloudflare DNS API token via runtime secret file;
- local-only health endpoint.

## Host services

### CrowdSec

Run CrowdSec as an Ubuntu host service unless a compelling operational reason favors a container. Host installation makes SSH/system signals natural and avoids giving a monitoring container broad host mounts.

V2 should ship only the project-specific acquisitions/profiles required to parse:

- SSH;
- Caddy access/security logs;
- Vaultwarden events/logs that are meaningful for detection.

### CrowdSec Cloudflare enforcement

Keep the edge enforcement model because the real web client is behind Cloudflare.

Provision/configure the Cloudflare Workers/KV bouncer through a single V2 edge module. The normal admin should see only:

```text
vwctl crowdsec status
vwctl crowdsec test
vwctl edge status
```

The implementation details should not become normal operator workflow.

---

# 3. Email architecture

## Preferred V2 design

Remove Postfix from the mandatory stack.

Use:

- Vaultwarden's direct authenticated SMTP configuration for application mail;
- the same relay credentials through a small operational notification sender for maintenance/backup failure mail.

This eliminates:

- a privileged sidecar;
- queue management code;
- queue deletion semantics;
- Postfix-specific health checks;
- Postfix-specific tmpfs/state behavior;
- extra capabilities;
- sender-domain and queue documentation;
- a significant portion of tests.

## Optional fallback

If real deployments demonstrate that local queueing is required, provide an optional `mail-relay` profile. Do not make it part of first-run setup until that evidence exists.

---

# 4. Network model

## 4.1 Compose networks

Use the smallest topology that preserves useful isolation:

```text
frontend network:
  Caddy <-> Vaultwarden
  internal where feasible

vaultwarden-egress network:
  Vaultwarden -> Internet where required

caddy-external network:
  Caddy -> DNS/ACME/Cloudflare + published 443
```

Do not create a network merely because V1 had one. If Postfix is removed, its dedicated relay network disappears.

## 4.2 Address allocation

Do not hard-code multiple narrow RFC1918 subnets unless firewall implementation truly requires deterministic bridge addresses.

If deterministic addressing is required, expose one advanced `DOCKER_NETWORK_POOL` setting and derive project networks from it. Validate overlap before creation.

## 4.3 Ingress

Default Cloudflare mode:

- publish TCP 443 only;
- origin 443 allowed from current Cloudflare IPv4/IPv6 ranges;
- provider firewall mirrors the same intention where practical;
- SSH remains restricted by operator/provider network policy;
- Caddy obtains certificates with DNS-01.

Direct mode:

- explicitly selected;
- separate firewall behavior;
- optionally port 80 for HTTP-01;
- docs must state that Cloudflare-origin hiding/WAF benefits no longer apply.

---

# 5. Firewall strategy

V1's custom Docker packet-path handling is security-conscious but expensive to maintain.

## V2 contract

Support one firewall backend combination for Ubuntu 24.04 and document it as part of the host contract.

The implementation should have three small responsibilities:

1. verify the supported Docker firewall backend is active;
2. maintain the minimum project ingress allow-list for Caddy;
3. fail closed by keeping/stopping the public Caddy listener when policy cannot be established.

Avoid implementing a generic iptables/nftables/UFW abstraction layer.

Cloudflare CIDRs should be:

- fetched over HTTPS;
- syntax validated;
- atomically cached;
- timestamped;
- refreshed periodically;
- never replaced by an empty/invalid set;
- permitted to use a recent last-known-good cache within a documented maximum age;
- treated as failed/degraded beyond that age.

`vwctl doctor` should display the current CIDR source age and firewall state.

---

# 6. Configuration model

## `/etc/vaultwarden-oci/config.env`

Only non-secret operator configuration belongs here.

Example categories:

```text
DOMAIN=
ADMIN_EMAIL=
TZ=UTC
MODE=cloudflare
STATE_DIR=/var/lib/vaultwarden-oci
PUID=1001
PGID=1001
ADMIN_ALLOW_CIDR=127.0.0.1/32
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
PUSH_ENABLED=false
SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_FROM=
CROWDSEC_ENABLED=true
BACKUP_REMOTE=
```

Secrets such as tokens/passwords never belong in this file.

## Validation

`vwctl config validate` should:

- parse without shell `source` execution;
- reject duplicate keys;
- reject unknown production keys unless explicitly permitted for forward compatibility;
- validate booleans/enums/CIDRs/ports/domain/email/path values;
- report missing conditional fields based on enabled profile.

A Python parser should be used rather than sourcing arbitrary operator text as shell code.

---

# 7. Secret model

## Persistent

```text
/etc/vaultwarden-oci/secrets.yaml
/etc/vaultwarden-oci/age-key.txt
```

Both root-owned; Age private key mode `0600` or stricter equivalent.

## Runtime

```text
/run/vaultwarden-oci/secrets/
```

- directory root-owned `0700`;
- files readable only by the intended runtime access path;
- recreated on stack start;
- deleted on stop where appropriate;
- never included in backup payloads.

## Suggested V2 secret set

Keep the set small and profile-driven:

Core:

- Vaultwarden admin token/hash as required;
- Cloudflare DNS token;
- SMTP password.

Cloudflare/CrowdSec profile:

- Cloudflare zone ID/account ID where needed;
- Workers/bouncer credentials.

Optional push profile:

- push installation ID/key.

Avoid maintaining a broad generic transform engine for values that are not used by the normal V2 profiles.

---

# 8. Version architecture

## `versions.yaml`

Example:

```yaml
schema: 1
components:
  vaultwarden:
    version: "1.x.y"
    source: ghcr.io/dani-garcia/vaultwarden
  caddy:
    version: "2.x.y"
  sops:
    version: "3.x.y"
  yq:
    version: "4.x.y"
  crowdsec:
    version: "..."
```

Checksums for downloadable architecture-specific assets should live beside the version entries.

## Production policy

`vwctl install` and `vwctl update` consume exact pins.

No literal floating `latest` tag is stored as the production release lock.

## `--use-latest`

`vwctl install --use-latest`:

1. prints a development/test warning;
2. resolves latest compatible versions from authoritative upstream release sources;
3. validates architecture availability;
4. records the exact resolved versions/checksums in a local resolution report;
5. uses those exact values for that invocation;
6. marks the install as `development-version-policy=latest-resolved` in status output.

This preserves the requested test behavior without sacrificing post-test reproducibility.

---

# 9. `vwctl` design

One public administrative CLI should own the production workflow.

## Core commands

```text
vwctl install [--use-latest]
vwctl start
vwctl stop
vwctl restart
vwctl status
vwctl health [--full]
vwctl doctor
vwctl logs [SERVICE]

vwctl config show
vwctl config edit
vwctl config validate

vwctl secrets edit
vwctl secrets rotate KEY
vwctl secrets check

vwctl backup
vwctl backup status
vwctl restore [ARCHIVE]

vwctl crowdsec status
vwctl crowdsec test
vwctl edge status

vwctl versions
vwctl update --check
vwctl update

vwctl uninstall
```

Do not expose internal helpers as stable CLI merely because they are executable files.

## Exit code contract

Keep it small:

- `0` success/healthy;
- `1` command failure/unhealthy;
- `2` invalid usage/configuration;
- `75` optional temporary contention if retained for scheduled jobs.

Do not make junior admins memorize a broad taxonomy.

---

# 10. Installed release lifecycle

## Installation

`install.sh` should be a short bootstrapper that:

1. validates Ubuntu 24.04 and architecture;
2. installs a minimal apt dependency set;
3. installs the V2 application release under `/opt/vaultwarden-oci/<version>/`;
4. points `/opt/vaultwarden-oci/current` at it atomically;
5. installs `/usr/local/sbin/vwctl` as a stable entrypoint/symlink;
6. creates `/etc/vaultwarden-oci` and state directories;
7. creates initial config/secrets;
8. renders/installs systemd units;
9. validates configuration before first start.

The Git checkout is not the production runtime.

## Update

`vwctl update` should:

1. obtain/verify the target source release;
2. install to a new immutable release directory;
3. validate/render against current configuration;
4. take a verified backup;
5. switch `current` atomically;
6. restart;
7. run health checks;
8. retain the previous application release briefly for code rollback.

V2 does not need V1 data migration code, but future V2 schema migrations should be explicit, versioned, and narrowly scoped.

---

# 11. systemd model

Recommended units:

```text
vaultwarden-oci.service
vaultwarden-oci-health.service
vaultwarden-oci-health.timer
vaultwarden-oci-backup.service
vaultwarden-oci-backup.timer
vaultwarden-oci-maintenance.service
vaultwarden-oci-maintenance.timer
vaultwarden-oci-edge-refresh.service   # only if necessary
vaultwarden-oci-edge-refresh.timer     # only if necessary
```

The main service should own the startup firewall gate and Compose lifecycle.

Scheduled units invoke `/usr/local/sbin/vwctl` and consume the same `/etc/vaultwarden-oci/config.env` authority as interactive administration.

No copy/sync step from repository scripts to an installed systemd tree should exist.

---

# 12. Backup/recovery architecture

## Automatic backup

A normal backup should contain everything needed to reconstruct application state **except** the private recovery identity that decrypts it.

Suggested contents:

- verified SQLite snapshot;
- Vaultwarden attachments/sends and application state;
- encrypted `secrets.yaml`;
- non-secret `config.env`;
- Caddy persistent state only if necessary for useful recovery;
- manifest containing V2 schema, application version, component versions, timestamps, hashes, and state layout.

Encrypt the archive to the operational recipient and preferably a separate offline recovery recipient.

## Offline recovery kit

Contains or documents the private material required to decrypt/rebuild:

- Age recovery identity;
- essential account/domain/provider identifiers as appropriate;
- human-readable recovery instructions.

It is exported explicitly and must be stored separately/offline.

## Restore

`vwctl restore` sequence:

1. identify archive and decryption identity;
2. verify archive metadata/hashes;
3. verify compatible V2 backup schema;
4. verify target disk capacity;
5. stop application services;
6. stage restored state;
7. apply ownership/modes;
8. atomically promote state where practical;
9. optionally start;
10. verify `/alive` and core health;
11. report exact recovery status.

No V1 archive formats need support.

---

# 13. Storage model

Default state root:

```text
/var/lib/vaultwarden-oci
```

Optional data volume:

- configured by a stable `/dev/disk/by-*` identifier;
- mounted by normal systemd/fstab semantics;
- one project sentinel identifies initialized state;
- installer never formats a non-empty/recognized filesystem without explicit destructive authorization;
- service has `RequiresMountsFor=` or equivalent protection so missing attached storage cannot cause writes to a boot-volume shadow directory.

Cloud-provider device names must never be hard-coded.

---

# 14. Observability and `doctor`

`vwctl doctor` is the primary diagnostic interface.

It should produce a concise human summary and optional machine-readable JSON.

Checks:

- host release and architecture;
- effective V2 version and version policy;
- config validity;
- encrypted secret file presence and decryptability;
- Age key permissions;
- state filesystem/mount identity;
- free disk space;
- Docker/Compose versions and daemon health;
- Compose config validity;
- container health;
- public listener exposure;
- Cloudflare CIDR cache freshness;
- firewall rule presence;
- DNS/domain reachability where network access is available;
- CrowdSec daemon/bouncer health;
- systemd service/timer state;
- last backup time and verification status;
- last maintenance state.

Output should tell the operator what to do next, e.g.:

```text
DEGRADED: Cloudflare CIDR cache is 30h old.
Fix: sudo vwctl edge refresh
```

---

# 15. Development and CI architecture

## Static checks

- ShellCheck for bootstrap shell;
- Ruff or equivalent for Python formatting/linting;
- pytest for structured application logic;
- YAML validation;
- Compose render/config validation.

## Security contract tests

Assert generated Compose has:

- no Vaultwarden public port;
- only expected Caddy public ports for selected mode;
- `no-new-privileges`;
- expected capability drops/additions;
- expected read-only settings;
- no secret values embedded into environment output;
- expected network membership.

## Architecture tests

For amd64 and arm64:

- resolve/check every downloadable binary asset;
- verify container image manifests contain target architecture;
- test checksum mapping;
- periodically perform a native or appropriate integration deployment on both architectures.

## Release tests

A V2 release should require:

1. unit/static suite;
2. fresh Ubuntu 24.04 install test;
3. start/health test;
4. synthetic data backup;
5. destructive restore into a fresh state root;
6. post-restore health verification;
7. uninstall non-data-destructive test.

---

# 16. OCI A1 Flex reference profile

OCI A1 Flex remains a useful documented reference because it is a low-cost ARM64 target, but V2 core code should not contain OCI APIs, device assumptions, metadata dependencies, or network-resource provisioning.

Provide a documentation appendix/example covering:

- Ubuntu 24.04 ARM64 image;
- sensible A1 Flex OCPU/RAM sizing for a small team;
- boot-volume sizing;
- optional block volume using stable `/dev/disk/by-*` identity;
- OCI NSG/security-list ingress for SSH/443;
- Cloudflare proxy setup.

Equivalent cloud-provider docs can be added later without changing the runtime.

---

# 17. Explicit non-goals for V2

V2 should not become:

- Kubernetes deployment tooling;
- multi-node/HA Vaultwarden;
- a generic Linux distribution installer;
- a generic firewall framework;
- a generic secrets manager;
- a generic backup product;
- a cloud infrastructure provisioner;
- a universal reverse-proxy framework;
- a compatibility layer for V1 state/data formats;
- an enterprise SIEM/monitoring platform.

---

# 18. Definition of architectural success

V2 architecture is successful when a junior administrator can answer these questions from one page of documentation:

- Where is configuration?
- Where are encrypted secrets?
- Where is the Age key?
- Where is Vaultwarden data?
- Where are backups?
- What service is public?
- How do I check health?
- How do I see logs?
- How do I update?
- How do I restore?
- What versions am I running?

The target is not the fewest lines of code. The target is the fewest **independent concepts** required to operate the system safely.