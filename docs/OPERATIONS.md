# Operations

`vwctl` is the implementation and mutation authority. `dashboard.sh` is also a supported day-2 human interface; it presents/guides operations and delegates mutations to `vwctl` rather than owning separate state-changing logic.

The useful color-coded/AMTM-style interaction conventions of the earlier product are the dashboard design reference. The earlier backend architecture is not.

## Day-2 dashboard

From a source checkout:

```bash
sudo ./dashboard.sh
```

On an installed appliance the dashboard is carried inside every immutable release and remains reachable through the stable current-release link:

```bash
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

The main screen summarizes Vaultwarden/Caddy health, overall doctor state, dedicated-storage usage/warnings, local and offsite recovery age/state, rclone, Cloudflare/CrowdSec edge health, systemd automation, notification state, installed/update state, `/admin` protection, and reboot-required state. `NO_COLOR=1` disables dashboard color; non-TTY and JSON output are uncolored.

The task-oriented menu is: Stack; Diagnostics; Backup & Recovery; Security; Config & Secrets; Recovery Kit; Email & Notifications; Updates & Host; Automation. Number keys and compact letter shortcuts are supported; `e`/`q` retain the V1 exit convention. Every state-changing action delegates to `vwctl`; the only direct non-`vwctl` dashboard operation is bounded read-only `journalctl` display. EOF exits cleanly rather than redrawing indefinitely.

The dashboard presentation module does not own locks or state-changing transactions. Config editing remains owned by `runtime.py`, SOPS/Age editing and validation by `secrets.py`, CrowdSec/Cloudflare mutations by `edge.py`, notification transport by `notification.py`, recovery by the Workstream 3 owners, and update/apply by the Workstream 4 owners. The day-2 aggregation module is limited to read-only appliance status, timer inspection, and sanitized support-bundle creation.

## Routine lifecycle

Authoritative CLI forms remain available for direct operation and automation:

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl status --json
sudo vwctl doctor
sudo vwctl doctor --json
sudo vwctl logs --tail 200
sudo vwctl logs vaultwarden --tail 500
sudo vwctl restart
sudo vwctl stop
```

`status --json` is the dashboard's stable read-only appliance summary and includes service health, doctor state, storage, recovery age/state, edge/CrowdSec checks, timers, notification state, update-check freshness/availability, admin protection, and reboot-required state. `doctor --json` remains the detailed machine-readable diagnostic truth; scripts should key on stable check IDs/status rather than prose messages. A doctor `FAIL` blocks acceptance. `WARN` is intentionally visible.

For normal human day-2 work, `dashboard.sh` exposes the same supported lifecycle, health, recovery, update, and security workflows interactively. It does not bypass `vwctl` for mutations.

## Logs

Runtime container logs are available through `vwctl logs`. Systemd automation logs remain in the journal. Use the installed unit names from the active release, for example:

```bash
journalctl -u vaultwarden-oci.service
journalctl -u vaultwarden-oci-health.service
journalctl -u vaultwarden-oci-backup.service
journalctl -u vaultwarden-oci-maintenance.service
journalctl -u 'vaultwarden-oci-notify@*'
```

A bounded support artifact is available through:

```bash
sudo vwctl support-bundle
```

The default bundle is built in root-only volatile `/run` storage so a missing dedicated mount cannot silently create persistent appliance state on the root filesystem. It includes structured status/doctor/timer state, versions, failed systemd state, and storage usage. Bounded recent project journal output is included only when configured secret values can be loaded for exact-value redaction; otherwise journal collection is deliberately omitted. Config/secrets files themselves are never included, and collected text is redacted for configured secret values, common credential/passphrase forms, bearer material, and Age private-key text.

An explicit `--output` destination must use an existing directory and never overwrites an existing path. Publication is exclusive/atomic at the destination, so a symlink or regular file appearing at the requested name is not truncated.

## Dedicated-storage health

Production persistent application/recovery state must be on the configured dedicated filesystem/volume, not the boot/root filesystem.

Day-2 health/doctor checks make a missing or wrong production storage mount observable and prevent service startup from silently writing persistent state to root. Treat any storage-invariant failure as a stop condition, not a warning to ignore. The dashboard also raises a disk-usage warning before the volume reaches exhaustion.

## Systemd automation

