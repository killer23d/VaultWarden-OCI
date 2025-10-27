# API Reference - VaultWarden-OCI-Simplified

This document provides API reference for interacting with VaultWarden-OCI-Simplified components, including health checks, backup operations, and administrative functions.

## VaultWarden API

VaultWarden implements the Bitwarden API specification, providing complete compatibility with Bitwarden clients.

### Base URL Structure

```
https://vault.yourdomain.com/api/
```

### Authentication

VaultWarden uses JWT tokens for API authentication:

```bash
# Login to get access token
curl -X POST "https://vault.yourdomain.com/identity/connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=user@example.com&password=userpassword&scope=api&client_id=web"

# Response includes access_token for subsequent requests
{
  "access_token": "jwt_token_here",
  "expires_in": 3600,
  "token_type": "Bearer",
  "refresh_token": "refresh_token_here"
}
```

### Health and Status Endpoints

#### System Health Check
```bash
# Public health endpoint (no auth required)
curl "https://vault.yourdomain.com/alive"
# Returns: 200 OK if service is healthy

# Detailed diagnostics (admin token required)
curl -H "Authorization: Bearer ADMIN_TOKEN" \
     "https://vault.yourdomain.com/admin/diagnostics"
```

#### Version Information
```bash
# Get VaultWarden version
curl "https://vault.yourdomain.com/api/config"

# Response includes server configuration
{
  "version": "1.30.5",
  "git_hash": "commit_hash",
  "server_name": "Vaultwarden"
}
```

### Administrative API Endpoints

#### Admin Panel Authentication
```bash
# Admin panel uses basic authentication
# Username: admin
# Password: configured in admin_basic_auth_hash

curl -u "admin:your_password" \
     "https://vault.yourdomain.com/admin/users"
```

#### User Management
```bash
# List all users (admin only)
curl -H "Authorization: Bearer ADMIN_TOKEN" \
     "https://vault.yourdomain.com/admin/users"

# Invite new user (admin only)
curl -X POST "https://vault.yourdomain.com/admin/invite" \
  -H "Authorization: Bearer ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email": "newuser@example.com"}'

# Delete user (admin only)
curl -X DELETE "https://vault.yourdomain.com/admin/users/{user_id}" \
  -H "Authorization: Bearer ADMIN_TOKEN"
```

#### Organization Management  
```bash
# List organizations (admin only)
curl -H "Authorization: Bearer ADMIN_TOKEN" \
     "https://vault.yourdomain.com/admin/organizations"

# Get organization details
curl -H "Authorization: Bearer ADMIN_TOKEN" \
     "https://vault.yourdomain.com/admin/organizations/{org_id}"
```

### Standard Bitwarden API

VaultWarden implements the full Bitwarden API. Key endpoints include:

#### Sync
```bash
# Get user's vault data
curl -H "Authorization: Bearer USER_TOKEN" \
     "https://vault.yourdomain.com/api/sync"
```

#### Ciphers (Password Items)
```bash
# List user's ciphers
curl -H "Authorization: Bearer USER_TOKEN" \
     "https://vault.yourdomain.com/api/ciphers"

# Create new cipher
curl -X POST "https://vault.yourdomain.com/api/ciphers" \
  -H "Authorization: Bearer USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": 1,
    "name": "Example Login",
    "login": {
      "username": "user@example.com",
      "password": "securepassword"
    }
  }'

# Update cipher
curl -X PUT "https://vault.yourdomain.com/api/ciphers/{cipher_id}" \
  -H "Authorization: Bearer USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{...updated_cipher_data}'

# Delete cipher
curl -X DELETE "https://vault.yourdomain.com/api/ciphers/{cipher_id}" \
  -H "Authorization: Bearer USER_TOKEN"
```

#### Folders
```bash
# List folders
curl -H "Authorization: Bearer USER_TOKEN" \
     "https://vault.yourdomain.com/api/folders"

# Create folder
curl -X POST "https://vault.yourdomain.com/api/folders" \
  -H "Authorization: Bearer USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Work Accounts"}'
```

## Management Script APIs

### Health Check Script (health.sh)

#### Command Line Interface
```bash
# Basic health check
./health.sh
# Exit code: 0 = healthy, 1 = issues detected

# Comprehensive check
./health.sh --comprehensive
# Returns detailed status of all components

# Auto-heal mode
./health.sh --auto-heal
# Attempts to fix detected issues automatically

# Email alert mode
./health.sh --email-alert
# Sends email notification if errors detected

# Quiet mode
./health.sh --quiet
# Only outputs warnings and errors

# Combined options
./health.sh --comprehensive --auto-heal --email-alert
```

#### Programmatic Output
```bash
# JSON output format (when piped or redirected)
./health.sh --comprehensive --quiet 2>/dev/null | tail -1
# Returns JSON with health status
{
  "status": "healthy|warning|error",
  "checks": {
    "docker": "pass|fail",
    "containers": "pass|fail", 
    "resources": "pass|fail",
    "network": "pass|fail",
    "backups": "pass|fail",
    "secrets": "pass|fail"
  },
  "warnings": 2,
  "errors": 0,
  "timestamp": "2024-10-25T22:30:00Z"
}
```

