# Makefile for VaultWarden-OCI-Simplified - Quality of Life Shortcuts

# Default Variables (Can be overridden: make logs SERVICE=caddy)
SERVICE ?= vaultwarden
LINES ?= 100
IP ?= "ENTER_IP_ADDRESS"
VERSION ?= "ENTER_VERSION"

# Phony targets to prevent conflicts with filenames
.PHONY: help up down restart logs logs-follow health backup-db backup-full backup-emergency list-backups restore maint-standard maint-deep db-maint update-containers update-system update-ips update-ips-force update-ips-check check-updates check-system-updates config-check configure-rclone status pins pin unpin edit-secrets unban breakglass-create breakglass-password breakglass-status

help:
	@echo "VaultWarden-OCI-Simplified Makefile"
	@echo ""
	@echo "Usage: make <target> [VARIABLE=value]"
	@echo ""
	@echo "Common Targets:"
	@echo "  up             - Start services (./startup.sh)"
	@echo "  down           - Stop services (./startup.sh --down)"
	@echo "  restart        - Force restart services (./startup.sh --force-restart)"
	@echo "  logs           - Show recent logs for a service (Default: vaultwarden)"
	@echo "                   Usage: make logs [SERVICE=caddy] [LINES=200]"
	@echo "  logs-follow    - Follow logs for a service (Default: vaultwarden)"
	@echo "                   Usage: make logs-follow [SERVICE=fail2ban]"
	@echo "  health         - Run comprehensive health check (./health.sh --comprehensive)"
	@echo "  status         - Show quick system status overview"
	@echo "  config-check   - Validate docker-compose configuration syntax"
	@echo ""
	@echo "Backup & Restore:"
	@echo "  backup-db      - Create database backup (./backup.sh --type db)"
	@echo "  backup-full    - Create full system backup (./backup.sh --type full)"
	@echo "  backup-emergency - Create emergency kit (./backup.sh --type emergency)"
	@echo "  list-backups   - List available local backups (./backup.sh --list)"
	@echo "  restore        - Start interactive restore from backup (./restore.sh --interactive)"
	@echo "  configure-rclone - Interactively configure rclone for remote backups"
	@echo ""
	@echo "Updates & Maintenance:"
	@echo "  check-updates       - Check for available container updates (no changes)"
	@echo "  check-system-updates- Check for available system package updates (no changes) (Requires sudo)"
	@echo "  update-containers - Update container images (./update.sh --type containers)"
	@echo "  update-system     - Update system packages (sudo ./update.sh --type system) (Requires sudo)"
	@echo "  maint-standard    - Run standard maintenance (sudo ./maintenance.sh --type standard) (Requires sudo)"
	@echo "  maint-deep        - Run deep maintenance (sudo ./maintenance.sh --type deep) (Requires sudo)"
	@echo "  db-maint          - Run database maintenance (sudo ./db-maint.sh) (Requires sudo)"
	@echo ""
	@echo "Cloudflare IP Management (Caddy Only):"
	@echo "  update-ips        - Update Cloudflare IPs in Caddy config (./update-cloudflare-ips.sh)"
	@echo "  update-ips-force  - Force update Cloudflare IPs (./update-cloudflare-ips.sh --force)"
	@echo "  update-ips-check  - Preview Cloudflare IP changes (./update-cloudflare-ips.sh --dry-run)"
	@echo ""
	@echo "Version Management:"
	@echo "  pins           - Show currently pinned versions (./update.sh --show-pins)"
	@echo "  pin            - Pin a service version (Requires SERVICE and VERSION)"
	@echo "                   Usage: make pin SERVICE=vaultwarden VERSION=1.31.0"
	@echo "  unpin          - Unpin a service version (Requires SERVICE)"
	@echo "                   Usage: make unpin SERVICE=caddy"
	@echo ""
	@echo "Configuration & Security:"
	@echo "  edit-secrets   - Edit encrypted secrets (./edit-secrets.sh)"
	@echo "  unban          - Unban an IP address in Fail2ban (Requires IP)"
	@echo "                   Usage: make unban IP=1.2.3.4"
	@echo ""
	@echo "Emergency Access (Break-Glass Admin):"
	@echo "  breakglass-create    - Create/Update break-glass admin (sudo ./create-breakglass-admin.sh create) (Requires sudo)"
	@echo "  breakglass-password  - Set password for break-glass admin (sudo ./create-breakglass-admin.sh password) (Requires sudo)"
	@echo "  breakglass-status    - Check status of break-glass admin (sudo ./create-breakglass-admin.sh status) (Requires sudo)"
	@echo ""


# --- Service Lifecycle ---
up:
	./startup.sh

down:
	./startup.sh --down

restart:
	./startup.sh --force-restart

