# API Reference - VaultWarden-OCI

This document provides API reference for interacting with VaultWarden-OCI components, including enhanced health checks, backup operations, administrative functions, and integration with the template-based architecture.

## VaultWarden API

VaultWarden implements the Bitwarden API specification, providing complete compatibility with Bitwarden clients while adding enhanced administrative capabilities.

### Base URL Structure

```
https://vault.yourdomain.com/api/
```

### Authentication

VaultWarden uses JWT tokens for API authentication with enhanced security features:

```bash
# Login to get access token
curl -X POST "https://vault.yourdomain.com/identity/connect/token"   -H "Content-Type: application/x-www-form-urlencoded"   -d "grant_type=password&username=user@example.com&password=userpassword&scope=api&client_id=web"

# Response includes access_token for subsequent requests
{
  "access_token": "jwt_token_here",
  "expires_in": 3600,
  "token_type": "Bearer",
  "refresh_token": "refresh_token_here"
}
```

### Health and Status Endpoints

#### System Health Check with Template Validation
```bash
# Public health endpoint (no auth required)
curl "https://vault.yourdomain.com/alive"
# Returns: 200 OK if service is healthy

# Enhanced diagnostics (admin token required)
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/diagnostics"

# Template configuration validation endpoint
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/config/validate"
```

#### Version Information with Template Context
```bash
# Get VaultWarden version and template information
curl "https://vault.yourdomain.com/api/config"

# Response includes server configuration and template status
{
  "version": "1.30.5",
  "git_hash": "commit_hash",
  "server_name": "Vaultwarden",
  "template_based": true,
  "enhanced_security": true
}
```

### Enhanced Administrative API Endpoints

#### Admin Panel Authentication with Template-Based Security
```bash
# Admin panel uses enhanced basic authentication
# Username: admin
# Password: configured in admin_basic_auth_hash (bcrypt)

curl -u "admin:your_password"      "https://vault.yourdomain.com/admin/users"

# Admin token authentication (enhanced security)
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/users"
```

#### Enhanced User Management
```bash
# List all users with enhanced details (admin only)
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/users"

# Invite new user with enhanced validation (admin only)
curl -X POST "https://vault.yourdomain.com/admin/invite"   -H "Authorization: Bearer ADMIN_TOKEN"   -H "Content-Type: application/json"   -d '{"email": "newuser@example.com"}'

# Delete user with audit logging (admin only)
curl -X DELETE "https://vault.yourdomain.com/admin/users/{user_id}"   -H "Authorization: Bearer ADMIN_TOKEN"

# Get user activity with enhanced logging
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/users/{user_id}/events"
```

#### Organization Management with Enhanced Features
```bash
# List organizations with template-based configuration (admin only)
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/organizations"

# Get organization details with enhanced metrics
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/organizations/{org_id}"

# Organization events with enhanced logging
curl -H "Authorization: Bearer ADMIN_TOKEN"      "https://vault.yourdomain.com/admin/organizations/{org_id}/events"
```

### Standard Bitwarden API

VaultWarden implements the full Bitwarden API with enhanced security features:

#### Sync with Enhanced Security
```bash
# Get user's vault data with enhanced validation
curl -H "Authorization: Bearer USER_TOKEN"      "https://vault.yourdomain.com/api/sync"
```

#### Ciphers (Password Items) with Enhanced Features
```bash
# List user's ciphers with enhanced metadata
curl -H "Authorization: Bearer USER_TOKEN"      "https://vault.yourdomain.com/api/ciphers"

# Create new cipher with enhanced validation
curl -X POST "https://vault.yourdomain.com/api/ciphers"   -H "Authorization: Bearer USER_TOKEN"   -H "Content-Type: application/json"   -d '{
    "type": 1,
    "name": "Example Login",
    "login": {
      "username": "user@example.com",
      "password": "securepassword"
    }
  }'

# Update cipher with audit logging
curl -X PUT "https://vault.yourdomain.com/api/ciphers/{cipher_id}"   -H "Authorization: Bearer USER_TOKEN"   -H "Content-Type: application/json"   -d '{...updated_cipher_data}'

# Delete cipher with enhanced logging
curl -X DELETE "https://vault.yourdomain.com/api/ciphers/{cipher_id}"   -H "Authorization: Bearer USER_TOKEN"
```

