# Ubuntu 24.04 disposable-host acceptance

This is the real release gate, not an ordinary PR controller. Run it on disposable Ubuntu 24.04 hosts for both `amd64` and `arm64` when those environments are available. Record unavailable architecture/provider/destructive coverage as **NOT RUN**; CI mocks or container integrations do not turn missing real-host evidence into `PASS`.

## Acceptance record

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
setup custody mode: interactive | terminal-auto-generated | explicit-recipient | headless-refusal
started at:
completed at:
result: PASS | FAIL | NOT RUN
notes:
```

A release is not accepted for an architecture unless every applicable mandatory section passes.

## 1. Clean install, auto custody, and root-only refusal

On clean hosts with real separate data volumes, exercise the supported `setup.sh` path from [Install](INSTALL.md) with all applicable first-run custody boundaries:

1. one normal interactive install;
2. one interactive-terminal `--auto` install with no `--offline-recipient` on a host where `age-keygen` is initially absent, proving setup bootstraps/verifies the Ubuntu `age` tooling before private-identity generation and before dedicated-storage provisioning, then completes setup-generated offline custody and verified recovery-kit handoff;
3. one interactive-terminal `--auto` install with an explicit offline recipient, including at least one normal value form such as `--offline-recipient=age1...`, proving the supplied recipient is preserved and no replacement identity is generated;
4. one fully headless `--auto` invocation without an offline recipient, proving it fails before storage provisioning or other installation mutation;
5. on separate disposable/root-only state, attempt setup without acceptable separate storage.

Where practical, also force the pre-custody Age bootstrap to fail on disposable state (for example with package access intentionally unavailable) and prove setup stops before generating an offline private identity or provisioning the data device.

**PASS:** supported OS/architecture accepted; root-only production install refused; real dedicated volume is mounted at `/var/lib/vaultwarden-oci`; immutable release/current/vwctl/config/secrets exist with correct ownership; a clean host without preinstalled `age-keygen` reaches the setup-owned Age bootstrap before private-key generation and storage provisioning; terminal-driven `--auto` without a recipient reaches the verified recovery-kit handoff and removes its transient offline identity after successful custody; an explicit recipient reaches installed config/secrets unchanged and is not replaced; fully headless `--auto` without a recipient fails before storage provisioning; a failed Age bootstrap creates no private identity and does not provision the data device; setup stops at a truthful external-config/custody checkpoint. **FAIL:** any silent persistent-state fallback to `/`, explicit-recipient substitution, headless generated private identity, private-identity generation before required Age tooling is verified, data-device provisioning after a failed Age bootstrap, install mutation before missing headless custody is rejected, or false success.

## 2. Dedicated-volume identity, boot guard, and restart safety

Record `findmnt`, UUID/type, `/etc/vaultwarden-oci/storage-identity.json`, and the volume marker. Start successfully, then on disposable state hide/unmount the intended volume and exercise boot/service restart safeguards.

**PASS:** start/doctor/mutating paths fail safely and Docker/systemd do not recreate persistent appliance paths on root. Restore the intended volume before continuing.

## 3. Config/secrets and plaintext leakage

Use only `vwctl config edit/validate` and `vwctl secrets edit/validate` for normal configuration. Configure distinct operational/offline Age identities and required test credentials. For the terminal-auto-generated case, inspect root-owned volatile state before and after the recovery-kit handoff.

**PASS:** encrypted authority is valid/decryptable by the operational identity, the offline private identity is not persistent server state, a setup-generated offline identity exists only in protected volatile storage until handoff and is absent afterward, and process listings/logs/operator config/release files contain no plaintext credential leakage.

## 4. Exact custom Caddy, Cloudflare trust, and fail-closed origin

Inspect the installed Caddy module set and rendered configuration. Exercise real origin packets from permitted Cloudflare test context and a non-Cloudflare source where the environment permits it; also invalidate current and cached range input on disposable state.

**PASS:** exact-pinned Cloudflare DNS, trusted-proxy/client-IP, combined-range, and rate-limit capabilities are present; Caddy has one trusted-proxy authority; direct non-Cloudflare origin TCP/443 is denied; no safe range policy means fail-closed ingress.

## 5. `/admin` protection and authentication rate limiting

With admin enabled, prove Vaultwarden admin token + Caddy rate limit + one outer auth gate. Exercise repeated test authentication requests from a safe source.

**PASS:** unauthenticated outer access is rejected, valid outer auth still requires the application token as designed, and configured rate limiting applies. A deliberately disabled admin route must be closed rather than exposed.

## 6. Start, status, doctor, dashboard, and logs

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json | tee /tmp/vwoci-doctor.json
sudo vwctl logs --tail 50
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

**PASS:** application healthy, doctor has no `FAIL`, dashboard accurately represents failures/warnings, and dashboard mutations delegate to `vwctl`.

## 7. Backup -> verify -> rclone -> guided restore

Create known vault state, then:

```bash
sudo vwctl backup --remote 'REMOTE:vwoci-acceptance'
sudo vwctl recovery list --remote 'REMOTE:vwoci-acceptance'
```

Record the local `.vwrec` SHA-256 and independently confirm/verify the remote object. Exercise a wrong offline identity first and prove it fails before live mutation. Then exercise guided local restore and guided remote restore on disposable dedicated storage; retain one explicit noninteractive restore case.

**PASS:** offsite success only after remote verification; bad preflight does not stop/corrupt healthy state; valid restore returns known state; operational Age private key is absent from `.vwrec`; status/doctor pass afterward.

## 8. Complete recovery-kit AES-256 ZIP and SMTP email path

Run complete export with the matching offline identity. Also exercise the first-run terminal-generated recovery-kit path from section 1. Inspect process/log/filesystem behavior and exercise SMTP email handoff where a real test account is available.

**PASS:** exact documented member set, AES-256 encryption, correct-password test succeeds, wrong/empty/no-password tests fail, passphrase never appears in argv/env/file/email/logs, ZIP verification completes before SMTP, email failure is reported as email failure rather than archive-verification failure, the first-run generated kit contains the generated credential values plus both Age private identities, and the setup-generated offline private identity is removed from host-side volatile storage only after successful custody handoff. If handoff is deliberately declined/fails, the transient identity remains protected and setup reports truthful recovery guidance instead of claiming success.

## 9. Normal stable application update and rollback boundary

From a healthy installed release:

```bash
sudo vwctl update check
sudo vwctl update apply
sudo vwctl versions
sudo vwctl status
sudo vwctl doctor --json
```

**PASS:** stable project candidate is discovered/staged with exact immutable values before downtime where practical; verified pre-update `.vwrec` exists; activation health-gates; a safely rollbackable pre-mutation failure returns coherently; a post-possible-data-mutation failure refuses fake old-code-only rollback and identifies the recovery point as the downgrade boundary.

## 10. Explicit `--use-latest` exact freeze

On separate disposable state:

```bash
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

