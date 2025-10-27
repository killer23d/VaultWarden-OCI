# Migration Guide - Version Management Updates

This guide helps you migrate from the previous version pinning approach to the new flexible version management system.

## Overview of Changes

The new version management system provides:
- **Flexible defaults**: `docker-compose.yml` now defaults to `latest` tags
- **Production stability**: `.env` file pins specific versions when desired
- **Easy switching**: Simple commands to pin/unpin versions
- **Enhanced update.sh**: New `--pin` and `--unpin` commands

## Migration Steps

### Step 1: Backup Current System

```bash
# Create emergency backup before migration
./backup.sh --type emergency --rclone --email

# Note current running versions
docker compose ps --format "table {{.Service}}	{{.Image}}" > current-versions.txt
```

### Step 2: Update Core Files

Replace the following files with the new versions:

1. **docker-compose.yml** → `docker-compose-updated.yml`
2. **.env.example** → `env-example-updated.txt`  
3. **update.sh** → `update-enhanced.sh`

```bash
# Backup originals
cp docker-compose.yml docker-compose.yml.backup
cp .env.example .env.example.backup
cp update.sh update.sh.backup

# Replace with new versions
cp docker-compose-updated.yml docker-compose.yml
cp env-example-updated.txt .env.example
cp update-enhanced.sh update.sh
chmod +x update.sh
```

### Step 3: Verify Current Configuration

Check that your existing `.env` file will continue to work:

```bash
# Check current version pins in .env
grep "_VERSION=" .env

# Expected output should show pinned versions:
# VAULTWARDEN_VERSION=1.30.5
# CADDY_VERSION=2.8.4
# FAIL2BAN_VERSION=1.1.0
# DDCLIENT_VERSION=3.11.2
```

**✅ If you see pinned versions**: No action needed, system will continue using current versions.

**❌ If no version pins exist**: Add them to maintain current behavior:
```bash
# Add current versions to .env file
echo "VAULTWARDEN_VERSION=1.30.5" >> .env
echo "CADDY_VERSION=2.8.4" >> .env
echo "FAIL2BAN_VERSION=1.1.0" >> .env
echo "DDCLIENT_VERSION=3.11.2" >> .env
```

### Step 4: Test Configuration

```bash
# Validate docker-compose configuration
docker compose config

# Should show no errors and display resolved image names
```

### Step 5: Apply Changes

```bash
# Restart services with new configuration
./startup.sh --force-restart

# Verify all services start correctly
docker compose ps

# Run comprehensive health check
./health.sh --comprehensive
```

## Verification

### Check Migration Success

```bash
# 1. Verify service status
docker compose ps
# All services should show "Up" status

# 2. Check image names
docker compose ps --format "table {{.Service}}	{{.Image}}"
# Should show your pinned versions, not "latest"

# 3. Test new version management commands
./update.sh --type containers --check-only
# Should show current status without errors

# 4. Test pin/unpin functionality
./update.sh --pin caddy 2.8.4
grep "CADDY_VERSION" .env
# Should show: CADDY_VERSION=2.8.4
```

### Verify Backup Compatibility

```bash
# Test backup creation with new system
./backup.sh --type db

# Verify backup can be restored
ls -la backups/db/
# Should show recent backup files
```

## Troubleshooting Migration Issues

### Issue: Services Won't Start After Migration

**Symptoms**: Containers exit or fail health checks

**Solution**:
```bash
# Check container logs
docker compose logs

# Verify .env file format
cat .env | grep -v '^#' | grep -v '^$'

# Reset to original configuration if needed
cp docker-compose.yml.backup docker-compose.yml
./startup.sh --force-restart
```

### Issue: Version Commands Not Working

**Symptoms**: `./update.sh --pin` commands fail

**Solution**:
```bash
# Ensure update.sh is executable
chmod +x update.sh

# Verify update.sh was replaced correctly
./update.sh --help | grep -E "pin|unpin"
# Should show new version management options

# Check .env file permissions
ls -la .env
# Should be readable/writable by your user
```

### Issue: Images Pull as "Latest" Despite Pins

**Symptoms**: Containers use latest images instead of pinned versions

**Solution**:
```bash
# Check environment variable loading
docker compose config | grep "image:"

# Verify .env syntax (no spaces around =)
grep "_VERSION" .env

# Correct format:
# VAULTWARDEN_VERSION=1.30.5

# Incorrect format (will be ignored):
# VAULTWARDEN_VERSION = 1.30.5
```

## Post-Migration Best Practices

### Production Environment

```bash
# Pin all services to current stable versions
./update.sh --pin vaultwarden 1.30.5
./update.sh --pin caddy 2.8.4
./update.sh --pin fail2ban 1.1.0
./update.sh --pin ddclient 3.11.2

# Verify pins are active
grep "_VERSION=" .env
```

### Development Environment

```bash
# Use latest versions for development
./update.sh --unpin vaultwarden
./update.sh --unpin caddy
./update.sh --unpin fail2ban
./update.sh --unpin ddclient

# Apply changes
./startup.sh --force-restart
```

## New Workflow Examples

### Safe Production Update

```bash
# 1. Check for updates
./update.sh --type containers --check-only

# 2. Create backup
./backup.sh --type full --rclone

# 3. Pin to new version
./update.sh --pin vaultwarden 1.31.0

# 4. Apply update
./update.sh --type containers

# 5. Verify health
./health.sh --comprehensive
```

### Emergency Security Update

```bash
# 1. Quickly unpin to get latest security patches
./update.sh --unpin vaultwarden

# 2. Update immediately
./update.sh --type containers

# 3. Verify and monitor
./health.sh --auto-heal --email-alert

# 4. Pin to specific version once validated
./update.sh --pin vaultwarden $(docker inspect vaultwarden_app --format='{{index .Config.Image}}' | cut -d: -f2)
```

### Testing New Versions

```bash
# 1. Create backup
./backup.sh --type db

# 2. Pin to test version
./update.sh --pin vaultwarden 1.31.0-beta

# 3. Update and test
./update.sh --type containers
./health.sh --comprehensive

# 4. Rollback if needed
./update.sh --pin vaultwarden 1.30.5
./startup.sh --force-restart
```

## Rollback Procedure

If you need to rollback the migration:

```bash
# 1. Stop services
./startup.sh --down

# 2. Restore original files
cp docker-compose.yml.backup docker-compose.yml
cp .env.example.backup .env.example
cp update.sh.backup update.sh
chmod +x update.sh

# 3. Restart with original configuration
./startup.sh --force-restart

# 4. Verify rollback
docker compose ps
./health.sh --comprehensive
```

## Support

If you encounter issues during migration:

1. **Check the troubleshooting section** in this guide
2. **Review container logs**: `docker compose logs`
3. **Verify backup integrity**: `./backup.sh --type emergency`
4. **Test emergency access**: `sudo ./create-breakglass-admin.sh status`

Remember: The new system is designed to be backward compatible. Your existing `.env` configuration should continue working without changes.