## Management Script APIs

### Enhanced Health Check Script (health.sh)

#### Command Line Interface with Template Validation
```bash
# Basic health check with template validation
./health.sh
# Exit code: 0 = healthy, 1 = issues detected

# Comprehensive check with template validation
./health.sh --comprehensive
# Returns detailed status of all components including templates

# Auto-heal mode with template repair
./health.sh --auto-heal
# Attempts to fix detected issues including template regeneration

# Email alert mode with enhanced notifications
./health.sh --email-alert
# Sends email notification if errors detected

# JSON output with template status
./health.sh --comprehensive --json
# Returns structured JSON with template validation status
```

#### Enhanced Programmatic Output
```bash
# JSON output format with template validation
./health.sh --comprehensive --quiet 2>/dev/null | tail -1
# Returns JSON with enhanced health status
{
  "status": "healthy|warning|error",
  "checks": {
    "docker": "pass|fail",
    "containers": "pass|fail", 
    "resources": "pass|fail",
    "network": "pass|fail",
    "backups": "pass|fail",
    "secrets": "pass|fail",
    "templates": "pass|fail",
    "fail2ban_enhanced": "pass|fail",
    "breakglass_admin": "pass|fail"
  },
  "warnings": 2,
  "errors": 0,
  "timestamp": "2024-10-25T22:30:00Z"
}
```

### Enhanced Backup Script (backup.sh)

#### Command Line Interface with Atomic Operations
```bash
# Enhanced database backup with atomic operations
./backup.sh
# Returns: path to encrypted backup file

# Full system backup with template preservation
./backup.sh --type full
# Returns: path to encrypted backup archive including templates

# Emergency recovery kit with complete template context
./backup.sh --type emergency  
# Returns: path to encrypted emergency kit with templates

# Enhanced listing with detailed information
./backup.sh --list
# Shows: ID, Type, Date, Time, Size, Filename in formatted table

# Backup with enhanced verification
./backup.sh --type db --verify --rclone --email
# Creates backup with full verification, cloud sync, and notification
```

#### Enhanced Programmatic Output
```bash
# Backup script returns enhanced information
BACKUP_INFO=$(./backup.sh --type db --json 2>/dev/null | tail -1)
echo "Backup details: $BACKUP_INFO"

# Enhanced status checking
if ./backup.sh --type db --verify >/dev/null 2>&1; then
  echo "Atomic backup successful with verification"
else
  echo "Backup failed - check logs"
fi
```

### Enhanced Update Script (update.sh)

#### Command Line Interface with Template Integration
```bash
# Enhanced container updates with template validation
./update.sh --type containers
# Updates Docker images with template validation

# Check for updates with template compatibility
./update.sh --type containers --check-only --template-validate
# Shows available updates and template compatibility

# Update specific service with template awareness
./update.sh --type containers --service vaultwarden --template-validate
# Updates specific container with template validation

# System updates with enhanced safety
sudo ./update.sh --type system --backup --template-preserve
# Updates packages while preserving template configuration
```

### Template Management API

#### Template Validation and Generation
```bash
# Validate current template configuration
docker compose config
# Returns: validation status of template-generated configuration

# Generate configuration from templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com
# Regenerates configuration files from templates

# Template difference checking
diff docker-compose.yml.example docker-compose.yml
diff .env.example .env
# Shows differences between templates and generated files
```

## Enhanced Cloudflare API Integration

### DNS Management with Enhanced Error Handling

The ddclient service automatically manages DNS records with enhanced reliability:

#### Manual DNS Updates with Template Integration
```bash
# Test Cloudflare API connectivity with enhanced validation
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify"      -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN"

# List DNS records with template context
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records"      -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN"      | jq '.result[] | select(.name == env.DOMAIN)'

# Update DNS record with enhanced validation
curl -X PUT "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records/RECORD_ID"      -H "Authorization: Bearer YOUR_DDCLIENT_TOKEN"      -H "Content-Type: application/json"      -d '{
       "type": "A",
       "name": "vault.yourdomain.com", 
       "content": "NEW_IP_ADDRESS",
       "ttl": 1,
       "proxied": true
     }'
```

