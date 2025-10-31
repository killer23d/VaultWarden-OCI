# Advanced Customization Guide - VaultWarden-OCI

This guide covers advanced customization options for power users who need to extend or modify VaultWarden-OCI beyond its default configuration while maintaining the template-based architecture and "set-and-forget" philosophy.

## Customization Philosophy

VaultWarden-OCI is designed for simplicity and reliability with template-based configuration management. Advanced customizations should:

- **Maintain Template-Based Architecture** - Work within the `.example` template system
- **Preserve System Stability** - Don't compromise the "set-and-forget" operation
- **Enhance Security** - Any changes must not weaken the security model
- **Stay Maintainable** - Customizations should be well-documented and sustainable
- **Support Automation** - Changes should work with existing automation

## Template-Based Customization Framework

### Understanding the Template System

The template-based architecture provides customization through:

```
📁 Template Structure
├── docker-compose.yml.example  # Docker services template
├── .env.example                # Environment variables template
├── Generated Files (DO NOT EDIT):
│   ├── docker-compose.yml      # Generated from template
│   └── .env                    # Generated from template
├── Static Configuration:
│   ├── caddy/Caddyfile         # Reverse proxy config
│   └── fail2ban/               # Security configurations
```

### Template Customization Workflow

```bash
# 1. Edit templates (source of truth)
nano docker-compose.yml.example
nano .env.example

# 2. Validate template changes
docker compose config  # Should show no errors

# 3. Apply template changes
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Restart services
./startup.sh --force-restart

# 5. Verify customizations
./health.sh --comprehensive
```

## Docker Compose Template Customizations

### Resource Optimization via Templates

Edit `docker-compose.yml.example` for resource adjustments:

```yaml
# docker-compose.yml.example - Resource adjustments for high-performance systems
version: '3.8'

services:
  vaultwarden:
    image: vaultwarden/server:${VAULTWARDEN_VERSION:-latest}
    container_name: vaultwarden_app
    restart: unless-stopped

    # Enhanced resource limits via template
    deploy:
      resources:
        limits:
          memory: ${VAULTWARDEN_MEMORY_LIMIT:-1g}    # Configurable via .env
          cpus: '${VAULTWARDEN_CPU_LIMIT:-2.0}'      # Configurable via .env
        reservations:
          memory: 256m
          cpus: '0.25'

    # Additional environment variables via template
    environment:
      # Core settings from .env template
      - DOMAIN=${DOMAIN}
      - ADMIN_TOKEN_FILE=/run/secrets/admin_token

      # Custom performance settings (add to .env.example)
      - DATABASE_MAX_CONNS=${DATABASE_MAX_CONNS:-20}
      - ROCKET_WORKERS=${ROCKET_WORKERS:-10}
      - ATTACHMENT_LIMIT=${ATTACHMENT_LIMIT:-104857600}

    # Additional volumes for customization
    volumes:
      - ${PROJECT_STATE_DIR}/data:/data
      - ${PROJECT_STATE_DIR}/custom-templates:/templates:ro  # Custom templates
      - ${PROJECT_STATE_DIR}/custom-icons:/web-vault/bwrs_static:ro  # Custom icons

  # Custom monitoring service via template
  monitoring:
    image: prom/prometheus:${PROMETHEUS_VERSION:-latest}
    container_name: vaultwarden_prometheus
    restart: unless-stopped
    profiles:
      - monitoring  # Enable with: docker compose --profile monitoring up
    ports:
      - "${PROMETHEUS_PORT:-9090}:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'

volumes:
  prometheus_data:
    name: vaultwarden_prometheus_data
```

### Environment Template Customizations

Edit `.env.example` for additional configuration options:

```bash
# .env.example - Extended configuration template

# Core settings (existing)
DOMAIN=vault.yourdomain.com
ADMIN_EMAIL=admin@yourdomain.com
PROJECT_STATE_DIR=/var/lib/vaultwarden

# Enhanced resource configuration
VAULTWARDEN_MEMORY_LIMIT=1g
VAULTWARDEN_CPU_LIMIT=2.0
DATABASE_MAX_CONNS=20
ROCKET_WORKERS=10

# Custom feature toggles
ATTACHMENT_LIMIT=104857600
CUSTOM_ICONS_ENABLED=true
MONITORING_ENABLED=false

# Monitoring configuration
PROMETHEUS_VERSION=latest
PROMETHEUS_PORT=9090
GRAFANA_VERSION=latest
GRAFANA_PORT=3000

# Development/testing options
USE_LATEST_IMAGES=false
DEBUG_LOGGING=false
CUSTOM_WEB_VAULT_PATH=
```

