# Ubuntu 24.04 disposable-host acceptance

This is a release gate, not a per-PR test controller. Run it on disposable Ubuntu 24.04 hosts for both `amd64` and `arm64` when those environments are available. Record unavailable architecture/provider resources as **NOT RUN**; do not replace missing real-host evidence with claims based on mocks.

Use a dedicated test domain, Cloudflare zone/tokens, notification provider account, SMTP credentials, rclone remote, dedicated storage volume/filesystem, and offline Age identity. Destroy/rotate test credentials after the gate as appropriate.

## Acceptance record

Record before starting:

```text
release/ref:
commit:
versions output:
host architecture: amd64 | arm64
Ubuntu image/build:
dedicated storage device/filesystem/mount:
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

## 1. Clean host, dedicated storage, and setup

Begin on a clean Ubuntu 24.04 host with a separate test storage filesystem/volume intended for persistent application/recovery state.

Run the supported first-run interface rather than substituting the low-level bootstrap:

```bash
sudo ./setup.sh install --domain vault.example.com --email admin@example.com
```

Repeat a separate acceptance case with `--auto` where noninteractive setup support is being released. Confirm `--auto` does not imply `--use-latest`.

Pass only when:

- Ubuntu 24.04 and the host architecture are accepted;
- required dependencies are installed/validated by setup;
- the dedicated storage filesystem is mounted and the persistent application/recovery state path resolves onto that filesystem rather than `/`;
- removing/hiding that mount causes startup/doctor to fail safely instead of creating persistent state on the root filesystem;
- the immutable release exists under `/opt/vaultwarden-oci/releases/<version>` and `current`/`vwctl` select it;
- operator config and encrypted secret authorities exist under `/etc/vaultwarden-oci` with narrow ownership/modes;
- setup leaves an explicit config/secrets -> start checkpoint rather than claiming success for an incompletely configured running service.

Restore the dedicated mount before continuing.

## 2. Explicit `--use-latest` freeze

On a separate disposable install, exercise the independent override:

```bash
sudo ./setup.sh install \
  --domain vault-latest.example.com \
  --email admin@example.com \
  --use-latest
```

Pass only when every mutable project/component/image boundary is resolved once to an exact immutable version/digest, the exact resolved values are recorded, and no installed config/state/image reference retains floating `latest` semantics.

Do not accept a workflow that writes `latest` and relies on later pulls to resolve it again.

## 3. SOPS/Age and recovery-kit custody

Create distinct operational and offline Age identities. Put only the operational private identity on the appliance; keep the offline private identity off-host. Encrypt the normal SOPS document to the required recipients and configure required test credentials.

Before first start:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
```

Exercise recovery-kit creation/handoff separately from `.vwrec` application recovery. Pass only when:

- the recovery kit is an AES-256 encrypted ZIP;
- its passphrase is entered and confirmed interactively;
- that passphrase is independent of stored credentials;
- the passphrase does not appear in argv, environment variables, files, email, logs, or captured process listings;
- the encrypted ZIP is fully verified before email is attempted;
- failed/declined email is reported truthfully without changing ZIP-verification truth;
- the offline Age private identity is not persistently stored on the server.

## 4. First start, dashboard, status, doctor, and logs

