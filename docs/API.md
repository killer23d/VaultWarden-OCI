# HTTP and API Integration — VaultWarden-OCI

VaultWarden-OCI does not add a separate application API layer. Vaultwarden owns the password-manager HTTP/API surface; Caddy owns the public reverse-proxy/TLS boundary; Cloudflare owns the supported edge path.

This document describes the repository integration boundary rather than duplicating Vaultwarden's complete upstream API documentation.

Related docs: [ARCHITECTURE.md](ARCHITECTURE.md) · [SECURITY.md](SECURITY.md) · [CONFIGURATION.md](CONFIGURATION.md) · [CROWDSEC.md](CROWDSEC.md)

## Public request path

The supported normal path is:

```text
client
  -> Cloudflare DNS / proxy / WAF
  -> provider firewall / security group / network firewall
  -> Ubuntu UFW / iptables path
  -> Caddy
  -> Vaultwarden
```

The normal production edge is Cloudflare-first. Do not document direct public exposure of the Vaultwarden container as the supported API path.

Caddy terminates TLS, applies the repository's proxy/security policy, and forwards application traffic to Vaultwarden on the private Compose network.

## Base URL

The operator configures:

```bash
DOMAIN=https://vault.example.com
```

Clients and integrations use the configured HTTPS origin:

```text
https://vault.example.com
```

Do not add a separate `DOMAIN_NAME` configuration source for normal deployments. The current Caddy/Vaultwarden configuration derives the needed hostname from `DOMAIN`.

## Health and readiness endpoint

The canonical application readiness path used by the current repository is:

```text
/alive
```

Examples:

```bash
curl -fsS https://vault.example.com/alive
```

Local origin check with SNI and normal certificate verification:

```bash
DOMAIN="vault.example.com"

curl -fsS -v --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/alive"
```

The Vaultwarden Compose healthcheck and the project health/smoke tooling use `/alive`.

Do not substitute `/api/alive` in repository readiness checks.

A successful `/alive` response is one live-service signal. It is not, by itself, the complete production-readiness gate. Installed systemd runtime consistency, timers, secrets, backup evidence, CrowdSec, disk, and other required smoke checks still matter.

## Vaultwarden API surface

Vaultwarden implements the Bitwarden-compatible server API used by supported Bitwarden clients and web-vault flows.

Repository operators should rely on the currently deployed Vaultwarden version and its upstream compatibility/documentation for endpoint-specific application API semantics.

The repository intentionally does not maintain a hand-copied endpoint catalog because that would become a second, stale Vaultwarden API reference.

Current application image pin is owned by `.env.example`:

```bash
VAULTWARDEN_VERSION=1.37.1
```

When changing the pin, validate the supported clients/integrations against the new deployed Vaultwarden version.

## `/api/config`

The repository uses `/api/config` as a useful application/configuration probe in selected health and troubleshooting flows.

Example local origin check:

```bash
DOMAIN="vault.example.com"

curl -fsS -v --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/api/config" \
  -o /dev/null \
  -w "HTTP %{http_code}\n"
```

A healthy normal origin is expected to return HTTP `200` for the current probe.

Do not expose secret values through a custom wrapper endpoint merely to make health diagnostics easier.

## Admin path

Vaultwarden's `/admin` path is protected by separate controls:

- the Vaultwarden `admin_token` secret, stored as an Argon2id value according to `secrets-schema.yaml`;
- the Caddy administrative source-range policy using `ADMIN_ALLOW_CIDR`;
- Caddy basic authentication using the schema-managed `admin_basic_auth_hash`.

These controls are intentionally separate.

Rotate the application admin token with:

```bash
sudo ./edit-secrets.sh rotate admin_token
```

Rotate the Caddy basic-auth credential with:

```bash
sudo ./edit-secrets.sh rotate admin_basic_auth_hash
```

Edit the trusted administrative source range through:

```bash
sudo make edit-env
```

Do not put a plaintext admin token in `.env` or weaken the Caddy boundary merely because a client/tool needs ordinary Vaultwarden API access.

## Client IP handling

The supported edge is Cloudflare. The application/proxy configuration uses the Cloudflare client IP path expected by the current Caddy/Vaultwarden integration.

Current `.env.example` uses:

```bash
IP_HEADER=CF-Connecting-IP
```

Caddy is built from the repository's pinned xcaddy image definition in `caddy/Dockerfile`; the production build must remain pinned and compatible with amd64 and arm64.

Do not replace the pinned build with a mutable image such as:

```text
ghcr.io/caddybuilds/caddy-cloudflare:latest
```