systemd remains the lifecycle/scheduling authority. Enable the supported target only after setup, configuration, secrets, storage, and first-start health have passed:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
vwctl timers
vwctl timers --json
```

`vaultwarden-oci.target` is the persistent boot authority and statically `Wants=` all four project timers. `vwctl timers` therefore requires that target to be loaded, enabled, and active and requires each supported timer to be loaded and active; an individual timer's `UnitFileState` may remain `disabled` because the enabled target owns its activation. The corresponding triggered service is checked independently: systemd results such as `exit-code`, `signal`, and `timeout`, a failed service `ActiveState`, a missing/inactive timer, or a disabled/inactive target are failures rather than green status. A waiting timer therefore cannot hide a failed automation run. The installed services invoke the authoritative appliance CLI. There is no Postfix/local MTA, durable notification queue, or application scheduler to operate.

## Cloudflare edge, Caddy, and CrowdSec

Real-client-IP trust and host-level origin filtering are separate controls.

Caddy's exact-pinned Cloudflare trusted-proxy/real-client-IP module owns client-IP trust, with combined Cloudflare ranges. Do not maintain a generated static Cloudflare `trusted_proxies` CIDR block in Caddy as a second authority.

The host separately maintains one fail-closed Docker `DOCKER-USER` origin-filter path permitting published HTTPS only from validated Cloudflare source ranges. A current range policy is preferred; only bounded validated last-known-good state may be used as fallback. If no safe policy exists, origin ingress remains blocked.

CrowdSec web-client remediation is Cloudflare-side. A CrowdSec host firewall bouncer is not required.

The authoritative forms are:

```bash
sudo vwctl edge refresh
sudo vwctl crowdsec status
sudo vwctl crowdsec decisions
sudo vwctl crowdsec unban 203.0.113.7
```

`crowdsec decisions` and `crowdsec unban` are public CLI surfaces over the existing `edge.py` CrowdSec owner. `crowdsec unban` accepts one syntactically valid IPv4/IPv6 address; `edge.py` owns the mutation lock and delegates the actual deletion to `cscli`. The dashboard does not implement a second decision store or CrowdSec mutation path.

## `/admin` defense in depth

The supported `/admin` posture is intentionally lightweight:

- Vaultwarden admin token;
- Caddy-side rate limiting;
- one simple outer authentication gate.

Do not replace this with an enterprise identity stack or accumulate multiple redundant outer gates. Dashboard status consumes the authoritative `edge.admin.protection` doctor result, which examines the rendered Caddy policy and required runtime material. A deliberately disabled `/admin` route is a valid closed PASS; merely having admin-related secrets present is not sufficient to claim protection.

## Notifications

Operational notifications use the closed immutable `email-providers.toml` catalog. Vaultwarden application email remains direct authenticated SMTP.

Provider API delivery uses bounded retries only for failures classified transient by network semantics or current provider documentation. Authenticated SMTP fallback follows only an eligible transient API outcome. It does not mask authentication, TLS validation, permanent provider, or ambiguous delivery failures.

For CyberPersons, current verified behavior is:

- `503 service_unavailable` is status-only transient/retry/fallback eligible;
- `429 rate_limit_exceeded` remains visible because current provider behavior includes account-wide minute/hour/day/month limits shared across API and SMTP credentials;
- `500 send_failed` remains visible and is not fallback eligible by status alone.

Do not restore older documentation that categorizes arbitrary CyberPersons 429 responses as transient.

Day-2 notification tests exercise the existing notification transport owner without adding Postfix or a queue:

```bash
sudo vwctl notification test
sudo vwctl notification test --smtp
```

The first exercises the configured operational route and its existing eligible SMTP-fallback policy. The second explicitly exercises direct authenticated SMTP.

## Recovery and rclone

Create a verified local `.vwrec` application recovery point with the authoritative CLI:

```bash
sudo vwctl backup
```

Where configured, offsite publication uses non-destructive rclone copy/copyto semantics and must be remotely verified before success is reported. Pruning remains a separate explicit action.

Recovery inventory, verification, and guided local/remote restore remain owned by the Workstream 3 interfaces:

```bash
sudo vwctl recovery list
sudo vwctl recovery list --remote REMOTE:path
sudo vwctl recovery verify --file /path/to/recovery.vwrec --identity /path/to/offline.age
sudo vwctl recovery verify --from-remote REMOTE:path/to/recovery.vwrec --identity /path/to/offline.age
sudo vwctl restore
```

The human recovery experience includes a guided local/remote restore picker. Explicit noninteractive CLI restore forms remain supported for automation. See [RECOVERY.md](RECOVERY.md).

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

Automated update checking/notification is supported. Unattended update **apply** is not the default.

The Workstream 4 public update forms are:

```bash
sudo vwctl update check
sudo vwctl update apply
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

The update owner stages exact images/builds, verifies a pre-update recovery point, activates an immutable release, and health-gates it. If candidate runtime activation may have changed persistent state, it deliberately refuses a blind binary rollback; the verified pre-update recovery point is the safe downgrade boundary.

The dashboard's update summary uses a public read-only persisted update-check view; it does not call private update-transaction helpers. The explicit `--use-latest` path freezes exact immutable values; it does not leave a floating `latest` state.

## Ubuntu package updates

Ubuntu host package updates are a separate workflow from application updates. Do not claim that `.vwrec` recovery can roll back apt/kernel changes. The appliance never auto-reboots; any reboot remains an explicit administrator action after host maintenance.

```bash
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

The dashboard surfaces `/var/run/reboot-required` when applicable.

## Configuration changes

The config and encrypted SOPS authorities remain `/etc/vaultwarden-oci/config.toml` and `/etc/vaultwarden-oci/secrets.sops.yaml`.

Supported day-2 helpers are:

```bash
sudo vwctl config edit
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets edit
sudo vwctl secrets validate
```

`runtime.py` owns the validated config-edit transaction: it uses a root-only candidate beside the config authority and parses it before durable atomic replacement. `secrets.py` owns the SOPS/Age edit and validation transaction: it invokes SOPS against an encrypted root-only candidate beside the SOPS authority on the same filesystem, validates custody/decryption/admin-pairing, and only then durably replaces the installed document. Invalid edits leave the installed authority unchanged.

High-value credential rotation remains an edit of the same SOPS authority rather than a second credential store. After a validated configuration or secret change:

```bash
sudo vwctl doctor --json
sudo vwctl restart
sudo vwctl status
```

Human wrappers may guide these steps, but all mutations converge on the established cohesive owner behind the same `vwctl` authority and mutation lock.

## Current development-branch state

The supported `dashboard.sh`, dedicated-storage enforcement, Caddy trusted-proxy/rate-limit module set, production `setup.sh --use-latest` behavior, Workstream 3 recovery interfaces, and Workstream 4 update/check/apply interfaces are now present on this branch. The dashboard is intentionally presentation-only: it does not restore Make orchestration, Postfix queues, old backup tiers, direct Docker lifecycle mutation, or duplicate recovery/update/backup state machines.
