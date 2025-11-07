# Advanced Customization Guide - VaultWarden-OCI

Advanced configuration options, customization strategies, and optimization techniques for VaultWarden-OCI.

## Template Customization Strategy

### Understanding the Template System

VaultWarden-OCI uses a template-first approach:

```
Source Templates (.example files)
         ↓
    setup.sh applies
         ↓
Generated Configuration
         ↓
    Docker Compose validates
         ↓
     Services start
```

**Key Principle**: Always edit `.example` files, never generated files directly.

### Custom Template Workflow

```bash
# 1. Edit template
nano docker-compose.yml.example

# 2. Validate template syntax
docker compose -f docker-compose.yml.example config

# 3. Test in development
cp docker-compose.yml.example docker-compose.override.yml
docker compose config

# 4. Apply to production
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 5. Restart services
./startup.sh --force-restart
```

## Resource Customization

### Adjusting Container Limits

**For Larger Systems** (12GB+ RAM):
```yaml
# Edit docker-compose.yml.example
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          memory: 4G        # Increased from 2G
          cpus: '1.0'       # Increased from 0.6
        reservations:
          memory: 1G        # Increased from 512M
          cpus: '0.4'       # Increased from 0.2
  
  caddy:
    deploy:
      resources:
        limits:
          memory: 2G        # Increased from 1G
          cpus: '0.5'       # Increased from 0.3
```

**For Smaller Systems** (4GB RAM):
```yaml
# Edit docker-compose.yml.example
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          memory: 1536M     # Decreased from 2G
          cpus: '0.5'       # Decreased from 0.6
        reservations:
          memory: 384M      # Decreased from 512M
```

### CPU Pinning for Performance

```yaml
# Edit docker-compose.yml.example
services:
  vaultwarden:
    deploy:
      resources:
        limits:
          cpus: '2.0'
        reservations:
          cpus: '0.5'
      placement:
        constraints:
          - node.role == manager
    cpuset: "0,1"  # Pin to specific CPU cores
```

## Network Customization

### Custom Docker Network

```yaml
# Add to docker-compose.yml.example
networks:
  vaultwarden_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/16
          gateway: 172.30.0.1

services:
  vaultwarden:
    networks:
      vaultwarden_net:
        ipv4_address: 172.30.0.10
```

### Multiple Domain Support

```yaml
# Edit caddy/Caddyfile
vault1.example.com, vault2.example.com {
    reverse_proxy vaultwarden:80
    
    # Domain-specific logging
    log {
        output file /logs/vault1.log
    }
}
```

### IPv6 Configuration

```yaml
# Enable IPv6 in docker-compose.yml.example
services:
  vaultwarden:
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
    
networks:
  default:
    enable_ipv6: true
    ipam:
      config:
        - subnet: "fd00::/64"
```

## Storage Customization

### External Database

```yaml
# Use external MySQL/PostgreSQL
# Edit docker-compose.yml.example
services:
  vaultwarden:
    environment:
      - DATABASE_URL=mysql://user:pass@mysql-host:3306/vaultwarden
      # Or PostgreSQL:
      # - DATABASE_URL=postgresql://user:pass@pg-host:5432/vaultwarden
```

### Separate Volume Mounts

```yaml
# Edit docker-compose.yml.example
services:
  vaultwarden:
    volumes:
      - ${PROJECT_STATE_DIR}/data/attachments:/data/attachments
      - ${PROJECT_STATE_DIR}/data/sends:/data/sends
      - ${PROJECT_STATE_DIR}/data/icon_cache:/data/icon_cache
      - /mnt/nfs/vaultwarden/attachments:/data/attachments  # NFS mount
```

### Backup to Multiple Destinations

```bash
# Create custom backup script: custom-backup.sh
#!/bin/bash
set -euo pipefail

# Create backup
BACKUP_FILE=$(./backup.sh --type full --full-verification)

# Sync to multiple remotes
rclone copy "$BACKUP_FILE" gdrive:vaultwarden-backups/
rclone copy "$BACKUP_FILE" s3:my-bucket/vaultwarden/
rclone copy "$BACKUP_FILE" dropbox:backups/vaultwarden/

echo "Multi-destination backup complete"
```

## Email Customization

### External SMTP Relay

```yaml
# Use external SMTP instead of msmtpd
# Create docker-compose.override.yml
services:
  vaultwarden:
    environment:
      - SMTP_HOST=smtp.sendgrid.net
      - SMTP_PORT=587
      - SMTP_SECURITY=starttls
      - SMTP_USERNAME=${SMTP_USERNAME}
      - SMTP_PASSWORD_FILE=/run/secrets/smtp_password
  
  # Remove msmtpd if using external SMTP
  msmtpd:
    deploy:
      replicas: 0
```

### Custom Email Templates

