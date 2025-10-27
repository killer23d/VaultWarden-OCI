# Advanced Customization Guide - VaultWarden-OCI-Simplified

This guide covers advanced customization options for power users who need to extend or modify VaultWarden-OCI-Simplified beyond its default configuration while maintaining the "set-and-forget" philosophy.

## Customization Philosophy

VaultWarden-OCI-Simplified is designed for simplicity and reliability. Advanced customizations should:

- **Maintain system stability** - Don't compromise the core "set-and-forget" operation
- **Preserve security** - Any changes must not weaken the security model  
- **Stay maintainable** - Customizations should be well-documented and sustainable
- **Support automation** - Changes should work with existing automation

## Docker Compose Overrides

### Using docker-compose.override.yml

The recommended way to customize container configuration without modifying core files:

```yaml
# docker-compose.override.yml
version: '3.8'

services:
  vaultwarden:
    # Resource adjustments for high-performance systems
    deploy:
      resources:
        limits:
          memory: 4g
          cpus: '2.0'
        reservations:
          memory: 1g
          cpus: '0.5'

    # Additional environment variables
    environment:
      # Enable admin token rotation
      - ADMIN_TOKEN_ROTATION_ENABLED=true
      # Custom attachment size limit (100MB)
      - ATTACHMENT_LIMIT=104857600
      # Enable organization creation by users
      - ORG_CREATION_USERS=admin@yourdomain.com

    # Additional volumes for custom data
    volumes:
      - ./custom-templates:/web-vault/templates:ro
      - ./custom-icons:/web-vault/bwrs_static:ro

  caddy:
    # Additional ports for development
    ports:
      - "8080:8080"  # Development proxy
      - "2019:2019"  # Admin API

    # Override Caddyfile for custom configuration
    volumes:
      - ./caddy/Caddyfile.custom:/etc/caddy/Caddyfile:ro

  # Add additional services
  monitoring:
    image: prom/prometheus:latest
    container_name: vaultwarden_prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'

volumes:
  prometheus_data:
```

### Advanced VaultWarden Configuration

#### Extended Security Settings
```yaml
# docker-compose.override.yml - VaultWarden security hardening
services:
  vaultwarden:
    environment:
      # Disable user registration completely
      - SIGNUPS_ALLOWED=false
      - SIGNUPS_VERIFY=true

      # Enhanced password policy
      - PASSWORD_COMPLEXITY_ENABLED=true
      - PASSWORD_MIN_LENGTH=14
      - PASSWORD_REQUIRE_SYMBOLS=true
      - PASSWORD_REQUIRE_NUMBERS=true

      # Session management
      - SESSION_TIMEOUT=3600          # 1 hour session timeout
      - EXTENDED_LOGGING=true         # Detailed audit logs

      # Two-factor authentication requirements
      - REQUIRE_DEVICE_EMAIL=true     # Email verification for new devices
      - DISABLE_2FA_REMEMBER=true     # Always require 2FA

      # Organization policies
      - ORG_GROUPS_ENABLED=true       # Enable group management
      - ORG_EVENTS_ENABLED=true       # Enable event logging
```

#### Performance Optimization
```yaml
# docker-compose.override.yml - Performance tuning
services:
  vaultwarden:
    environment:
      # Database optimization
      - DATABASE_MAX_CONNS=10         # Connection pooling
      - DATABASE_TIMEOUT=30           # Query timeout

      # Caching settings
      - ICON_CACHE_TTL=2592000       # 30 days icon cache
      - ICON_CACHE_NEGTTL=259200     # 3 days negative cache

      # Attachment settings for high-usage
      - ATTACHMENT_LIMIT=104857600    # 100MB attachment limit
      - FILE_SIZE_LIMIT=52428800      # 50MB file size limit

    # SSD-optimized storage
    volumes:
      - type: bind
        source: /mnt/ssd/vaultwarden
        target: /data
        bind:
          propagation: shared
```

## Advanced Caddy Configurations

