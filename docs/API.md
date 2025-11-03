# API Reference - VaultWarden-OCI

This document provides API reference for interacting with VaultWarden-OCI components, including current enhanced health checks, atomic backup operations, administrative functions, and integration with the current template-based architecture with resource management and enhanced security.

## VaultWarden API (Current Implementation)

VaultWarden implements the Bitwarden API specification with current enhanced security features including rate limiting, forensic logging, and dual CF+UFW protection.

### Base URL Structure (Current)
```
https://vault.yourdomain.com/api/
```

### Authentication (Enhanced)
VaultWarden uses JWT tokens with current enhanced security:

```bash
# Login with current rate limiting protection
curl -X POST "https://vault.yourdomain.com/identity/connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=user@example.com&password=userpassword&scope=api&client_id=web"

# Response includes enhanced security context
{
  "access_token": "jwt_token_here",
  "expires_in": 3600,
  "token_type": "Bearer",
  "refresh_token": "refresh_token_here",
  "enhanced_security_active": true,
  "rate_limiting_active": true
}
```

### Current Health and Status Endpoints

#### System Health (Current Implementation)
```bash
# Public health endpoint (no auth required)
curl "https://vault.yourdomain.com/alive"
# Returns: 200 OK if service healthy

# Enhanced diagnostics with resource information
curl -H "Authorization: Bearer ADMIN_TOKEN" \
  "https://vault.yourdomain.com/admin/diagnostics"

# Current template validation endpoint  
curl -H "Authorization: Bearer ADMIN_TOKEN" \
  "https://vault.yourdomain.com/admin/config/validate"
```

#### Current Version Information
```bash
# Get current VaultWarden version with enhanced context
curl "https://vault.yourdomain.com/api/config"

# Response includes current implementation details
{
  "version": "1.30.5",
  "git_hash": "commit_hash", 
  "server_name": "Vaultwarden",
  "template_based": true,
  "resource_limits": true,
  "enhanced_security": true,
  "dual_blocking": true,
  "forensic_logging": "3GB"
}
```

## Current Management Script APIs

### Enhanced Health Check (Current health.sh)

#### Command Interface (Current)
```bash
# Basic health with current comprehensive checks
./health.sh
# Checks: Docker, containers, resources, templates, security

# Current comprehensive mode
./health.sh --comprehensive
# Adds: backups, secrets, fail2ban, break-glass, resource limits

# Current auto-heal with template repair
./health.sh --auto-heal
# Attempts fixes including template regeneration

# Current JSON output with enhanced metrics
./health.sh --comprehensive --json
```

#### Current Programmatic Output
```bash
# Current JSON format with enhanced status
{
  "status": "healthy|warning|error",
  "checks": {
    "docker": "pass|fail",
    "containers": "pass|fail", 
    "resources": "pass|fail",
    "templates": "pass|fail",
    "dual_fail2ban": "pass|fail",
    "forensic_logs": "pass|fail",
    "break_glass": "pass|fail",
    "resource_limits": "pass|fail"
  },
  "resource_usage": {
    "memory_percent": 45,
    "disk_percent": 25,
    "container_memory": "2.1GB/3.5GB"
  },
  "enhanced_features": {
    "dual_blocking": true,
    "forensic_capacity": "3GB",
    "atomic_backups": true
  }
}
```

### Current Backup Script (backup.sh)

#### Command Interface (Current Atomic Operations)
```bash
# Current atomic database backup
./backup.sh --type db
# Uses atomic operations, WAL checkpoints

# Current full backup with templates
./backup.sh --type full  
# Includes templates and current configuration

# Current emergency kit with complete context
./backup.sh --type emergency
# Self-contained recovery with current architecture

# Current enhanced listing
./backup.sh --list
# Shows: ID, type, date, time, size, integrity status
```

#### Current Programmatic Output  
```bash
# Current backup script returns enhanced information
{
  "backup_file": "/path/to/backup.age",
  "backup_type": "db|full|emergency",
  "size_bytes": 12345678,
  "encrypted": true,
  "verified": true,
  "atomic_operation": true,
  "includes_templates": true,
  "timestamp": "2024-10-25T22:30:00Z"
}
```

### Current Template Management API

#### Current Template Operations
```bash
# Validate current template configuration
docker compose -f docker-compose.yml.example config

# Apply current templates with validation
sudo ./setup.sh --force --domain $DOMAIN --email $ADMIN_EMAIL

# Check current template status
ls -la *.example
docker compose config >/dev/null && echo "Templates valid"
```

## Current Cloudflare Integration

### Current DNS Management
```bash
# Test current API connectivity
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CADDY_CF_TOKEN"

# Current DNS record management
curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CADDY_CF_TOKEN" | \
  jq '.result[] | select(.name == env.DOMAIN)'
```

