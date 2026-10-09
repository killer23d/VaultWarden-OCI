# Operations

These operations apply to supported Ubuntu 24.04 LTS Noble and Ubuntu 26.04 LTS Resolute hosts. Application updates and Ubuntu package maintenance remain separate; `vwctl update` does not perform an Ubuntu release upgrade.

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

**Prerequisite:** the installed `/etc/vaultwarden-oci` authorities and valid dedicated storage. See [Configuration](CONFIGURATION.md) for the full pre-populated setting catalog and defaults.

```bash
sudo vwctl config edit
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl secrets edit
sudo vwctl secrets validate
sudo vwctl doctor --json
```

The config editor parses a protected candidate before atomic replacement. The secret editor lets SOPS operate on a protected encrypted candidate, then validates recipients, operational decryption, and credential pairing before replacement.

On a fresh or fully reconciled appliance, a successful interactive `config edit` or `secrets edit` checks the stack state and offers to restart a running stack immediately. Accepting uses the same supported lifecycle as `sudo vwctl restart`; declining prints the command to run later. If the stack is stopped, the validated changes apply on the next start. Non-interactive callers do not receive a blocking prompt.

Vaultwarden's web Admin settings are not a second durable appliance authority in the steady state. A fresh/reconciled runtime points upstream `CONFIG_FILE` at container tmpfs, so Admin-panel changes are temporary diagnostics and do not override `/etc/vaultwarden-oci/config.toml` after restart.

An upgrade that finds a pre-existing `/data/config.json` does **not** silently ignore it. The candidate keeps that historical Admin file effective until the operator reconciles its appliance-supported values through `vwctl config edit`/`secrets edit`. Supported differences are shown without secret values and finalization is refused while they differ. When they match, the interactive flow names legacy-only/incompatible/sensitive keys whose values will stop participating, asks for explicit confirmation, and records a digest-bound finalization marker. Only then does the next start/restart switch `CONFIG_FILE` to tmpfs. If the historical file later changes, its digest no longer matches the marker and reconciliation becomes pending again.

**Expected success:** validation passes before restart or the next start, and an upgraded host with historical Admin policy reaches appliance-only authority only after explicit reconciliation. **On failure:** the original config/SOPS authority remains installed and an unfinalized legacy Admin file remains effective; correct the candidate through the supported editors rather than copying plaintext secrets around.

## Recovery custody after setup

The operational Age private identity is normal root-only appliance state. The offline recovery private identity is not. If first-run setup generated the offline identity because a terminal-driven install, including `--auto`, omitted `--offline-recipient`, that private identity exists only temporarily under root-owned volatile `/run/vaultwarden-oci` while the verified recovery-kit handoff is in progress. After successful custody acknowledgement or successful authenticated email handoff, it must be absent from the appliance.

If setup reported a failed or unacknowledged handoff and displayed the transient identity path, secure that exact identity before reboot. Do not delete it and do not rerun setup in a way that creates a different offline identity for config/secrets already addressed to the original recipient. For normal later recovery-kit export, use the off-host identity already in operator custody.

An install performed with an explicit `--offline-recipient` uses that existing off-host custody and does not create a replacement offline private identity. Fully headless `--auto` therefore requires an explicit public recipient.

## Caddy, Cloudflare origin protection, and `/admin`

Caddy uses exact-pinned Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP, combined-range, and rate-limit modules. Its trusted-proxy module is the single Caddy authority for Cloudflare client-IP trust.

For creation or rotation of `cloudflare_api_token` and `cloudflare_remediation_token`, including the intentionally different Cloudflare permission sets, see [Cloudflare tokens](CLOUDFLARE-TOKENS.md). Keep the two credentials separate and update them only through `sudo vwctl secrets edit`.

The configured public hostname is published through the same narrow `cloudflare_api_token` without creating another zone-ID or DNS configuration authority:

```bash
sudo vwctl dns status
sudo vwctl dns update --dry-run
sudo vwctl dns update
```

