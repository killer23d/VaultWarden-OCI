# Security Model — VaultWarden-OCI

VaultWarden-OCI is a security-first appliance for a small production team. The design deliberately favors a narrow supported boundary, root-operated administration, explicit key custody, fail-closed storage/recovery behavior, truthful readiness, and a small number of understandable controls.

This is not an enterprise security platform, SIEM, multi-node HA system, or generic cloud/edge framework.

Related docs: [PROJECT-BOUNDARY.md](PROJECT-BOUNDARY.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [CROWDSEC.md](CROWDSEC.md) · [BACKUP-RESTORE.md](BACKUP-RESTORE.md) · [BOOTSTRAP_KEY_RECOVERY.md](BOOTSTRAP_KEY_RECOVERY.md)

## Security priorities

The repository's security priorities are:

1. protect production secrets and private recovery identities;
2. keep database and disaster-recovery paths verifiable;
3. fail closed before destructive storage/recovery mutation when ownership or layout is ambiguous;
4. serialize conflicting production mutations;
5. keep operator success/readiness claims truthful;
6. preserve a simple production path that a junior administrator can understand.

A control that reports green while the check did not run is not a security control.

---

## Supported boundary

The supported normal production host is:

```text
Ubuntu 24.04 LTS Noble
amd64 or arm64
systemd
Docker Engine + Docker Compose plugin
```

The normal edge path is Cloudflare-first:

```text
Cloudflare DNS/proxy/WAF
        ->
provider firewall / security group / network firewall
        ->
Ubuntu UFW / iptables path
        ->
Caddy
        ->
Vaultwarden
```

Host runtime is cloud-provider neutral. OCI, AWS, Azure, Google Cloud, another VM provider, private virtualization, or physical hardware may be used when the supported host and networking prerequisites are met.

The setup system fails closed on an unsupported/unresolved Ubuntu release or CPU architecture. Unknown hosts are not silently treated as Noble/amd64.

---

## Cloudflare-first origin protection

The supported UFW setup fetches Cloudflare's IPv4/IPv6 CIDR lists and restricts origin ports `80`/`443` to validated Cloudflare ranges.

The firewall path:

- detects the host SSH port and allows SSH;
- fetches current Cloudflare CIDRs;
- persists a last-known-good CIDR cache;
- refuses to configure `80`/`443` with no valid Cloudflare CIDR data;
- refuses an expired cached CIDR set when fresh data cannot be fetched;
- applies Cloudflare-source rules for the web ports;
- enables UFW when needed.

The provider firewall/security group remains outside the host. Configure it separately.

Do not copy old guidance that opens origin `80`/`443` to all clients as the normal security path.

### Docker/iptables boundary

Docker modifies iptables chains. `setup-firewall.sh` applies the host firewall after Docker installation and maintains project NAT/`DOCKER-USER` behavior.

`vaultwarden-iptables.service` re-applies the supported iptables phase after Docker-related chain resets.

The setup path detects an active nftables ruleset and refuses the mixed iptables/nftables state unless the operator explicitly acknowledges the risk with `--force-iptables`.

Do not force the override merely to make setup continue. Verify which firewall framework owns the host first.

---

## Caddy security boundary

Caddy is the supported reverse proxy/TLS endpoint.

Current production behavior includes:

- Cloudflare-first DNS-01 certificate management;
- restricted `/admin` exposure using the configured admin CIDR and Caddy basic-auth secret;
- structured access/security logs under the project state directory;
- a local health endpoint on the configured loopback path;
- container hardening with dropped capabilities except the required bind-service capability;
- read-only container root filesystem with explicit writable mounts/tmpfs.

Caddy runs as UID/GID `2000:2000`. Runtime permission repair normalizes Caddy data, config, and log bind mounts to this identity.

Do not expose `/admin` merely by setting a weak global WAF rule. The application admin token and the Caddy access boundary are separate controls.

---

## CrowdSec enforcement architecture

The current design is not the old Fail2Ban/Cloudflare-WAF-API model.

CrowdSec runs on the host and consumes configured Vaultwarden/Caddy/SSH signals.

Two bouncer paths are used:

1. **Firewall bouncer** — enforces CrowdSec decisions at the host firewall layer.
2. **Cloudflare Workers bouncer** — synchronizes the configured locally generated CrowdSec decisions to Cloudflare Workers KV; the deployed Worker uses KV state for edge enforcement.

The Workers path is not documented as a WAF Custom Rules ruleset updater.

The local firewall bouncer may also see decisions that are not useful for blocking the real proxied web client at the origin, because Cloudflare is the network peer. The Workers/KV edge path is the control that blocks the real attacker before origin for the configured web decision flow.

See [CROWDSEC.md](CROWDSEC.md) for the exact setup and credential model.

---

## Root-operated production lifecycle

Production lifecycle and privileged maintenance are root-operated:

```bash
sudo make up
sudo make down
sudo make restart
sudo make health
sudo make backup
sudo make restore
```

This matches the ownership of:

```text
/etc/vaultwarden/
${PROJECT_STATE_DIR}/config/
${PROJECT_STATE_DIR}/secrets/
/run/vaultwarden-oci/secrets/
/opt/vaultwarden-scripts/
/etc/systemd/system/
```

Do not redesign the production model around membership in the Docker group merely because Docker supports that operating pattern.

Metadata/help paths may be root-free where intentionally implemented. A root-free `--help` path does not imply a root-free production mutation path.

---

## Persistent secret model

The canonical encrypted secret file is:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

Secret key definitions, transforms, collection rules, required/conditional status, and apply behavior are owned by:

```text
secrets-schema.yaml
```

Use:

```bash
sudo ./edit-secrets.sh edit
sudo ./edit-secrets.sh rotate <secret-key>
```

Do not place production passwords/tokens in repository `.env`.

The repository must not:

- commit plaintext secrets;
- print production secret values into ordinary logs;
- expose private Age keys in process arguments where avoidable;
- persist the offline recovery private key on the server;
- weaken root-owned key permissions for a convenience command.

---

## Runtime secret lifetime

Decoded Docker secret source files are generated under:

```text
/run/vaultwarden-oci/secrets/
```

Expected contract:

```text
runtime secret directory: root:root 0700
decoded secret files:     root:root 0444
```

`/run` is volatile. Startup rematerializes these files from the SOPS ciphertext.

Persistent project backups must not archive the decrypted `/run/vaultwarden-oci/secrets` tree.

Do not "fix" runtime secret access by copying decoded values into `.env` or a persistent world-readable directory.

---

## Age key custody

The live operational Age private key is installed at:

```text
/etc/vaultwarden/age-key.txt
```

It is root-owned private state.

Production commands use the exact `SOPS_AGE_KEY_FILE` selected by the canonical runtime environment. A missing, unreadable, or unhealthy configured key is a blocking error; startup and health checks do not silently substitute a repository-local private key. Repository key use is limited to an explicit bootstrap/development selection (`VW_CONFIG_AGE_KEY_MODE=repository` while repository `.env` is the selected source).

Check it with:

```bash
sudo make key-health
sudo make key-show
```

The SOPS policy may include a separate offline recovery Age public recipient. The matching private key stays offline.

Do not confuse:

- operational Age private key;
- operational Age public recipient;
- offline recovery Age private key;
- offline recovery public recipient;
- emergency backup passphrase;
- `EMERGENCY_BACKUP_AGE_RECIPIENT`.

The offline private key is used in place by `recover.sh`; recovery generates a replacement operational key for the new server.

---

## Key rotation

Rotate the operational key through:

```bash
sudo make key-rotate
```

The key-rotation path must verify the resulting ciphertext remains decryptable with the current key policy before success.

After rotation:

```bash
sudo make key-health
sudo ./utilities/secrets-export-recovery-kit.sh
```

Retain historical private identities required by retained backup generations. Operational key rotation does not retroactively re-encrypt every historical backup.

---

## Backup security model

The three backup tiers are security-relevant:

| Tier | Security meaning |
| :-- | :-- |
| `db` | encrypted verified SQLite rollback point |
| `full` | normal DR archive; does not include the live operational Age private key |
| `emergency` | clone-grade secrets-bearing capsule that can include staged operational key/config material and therefore requires independent sealing |

Emergency protection must be independent from the operational key the capsule may contain.

Supported independent protection is:

- `age -p` passphrase mode; or
- `EMERGENCY_BACKUP_AGE_RECIPIENT` with a separate private identity.

Do not put emergency passphrases in shell history, environment variables, logs, or archive metadata.

### Backup verification truthfulness

A backup that fails required verification is not a valid new recovery point.

The current backup failure contract prevents a newly failed archive from:

- remaining as a normal restore candidate;
- triggering local retention that could delete older recovery points;
- running remote pruning;
- sending normal completion success notifications;
- reporting verified backup success.

Retention preserves the newest parseable timestamped archive even when older than the configured retention window.

See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

---

## Restore and recovery security boundaries

Restore/recovery are high-risk mutations.

The important contracts are:

- validate storage before destructive work;
- identify the exact archive and required decryption identity/protection;
- verify backup integrity/metadata according to the archive contract;
- take the configured pre-restore safety snapshot unless deliberately skipped;
- stop services before broad state replacement;
- stage/promote through the owning restore/recovery transaction;
- repair target-host runtime ownership/modes;
- use an explicit service start policy;
- require `/alive`/health success where startup is part of the operation;
- return non-zero when the state claimed by the command did not pass.

Timeout/EOF at guarded confirmation and `SAVED` acknowledgement points is fail-safe. Lost SSH input must not be converted into a silent yes/no success.

### `recover.sh` transaction

State-volume recovery stages and validates:

- ciphertext;
- replacement operational Age key;
- SOPS policy;
- persistent `install.env`;
- DR manifest;
- recovery-created sentinel state when required.

Before the commit boundary, failure/signal restores the prior recovery identity/config state.

After the commit boundary, startup or `/alive` failure remains non-zero but preserves the newly committed artifacts for diagnosis. The workflow does not silently roll cryptographic state back while leaving new environment references behind.

---

## Storage safety

The project supports:

- boot-volume state;
- an explicitly configured attached block/data volume.

Attached-volume mode requires:

- explicit device/mount configuration;
- matching `PROJECT_STATE_DIR` and `DATA_VOLUME_MOUNT`;
- the expected mount to be active;
- the `.vw-data-volume` project sentinel.

Storage code must fail closed before format/fstab/mount/destructive cleanup when ownership is ambiguous.

Blank-device formatting is an explicit authorization. In storage migration, `--force-format` owns that consent. `--force` does not silently mean "format the disk."

Prefer stable device identities such as `/dev/disk/by-id/...` or `/dev/disk/by-uuid/...`.

Do not assume `/dev/sdb`, `/dev/vdb`, or provider-specific device aliases are universal.

---

## Runtime permission contract

The shared runtime repair helper applies explicit known-path contracts.

Root-operated private paths include:

```text
/etc/vaultwarden/
${PROJECT_STATE_DIR}/config/
${PROJECT_STATE_DIR}/secrets/
/run/vaultwarden-oci/secrets/
```

Vaultwarden application data/logs use the configured `PUID:PGID`.

Caddy data/config/log bind mounts use UID/GID `2000:2000` with the defined runtime modes.

Check/repair:

```bash
sudo utilities/repair-permissions.sh --check
sudo utilities/repair-permissions.sh
```

Do not use broad permission commands such as:

```bash
sudo chmod -R 777 "$PROJECT_STATE_DIR"
sudo chown -R 2000:2000 "$PROJECT_STATE_DIR"
```

Those commands can expose encrypted/private state or break application ownership.

---

## Shared operation guard

Conflicting mutations use `lib/operations.sh` and `flock`.

Inspect status:

```bash
sudo make operations
```

Kernel lock state is authoritative; metadata is operator-facing context.

The guard preserves:

- global serialization where required;
- operation-specific locks where justified;
- verified owner PID/start identity;
- a verified owner-bound holder that keeps lock descriptors out of workload descendants and exits when the owner control channel closes;
- conservative stale metadata handling;
- controlled TERM-before-KILL behavior for eligible owners;
- refusal to automatically terminate package-manager work;
- exit `75` for expected non-interactive contention where the owning service contract uses it.

Do not delete lock files to bypass concurrency protection.

Do not add a second lock framework, daemon, database, or Redis dependency for this project.

---

## systemd hardening and installed runtime

Managed units are installed under `/etc/systemd/system` and use root-owned runtime copies under `/opt/vaultwarden-scripts`.

Managed services use systemd sandboxing directives appropriate to their required behavior, including combinations of:

- `PrivateTmp`;
- `ProtectSystem`;
- `ProtectHome`;
- `NoNewPrivileges` where compatible with the owning service.

The exact writable paths and command grammar must match the current script/runtime contracts.

After repository updates that change managed scripts/libraries/units:

```bash
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

The installer reconciles a closed inventory of VaultWarden-OCI scripts, libraries, units, and generated drop-ins. Removed managed units are stopped and disabled before their files are removed; operator and third-party drop-ins are preserved. `systemd validate` detects repository/installed split-brain and unexpected managed leftovers instead of returning success with stale active runtime.

Runtime coordination files are prepared in place as regular, non-symlink files with the verified `root:vaultwarden 0660` contract. Preparation failure blocks installation; an existing valid lock inode is never replaced merely to normalize metadata.

Expected operation contention must not trigger false failure incidents. Real service failure must not be mapped to clean contention.

---

## Container hardening

The production Compose model uses explicit service hardening rather than a generic orchestration platform.

Current patterns include:

- pinned image/build versions;
- explicit service users where required;
- capability drops and minimal capability additions;
- `no-new-privileges`;
- read-only root filesystems for core containers where implemented;
- tmpfs for temporary writable paths;
- bounded Docker json-file logs;
- explicit memory/swap limits on the core services;
- internal/private application networking plus explicit egress networks for components that require outbound access.

Vaultwarden is attached to the dedicated `vaultwarden_egress` network for outbound requirements such as push integration. Do not follow old instructions that tell operators to remove the main application network's isolation as the default push fix.

Caddy uses a pinned xcaddy build. Do not set `CADDY_VERSION=latest` for production.

---

## Email security boundary

The normal mail architecture is Postfix-first:

```text
Vaultwarden
    -> internal Postfix sidecar
    -> authenticated/TLS upstream relay
```

Operational scripts may use the configured provider HTTP API path in `EMAIL_MODE=auto`/`api`, but SMTP/Postfix remains required for Vaultwarden mail and attachment-based recovery-kit delivery.

Secrets such as `smtp_password` and `email_api_token` are stored in SOPS, not `.env`.

`ALLOWED_SENDER_DOMAINS` limits the sidecar's sender-domain behavior. The Postfix container is a private relay to the configured upstream provider, not a public mail server.

See [EMAIL.md](EMAIL.md).

---

## Production readiness security gate

Repository CI is necessary but does not prove the state of an installed production host.

For an existing healthy host after managed repository changes:

```bash
git pull --ff-only
sudo ./setup.sh systemd install --enable-now
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

The smoke test must not return production-ready success when a required check was skipped.

After major deployment/recovery changes also verify:

```bash
sudo make health
sudo ./maintenance.sh test-email --verbose
sudo ./backup.sh run full --full-verification
sudo ./backup.sh verify
```

Production readiness is a property of the actual host, installed automation, recovery points, and operator access—not merely a green GitHub Actions run.

---

## Security anti-patterns

Do not:

- commit plaintext secrets, `.env` credentials, Age private keys, recovery kits, or backup archives;
- persist the offline recovery private key on the server;
- open origin `80`/`443` to the world as the normal Cloudflare-first configuration;
- disable the operation guard because a long-running task is inconvenient;
- kill `apt`/`dpkg` automatically to resolve a project lock conflict;
- use `chmod -R 777` on project state;
- broad-chown the whole state tree to Vaultwarden or Caddy;
- copy decoded `/run` secrets into persistent config;
- treat an emergency backup like an ordinary encrypted DB archive;
- destroy old Age identities before retained backups using them are retired;
- hand-edit `/etc/vaultwarden/vaultwarden.env` to hide environment drift;
- assume `git pull` updates the installed `/opt` systemd runtime;
- describe a skipped readiness probe as healthy;
- run destructive restore/recovery rehearsal on the only production state volume;
- introduce Kubernetes, distributed locks, a new secrets manager, an operation database, or another enterprise subsystem without a demonstrated production defect that requires it.

---

## Security review checklist

When reviewing a change, ask:

1. Does this expose plaintext secret/private-key material in logs, process arguments, Git, or persistent world-readable paths?
2. Does the change alter root/non-root privilege boundaries for a supported entry point?
3. Does it introduce a new mutating caller that bypasses `lib/operations.sh`?
4. Can a timeout, EOF, signal, or `set -e` interaction turn a failure into success or continue after cleanup?
5. Does backup/restore still report only verified state as successful?
6. Does storage fail closed when device/mount/sentinel ownership is ambiguous?
7. Do systemd installed scripts/units/environment remain synchronized with the repository contract?
8. Does a health/readiness check become green when the probe did not actually run?
9. Does the change work on both Noble amd64 and Noble arm64 for architecture-sensitive dependencies?
10. Can the defect be fixed locally without adding a framework, registry, database, daemon, or second source of truth?

Prefer the smallest coherent fix that preserves a truthful production contract.

## Protected credential output

<!-- VWOCI-PRR-PATCH-04 -->

Setup, Age-key rotation, restore, and recovery export do not print private identities or generated plaintext credentials. New setup credentials and key handoffs are root-only files under `/root/vaultwarden-recovery/`; operators must move them offline and explicitly remove the host copy. The setup handoff is not emailed. See [Secure credential and recovery handoffs](SECURE-CREDENTIAL-HANDOFFS.md).