```bash
# Mount custom templates
# Edit docker-compose.yml.example
services:
  vaultwarden:
    volumes:
      - ./email-templates:/data/templates
```

## Security Customization

### Custom Fail2Ban Rules

**More Aggressive Blocking**:
```ini
# Edit fail2ban/jail.d/vaultwarden-oci.conf
[vaultwarden-auth]
maxretry = 2       # Decreased from 3
bantime = 24h      # Increased from 2h
findtime = 10m     # Decreased from 1h
```

**Custom Filter for Specific Patterns**:
```ini
# Create fail2ban/filter.d/vaultwarden-custom.conf
[Definition]
failregex = ^.*Custom attack pattern.*<HOST>.*$
ignoreregex =
```

### Additional Security Headers

```caddyfile
# Edit caddy/Caddyfile
header {
    # Additional security headers
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Feature-Policy "geolocation 'none'; microphone 'none'; camera 'none'"
    Expect-CT "enforce, max-age=86400"
    
    # Custom headers
    X-Custom-Header "VaultWarden-OCI"
}
```

### IP Whitelisting

```caddyfile
# Edit caddy/Caddyfile
@admin_access {
    path /admin*
}

handle @admin_access {
    # Only allow from specific IPs
    @allowed_ips {
        remote_ip 192.168.1.0/24 10.0.0.0/8
    }
    
    handle @allowed_ips {
        basic_auth {
            import secret_admin_basic_auth_hash
        }
        reverse_proxy vaultwarden:80
    }
    
    handle {
        respond "Access Denied" 403
    }
}
```

## Performance Optimization

### Database Optimization

**Enable WAL Mode Permanently**:
```bash
# Add to startup script
docker compose exec vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA journal_mode=WAL;"
docker compose exec vaultwarden sqlite3 /data/db.sqlite3 "PRAGMA synchronous=NORMAL;"
```

**Increase Cache Size**:
```bash
# Edit .env
# Add custom database settings
VAULTWARDEN_SQLITE_CACHE_SIZE=-2000  # 2MB cache (negative = KB)
```

### Caddy Optimizations

```caddyfile
# Edit caddy/Caddyfile
{
    # Global options
    servers {
        protocol {
            experimental_http3
        }
        
        # Connection limits
        max_header_size 16384
        
        # Timeouts
        idle_timeout 5m
        read_header_timeout 10s
    }
}
```

### Enable Compression

```caddyfile
# Edit caddy/Caddyfile
encode {
    gzip 6
    zstd
    minimum_length 256
    match {
        header Content-Type text/*
        header Content-Type application/json*
        header Content-Type application/javascript*
    }
}
```

## Monitoring Integration

### Prometheus Exporter

```yaml
# Add to docker-compose.yml.example
services:
  vaultwarden-exporter:
    image: vaultwarden/exporter:latest
    restart: unless-stopped
    environment:
      - VAULTWARDEN_URL=http://vaultwarden:80
    ports:
      - "9195:9195"
```

### Custom Health Checks

```bash
# Create custom-health.sh
#!/bin/bash
# Extended health checks

# Check specific endpoints
curl -f https://vault.example.com/alive || exit 1
curl -f https://vault.example.com/api/config || exit 1

# Check database size
DB_SIZE=$(docker compose exec vaultwarden du -sm /data/db.sqlite3 | cut -f1)
if [ "$DB_SIZE" -gt 1000 ]; then
    echo "Warning: Database over 1GB"
fi

# Check certificate expiry
DAYS_LEFT=$(echo | openssl s_client -servername vault.example.com -connect vault.example.com:443 2>/dev/null | openssl x509 -noout -checkend $((30*86400)))
if [ $? -ne 0 ]; then
    echo "Warning: Certificate expires in <30 days"
fi

echo "Custom health checks passed"
```

### Grafana Dashboard

```bash
# Create grafana dashboard JSON
cat > vaultwarden-dashboard.json << 'EOF'
{
  "dashboard": {
    "title": "VaultWarden-OCI Metrics",
    "panels": [
      {
        "title": "Container Memory Usage",
        "targets": [
          {
            "expr": "container_memory_usage_bytes{name=~'vaultwarden.*'}"
          }
        ]
      },
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "rate(caddy_http_requests_total[5m])"
          }
        ]
      }
    ]
  }
}
EOF
```

## High Availability Setup

### Load Balancer Configuration

```yaml
# Add HAProxy for load balancing
services:
  haproxy:
    image: haproxy:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    depends_on:
      - vaultwarden1
      - vaultwarden2
```

### Shared Storage for HA

```yaml
# Use NFS or distributed storage
services:
  vaultwarden1:
    volumes:
      - nfs-data:/data
      
  vaultwarden2:
    volumes:
      - nfs-data:/data

volumes:
  nfs-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=nfs-server,rw
      device: ":/export/vaultwarden"
```

## Development Environment

