# VaultWarden-OCI

VaultWarden-OCI is a small, opinionated Vaultwarden appliance for a small team. It targets Ubuntu 24.04 LTS on `amd64` and `arm64`, requires a dedicated production data filesystem, and assumes Cloudflare-proxied public access.

## What the appliance contains

| Component | Purpose |
| --- | --- |
| Vaultwarden | Password-manager application and persistent vault data. |
| Custom Caddy | TLS, reverse proxying, Cloudflare real-client-IP trust, rate limiting, and the outer `/admin` authentication gate. |
| Cloudflare | Supported public edge and the only allowed public source for origin TCP/443. |
| CrowdSec | Detects abuse across Caddy, Vaultwarden, SSH/Linux, and kernel/firewall signals; locally generated proxied web decisions are remediated through Cloudflare while broad/community decisions can protect host INPUT through the nftables firewall bouncer. |
| SOPS + Age | Encrypts appliance credentials while keeping operational and offline recovery identities separate. |
| rclone | Publishes and retrieves verified `.vwrec` recovery points without destructive sync semantics. |
| systemd | Owns boot lifecycle and health, backup, maintenance, and update-check timers. |
| Notifications | Sends operational events through one built-in HTTPS provider, with authenticated SMTP fallback only for eligible transient failures. Vaultwarden application mail uses direct authenticated SMTP. |

```text
Internet
   |
   v
Cloudflare  <----- local CrowdSec web decisions / Worker remediation
   |
   v
host TCP/443 origin filter (Cloudflare sources only; fail closed)
   |
   v
custom Caddy (real client IP, TLS, rate limits, /admin outer auth)
   |
   v
internal Vaultwarden

Direct host services (for example SSH)
   ^
   |
CrowdSec nftables bouncer (host INPUT only; broad/community decisions)
```

Caddy's trusted-proxy logic, the host origin filter, CrowdSec host-input remediation, and Cloudflare Worker remediation are separate controls. The firewall bouncer never owns Docker `FORWARD` or `DOCKER-USER`; published container ingress stays under the single Cloudflare-origin filter. The dashboard is also separate from backend ownership: it is a supported human interface, but every mutation delegates to `vwctl` and the existing Python owners.

## Start here

Production installation requires a dedicated ext4/xfs filesystem separate from `/`. There is no boot-disk fallback.

```bash
sudo ./setup.sh install \
  --domain example.com \
  --url https://vault.example.com \
  --email admin@example.com
```

Interactive setup can select a suitable non-boot data device and can generate the offline recovery identity only in root-owned volatile storage long enough to hand it off in a verified encrypted recovery kit. Terminal-driven `--auto` uses the same custody flow when no `--offline-recipient` is supplied: install steps remain automatic, while the recovery-kit passphrase and final custody acknowledgement remain interactive. Fully headless `--auto` must supply its storage decisions and an existing public `--offline-recipient`. An explicitly supplied recipient is authoritative and is never replaced by a generated identity. Read [Install](docs/INSTALL.md) before changing a production host.

After setup and external credentials are complete:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets validate
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

A doctor `FAIL` is not a successful installation. CrowdSec setup/remediation is an explicit first-run security step documented in [Operations](docs/OPERATIONS.md); Cloudflare Worker routes must be set to Fail Open before their invocation is confirmed.

For normal day-2 work:

```bash
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

From a source checkout, `sudo ./dashboard.sh` is equivalent.

## Administrator manual

- [Install](docs/INSTALL.md) — blank VM, dedicated storage, `--domain`/`--url`/`--email`, interactive and `--auto`, terminal-generated versus pre-existing offline recovery custody, explicit `--use-latest`, config/secrets completion, and first start.
- [Operations](docs/OPERATIONS.md) — dashboard, lifecycle, status/doctor/logs, config/secrets, Caddy/Cloudflare/CrowdSec, notifications, timers, application updates, host upgrades, reboot-required state, troubleshooting, and file locations.
- [Recovery](docs/RECOVERY.md) — backup contents/exclusions, verification, same-host restore, lost-server disaster recovery, rclone, and the separate recovery-kit ZIP.
- [Security](docs/SECURITY.md) — trust boundaries, secret custody, origin protection, `/admin`, notification security, and unsupported designs.
- [Host acceptance](docs/HOST-ACCEPTANCE.md) — disposable Ubuntu 24.04 release gate for `amd64` and `arm64`; unavailable real-host coverage must be recorded as `NOT RUN`.

Maintainer/product authorities are [Project boundary](docs/PROJECT-BOUNDARY.md), [Durable decisions](docs/DECISIONS.md), [Development](docs/DEVELOPMENT.md), and [Test strategy](reports/TEST-STRATEGY.md). The prompt archives under `reports/` are historical execution/review records, not competing product authority.

## Product boundaries worth remembering

Production state is dedicated-storage-only. There is one operator config, one encrypted SOPS secret authority, and one exact version manifest. Normal application recovery is one encrypted `.vwrec` format; the credential recovery-kit ZIP is a separate artifact. The offline recovery private identity is never persistent server state. Application updates are explicit and recovery-gated. Ubuntu package updates are separate and the appliance never auto-reboots.

There is intentionally no Postfix/local queue, public backup-tier matrix, compatibility reader for an earlier archive format, generic plugin/storage/update framework, broad repair command, HA layer, Kubernetes/Swarm layer, or second dashboard backend.