`dns update` discovers this host's public IPv4 through a bounded direct-HTTPS fallback set, requires exactly one existing Cloudflare A record for `[site].domain`, requires that record to already be proxied, refuses explicit AAAA records, patches only the A-record content, and then reads the record back authoritatively. It does not put the Cloudflare token in argv, environment variables, logs, or persistent runtime files. The initial proxied A record remains an operator/Cloudflare setup prerequisite; the appliance does not guess whether a missing record should be created or whether IPv6 should be published.

The host separately owns a fail-closed Docker `DOCKER-USER` origin filter that permits published TCP/443 only from validated Cloudflare IPv4/IPv6 ranges. A bounded last-known-good range set can be used. With neither current nor safe cached ranges, public origin ingress remains blocked.

`/admin` uses only the intended small stack: Vaultwarden admin token, Caddy rate limiting, and one outer Basic Auth gate. A deliberately disabled admin route is a valid closed state. The outer route defaults to 60 requests per minute, which is intentionally high enough for the Admin page's normal multi-request UI while still bounded. Vaultwarden's own admin-login limiter remains separate at its 300-second/3-burst default. The previous 5-requests-per-5-minutes outer limit was too restrictive for normal Admin navigation and could return HTTP 429 before an SMTP test reached Vaultwarden.

To **enable or rotate** admin access, edit the encrypted secret authority and set both `vaultwarden_admin_token` and `admin_basic_auth_password` together; changing either value is treated as a rotation of that layer:

```bash
sudo vwctl secrets edit
sudo vwctl secrets validate
sudo vwctl doctor --json
```

Accept the restart prompt, or run `sudo vwctl restart` later if you decline it. If a legacy Admin reconciliation is still pending, complete that explicit transition before expecting an appliance config change to replace values from the historical Admin file.

To **disable** `/admin`, run `sudo vwctl secrets edit` and remove both `vaultwarden_admin_token` and `admin_basic_auth_password`, then validate and restart when prompted. Do not place either plaintext value in `config.toml`.

Refresh or diagnose the separate Cloudflare origin policy with:

```bash
sudo vwctl edge refresh
sudo vwctl doctor --json
```

The existing five-minute health timer starts two independent oneshot services: `vaultwarden-oci-health.service` runs local `vwctl status`, while `vaultwarden-oci-dns.service` runs the idempotent `vwctl dns update --timer` path. A DNS/API outage therefore cannot prevent or fail the local appliance health check. DNS HTTPS transport failures receive bounded retry and are journaled without OnFailure for the first two consecutive timer failures; the third consecutive transient failure fails the DNS service and notifies. Structural configuration, credential, DNS-shape, proxy-state, and authoritative-readback failures remain immediate failures. A successful DNS run clears the transient-failure history. Expected mutation-lock contention remains a clean skip for the next interval. The separate daily maintenance timer continues to run the authoritative `vwctl edge refresh` before `vwctl doctor`, keeping long-running hosts inside the 72-hour Cloudflare last-known-good validity window.

**Expected success:** the secrets transaction validates, restart succeeds, and edge/trusted-proxy/admin doctor checks show either protected admin access or the deliberate closed/disabled state. **On failure:** the validated editor leaves the previous authority intact; do not bypass the origin filter or remove only one admin secret to obtain green status.

## CrowdSec and Cloudflare remediation

The supported CrowdSec path restores the useful earlier-product detection breadth without restoring its competing Docker-firewall ownership. `vwctl crowdsec setup` installs and manages:

- the CrowdSec Security Engine;
- `crowdsecurity/caddy`, `crowdsecurity/linux`, `crowdsecurity/iptables`, and `Dominic-Wagner/vaultwarden` Hub collections;
- acquisition of Caddy access logs, Vaultwarden security logs, Ubuntu `ssh.service`, and kernel/firewall journal events;
- the Cloudflare Worker bouncer for locally generated proxied web decisions;
- the nftables firewall bouncer for broad/community/list decisions on **host INPUT only**.