# --- Monitoring & Status ---
logs:
	@echo "Showing last $(LINES) lines for $(SERVICE)... (Use Ctrl+C to stop)"
	docker compose logs --tail=$(LINES) $(SERVICE)

logs-follow:
	@echo "Following logs for $(SERVICE)... (Use Ctrl+C to stop)"
	docker compose logs -f $(SERVICE)

health:
	./health.sh --comprehensive

status:
	@echo "--- System Status Overview ---"
	@echo "Services:"
	@docker compose ps
	@echo "\nResources:"
	@df -h / /var/lib/vaultwarden ./backups 2>/dev/null | grep -v Filesystem || echo "  Resource paths may not exist yet."
	@free -h | grep Mem || true
	@echo "\nPinned Versions:"
	@./update.sh --show-pins | grep -v "Currently pinned" | grep -v "default to" || echo "  (None - using latest)"
	@echo "\nRecent Backups (Top 3):"
	@./backup.sh --list 2>/dev/null | grep '\.age' | head -n 3 || echo "  No recent backups found."
	@echo "\nFail2ban Status (vaultwarden-admin jail):"
	@docker compose exec fail2ban fail2ban-client status vaultwarden-admin 2>/dev/null | grep -E "Status|Currently banned" || echo "  Fail2ban jail 'vaultwarden-admin' status unavailable."
	@echo "------------------------------"


# --- Backups & Restore ---
backup-db:
	./backup.sh --type db

backup-full:
	./backup.sh --type full

backup-emergency:
	./backup.sh --type emergency

list-backups:
	./backup.sh --list

restore:
	./restore.sh --interactive

# --- Updates & Maintenance ---
check-updates:
	./update.sh --type containers --check-only

check-system-updates:
	sudo ./update.sh --type system --check-only

update-containers:
	./update.sh --type containers --backup # Always backup before container updates via make

update-system:
	sudo ./update.sh --type system

# Cloudflare IP Updates (Simplified)
update-ips:
	@echo "Updating Cloudflare IPs in Caddy config file..."
	./update-cloudflare-ips.sh

update-ips-force:
	@echo "Forcing update of Cloudflare IPs in Caddy config file..."
	./update-cloudflare-ips.sh --force

update-ips-check:
	@echo "Checking Cloudflare IP changes (dry run)..."
	./update-cloudflare-ips.sh --dry-run

# Maintenance
maint-standard:
	sudo ./maintenance.sh --type standard --force

maint-deep:
	sudo ./maintenance.sh --type deep --force

db-maint:
	sudo ./db-maint.sh --force

# --- Version Management ---
pins:
	./update.sh --show-pins

pin:
ifndef SERVICE
	$(error SERVICE is not set. Usage: make pin SERVICE=<service_name> VERSION=<version>)
endif
ifndef VERSION
	$(error VERSION is not set. Usage: make pin SERVICE=<service_name> VERSION=<version>)
endif
	./update.sh --pin $(SERVICE) $(VERSION)

unpin:
ifndef SERVICE
	$(error SERVICE is not set. Usage: make unpin SERVICE=<service_name>)
endif
	./update.sh --unpin $(SERVICE)

# --- Configuration & Security ---
edit-secrets:
	./edit-secrets.sh

unban:
ifndef IP
	$(error IP is not set. Usage: make unban IP=<ip_address>)
endif
	@echo "Attempting to unban IP $(IP) in Fail2ban jails..."
	docker compose exec fail2ban fail2ban-client set vaultwarden-admin unbanip $(IP) || echo "  IP $(IP) not found or already unbanned in vaultwarden-admin jail."
	docker compose exec fail2ban fail2ban-client set vaultwarden-api unbanip $(IP) || echo "  IP $(IP) not found or already unbanned in vaultwarden-api jail."
	docker compose exec fail2ban fail2ban-client set caddy-botsearch unbanip $(IP) || echo "  IP $(IP) not found or already unbanned in caddy-botsearch jail."
	@echo "Unban attempt finished for IP $(IP)."

config-check:
	@echo "Validating docker-compose configuration..."
	@if docker compose config --quiet; then \
		echo "Docker configuration syntax appears OK."; \
	else \
		echo "ERROR: Docker configuration validation failed!"; \
		docker compose config; \
		exit 1; \
	fi

configure-rclone:
	@echo "Starting interactive rclone configuration..."
	rclone config
	@echo ""
	@echo "IMPORTANT: After configuring your remote, update the RCLONE_REMOTE_NAME"
	@echo "           variable in your .env file to match the name you chose."
	@grep '^RCLONE_REMOTE_NAME=' .env || echo "(Variable not found in .env yet)"

# --- Emergency Access ---
breakglass-create:
	sudo ./create-breakglass-admin.sh create

breakglass-password:
	sudo ./create-breakglass-admin.sh password

breakglass-status:
	sudo ./create-breakglass-admin.sh status