## Enhanced Security Customizations

### Advanced VaultWarden Security via Templates

Add to `docker-compose.yml.example`:

```yaml
services:
  vaultwarden:
    environment:
      # Enhanced security settings (add to .env.example)
      - SIGNUPS_ALLOWED=${SIGNUPS_ALLOWED:-false}
      - SIGNUPS_VERIFY=${SIGNUPS_VERIFY:-true}
      - INVITATIONS_ALLOWED=${INVITATIONS_ALLOWED:-true}

      # Advanced password policy
      - PASSWORD_COMPLEXITY_ENABLED=${PASSWORD_COMPLEXITY_ENABLED:-true}
      - PASSWORD_MIN_LENGTH=${PASSWORD_MIN_LENGTH:-14}
      - PASSWORD_REQUIRE_SYMBOLS=${PASSWORD_REQUIRE_SYMBOLS:-true}
      - PASSWORD_REQUIRE_NUMBERS=${PASSWORD_REQUIRE_NUMBERS:-true}

      # Enhanced session management
      - SESSION_TIMEOUT=${SESSION_TIMEOUT:-3600}
      - EXTENDED_LOGGING=${EXTENDED_LOGGING:-true}
      - REQUIRE_DEVICE_EMAIL=${REQUIRE_DEVICE_EMAIL:-true}
      - DISABLE_2FA_REMEMBER=${DISABLE_2FA_REMEMBER:-true}

      # Organization policies
      - ORG_GROUPS_ENABLED=${ORG_GROUPS_ENABLED:-true}
      - ORG_EVENTS_ENABLED=${ORG_EVENTS_ENABLED:-true}
      - ORG_CREATION_USERS=${ORG_CREATION_USERS:-}
```

### Enhanced Caddy Configuration

Create `caddy/Caddyfile.custom` for advanced security:

```caddyfile
# caddy/Caddyfile.custom - Enhanced security headers and customizations
{$DOMAIN} {
    # Import Cloudflare IP restrictions
    import cloudflare-ips.caddy

    # Enhanced security headers
    header {
        # Strict Content Security Policy
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'sha256-{HASH}'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"

        # Additional security headers
        X-Permitted-Cross-Domain-Policies "none"
        Cross-Origin-Embedder-Policy "require-corp"
        Cross-Origin-Opener-Policy "same-origin"
        Cross-Origin-Resource-Policy "same-origin"

        # Privacy headers
        Referrer-Policy "no-referrer"
        Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()"

        # Remove server identification
        -Server
        -X-Powered-By
        -X-Version
    }

    # Geographic restrictions (if needed)
    @blocked_countries {
        header_regexp CF-IPCountry "^(CN|RU|KP)$"
    }
    respond @blocked_countries 403 {
        body "Access from your location is not permitted."
    }

    # Enhanced rate limiting
    rate_limit {
        zone general {
            key {http.request.header.CF-Connecting-IP}
            events 100
            window 1m
        }
        zone admin {
            key {http.request.header.CF-Connecting-IP}
            events 10
            window 10m
        }
        response 429 {
            body "Rate limit exceeded. Please try again later."
        }
    }

    # Admin panel additional protection
    @admin {
        path /admin*
    }

    rate_limit @admin admin

    # Main proxy configuration
    reverse_proxy vaultwarden:80 {
        # Enhanced headers
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}

        # Connection optimization
        transport http {
            keepalive 60s
            keepalive_idle_conns 20
            max_conns_per_host 10
        }

        # Advanced health checking
        health_uri /alive
        health_port 80
        health_interval 15s
        health_timeout 5s
        health_status 200
    }
}

# Custom error pages
(error_pages) {
    handle_errors {
        @4xx expression `{http.error.status_code} >= 400 && {http.error.status_code} < 500`
        @5xx expression `{http.error.status_code} >= 500 && {http.error.status_code} < 600`

        rewrite @4xx /errors/4xx.html
        rewrite @5xx /errors/5xx.html
        file_server {
            root /etc/caddy/errors
        }
    }
}
```

## Enhanced fail2ban Customizations

### Advanced fail2ban Configuration

Create `fail2ban/jail.d/custom.conf`:

