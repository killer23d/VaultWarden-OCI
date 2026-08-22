# Install

## Supported host

Production beta supports Ubuntu 24.04 LTS only, on `amd64` or `arm64`. The host must provide Python 3.12, systemd, Docker Engine with the Compose plugin (including `up --wait`), `age`, `age-keygen`, `sops`, `rclone`, `iptables`, and `ip6tables`. The deployment is cloud-provider neutral; provider firewalls/security groups remain outside this repository and must permit the traffic you intend to expose.

Use a trusted V2 release/checkout. Production uses the exact values in `versions.toml`; do not substitute mutable application image tags.

## Prepare a clean Ubuntu 24.04 host

Install the Ubuntu-packaged prerequisites first:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl age rclone iptables
python3 --version
age --version
rclone version
```

Install Docker Engine and the Compose plugin from Docker's official Ubuntu repository. These commands follow Docker's current Ubuntu repository procedure:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

Install SOPS from an official release binary for the host architecture. V2 CI currently exercises SOPS `3.13.3`; its release provides Linux binaries and signed checksum/provenance material. Select only a supported architecture and verify the downloaded artifact against the release checksums/signature before installing it:

```bash
SOPS_VERSION=3.13.3
case "$(dpkg --print-architecture)" in
  amd64) SOPS_ARCH=amd64 ;;
  arm64) SOPS_ARCH=arm64 ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac
curl -fL \
  "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${SOPS_ARCH}" \
  -o /tmp/sops
# Verify /tmp/sops using the checksums/signature published with that SOPS release.
sudo install -m 0755 /tmp/sops /usr/local/bin/sops
rm -f /tmp/sops
sops --version
```

Do not use an unreviewed convenience script to prepare a production host. Before bootstrap, all of these must succeed: `python3 --version`, `sudo docker version`, `sudo docker compose version`, `age --version`, `sops --version`, `rclone version`, `iptables --version`, and `ip6tables --version`.

## Immutable install

Run as root from the release root:

```bash
sudo ./bootstrap-v2.sh
```

The installer validates Ubuntu/architecture and creates:

- `/opt/vaultwarden-oci/releases/<version>` — immutable release content;
- `/opt/vaultwarden-oci/current` — active-release symlink;
- `/usr/local/bin/vwctl` — operator CLI symlink;
- `/etc/vaultwarden-oci/config.toml` — the one operator TOML config;
- `/etc/vaultwarden-oci/secrets.sops.yaml` — encrypted secret document;
- `/etc/vaultwarden-oci/age-key.txt` — operational Age identity, root `0600`;
- `/var/lib/vaultwarden-oci` — durable application/recovery state;
- `/run/vaultwarden-oci` — volatile generated/runtime material.

The installer copies only V2 systemd units from `systemd-v2/` to `/etc/systemd/system` and records the exact resolved versions in `/var/lib/vaultwarden-oci/state/resolved-versions.json`.

## Operator config

Edit `/etc/vaultwarden-oci/config.toml`. A fresh install now writes the complete supported beta schema with reserved `.invalid` placeholders and comments. Replace the placeholder domain/email/SMTP values and the placeholder offline Age recipient before first start. The required shape is:

```toml
schema_version = 1

[site]
domain = "vault.example.com"
acme_email = "admin@example.com"

[secrets]
offline_recovery_recipient = "age1..."

[vaultwarden]
signups_allowed = false

[smtp]
host = "smtp.example.com"
port = 587
security = "starttls"
from_email = "vaultwarden@example.com"
from_name = "Vaultwarden"
timeout_seconds = 15
```

Operational notifications are optional. Add the table only after the provider and SOPS token are ready:

```toml
[notifications]
provider = "cyberpersons"
to_email = "ops@example.com"
```

Validate without starting services:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
```

Unknown config fields fail validation. Operator config cannot replace notification endpoints, auth modes, headers, request payloads, success rules, or retry rules.

## SOPS + Age custody

Create two different Age X25519 identities:

1. **Operational identity** — stored root-only at `/etc/vaultwarden-oci/age-key.txt`; used for normal host-side decryption.
2. **Offline recovery identity** — generated and stored away from the host; only its public `age1...` recipient is placed in `config.toml`.

### Generate the identities

After `bootstrap-v2.sh`, create the operational identity directly into the root-owned file the installer prepared:

```bash
sudo sh -c 'umask 077; age-keygen > /etc/vaultwarden-oci/age-key.txt'
sudo chmod 0600 /etc/vaultwarden-oci/age-key.txt
OPERATIONAL_RECIPIENT="$(sudo age-keygen -y /etc/vaultwarden-oci/age-key.txt)"
printf 'operational recipient: %s\n' "$OPERATIONAL_RECIPIENT"
```

Generate the **offline** identity on a separate trusted/offline machine, not on the Vaultwarden host:

```bash
umask 077
age-keygen -o vwoci-offline-age-key.txt
OFFLINE_RECIPIENT="$(age-keygen -y vwoci-offline-age-key.txt)"
printf 'offline recipient: %s\n' "$OFFLINE_RECIPIENT"
```

Keep `vwoci-offline-age-key.txt` off-host. Transfer only the printed `age1...` public recipient to the Vaultwarden host and set it as `[secrets].offline_recovery_recipient` in `/etc/vaultwarden-oci/config.toml`.

On the Vaultwarden host, set the two public recipients for the encryption command without putting either private key into shell variables:

```bash
OPERATIONAL_RECIPIENT="$(sudo age-keygen -y /etc/vaultwarden-oci/age-key.txt)"
OFFLINE_RECIPIENT='age1REPLACE_WITH_OFFLINE_PUBLIC_RECIPIENT'
```

