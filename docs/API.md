# API Integration Guide - VaultWarden-OCI

Guide for integrating with VaultWarden API, automating operations, and extending functionality.

## VaultWarden API Overview

VaultWarden implements the Bitwarden API, providing compatibility with official Bitwarden clients and allowing programmatic access to your password vault.

**API Endpoints**:
- Identity API: `/identity` - Authentication and tokens
- API: `/api` - Vault operations
- Admin API: `/admin` - Administrative functions
- Web Vault: `/` - Web interface

## Authentication

### Obtaining Access Tokens

**Via Password Grant** (User login):
```bash
curl -X POST https://vault.example.com/identity/connect/token \\
  -H "Content-Type: application/x-www-form-urlencoded" \\
  -d "grant_type=password" \\
  -d "username=user@example.com" \\
  -d "password=user_password" \\
  -d "scope=api offline_access" \\
  -d "client_id=web" \\
  -d "deviceType=3" \\
  -d "deviceName=api-client" \\
  -d "deviceIdentifier=$(uuidgen)"
```

**Response**:
```json
{
  "access_token": "eyJhbGc...",
  "expires_in": 3600,
  "token_type": "Bearer",
  "refresh_token": "eyJhbGc..."
}
```

**Using Access Token**:
```bash
curl -X GET https://vault.example.com/api/sync \\
  -H "Authorization: Bearer eyJhbGc..."
```

### Admin Authentication

**Admin Token** (configured in secrets):
```bash
# Admin operations use admin token from secrets
curl -X GET https://vault.example.com/admin/users \\
  -H "Authorization: Bearer YOUR_ADMIN_TOKEN"
```

**Admin Basic Auth** (Caddy layer):
```bash
# Admin panel protected by basic auth
curl -u "admin:password" https://vault.example.com/admin
```

## Common API Operations

### Vault Operations

**Sync Vault**:
```bash
curl -X GET https://vault.example.com/api/sync \\
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

**Get Ciphers** (vault items):
```bash
curl -X GET https://vault.example.com/api/ciphers \\
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

**Create Cipher**:
```bash
curl -X POST https://vault.example.com/api/ciphers \\
  -H "Authorization: Bearer $ACCESS_TOKEN" \\
  -H "Content-Type: application/json" \\
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

**Update Cipher**:
```bash
curl -X PUT https://vault.example.com/api/ciphers/$CIPHER_ID \\
  -H "Authorization: Bearer $ACCESS_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{...}'
```

**Delete Cipher**:
```bash
curl -X DELETE https://vault.example.com/api/ciphers/$CIPHER_ID \\
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

## API Security Best Practices

1. **Use HTTPS only**: Always use secure connections
2. **Rotate tokens regularly**: Implement token rotation
3. **Limit token scope**: Use minimum required permissions
4. **Rate limiting**: Implement rate limiting in automation
5. **Log API access**: Monitor API usage for anomalies
6. **Secure credentials**: Never hardcode tokens in scripts
7. **Use service accounts**: Create dedicated API users
8. **Validate inputs**: Sanitize all user inputs
9. **Error handling**: Implement proper error handling
10. **Audit regularly**: Review API access logs

## Rate Limiting

VaultWarden-OCI implements rate limiting via Caddy:

- Static endpoints: 20 requests per 5 minutes per IP
- Admin endpoints: 5 requests per 5 minutes per IP
- API auth endpoints: 10 requests per 5 minutes per IP

## Further Resources

- **Bitwarden API Documentation**: https://bitwarden.com/help/api/
- **VaultWarden Wiki**: https://github.com/dani-garcia/vaultwarden/wiki
- **Official Bitwarden CLI**: https://bitwarden.com/help/cli/

---

This API guide provides comprehensive examples for integrating with VaultWarden-OCI programmatically, automating operations, and extending functionality through various programming languages and tools.
"""
