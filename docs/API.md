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

### Organization Operations

**List Organizations**:
```bash
curl -X GET https://vault.example.com/api/organizations \\
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

**Get Organization Details**:
```bash
curl -X GET https://vault.example.com/api/organizations/$ORG_ID \\
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

**Invite User to Organization**:
```bash
curl -X POST https://vault.example.com/api/organizations/$ORG_ID/users/invite \\
  -H "Authorization: Bearer $ACCESS_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{
    "emails": ["user@example.com"],
    "type": 2,
    "accessAll": false,
    "collections": []
  }'
```

## Admin API Operations

### User Management

**List Users**:
```bash
curl -X GET https://vault.example.com/admin/users \\
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

**Invite User**:
```bash
curl -X POST https://vault.example.com/admin/invite \\
  -H "Authorization: Bearer $ADMIN_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"email": "newuser@example.com"}'
```

**Delete User**:
```bash
curl -X POST https://vault.example.com/admin/users/$USER_ID/delete \\
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

### System Operations

**Get Diagnostics**:
```bash
curl -X GET https://vault.example.com/admin/diagnostics \\
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

**Test SMTP**:
```bash
curl -X POST https://vault.example.com/admin/test/smtp \\
  -H "Authorization: Bearer $ADMIN_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"email": "test@example.com"}'
```

## Automation Scripts

### Backup Automation

**Automated Backup Script**:
```bash
#!/bin/bash
# automated-backup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Create backup
./backup.sh --type db --rclone --email

# Check result
if [ $? -eq 0 ]; then
    echo "Backup completed successfully"
    exit 0
else
    echo "Backup failed"
    exit 1
fi
```

**Scheduled via Cron**:
```bash
# Daily backup at 2 AM
0 2 * * * cd /path/to/VaultWarden-OCI && ./backup.sh --type db --rclone --email
```

### Health Monitoring

**Health Check Script**:
```bash
#!/bin/bash
# health-monitor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Run health check
./health.sh --comprehensive --json > /tmp/health-status.json

# Check result
if [ $? -eq 0 ]; then
    echo "Health check passed"
    exit 0
else
    echo "Health check failed"
    # Send alert
    ./health.sh --comprehensive --email
    exit 1
fi
```

### User Management Automation

**Bulk User Import**:
```bash
#!/bin/bash
# bulk-invite.sh

ADMIN_TOKEN="your_admin_token"
API_URL="https://vault.example.com"

# Read users from file
while IFS= read -r email; do
    echo "Inviting $email..."
    
    curl -X POST "$API_URL/admin/invite" \\
      -H "Authorization: Bearer $ADMIN_TOKEN" \\
      -H "Content-Type: application/json" \\
      -d "{\"email\": \"$email\"}"
    
    sleep 1  # Rate limiting
done < users.txt

echo "Bulk invite completed"
```

## Integration Examples

### Monitoring Integration

**Prometheus Metrics** (via health check):
```bash
#!/bin/bash
# prometheus-exporter.sh

# Run health check and convert to Prometheus format
./health.sh --json | jq -r '
  "vaultwarden_up " + (.services.vaultwarden.running | if . then "1" else "0" end),
  "caddy_up " + (.services.caddy.running | if . then "1" else "0" end),
  "fail2ban_up " + (.services.fail2ban.running | if . then "1" else "0" end)
'
```

**Integration with monitoring system**:
```bash
# Add to monitoring agent configuration
*/5 * * * * /path/to/prometheus-exporter.sh > /var/lib/node_exporter/textfile_collector/vaultwarden.prom
```

### CI/CD Integration

**Automated Deployment Pipeline**:
```yaml
# .github/workflows/deploy.yml
name: Deploy VaultWarden

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Deploy to server
        run: |
          ssh user@server 'cd /path/to/VaultWarden-OCI && git pull'
          ssh user@server 'cd /path/to/VaultWarden-OCI && ./update.sh'
      
      - name: Verify deployment
        run: |
          ssh user@server 'cd /path/to/VaultWarden-OCI && ./health.sh'
```

### Backup to S3

**S3 Backup Integration**:
```bash
#!/bin/bash
# backup-to-s3.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Create backup
BACKUP_FILE=$(./backup.sh --type full)

# Upload to S3
aws s3 cp "$BACKUP_FILE" s3://your-bucket/vaultwarden-backups/

# Cleanup old backups (keep last 30 days)
aws s3 ls s3://your-bucket/vaultwarden-backups/ | \\
  awk '{print $4}' | \\
  sort -r | \\
  tail -n +31 | \\
  xargs -I {} aws s3 rm s3://your-bucket/vaultwarden-backups/{}

echo "Backup uploaded to S3"
```

## Webhook Integration

### Notification Webhooks

**Slack Notification**:
```bash
#!/bin/bash
# slack-notify.sh

WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
MESSAGE="$1"

curl -X POST "$WEBHOOK_URL" \\
  -H "Content-Type: application/json" \\
  -d "{\"text\": \"$MESSAGE\"}"
```

**Integration with backup**:
```bash
# backup-with-notification.sh
./backup.sh --type db && \\
  ./slack-notify.sh "✅ VaultWarden backup completed successfully" || \\
  ./slack-notify.sh "❌ VaultWarden backup failed"
