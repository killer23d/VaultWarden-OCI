# Ubuntu 24.04 disposable-host acceptance

This is the real release gate, not an ordinary PR controller. Run it on disposable Ubuntu 24.04 hosts for both `amd64` and `arm64` when those environments are available. Record unavailable architecture/provider/destructive coverage as **NOT RUN**; CI mocks or container integrations do not turn missing real-host evidence into `PASS`.

The gate is intentionally appliance-sized for a small team: prove the supported operator paths and security ownership boundaries directly rather than inventing a second orchestration or migration layer just for acceptance.

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
pre-existing Vaultwarden Admin config: absent | reconciled | NOT RUN
Admin browser navigation/SMTP test: PASS | FAIL | NOT RUN
config/secrets edit restart prompt: PASS | FAIL | NOT RUN
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

## 3. Config/secrets, existing Admin policy, restart UX, and plaintext leakage

Use only `vwctl config edit/validate` and `vwctl secrets edit/validate` for normal configuration. Configure distinct operational/offline Age identities and required test credentials. For the terminal-auto-generated case, inspect root-owned volatile state before and after the recovery-kit handoff.

On a clean installation with no historical Vaultwarden Admin file, inspect the running container environment and prove `CONFIG_FILE=/tmp/vaultwarden-admin-config.json` with `/tmp` backed by the declared container tmpfs. Make a harmless Admin-panel setting change, use the supported restart path, and prove the web-only change does not become durable while the value rendered from `config.toml` remains authoritative.

On a separate disposable upgrade host, start from the exact supported predecessor and create a representative pre-existing `/var/lib/vaultwarden-oci/data/config.json` before the candidate update. Include at least one appliance-supported policy difference, such as organization creation restricted to `none`, and at least one harmless legacy-only key. Do not use production secrets as fixtures.

Exercise the exact candidate update and prove the bounded transition in order:

1. the candidate starts healthy without silently replacing the historical Admin policy;
2. the running container initially has `CONFIG_FILE=/data/config.json` and the representative historical supported policy is still effective;
3. `sudo vwctl config edit` reports the supported legacy/current difference without printing secret values and refuses finalization while the supported values differ;
4. after copying the intended supported value into `config.toml` (and using `secrets edit` for any relevant credential authority), the interactive flow names legacy-only/incompatible/sensitive keys by **name only**, asks for explicit finalization, and writes a root-only digest-bound reconciliation marker;
5. accepting the normal restart prompt makes the next runtime use `CONFIG_FILE=/tmp/vaultwarden-admin-config.json` while the historical file remains retained rather than being destructively deleted;
6. changing that retained historical file after finalization invalidates its digest binding and makes the reconciliation state pending again rather than silently ignoring newly persisted Admin policy; restore/reconcile the fixture before continuing;
7. a normal successful interactive `config edit` and `secrets edit` on the reconciled state offer the expected restart behavior, while non-TTY callers do not block on prompts.

**PASS:** encrypted authority is valid/decryptable by the operational identity; the offline private identity is not persistent server state; a setup-generated offline identity exists only in protected volatile storage until handoff and is absent afterward; process listings/logs/operator config/release files contain no plaintext credential leakage; clean installs use tmpfs Admin persistence; supported predecessor upgrades preserve pre-existing Admin policy until explicit reconciliation; finalization cannot occur while supported values differ; the marker is bound to the exact historical file; legacy-only/sensitive **values** are never displayed or persisted in the marker; and restart semantics are truthful. **FAIL:** an update silently discards historical Admin policy, an unfinalized legacy file is ignored, unsupported/sensitive values are printed, finalization bypasses supported differences, or web Admin changes remain a competing durable authority after reconciliation.

## 4. Exact custom Caddy, Cloudflare trust, and fail-closed origin

Inspect the installed Caddy module set and rendered configuration. Exercise real origin packets from permitted Cloudflare test context and a non-Cloudflare source where the environment permits it; also invalidate current and cached range input on disposable state.

**PASS:** exact-pinned Cloudflare DNS, trusted-proxy/client-IP, combined-range, and rate-limit capabilities are present; Caddy has one trusted-proxy authority; direct non-Cloudflare origin TCP/443 is denied; no safe range policy means fail-closed ingress.

## 5. `/admin` protection, normal navigation, SMTP test, and authentication rate limiting

With admin enabled, prove Vaultwarden admin token + Caddy rate limit + one outer auth gate. Exercise repeated test authentication requests from a safe source. In a browser, pass Caddy Basic Auth and then authenticate to Vaultwarden `/admin` using the original recoverable `vaultwarden_admin_token` from the supported custody path.

Navigate several normal Admin pages/actions in one minute and prove the supported outer interactive budget does not return a premature `429`. Confirm the rendered Caddy route uses the configured default `60` events / `1m` (or the explicitly configured accepted values), while Vaultwarden's own admin-login limiter remains the separate configured control. From the real browser Admin page, run Vaultwarden's SMTP test and prove it completes without the previous outer-route `429`/JSON-parse failure.