After configuration/secrets/storage checks pass:

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json | tee /tmp/vwoci-doctor.json
sudo vwctl logs --tail 50
```

Pass when the application is healthy and doctor has no `FAIL`. Preserve secret-free doctor JSON as evidence.

Then launch `dashboard.sh` as the supported day-2 human interface. Confirm the useful color-coded/AMTM-style interaction is functional and that any mutation selected from the dashboard delegates to `vwctl` rather than performing a second independent state mutation.

A dashboard presentation must not hide or reinterpret a doctor `FAIL`.

## 5. Caddy module set, real-client-IP trust, and origin firewall

Inspect the installed Caddy binary/module set. Pass only when the exact-pinned xcaddy build contains the required capabilities:

- Cloudflare DNS;
- Cloudflare trusted-proxy/real-client-IP support;
- combined Cloudflare IP ranges;
- Caddy rate limiting.

Inspect generated Caddy configuration. Pass only when Cloudflare client-IP trust is owned by the trusted-proxy module and there is no second generated static Cloudflare CIDR `trusted_proxies` block.

Then test the distinct host-level origin control:

- the `DOCKER-USER` path permits published HTTPS only from validated Cloudflare IPv4/IPv6 ranges;
- direct non-Cloudflare origin TCP/443 is denied;
- invalid current ranges plus unusable last-known-good state leaves origin HTTPS fail-closed;
- restoring a safe range policy restores supported ingress.

The Caddy trusted-proxy test and origin-filter test are separate acceptance conditions.

## 6. `/admin` defense in depth

Verify the supported lightweight stack:

- Vaultwarden admin token is required;
- Caddy rate limiting applies to `/admin`;
- exactly one simple outer authentication gate protects `/admin` before the application;
- no enterprise identity stack or redundant outer gate is required for acceptance.

## 7. CrowdSec Cloudflare remediation

Configure the supported CrowdSec web-remediation path and verify a safe test decision is enforced through Cloudflare.

Pass only when proxied web-client remediation occurs at Cloudflare and no CrowdSec host firewall bouncer is required. Do not confuse the separate `DOCKER-USER` Cloudflare source-range origin filter with CrowdSec remediation.

## 8. Notification API success and transient SMTP fallback

Configure one real built-in provider and trigger a controlled operational notification. Confirm API delivery succeeds without SMTP fallback for a successful request.

Exercise a catalog-declared transient case and confirm bounded retry plus authenticated SMTP fallback. For CyberPersons, the current status-only transient case is `503 service_unavailable`.

Also prove CyberPersons `429 rate_limit_exceeded` and `500 send_failed` are **not** SMTP-fallback eligible by status alone. Focused automated injection is acceptable when safely forcing those real provider responses is impractical.

Pass when permanent/auth/TLS/ambiguous outcomes remain visible and are not masked by SMTP.

## 9. Application recovery: backup -> rclone -> verify -> restore

Create known test vault state before backup.

```bash
sudo vwctl backup --remote 'REMOTE:vwoci-acceptance'
sudo vwctl status
```

Record the local `.vwrec` name/SHA-256 and independently confirm the remote object.

Exercise the supported guided human restore picker for both a local and a remote selection on disposable state. Confirm it delegates to the same authoritative restore implementation.

Also retain explicit noninteractive CLI acceptance for automation. For a running disposable target, first prove a safe preflight failure (for example, wrong offline identity) does not stop/corrupt the healthy service. Then perform a valid restore without pre-stopping the service:

```bash
sudo vwctl restore \
  --from-remote 'REMOTE:vwoci-acceptance/<artifact>.vwrec' \
  --identity /secure/offline-age-key.txt --start
sudo vwctl status
sudo vwctl doctor --json
```

Pass when publication succeeded only after remote verification, invalid input failed before destructive mutation, restored known state is present, and the operational Age private key was not embedded in the recovery point.

Test retention separately in plan mode before confirmed deletion.

## 10. systemd

Enable the installed lifecycle/timers only after setup/start acceptance:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

Pass when services/timers use the installed authoritative CLI and do not start the application against a missing dedicated storage filesystem.

## 11. Operator-driven application update

Prepare or discover a trusted stable candidate application release with exact immutable component/image values.

The required flow is:

```text
discover stable release
-> stage/download/build before downtime
-> verify pre-update recovery point
-> activate immutable release
-> health-gate
-> roll back coherently when safe
```

Where the current CLI source form is still used, validate it with:

```bash
cd /path/to/candidate
sudo vwctl update check --source "$PWD"
sudo vwctl update apply --source "$PWD"
sudo vwctl versions
sudo vwctl status
sudo vwctl doctor --json
```

Pass when candidate content is prepared before downtime where possible, a verified pre-update `.vwrec` exists, activation uses exact immutable values, health gating is truthful, and rollback behavior refuses unsafe binary-only downgrade after possible persistent-state mutation.

Verify automatic update **check/notification** if that release includes it. Unattended update **apply** must not be enabled by default.

## 12. Ubuntu package-update separation

Verify administrator documentation/tooling treats apt/kernel maintenance as a separate workflow from application updates/recovery. No application recovery claim may imply apt/kernel rollback, and no supported path may auto-reboot the host.

## 13. Cleanup and evidence

Collect only secret-free evidence: host/architecture, commit/version, dedicated-storage mount evidence, exact resolved version/digests where relevant, test command/result, doctor JSON, artifact hashes, and external verification notes.

Remove disposable hosts/state and acceptance-only remote objects through explicit deletion after evidence retention requirements are met. Rotate/revoke test tokens where appropriate.

Report each architecture as PASS, FAIL, or NOT RUN. Never convert unavailable `arm64`/external-provider evidence into PASS based on `amd64` or unit tests.

## Current development-branch applicability

At the time the durable contract was synchronized, the current development branch did not yet implement several mandatory acceptance surfaces: supported `setup.sh`, dedicated-storage enforcement, supported `dashboard.sh`, production `--use-latest` exact freezing, the full required Caddy module/trusted-proxy design, guided restore picker, and recovery-kit ZIP workflow.

Therefore a full host release acceptance against that snapshot must report those sections as **FAIL/not yet implementable**, not silently fall back to the superseded bootstrap contract. This document defines the release gate the implementation must converge on.