```ini
# fail2ban/jail.d/custom.conf - Advanced attack detection

[vaultwarden-adaptive]
enabled = true
filter = vaultwarden-adaptive
logpath = /var/log/caddy/access.log
maxretry = 5
findtime = 300
bantime = 3600

# Progressive ban time based on repeat offenses
bantime.increment = true
bantime.factor = 2
bantime.multipliers = 1 2 4 8 16 32 64
bantime.maxtime = 86400

# Enhanced action with rate limiting (uses existing cloudflare-optimized.conf)
action = cloudflare-optimized[name=%(name)s]

[vaultwarden-honeypot]
enabled = true
filter = vaultwarden-honeypot
logpath = /var/log/caddy/access.log
maxretry = 1
findtime = 86400
bantime = 604800  # 7 days for honeypot hits

# Honeypot for common attack paths
```

Create `fail2ban/filter.d/vaultwarden-adaptive.conf`:

```ini
# fail2ban/filter.d/vaultwarden-adaptive.conf - Sophisticated attack detection

[Definition]
# Advanced pattern matching for sophisticated attacks

# Brute force with varying user agents
failregex = ^.*"remote_ip":"<HOST>".*"uri":"/identity/connect/token".*"status":400.*"user_agent":"(?!Mozilla).*".*$

# API abuse patterns
            ^.*"remote_ip":"<HOST>".*"uri":"/api/.*".*"status":429.*$

# Suspicious enumeration attempts  
            ^.*"remote_ip":"<HOST>".*"uri":"/(admin|api|identity)/.*".*"status":404.*$

# Mass download attempts
            ^.*"remote_ip":"<HOST>".*"uri":"/api/ciphers".*"method":"GET".*"status":200.*$

# Ignore legitimate clients
ignoreregex = ^.*"user_agent":".*Bitwarden.*".*$
```

## Database and Performance Customizations

### Advanced SQLite Tuning via Templates

Add to `docker-compose.yml.example`:

```yaml
services:
  vaultwarden:
    environment:
      # SQLite performance settings via template
      - DATABASE_URL=sqlite:///data/bwdata/db.sqlite3?mode=rwc&cache=shared&_journal_mode=WAL&_synchronous=NORMAL&_cache_size=10000&_temp_store=MEMORY

    # Optimized storage configuration
    volumes:
      - type: bind
        source: ${PROJECT_STATE_DIR}/data
        target: /data
        bind:
          propagation: shared
        # Add mount options for SSD optimization if available
```

### Database Monitoring Integration

Create `scripts/db-monitor-custom.sh`:

```bash
#!/bin/bash
# Custom database monitoring with enhanced metrics

source "lib/common.sh"
init_common_lib "$0"

DB_PATH="${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3"
LOG_FILE="/var/log/vaultwarden-db-monitor.log"

# Enhanced database statistics
get_enhanced_db_stats() {
    sqlite3 "$DB_PATH" << SQL
.headers on
.mode column
SELECT 
  'Database Size (MB)' as Metric,
  ROUND(page_count * page_size / 1024.0 / 1024.0, 2) as Value
FROM pragma_page_count(), pragma_page_size()
UNION ALL
SELECT 
  'Free Pages',
  freelist_count
FROM pragma_freelist_count()
UNION ALL
SELECT
  'Fragmentation %',
  ROUND(freelist_count * 100.0 / page_count, 2)
FROM pragma_page_count(), pragma_freelist_count()
UNION ALL
SELECT
  'WAL Size (MB)',
  ROUND(COALESCE((SELECT size FROM pragma_wal_checkpoint('PASSIVE')), 0) / 1024.0 / 1024.0, 2)
UNION ALL
SELECT
  'User Count',
  COUNT(*)
FROM users
UNION ALL
SELECT
  'Cipher Count', 
  COUNT(*)
FROM ciphers
UNION ALL
SELECT
  'Organization Count',
  COUNT(*)
FROM organizations;
SQL
}

# Performance analysis with custom metrics
analyze_custom_performance() {
    # Custom performance metrics
    local db_size=$(stat -c%s "$DB_PATH" 2>/dev/null || echo "0")
    local wal_size=$(stat -c%s "${DB_PATH}-wal" 2>/dev/null || echo "0")

    if [[ $wal_size -gt 10485760 ]]; then  # 10MB
        log_warn "WAL file large: $(( wal_size / 1024 / 1024 ))MB - considering checkpoint"
        # Enhanced WAL checkpoint with verification
        sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" &&         log_info "WAL checkpoint completed successfully"
    fi

    # Check for slow queries (if enabled via custom logging)
    if [[ -f "/var/log/vaultwarden/slow-queries.log" ]]; then
        local slow_queries=$(grep "$(date +%Y-%m-%d)" /var/log/vaultwarden/slow-queries.log | wc -l)
        if [[ $slow_queries -gt 10 ]]; then
            log_warn "High number of slow queries today: $slow_queries"
        fi
    fi
}

# Main monitoring function
main() {
    echo "=== Enhanced Database Monitor $(date) ===" >> "$LOG_FILE"
    get_enhanced_db_stats >> "$LOG_FILE"
    analyze_custom_performance
    echo "" >> "$LOG_FILE"
}

main "$@"
```