### Custom Security Headers
```caddyfile
# caddy/Caddyfile.custom - Enhanced security headers
{$DOMAIN} {
    # Import base configuration
    import cloudflare-ips.caddy

    # Enhanced security headers
    header {
        # Strict Content Security Policy
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'sha256-allowed-hash'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: https:; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"

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

    # Custom error pages
    handle_errors {
        @4xx expression `{http.error.status_code} >= 400 && {http.error.status_code} < 500`
        @5xx expression `{http.error.status_code} >= 500 && {http.error.status_code} < 600`

        rewrite @4xx /errors/4xx.html
        rewrite @5xx /errors/5xx.html
        file_server {
            root /etc/caddy/errors
        }
    }

    # Enhanced rate limiting
    rate_limit {
        zone general {
            key {http.request.header.CF-Connecting-IP}
            events 100
            window 1m
        }
        response 429 {
            body "Rate limit exceeded. Please try again later."
        }
    }

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
        health_body "OK"
    }
}
```

### Geographic Restrictions
```caddyfile
# caddy/Caddyfile.geo - Geographic access control
{$DOMAIN} {
    # Block requests from specific countries (example)
    @blocked_countries {
        header_regexp CF-IPCountry "^(CN|RU|KP)$"
    }

    respond @blocked_countries 403 {
        body "Access from your location is not permitted."
    }

    # Allow only specific countries for admin panel
    @admin_geo {
        path /admin*
        not header_regexp CF-IPCountry "^(US|CA|GB|DE|FR|AU)$"
    }

    respond @admin_geo 403 {
        body "Administrative access not available from your location."
    }

    # Continue with main configuration
    import /etc/caddy/Caddyfile.main
}
```

## Advanced fail2ban Configuration

### Custom Filters and Jails

#### Sophisticated Attack Detection
```ini
# fail2ban/filter.d/vaultwarden-advanced.conf
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

ignoreregex = ^.*"user_agent":".*Bitwarden.*".*$
```

#### Adaptive Ban Policies
```ini
# fail2ban/jail.d/vaultwarden-advanced.conf
[vaultwarden-adaptive]
enabled = true
filter = vaultwarden-advanced
logpath = /var/log/caddy/access.log
maxretry = 5
findtime = 300
bantime = 3600

# Progressive ban time based on repeat offenses
bantime.increment = true
bantime.factor = 2
bantime.multipliers = 1 2 4 8 16 32 64
bantime.maxtime = 86400

# Custom action with Cloudflare and email notification  
action = %(banaction)s[name=%(name)s, cfzone="%(env_CLOUDFLARE_ZONE_ID)s", cftoken="%(env_FAIL2BAN_API_TOKEN)s"]
         sendmail-whois-lines[name=%(name)s, sender="%(sender)s", dest="%(destemail)s", logpath=%(logpath)s]

[vaultwarden-honeypot]
enabled = true
filter = vaultwarden-honeypot
logpath = /var/log/caddy/access.log
maxretry = 1
findtime = 86400
bantime = 604800  # 7 days for honeypot hits

# Honeypot filter for common attack paths
```

### Intelligent IP Whitelisting
```bash
# Create dynamic whitelist based on successful authentications
cat > /opt/vaultwarden/scripts/update-whitelist.sh << 'EOF'
#!/bin/bash
# Extract IPs that have successfully authenticated in last 24 hours
successful_ips=$(grep -E '"status":(200|302)' /var/log/caddy/access.log |                  grep -E '(identity|api)' |                  jq -r '.remote_ip' |                  sort | uniq)

# Add to fail2ban whitelist
for ip in $successful_ips; do
    fail2ban-client set vaultwarden-adaptive addignoreip $ip
done
EOF

chmod +x /opt/vaultwarden/scripts/update-whitelist.sh

# Add to cron for hourly execution
echo "0 * * * * /opt/vaultwarden/scripts/update-whitelist.sh" >> /etc/cron.d/vaultwarden-whitelist
```

## Database Optimizations

### Advanced SQLite Tuning
```yaml
# docker-compose.override.yml - Database optimization
services:
  vaultwarden:
    environment:
      # SQLite performance settings
      - DATABASE_URL=sqlite:///data/bwdata/db.sqlite3?mode=rwc&cache=shared&_journal_mode=WAL&_synchronous=NORMAL&_cache_size=10000&_temp_store=MEMORY

    # Optimized storage for database
    volumes:
      - type: bind
        source: /mnt/ssd/vaultwarden/data
        target: /data
        bind:
          propagation: shared

    # Database maintenance automation
    command: >
      sh -c "
        # Pre-flight database optimization
        sqlite3 /data/bwdata/db.sqlite3 'PRAGMA optimize;' 2>/dev/null || true
        # Start VaultWarden
        exec /start.sh
      "
```

