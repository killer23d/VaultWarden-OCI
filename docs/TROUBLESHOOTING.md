# Troubleshooting

This guide applies to supported Ubuntu 24.04 LTS Noble and Ubuntu 26.04 LTS Resolute hosts. When collecting host evidence, record the Ubuntu version/codename and architecture; do not assume a failure on one LTS proves the same behavior on the other.

Use this guide when the appliance is installed or being installed but a supported workflow does not reach its expected result. Start with the symptom; use the narrow diagnostics shown here before changing state.

The normal rule is:

**Symptom -> safe diagnostics -> interpretation -> supported correction -> verification**

Do not use broad Docker cleanup, delete appliance state, bypass the dedicated-storage guard, disable the Cloudflare origin filter, hand-edit generated runtime files, or repoint `/opt/vaultwarden-oci/current` to make a check green.

## Find your symptom

| Symptom | Go to |
| --- | --- |
| Setup cannot use the data disk | [Setup cannot find or accept storage](#setup-cannot-find-or-accept-storage) |
| Setup stopped while handing off the recovery identity/kit | [Setup stops during recovery custody](#setup-stops-during-recovery-custody) |
| Config or SOPS validation fails | [Config validation fails](#config-validation-fails) / [Secrets validation fails](#secrets-validation-fails) |
| Stack or container will not start | [Stack will not start](#stack-will-not-start) / [A container is unhealthy](#a-container-is-unhealthy) |
| Doctor, timer, or systemd failure | [`vwctl doctor` reports FAIL](#vwctl-doctor-reports-fail) / [A systemd unit or timer failed](#a-systemd-unit-or-timer-failed) |
| DNS, origin, or real-client-IP issue | [DNS is wrong](#dns-is-wrong-or-the-dns-update-fails) / [Cloudflare origin policy](#cloudflare-origin-policy-is-stale-or-fails) / [Real client IP](#real-client-ip-is-wrong) |
| `/admin` or Admin SMTP-test problem | [`/admin` access fails](#admin-access-fails) |
| CrowdSec problem | [CrowdSec engine, Hub, or host firewall fails](#crowdsec-engine-hub-or-host-firewall-fails) / [Cloudflare remediation is not armed](#cloudflare-crowdsec-remediation-is-not-armed) |
| Notification or SMTP delivery fails | [Notification or SMTP test fails](#notification-or-smtp-test-fails) |
| Backup, rclone, verify, or restore problem | [Local backup fails](#local-backup-fails) / [Offsite/rclone recovery fails](#offsiterclone-recovery-fails) / [Recovery artifact cannot be verified](#a-recovery-artifact-cannot-be-verified) |
| Update stopped, rolled back, or requires recovery | [Update check/candidate failure](#update-check-or-candidate-preparation-fails) / [Update health gate/recovery required](#update-health-gate-rolled-back-or-recovery-is-required) |
| Reboot leaves Worker unarmed | [Reboot leaves CrowdSec Worker unarmed](#reboot-leaves-crowdsec-worker-unarmed) |

## First response: collect the appliance view

These commands are safe first checks on an installed host:

```bash
sudo vwctl status
sudo vwctl doctor --json
sudo vwctl timers
systemctl --failed --no-pager
```

For recent application logs:

```bash
sudo vwctl logs --tail 200
```

For lifecycle failures that occur before containers are available:

```bash
systemctl status vaultwarden-oci.service --no-pager
journalctl -u vaultwarden-oci.service --no-pager --lines=200
```

A `doctor` **FAIL** is an unresolved appliance problem. A `WARN` is not automatically ignorable; read the named check. During first-run, `recovery.local` is expected to remain WARN until you create the first verified `.vwrec` with `sudo vwctl backup`. Offsite recovery is separately optional: `recovery.offsite` / `recovery.rclone` can remain warning/unconfigured until an offsite target is deliberately configured.

If you need to hand diagnostics to another administrator, create the bounded sanitized bundle:

```bash
sudo vwctl support-bundle
```

Review the archive before sharing it. The command omits config/secrets and omits journal collection if loaded secrets cannot be safely prepared for fail-closed redaction.

## Setup cannot find or accept storage

**Symptom:** setup reports no acceptable storage, refuses the selected device, or rejects a root-related device.

**Diagnose:**

```bash
findmnt -n -o SOURCE,FSTYPE,TARGET --target /
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL
```

**Interpretation:** production state must live on a dedicated ext4/xfs filesystem that is not the boot/root block-device family. `/var/lib/vaultwarden-oci` is the canonical state mount; root-only production is unsupported.

**Correction:** attach/select the intended separate volume. For an existing ext4/xfs filesystem use the explicit existing-filesystem acknowledgement. For a blank device that setup is allowed to format use the explicit format confirmation. Do not switch to the boot disk just to continue.

Before mutation, you can re-run setup with the same arguments plus `--dry-run`.

**Verify:** setup should identify the selected device and later record the dedicated mount/identity without a root fallback.

## Setup stops during recovery custody

**Symptom:** setup generated an offline Age identity but recovery-kit handoff or email delivery did not complete.

**Interpretation:** the generated offline private identity is intentionally temporary root-owned state under `/run/vaultwarden-oci`. If setup reports that it remains after a failed/unacknowledged handoff, that exact identity may already correspond to config/secrets encrypted for its public recipient.

**Correction:** follow the exact `ACTION` printed by setup. Secure the reported identity off-host **before rebooting**. Do not delete it and do not casually rerun setup in a way that creates a different offline identity.

**Verify:** successful custody ends with a verified encrypted recovery-kit handoff and removal of the transient offline identity from the appliance.

For a fully headless `--auto` install, provide an existing public `--offline-recipient`; headless setup is expected to refuse missing custody before storage provisioning.

## Config validation fails

**Diagnose:**

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl config edit
```

**Interpretation:** `config.toml` is the only operator-editable non-secret configuration authority. Unknown keys, invalid types/ranges, reserved/invalid hostnames, or invalid provider options are rejected.

**Correction:** edit through `vwctl config edit`, which validates a protected candidate before replacement. Do not edit rendered Compose/Caddy/runtime files to bypass config validation.

**Verify:**

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
```

If the stack is running, accept the supported restart prompt or restart later with `sudo vwctl restart`.

## Secrets validation fails

**Diagnose:**

```bash
sudo vwctl secrets validate
sudo vwctl secrets edit
```

**Interpretation:** the SOPS document must remain decryptable by the operational Age identity and addressed to the configured offline recipient. The common required values are `cloudflare_api_token`, `smtp_username`, and `smtp_password`; admin protection requires both admin secrets together. CrowdSec setup separately requires the remediation token.

**Correction:** use `vwctl secrets edit`. Do not decrypt the file into a persistent plaintext copy or place secrets in shell arguments/config.toml.

**Verify:**

```bash
sudo vwctl secrets validate
```

## Stack will not start

**Diagnose:**

```bash
sudo vwctl doctor --json
systemctl status vaultwarden-oci.service --no-pager
journalctl -u vaultwarden-oci.service --no-pager --lines=200
sudo vwctl logs --tail 200
```

If `vwctl start` has not successfully materialized runtime state yet, some runtime/edge doctor checks can be unavailable; use the start error and journal first.

**Interpretation:** fix the named storage, config, secret, runtime, Caddy, edge, or CrowdSec prerequisite. Do not run generic Docker cleanup and do not create persistent application paths on `/`.

**Correction:** repair the specific prerequisite through its supported owner, then retry:

```bash
sudo vwctl start
```

**Verify:** start returns `PASS`, then create/verify the first backup and run the post-start doctor as described in [Install](INSTALL.md).

## `vwctl doctor` reports FAIL

Run the human form once if you need the check names inline:

```bash
sudo vwctl doctor
```

Use the failing stable check ID to choose the subsystem. Common groups are:

| Check prefix | Owner / next diagnostic |
| --- | --- |
| `storage.dedicated` | dedicated mount/identity; inspect `findmnt` |
| `config.*` / `secrets.*` | `vwctl config validate`, `vwctl secrets validate` |
| `runtime.*` | lifecycle service and `vwctl logs` |
| `edge.*` | Caddy, admin protection, Cloudflare origin policy |
| `crowdsec.*` | CrowdSec engine/Hub/firewall/Worker |
| `recovery.*` | local/offsite recovery state and rclone |
| `notification.*` | provider/SMTP configuration and last delivery |

A successful command in another subsystem does not cancel a doctor `FAIL`. Correct the named owner and rerun doctor.

## A systemd unit or timer failed

**Diagnose:**

```bash
systemctl --failed --no-pager
sudo vwctl timers
```

Then inspect only the failed unit, for example:

```bash
systemctl status vaultwarden-oci-backup.service --no-pager
journalctl -u vaultwarden-oci-backup.service --no-pager --lines=200
```

The managed one-shot services are:

- `vaultwarden-oci-health.service` — DNS synchronization followed by status;
- `vaultwarden-oci-backup.service` — local verified `.vwrec`;
- `vaultwarden-oci-maintenance.service` — Cloudflare origin refresh followed by doctor;
- `vaultwarden-oci-update-check.service` — project update availability check.

**Correction:** repair the underlying appliance check; do not merely reset a failed unit and call the appliance healthy.

**Verify:** rerun the relevant service when appropriate, then `sudo vwctl timers`. A healthy target has all four managed timer/service pairs healthy.

## A container is unhealthy

**Diagnose:**

```bash
sudo vwctl status
sudo vwctl logs vaultwarden --tail 200
sudo vwctl logs caddy --tail 200
sudo vwctl doctor --json
```

**Interpretation:** distinguish a Vaultwarden health failure from Caddy/edge failure. If the lifecycle systemd unit failed before Compose completed, use the lifecycle journal instead.

**Correction:** fix the named config/secrets/storage/edge cause and use `sudo vwctl restart`. Do not delete volumes or recreate containers manually as a repair shortcut.

**Verify:** both managed services are running/healthy and doctor has no `FAIL`.

## DNS is wrong or the DNS update fails

**Diagnose:**

```bash
sudo vwctl dns status
sudo vwctl dns update --dry-run
```

**Interpretation:** the appliance owns one existing proxied IPv4 A record for the configured hostname. It refuses ambiguous/multiple A records, a DNS-only record, or explicit AAAA ownership. It does not silently create a missing record.

**Correction:** in Cloudflare, make the intended hostname unambiguous: one existing proxied A record and no explicit AAAA record owned outside the appliance contract. Confirm the narrow `cloudflare_api_token` has the permissions/scoping in [Cloudflare tokens](CLOUDFLARE-TOKENS.md).

When the dry run is clean and the host is ready:

```bash
sudo vwctl dns update
```

**Verify:** `sudo vwctl dns status` reports the current validated public IPv4 and in-sync proxied record.

## Cloudflare origin policy is stale or fails

**Diagnose:**

```bash
sudo vwctl edge refresh
sudo vwctl doctor --json
```

**Interpretation:** Caddy trusted-proxy handling and the host `DOCKER-USER` Cloudflare-only origin filter are separate controls. A failed origin-policy refresh is not permission to expose origin TCP/443 directly.

**Correction:** restore network access/current Cloudflare ranges or the bounded safe last-known-good path. Do not remove the fail-closed filter.

**Verify:** `edge.cloudflare.cidrs` and `edge.cloudflare.iptables` pass.

## Site works at the origin but not through Cloudflare

Do not disable the origin filter to test around Cloudflare.

**Diagnose:**

```bash
sudo vwctl dns status
sudo vwctl doctor --json
sudo vwctl logs caddy --tail 200
```

Check the DNS, Caddy, trusted-proxy, origin-filter, and CrowdSec doctor IDs separately. Confirm the public hostname is proxied in Cloudflare.

**Correction:** fix the failing boundary rather than exposing the origin.

**Verify:** the proxied public hostname works and the edge/Caddy doctor checks pass.

## Real client IP is wrong

**Diagnose:**

```bash
sudo vwctl doctor --json
sudo vwctl logs caddy --tail 200
```

Look specifically at `edge.caddy.trusted_proxy`.

**Interpretation:** Caddy's Cloudflare trusted-proxy module is the request-layer owner of real-client-IP trust. The host origin filter only restricts who may reach public 443; it does not replace trusted-proxy handling.

**Correction:** repair the supported Caddy/runtime configuration. Do not add a second static Cloudflare trusted-proxy CIDR block.

**Verify:** the trusted-proxy doctor check passes and application/security logs attribute proxied requests to the expected client IPs.

## `/admin` access fails

**Diagnose:**

```bash
sudo vwctl doctor --json
sudo vwctl secrets validate
sudo vwctl logs caddy --tail 200
```

A deliberate disabled/closed admin route is healthy. When enabled, both `vaultwarden_admin_token` and `admin_basic_auth_password` must be present.

If the browser Admin SMTP test returns HTTP `429` followed by a JSON parse error, test SMTP independently:

```bash
sudo vwctl notification test --smtp
```

That symptom can be the Caddy outer rate limit rather than SMTP rejection.

**Correction:** rotate/enable/disable the paired admin secrets only through `sudo vwctl secrets edit`, then use the supported restart path. Do not remove only one admin secret.

**Verify:** `edge.admin.protection` reports either protected or deliberately disabled/closed.

## CrowdSec engine, Hub, or host firewall fails

**Diagnose:**

```bash
sudo vwctl crowdsec status
sudo vwctl doctor --json
systemctl status crowdsec.service --no-pager
systemctl status crowdsec-firewall-bouncer.service --no-pager
```

Look separately at `crowdsec.engine`, `crowdsec.hub`, and `crowdsec.firewall`.

**Correction:** for an incomplete first setup or deliberate reconfiguration, use:

```bash
sudo vwctl crowdsec setup
```

Do not move the firewall bouncer into Docker `FORWARD` or `DOCKER-USER`; it is intentionally host-INPUT-only.

**Verify:** the three foundational CrowdSec checks pass before diagnosing Worker remediation separately.

## Cloudflare CrowdSec remediation is not armed

**Symptom:** `crowdsec.cloudflare` fails while engine/Hub/firewall are healthy, commonly after reboot or Worker recreation.

**Diagnose:**

```bash
sudo vwctl crowdsec status
systemctl status crowdsec-cloudflare-worker-bouncer.service --no-pager
```

**Correction:**

```bash
sudo vwctl crowdsec remediation-start
```

Then set **every bouncer-created Worker Route for the current invocation to Fail Open in Cloudflare** and attest that exact invocation:

```bash
sudo vwctl crowdsec confirm-fail-open
```

Do not reuse an old confirmation and do not rerun the entire CrowdSec setup merely to re-arm a boot-disabled Worker.

**Verify:** `sudo vwctl crowdsec status` and doctor show `crowdsec.cloudflare` PASS.

## Notification or SMTP test fails

Test the two paths independently:

```bash
sudo vwctl notification test
sudo vwctl notification test --smtp
```

**Interpretation:** the first tests the configured operational route; the second tests direct authenticated SMTP with normal certificate/hostname validation. A direct SMTP success does not prove a Vaultwarden-only invalid-certificate exception.

**Correction:** edit non-secret SMTP/provider settings with `sudo vwctl config edit` and credentials with `sudo vwctl secrets edit`. Permanent/authentication/TLS/ambiguous API failures are intentionally not hidden by SMTP fallback.

**Verify:** rerun the failing test and then doctor.

## Local backup fails

**Diagnose:**

```bash
sudo vwctl doctor --json
journalctl -u vaultwarden-oci-backup.service --no-pager --lines=200
```

Then run the supported operation directly to receive its exact error:

```bash
sudo vwctl backup
```

**Interpretation:** backup requires verified dedicated storage, valid config/secrets, and the recovery transaction's consistency/integrity checks.

**Correction:** fix the reported prerequisite. Do not manually tar live data as a substitute for a verified `.vwrec`.

**Verify:**

```bash
sudo vwctl recovery list
```

The new local recovery point should be present and recorded as verified.

## Offsite/rclone recovery fails

**Diagnose:** use the same explicit remote you configured/selected for the operation:

```bash
sudo vwctl recovery list --remote 'REMOTE:path'
sudo vwctl doctor --json
```

**Interpretation:** offsite publication is create -> local verify -> rclone copy/copyto-style publication -> remote re-download/verification. It never uses destructive sync semantics for normal publication.

**Correction:** repair the rclone remote credentials/connectivity or remote path outside the recovery artifact. Do not replace publication with `rclone sync`.

**Verify:** after the remote is healthy, explicitly publish a new verified point:

```bash
sudo vwctl backup --remote 'REMOTE:path'
```

## A recovery artifact cannot be verified

For a local artifact:

```bash
sudo vwctl recovery verify --file /secure/recovery.vwrec
```

For a remote artifact:

```bash
sudo vwctl recovery verify --from-remote 'REMOTE:path/recovery.vwrec'
```

On an interactive terminal the command securely asks for the matching offline identity source; for non-TTY use supply `--identity /secure/offline-age-key.txt`.

**Interpretation:** wrong identity, corrupt/truncated envelope, manifest/checksum mismatch, SOPS mismatch, or retrieval failure must stop before live mutation.

**Correction:** use the matching custody material or another independently verified copy. Do not unpack or rewrite the `.vwrec` to force acceptance.

**Verify:** recovery verification returns PASS before any restore attempt.

See [Recovery](RECOVERY.md) for the recovery-kit versus `.vwrec` capability matrix and lost-server procedure.

## Update check or candidate preparation fails

Start read-only:

```bash
sudo vwctl update check
sudo vwctl status
sudo vwctl doctor --json
```

**Interpretation:** an update may intentionally stop at a prerequisite/handoff boundary and print an `ACTION`. That is not permission to bypass the boundary.

**Correction:** follow the exact action from the installed updater. If it requires a CrowdSec Worker recreation, confirm the new Fail Open routes for that invocation and rerun the **same installed** `sudo vwctl update apply`. If a supported update-controller handoff is active, leave the launcher/handoff state intact.

Do not run update code from a candidate checkout, manually switch `current`, or remove forward-only compatibility packages after an application rollback.

**Verify:** a completed apply reports the exact activated release, then status/doctor are healthy.

## Update health gate rolled back or recovery is required

**Diagnose:**

```bash
sudo vwctl status
sudo vwctl doctor --json
```

Read the updater's recorded recovery message. After possible candidate persistent-state mutation, a binary-only rollback is intentionally not treated as data rollback.

**Correction:** use the **exact `vwctl update rollback ...` command and recorded artifact/SHA/release values printed by the updater**, supplying the matching offline identity. Do not improvise paths or repoint symlinks.

The command grammar is available without mutation:

```bash
vwctl update rollback --help
```

**Verify:** the updater proves the coherent predecessor/recovery state and predecessor health. If a permitted compatibility host dependency was installed before the later application failure, it is forward-only host state and is not removed by `.vwrec` rollback.

## Reboot leaves CrowdSec Worker unarmed

The Worker is intentionally boot-disabled. First allow the normal `vaultwarden-oci.target` / lifecycle service to converge; do not manually create `/run/vaultwarden-oci`.

Check:

```bash
systemctl is-active vaultwarden-oci.target
systemctl is-active vaultwarden-oci.service
sudo vwctl status
sudo vwctl doctor --json
```

If the only remaining security failure is `crowdsec.cloudflare`, use the remediation re-arm procedure above: `remediation-start` -> set current Worker Routes Fail Open -> `confirm-fail-open`.

Then re-check:

```bash
sudo vwctl timers
systemctl --failed --no-pager
```

## What to collect when asking for help

Prefer secret-free evidence:

```bash
sudo vwctl versions
sudo vwctl status --json
sudo vwctl doctor --json
sudo vwctl timers --json
systemctl --failed --no-pager
sudo vwctl support-bundle
```

Also record the exact command that failed and its complete error, whether the host is `amd64` or `arm64`, and whether this is a fresh install, normal day-2 operation, restore, reboot, or update transition.

Do **not** collect or paste plaintext SOPS values, Age private identities, recovery-kit passphrases, Cloudflare/SMTP/provider tokens, admin passwords/tokens, or CrowdSec bouncer credentials.

## See also

- [Install](INSTALL.md) — supported blank-host path and first-run ordering.
- [Configuration](CONFIGURATION.md) — accepted config keys, types/ranges, secrets scope, and restart behavior.
- [Operations](OPERATIONS.md) — normal day-2 commands and systemd automation.
- [Recovery](RECOVERY.md) — artifact roles, verification, restore, and disaster recovery.
- [Security](SECURITY.md) — control boundaries that troubleshooting must not weaken.
- [Cloudflare tokens](CLOUDFLARE-TOKENS.md) — token purposes, permissions, and scoping.
