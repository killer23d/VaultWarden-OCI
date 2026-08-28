# Cloudflare tokens

VaultWarden-OCI uses two separate Cloudflare user API tokens for two different trust boundaries. Do not reuse one token for both jobs.

The token values are secrets and belong only in `/etc/vaultwarden-oci/secrets.sops.yaml` through `sudo vwctl secrets edit`. Do not put them in `config.toml`, shell arguments, service unit files, or documentation.

Cloudflare's current token-creation flow is **Cloudflare dashboard -> My Profile -> API Tokens -> Create Token**. See Cloudflare's official [Create API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/) documentation. Copy each token when Cloudflare displays it; the secret is shown only once.

## `cloudflare_api_token` - Caddy DNS-01

This is the narrow token Caddy uses to create and remove the temporary DNS records required for ACME DNS-01 certificate issuance.

Create a separate user API token. You can start from Cloudflare's **Edit zone DNS** template or create a custom token. The current `caddy-dns/cloudflare` module recommends one token with:

| Scope | Permission | Access |
| --- | --- | --- |
| Zone | Zone | Read |
| Zone | DNS | Edit |

Under **Zone Resources**, restrict the token to the specific DNS zone that contains the Vaultwarden hostname, for example `example.com`. Do not grant all-zone access unless the appliance genuinely manages certificates for all of those zones.

A descriptive name such as `VaultWarden-OCI Caddy DNS` is recommended.

Store the resulting secret as:

```yaml
cloudflare_api_token: "<token from Cloudflare>"
```

Reference: [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) documents `Zone.Zone:Read` plus `Zone.DNS:Edit` for its recommended single-token configuration.

## `cloudflare_remediation_token` - CrowdSec Cloudflare remediation

This is a separate, broader token used only when CrowdSec Cloudflare remediation is enabled. It allows the supported Cloudflare Worker bouncer to discover the configured zone/account and manage the Cloudflare Worker/KV resources used for remediation.

Create a second Cloudflare **user API token** with the current permissions required by CrowdSec's Cloudflare Worker bouncer:

| Scope | Permission | Access |
| --- | --- | --- |
| Account | Turnstile | Edit |
| Account | Workers KV Storage | Edit |
| Account | Workers Scripts | Edit |
| Account | Account Settings | Read |
| Account | Account Analytics | Read |
| User | User Details | Read |
| Zone | DNS | Read |
| Zone | Workers Routes | Edit |
| Zone | Zone | Read |

Restrict **Account Resources** to the Cloudflare account that owns the Vaultwarden zone and restrict **Zone Resources** to the specific zone being protected whenever the Cloudflare token builder allows it. CrowdSec explicitly recommends limiting the token to only the accounts and zones that are intended to be protected.

A descriptive name such as `VaultWarden-OCI CrowdSec Remediation` is recommended.

Store the resulting secret as:

```yaml
cloudflare_remediation_token: "<separate token from Cloudflare>"
```

Reference: CrowdSec's official [Cloudflare Worker Bouncer](https://docs.crowdsec.net/u/bouncers/cloudflare/) documentation is the permission authority for this token.

The remediation token is intentionally separate from `cloudflare_api_token`. Its Worker/KV permissions are broader than Caddy needs, so using the same credential for both would unnecessarily expand the Caddy certificate-management trust boundary.

## Values you do not enter

The appliance does not require the administrator to paste Cloudflare Account ID or Zone ID. CrowdSec remediation resolves the configured DNS zone through the Cloudflare API and obtains both identifiers at runtime.

The local CrowdSec LAPI bouncer credential is also generated locally by the appliance. Do not create or copy a separate `cf_worker_bouncer_token` into SOPS.

## Other first-run secret fields

A fresh secrets document exposes the complete field map:

```yaml
cloudflare_api_token: ""
cloudflare_remediation_token: ""
smtp_username: ""
smtp_password: ""
email_api_token: ""
vaultwarden_admin_token: <generated>
admin_basic_auth_password: <generated>
```

`cloudflare_api_token`, `smtp_username`, and `smtp_password` are required for the normal first-run path. `cloudflare_remediation_token` is required only when CrowdSec Cloudflare remediation is enabled. `email_api_token` is unrelated to Cloudflare and is required only when an HTTPS operational notification provider is configured; obtain that credential from the selected email provider.

After entering or rotating Cloudflare credentials:

```bash
sudo vwctl secrets validate
sudo vwctl doctor --json
```

Restart or start the affected services only after validation succeeds.