# CrowdSec and Cloudflare Workers — VaultWarden-OCI

VaultWarden-OCI runs CrowdSec on the Ubuntu host and uses two bouncer paths:

1. `crowdsec-firewall-bouncer` for host firewall enforcement of CrowdSec decisions.
2. `crowdsec-cloudflare-worker-bouncer` for synchronizing the configured locally generated decisions to Cloudflare Workers KV so the deployed Worker can block at the edge.

This is the current architecture. Do not use older project guidance that describes Fail2Ban or Cloudflare WAF Custom Rules/Rulesets API updates as the normal web-ban path.

Related docs: [SECURITY.md](SECURITY.md) · [DEPLOYMENT.md](DEPLOYMENT.md) · [OPERATIONS.md](OPERATIONS.md)

## Architecture

```text
Vaultwarden/Caddy/SSH logs
           |
           v
      CrowdSec engine
       (host systemd)
           |
           +-----------------------------+
           |                             |
           v                             v
crowdsec-firewall-bouncer   crowdsec-cloudflare-worker-bouncer
           |                             |
           v                             v
 host firewall decisions       Cloudflare Workers KV
                                         |
                                         v
                                Cloudflare Worker route
                                         |
                                         v
                                edge allow / block result
```

The firewall bouncer consumes CrowdSec decisions at the host. For proxied HTTP traffic, the network peer at the origin is Cloudflare; Workers/KV enforcement is the path that can block the real web attacker before origin using the configured locally generated decision set.

The Workers bouncer intentionally restricts the free-plan-aware synchronization path to locally generated decisions so Workers KV write budget is not consumed by broad community blocklist churn. The current setup code owns this filtering behavior.

## Supported host boundary

CrowdSec setup is part of the Ubuntu 24.04 LTS Noble production path on amd64 and arm64.

The setup utility explicitly maps the Cloudflare Workers bouncer release architecture for:

```text
amd64 / x86_64
arm64 / aarch64
```

Unknown architectures fail closed.

## Normal setup

Complete the normal project setup first:

```bash
sudo ./setup.sh install \
  --domain vault.example.com \
  --email admin@example.com \
  --auto
```

Set the Cloudflare/CrowdSec SOPS secrets:

```bash
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./edit-secrets.sh rotate cloudflare_zone_id
sudo ./edit-secrets.sh rotate cf_account_id
```

The normal setup path installs/reconciles CrowdSec. To run the CrowdSec installer directly:

```bash
sudo ./utilities/setup-crowdsec.sh
```

The utility requires root for real installation/mutation. Use:

```bash
sudo ./utilities/setup-crowdsec.sh --help
```

for the exact current options.

## Optional security-event email

CrowdSec security-event email is opt-in and disabled by default:

```bash
CROWDSEC_EMAIL_NOTIFICATIONS=false
```

To enable it, edit the normal non-secret environment and run the existing
root-operated CrowdSec reconciliation path:

```bash
sudo make edit-env
# Set CROWDSEC_EMAIL_NOTIFICATIONS=true
sudo ./utilities/setup-crowdsec.sh
```

The delivery route is deliberately narrow:

```text
CrowdSec host service
        -> 127.0.0.1:587
        -> existing VaultWarden Postfix sidecar
        -> authenticated/TLS upstream SMTP relay
```

The generated `/etc/crowdsec/notifications/vaultwarden-email.yaml` uses
`SMTP_FROM` and `ADMIN_EMAIL` only as addressing values. It contains no SMTP
password, upstream relay credential, or email API token. The unauthenticated,
unencrypted submission hop is permitted only on the existing loopback-only
Postfix publication; do not expose port 587 on a public interface.

Setup writes only the marked plugin file and the marked
VaultWarden-OCI block in `/etc/crowdsec/profiles.yaml.local`. Operator content
outside that block is retained. Static configuration validation uses the
CrowdSec 1.7-supported command before the service restart:

```bash
sudo crowdsec -t
```

Normal setup does not attempt live mail delivery and does not require Postfix
to be running. After the application stack is up, request an end-to-end test
explicitly:

```bash
sudo cscli notifications test vaultwarden_email
```

That command submits through the same `127.0.0.1:587` Postfix route and returns
nonzero when delivery fails. Inspect the exact failure with:

```bash
sudo cscli notifications inspect vaultwarden_email
sudo journalctl -u crowdsec -n 100 --no-pager
sudo make health
```

Health reports disabled, missing-plugin, missing-profile, invalid, configured,
and statically valid states separately. A disabled optional notification is a
healthy state and does not generate a warning. Health does not send a live
notification test on every run.

To disable the feature, set the option back to `false` and reconcile again:

```bash
sudo make edit-env
# Set CROWDSEC_EMAIL_NOTIFICATIONS=false
sudo ./utilities/setup-crowdsec.sh
```