### Backup Script (backup.sh)

#### Command Line Interface
```bash
# Database backup (default)
./backup.sh
# Returns: path to encrypted backup file

# Full system backup  
./backup.sh --type full
# Returns: path to encrypted backup archive

# Emergency recovery kit
./backup.sh --type emergency  
# Returns: path to encrypted emergency kit

# Backup with cloud sync
./backup.sh --type db --rclone
# Creates backup and syncs to configured remote

# Backup with email notification
./backup.sh --type full --email
# Sends email on completion (success or failure)

# Combined options
./backup.sh --type full --rclone --email
```

#### Programmatic Output
```bash
# Backup script returns path on success
BACKUP_FILE=$(./backup.sh --type db 2>/dev/null | tail -1)
echo "Backup created: $BACKUP_FILE"

# Check exit code for success/failure
if ./backup.sh --type db >/dev/null 2>&1; then
  echo "Backup successful"
else
  echo "Backup failed"
fi
```

### Update Script (update.sh)

#### Command Line Interface
```bash
# Update containers
./update.sh --type containers
# Updates Docker images to versions specified in .env

# Check for updates only
./update.sh --type containers --check-only
# Shows available updates without applying

# Update specific service
./update.sh --type containers --service vaultwarden
# Updates only specified container

# System package updates (requires sudo)
sudo ./update.sh --type system
# Updates Ubuntu/Debian packages

# System update with auto-reboot
sudo ./update.sh --type system --auto-reboot
# Reboots automatically if kernel updated
```

### Maintenance Script (maintenance.sh)

#### Command Line Interface
```bash
# Standard maintenance
sudo ./maintenance.sh --type standard
# Log cleanup, old backup removal, Docker cleanup

# Deep system maintenance  
sudo ./maintenance.sh --type deep
# Standard + system cache cleanup, temp files

# Docker-only cleanup
sudo ./maintenance.sh --type docker
# Docker images, containers, volumes, networks

# Preview mode
sudo ./maintenance.sh --dry-run
# Shows what would be done without executing

# Force mode (no confirmations)
sudo ./maintenance.sh --force --type deep
```

## Cloudflare API Integration

### DNS Management (ddclient)

The ddclient service automatically manages DNS records:

#### Manual DNS Updates
```bash
# Test Cloudflare API connectivity
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
     -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN"

# List DNS records
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records" \
     -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN"

# Update DNS record
curl -X PUT "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records/RECORD_ID" \
     -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "type": "A",
       "name": "vault.yourdomain.com", 
       "content": "NEW_IP_ADDRESS",
       "ttl": 1
     }'
```

### Firewall Management (fail2ban)

fail2ban automatically manages Cloudflare firewall rules:

#### Manual IP Management
```bash
# List firewall rules
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules" \
     -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"

# Block IP address
curl -X POST "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules" \
     -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "mode": "block",
       "configuration": {
         "target": "ip",
         "value": "MALICIOUS_IP"
       },
       "notes": "Blocked by fail2ban"
     }'

# Unblock IP address  
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules/RULE_ID" \
     -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"
```

## Docker API Integration

### Container Management

#### Service Status
```bash
# Check container status
docker compose ps --format json
# Returns JSON array of container information

# Get container health
docker inspect vaultwarden_app --format='{{.State.Health.Status}}'
# Returns: healthy|unhealthy|starting

# Container resource usage
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}"
```

#### Log Management  
```bash
# Get container logs with timestamps
docker compose logs --timestamps --tail=100 vaultwarden

# Follow logs in real-time
docker compose logs --follow vaultwarden

# Export logs for analysis
docker compose logs --since="24h" vaultwarden > vaultwarden-24h.log
```

#### Service Control
```bash
# Restart specific service
docker compose restart vaultwarden

# Scale services (if applicable)
docker compose up -d --scale vaultwarden=2

# Update service with new image
docker compose pull vaultwarden
docker compose up -d vaultwarden
```

## Monitoring and Metrics

### Prometheus-Compatible Metrics

VaultWarden doesn't expose Prometheus metrics by default, but you can monitor via:

#### System Metrics Collection
```bash
# CPU usage
cat /proc/loadavg

# Memory usage
cat /proc/meminfo | grep -E "(MemTotal|MemAvailable|MemFree)"

# Disk usage
df -h /var/lib/vaultwarden | tail -1

# Network statistics
cat /proc/net/dev | grep -v "lo:"
```

#### Container Metrics
```bash
# Docker stats in JSON format
docker stats --no-stream --format json

# Container resource limits
docker inspect vaultwarden_app | jq '.[0].HostConfig.Memory'
docker inspect vaultwarden_app | jq '.[0].HostConfig.NanoCpus'

# Container uptime
docker inspect vaultwarden_app | jq '.[0].State.StartedAt'
```

### Custom Health Endpoints