### Create the encrypted SOPS document

Do not put real secret values in shell history. Create the plaintext draft only in the root-only volatile runtime tree:

```bash
sudo install -d -m 0700 /run/vaultwarden-oci/transient
sudoedit /run/vaultwarden-oci/transient/secrets.yaml
```

Use this YAML shape in the editor, replacing values there:

```yaml
cloudflare_api_token: REPLACE_ME
cloudflare_remediation_token: REPLACE_ME
smtp_username: REPLACE_ME
smtp_password: REPLACE_ME
# Optional:
# vaultwarden_admin_token: REPLACE_ME
# email_api_token: REPLACE_ME
```

Encrypt that draft to **both** public recipients. SOPS accepts multiple Age recipients as a comma-separated `--age` value. Write the encrypted result to a volatile temporary path first so an encryption failure cannot truncate an existing persistent SOPS document; install it into `/etc` only after SOPS exits successfully:

```bash
sudo env \
  OPERATIONAL_RECIPIENT="$OPERATIONAL_RECIPIENT" \
  OFFLINE_RECIPIENT="$OFFLINE_RECIPIENT" \
  sh -c '
    set -eu
    out=/run/vaultwarden-oci/transient/secrets.sops.yaml.new
    trap "rm -f $out" EXIT
    umask 077
    sops encrypt \
      --age "$OPERATIONAL_RECIPIENT,$OFFLINE_RECIPIENT" \
      --input-type yaml --output-type yaml \
      /run/vaultwarden-oci/transient/secrets.yaml \
      > "$out"
    install -m 0600 -o root -g root \
      "$out" /etc/vaultwarden-oci/secrets.sops.yaml
  '
sudo rm -f /run/vaultwarden-oci/transient/secrets.yaml
```

Confirm the host operational identity can decrypt the document without printing plaintext:

```bash
sudo env SOPS_AGE_KEY_FILE=/etc/vaultwarden-oci/age-key.txt \
  sops decrypt /etc/vaultwarden-oci/secrets.sops.yaml >/dev/null
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl doctor --json
```

The SOPS document must remain encrypted to **both** recipients. Required beta keys are:

```text
cloudflare_api_token
cloudflare_remediation_token
smtp_username
smtp_password
```

Optional/transient-only keys are:

```text
vaultwarden_admin_token
email_api_token
```

`email_api_token` and `cloudflare_remediation_token` are decrypted in host memory for host-side work and are not placed in the Vaultwarden/Caddy secret mounts. Other runtime secret files are materialized under `/run/vaultwarden-oci/secrets`, never under the release or persistent data tree. `vwctl doctor` validates custody using the stable IDs `secrets.custody` and `secrets.decrypt`.

Keep the offline Age private identity physically/logically separate from the host. The V2 recovery artifact never contains `/etc/vaultwarden-oci/age-key.txt`.

## Cloudflare origin and CrowdSec

`vwctl start` refreshes validated Cloudflare IPv4/IPv6 ranges and applies a Docker `DOCKER-USER` fail-closed policy for published HTTPS ingress. A bounded last-known-good policy may be used when the live fetch fails; if no safe policy exists, origin ingress remains blocked and startup fails.

After normal configuration is valid:

```bash
sudo vwctl crowdsec setup
sudo vwctl crowdsec remediation-start
```

The second command creates one explicit Cloudflare remediation invocation. In Cloudflare, set every Worker Route created by that bouncer invocation to **Fail Open**, then record the checked state:

```bash
sudo vwctl crowdsec confirm-fail-open
sudo vwctl crowdsec status
```

Beta web remediation is Cloudflare-only. Do not install the retired V1 CrowdSec host firewall bouncer as part of this architecture.

## CyberPanel Email / CyberPersons

The canonical provider ID is `cyberpersons`; `cyberpanel` is accepted as an alias only.

Before configuring it:

1. In CyberPanel Email/CyberPersons, verify the sending domain used by `[smtp].from_email`.
2. Create an API key/token with the `can_send` permission.
3. Store that API token as `email_api_token` in the SOPS document.
4. If you want CyberPanel SMTP as the fallback transport, create/use **independent SMTP credentials** and store those values as `smtp_username` / `smtp_password`; do not reuse the API token as an SMTP password.
5. Configure `[smtp]` for `mail.cyberpersons.com`, port `587`, `security = "starttls"` when using CyberPersons SMTP.

The closed provider catalog fixes the REST endpoint at `https://platform.cyberpersons.com/email/v1/send`; operator config cannot redirect the credential. Phase 8 re-verified the current official CyberPanel Email documentation on 2026-08-21. Accepted REST sends use HTTP `202`. HTTP `503 service_unavailable` is the current status-only transient rule. HTTP `429 rate_limit_exceeded` is **not** treated as transient by status alone because the provider uses 429 for account-wide minute, hour, day, and month limits shared across API and SMTP credentials. HTTP `500 send_failed` likewise remains visible and is not SMTP-fallback eligible by status alone. Re-verify the official provider documentation whenever catalog metadata changes.

## First start

```bash
sudo vwctl versions
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

Treat any doctor `FAIL` as a failed acceptance condition. `WARN` is visible diagnostic state; do not normalize it away in scripts.

When the host is healthy, enable automation:

```bash
sudo systemctl enable --now vaultwarden-oci.target
systemctl status vaultwarden-oci.target
systemctl list-timers 'vaultwarden-oci-*'
```

Continue with [OPERATIONS.md](OPERATIONS.md), [RECOVERY.md](RECOVERY.md), and the disposable-host [HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md) release gate.
