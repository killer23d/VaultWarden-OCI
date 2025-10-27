# Makefile for VaultWarden-OCI-Simplified - Quality of Life Shortcuts

# Default Variables (Can be overridden: make logs SERVICE=caddy)
SERVICE ?= vaultwarden
LINES ?= 100
IP ?= "ENTER_IP_ADDRESS"
VERSION ?= "ENTER_VERSION"

# Phony targets to prevent conflicts with filenames
# --- START FIX & ENHANCEMENT ---
.PHONY: help up down restart logs logs-follow health backup-db backup-full backup-emergency list-backups restore maint-standard maint-deep db-maint update-containers update-system update-ips check-updates check-system-updates config-check configure-rclone status pins pin unpin edit-secrets unban breakglass-create breakglass-password breakglass-status
# --- END FIX & ENHANCEMENT ---

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
	# --- START FIX & ENHANCEMENT ---
	@echo "  list-backups   - List available local backups (./backup.sh --list)"
	@echo "  restore        - Start interactive restore from backup (./restore.sh --interactive)"
	@echo "                   # For non-interactive: ./restore.sh <backup-file>"
	# --- END FIX & ENHANCEMENT ---
	@echo "  configure-rclone - Interactively configure rclone for remote backups"
	@echo ""
	@echo "Updates & Maintenance:"
	@echo "  check-updates       - Check for available container updates (no changes)"
	@echo "  check-system-updates- Check for available system package updates (no changes)"
	@echo "  update-containers - Update container images (./update.sh --type containers)"
	@echo "  update-system     - Update system packages (sudo ./update.sh --type system)"
	@echo "  update-ips        - Update Cloudflare IPs in firewall (sudo ./update-cloudflare-ips.sh)"
	@echo "  maint-standard    - Run standard maintenance (sudo ./maintenance.sh --type standard)"
	@echo "  maint-deep        - Run deep maintenance (sudo ./maintenance.sh --type deep)"
	@echo "  db-maint          - Run database maintenance (sudo ./db-maint.sh)"
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
	@echo "  breakglass-create    - Create/Update break-glass admin (sudo ./create-breakglass-admin.sh create)"
	@echo "  breakglass-password  - Set password for break-glass admin (sudo ./create-breakglass-admin.sh password)"
	@echo "  breakglass-status    - Check status of break-glass admin (sudo ./create-breakglass-admin.sh status)"
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
	@df -h / /var/lib/vaultwarden ./backups | grep -v Filesystem || true
	@free -h | grep Mem || true
	@echo "\nPinned Versions:"
	@./update.sh --show-pins | grep -v "Currently pinned" | grep -v "default to" || echo "  (None - using latest)"
	@echo "\nRecent Backups (Top 3):"
	@# --- START FIX #5: Robust backup listing in status ---
	@./backup.sh --list | grep '\.age' | head -n 3 || echo "  No recent backups found."
	@# --- END FIX #5 ---
	@echo "\nFail2ban Status:"
	@docker compose exec fail2ban fail2ban-client status | grep "Jail list" || echo "  Fail2ban not running or status unavailable."
	@echo "------------------------------"


# --- Backups & Restore ---
backup-db:
	./backup.sh --type db

backup-full:
	./backup.sh --type full

backup-emergency:
	./backup.sh --type emergency

# --- START FIX & ENHANCEMENT ---
list-backups:
	./backup.sh --list

restore:
	./restore.sh --interactive
# --- END FIX & ENHANCEMENT ---

# --- Updates & Maintenance ---
# --- START FIX & ENHANCEMENT: Add check targets ---
check-updates:
	./update.sh --type containers --check-only

check-system-updates:
	sudo ./update.sh --type system --check-only
# --- END FIX & ENHANCEMENT ---

update-containers:
	./update.sh --type containers --backup # Always backup before container updates via make

update-system:
	sudo ./update.sh --type system

update-ips:
	sudo ./update-cloudflare-ips.sh

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
ifeq ($(SERVICE), ENTER_SERVICE_NAME)
	@echo "ERROR: Please specify SERVICE=..."
	@exit 1
endif
ifeq ($(VERSION), ENTER_VERSION)
	@echo "ERROR: Please specify VERSION=..."
	@exit 1
endif
	./update.sh --pin $(SERVICE) $(VERSION)

unpin:
ifeq ($(SERVICE), ENTER_SERVICE_NAME)
	@echo "ERROR: Please specify SERVICE=..."
	@exit 1
endif
	./update.sh --unpin $(SERVICE)

# --- Configuration & Security ---
edit-secrets:
	./edit-secrets.sh

unban:
ifeq ($(IP), ENTER_IP_ADDRESS)
	@echo "ERROR: Please specify IP=..."
	@exit 1
endif
	@echo "Unbanning IP $(IP) in all relevant jails..."
	docker compose exec fail2ban fail2ban-client set vaultwarden-admin unbanip $(IP) || echo "  (Not banned in vaultwarden-admin)"
	docker compose exec fail2ban fail2ban-client set vaultwarden-api unbanip $(IP) || echo "  (Not banned in vaultwarden-api)"
	docker compose exec fail2ban fail2ban-client set caddy-botsearch unbanip $(IP) || echo "  (Not banned in caddy-botsearch)"
	@echo "Attempted unban for IP $(IP)."

# --- START FIX & ENHANCEMENT: Add config-check and configure-rclone ---
config-check:
	@echo "Validating docker-compose configuration..."
	@if docker compose config --quiet; then \
		echo "Docker configuration syntax appears OK."; \
	else \
		echo "ERROR: Docker configuration validation failed!"; \
		exit 1; \
	fi

configure-rclone:
	@echo "Starting interactive rclone configuration..."
	rclone config
	@echo ""
	@echo "IMPORTANT: After configuring your remote, update the RCLONE_REMOTE_NAME"
	@echo "           variable in your .env file to match the name you chose."
	@grep '^RCLONE_REMOTE_NAME=' .env || echo "(Variable not found in .env yet)"
# --- END FIX & ENHANCEMENT ---


# --- Emergency Access ---
breakglass-create:
	sudo ./create-breakglass-admin.sh create

breakglass-password:
	sudo ./create-breakglass-admin.sh password

breakglass-status:
	sudo ./create-breakglass-admin.sh status

