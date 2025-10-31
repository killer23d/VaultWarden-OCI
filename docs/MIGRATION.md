# Migration Guide - VaultWarden-OCI

This guide helps you migrate to VaultWarden-OCI's template-based architecture and provides migration paths for different scenarios including version updates, system migrations, and configuration changes.

## Overview of Template-Based Migration

The VaultWarden-OCI template-based system provides:
- **Template-First Configuration**: All settings managed through `.example` files
- **Consistent Deployments**: Same templates produce identical configurations
- **Version Control Friendly**: Templates tracked in git, generated files excluded
- **Easy Updates**: Simple template editing with automatic configuration generation
- **Rollback Capability**: Easy reversion to previous template states

## Migration Types

### 1. Legacy to Template-Based Migration

If you have an existing VaultWarden-OCI installation without templates:

#### Pre-Migration Assessment
```bash
# Check if you have templates
ls -la *.example

# If missing, you need to migrate to template-based system
# Backup current configuration
cp docker-compose.yml docker-compose.yml.backup
cp .env .env.backup

# Create emergency backup
./backup.sh --type emergency --rclone
```

#### Migration Steps
```bash
# 1. Update repository to latest template-based version
git pull origin main

# 2. Stop services
./startup.sh --down

# 3. Run setup to generate templates from existing configuration
sudo ./setup.sh --domain $(grep DOMAIN .env | cut -d= -f2) --email $(grep ADMIN_EMAIL .env | cut -d= -f2) --force

# 4. Validate template-generated configuration
docker compose config

# 5. Start services with new template-based configuration
./startup.sh

# 6. Verify migration
./health.sh --comprehensive
```

### 2. Server Migration (Same Domain)

Moving to a new server while keeping the same domain:

#### Source Server Preparation
```bash
# Create comprehensive emergency kit
./backup.sh --type emergency --rclone --email

# Document current configuration
docker compose config > migration-config.yml
./backup.sh --list > migration-backups.txt
./create-breakglass-admin.sh status > migration-breakglass.txt

# Stop services on source server (when ready to migrate)
./startup.sh --down
```

#### Target Server Setup
```bash
# 1. Provision new server and install dependencies
sudo apt update && sudo apt upgrade -y

# 2. Clone repository
git clone https://github.com/killer23d/VaultWarden-OCI.git
cd VaultWarden-OCI
chmod +x *.sh

# 3. Transfer emergency kit to new server
scp emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age user@newserver:/tmp/

# 4. Restore from emergency kit (includes templates and configuration)
./restore.sh /tmp/emergency-kit-YYYYMMDD-HHMMSS.tar.gz.age

# 5. Validate template configuration
docker compose config

# 6. Start services
./startup.sh

# 7. Verify migration
./health.sh --comprehensive
```

## Configuration Migration Scenarios

### Enhanced Security Migration

Migrating to enhanced fail2ban and security features:

```bash
# 1. Update repository to latest version
git pull origin main

# 2. Create backup
./backup.sh --type emergency

# 3. Regenerate configuration with enhanced features
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Verify enhanced fail2ban configuration
docker compose config | grep -A 10 fail2ban

# 5. Restart with enhanced security
./startup.sh --force-restart

# 6. Verify enhanced fail2ban is working
docker compose logs fail2ban | grep -E "Rate|Enhanced"
```

### Version Migration

Updating to newer versions using template-based management:

```bash
# 1. Create emergency backup
./backup.sh --type emergency --rclone

# 2. Update version pins in template
nano .env.example
# Update version variables:
# VAULTWARDEN_VERSION=1.31.0
# CADDY_VERSION=2.8.5

# 3. Regenerate configuration from updated templates
sudo ./setup.sh --force --domain vault.yourdomain.com --email admin@yourdomain.com

# 4. Apply updates
./startup.sh --force-restart

# 5. Verify update
./health.sh --comprehensive
```

## Migration Best Practices

### Pre-Migration Preparation

1. **Complete Backup Strategy**
   ```bash
   # Create multiple backup types
   ./backup.sh --type db --rclone
   ./backup.sh --type full --rclone
   ./backup.sh --type emergency --rclone
   ```

2. **Document Current State**
   ```bash
   # Document current configuration
   docker compose config > pre-migration-config.yml
   docker compose ps > pre-migration-services.txt
   ./health.sh --comprehensive > pre-migration-health.txt
   ```

### During Migration

1. **Template-First Approach**
   - Always edit `.example` files first
   - Use `setup.sh --force` to regenerate configuration
   - Validate with `docker compose config` before starting services

2. **Validation Steps**
   ```bash
   # After each major change
   docker compose config
   ./health.sh --comprehensive
   curl -f https://vault.yourdomain.com/alive
   ```

### Migration Checklist

#### Pre-Migration
- [ ] Create comprehensive backups (db, full, emergency)
- [ ] Document current configuration and services
- [ ] Test migration in development environment
- [ ] Schedule maintenance window
- [ ] Prepare rollback procedures

#### Migration Execution
- [ ] Stop services gracefully
- [ ] Update templates with new configuration
- [ ] Regenerate configuration using setup.sh
- [ ] Validate template-generated configuration
- [ ] Start services and verify functionality
- [ ] Run comprehensive health checks

#### Post-Migration
- [ ] Verify all services are healthy
- [ ] Test critical functionality (login, admin panel)
- [ ] Confirm security features are active
- [ ] Update monitoring and alerting
- [ ] Create post-migration backup
- [ ] Update operational documentation

---

**Migration Support**: 
- Review the template-based architecture documentation
- Test all procedures in development environment first  
- Keep comprehensive backups throughout the migration process
- Document any custom configurations or deviations from templates

**Remember**: The template-based system is designed to make migrations safer and more predictable. Always validate template changes before applying them to production systems.