### Current Enhanced Firewall Management
```bash
# Current dual-action firewall rules
curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules" \
  -H "Authorization: Bearer $FAIL2BAN_CF_TOKEN" | \
  jq '.result[] | select(.notes | contains("dual-action"))'

# Current rate limiting status
docker compose logs fail2ban | grep -E "Rate.*limit|CF.*ok|UFW.*ok"
```

## Current Docker Integration

### Current Container Management
```bash
# Current container status with resource limits
docker compose ps --format json | \
  jq '.[] | {name: .Name, status: .Status, memory_limit: .MemLimit}'

# Current resource usage
docker stats --no-stream --format json | \
  jq '.[] | {name: .Name, memory: .MemUsage, cpu: .CPUPerc}'

# Current template validation
docker compose config >/dev/null && echo "Configuration valid"
```

### Current Enhanced Log Management
```bash
# Current forensic log access (3GB capacity)
docker compose logs vaultwarden --since 24h --timestamps

# Current fail2ban with dual action logs
docker compose logs fail2ban | grep -E "CF.*ok|UFW.*ok|Rate"

# Current structured JSON logs
tail -f /var/lib/vaultwarden/logs/caddy/access.log | jq .
```

## Current Monitoring and Metrics

### Current System Metrics
```bash
# Current resource usage with limits
free -h && echo "Container limits:"
docker compose config | grep -E "memory:|cpus:"

# Current disk usage with forensic logs
df -h /var/lib/vaultwarden
du -sh /var/lib/vaultwarden/logs/

# Current network with dual blocking
netstat -tuln
docker compose logs fail2ban | grep -c "Ban.*CF.*UFW"
```

### Current Service Health
```bash
# Current service health with enhanced checks
curl -f "http://localhost/alive" && echo "VaultWarden: healthy"
docker compose config >/dev/null && echo "Templates: valid"

# Current fail2ban dual action status
docker compose exec fail2ban fail2ban-client ping && echo "fail2ban: healthy"
docker compose logs fail2ban | grep -q "dual.*action" && echo "Dual blocking: active"

# Current break-glass admin status
./create-breakglass-admin.sh status >/dev/null && echo "Break-glass: ready"
```

## Current Error Handling

### Current HTTP Status Codes
- **200 OK**: Success with current security headers
- **401 Unauthorized**: Enhanced with fail2ban tracking
- **403 Forbidden**: Triggers dual CF+UFW blocking
- **429 Too Many Requests**: Current rate limiting active
- **500 Internal Server Error**: Check current template config

### Current Script Exit Codes
- **0**: Success, templates valid, resources within limits
- **1**: General error
- **2**: Template configuration error
- **3**: Network/Cloudflare connectivity error
- **4**: Authentication/secrets error
- **5**: Resource constraint (memory/disk limits exceeded)
- **6**: Dual-action fail2ban error

### Current Enhanced Error Format
```json
{
  "error": "invalid_grant",
  "error_description": "Username or password incorrect",
  "ErrorModel": {
    "Message": "Authentication failed",
    "Object": "error"
  },
  "current_features": {
    "template_status": "valid",
    "resource_limits": "active", 
    "dual_blocking": true,
    "forensic_logging": "3GB",
    "rate_limiting": "active"
  }
}
```

## Current Rate Limiting

### Current Caddy Limits
```caddyfile
# Current rate limiting configuration
rate_limit {
    zone static_rl {
        capacity 20         # Current: password manager optimized
    }
    zone admin_rl {
        capacity 5          # Current: very strict admin
    }
    zone api_auth_rl {      # Current: API auth protection
        capacity 10         # 10 attempts per 5 minutes
    }
}
```

### Current Fail2Ban Limits
- **Admin panel**: 2 failures = 24h ban (dual CF+UFW)
- **Auth endpoints**: 3 failures = 2h ban (dual CF+UFW)  
- **API abuse**: 10 failures = 1h ban (dual CF+UFW)
- **Rate limiting**: Max 30 CF API calls/minute with backoff

## Current Development Testing

### Current Local Testing
```bash
# Current development override
cp docker-compose.override.yml.example docker-compose.override.yml
nano docker-compose.override.yml  # Disable Cloudflare requirements

# Current test with template validation
docker compose -f docker-compose.yml -f docker-compose.override.yml config
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d

# Current API testing
curl -k "https://localhost/alive"
./health.sh --comprehensive --json
```

---

**Current Implementation Status**: This API reference reflects the current VaultWarden-OCI implementation with:
- Resource optimization (container limits for 6GB systems)
- Dual CF+UFW fail2ban protection with idempotent operations  
- Enhanced forensic logging (3GB capacity with 60x retention improvement)
- Atomic backup operations with template integration
- Centralized security validation via lib/security.sh
- Break-glass emergency access with comprehensive validation

All API endpoints and management scripts work within this current enhanced architecture optimized for small teams requiring reliable, secure password management.