Also inspect the volatile runtime admin value only by shape: it must be an Argon2id PHC derived by the selected Vaultwarden image, not the plaintext source secret, and normal Vaultwarden logs must not contain the plaintext `ADMIN_TOKEN` warning.

**PASS:** unauthenticated outer access is rejected; valid outer auth still requires Vaultwarden admin authentication; the original recoverable source admin secret successfully authenticates through the application boundary; normal Admin navigation and the browser SMTP test do not prematurely exhaust the outer route; only an Argon2id PHC is materialized at runtime; configured outer and login-specific rate limiting remain independent; and a deliberately disabled admin route is closed rather than exposed. **FAIL:** the runtime PHC becomes the operator credential, the recoverable source secret no longer authenticates, plaintext admin material leaks, normal navigation hits the former false-positive rate limit, or the outer gate/rate limit can be bypassed.

## 6. Start, status, doctor, dashboard, and logs

```bash
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json | tee /tmp/vwoci-doctor.json
sudo vwctl logs --tail 50
sudo /opt/vaultwarden-oci/current/vaultwarden_oci/dashboard.sh
```

**PASS:** application healthy, doctor has no `FAIL`, dashboard accurately represents failures/warnings, and dashboard mutations delegate to `vwctl`. Human `status` may use the color dashboard on a TTY, while `status --json` and captured/non-TTY status remain machine-safe and retain the stable CLI contract used by update health gates.

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

## 9. Stable update, supported-predecessor handoff, config-owner transition, and rollback boundary

From a healthy installed release:

```bash
sudo vwctl update check
sudo vwctl update apply
sudo vwctl versions
sudo vwctl status
sudo vwctl doctor --json
```

**PASS for the ordinary stable path:** the project candidate is discovered/staged with exact immutable values before downtime where practical; a verified pre-update `.vwrec` exists before candidate-owned persistent-state mutation; activation health-gates; safely rollbackable pre-mutation failure restores the previous release coherently; and a post-possible-data-mutation failure refuses fake old-code-only rollback and identifies the verified recovery point as the downgrade boundary.

When the release deliberately supports a predecessor compatibility transition, exercise that transition from the exact documented predecessor rather than synthesizing arbitrary intermediate hops. Record each boundary separately:

1. **Pre-recovery Worker re-arm:** the predecessor's broader/legacy Cloudflare Worker policy is replaced by the supported local-source policy (`cscli`,`crowdsec`), the old Fail Open proof is invalidated, a new systemd invocation is created, and the update stops for explicit operator Fail Open confirmation before recovery or target data mutation.
2. **Controller handoff when required:** candidate code may pre-stage only the exact target update controller and publish the bounded handoff while `/opt/vaultwarden-oci/current` still points to the predecessor. Ordinary non-update commands continue to execute through the selected predecessor. The handoff does not advance recovery or silently activate the target.
3. **Target-owned retry:** rerunning the same installed update command through the staged target controller creates/verifies the pre-update recovery point, owns the bounded application-health settle window, and continues the transaction.
4. **Existing Admin-policy preservation:** when the predecessor has the representative `config.json` fixture from section 3, target activation keeps that exact historical file effective until explicit reconciliation. The update itself must not silently flip its supported policy to catalog defaults merely because the target owns a new steady-state config model.
5. **Forward-only host dependency boundary:** any explicitly permitted CrowdSec/logrotate compatibility package transition occurs only after candidate prevalidation and verified recovery. It is host state outside `.vwrec` rollback; no general apt upgrade, kernel update, package downgrade, or reboot is implied.
6. **Coherent failure and retry:** on disposable state inject a candidate failure after the permitted host dependency transition. Application rollback must restore a healthy predecessor without pretending to roll back apt state; CrowdSec ownership must remain approved; and retrying the same target must converge safely without destructive package cleanup.

**PASS:** every intentional stop names the next operator action; Worker source policy/invocation/Fail Open proof is never silently reused; `current` and installed launcher ownership are truthful at each handoff boundary; recovery occurs before forward-only host expansion; pre-existing Admin policy remains effective until the operator separately finalizes its reconciliation; the predecessor remains healthy after rollback with retained approved host state; and the same target succeeds on retry. **FAIL:** candidate checkout directly takes over ordinary commands, a stale Worker invocation/Fail Open confirmation is accepted, recovery advances during a pre-recovery handoff, generic package maintenance is folded into application update, historical Admin policy is silently replaced, or rollback claims to undo host package state it did not restore.

## 10. Explicit `--use-latest` exact freeze and source-aware identity

On separate disposable state:

```bash
sudo vwctl update check --use-latest
sudo vwctl update apply --use-latest
```

Also exercise `setup.sh ... --use-latest` on a separate disposable blank install, including the terminal-driven `--auto` path where applicable.

In addition to exact upstream refs/digests, prove source-aware immutable identity:

1. changing release-owned source bytes changes the `.latest` identity even when component/image pins are unchanged;
2. generated `__pycache__`/`.pyc` content does not affect identity and installed `vwctl` does not create bytecode inside immutable releases;
3. an already-frozen legacy latest source can be re-keyed locally without silently resolving a different upstream snapshot;
4. where a bounded predecessor controller handoff exists, a newer source-aware snapshot may supersede only an older **unselected, pre-recovery** handoff; it must not replace a selected release or a handoff that has crossed the recovery boundary.

**PASS:** every supported mutable upstream boundary is resolved once to exact refs/digests; exact release-owned source bytes participate in the frozen identity; cache artifacts do not; no installed image/config/state retains floating `latest` semantics; and supported long-option forms do not bypass setup warning/confirmation semantics.

## 11. Update-check timer, host upgrade, and reboot-required handling

```bash
sudo systemctl enable --now vaultwarden-oci.target
sudo vwctl timers
sudo vwctl host-upgrade check
sudo vwctl host-upgrade apply
```

**PASS:** automatic project **check/notification** works without unattended application apply; host package workflow remains separate except for an explicitly documented/tested supported-predecessor compatibility dependency transition from section 9; reboot-required state is surfaced when applicable; no supported path auto-reboots.

## 12. CrowdSec split remediation and representative notification path

Exercise the supported small-team protection split with real systemd/CrowdSec state:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
# Set every bouncer-created Cloudflare Worker Route to Fail Open.
sudo vwctl crowdsec confirm-fail-open
sudo vwctl doctor --json | tee /tmp/vwoci-crowdsec-doctor.json
sudo systemctl is-active crowdsec.service
sudo systemctl is-active crowdsec-firewall-bouncer.service
sudo systemctl is-enabled crowdsec-firewall-bouncer.service
sudo systemctl is-active crowdsec-cloudflare-worker-bouncer.service
sudo systemctl is-enabled crowdsec-cloudflare-worker-bouncer.service || true
```

Record secret-free live nftables evidence for both families and the Worker `InvocationID`. Verify the Worker configuration/attestation reports exactly the local decision sources `cscli` and `crowdsec`.

The supported ownership model is:

- CrowdSec engine + Hub collections detect Caddy, Vaultwarden, SSH/Linux, and kernel/firewall abuse;
- the nftables firewall bouncer is active and enabled for broad/community decisions on host `INPUT` only;
- it owns exactly the IPv4 `crowdsec-chain-input` and IPv6 `crowdsec6-chain-input` hooks and no `forward` hook;
- it never owns Docker `FORWARD` or `DOCKER-USER`;
- Docker/public 443 remains under the separate Cloudflare-only origin filter;
- the Cloudflare Worker handles local/proxied decisions only, is active for the explicitly armed invocation, remains boot-disabled, is attested to that exact invocation/config, and is Fail-Open-confirmed for that invocation.

Require these canonical doctor IDs to be `PASS`: `crowdsec.engine`, `crowdsec.hub`, `crowdsec.firewall`, and `crowdsec.cloudflare`.

Then exercise one real built-in operational HTTPS provider success, one documented transient path with SMTP fallback, and direct SMTP test. For CyberPersons, status-only transient is `503 service_unavailable`; `429` and `500 send_failed` must not become fallback-eligible by status alone. Inspect the delivered diagnostics: API success must identify the actual HTTPS provider route, direct SMTP must identify direct authenticated SMTP, and a real eligible fallback must identify authenticated SMTP fallback. The direct SMTP path must retain normal certificate/hostname validation regardless of Vaultwarden's application-specific invalid-certificate/hostname options.

**PASS:** all four CrowdSec checks pass; IPv4/IPv6 firewall ownership is exactly host INPUT-only; no CrowdSec rule claims `forward`/`DOCKER-USER`; the Worker is local-source-only, boot-disabled, invocation-attested, and Fail-Open-confirmed; the Cloudflare origin filter still exclusively owns Docker/public 443; successful notification API delivery does not invoke SMTP and truthfully labels the API route; eligible transient fallback is bounded and truthfully labelled; direct SMTP is truthfully labelled and uses strict TLS; and auth/TLS/permanent/ambiguous failures remain visible.

## 13. Evidence and cleanup

Collect only secret-free evidence: commit/version, architecture/Ubuntu build, storage identity/mount evidence, exact resolved pins, command/result, doctor JSON, artifact hashes, systemd invocation IDs, nftables hook names, reconciliation-marker digest/state (not secret values), and external verification notes. Do not record generated private identities, recovery-kit passphrases, admin plaintext credentials, SMTP passwords, bouncer API keys, or other plaintext secrets as acceptance evidence. Remove acceptance-only hosts/remote objects explicitly and rotate test credentials as appropriate.

Report each architecture and each external-provider section as `PASS`, `FAIL`, or `NOT RUN`. CI integration that builds Caddy, uses real Age/SOPS/rclone on temporary data, verifies an AES ZIP, or exercises Docker packet rules is valuable, but it is not a substitute for this disposable real-host gate.
