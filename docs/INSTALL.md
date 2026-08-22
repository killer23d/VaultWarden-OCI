# Install

## Supported production host

VaultWarden-OCI supports Ubuntu 24.04 LTS only, on `amd64` or `arm64`.

Production persistent application state **must** live on a dedicated filesystem/volume separate from the boot/root filesystem. A root-only host is not a supported production installation. The setup path must verify that the configured state location is backed by the intended dedicated storage and fail safely if that storage is absent or unsuitable.

The appliance is cloud-provider neutral. Provider firewalls/security groups remain outside this repository and must allow only the traffic you intend to expose.

## Normal first-run path

The supported first-run interface is `setup.sh`.

Its production responsibility is to:

1. validate Ubuntu 24.04, architecture, and dedicated storage;
2. install required host dependencies;
3. install the immutable appliance release;
4. prepopulate normal operator configuration from supplied inputs;
5. assist operational/offline Age and secret custody plus recovery-kit handoff;
6. leave an explicit config/secrets -> start sequence rather than silently starting an incompletely configured appliance.

Interactive setup is the normal human path. `--auto` is the noninteractive setup mode. `--use-latest` is a separate explicit override and **must not** be implied by `--auto`.

Example intended forms:

```bash
sudo ./setup.sh install --domain vault.example.com --email admin@example.com
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --auto
sudo ./setup.sh install --domain vault.example.com --email admin@example.com --use-latest
```

When `--use-latest` is requested, setup resolves each mutable upstream/project boundary once, freezes exact immutable versions/digests, records those resolved values, and uses only those exact values downstream. It must never leave a floating `latest` tag or other mutable resolution state in the installed appliance.

## Dedicated storage acceptance

Before installation, identify the dedicated production filesystem/volume intended for application state. The setup implementation may choose its exact flags and mount path, but the acceptance conditions are fixed:

- the persistent state location is on a mounted filesystem distinct from `/`;
- the mount is present before application services may start;
- a missing/wrong mount fails closed rather than allowing state to fall back onto the root filesystem;
- ownership/modes are prepared for the appliance without widening host access;
- recovery-state and application-state paths share this production storage invariant.

A removable or ephemeral mount that can disappear during normal operation is not an acceptable production substitute.

## Installed authorities

The durable installed authorities are:

```text
/opt/vaultwarden-oci/releases/<version>  immutable release content
/opt/vaultwarden-oci/current             active-release selector
/usr/local/bin/vwctl                     authoritative operator CLI
/etc/vaultwarden-oci/config.toml         operator-editable non-secret config
/etc/vaultwarden-oci/secrets.sops.yaml   encrypted secret document
/etc/vaultwarden-oci/age-key.txt         root-only operational Age identity
/run/vaultwarden-oci                     volatile generated/decrypted material
```

Persistent application/recovery state belongs on the validated dedicated storage filesystem. Do not establish `/var/lib/vaultwarden-oci` on the root filesystem as a supported production fallback merely because current development code still uses that path.

`versions.toml` is the source-controlled exact version authority. `email-providers.toml` is closed immutable release metadata, not operator configuration.

## Operator configuration

The one non-secret operator config authority is `/etc/vaultwarden-oci/config.toml`. The supported shape currently includes site, offline recovery recipient, Vaultwarden, SMTP, and optional operational-notification settings. Secrets do not belong in this file.

Validate before start:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
```

Unknown config fields fail validation. Operator config cannot replace notification endpoints, authentication modes, headers, request payloads, success rules, or retry rules.

## SOPS + Age custody

Use two different Age identities:

1. **Operational identity** — root-only on the appliance at `/etc/vaultwarden-oci/age-key.txt`.
2. **Offline recovery identity** — private key kept away from the appliance; only its public Age recipient is stored in normal configuration/encryption metadata.

The offline recovery private identity must not be persistently stored on the server.

The SOPS document remains encrypted at rest and contains required service credentials such as Cloudflare, SMTP, and optional operational-notification tokens. Plaintext credentials must not be written into `config.toml`, release files, command arguments, ordinary logs, or persistent temporary files. Decrypted runtime material belongs only under the root-owned volatile runtime tree.

After secret setup, prove host-side decryption without printing plaintext and then revalidate:

```bash
sudo env SOPS_AGE_KEY_FILE=/etc/vaultwarden-oci/age-key.txt \
  sops decrypt /etc/vaultwarden-oci/secrets.sops.yaml >/dev/null
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
```

## Recovery-kit credential handoff

The password-protected recovery-kit ZIP is separate from `.vwrec` application recovery.

Its contract is strict:

- AES-256 ZIP encryption;
- passphrase entered and confirmed interactively;
- passphrase independent of stored project credentials;
- passphrase never supplied in argv, environment variables, files, or email;
- the encrypted ZIP is fully verified before any email attempt;
- email delivery is a handoff step, not proof that application recovery exists.

Do not substitute the operational Age private key or a normal application recovery point for this credential-handoff artifact.

## Cloudflare origin, Caddy, and CrowdSec

Caddy is an exact-pinned xcaddy custom build with Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP support, combined Cloudflare IP ranges, and Caddy rate limiting.

Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. The generated Caddy configuration must not contain a second static Cloudflare CIDR `trusted_proxies` list.

Host-level origin protection is separate. Before published HTTPS is considered ready, the appliance must establish one small fail-closed Docker `DOCKER-USER` path that permits origin TCP/443 only from validated Cloudflare IPv4/IPv6 ranges, with bounded last-known-good handling. If no safe policy is available, ingress remains blocked.

CrowdSec remediates proxied web-client decisions through Cloudflare. Do not install a CrowdSec host firewall bouncer as part of the supported architecture.

## CyberPersons / CyberPanel Email

The canonical provider ID is `cyberpersons`; `cyberpanel` is only an alias.

Before configuring it:

1. verify the sending domain used by the configured SMTP/from address;
2. create an API token with the provider's required send permission;
3. store the API token in SOPS as `email_api_token`;
4. use independent SMTP credentials for authenticated SMTP fallback; do not reuse the API token as an SMTP password.

The closed provider catalog owns the REST endpoint/request/success/retry metadata. Current verified behavior is:

- accepted REST sends use HTTP `202`;
- HTTP `503 service_unavailable` is the status-only transient/retry/fallback case;
- HTTP `429 rate_limit_exceeded` is **not** transient by status alone because current provider behavior includes account-wide minute/hour/day/month limits shared across API and SMTP credentials;
- HTTP `500 send_failed` is **not** transient by status alone.

Re-verify official provider documentation before changing catalog metadata; do not restore older wording that treats arbitrary 429 responses as transient.

## First start

Setup should leave the administrator at an explicit final configuration/secrets checkpoint. Once those are complete:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

Treat any doctor `FAIL` as a failed acceptance condition. `WARN` remains visible diagnostic state.

When healthy, enable the supported systemd lifecycle/timers as documented by the installed release:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

Continue with [OPERATIONS.md](OPERATIONS.md), [RECOVERY.md](RECOVERY.md), and [HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md).

## Current development-branch gap

At this contract-synchronization point, the current development branch still exposes `bootstrap-v2.sh` as its low-level installer, stores state under `/var/lib/vaultwarden-oci`, gates `--use-latest` behind a development boundary, and lacks the supported `setup.sh` flow. Therefore the current branch does **not yet** satisfy the supported production installation procedure above.

Do not reinterpret that implementation lag as permission to weaken the product contract. `bootstrap-v2.sh` remains useful implementation/bootstrap machinery, but it is not the final supported production first-run interface.
