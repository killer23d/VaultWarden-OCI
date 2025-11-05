# Advanced Customization Guide - VaultWarden-OCI

This guide covers advanced customization options for power users who need to extend or modify VaultWarden-OCI beyond its default configuration while maintaining the current template-based architecture, resource optimization, and enhanced security features.

## Current Customization Philosophy

VaultWarden-OCI's current architecture supports advanced customizations through:

- **Template-Based Configuration**: Work within `.example` template system
- **Resource-Aware Design**: Respect container limits for 6GB systems
- **Enhanced Security**: Maintain dual CF+UFW blocking and centralized security
- **Atomic Operations**: Preserve backup integrity and system reliability
- **Forensic Logging**: Work with enhanced 3GB log retention system
- **Emergency Access**: Maintain break-glass admin compatibility
- **Containerized Email**: Use the msmtpd relay for decoupled SMTP by default (host msmtp-mta optional)

## Current Template Structure

### Configuration Files (Current State)
```
📁 Template Architecture
├── docker-compose.yml.example          # Service definitions with resource limits
├── docker-compose.override.yml.example # Optional email decoupling (msmtpd)
├── .env.example                        # Environment variables
├── Generated Files (never edit directly):
│   ├── docker-compose.yml              # Generated with resource limits
│   └── .env                            # Generated with current values
├── Static Configuration:
│   ├── caddy/Caddyfile                 # Enhanced logging (3GB retention)
│   ├── fail2ban/action.d/cloudflare-apiv4.conf  # Dual CF+UFW action
│   └── fail2ban/filter.d/               # Regex-based filters (no deps)
└── lib/
    ├── common.sh                       # Shared utilities
    ├── security.sh                     # Centralized security validation
    ├── docker.sh                       # Docker management
    └── crypto.sh                       # Encryption functions
```

### Current Customization Workflow
```bash
# 1. Edit templates (source of truth)
nano docker-compose.yml.example
nano .env.example

# 2. Validate templates
docker compose -f docker-compose.yml.example config

# 3. Apply changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Restart and verify
./startup.sh --force-restart
./health.sh --comprehensive
```

## Current Resource Management Customizations

### Container Resource Tuning (Current Limits)
Edit `docker-compose.yml.example` for resource optimization:

```yaml
# Current optimized limits for 6GB systems
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          memory: ${VAULTWARDEN_MEMORY_LIMIT:-2G}     # Balanced for main app
          cpus: '${VAULTWARDEN_CPU_LIMIT:-0.6}'       # 60% single CPU
        reservations:
          memory: 512M                               # Guaranteed minimum
          cpus: '0.2'                               # 20% guaranteed

  caddy:
    deploy:
      resources:
        limits:
          memory: ${CADDY_MEMORY_LIMIT:-1G}          # SSL + forensic logs
          cpus: '${CADDY_CPU_LIMIT:-0.3}'           # 30% single CPU
        reservations:
          memory: 256M                              # Minimum for SSL
          cpus: '0.1'                              # 10% guaranteed

  fail2ban:
    deploy:
      resources:
        limits:
          memory: ${FAIL2BAN_MEMORY_LIMIT:-512M}     # Log processing
          cpus: '${FAIL2BAN_CPU_LIMIT:-0.2}'        # 20% single CPU
        reservations:
          memory: 128M                              # Minimum for processing
          cpus: '0.05'                             # 5% guaranteed

  msmtpd:
    deploy:
      resources:
        limits:
          memory: ${MSMTPD_MEMORY_LIMIT:-32M}       # Lightweight relay
          cpus: '${MSMTPD_CPU_LIMIT:-0.05}'         # 5% single CPU
        reservations:
          memory: 8M                                # Minimal reservation
          cpus: '0.01'                              # Minimal CPU
```

### Environment Template Extensions (Current)
Add to `.env.example` for custom resource management:

```bash
# Current resource optimization variables
VAULTWARDEN_MEMORY_LIMIT=2G
VAULTWARDEN_CPU_LIMIT=0.6
CADDY_MEMORY_LIMIT=1G
CADDY_CPU_LIMIT=0.3
FAIL2BAN_MEMORY_LIMIT=512M
FAIL2BAN_CPU_LIMIT=0.2
MSMTPD_MEMORY_LIMIT=32M
MSMTPD_CPU_LIMIT=0.05

# Enhanced security settings (current)
PASSWORD_ITERATIONS=350000
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
WEBSOCKET_ENABLED=false

# Current forensic logging settings
LOG_LEVEL=warn
EXTENDED_LOGGING=true
```

## Enhanced Security Customizations (Current)

### Advanced VaultWarden Security (Current Implementation)
```yaml
# In docker-compose.yml.example, current security settings:
services:
  vaultwarden:
    environment:
      # Current security configuration
      SIGNUPS_ALLOWED: ${SIGNUPS_ALLOWED:-false}
      INVITATIONS_ALLOWED: ${INVITATIONS_ALLOWED:-true}
      EMERGENCY_ACCESS_ALLOWED: ${EMERGENCY_ACCESS_ALLOWED:-true}
      PASSWORD_ITERATIONS: ${PASSWORD_ITERATIONS:-350000}
      PASSWORD_HINTS_ALLOWED: ${PASSWORD_HINTS_ALLOWED:-false}
      SHOW_PASSWORD_HINT: ${SHOW_PASSWORD_HINT:-false}

      # Enhanced logging (current)
      LOG_FILE: /logs/vaultwarden.log
      LOG_LEVEL: ${LOG_LEVEL:-warn}
      EXTENDED_LOGGING: ${EXTENDED_LOGGING:-true}

      # Current session management
      SESSION_TIMEOUT: ${SESSION_TIMEOUT:-3600}

    # Current security constraints
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

### Enhanced Caddy Customizations (Current Configuration)
Modify `caddy/Caddyfile` for advanced features:

```caddyfile
# Current enhanced rate limiting
rate_limit {
    zone static_rl {
        key {remote_host}
        capacity 20         # Current: stricter for password manager
    }

    zone admin_rl {
        key {remote_host}
        match /admin*
        capacity 5          # Current: very strict for admin
    }

    # Current: API auth rate limiting
    zone api_auth_rl {
        key {remote_host}
        match_path /api/accounts/prelogin /identity/connect/token
        window 5m
        capacity 10         # Current: 10 auth attempts per 5 min
    }
}

# Current enhanced logging (3GB capacity)
log {
    output file /logs/access.log {
        roll_size 50MB      # Current: increased from 10MB
        roll_keep 20        # Current: increased from 5 files
        roll_keep_for 30d   # Current: 30-day retention
    }
    format json {
        time_format "2006-01-02T15:04:05.000Z07:00"
        message_key "msg"
    }
}

# Current specialized logging
@admin path /admin*
handle @admin {
    log {
        output file /logs/admin_access.log {
            roll_size 25MB
            roll_keep 30      # Current: 90-day retention
            roll_keep_for 90d
        }
        format json {
            message_key "admin_access"
        }
    }
    # ... admin handling
}
```

## Current Fail2Ban Enhancements

### Advanced Dual-Action Configuration (Current)
The current `fail2ban/action.d/cloudflare-apiv4.conf` provides:

```ini
# Current dual CF+UFW action features:
# - Idempotent operations (checks existing rules)
# - Retry logic with exponential backoff  
# - UFW fallback if Cloudflare fails
# - Transactional ban/unban operations
# - Comprehensive logging and status reporting
```

### Custom Filter Development (Current Approach)
Create additional filters using current regex-based approach:

```ini
# fail2ban/filter.d/custom-patterns.conf
[Definition]
# Custom attack pattern detection (current regex approach)
failregex = ^.*"remote_ip":"<HOST>".*"uri":"/custom-endpoint".*"status":40[13].*$
            ^.*"remote_ip":"<HOST>".*"method":"TRACE".*$

