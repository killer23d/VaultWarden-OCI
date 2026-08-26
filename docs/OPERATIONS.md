# Operations

`dashboard.sh` is the normal day-2 human interface. `vwctl` remains the single implementation and mutation authority: the dashboard reads stable status/doctor output and delegates every state-changing action to `vwctl`. Its only direct command is bounded read-only `journalctl` display.

## Dashboard

**Prerequisite:** a completed installation with valid dedicated storage.

```bash
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

From a source checkout:

```bash
sudo ./dashboard.sh
```

The main screen covers Vaultwarden/Caddy, doctor, dedicated-storage usage, local/offsite recovery age, rclone, CrowdSec/Cloudflare, timers, notifications, installed/update state, `/admin` protection, and reboot-required state. Menus cover Stack, Diagnostics, Backup & Recovery, Security, Config & Secrets, Recovery Kit, Email & Notifications, Updates & Host, and Automation. `NO_COLOR=1` disables color; JSON and non-TTY output remain machine-safe.

**Expected success:** the screen truthfully reflects `vwctl status --json` and doctor state. **On failure:** exit to `sudo vwctl status --json` and `sudo vwctl doctor --json`; never interpret a dashboard presentation error as appliance health.

## Lifecycle, status, doctor, and logs

| Task | Command | Expected success | If it fails |
| --- | --- | --- | --- |
| Start | `sudo vwctl start` | `PASS` and healthy containers | Run doctor; fix storage/secret/edge failure first. |
| Stop | `sudo vwctl stop` | Containers removed; volatile secrets cleaned | Inspect Docker state; do not delete persistent data. |
| Restart | `sudo vwctl restart` | Re-rendered exact runtime becomes healthy | Run doctor and logs. |
| Summary | `sudo vwctl status` / `sudo vwctl status --json` | Truthful service/storage/recovery/update summary | Use doctor for check-level causes. |
| Diagnostics | `sudo vwctl doctor --json` | No `FAIL` | Fix the named stable check ID before acceptance. |
| Logs | `sudo vwctl logs --tail 200` | Bounded recent container logs | Use systemd journal if launch failed before containers ran. |

Useful journals:

```bash
journalctl -u vaultwarden-oci.service
journalctl -u vaultwarden-oci-health.service
journalctl -u vaultwarden-oci-backup.service
journalctl -u vaultwarden-oci-maintenance.service
journalctl -u vaultwarden-oci-update-check.service
journalctl -u 'vaultwarden-oci-notify@*'
```

`sudo vwctl support-bundle` creates a bounded sanitized artifact in root-only volatile storage by default. It excludes config/secrets files and includes journal text only when loaded secret values can be applied to fail-closed redaction.

## Config and secrets

**Prerequisite:** the installed `/etc/vaultwarden-oci` authorities and valid dedicated storage.

```bash
sudo vwctl config edit
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets edit
sudo vwctl secrets validate
sudo vwctl doctor --json
sudo vwctl restart
```

The config editor parses a protected candidate before atomic replacement. The secret editor lets SOPS operate on a protected encrypted candidate, then validates recipients, operational decryption, and credential pairing before replacement.

**Expected success:** validation passes before restart. **On failure:** the original authority remains installed; correct the candidate through the same command rather than copying plaintext secrets around.

## Caddy, Cloudflare origin protection, and `/admin`

Caddy uses exact-pinned Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP, combined-range, and rate-limit modules. Its trusted-proxy module is the single Caddy authority for Cloudflare client-IP trust.

The host separately owns a fail-closed Docker `DOCKER-USER` origin filter that permits published TCP/443 only from validated Cloudflare IPv4/IPv6 ranges. A bounded last-known-good range set can be used. With neither current nor safe cached ranges, public origin ingress remains blocked.

`/admin` uses only the intended small stack: Vaultwarden admin token, Caddy rate limiting, and one outer Basic Auth gate. A deliberately disabled admin route is a valid closed state.

To **enable or rotate** admin access, edit the encrypted secret authority and set both `vaultwarden_admin_token` and `admin_basic_auth_password` together; changing either value is treated as a rotation of that layer:

```bash
sudo vwctl secrets edit
sudo vwctl secrets validate
sudo vwctl restart
sudo vwctl doctor --json
```

To **disable** `/admin`, run `sudo vwctl secrets edit` and remove both `vaultwarden_admin_token` and `admin_basic_auth_password`, then run the same validate/restart/doctor sequence. Do not place either plaintext value in `config.toml`.

Refresh or diagnose the separate Cloudflare origin policy with:

```bash
sudo vwctl edge refresh
sudo vwctl doctor --json
```

**Expected success:** the secrets transaction validates, restart succeeds, and edge/trusted-proxy/admin doctor checks show either protected admin access or the deliberate closed/disabled state. **On failure:** the validated editor leaves the previous authority intact; do not bypass the origin filter or remove only one admin secret to obtain green status.

## CrowdSec and Cloudflare remediation

```bash
sudo vwctl crowdsec status
sudo vwctl crowdsec decisions
sudo vwctl crowdsec unban 203.0.113.7
```

CrowdSec consumes Caddy web logs and remediates proxied clients through Cloudflare. It does not need a host firewall bouncer; the `DOCKER-USER` source filter is a separate control.

**Expected success:** engine and Cloudflare remediation report healthy state. **On failure:** inspect CrowdSec service state and Cloudflare credentials/config before changing host firewall rules.

## Notifications and email tests

Vaultwarden application mail uses direct authenticated SMTP. Operational notifications use one built-in HTTPS provider and fall back to authenticated SMTP only after a failure classified as eligible transient. For CyberPersons, `503 service_unavailable` is status-only transient; `429 rate_limit_exceeded` and `500 send_failed` are not transient by status alone.

```bash
sudo vwctl notification test
sudo vwctl notification test --smtp
```

**Expected success:** the first command proves the configured operational route; the second proves direct authenticated SMTP. **On failure:** inspect `notification.*` doctor checks and provider/SMTP settings. Permanent/auth/TLS/ambiguous API failures are intentionally not hidden by SMTP fallback.

## Timers and automation

systemd owns scheduling. The enabled `vaultwarden-oci.target` wants the health, backup, maintenance, and update-check timers.

```bash
sudo systemctl enable --now vaultwarden-oci.target
sudo vwctl timers
sudo vwctl timers --json
systemctl list-timers 'vaultwarden-oci-*'
```

`vwctl timers` checks the triggered services too, so a waiting timer cannot hide a previously failed run.

**Expected success:** target active and all four timers healthy. **On failure:** inspect the corresponding service journal and any `OnFailure` notification.

## Application updates

Normal update is explicit and recovery-gated:

```bash
sudo vwctl update check
sudo vwctl update apply
```

The updater discovers/stages exact immutable content before downtime where practical, verifies a pre-update `.vwrec`, activates the immutable release, and health-gates it. If candidate runtime activation may have changed persistent state, it refuses to pretend a binary-only rollback restored data; the verified pre-update recovery point is the downgrade boundary.

Explicit current-upstream discovery:

```bash
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