The Cloudflare Worker is intentionally limited to exactly `only_include_decisions_from: ["cscli", "crowdsec"]`. Broad CAPI/community/list decisions stay off the Worker/KV path and are consumed by the host firewall bouncer instead. `crowdsec.cloudflare` can report `PASS` only when the active Worker invocation is bound to a policy attestation containing that exact source set and a digest of the exact base/local config files it started from. Editing the config after start, starting the service outside the supported `vwctl` flow, or carrying an attestation across a new systemd invocation therefore fails the check.

The firewall bouncer is intentionally constrained to the nftables `input` hook. It must not own Docker `forward` or `DOCKER-USER`; the existing Cloudflare-only origin filter remains the single owner of published container ingress.

First setup or a deliberate reconfiguration is:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec status
sudo vwctl crowdsec remediation-start
```

`crowdsec setup` leaves the Cloudflare Worker boot-disabled and clears any prior Fail Open confirmation because a new remediation invocation must be explicitly authorized. `remediation-start` starts the Worker only through the supported one-shot token path and records the current invocation/config policy attestation before returning success. After `remediation-start`, set every Worker Route created by the bouncer to **Fail Open** in Cloudflare, then attest that exact invocation:

```bash
sudo vwctl crowdsec confirm-fail-open
sudo vwctl crowdsec status
```

A healthy final state has four CrowdSec doctor checks: `crowdsec.engine`, `crowdsec.hub`, `crowdsec.firewall`, and `crowdsec.cloudflare`, all `PASS`. The firewall bouncer should be active/enabled; the Cloudflare Worker should be active for the current explicit invocation but remain disabled at boot.

Normal day-2 commands remain:

```bash
sudo vwctl crowdsec status
sudo vwctl crowdsec decisions
sudo vwctl crowdsec unban 203.0.113.7
```

`cloudflare_remediation_token` must carry the Worker/KV and read permissions documented in [Cloudflare tokens](CLOUDFLARE-TOKENS.md). The appliance discovers Cloudflare Account ID and Zone ID and generates the Cloudflare Worker's local LAPI credential. For the host firewall bouncer, `vwctl crowdsec setup` creates a separate `vaultwarden-oci-firewall` LAPI credential only after the CrowdSec engine is healthy and writes that key plus the loopback LAPI URL into the root-only `.yaml.local` override. The package-owned base firewall-bouncer config remains unchanged, so package upgrades retain ownership of package defaults while the appliance owns its narrow credential/policy override.

**Expected success:** engine, required Hub collections, host-input firewall remediation, and explicitly armed Cloudflare remediation all report healthy state. **On failure:** inspect the named CrowdSec doctor check, `systemctl status crowdsec.service`, `systemctl status crowdsec-firewall-bouncer.service`, and the Cloudflare Worker service before changing firewall policy. Never add the CrowdSec firewall bouncer to Docker `FORWARD`/`DOCKER-USER` to make a check green.

## Notifications and email tests

Vaultwarden application mail and the appliance direct SMTP path share the common `[smtp]` host/port/security/sender/timeout values and SOPS `smtp_username`/`smtp_password`. This covers invitations, verification, email 2FA, new-device mail, the Vaultwarden Admin SMTP test, `vwctl notification test --smtp`, and eligible operational-notification fallback. Operational notifications may additionally use one built-in HTTPS provider. For CyberPersons, `503 service_unavailable` is status-only transient; `429 rate_limit_exceeded` and `500 send_failed` are not transient by status alone.

The Vaultwarden-specific `smtp.embed_images`, `smtp.accept_invalid_certs`, and `smtp.accept_invalid_hostnames` controls are not settings for the appliance direct SMTP client. The direct client always performs normal certificate and hostname validation and intentionally does not honor Vaultwarden's TLS exceptions.

```bash
sudo vwctl notification test
sudo vwctl notification test --smtp
```

**Expected success:** the first command proves the configured operational route and labels the actual API/fallback transport in the delivered diagnostic; the second proves the common SMTP endpoint/sender/credentials using direct authenticated SMTP with strict TLS validation. It does not prove Vaultwarden-only TLS exception knobs. **On failure:** inspect `notification.*` doctor checks and provider/SMTP settings. Permanent/auth/TLS/ambiguous API failures are intentionally not hidden by SMTP fallback.

If the Vaultwarden Admin SMTP test reports `429` followed by JavaScript such as `SyntaxError: Unexpected end of JSON input`, inspect the Caddy access log before changing SMTP credentials. That symptom can be an HTTP rate-limit response rather than an SMTP rejection. The supported default outer `/admin` limit is now 60 requests/minute specifically to avoid the former 5-per-5-minute false failure. Use `sudo vwctl notification test --smtp` to test the common SMTP transport independently under strict TLS.

## Timers and automation

systemd owns scheduling. The enabled `vaultwarden-oci.target` wants the health, backup, maintenance, and update-check timers. Every five-minute health activation starts the local health service and independently pulls in the DNS synchronization service; they do not share a failure result.

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

The updater discovers/stages exact immutable content before downtime where practical, verifies a pre-update `.vwrec`, activates the immutable release, and health-gates it. A recovery snapshot briefly pauses/unpauses the running containers for consistency; the updater allows only a bounded Docker-health recovery window afterward. Unrelated failures still fail closed immediately. If candidate runtime activation may have changed persistent state, it refuses to pretend a binary-only rollback restored data; the verified pre-update recovery point is the downgrade boundary.

An update that changes the Cloudflare Worker decision-source contract may deliberately stop **before** creating the recovery point. In that case the candidate re-arms the Worker under the required local-only policy, invalidates the previous invocation's Fail Open confirmation, and prints an `ACTION` telling the operator to set every newly recreated Worker Route to **Fail Open** and run `sudo vwctl crowdsec confirm-fail-open`. After confirming the new invocation, rerun the **same installed `vwctl update apply` command**. Do not substitute a candidate checkout, run `crowdsec setup`, reuse the old Fail Open confirmation, or bypass this stop.

A narrowly supported predecessor transition may print one additional pre-recovery `ACTION` after that prerequisite is healthy: the exact validated target update controller has been staged and the same `sudo vwctl update apply ...` command must be rerun. At this boundary `/opt/vaultwarden-oci/current` and the running appliance still select the predecessor. Only installed `vwctl update ...` is temporarily routed through the exact staged target controller so the retry can use target-owned update safety logic; `vwctl status`, `doctor`, lifecycle, CrowdSec, and every other command continue to execute from the selected predecessor. Do not edit `/usr/local/bin/vwctl`, switch `current`, invoke the candidate checkout, or remove the root-only handoff state manually. Successful target selection restores the normal `/usr/local/bin/vwctl -> /opt/vaultwarden-oci/current/vwctl` launcher automatically. A failed recovery/update leaves the handoff in place so the same supported update can be retried without patching immutable predecessor code.

The broader host CrowdSec package/Hub/acquisition/firewall transition is not allowed to occur until the target-owned retry has created and verified the pre-update recovery point. An explicitly tested supported-predecessor transition may then install a host dependency required by the target appliance security/runtime contract. This is a narrow compatibility exception, not ordinary Ubuntu maintenance: it happens only after candidate prevalidation and verified recovery, does not include a kernel upgrade or reboot, and its host package/security-control changes are **forward-only state outside `.vwrec` rollback**. If later candidate activation fails and the application is coherently rolled back, the rollback restores application data, release selection, application systemd units, and update guard state; it does not uninstall or downgrade that compatibility dependency. Leave the retained host controls in place, require the predecessor to remain healthy with the Worker still local-only and Fail Open confirmed and the firewall still INPUT-only, then retry the same supported target update. Do not manually remove the dependency to make the host look like its pre-update package set.

Explicit current-upstream discovery:

```bash
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