### Database Monitoring and Maintenance
```bash
# Create advanced database monitoring script
cat > /opt/vaultwarden/scripts/db-monitor.sh << 'EOF'
#!/bin/bash
source "lib/common.sh"
init_common_lib "$0"

DB_PATH="/var/lib/vaultwarden/data/bwdata/db.sqlite3"
LOG_FILE="/var/log/vaultwarden-db-monitor.log"

# Database statistics
get_db_stats() {
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
  'User Count',
  COUNT(*)
FROM users
UNION ALL
SELECT
  'Cipher Count', 
  COUNT(*)
FROM ciphers;
SQL
}

# Performance analysis
analyze_performance() {
    # Check for slow queries (if query log enabled)
    if [[ -f "/var/log/vaultwarden/slow-queries.log" ]]; then
        slow_queries=$(grep "$(date +%Y-%m-%d)" /var/log/vaultwarden/slow-queries.log | wc -l)
        echo "Slow queries today: $slow_queries" >> "$LOG_FILE"
    fi

    # Check WAL file size
    wal_size=$(stat -c%s "${DB_PATH}-wal" 2>/dev/null || echo "0")
    if [[ $wal_size -gt 10485760 ]]; then  # 10MB
        log_warn "WAL file large: $(( wal_size / 1024 / 1024 ))MB"
        # Trigger checkpoint
        sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);"
    fi
}

# Main monitoring function
main() {
    echo "=== Database Monitor $(date) ===" >> "$LOG_FILE"
    get_db_stats >> "$LOG_FILE"
    analyze_performance
    echo "" >> "$LOG_FILE"
}

main "$@"
EOF

chmod +x /opt/vaultwarden/scripts/db-monitor.sh

# Add to cron for daily execution
echo "0 6 * * * /opt/vaultwarden/scripts/db-monitor.sh" >> /etc/cron.d/vaultwarden-db-monitor
```

## Monitoring and Observability

### Prometheus Integration
```yaml
# monitoring/docker-compose.monitoring.yml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: vaultwarden_prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'
    networks:
      - vaultwarden_network

  grafana:
    image: grafana/grafana:latest
    container_name: vaultwarden_grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_password
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./monitoring/grafana/datasources:/etc/grafana/provisioning/datasources:ro
    secrets:
      - grafana_password
    networks:
      - vaultwarden_network

  node_exporter:
    image: prom/node-exporter:latest
    container_name: vaultwarden_node_exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - vaultwarden_network

volumes:
  prometheus_data:
  grafana_data:

secrets:
  grafana_password:
    file: ./secrets/.docker_secrets/grafana_password

networks:
  vaultwarden_network:
    external: true
```

### Custom Metrics Collection
```bash
# Create metrics collection script
cat > /opt/vaultwarden/scripts/collect-metrics.sh << 'EOF'
#!/bin/bash
# Custom metrics collector for VaultWarden

METRICS_DIR="/var/lib/vaultwarden/metrics"
mkdir -p "$METRICS_DIR"

# System metrics
collect_system_metrics() {
    cat > "$METRICS_DIR/system.prom" << PROM
# HELP vaultwarden_system_memory_usage_bytes Memory usage in bytes
# TYPE vaultwarden_system_memory_usage_bytes gauge
vaultwarden_system_memory_usage_bytes $(free -b | awk '/^Mem:/ {print $3}')

# HELP vaultwarden_system_disk_usage_bytes Disk usage in bytes  
# TYPE vaultwarden_system_disk_usage_bytes gauge
vaultwarden_system_disk_usage_bytes $(df -B1 /var/lib/vaultwarden | awk 'NR==2 {print $3}')

# HELP vaultwarden_system_load_average System load average
# TYPE vaultwarden_system_load_average gauge
vaultwarden_system_load_average $(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
PROM
}

# VaultWarden specific metrics
collect_vaultwarden_metrics() {
    if [[ -f "/var/lib/vaultwarden/data/bwdata/db.sqlite3" ]]; then
        user_count=$(sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM users;")
        cipher_count=$(sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM ciphers;")
        org_count=$(sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 "SELECT COUNT(*) FROM organizations;")

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
PROM
    fi
}

# Backup metrics
collect_backup_metrics() {
    recent_backups=$(find /opt/vaultwarden/backups -name "*.age" -mtime -1 | wc -l)
    backup_size=$(du -sb /opt/vaultwarden/backups 2>/dev/null | awk '{print $1}')

    cat > "$METRICS_DIR/backups.prom" << PROM
# HELP vaultwarden_backups_recent_total Recent backups (24h)
# TYPE vaultwarden_backups_recent_total gauge
vaultwarden_backups_recent_total $recent_backups

# HELP vaultwarden_backup_storage_bytes Total backup storage usage
# TYPE vaultwarden_backup_storage_bytes gauge
vaultwarden_backup_storage_bytes ${backup_size:-0}
PROM
}

main() {
    collect_system_metrics
    collect_vaultwarden_metrics  
    collect_backup_metrics
}

main "$@"
EOF

chmod +x /opt/vaultwarden/scripts/collect-metrics.sh

# Add to cron for frequent collection
echo "*/5 * * * * /opt/vaultwarden/scripts/collect-metrics.sh" >> /etc/cron.d/vaultwarden-metrics
```