Only marked VaultWarden-OCI content is removed. An unmarked file at the managed
plugin path is treated as an operator conflict and is neither overwritten nor
deleted.

## Secret source

The CrowdSec Workers credentials are SOPS keys in:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

Canonical keys:

```text
cf_worker_bouncer_token
cloudflare_zone_id
cf_account_id
```

The setup/Workers apply path reads the encrypted secret source through the repository secret helpers. Do not copy tokens into a persistent `${PROJECT_STATE_DIR}/secrets/.docker_secrets` directory or document that stale path as the credential source.

Transient decoded project secret material belongs under:

```text
/run/vaultwarden-oci/secrets/
```

when the runtime secret materialization path needs it.

## Cloudflare token/account requirements

The Workers bouncer needs Cloudflare credentials that allow the repository's deployed Workers/KV integration to manage the required account/zone resources.

Use a dedicated token scoped as narrowly as practical to the account/zone and Worker/KV operations required by the current bouncer release and repository setup path.

Cloudflare permission labels can change over time. Use the current setup output and the upstream bouncer/Cloudflare dashboard permission names rather than copying old `Zone:Firewall Services:Edit`-only guidance from the previous WAF API architecture.

The SOPS schema label for `cf_worker_bouncer_token` may lag Cloudflare's current dashboard wording; the executable architecture is Workers/KV, not WAF Custom Rules.

## Apply configuration after credential rotation

After rotating Workers credentials or IDs:

```bash
sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
sudo ./utilities/crowdsec-worker-apply.sh
```

The secret schema's `crowdsec_worker_config` apply contract owns the same configuration direction for:

```text
cf_worker_bouncer_token
cloudflare_zone_id
cf_account_id
```

Do not restart unrelated containers to "apply" Workers credentials.

## Worker route fail-open setting

After the Worker route is deployed, configure the Cloudflare route request-limit failure mode to **Fail open**.

Why: an edge enforcement component should not turn a Cloudflare Worker/KV quota or transient Worker failure into a total Vaultwarden outage for this small-team appliance.

The Worker continues to block IPs present in KV during normal operation. Fail-open is the availability choice for the route's platform/request-limit failure mode, not a request to disable CrowdSec enforcement.

Verify the setting in the Cloudflare dashboard for the route attached to the Vaultwarden hostname.

## Firewall bouncer

The firewall bouncer is a host systemd service:

```bash
sudo systemctl status crowdsec-firewall-bouncer
```

The installed configuration is under the CrowdSec bouncer configuration tree, normally:

```text
/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

The setup utility reconciles the local API URL when CrowdSec LAPI must move because its configured loopback port is occupied.

The firewall bouncer receives the CrowdSec decision stream. Do not describe it as SSH-only.

For Cloudflare-proxied web traffic, host firewall decisions against the original client IP are not the same as edge blocking because the origin connection comes from Cloudflare. The Workers/KV path is the supported real-client edge enforcement for the configured web decision flow.

## CrowdSec LAPI port conflicts

The setup utility checks the configured CrowdSec LAPI loopback port before/after service start.

When the port is occupied, the current setup can:

1. identify the listener when `ss`/`lsof` can show it;
2. choose a free loopback port starting from the current project range;
3. update CrowdSec local API credentials and both bouncer configs;
4. restart/recheck CrowdSec.

Check current state with:

```bash
sudo ss -tlnp | grep crowdsec
sudo systemctl status crowdsec
sudo journalctl -xeu crowdsec --no-pager | tail -50
```

Do not expose CrowdSec LAPI publicly merely to resolve a local port conflict. The normal appliance uses loopback LAPI access.

## Log acquisition

CrowdSec acquisition is configured through the repository's `crowdsec/acquis.yaml` and installed CrowdSec state.

The normal setup path installs and reconciles this collection set:

```text
crowdsecurity/caddy
crowdsecurity/linux
crowdsecurity/iptables
Dominic-Wagner/vaultwarden
```

The intended signal sources are the project's current Vaultwarden/Caddy logs and host SSH authentication logs.

Check acquisition/metrics:

```bash
sudo cscli metrics
sudo cscli collections list
sudo cscli parsers list
sudo cscli scenarios list
```

If a log path changes, update the owning environment/acquisition configuration and verify CrowdSec metrics. Do not add another log-copy daemon simply to preserve an old path.

## Admin IP allowlist

Use the setup utility for the persistent administrator allowlist:

```bash
sudo ./utilities/setup-crowdsec.sh --admin-ip <ip-or-cidr>
```

Examples:

```bash
sudo ./utilities/setup-crowdsec.sh --admin-ip 203.0.113.10
sudo ./utilities/setup-crowdsec.sh --admin-ip 203.0.113.0/24
```

The setup path owns the persistent parser/allowlist representation so it survives normal CrowdSec hub updates.

Do not use the result of an untrusted remote `curl` service as formatting consent or as a substitute for verifying your current administrative source IP.

## Normal operations

### Service status

```bash
sudo systemctl status crowdsec
sudo systemctl status crowdsec-firewall-bouncer
sudo systemctl status crowdsec-cloudflare-worker-bouncer
```

### Logs

```bash
sudo journalctl -u crowdsec -f
sudo journalctl -u crowdsec-firewall-bouncer -f
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -f
```

### Decisions

```bash
sudo cscli decisions list
```

Add a temporary manual decision:

```bash
sudo cscli decisions add \
  --ip 203.0.113.20 \
  --duration 24h