### Enhanced Firewall Management (fail2ban)

fail2ban automatically manages Cloudflare firewall rules with rate limiting:

#### Manual IP Management with Enhanced Features
```bash
# List firewall rules with enhanced filtering
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules"      -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"      | jq '.result[] | select(.notes | contains("fail2ban"))'

# Block IP address with enhanced metadata
curl -X POST "https://api.cloudflare.com/client/v4/zones/ZONE_ID/firewall/access_rules/rules"      -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"      -H "Content-Type: application/json"      -d '{
       "mode": "block",
       "configuration": {
         "target": "ip",
         "value": "MALICIOUS_IP"
       },
       "notes": "Blocked by enhanced fail2ban - rate limited"
     }'

# Check rate limiting status
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify"      -H "Authorization: Bearer YOUR_FAIL2BAN_TOKEN"      | jq '.result.status'
```

## Enhanced Docker API Integration

### Container Management with Template Awareness

#### Service Status with Template Validation
```bash
# Check container status with template information
docker compose ps --format json | jq '.[] | {name: .Name, status: .Status, image: .Image}'

# Get container health with enhanced checks
docker inspect vaultwarden_app --format='{{.State.Health.Status}}'
# Returns: healthy|unhealthy|starting

# Validate container configuration against templates
docker compose config --quiet && echo "Template configuration valid"
```

#### Enhanced Log Management  
```bash
# Get container logs with template context
docker compose logs --timestamps --tail=100 vaultwarden

# Enhanced fail2ban logs with rate limiting information
docker compose logs fail2ban | grep -E "Rate|Ban|Enhanced"

# Export logs for analysis with template metadata
docker compose logs --since="24h" > vaultwarden-enhanced-logs.txt
echo "Template Status: $(docker compose config >/dev/null 2>&1 && echo 'Valid' || echo 'Invalid')" >> vaultwarden-enhanced-logs.txt
```

#### Service Control with Enhanced Safety
```bash
# Restart specific service with template validation
docker compose config && docker compose restart vaultwarden

# Force restart with template regeneration if needed
./startup.sh --force-restart

# Update service with enhanced validation
docker compose pull vaultwarden
docker compose config
docker compose up -d vaultwarden
```

## Enhanced Monitoring and Metrics

### Template-Aware Health Endpoints

VaultWarden-OCI provides enhanced monitoring capabilities:

#### System Metrics Collection with Template Status
```bash
# Enhanced CPU usage with template validation status
cat /proc/loadavg
echo "Template Status: $(docker compose config >/dev/null 2>&1 && echo 'Valid' || echo 'Invalid')"

# Memory usage with container resource limits from templates
free -m
docker compose config | grep -E "memory:|mem_limit:"

# Disk usage with backup retention from templates
df -h /var/lib/vaultwarden
source .env && echo "Backup retention: ${BACKUP_RETENTION_DAYS:-30} days"

# Network statistics with enhanced fail2ban metrics
cat /proc/net/dev | grep -v "lo:"
docker compose logs fail2ban | grep -c "Rate limit"
```

#### Enhanced Container Metrics
```bash
# Docker stats with template-defined limits
docker stats --no-stream --format json | jq '.[] | {name: .Name, cpu: .CPUPerc, memory: .MemUsage}'

# Container resource limits from templates
docker compose config | grep -A 5 -B 5 "deploy:"

# Enhanced container uptime with template generation time
docker inspect vaultwarden_app | jq '.[0].State.StartedAt'
ls -la docker-compose.yml | awk '{print "Template generated: " $6, $7, $8}'
```

### Enhanced Custom Health Endpoints

