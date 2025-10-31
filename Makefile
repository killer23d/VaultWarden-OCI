# VaultWarden-OCI-NG Makefile
# Modernized to match new scripts (backup --type, update --pin, etc.)
# Enhanced with DNS management for dynamic IP environments

.PHONY: help
.DEFAULT_GOAL := help

# Load environment variables quietly
-include .env
export

# --- Colors for Output ---
RED     := \033[0;31m
GREEN   := \033[0;32m
YELLOW  := \033[0;33m
BLUE    := \033[0;34m
NC      := \033[0m

##@ Help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Basic Operations
up: ## Start all services (includes DNS update)
	@echo "$(BLUE)[INFO]$(NC) Starting VaultWarden services..."
	@./startup.sh

down: ## Stop all services
	@echo "$(BLUE)[INFO]$(NC) Stopping VaultWarden services..."
	@./startup.sh --down

restart: ## Force restart all services (required after secrets changes)
	@echo "$(BLUE)[INFO]$(NC) Force restarting all services..."
	@./startup.sh --force-restart

status: ## Show container status
	@echo "$(BLUE)[INFO]$(NC) Checking container status..."
	@docker compose ps

##@ DNS Management
update-dns: ## Update Cloudflare DNS to current IP
	@echo "$(BLUE)[INFO]$(NC) Updating DNS record..."
	@./update-dns.sh

check-dns: ## Check current DNS record vs public IP (dry-run)
	@echo "$(BLUE)[INFO]$(NC) Checking DNS record..."
	@./update-dns.sh || echo "$(YELLOW)[INFO]$(NC) DNS check completed (may show differences)"

##@ Health & Monitoring
health: ## Run comprehensive health check
	@echo "$(BLUE)[INFO]$(NC) Running comprehensive health check..."
	@./health.sh --comprehensive

logs: ## Show logs for a service (e.g., make logs SERVICE=vaultwarden LINES=100)
	@docker compose logs --follow --tail=${LINES:-50} $(SERVICE)

logs-follow: ## Follow logs for a service (e.g., make logs-follow SERVICE=caddy)
	@docker compose logs --follow $(SERVICE)

config-check: ## Validate Docker Compose configuration
	@echo "$(BLUE)[INFO]$(NC) Validating Docker Compose files..."
	@docker compose config

##@ Backup & Restore
backup-db: ## Create a quick database-only backup
	@echo "$(BLUE)[INFO]$(NC) Creating database backup..."
	@./backup.sh --type db

backup-full: ## Create a full system backup (config + data)
	@echo "$(BLUE)[INFO]$(NC) Creating full system backup..."
	@./backup.sh --type full

backup-emergency: ## Create a disaster recovery emergency kit
	@echo "$(BLUE)[INFO]$(NC) Creating emergency recovery kit..."
	@./backup.sh --type emergency

list-backups: ## List all available local backups
	@echo "$(BLUE)[INFO]$(NC) Listing available local backups..."
	@./backup.sh --list

restore: ## Restore a backup interactively
	@echo "$(YELLOW)[WARN]$(NC) Starting interactive restore. This will stop services."
	@./restore.sh --interactive

configure-rclone: ## Run interactive setup for rclone remote backups
	@echo "$(BLUE)[INFO]$(NC) Starting rclone configuration..."
	@rclone config

##@ Version Management
pins: ## Show currently pinned container versions from .env
	@echo "$(BLUE)[INFO]$(NC) Showing pinned versions..."
	@./update.sh --show-pins

pin: ## Pin a service to a version (e.g., make pin SERVICE=vaultwarden VERSION=1.31.0)
	@echo "$(BLUE)[INFO]$(NC) Pinning $(SERVICE) to $(VERSION)..."
	@./update.sh --pin $(SERVICE) $(VERSION)

unpin: ## Unpin a service to use the 'latest' tag (e.g., make unpin SERVICE=caddy)
	@echo "$(BLUE)[INFO]$(NC) Unpinning $(SERVICE) to use 'latest'..."
	@./update.sh --unpin $(SERVICE)

check-updates: ## Check for available container updates (no changes made)
	@echo "$(BLUE)[INFO]$(NC) Checking for container updates..."
	@./update.sh --type containers --dry-run

check-system-updates: ## Check for available system (OS) package updates
	@echo "$(BLUE)[INFO]$(NC) Checking for system package updates..."
	@sudo ./update.sh --type system --dry-run

update-containers: ## Update containers to pinned/latest versions
	@echo "$(BLUE)[INFO]$(NC) Updating containers..."
	@./update.sh --type containers --no-backup

update-system: ## Update system (OS) packages
	@echo "$(BLUE)[INFO]$(NC) Updating system packages..."
	@sudo ./update.sh --type system

##@ Maintenance & Secrets
edit-secrets: ## Edit encrypted secrets file
	@echo "$(BLUE)[INFO]$(NC) Opening secrets editor..."
	@./edit-secrets.sh

test-secrets: ## Test if secrets can be decrypted
	@echo "$(BLUE)[INFO]$(NC) Testing secrets decryption..."
	@./edit-secrets.sh --test

show-secrets: ## Show decrypted secrets (USE WITH CAUTION)
	@echo "$(YELLOW)[WARN]$(NC) Displaying secrets in plain text!"
	@./edit-secrets.sh --show

maint-standard: ## Run standard maintenance (logs, docker prune, backups)
	@echo "$(BLUE)[INFO]$(NC) Running standard maintenance..."
	@sudo ./maintenance.sh --type standard

maint-deep: ## Run deep maintenance (standard + system cache)
	@echo "$(BLUE)[INFO]$(NC) Running deep system maintenance..."
	@sudo ./maintenance.sh --type deep

db-maint: ## Run on-demand database optimization (VACUUM)
	@echo "$(BLUE)[INFO]$(NC) Running database maintenance (VACUUM)..."
	@sudo ./db-maint.sh

##@ Emergency Access
breakglass-create: ## Create or update the emergency break-glass admin
	@echo "$(BLUE)[INFO]$(NC) Running break-glass admin setup..."
	@sudo ./create-breakglass-admin.sh create

breakglass-status: ## Check the status of the emergency break-glass admin
	@echo "$(BLUE)[INFO]$(NC) Checking break-glass admin status..."
	@sudo ./create-breakglass-admin.sh status

breakglass-password: ## Set/change the password for the emergency break-glass admin
	@echo "$(BLUE)[INFO]$(NC) Setting break-glass admin password..."
	@sudo ./create-breakglass-admin.sh password

##@ Security Maintenance
update-cf-ranges: ## Update UFW Cloudflare IP ranges
	@echo "$(BLUE)[INFO]$(NC) Updating UFW Cloudflare IP ranges..."
	@sudo ./maintenance.sh --type cf-ranges

check-cf-ranges: ## Check current UFW Cloudflare rules
	@echo "$(BLUE)[INFO]$(NC) Current UFW Cloudflare rules:"
	@sudo ufw status | grep "CF-"