```

Delete a decision:

```bash
sudo cscli decisions delete --ip 203.0.113.20
```

### Alerts and metrics

```bash
sudo cscli alerts list --since 24h
sudo cscli metrics
sudo cscli bouncers list
```

Project helpers:

```bash
sudo make crowdsec-status
sudo make crowdsec-alerts
sudo make security-report
```

## Verify Workers synchronization

Check the Workers bouncer service:

```bash
sudo systemctl is-active crowdsec-cloudflare-worker-bouncer
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 100 --no-pager
```

Check bouncer registration:

```bash
sudo cscli bouncers list
```

Create a short-lived test decision only from a safe test IP plan that cannot lock out the current administrator. Then verify:

1. CrowdSec shows the decision;
2. the Workers bouncer logs its processing/sync behavior;
3. the deployed Worker/KV state reflects the decision according to the bouncer's current key format;
4. the decision expires or is removed;
5. the administrative allowlist remains effective.

Do not test by banning the only current SSH/operator source IP.

## Host firewall and Cloudflare CIDR refresh

The CrowdSec bouncers and the project's Cloudflare-origin UFW rules are different controls.

Refresh the host Cloudflare CIDR allowlist through:

```bash
sudo ./maintenance.sh update-firewall
```

or:

```bash
sudo make maintenance-full
```

`maintenance-update-firewall.sh` uses the shared operation guard. Active-operation contention returns exit `75` for the owning systemd/aggregate maintenance contract.

The host firewall refresh fetches Cloudflare's current CIDR lists and uses a bounded last-known-good cache. It refuses to apply stale/absent CIDR data as a normal successful refresh.

## Troubleshooting

### CrowdSec is inactive

```bash
sudo systemctl status crowdsec --no-pager -l
sudo journalctl -xeu crowdsec --no-pager | tail -100
sudo ss -tlnp
```

Re-run the supported setup after fixing the reported dependency/configuration problem:

```bash
sudo ./utilities/setup-crowdsec.sh
```

### Firewall bouncer is inactive

```bash
sudo systemctl status crowdsec-firewall-bouncer --no-pager -l
sudo journalctl -u crowdsec-firewall-bouncer -n 100 --no-pager
sudo cscli bouncers list
```

Check that its LAPI URL matches the current CrowdSec loopback port.

### Workers bouncer is inactive

```bash
sudo systemctl status crowdsec-cloudflare-worker-bouncer --no-pager -l
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 100 --no-pager
sudo cscli bouncers list
```

Reapply current SOPS-backed Worker configuration:

```bash
sudo ./utilities/crowdsec-worker-apply.sh
```

### Decisions exist but edge blocks do not appear

Check:

```bash
sudo cscli decisions list
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 150 --no-pager
```

Then verify the Cloudflare Worker route and KV resources associated with the configured account/zone.

Remember that the project intentionally synchronizes the configured locally generated decision set for the free-plan-aware path. A broad community decision not selected by the current filter is not proof that the bouncer is broken.

### Administrator locked out of the web vault

From SSH/provider console:

```bash
sudo cscli decisions delete --ip <admin-ip>
sudo ./utilities/setup-crowdsec.sh --admin-ip <admin-ip-or-cidr>
```

Do not disable CrowdSec permanently as the first recovery step.

## Updates

CrowdSec and both bouncer versions are pinned in the repository environment template.

The setup path supports explicit version/update behavior documented by its current `--help`. Do not change the production pins to mutable `latest` values in `.env` as a generic update method.

After intentional CrowdSec/bouncer changes:

```bash
sudo ./utilities/setup-crowdsec.sh
sudo make health
sudo ./utilities/smoke-test.sh
```

## Security notes

- Keep Workers/KV tokens in SOPS, not `.env`.
- Keep CrowdSec LAPI on loopback for the normal appliance path.
- Use a persistent admin allowlist before testing decisions.
- Do not treat the firewall bouncer as SSH-only.
- Do not describe the Workers bouncer as a WAF Rulesets API updater.
- Keep the Cloudflare Worker route fail-open platform/request-limit behavior configured as documented.
- Use the host firewall CIDR refresh path separately from CrowdSec decisions.
- Verify both bouncers after restore or credential rotation.
- Preserve the project scope: CrowdSec + two bouncers is sufficient; do not add a second SIEM/firewall orchestration platform without a demonstrated defect.