## Monitoring and Observability Customizations

### Prometheus Integration via Templates

Add to `docker-compose.yml.example`:

```yaml
services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION:-latest}
    container_name: vaultwarden_prometheus
    restart: unless-stopped
    profiles:
      - monitoring
    ports:
      - "${PROMETHEUS_PORT:-9090}:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-30d}'
      - '--web.enable-lifecycle'

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION:-latest}
    container_name: vaultwarden_grafana
    restart: unless-stopped
    profiles:
      - monitoring
    ports:
      - "${GRAFANA_PORT:-3000}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_password
      - GF_INSTALL_PLUGINS=${GRAFANA_PLUGINS:-}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./monitoring/grafana/datasources:/etc/grafana/provisioning/datasources:ro
    secrets:
      - grafana_password

  node_exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION:-latest}
    container_name: vaultwarden_node_exporter
    restart: unless-stopped
    profiles:
      - monitoring
    ports:
      - "${NODE_EXPORTER_PORT:-9100}:9100"
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro

volumes:
  prometheus_data:
    name: vaultwarden_prometheus_data
  grafana_data:
    name: vaultwarden_grafana_data

secrets:
  grafana_password:
    file: ./secrets/.docker_secrets/grafana_password
```

### Custom Metrics Collection

Create `scripts/collect-metrics-custom.sh`:

```bash
#!/bin/bash
# Enhanced metrics collection for VaultWarden

METRICS_DIR="${PROJECT_STATE_DIR}/metrics"
mkdir -p "$METRICS_DIR"

# Enhanced system metrics
collect_enhanced_system_metrics() {
    cat > "$METRICS_DIR/system.prom" << PROM
# HELP vaultwarden_system_memory_usage_bytes Memory usage in bytes
# TYPE vaultwarden_system_memory_usage_bytes gauge
vaultwarden_system_memory_usage_bytes $(free -b | awk '/^Mem:/ {print $3}')

# HELP vaultwarden_system_disk_usage_bytes Disk usage in bytes  
# TYPE vaultwarden_system_disk_usage_bytes gauge
vaultwarden_system_disk_usage_bytes $(df -B1 ${PROJECT_STATE_DIR} | awk 'NR==2 {print $3}')

# HELP vaultwarden_system_load_average System load average
# TYPE vaultwarden_system_load_average gauge
vaultwarden_system_load_average $(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')

# HELP vaultwarden_template_config_valid Template configuration validity
# TYPE vaultwarden_template_config_valid gauge
vaultwarden_template_config_valid $(docker compose config >/dev/null 2>&1 && echo 1 || echo 0)
PROM
}

# Enhanced VaultWarden specific metrics
collect_enhanced_vaultwarden_metrics() {
    if [[ -f "${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3" ]]; then
        local user_count=$(sqlite3 ${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)
        local cipher_count=$(sqlite3 ${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM ciphers;" 2>/dev/null || echo 0)
        local org_count=$(sqlite3 ${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM organizations;" 2>/dev/null || echo 0)
        local active_sessions=$(sqlite3 ${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM devices WHERE updated_at > datetime('now', '-1 hour');" 2>/dev/null || echo 0)

        cat > "$METRICS_DIR/vaultwarden.prom" << PROM
# HELP vaultwarden_users_total Total number of users
# TYPE vaultwarden_users_total gauge
vaultwarden_users_total $user_count

# HELP vaultwarden_ciphers_total Total number of ciphers
# TYPE vaultwarden_ciphers_total gauge  
vaultwarden_ciphers_total $cipher_count

# HELP vaultwarden_organizations_total Total number of organizations
# TYPE vaultwarden_organizations_total gauge
vaultwarden_organizations_total $org_count

# HELP vaultwarden_active_sessions Active sessions in last hour
# TYPE vaultwarden_active_sessions gauge
vaultwarden_active_sessions $active_sessions
PROM
    fi
}

# Enhanced backup metrics
collect_enhanced_backup_metrics() {
    local recent_backups=$(find ${PROJECT_STATE_DIR}/backups -name "*.age" -mtime -1 2>/dev/null | wc -l)
    local backup_size=$(du -sb ${PROJECT_STATE_DIR}/backups 2>/dev/null | awk '{print $1}')
    local failed_backups=$(grep -c "FAILED" ${PROJECT_STATE_DIR}/logs/backup.log 2>/dev/null || echo 0)

    cat > "$METRICS_DIR/backups.prom" << PROM
# HELP vaultwarden_backups_recent_total Recent backups (24h)
# TYPE vaultwarden_backups_recent_total gauge
vaultwarden_backups_recent_total $recent_backups

# HELP vaultwarden_backup_storage_bytes Total backup storage usage
# TYPE vaultwarden_backup_storage_bytes gauge
vaultwarden_backup_storage_bytes ${backup_size:-0}

# HELP vaultwarden_backup_failures_total Failed backup attempts
# TYPE vaultwarden_backup_failures_total counter
vaultwarden_backup_failures_total $failed_backups
PROM
}

main() {
    collect_enhanced_system_metrics
    collect_enhanced_vaultwarden_metrics  
    collect_enhanced_backup_metrics
}

main "$@"
```