Also exercise `setup.sh ... --use-latest` on a separate disposable blank install, including the terminal-driven `--auto` path where applicable.

**PASS:** every supported mutable upstream boundary is resolved once to exact refs/digests and no installed image/config/state retains floating `latest` semantics. Supported long-option forms must not bypass the setup warning/confirmation semantics.

## 11. Update-check timer, host upgrade, and reboot-required handling

```bash
sudo systemctl enable --now vaultwarden-oci.target
sudo vwctl timers
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

**PASS:** automatic project **check/notification** works without unattended application apply; host package workflow remains separate; reboot-required state is surfaced when applicable; no supported path auto-reboots.

## 12. CrowdSec/Cloudflare and representative notification path

Exercise CrowdSec detection/decision with Cloudflare remediation on a safe test client. Exercise one real built-in operational HTTPS provider success, one documented transient path with SMTP fallback, and direct SMTP test. For CyberPersons, status-only transient is `503 service_unavailable`; `429` and `500 send_failed` must not become fallback-eligible by status alone.

**PASS:** Cloudflare remediation works without a host CrowdSec firewall bouncer; successful API does not invoke SMTP; eligible transient behavior is bounded; auth/TLS/permanent/ambiguous failures remain visible.

## 13. Evidence and cleanup

Collect only secret-free evidence: commit/version, architecture/Ubuntu build, storage identity/mount evidence, exact resolved pins, command/result, doctor JSON, artifact hashes, and external verification notes. Do not record generated private identities, recovery-kit passphrases, or plaintext credentials as acceptance evidence. Remove acceptance-only hosts/remote objects explicitly and rotate test credentials as appropriate.

Report each architecture and each external-provider section as `PASS`, `FAIL`, or `NOT RUN`. CI integration that builds Caddy, uses real Age/SOPS/rclone on temporary data, verifies an AES ZIP, or exercises Docker packet rules is valuable, but it is not a substitute for this disposable real-host gate.