# Ubuntu 24.04 disposable-host acceptance

This is a **release gate**, not a per-PR test controller. Run it on disposable Ubuntu 24.04 hosts for both `amd64` and `arm64` when those environments are available. Record unavailable architecture/provider resources as **not run**; do not replace missing real-host evidence with claims based on mocks.

Use a dedicated test domain, Cloudflare zone/tokens, notification provider account, SMTP credentials, rclone remote, and offline Age identity. Destroy/rotate test credentials after the gate as appropriate.

## Acceptance record

Record before starting:

```text
release/ref:
commit:
versions output:
host architecture: amd64 | arm64
Ubuntu image/build:
Docker/Compose version:
Cloudflare test zone:
notification provider:
rclone remote/path:
offline Age identity custody verified: yes/no
started at:
completed at:
result: PASS/FAIL/NOT RUN
notes:
```

A release is not accepted for an architecture unless every applicable mandatory section passes.

## 1. Clean host and install/layout

On a clean Ubuntu 24.04 host, follow [INSTALL.md](INSTALL.md) from its prerequisite section rather than assuming tools are preinstalled. Before bootstrap, record:

```bash
. /etc/os-release
printf '%s %s\n' "$ID" "$VERSION_ID"
uname -m
python3 --version
sudo docker version
sudo docker compose version
age --version
sops --version
rclone version
iptables --version
ip6tables --version
```

Then install V2:

```bash
sudo ./bootstrap-v2.sh
readlink -f /opt/vaultwarden-oci/current
readlink -f /usr/local/bin/vwctl
sudo find /etc/vaultwarden-oci -maxdepth 1 -printf '%M %u:%g %p\n'
sudo find /var/lib/vaultwarden-oci -maxdepth 2 -printf '%M %u:%g %p\n' | sort
systemctl cat vaultwarden-oci.service
```

Inspect `/etc/vaultwarden-oci/config.toml` before editing it. Pass when the immutable release exists under `/opt/vaultwarden-oci/releases/<version>`, `current` and `/usr/local/bin/vwctl` resolve to it, the fresh config contains the complete beta schema rather than a phase placeholder, V2 systemd units are installed, and no V1 runtime/dashboard/Postfix unit is installed by V2.

## 2. SOPS/Age and no-leak materialization

Create distinct operational and offline Age identities. Put only the operational private identity at `/etc/vaultwarden-oci/age-key.txt`; put only the offline public recipient in config. Encrypt `secrets.sops.yaml` to both recipients and configure required secrets plus test notification credentials.

Before start:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
```

Start and inspect volatile material:

```bash
sudo vwctl start
sudo find /run/vaultwarden-oci -maxdepth 3 -printf '%M %u:%g %p\n' | sort
```

Pass when `secrets.custody` and `secrets.decrypt` pass; required component secrets exist only in the intended `/run/vaultwarden-oci/secrets` mounts; `email_api_token` and `cloudflare_remediation_token` are not materialized there; plaintext secrets are absent from `/opt/vaultwarden-oci`, `config.toml`, generated Compose/Caddy files, journal output, and recovery state JSON.

Use bounded searches for **known test secret values** rather than generic strings. Do not print real production secrets into a release record.

## 3. Start/status/doctor/logs

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json | tee /tmp/vwoci-doctor.json
sudo vwctl logs --tail 50
```

Pass when Vaultwarden and Caddy are running/healthy and doctor has no `FAIL`. Preserve the JSON as release evidence after reviewing it for secret-free output.

## 4. Cloudflare origin fail-closed and CrowdSec Cloudflare remediation

Run the bounded local packet test on the disposable host:

```bash
sudo tests/v2/acceptance_edge_packet.sh
```

Then test the real edge path:

```bash
sudo vwctl edge refresh
sudo iptables -w -n -L DOCKER-USER
sudo ip6tables -w -n -L DOCKER-USER
```

From outside the origin, verify the public application works through Cloudflare. Verify a direct non-Cloudflare path to origin TCP/443 is denied. In a controlled window, invalidate/block the current Cloudflare CIDR fetch **and** make any LKG unusable; invoke refresh/start and verify it fails while published 443 remains guarded. Restore normal network/LKG state afterward.