`--use-latest` resolves supported mutable upstreams once to exact refs/digests and freezes them. It must never leave floating `latest` state. The update-check timer checks/notifies automatically; application **apply** remains operator-driven.

**Expected success:** check reports a coherent candidate/no-update state; apply may stop at an explicitly described prerequisite/handoff boundary, and the final apply ends with exact active version plus healthy status/doctor. If the candidate reports a pre-existing Vaultwarden Admin config transition, existing Admin policy remains effective until the separate explicit reconciliation described above. **On failure:** follow the updater's recovery/rollback message; do not manually repoint either `current` or `/usr/local/bin/vwctl`. If a supported compatibility dependency was already installed, do not manually remove it after application rollback; verify predecessor health and retry the supported target update.

## Ubuntu package updates and reboot-required state

Routine host package maintenance is deliberately separate:

```bash
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

The narrow supported-predecessor compatibility dependency described above does not turn application update into a general host-upgrade path. Application recovery does not roll back apt/kernel changes. The appliance never auto-reboots; dashboard/status surface `/var/run/reboot-required` and the administrator chooses when to reboot.

**Expected success:** package outcome and reboot requirement are reported truthfully. **On failure:** use normal Ubuntu package diagnostics; do not use `.vwrec` as an apt rollback mechanism.

## Troubleshooting

For failures, use the symptom-oriented [Troubleshooting guide](TROUBLESHOOTING.md). It starts from the observed problem, gives safe diagnostics, explains what the result means, names the supported correction, and ends with a verification step.

A good first triage is:

```bash
sudo vwctl status
sudo vwctl doctor --json
sudo vwctl timers
systemctl --failed --no-pager
```

Do not use broad Docker cleanup, bypass dedicated storage or the Cloudflare origin filter, delete state, or manually repoint the active release to make a check green. Use `sudo vwctl support-bundle` when you need a bounded sanitized diagnostic artifact.

## Where things live

| Purpose | Location |
| --- | --- |
| Operator config | `/etc/vaultwarden-oci/config.toml` |
| Encrypted secret authority | `/etc/vaultwarden-oci/secrets.sops.yaml` |
| Operational Age private identity | `/etc/vaultwarden-oci/age-key.txt` (root-only) |
| Expected storage identity | `/etc/vaultwarden-oci/storage-identity.json` |
| Dedicated persistent data mount | `/var/lib/vaultwarden-oci` |
| Historical Vaultwarden Admin config during bounded reconciliation | `/var/lib/vaultwarden-oci/data/config.json` |
| Legacy Admin reconciliation marker | `/var/lib/vaultwarden-oci/state/legacy-admin-config-finalized.json` |
| Vaultwarden CrowdSec security log | `/var/lib/vaultwarden-oci/vaultwarden/log/vaultwarden.log` |
| Project CrowdSec acquisition | `/etc/crowdsec/acquis.d/vaultwarden-oci.yaml` |
| CrowdSec firewall policy override | `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local` |
| Cloudflare Worker runtime config | `/run/vaultwarden-oci/transient/crowdsec-cloudflare-worker-bouncer.yaml` |
| Cloudflare Worker local policy override | `/run/vaultwarden-oci/transient/crowdsec-cloudflare-worker-bouncer.yaml.local` |
| Cloudflare Worker invocation/policy attestation | `/var/lib/vaultwarden-oci/state/crowdsec-cloudflare-worker-policy.json` |
| Cloudflare Worker Fail Open confirmation | `/var/lib/vaultwarden-oci/state/crowdsec-cloudflare-fail-open.json` |
| Temporary supported update-controller handoff state | `/var/lib/vaultwarden-oci/state/update-controller-handoff.json` |
| Local `.vwrec` recovery points | `/var/lib/vaultwarden-oci/backups` |
| Volatile rendered/decrypted state | `/run/vaultwarden-oci` |
| Immutable installed releases | `/opt/vaultwarden-oci/releases/<version>` |
| Active release selector | `/opt/vaultwarden-oci/current` |
| Stable CLI | `/usr/local/bin/vwctl` |
| Installed systemd units | `/etc/systemd/system/vaultwarden-oci*` |

The offline recovery private identity and recovery-kit ZIP passphrase do **not** belong in persistent server paths. During terminal-driven first-run setup only, a generated offline identity may temporarily exist under root-only volatile `/run/vaultwarden-oci`; successful handoff must remove it.