`--use-latest` resolves supported mutable upstreams once to exact refs/digests and freezes them. It must never leave floating `latest` state. The update-check timer checks/notifies automatically; application **apply** remains operator-driven.

**Expected success:** check reports a coherent candidate/no-update state; apply ends with exact active version plus healthy status/doctor. **On failure:** follow the updater's recovery/rollback message; do not manually point `current` at old code after possible persistent-state mutation.

## Ubuntu package updates and reboot-required state

Host packages are deliberately separate:

```bash
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

Application recovery does not roll back apt/kernel changes. The appliance never auto-reboots; dashboard/status surface `/var/run/reboot-required` and the administrator chooses when to reboot.

**Expected success:** package outcome and reboot requirement are reported truthfully. **On failure:** use normal Ubuntu package diagnostics; do not use `.vwrec` as an apt rollback mechanism.

## Common troubleshooting

- **Storage FAIL / service will not start:** `findmnt --target /var/lib/vaultwarden-oci`, then compare with `/etc/vaultwarden-oci/storage-identity.json`. Restore the intended mount; never create replacement data on `/`.
- **Caddy/origin FAIL:** run `sudo vwctl edge refresh`, then doctor. Do not expose origin 443 directly.
- **Secrets FAIL:** use `sudo vwctl secrets validate`/`edit`; do not copy decrypted YAML into files or shell history.
- **Recovery stale/missing:** create and verify a new recovery point before depending on it.
- **Timer failure:** inspect `vwctl timers` plus the specific service journal.
- **Update failure:** preserve the verified pre-update recovery point and obey the reported rollback boundary.
- **Support diagnostics:** use `sudo vwctl support-bundle` and review it before sharing.

## Where things live

| Purpose | Location |
| --- | --- |
| Operator config | `/etc/vaultwarden-oci/config.toml` |
| Encrypted secret authority | `/etc/vaultwarden-oci/secrets.sops.yaml` |
| Operational Age private identity | `/etc/vaultwarden-oci/age-key.txt` (root-only) |
| Expected storage identity | `/etc/vaultwarden-oci/storage-identity.json` |
| Dedicated persistent data mount | `/var/lib/vaultwarden-oci` |
| Local `.vwrec` recovery points | `/var/lib/vaultwarden-oci/backups` |
| Volatile rendered/decrypted state | `/run/vaultwarden-oci` |
| Immutable installed releases | `/opt/vaultwarden-oci/releases/<version>` |
| Active release selector | `/opt/vaultwarden-oci/current` |
| Stable CLI | `/usr/local/bin/vwctl` |
| Installed systemd units | `/etc/systemd/system/vaultwarden-oci*` |

The offline recovery private identity and recovery-kit ZIP passphrase do **not** belong in persistent server paths.