## Advanced Network Customizations

### VPN Integration via Templates

Add to `docker-compose.yml.example`:

```yaml
services:
  vpn:
    image: qmcgaw/gluetun:${GLUETUN_VERSION:-latest}
    container_name: vaultwarden_vpn
    restart: unless-stopped
    profiles:
      - vpn
    cap_add:
      - NET_ADMIN
    environment:
      - VPN_SERVICE_PROVIDER=${VPN_PROVIDER:-mullvad}
      - VPN_TYPE=${VPN_TYPE:-wireguard}
      - WIREGUARD_PRIVATE_KEY_FILE=/run/secrets/wg_private_key
      - WIREGUARD_ADDRESSES=${VPN_ADDRESSES:-10.64.0.1/32}
      - SERVER_CITIES=${VPN_CITIES:-Amsterdam}
    secrets:
      - wg_private_key
    volumes:
      - /dev/net/tun:/dev/net/tun

  # Route backup sync through VPN
  backup_sync:
    image: rclone/rclone:${RCLONE_VERSION:-latest}
    container_name: vaultwarden_backup_vpn
    restart: "no"
    profiles:
      - vpn
    network_mode: "service:vpn"
    volumes:
      - ${PROJECT_STATE_DIR}/backups:/backups:ro
      - ./rclone.conf:/config/rclone/rclone.conf:ro
    command: sync /backups remote:encrypted-backups --progress

secrets:
  wg_private_key:
    file: ./secrets/.docker_secrets/wireguard_key
```

## Template-Based Testing Framework

### Development Environment Template

Create `docker-compose.dev.yml.example`:

```yaml
# docker-compose.dev.yml.example - Development environment template
version: '3.8'

services:
  vaultwarden:
    build:
      context: ./custom-vaultwarden
      dockerfile: Dockerfile.dev
    environment:
      - ROCKET_ENV=development
      - LOG_LEVEL=debug
      - DISABLE_ADMIN_TOKEN=${DEV_DISABLE_ADMIN_TOKEN:-true}
    volumes:
      - ./dev-data:/data
      - ./custom-web-vault:/web-vault:ro

  # Development tools
  mailcatcher:
    image: schickling/mailcatcher:${MAILCATCHER_VERSION:-latest}
    container_name: vaultwarden_mailcatcher
    profiles:
      - development
    ports:
      - "${MAILCATCHER_WEB_PORT:-1080}:1080"
      - "${MAILCATCHER_SMTP_PORT:-1025}:1025"

  # Testing framework
  test_runner:
    image: node:${NODE_VERSION:-18-alpine}
    container_name: vaultwarden_tests
    profiles:
      - testing
    volumes:
      - ./tests:/tests
      - ./scripts:/scripts:ro
    working_dir: /tests
    command: npm test
```

### Comprehensive Testing Script

Create `scripts/test-suite-custom.sh`:

```bash
#!/bin/bash
# Enhanced testing framework for VaultWarden

source "lib/common.sh"
init_common_lib "$0"

TESTS_PASSED=0
TESTS_FAILED=0

test_function() {
    local test_name="$1"
    local test_command="$2"

    log_info "Running test: $test_name"

    if eval "$test_command" >/dev/null 2>&1; then
        log_success "✅ $test_name"
        ((TESTS_PASSED++))
    else
        log_error "❌ $test_name"
        ((TESTS_FAILED++))
    fi
}

run_enhanced_test_suite() {
    log_header "VaultWarden Enhanced Test Suite"

    # Template validation tests
    test_function "Template configuration valid" "docker compose config"
    test_function "Environment template exists" "test -f .env.example"
    test_function "Docker template exists" "test -f docker-compose.yml.example"

    # System tests
    test_function "Docker availability" "docker --version"
    test_function "Docker Compose availability" "docker compose version"
    test_function "Age encryption available" "age --version"
    test_function "SOPS available" "sops --version"

    # Service tests
    test_function "VaultWarden responding" "curl -f http://localhost:80/alive"
    test_function "Caddy configuration valid" "docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile"
    test_function "Database integrity" "sqlite3 ${PROJECT_STATE_DIR}/data/bwdata/db.sqlite3 'PRAGMA integrity_check;' | grep -q 'ok'"

    # Enhanced security tests
    test_function "Firewall active" "ufw status | grep -q 'Status: active'"
    test_function "Age key accessible" "./edit-secrets.sh --test"
    test_function "Enhanced fail2ban rate limiting active" "docker compose logs fail2ban | grep -q 'rate'"
    test_function "Break-glass admin configured" "./create-breakglass-admin.sh status"

    # Backup tests with atomic operations
    test_function "Backup directory writable" "touch ${PROJECT_STATE_DIR}/backups/test && rm ${PROJECT_STATE_DIR}/backups/test"
    test_function "Recent backup exists" "find ${PROJECT_STATE_DIR}/backups/ -name '*.age' -mtime -7 | grep -q ."
    test_function "Backup listing functional" "./backup.sh --list | grep -q 'ID.*Type.*Date'"

    # Template-specific tests
    test_function "Template differences acceptable" "diff -q docker-compose.yml.example docker-compose.yml >/dev/null || true"
    test_function "Environment variables loaded" "source .env && test -n \"\$DOMAIN\""

    # Performance tests
    local response_time=$(curl -w "%{time_total}" -o /dev/null -s http://localhost:80/alive 2>/dev/null || echo "999")
    test_function "Response time acceptable" "[[ $(echo "$response_time < 2.0" | bc -l 2>/dev/null || echo 0) -eq 1 ]]"

    # Report results
    log_header "Enhanced Test Results"
    log_info "Passed: $TESTS_PASSED"
    log_info "Failed: $TESTS_FAILED"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

run_enhanced_test_suite "$@"
```

## Customization Best Practices

### Template-Based Configuration Management

1. **Edit Templates First**: Always modify `.example` files as the source of truth
2. **Validate Before Apply**: Run `docker compose config` to validate template changes
3. **Use Setup Script**: Apply changes via `sudo ./setup.sh --force`
4. **Document Customizations**: Add comments to template files explaining customizations
5. **Version Control Templates**: Keep template files in version control

### Security Considerations

1. **Review Security Implications**: Analyze security impact of all customizations
2. **Maintain Template Security**: Ensure customizations don't weaken security model
3. **Test Security Controls**: Verify enhanced fail2ban and other security features work
4. **Regular Security Audits**: Include customizations in security review process
5. **Document Security Assumptions**: Clearly document security-related customizations

### Maintenance Strategy

1. **Template-Based Updates**: Maintain customizations through template system
2. **Automated Testing**: Include customizations in test suite
3. **Monitor Performance Impact**: Track performance impact of customizations
4. **Plan Rollback Procedures**: Maintain ability to revert customizations
5. **Keep Customizations Modular**: Design customizations for easy enable/disable
6. **Regular Review**: Periodically review and cleanup unused customizations

---

**Warning**: Advanced customizations should be thoroughly tested in a non-production environment. Always maintain comprehensive backups before implementing changes. The template-based architecture provides a solid foundation for customizations while maintaining the "set-and-forget" operational philosophy.

Remember: The goal is to enhance functionality while preserving the reliability, security, and maintainability that makes VaultWarden-OCI suitable for small team deployments.