### Development Override

```yaml
# docker-compose.override.yml for development
services:
  vaultwarden:
    environment:
      - SIGNUPS_ALLOWED=true
      - LOG_LEVEL=debug
      - DOMAIN=http://localhost:8080
    ports:
      - "8080:80"
    
  # Disable production services
  fail2ban:
    deploy:
      replicas: 0
  
  caddy:
    deploy:
      replicas: 0
```

### Local Testing

```bash
# Use make targets for development
make dev-setup       # Setup development environment
make test           # Run tests
make test-config    # Validate configuration
```

## Integration Examples

### SSO Integration (via Reverse Proxy)

```caddyfile
# Edit caddy/Caddyfile
# Add OAuth2 proxy
vault.example.com {
    # OAuth2 authentication
    forward_auth oauth2-proxy:4180 {
        uri /oauth2/auth
        copy_headers X-Auth-Request-User X-Auth-Request-Email
    }
    
    reverse_proxy vaultwarden:80
}
```

### LDAP Integration

```yaml
# Add LDAP container for authentication
services:
  ldap-auth:
    image: nitnelave/lldap:latest
    environment:
      - LLDAP_JWT_SECRET=${LDAP_JWT_SECRET}
      - LLDAP_LDAP_USER_PASS=${LDAP_USER_PASS}
```

### Webhook Notifications

```bash
# Add webhook script: webhook-notify.sh
#!/bin/bash
# Send webhook on events

EVENT="$1"
MESSAGE="$2"

curl -X POST https://your-webhook-url.com/notify \\
  -H "Content-Type: application/json" \\
  -d "{
    \\"event\\": \\"$EVENT\\",
    \\"message\\": \\"$MESSAGE\\",
    \\"timestamp\\": \\"$(date -Iseconds)\\"
  }"
```

## Custom Scripts and Automation

### Auto-Update Script

```bash
# Create auto-update.sh
#!/bin/bash
set -euo pipefail

# Backup before update
./backup.sh --type full --full-verification

# Update containers
./update.sh --system

# Verify health
sleep 30
./health.sh --comprehensive || {
    echo "Health check failed, rolling back..."
    ./restore.sh --file /path/to/pre-update-backup.age
    exit 1
}

echo "Update completed successfully"
```

### Custom Metrics Collection

```bash
# Create metrics-collector.sh
#!/bin/bash
# Collect custom metrics

TIMESTAMP=$(date +%s)
DB_SIZE=$(docker compose exec -T vaultwarden du -sm /data/db.sqlite3 | cut -f1)
USERS=$(docker compose exec -T vaultwarden sqlite3 /data/db.sqlite3 "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
CIPHERS=$(docker compose exec -T vaultwarden sqlite3 /data/db.sqlite3 "SELECT COUNT(*) FROM ciphers;" 2>/dev/null || echo "0")

# Output in Prometheus format
cat << EOF
# HELP vaultwarden_db_size_mb Database size in megabytes
# TYPE vaultwarden_db_size_mb gauge
vaultwarden_db_size_mb $DB_SIZE $TIMESTAMP

# HELP vaultwarden_users_total Total number of users
# TYPE vaultwarden_users_total gauge
vaultwarden_users_total $USERS $TIMESTAMP

# HELP vaultwarden_ciphers_total Total number of vault items
# TYPE vaultwarden_ciphers_total gauge
vaultwarden_ciphers_total $CIPHERS $TIMESTAMP
EOF
```

## Troubleshooting Custom Configurations

### Validation Workflow

```bash
# Always validate custom configurations
# 1. Validate template syntax
docker compose -f docker-compose.yml.example config

# 2. Test in dry-run mode
./startup.sh --dry-run

# 3. Apply and monitor
./startup.sh --force-restart
docker compose logs -f

# 4. Verify health
./health.sh --comprehensive
```

### Rollback Procedure

```bash
# If customization fails
# 1. Stop services
./startup.sh --down

# 2. Restore original templates
git checkout docker-compose.yml.example

# 3. Regenerate configuration
sudo ./setup.sh --force --domain vault.example.com --email admin@example.com

# 4. Restart
./startup.sh
```

## Best Practices for Customization

1. **Always use templates**: Edit `.example` files, not generated files
2. **Validate before applying**: Use `docker compose config`
3. **Test in development**: Use override files for testing
4. **Document changes**: Keep clear notes of customizations
5. **Version control**: Commit template changes to git
6. **Backup before changes**: Create backup before major changes
7. **Monitor after changes**: Watch logs and health checks
8. **Have rollback plan**: Know how to revert changes
9. **Test incrementally**: Make one change at a time
10. **Keep it simple**: Only customize what's necessary

---

This advanced customization guide provides comprehensive strategies for tailoring VaultWarden-OCI to specific needs while maintaining the template-based architecture and operational best practices.