## Advanced Security Customizations

### Multi-Factor Authentication Enforcement
```yaml
# docker-compose.override.yml - Enhanced MFA
services:
  vaultwarden:
    environment:
      # Require MFA for all users
      - REQUIRE_DEVICE_EMAIL=true
      - DISABLE_2FA_REMEMBER=true

      # Enhanced session security
      - SESSION_TIMEOUT=1800          # 30 minute timeout
      - REFRESH_TOKEN_ROTATION=true   # Rotate refresh tokens

      # IP-based restrictions
      - IP_HEADER=CF-Connecting-IP    # Trust Cloudflare IP header
      - ICON_BLACKLIST_REGEX="^https?://(?:localhost|127\.0\.0\.1|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.).*"
```

### Advanced Access Controls
```caddyfile
# caddy/snippets/advanced-access.caddy
# Time-based access restrictions
@business_hours {
    expression `{time.hour} >= 8 && {time.hour} <= 18`
}

@after_hours {
    not expression `{time.hour} >= 8 && {time.hour} <= 18`
}

# Restrict admin access to business hours
handle @after_hours {
    @admin_after_hours path /admin*
    respond @admin_after_hours 403 {
        body "Administrative access is only available during business hours (8 AM - 6 PM)."
    }
}

# Enhanced IP reputation checking
@suspicious_ip {
    header_regexp CF-Threat-Score "([5-9][0-9]|100)"
}

respond @suspicious_ip 403 {
    body "Access denied due to suspicious activity."
}
```

## Performance Customizations

### High-Availability Configuration
```yaml
# docker-compose.ha.yml - High availability setup
version: '3.8'

services:
  vaultwarden:
    # Enable multiple replicas (requires external database)
    deploy:
      replicas: 2
      update_config:
        parallelism: 1
        delay: 30s
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3

  # Load balancer for multiple instances
  haproxy:
    image: haproxy:2.8
    container_name: vaultwarden_lb
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    depends_on:
      - vaultwarden
```

### Caching Layer
```yaml
# docker-compose.cache.yml - Redis caching
services:
  redis:
    image: redis:7-alpine
    container_name: vaultwarden_redis
    restart: unless-stopped
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    networks:
      - vaultwarden_network

volumes:
  redis_data:
```

## Backup Customizations

