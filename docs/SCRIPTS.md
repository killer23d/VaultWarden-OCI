# Scripts Reference - VaultWarden-OCI

This reference summarizes each management script, its purpose, key options, and current behavior in the project.

## Core Lifecycle

### startup.sh
- Purpose: Start/stop/restart all services with enhanced safety
- Highlights:
  - Secure secret handling and umask fixes
  - Health checks and readiness probes
  - Force-restart path for clean redeploys
- Usage:
```bash
./startup.sh            # Start services
./startup.sh --down     # Stop services
./startup.sh --force-restart  # Restart with clean state
```

### setup.sh
- Purpose: Generate configuration from templates and perform initial setup
- Highlights:
  - Template-based generation of docker-compose.yml and .env
  - Validation of environment and dependencies
  - Optional --use-latest for dev
- Usage:
```bash
sudo ./setup.sh --domain $DOMAIN --email $ADMIN_EMAIL --auto
sudo ./setup.sh --force --validate
```

### health.sh
- Purpose: System health diagnostics with auto-heal
- Highlights:
  - Container status, resource checks, backup verification
  - JSON output for monitoring systems
- Usage:
```bash
./health.sh --comprehensive
./health.sh --json
./health.sh --auto-heal
```

## Backups & Recovery

### backup.sh
- Purpose: Create encrypted backups using atomic operations
- Highlights:
  - Types: db, full, emergency
  - rclone integration, email notifications, verification
- Usage:
```bash
./backup.sh --type db [--rclone|--email]
./backup.sh --list
```

### restore.sh
- Purpose: Restore from backups with interactive selection
- Highlights:
  - Pre-restore safety backup, integrity verification
  - Template-integrated full/emergency restore
- Usage:
```bash
./restore.sh --interactive
./restore.sh --dry-run <backup-file>
```

## Security & Networking

### maintenance.sh
- Purpose: System cleanup and security maintenance
- Highlights:
  - Safe Cloudflare IP updates (add-before-remove)
  - Log rotation, cleanup tasks
- Usage:
```bash
sudo ./maintenance.sh --update-firewall
sudo ./maintenance.sh --comprehensive
```

### update-dns.sh
- Purpose: Manual DNS updates via Cloudflare
- Highlights:
  - Uses API token from secrets
- Usage:
```bash
./update-dns.sh --record A --name $DOMAIN --ip <IP>
```

### cron-setup.sh
- Purpose: Configure secure automation
- Highlights:
  - Validates script ownership and permissions (root:root, 700)
  - Creates hardened copies to /opt/vaultwarden-scripts
- Usage:
```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --validate
sudo ./cron-setup.sh --remove
```

## Emergency & Admin

### create-breakglass-admin.sh
- Purpose: Create and manage emergency admin for OCI console access
- Highlights:
  - Secure creation, validation, password rotation
- Usage:
```bash
./create-breakglass-admin.sh
./create-breakglass-admin.sh --status
./create-breakglass-admin.sh --password
```

### db-maint.sh
- Purpose: Database maintenance and optimization
- Highlights:
  - Analyze, vacuum (safe), integrity checks
- Usage:
```bash
sudo ./db-maint.sh --analyze-only
sudo ./db-maint.sh --optimize-safe
```

### edit-secrets.sh
- Purpose: Secure secrets editing with SOPS/age
- Highlights:
  - No key path exposure, backup creation, validation
- Usage:
```bash
./edit-secrets.sh
./edit-secrets.sh --validate
```

---

All scripts share common logging and utilities via lib/common.sh and security validation via lib/security.sh, ensuring consistent behavior and easier maintenance.