Configure CrowdSec beta remediation:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
```

In Cloudflare, verify every Worker Route created by this invocation is **Fail Open**, then:

```bash
sudo vwctl crowdsec confirm-fail-open
sudo vwctl crowdsec status
sudo vwctl doctor --json
```

Create a safe test web decision through the supported CrowdSec tooling and verify Cloudflare remediation appears/acts as expected. Pass only if remediation is Cloudflare-side and no V2 host firewall bouncer is required.

## 5. Notification API success and transient SMTP fallback

Configure one real built-in provider. For CyberPersons use canonical `cyberpersons` (or verify the `cyberpanel` alias resolves to it), an API key with `can_send`, a verified sending domain, SOPS `email_api_token`, and independent authenticated SMTP credentials if using its SMTP fallback.

Trigger one controlled V2 notification event and confirm API delivery succeeds with no SMTP fallback. Review `vwctl status` / `vwctl doctor --json` for secret-free persisted status.

For a representative fallback test, use a disposable/test provider condition that produces a **catalog-declared transient** response without changing operator endpoint authority. For CyberPersons, the current status-only transient is `503 service_unavailable`. Confirm bounded API retries occur and authenticated TLS SMTP fallback sends once afterward.

Also prove that CyberPersons `429 rate_limit_exceeded` and `500 send_failed` are **not** treated as SMTP-fallback eligible by status alone. A focused automated test is acceptable when safely forcing those provider responses is unavailable. Current provider documentation uses 429 for account-wide minute/hour/day/month limits shared by API and SMTP credentials, so do not reinterpret an arbitrary 429 as a transient acceptance condition.

Pass when permanent/auth/TLS/ambiguous outcomes remain visible and are not masked by SMTP.

## 6. Provider catalog validation

```bash
python3 -m unittest tests.v2.test_notification tests.v2.test_notification_security -v
sudo vwctl doctor --json
```

Pass when the catalog has exactly the six canonical built-ins, `cyberpanel -> cyberpersons`, exact canonical message fields, HTTPS/closed endpoint authority, and configured provider/options validate. Re-check current official provider documentation used by the release when catalog metadata changed.

## 7. Recovery: backup -> rclone -> verify -> download -> restore

Create known test vault state before the backup.

```bash
sudo vwctl backup --remote 'REMOTE:vwoci-acceptance'
sudo vwctl status
```

Record the local artifact name/SHA-256 and independently list the remote object.

If the disposable target is already running, first prove the preflight-before-stop guarantee with a deliberately wrong offline identity or other safe preflight failure. Invoke restore **without pre-stopping the service**, expect restore to fail, then verify `sudo vwctl status` still reports the running target healthy. Do not manufacture a failure after promotion begins.

For the valid restore, use a clean target host or deliberately prepared disposable V2 target state and again do **not** run `vwctl stop` first:

```bash
sudo vwctl restore \
  --from-remote 'REMOTE:vwoci-acceptance/<artifact>.vwrec' \
  --identity /secure/offline-age-key.txt --start
sudo vwctl status
sudo vwctl doctor --json
```

Pass when publication succeeded only after remote re-download/checksum verification; invalid recovery input failed before stopping a healthy running target; the valid restore preflight completed before mutation/downtime; the restored known vault state is present; the operational Age private key was not inside the artifact; and the restored service passes status/doctor.

Test prune separately in plan mode before any confirmed deletion:

```bash
sudo vwctl recovery prune --remote 'REMOTE:vwoci-acceptance' --keep-last 1
```

## 8. systemd

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl is-active vaultwarden-oci.service
systemctl list-timers 'vaultwarden-oci-*'
systemctl cat vaultwarden-oci-health.service
systemctl cat vaultwarden-oci-backup.service
systemctl cat vaultwarden-oci-maintenance.service
```

Manually invoke each oneshot where safe and inspect its journal. Pass when lifecycle plus health/backup/maintenance timers use the installed `current/vwctl` authority and failure notifications use the V2 notify template.

## 9. Pinned update

Prepare a trusted candidate release with a **new** `vaultwarden_oci.version` and exact `versions.toml` pins.

```bash
cd /path/to/candidate
sudo vwctl update check --source "$PWD"
sudo vwctl update apply --source "$PWD"
readlink -f /opt/vaultwarden-oci/current
sudo vwctl versions
sudo vwctl status
sudo vwctl doctor --json
```

Pass when update check reports exact candidate versions/digests; apply creates/gates a pre-update recovery point; the immutable release changes; activation uses exact pins; and post-update status/doctor pass. Do not use `--use-latest` for this gate.

## 10. Cleanup and evidence

Collect only secret-free evidence: host/architecture, commit/version, test command/result, doctor JSON, artifact hashes, and external verification notes. Remove disposable host/state and acceptance-only remote objects through explicit deletion after evidence retention requirements are met. Rotate/revoke test tokens where appropriate.

Report each architecture as PASS, FAIL, or NOT RUN. Never convert an unavailable `arm64`/external-provider run into PASS based on `amd64` or unit tests alone.