### Advanced Backup Strategies
```bash
# Create custom backup script with multiple destinations
cat > /opt/vaultwarden/scripts/advanced-backup.sh << 'EOF'
#!/bin/bash
source "lib/common.sh"
init_common_lib "$0"

BACKUP_DESTINATIONS=(
    "local:/opt/vaultwarden/backups"
    "s3:vaultwarden-backups-primary"
    "gdrive:VaultWarden/Backups"
    "b2:vaultwarden-backup-bucket"
)

create_and_distribute_backup() {
    local backup_type="$1"

    # Create backup
    local backup_file
    backup_file=$(./backup.sh --type "$backup_type" 2>/dev/null | tail -1)

    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        log_error "Backup creation failed"
        return 1
    fi

    # Distribute to all destinations
    for dest in "${BACKUP_DESTINATIONS[@]}"; do
        local dest_type="${dest%%:*}"
        local dest_path="${dest#*:}"

        case "$dest_type" in
            "local")
                # Already stored locally
                log_success "Local backup: $backup_file"
                ;;
            "s3"|"gdrive"|"b2")
                if rclone copy "$backup_file" "$dest/$(basename "$(dirname "$backup_file")")/" --progress; then
                    log_success "Synced to $dest_type: $(basename "$backup_file")"
                else
                    log_error "Failed to sync to $dest_type"
                fi
                ;;
        esac
    done

    # Verify at least one remote backup succeeded
    local success_count=0
    for dest in "${BACKUP_DESTINATIONS[@]}"; do
        if [[ "$dest" != "local:"* ]]; then
            if rclone lsf "$dest/" | grep -q "$(basename "$backup_file")"; then
                ((success_count++))
            fi
        fi
    done

    if [[ $success_count -gt 0 ]]; then
        log_success "Backup distributed to $success_count remote locations"
        return 0
    else
        log_error "Failed to distribute backup to any remote location"
        return 1
    fi
}

main() {
    log_info "Advanced backup distribution starting"

    case "${1:-db}" in
        "db"|"full"|"emergency")
            create_and_distribute_backup "$1"
            ;;
        *)
            log_error "Invalid backup type: $1"
            log_info "Usage: $0 [db|full|emergency]"
            exit 1
            ;;
    esac
}

main "$@"
EOF

chmod +x /opt/vaultwarden/scripts/advanced-backup.sh
```

## Network Customizations

### VPN Integration
```yaml
# docker-compose.vpn.yml - VPN routing for enhanced security
services:
  vpn:
    image: qmcgaw/gluetun:latest
    container_name: vaultwarden_vpn
    cap_add:
      - NET_ADMIN
    environment:
      - VPN_SERVICE_PROVIDER=mullvad
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY_FILE=/run/secrets/wg_private_key
      - WIREGUARD_ADDRESSES=10.64.0.1/32
      - SERVER_CITIES=Amsterdam
    secrets:
      - wg_private_key
    volumes:
      - /dev/net/tun:/dev/net/tun
    networks:
      - vpn_network

  # Route specific services through VPN
  backup_sync:
    image: rclone/rclone:latest
    container_name: vaultwarden_backup_vpn
    restart: "no"
    network_mode: "service:vpn"
    volumes:
      - ./backups:/backups:ro
      - ./rclone.conf:/config/rclone/rclone.conf:ro
    command: sync /backups remote:encrypted-backups --progress

networks:
  vpn_network:

secrets:
  wg_private_key:
    file: ./secrets/.docker_secrets/wireguard_key
```

### Custom Networking
```yaml
# docker-compose.network.yml - Advanced networking
services:
  vaultwarden:
    networks:
      - frontend
      - backend

  caddy:
    networks:
      - frontend
      - public

  database:
    # If using external database
    networks:
      - backend

networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1

  backend:
    driver: bridge
    internal: true  # No external access
    ipam:
      config:
        - subnet: 172.21.0.0/16

  public:
    external: true
```

## Development and Testing Extensions

### Development Environment
```yaml
# docker-compose.dev.yml - Development overrides
services:
  vaultwarden:
    build:
      context: ./custom-vaultwarden
      dockerfile: Dockerfile.dev
    environment:
      - ROCKET_ENV=development
      - LOG_LEVEL=debug
      - DISABLE_ADMIN_TOKEN=true  # Only for development!
    volumes:
      - ./dev-data:/data
      - ./custom-web-vault:/web-vault:ro

  # Development tools
  mailcatcher:
    image: schickling/mailcatcher
    container_name: vaultwarden_mailcatcher
    ports:
      - "1080:1080"
      - "1025:1025"
    networks:
      - vaultwarden_network
```