#### Service-Specific Health Checks
```bash
# VaultWarden health
curl -f "http://localhost/alive" >/dev/null 2>&1 && echo "healthy" || echo "unhealthy"

# Caddy health  
curl -f "http://localhost:2019/config/" >/dev/null 2>&1 && echo "healthy" || echo "unhealthy"

# fail2ban status
docker compose exec fail2ban fail2ban-client ping 2>/dev/null && echo "healthy" || echo "unhealthy"

# ddclient process check
docker compose exec ddclient pidof ddclient >/dev/null 2>&1 && echo "healthy" || echo "unhealthy"
```

## Webhook Integration

### Backup Completion Webhooks

You can extend the backup script to send webhooks:

```bash
# Add to backup.sh after successful backup
if [[ $backup_exit_code -eq 0 ]]; then
  # Send success webhook
  curl -X POST "https://your-monitoring-system.com/webhook" \
    -H "Content-Type: application/json" \
    -d '{
      "service": "vaultwarden",
      "event": "backup_completed", 
      "status": "success",
      "backup_type": "'$BACKUP_TYPE'",
      "backup_file": "'$(basename "$backup_file")'",
      "timestamp": "'$(date -uIs)'"
    }'
else
  # Send failure webhook
  curl -X POST "https://your-monitoring-system.com/webhook" \
    -H "Content-Type: application/json" \
    -d '{
      "service": "vaultwarden",
      "event": "backup_failed",
      "status": "failure", 
      "backup_type": "'$BACKUP_TYPE'",
      "timestamp": "'$(date -uIs)'"
    }'
fi
```

### Health Check Webhooks

Similarly, extend health.sh for monitoring integration:

```bash
# Add to health.sh after checks complete
curl -X POST "https://your-monitoring-system.com/webhook" \
  -H "Content-Type: application/json" \
  -d '{
    "service": "vaultwarden",
    "event": "health_check",
    "status": "'$([ $ERRORS -eq 0 ] && echo "healthy" || echo "unhealthy")'",
    "warnings": '$WARNINGS',
    "errors": '$ERRORS',
    "timestamp": "'$(date -uIs)'"
  }'
```

## Error Handling and Response Codes

### HTTP Status Codes

VaultWarden follows standard HTTP status codes:

- **200 OK**: Successful request
- **400 Bad Request**: Invalid request format
- **401 Unauthorized**: Invalid or missing authentication  
- **403 Forbidden**: Valid auth but insufficient permissions
- **404 Not Found**: Resource doesn't exist
- **429 Too Many Requests**: Rate limit exceeded
- **500 Internal Server Error**: Server-side error

### Script Exit Codes

Management scripts use consistent exit codes:

- **0**: Success, no issues
- **1**: General error or failure
- **2**: Configuration error
- **3**: Network/connectivity error  
- **4**: Permission/authentication error
- **5**: Resource constraint (disk, memory)

### Error Response Format

API errors return JSON with details:

```json
{
  "error": "invalid_grant",
  "error_description": "Username or password is incorrect. Try again.",
  "ErrorModel": {
    "Message": "Username or password is incorrect. Try again.",
    "Object": "error"
  }
}
```

## Rate Limiting

### Caddy Rate Limits

Configured in Caddyfile:

- **Admin endpoints**: 5 requests per 10 minutes per IP
- **API endpoints**: 20 requests per minute per IP  
- **General requests**: Cloudflare handles edge rate limiting

### fail2ban Rate Limits  

Configured in jail settings:

- **Admin panel**: 3 failures in 5 minutes = 6 hour ban
- **API endpoints**: 10 failures in 10 minutes = 6 hour ban
- **Bot detection**: 2 suspicious requests in 1 hour = 24 hour ban

### Cloudflare Rate Limits

Cloudflare provides additional rate limiting at the edge:

- **DDoS protection**: Automatic volumetric attack mitigation
- **WAF rules**: Application-level attack prevention
- **Bot management**: Automated bot detection and challenges

## Development and Testing

### Local Testing Environment

```bash
# Create override file for development
cp docker-compose.override.yml.example docker-compose.override.yml

# Edit for local testing (disable Cloudflare requirements, etc.)
nano docker-compose.override.yml

# Start with override
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d

# Test API locally
curl -k "https://localhost/alive"
```

### API Testing Tools

#### Using curl
```bash
# Test admin authentication
curl -u "admin:password" "https://vault.yourdomain.com/admin/users"

# Test API authentication flow
TOKEN=$(curl -s -X POST "https://vault.yourdomain.com/identity/connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=test@example.com&password=testpass&scope=api&client_id=web" \
  | jq -r '.access_token')

curl -H "Authorization: Bearer $TOKEN" "https://vault.yourdomain.com/api/sync"
```

#### Using HTTPie (alternative)
```bash
# Install HTTPie
sudo apt install httpie

# Test endpoints
http GET https://vault.yourdomain.com/alive
http --auth admin:password GET https://vault.yourdomain.com/admin/users
```

---

**Note**: This API reference covers the key integration points for VaultWarden-OCI-Simplified. For complete Bitwarden API documentation, refer to the official Bitwarden API specification.