in production documentation or deployment automation.

When changing proxy/client-IP behavior, inspect:

- `caddy/Caddyfile`;
- `caddy/entrypoint.sh`;
- `caddy/Dockerfile`;
- `docker-compose.yml.example`;
- CrowdSec acquisition/parser behavior;
- health/security tests.

A client-IP change can affect rate/security decisions as well as application logging.

## Cloudflare and CrowdSec edge enforcement

CrowdSec does not directly update Cloudflare WAF Custom Rules as the current normal project architecture.

The current edge-enforcement path is:

```text
CrowdSec local decisions
        -> crowdsec-cloudflare-worker-bouncer
        -> Cloudflare Workers KV
        -> deployed Worker route
        -> edge allow/block decision
```

The host firewall bouncer is a separate enforcement path.

See [CROWDSEC.md](CROWDSEC.md).

## WebSocket and push behavior

Current application configuration includes:

```bash
WEBSOCKET_ENABLED=true
```

Caddy owns proxy behavior for the current Vaultwarden web/API traffic.

Push notification support is optional:

```bash
PUSH_ENABLED=true
PUSH_RELAY_URI=https://push.bitwarden.com
PUSH_IDENTITY_URI=https://identity.bitwarden.com
```

The two push credentials are SOPS secrets:

```text
push_installation_id
push_installation_key
```

Vaultwarden is attached to the dedicated `vaultwarden_egress` Compose network for outbound access. Do not use old guidance that removes the private application's network isolation as the default push fix.

## SMTP is not an HTTP API integration

Vaultwarden application mail uses the internal Postfix sidecar in the normal architecture:

```text
Vaultwarden
  -> postfix:587
  -> authenticated/TLS upstream SMTP relay
```

Operational scripts may optionally use supported provider HTTP APIs for alert delivery. That API mode does not replace the Postfix path for Vaultwarden mail or attachment-based recovery-kit delivery.

See [EMAIL.md](EMAIL.md).

## API credentials and secrets

Provider tokens, SMTP passwords, admin hashes, and push credentials belong in the SOPS secrets store:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

Manage them through:

```bash
sudo ./edit-secrets.sh edit
sudo ./edit-secrets.sh rotate <secret-key>
```

Do not:

- put API tokens in `.env`;
- pass private keys or tokens in command arguments when avoidable;
- log full authorization headers;
- commit example files containing real credentials;
- build a plaintext API-token cache outside the current secret lifecycle.

Transient decoded runtime secret files belong under:

```text
/run/vaultwarden-oci/secrets/
```

and are recreated by startup.

## Integrating an external client

For a normal Bitwarden-compatible client:

1. deploy and validate the supported host;
2. expose the configured hostname through Cloudflare/Caddy;
3. set the client's self-hosted server URL to the configured `DOMAIN`;
4. use the application's normal authentication flow;
5. verify client login/sync through the deployed Vaultwarden version.

The client should not connect to the Vaultwarden Compose container address or Caddy's loopback health port.

## Integrating automation

Before writing custom automation against Vaultwarden:

- confirm the deployed Vaultwarden version and upstream API behavior;
- use a least-privilege application credential/session model supported by Vaultwarden/Bitwarden;
- keep credentials outside shell history and Git;
- handle HTTP timeouts/non-2xx responses explicitly;
- avoid converting an unavailable API probe into a successful readiness result;
- do not add a repository-wide API wrapper framework for one integration.

When an integration needs a new project-managed secret, add it through the existing `secrets-schema.yaml` contract rather than adding a parallel plaintext environment key.

## Diagnosing HTTP/API failures

Start with:

```bash
sudo make health
docker compose ps
docker compose logs caddy --tail=120
docker compose logs vaultwarden --tail=120
```

Probe the canonical readiness endpoint:

```bash
curl -fsS https://vault.example.com/alive
```

Probe local origin routing with normal certificate verification:

```bash
DOMAIN="vault.example.com"

curl -fsS -v --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/alive"
```

Check Cloudflare mode and origin certificate health before debugging application API semantics.

For an installed production host after repository changes, also verify the installed runtime:

```bash
sudo ./setup.sh systemd validate
sudo ./utilities/smoke-test.sh
```

## Scope rule

The project should not create:

- a generic REST API gateway;
- an API credential database;
- a plugin registry for external integrations;
- a second health/readiness API;
- an application API compatibility shim;
- a service mesh.

Use Vaultwarden's application API, Caddy's existing reverse-proxy boundary, SOPS/Age for project-managed credentials, and focused integration code only when a demonstrated production requirement needs it.