```

### Discord Notification**:
```bash
#!/bin/bash
# discord-notify.sh

WEBHOOK_URL="https://discord.com/api/webhooks/YOUR/WEBHOOK"
MESSAGE="$1"

curl -X POST "$WEBHOOK_URL" \\
  -H "Content-Type: application/json" \\
  -d "{\"content\": \"$MESSAGE\"}"
```

## Client Library Examples

### Python Client

```python
#!/usr/bin/env python3
# vaultwarden-client.py

import requests
import json
from datetime import datetime

class VaultWardenClient:
    def __init__(self, base_url, email, password):
        self.base_url = base_url
        self.email = email
        self.password = password
        self.access_token = None
    
    def login(self):
        """Authenticate and obtain access token"""
        url = f"{self.base_url}/identity/connect/token"
        
        data = {
            "grant_type": "password",
            "username": self.email,
            "password": self.password,
            "scope": "api offline_access",
            "client_id": "web",
            "deviceType": "3",
            "deviceName": "python-client",
            "deviceIdentifier": "python-client-001"
        }
        
        response = requests.post(url, data=data)
        response.raise_for_status()
        
        self.access_token = response.json()["access_token"]
        return self.access_token
    
    def get_ciphers(self):
        """Get all vault items"""
        url = f"{self.base_url}/api/ciphers"
        headers = {"Authorization": f"Bearer {self.access_token}"}
        
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        
        return response.json()
    
    def create_login(self, name, username, password, uri):
        """Create new login item"""
        url = f"{self.base_url}/api/ciphers"
        headers = {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json"
        }
        
        data = {
            "type": 1,  # Login type
            "name": name,
            "login": {
                "username": username,
                "password": password,
                "uris": [{"match": None, "uri": uri}]
            }
        }
        
        response = requests.post(url, headers=headers, json=data)
        response.raise_for_status()
        
        return response.json()

# Usage example
if __name__ == "__main__":
    client = VaultWardenClient(
        base_url="https://vault.example.com",
        email="user@example.com",
        password="user_password"
    )
    
    # Login
    client.login()
    print("Logged in successfully")
    
    # Get all items
    ciphers = client.get_ciphers()
    print(f"Found {len(ciphers['Data'])} vault items")
    
    # Create new login
    new_item = client.create_login(
        name="Example Service",
        username="user@example.com",
        password="secure_password",
        uri="https://example.com"
    )
    print(f"Created item: {new_item['Name']}")
```

### Bash Helper Functions

```bash
#!/bin/bash
# vaultwarden-api.sh

VAULT_URL="https://vault.example.com"
ACCESS_TOKEN=""

# Login and get access token
vw_login() {
    local email="$1"
    local password="$2"
    
    ACCESS_TOKEN=$(curl -s -X POST "$VAULT_URL/identity/connect/token" \\
      -H "Content-Type: application/x-www-form-urlencoded" \\
      -d "grant_type=password" \\
      -d "username=$email" \\
      -d "password=$password" \\
      -d "scope=api offline_access" \\
      -d "client_id=web" \\
      -d "deviceType=3" \\
      -d "deviceName=bash-client" \\
      -d "deviceIdentifier=bash-$(uuidgen)" | \\
      jq -r '.access_token')
    
    echo "Logged in successfully"
}

# Get all ciphers
vw_get_ciphers() {
    curl -s -X GET "$VAULT_URL/api/ciphers" \\
      -H "Authorization: Bearer $ACCESS_TOKEN" | \\
      jq '.'
}

# Create login item
vw_create_login() {
    local name="$1"
    local username="$2"
    local password="$3"
    local uri="$4"
    
    curl -s -X POST "$VAULT_URL/api/ciphers" \\
      -H "Authorization: Bearer $ACCESS_TOKEN" \\
      -H "Content-Type: application/json" \\
      -d "{
        \"type\": 1,
        \"name\": \"$name\",
        \"login\": {
          \"username\": \"$username\",
          \"password\": \"$password\",
          \"uris\": [{\"match\": null, \"uri\": \"$uri\"}]
        }
      }" | jq '.'
}

# Usage
vw_login "user@example.com" "password"
vw_get_ciphers
vw_create_login "Test Service" "testuser" "testpass" "https://test.com"
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

**Handling rate limits**:
```bash
# Implement retry with backoff
retry_api_call() {
    local max_attempts=3
    local attempt=1
    local wait=5
    
    while [ $attempt -le $max_attempts ]; do
        response=$(curl -s -w "\\n%{http_code}" "$@")
        http_code=$(echo "$response" | tail -1)
        
        if [ "$http_code" = "200" ]; then
            echo "$response" | head -n -1
            return 0
        elif [ "$http_code" = "429" ]; then
            echo "Rate limited, waiting ${wait}s..." >&2
            sleep $wait
            wait=$((wait * 2))
        else
            echo "Error: HTTP $http_code" >&2
            return 1
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}
```

## Further Resources

- **Bitwarden API Documentation**: https://bitwarden.com/help/api/
- **VaultWarden Wiki**: https://github.com/dani-garcia/vaultwarden/wiki
- **Official Bitwarden CLI**: https://bitwarden.com/help/cli/

---

This API guide provides comprehensive examples for integrating with VaultWarden-OCI programmatically, automating operations, and extending functionality through various programming languages and tools.
