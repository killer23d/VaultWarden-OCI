# API Integration — VaultWarden-OCI

VaultWarden implements the **Bitwarden API**, making it compatible with all official Bitwarden clients and CLIs. This guide covers authentication, common operations, and security practices for programmatic access.

Related docs: [CONFIGURATION.md](CONFIGURATION.md) · [SECURITY.md](SECURITY.md)

---

## 🔐 Authentication

### User Access Token (Password Grant)

```bash
curl -X POST https://vault.yourdomain.com/identity/connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "username=user@example.com" \
  -d "password=your_password" \
  -d "scope=api offline_access" \
  -d "client_id=web" \
  -d "deviceType=3" \
  -d "deviceName=api-client" \
  -d "deviceIdentifier=$(uuidgen)"
```

Response:

```json
{
  "access_token": "eyJhbGc...",
  "expires_in": 3600,
  "token_type": "Bearer",
  "refresh_token": "eyJhbGc..."
}
```

Use the token:

```bash
curl -X GET https://vault.yourdomain.com/api/sync \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Admin Authentication

The admin panel is protected by two independent layers:

1. **Caddy basic auth** — `admin_basic_auth_hash` secret (bcrypt hash, **minimum cost 10**), prompted in browser
2. **VaultWarden admin token** — Argon2id hash stored in SOPS secrets, used for direct API calls

```bash
# Direct admin API call
curl -X GET https://vault.yourdomain.com/admin/users \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

To generate a valid bcrypt hash for `admin_basic_auth_hash`:

```bash
# Using the project tooling (enforces cost >= 10)
source lib/crypto.sh
generate_bcrypt_hash "yourpassword" 12

# Or using Caddy directly
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
```

> ⚠️ **bcrypt cost floor:** `lib/crypto.sh:generate_bcrypt_hash()` and `caddy/entrypoint.sh` both enforce a **minimum bcrypt cost of 10** (OWASP minimum for interactive logins). A hash generated with cost < 10 will be rejected at startup with an explicit error. The valid range is **10–31**; the project default is **12**.

To generate an Argon2id hash for the VaultWarden admin token:

```bash
# Using the project tooling
source lib/crypto.sh
generate_argon2_hash "your_admin_token"

# Or directly with argon2 CLI (parameters must match: -id -t 3 -m 16 -p 4 -l 32)
echo -n "your_admin_token" | argon2 "$(openssl rand -hex 8)" -id -t 3 -m 16 -p 4 -l 32 -e
```

---

## 📦 Common Vault Operations

### Sync

```bash
curl -X GET https://vault.yourdomain.com/api/sync \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### List Ciphers

```bash
curl -X GET https://vault.yourdomain.com/api/ciphers \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Create Cipher

```bash
curl -X POST https://vault.yourdomain.com/api/ciphers \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": 1,
    "name": "Example Login",
    "login": {
      "username": "user@example.com",
      "password": "secure_password",
      "uris": [{"match": null, "uri": "https://example.com"}]
    }
  }'
```

### Update / Delete Cipher

```bash
# Update
curl -X PUT https://vault.yourdomain.com/api/ciphers/$CIPHER_ID \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{...}'

# Delete
curl -X DELETE https://vault.yourdomain.com/api/ciphers/$CIPHER_ID \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

---

## 🚫 Rate Limiting

Rate limits are enforced via **Cloudflare WAF rules** configured manually in the Cloudflare dashboard — not by Caddy middleware. See [SECURITY.md](SECURITY.md) for setup instructions.

| Rule | Path | Limit | Action |
| :-- | :-- | :-- | :-- |
| Auth endpoint protection | `/identity/connect/token*`, `/api/accounts/prelogin*` | 10 req / 1 min per IP | Block (429) |
| Admin panel protection | `/admin*` | 5 req / 1 min per IP | Block (429) |
| General API protection (optional) | `/api/*` | 100 req / 1 min per IP | Managed Challenge |

Fail2ban adds a second layer — repeated auth failures trigger a **Cloudflare Edge WAF ban** (not a local iptables rule, since web traffic arrives via the Cloudflare proxy). Local `iptables` is strictly used for SSH protection.

---

## 🛡️ Content-Security-Policy and Push Notifications

The Caddy `Content-Security-Policy` header is generated dynamically by `caddy/entrypoint.sh` based on the `PUSH_ENABLED` environment variable:

- **`PUSH_ENABLED=false` (default):** `connect-src` does **not** include `https://push.bitwarden.com` or `https://identity.bitwarden.com`. This is the narrowest (most secure) policy.
- **`PUSH_ENABLED=true`:** Both push relay origins are added to `connect-src` automatically.

Do not manually edit the CSP in the Caddyfile — the `{$PUSH_CSP}` placeholder is populated at container startup from the environment. Mismatched push origins will cause silent sync failures in clients.

> ⚠️ **`PUSH_ENABLED=true` + `internal: true` network:** push relay connections to `https://push.bitwarden.com` will silently fail. The `startup.sh` probe will reject this combination at startup and print a clear error. Set `PUSH_ENABLED=false` or remove the `internal: true` constraint from the network in `docker-compose.yml`.

---

## ✅ API Security Practices

- Always use HTTPS — HTTP is redirected by Caddy
- Never hardcode tokens in scripts; load from environment or SOPS secrets
- Use dedicated service accounts rather than personal user accounts
- Rotate tokens regularly and audit access logs
- Implement back-off and retry logic in automation to stay within rate limits
- Admin token must be an Argon2id hash (not plaintext); bcrypt hashes for Caddy basic auth must use cost ≥ 10

---

## 📚 Further Resources

- [Bitwarden API Documentation](https://bitwarden.com/help/api/)
- [VaultWarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
- [Official Bitwarden CLI](https://bitwarden.com/help/cli/)