ignoreregex = ^.*"user_agent":".*Bitwarden.*".*$
```

## Database and Performance Customizations (Current)

### SQLite Optimization (Current Implementation)
```yaml
# In docker-compose.yml.example, current DB configuration:
services:
  vaultwarden:
    environment:
      # Current database settings
      DATABASE_MAX_CONNS: ${DATABASE_MAX_CONNS:-10}
      DATABASE_URL: data/db.sqlite3

    # Current optimized data directory
    volumes:
      - ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data:/data
```

### Database Monitoring (Current db-maint.sh Integration)
```bash
#!/bin/bash
# Custom monitoring with current db-maint.sh integration

source "lib/common.sh"
source "lib/security.sh"
init_common_lib "$0"

# Use current database path
DB_PATH="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/data/bwdata/db.sqlite3"

# Enhanced monitoring with current atomic operations
monitor_db_with_atomic_safety() {
    # Stop VaultWarden for safe analysis
    docker compose stop vaultwarden

    # Current database analysis
    sqlite3 "$DB_PATH" << SQL
PRAGMA integrity_check;
PRAGMA optimize;
PRAGMA analysis_limit=1000;
PRAGMA optimize;
SQL

    # Restart service
    docker compose start vaultwarden

    # Verify health
    ./health.sh --comprehensive
}
```

## Current Monitoring Integration

### Forensic Log Analysis (Current 3GB Capacity)
```bash
#!/bin/bash
# Enhanced log analysis with current forensic capabilities

# Current log locations with enhanced retention
MAIN_LOG="/var/lib/vaultwarden/logs/caddy/access.log"
ADMIN_LOG="/var/lib/vaultwarden/logs/caddy/admin_access.log"
AUTH_LOG="/var/lib/vaultwarden/logs/caddy/auth_attempts.log"
SECURITY_LOG="/var/lib/vaultwarden/logs/caddy/security_blocks.log"

# Current enhanced analysis
analyze_current_logs() {
    # Top IPs from main log (current JSON format)
    jq -r '.request.remote_ip' "$MAIN_LOG" 2>/dev/null | sort | uniq -c | sort -nr | head -10

    # Failed admin attempts (current admin log)
    jq -r 'select(.admin_access and .status >= 400) | .request.remote_ip' "$ADMIN_LOG" 2>/dev/null | sort | uniq -c

    # Auth failures (current auth attempts log)
    jq -r 'select(.auth_attempt and .status == 401) | .request.remote_ip' "$AUTH_LOG" 2>/dev/null | sort | uniq -c

    # Security blocks (current security log with 180-day retention)
    jq -r 'select(.security_block) | .request.remote_ip' "$SECURITY_LOG" 2>/dev/null | sort | uniq -c
}
```

### Health Monitoring Integration (Current)
```bash
#!/bin/bash
# Custom health monitoring with current comprehensive checks

source "lib/common.sh"
source "lib/security.sh"

# Integrate with current health.sh
custom_health_check() {
    # Use current health check as base
    ./health.sh --comprehensive --json > /tmp/base_health.json

    # Add custom metrics
    local custom_metrics='{
        "custom_db_size": "'$(stat -c%s "$DB_PATH" 2>/dev/null | numfmt --to=iec)'",
        "custom_log_usage": "'$(du -sh /var/lib/vaultwarden/logs/ | cut -f1)'",
        "custom_fail2ban_bans": "'$(docker compose logs fail2ban | grep -c "Ban")'",
        "custom_template_valid": "'$(docker compose config >/dev/null 2>&1 && echo "true" || echo "false")'"
    }'

    # Merge with current health data
    jq ". + $custom_metrics" /tmp/base_health.json
}
```

## Current Network Customizations

### Advanced Firewall Rules (Current Implementation)
```bash
#!/bin/bash
# Custom firewall management with current safe ordering

source "lib/common.sh"
source "lib/security.sh"

# Integrate with current firewall update approach
custom_firewall_rules() {
    # Use current safe approach (add before remove)
    log_info "Adding custom firewall rules with current safe ordering"

    # Add custom rules before existing ones
    sudo ufw insert 1 allow from 192.168.1.0/24 to any port 443 comment "Local network access"
    sudo ufw insert 2 deny from 10.0.0.0/8 to any comment "Block private range"

    # Use current Cloudflare IP update (safe ordering)
    ./maintenance.sh --update-firewall

    log_info "Custom firewall rules applied with current safety measures"
}
```

## Backup and Recovery Customizations (Current)

### Enhanced Backup Integration (Current Atomic Operations)
```bash
#!/bin/bash
# Custom backup workflow with current atomic operations

