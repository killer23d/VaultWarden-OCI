# Operations

`vwctl` is the implementation and mutation authority. `dashboard.sh` is also a supported day-2 human interface; it presents/guides operations and delegates mutations to `vwctl` rather than owning separate state-changing logic.

The useful color-coded/AMTM-style interaction conventions of the earlier product are the dashboard design reference. The earlier backend architecture is not.

## Routine lifecycle

Authoritative CLI forms remain available for direct operation and automation:

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor
sudo vwctl doctor --json
sudo vwctl logs --tail 200
sudo vwctl logs vaultwarden --tail 500
sudo vwctl restart
sudo vwctl stop
```

`status` reports service and relevant operational state. `doctor --json` is the machine-readable diagnostic truth; scripts should key on stable check IDs/status rather than prose messages. A doctor `FAIL` blocks acceptance. `WARN` is intentionally visible.

For normal human day-2 work, `dashboard.sh` may expose the same supported lifecycle, health, recovery, update, and security workflows interactively. It must not bypass `vwctl` for mutations.

## Logs

Runtime container logs are available through `vwctl logs`. Systemd automation logs remain in the journal. Use the installed unit names from the active release, for example:

```bash
journalctl -u vaultwarden-oci.service
journalctl -u vaultwarden-oci-health.service
journalctl -u vaultwarden-oci-backup.service
journalctl -u vaultwarden-oci-maintenance.service
journalctl -u 'vaultwarden-oci-notify@*'
```

## Dedicated-storage health

Production persistent application/recovery state must be on the configured dedicated filesystem/volume, not the boot/root filesystem.

Day-2 health/doctor checks must make a missing or wrong production storage mount observable and prevent service startup from silently writing persistent state to root. Treat any storage-invariant failure as a stop condition, not a warning to ignore.

## Systemd automation

systemd remains the lifecycle/scheduling authority. Enable the supported target/timers only after setup, configuration, secrets, storage, and first-start health have passed:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

The installed services invoke the authoritative appliance CLI. There is no Postfix/local MTA, durable notification queue, or application scheduler to operate.

## Cloudflare edge, Caddy, and CrowdSec

Real-client-IP trust and host-level origin filtering are separate controls.

Caddy's exact-pinned Cloudflare trusted-proxy/real-client-IP module owns client-IP trust, with combined Cloudflare ranges. Do not maintain a generated static Cloudflare `trusted_proxies` CIDR block in Caddy as a second authority.

The host separately maintains one fail-closed Docker `DOCKER-USER` origin-filter path permitting published HTTPS only from validated Cloudflare source ranges. A current range policy is preferred; only bounded validated last-known-good state may be used as fallback. If no safe policy exists, origin ingress remains blocked.

CrowdSec web-client remediation is Cloudflare-side. A CrowdSec host firewall bouncer is not required.

Where the current CLI exposes the existing edge/remediation operations, the authoritative forms remain:

```bash
sudo vwctl edge refresh
sudo vwctl crowdsec status
```

## `/admin` defense in depth

The supported `/admin` posture is intentionally lightweight:

- Vaultwarden admin token;
- Caddy-side rate limiting;
- one simple outer authentication gate.

Do not replace this with an enterprise identity stack or accumulate multiple redundant outer gates.

## Notifications

Operational notifications use the closed immutable `email-providers.toml` catalog. Vaultwarden application email remains direct authenticated SMTP.

Provider API delivery uses bounded retries only for failures classified transient by network semantics or current provider documentation. Authenticated SMTP fallback follows only an eligible transient API outcome. It does not mask authentication, TLS validation, permanent provider, or ambiguous delivery failures.

For CyberPersons, current verified behavior is:

- `503 service_unavailable` is status-only transient/retry/fallback eligible;
- `429 rate_limit_exceeded` remains visible because current provider behavior includes account-wide minute/hour/day/month limits shared across API and SMTP credentials;
- `500 send_failed` remains visible and is not fallback eligible by status alone.

Do not restore older documentation that categorizes arbitrary CyberPersons 429 responses as transient.

## Recovery and rclone

Create a verified local `.vwrec` application recovery point with the authoritative CLI:

```bash
sudo vwctl backup
```

Where configured, offsite publication uses non-destructive rclone copy/copyto semantics and must be remotely verified before success is reported. Pruning remains a separate explicit action.

The human recovery experience also includes a guided local/remote restore picker. Explicit noninteractive CLI restore forms remain supported for automation. See [RECOVERY.md](RECOVERY.md).

The AES-256 recovery-kit ZIP is a separate credential-handoff artifact; it is not interchangeable with `.vwrec` application recovery.

## Application versions and updates

Normal application updates are safe, explicit, and operator-driven:

```text
discover stable project release
-> resolve/stage/download/build before downtime
-> verify pre-update recovery point
-> activate immutable exact release
-> health-gate
-> roll back coherently when safe
```

Automated update checking/notification is desirable. Unattended update **apply** is not the default.

The current implementation already exposes explicit source-pinned update commands:

```bash
cd /path/to/trusted/new-release
sudo vwctl update check --source "$PWD"
sudo vwctl update apply --source "$PWD"
```

That existing implementation stages exact images/builds, verifies a pre-update recovery point, activates an immutable release, and health-gates it. If candidate runtime activation may have changed persistent state, it deliberately refuses a blind binary rollback; the verified pre-update recovery point is the safe downgrade boundary.

The approved product workflow additionally requires stable project-release discovery/check notification. That remains implementation work rather than a reason to broaden the update authority.

`--use-latest` belongs to the explicit setup/install path, not unattended update apply. When an operator selects it during setup, resolution freezes exact immutable values once and leaves no floating `latest` state.

## Ubuntu package updates

Ubuntu host package updates are a separate workflow from application updates. Do not claim that `.vwrec` recovery can roll back apt/kernel changes. The appliance must never auto-reboot; any reboot remains an explicit administrator action after host maintenance.

## Configuration changes

After editing non-secret config or the SOPS document:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
sudo vwctl restart
sudo vwctl status
```

Human wrappers may guide these steps, but all mutations must converge on the same `vwctl` authority and mutation lock.

## Current development-branch gaps

At this synchronization point, the development branch does not yet ship the approved `dashboard.sh`, dedicated-storage enforcement, Caddy trusted-proxy/rate-limit module set, or production-supported `setup.sh --use-latest` behavior. The current source-pinned update transaction is usable implementation groundwork; the missing stable-release discovery/check-notification layer is still a follow-up.

Treat these as bounded implementation gaps, not alternative product decisions.