### Testing Framework
```bash
# Create comprehensive testing framework
cat > /opt/vaultwarden/scripts/test-suite.sh << 'EOF'
#!/bin/bash
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

run_test_suite() {
    log_header "VaultWarden Test Suite"

    # System tests
    test_function "Docker availability" "docker --version"
    test_function "Docker Compose availability" "docker compose version"
    test_function "Age encryption available" "age --version"
    test_function "SOPS available" "sops --version"

    # Service tests
    test_function "VaultWarden responding" "curl -f http://localhost:80/alive"
    test_function "Caddy configuration valid" "docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile"
    test_function "Database integrity" "sqlite3 /var/lib/vaultwarden/data/bwdata/db.sqlite3 'PRAGMA integrity_check;' | grep -q 'ok'"

    # Security tests
    test_function "Firewall active" "ufw status | grep -q 'Status: active'"
    test_function "Age key accessible" "./edit-secrets.sh --show >/dev/null"
    test_function "SSL certificate valid" "echo | openssl s_client -connect vault.yourdomain.com:443 2>/dev/null | openssl x509 -noout -dates"

    # Backup tests
    test_function "Backup directory writable" "touch backups/test && rm backups/test"
    test_function "Recent backup exists" "find backups/ -name '*.age' -mtime -7 | grep -q ."

    # Performance tests
    local response_time=$(curl -w "%{time_total}" -o /dev/null -s http://localhost:80/alive)
    test_function "Response time acceptable" "[[ $(echo "$response_time < 2.0" | bc) -eq 1 ]]"

    # Report results
    log_header "Test Results"
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

run_test_suite "$@"
EOF

chmod +x /opt/vaultwarden/scripts/test-suite.sh
```

## Integration Extensions

### Webhook Integration
```bash
# Create webhook notification system
cat > /opt/vaultwarden/scripts/webhook-manager.sh << 'EOF'
#!/bin/bash
source "lib/common.sh"
init_common_lib "$0"

WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"

send_webhook() {
    local event="$1"
    local data="$2"

    if [[ -z "$WEBHOOK_URL" ]]; then
        log_debug "No webhook URL configured"
        return 0
    fi

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local hostname=$(hostname -f)

    local payload=$(jq -n         --arg event "$event"         --arg timestamp "$timestamp"         --arg hostname "$hostname"         --argjson data "$data"         '{
            event: $event,
            timestamp: $timestamp,
            hostname: $hostname,
            data: $data
        }')

    # Create signature if secret provided
    local signature=""
    if [[ -n "$WEBHOOK_SECRET" ]]; then
        signature=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -binary | base64)
    fi

    # Send webhook
    local curl_opts=(
        -X POST
        -H "Content-Type: application/json"
        -H "User-Agent: VaultWarden-OCI-Simplified/1.0"
        --max-time 10
        --retry 3
        --retry-delay 2
    )

    if [[ -n "$signature" ]]; then
        curl_opts+=(-H "X-Signature-SHA256: $signature")
    fi

    if curl "${curl_opts[@]}" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1; then
        log_debug "Webhook sent successfully for event: $event"
    else
        log_warn "Failed to send webhook for event: $event"
    fi
}

# Usage examples:
# send_webhook "backup_completed" '{"type": "db", "size": "50MB", "duration": "30s"}'
# send_webhook "health_check_failed" '{"errors": 2, "warnings": 1}'
# send_webhook "user_login" '{"user": "user@example.com", "ip": "1.2.3.4"}'

# Export for use by other scripts
export -f send_webhook
EOF

# Source in other scripts to enable webhook notifications
```

## Customization Best Practices

### Configuration Management
- **Use override files** instead of modifying core files
- **Document all customizations** in a `CUSTOMIZATIONS.md` file
- **Version control** your override files and custom scripts
- **Test thoroughly** in development before applying to production
- **Maintain upgrade compatibility** by avoiding deep modifications

### Security Considerations
- **Review security implications** of all customizations
- **Maintain the principle of least privilege** in custom configurations
- **Regularly audit** custom configurations for vulnerabilities
- **Keep customizations simple** to reduce attack surface
- **Document security assumptions** in custom code

### Maintenance Strategy
- **Automate testing** of customizations
- **Monitor performance impact** of custom features
- **Plan rollback procedures** for all customizations
- **Keep customizations modular** for easier maintenance
- **Regular review and cleanup** of unused customizations

---

**Warning**: Advanced customizations can impact system stability and security. Always test thoroughly in a non-production environment and maintain comprehensive backups before implementing changes.