source "lib/common.sh"
source "lib/crypto.sh"

# Integrate with current backup.sh atomic operations
custom_backup_workflow() {
    # Create custom data backup using current atomic approach
    log_info "Creating custom backup with current atomic operations"

    # Use current backup approach
    ./backup.sh --type full --rclone --email

    # Add custom data
    local custom_backup="custom-$(date +%Y%m%d-%H%M%S).tar.gz.age"
    tar czf - /custom/data | age -e -r "$(cat secrets/keys/age-key.txt)" > "backups/custom/$custom_backup"

    log_info "Custom backup completed: $custom_backup"
}
```

## Current Testing Framework

### Template Validation Testing (Current)
```bash
#!/bin/bash
# Enhanced testing with current template validation

source "lib/common.sh"
source "lib/security.sh"

test_current_customizations() {
    local tests_passed=0
    local tests_failed=0

    # Current template validation
    if docker compose -f docker-compose.yml.example config >/dev/null 2>&1; then
        log_success "✅ Template configuration valid"
        ((tests_passed++))
    else
        log_error "❌ Template configuration invalid"
        ((tests_failed++))
    fi

    # Current resource limits validation
    if docker compose config | grep -q "memory.*[0-9]"; then
        log_success "✅ Resource limits configured"
        ((tests_passed++))
    else
        log_error "❌ Resource limits missing"
        ((tests_failed++))
    fi

    # Current dual fail2ban action
    if docker compose logs fail2ban | grep -q "CF.*ok.*UFW.*ok"; then
        log_success "✅ Dual fail2ban action working"
        ((tests_passed++))
    else
        log_warn "⚠️  Dual fail2ban action not verified"
    fi

    # Current forensic logging
    if [[ $(du -sm /var/lib/vaultwarden/logs/ 2>/dev/null | cut -f1) -gt 10 ]]; then
        log_success "✅ Enhanced forensic logging active"
        ((tests_passed++))
    else
        log_warn "⚠️  Enhanced logging capacity not reached"
    fi

    log_info "Tests passed: $tests_passed, failed: $tests_failed"
}
```

## Current Customization Best Practices

### Template-Based Management (Current Approach)
1. **Always Edit Templates**: Modify `.example` files as source of truth
2. **Resource Awareness**: Respect 6GB system container limits
3. **Security Integration**: Use centralized `lib/security.sh` functions
4. **Atomic Operations**: Preserve current backup and database safety
5. **Forensic Compatibility**: Work with enhanced 3GB log retention

### Current Security Considerations
1. **Dual Action Compatibility**: Ensure customizations work with CF+UFW blocking
2. **Resource Limits**: Don't exceed current optimized container allocations
3. **Template Validation**: Always validate with `docker compose config`
4. **Centralized Security**: Use `lib/security.sh` for all security operations
5. **Emergency Access**: Maintain break-glass admin compatibility

### Current Operational Integration
1. **Health Check Integration**: Custom monitoring should use `./health.sh --json`
2. **Backup Compatibility**: Custom data should integrate with atomic operations
3. **Update Safety**: Use current `./startup.sh --force-restart` approach
4. **Log Analysis**: Work with current forensic JSON log format
5. **Template Regeneration**: Always use `sudo ./setup.sh --force` for changes

---

**Current Customization Status**: This guide reflects the current VaultWarden-OCI implementation with resource optimization for 6GB systems, dual CF+UFW security, enhanced forensic logging (3GB capacity), atomic backup operations, containerized email via msmtpd, and centralized security validation. All customizations should preserve these current architectural decisions while extending functionality.

Remember: Test all customizations thoroughly in a development environment before applying to production. The current template-based system provides a solid foundation for safe, reliable customizations.