#### Service-Specific Health Checks with Template Validation
```bash
# VaultWarden health with template status
curl -f "http://localhost/alive" >/dev/null 2>&1 && echo "VaultWarden: healthy" || echo "VaultWarden: unhealthy"
docker compose config >/dev/null 2>&1 && echo "Templates: valid" || echo "Templates: invalid"

# Caddy health with configuration validation
curl -f "http://localhost:2019/config/" >/dev/null 2>&1 && echo "Caddy: healthy" || echo "Caddy: unhealthy"

# Enhanced fail2ban status with rate limiting check
docker compose exec fail2ban fail2ban-client ping 2>/dev/null && echo "fail2ban: healthy" || echo "fail2ban: unhealthy"
docker compose logs fail2ban | grep -q "Rate limit active" && echo "fail2ban: rate limiting active"

# Break-glass admin status
./create-breakglass-admin.sh status >/dev/null 2>&1 && echo "Break-glass: ready" || echo "Break-glass: not configured"
```

## Enhanced Error Handling and Response Codes

### HTTP Status Codes with Enhanced Context

VaultWarden follows standard HTTP status codes with enhanced error information:

- **200 OK**: Successful request with template validation
- **400 Bad Request**: Invalid request format (check template configuration)
- **401 Unauthorized**: Invalid or missing authentication (check secrets)
- **403 Forbidden**: Valid auth but insufficient permissions (check admin settings)
- **404 Not Found**: Resource doesn't exist (check template URLs)
- **429 Too Many Requests**: Rate limit exceeded (enhanced fail2ban active)
- **500 Internal Server Error**: Server-side error (check template configuration)

### Enhanced Script Exit Codes

Management scripts use consistent exit codes with template awareness:

- **0**: Success, no issues, templates valid
- **1**: General error or failure
- **2**: Configuration error (check templates)
- **3**: Network/connectivity error  
- **4**: Permission/authentication error (check secrets)
- **5**: Resource constraint (disk, memory)
- **6**: Template validation error

### Enhanced Error Response Format

API errors return JSON with enhanced details:

```json
{
  "error": "invalid_grant",
  "error_description": "Username or password is incorrect. Try again.",
  "ErrorModel": {
    "Message": "Username or password is incorrect. Try again.",
    "Object": "error"
  },
  "template_status": "valid",
  "enhanced_security": true,
  "fail2ban_active": true
}
```

## Enhanced Rate Limiting

### Caddy Rate Limits with Template Configuration

Configured in Caddyfile with template awareness:

- **Admin endpoints**: 5 requests per 10 minutes per IP
- **API endpoints**: 20 requests per minute per IP  
- **General requests**: Cloudflare handles edge rate limiting
- **Template validation**: No rate limiting for internal health checks

### Enhanced fail2ban Rate Limits  

Configured with enhanced rate limiting safeguards:

- **Admin panel**: 3 failures in 5 minutes = 6 hour ban
- **API endpoints**: 10 failures in 10 minutes = 6 hour ban
- **Bot detection**: 2 suspicious requests in 1 hour = 24 hour ban
- **API rate limiting**: Maximum 30 Cloudflare API calls per minute with backoff

### Cloudflare Rate Limits with Enhanced Integration

Cloudflare provides additional rate limiting at the edge:

- **DDoS protection**: Automatic volumetric attack mitigation
- **WAF rules**: Application-level attack prevention  
- **Bot management**: Automated bot detection and challenges
- **Enhanced fail2ban integration**: API-driven IP blocking with rate limiting

## Development and Testing with Templates

### Local Testing Environment with Template Override

```bash
# Create override file for development testing
cp docker-compose.override.yml.example docker-compose.override.yml

# Edit for local testing (disable Cloudflare requirements, etc.)
nano docker-compose.override.yml

# Start with override and template validation
docker compose -f docker-compose.yml -f docker-compose.override.yml config
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d

# Test API locally with template awareness
curl -k "https://localhost/alive"
```

---

**Note**: This API reference covers the enhanced integration points for VaultWarden-OCI with template-based architecture, atomic backup operations, enhanced fail2ban security with rate limiting, and comprehensive emergency access capabilities. For complete Bitwarden API documentation, refer to the official Bitwarden API specification.
