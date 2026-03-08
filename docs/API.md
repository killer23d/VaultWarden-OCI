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

The admin panel is protected by two layers:

1. **Caddy basic auth** — `admin_basic_auth_hash` secret (bcrypt hash), prompted in browser
2. **VaultWarden admin token** — configured in secrets, used for direct API calls

```bash
# Direct admin API call
curl -X GET https://vault.yourdomain.com/admin/users \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

To generate a valid bcrypt hash for `admin_basic_auth_hash`:

```bash
docker run --rm -it ghcr.io/caddybuilds/caddy-cloudflare:latest caddy hash-password
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

Caddy applies rate limits to protect sensitive endpoints:

| Endpoint | Limit |
| :-- | :-- |
| Static endpoints | 20 requests / 5 min / IP |
| API auth endpoints | 10 requests / 5 min / IP |
| Admin endpoints | 5 requests / 5 min / IP |

Fail2ban adds a second layer — repeated auth failures trigger a **Cloudflare Edge WAF ban** (not a local iptables rule, since traffic arrives via the Cloudflare proxy).

---

## ✅ API Security Practices

- Always use HTTPS — HTTP is redirected by Caddy
- Never hardcode tokens in scripts; load from environment or secrets
- Use dedicated service accounts rather than personal user accounts
- Rotate tokens regularly and audit access logs
- Implement back-off and retry logic in automation to stay within rate limits

---

## 📚 Further Resources

- [Bitwarden API Documentation](https://bitwarden.com/help/api/)
- [VaultWarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
- [Official Bitwarden CLI](https://bitwarden.com/help/cli/)
