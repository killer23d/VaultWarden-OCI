# VaultWarden-OCI-NG Makefile
# Enhanced with permission fixes, cleanup tools, and Cloudflare IP management

# Default target
.DEFAULT_GOAL := help

# Variables
COMPOSE_FILE := docker-compose.yml
ENV_FILE := .env
PROJECT_NAME := vaultwarden

# Load environment variables
include $(ENV_FILE)
export

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

# Helper function to print colored output
define log_info
	@echo "$(BLUE)[INFO]$(NC) $(1)"
endef

define log_success
	@echo "$(GREEN)[SUCCESS]$(NC) $(1)"
endef

define log_warn
	@echo "$(YELLOW)[WARN]$(NC) $(1)"
endef

define log_error
	@echo "$(RED)[ERROR]$(NC) $(1)"
endef

##@ Help

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Basic Operations

.PHONY: up
up: ## Start all services
	$(call log_info,"Starting VaultWarden-OCI-NG services...")
	@./startup.sh

.PHONY: down
down: ## Stop all services
	$(call log_info,"Stopping VaultWarden-OCI-NG services...")
	@./startup.sh --down

.PHONY: restart
restart: ## Force restart all services (required after secrets changes)
	$(call log_info,"Force restarting all services...")
	@./startup.sh --force-restart

.PHONY: status
status: ## Show container status
	$(call log_info,"Checking container status...")
	@docker compose ps

##@ Health and Monitoring

.PHONY: health
health: ## Run comprehensive health check
	$(call log_info,"Running comprehensive health check...")
	@./health.sh --comprehensive

.PHONY: logs
logs: ## Show logs for a specific service (Usage: make logs SERVICE=vaultwarden)
ifndef SERVICE
	$(call log_error,"SERVICE parameter required. Usage: make logs SERVICE=vaultwarden")
	@exit 1
endif
	@docker compose logs --follow --tail=${LINES:-50} $(SERVICE)

.PHONY: logs-all
logs-all: ## Show logs for all services
	$(call log_info,"Showing logs for all services...")
	@docker compose logs --follow --tail=${LINES:-50}

.PHONY: monitor
monitor: ## Monitor system resources and container stats
	$(call log_info,"Monitoring system resources...")
	@echo "=== Container Stats ==="
	@docker compose top
	@echo -e "\n=== Resource Usage ==="
	@docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"

##@ Maintenance

.PHONY: update
update: ## Update container images and restart services
	$(call log_info,"Updating container images...")
	@docker compose pull
	$(call log_success,"Images updated. Restarting services...")
	@make restart

.PHONY: cleanup
cleanup: ## Clean up unused Docker resources
	$(call log_info,"Cleaning up unused Docker resources...")
	@docker system prune -f
	@docker volume prune -f
	$(call log_success,"Docker cleanup completed")

.PHONY: backup
backup: ## Create backup of important data
	$(call log_info,"Creating backup...")
	@./backup.sh --create
	$(call log_success,"Backup completed")

.PHONY: restore
restore: ## Restore from backup (Usage: make restore BACKUP_FILE=path/to/backup.tar.gz)
ifndef BACKUP_FILE
	$(call log_error,"BACKUP_FILE parameter required. Usage: make restore BACKUP_FILE=path/to/backup.tar.gz")
	@exit 1
endif
	$(call log_info,"Restoring from backup: $(BACKUP_FILE)")
	@./backup.sh --restore $(BACKUP_FILE)

##@ Security and Configuration

.PHONY: edit-secrets
edit-secrets: ## Edit encrypted secrets file
	$(call log_info,"Opening secrets editor...")
	@./edit-secrets.sh

.PHONY: update-secrets
update-secrets: ## Update secrets configuration
	$(call log_info,"Updating secrets configuration...")
	@./edit-secrets.sh

.PHONY: init-secrets
init-secrets: ## Initialize new secrets file
	$(call log_info,"Initializing new secrets file...")
	@./edit-secrets.sh --init

.PHONY: test-secrets
test-secrets: ## Test secrets decryption
	$(call log_info,"Testing secrets decryption...")
	@./edit-secrets.sh --test

.PHONY: show-secrets
show-secrets: ## Show decrypted secrets (DANGEROUS - use with caution)
	$(call log_warn,"WARNING: This will display secrets in plain text!")
	@read -p "Are you sure you want to continue? [y/N]: " confirm && [ "$$confirm" = "y" ] || exit 1
	@./edit-secrets.sh --show

.PHONY: strict-start
strict-start: ## Start with strict secrets validation (production mode)
	$(call log_info,"Starting with strict secrets validation...")
	@./startup.sh --strict-secrets

.PHONY: update-cf-ips
update-cf-ips: ## Update Cloudflare IP ranges
	$(call log_info,"Updating Cloudflare IP ranges...")
	@./update-cloudflare-ips.sh

.PHONY: update-cf-ips-force
update-cf-ips-force: ## Force update Cloudflare IP ranges
	$(call log_info,"Force updating Cloudflare IP ranges...")
	@./update-cloudflare-ips.sh --force

##@ Troubleshooting

.PHONY: fix-permissions
fix-permissions: ## Fix ownership and permission issues
	$(call log_warn,"Fixing file permissions and ownership...")
	@if [ -d "secrets/.docker_secrets" ]; then \
		sudo chown -R $(shell whoami):$(shell id -gn) secrets/.docker_secrets/ 2>/dev/null || true; \
		$(call log_success,"Fixed secrets directory ownership"); \
	fi
	@sudo chown -R $(shell whoami):$(shell id -gn) . 2>/dev/null || $(call log_warn,"Some files may still be root-owned")
	$(call log_success,"Permission fix completed")

.PHONY: clean-secrets
clean-secrets: ## Remove docker secrets directory (forces recreation on next start)
	$(call log_warn,"Removing docker secrets directory...")
	@sudo rm -rf secrets/.docker_secrets/
	$(call log_success,"Secrets directory cleaned. Next startup will recreate files.")

.PHONY: emergency-cleanup
emergency-cleanup: ## Emergency cleanup of all temporary files and containers
	$(call log_warn,"Emergency cleanup of all temporary files...")
	@sudo rm -rf secrets/.docker_secrets/ || true
	@docker compose down --volumes --remove-orphans || true
	@docker system prune -f || true
	$(call log_success,"Emergency cleanup completed. Use 'make up' to restart fresh.")

.PHONY: debug-mounts
debug-mounts: ## Debug volume mount issues
	$(call log_info,"Debugging volume mounts...")
	@echo "=== Checking local files ==="
	@ls -la caddy/
	@echo -e "\n=== Checking container mounts ==="
	@docker compose config | grep -A5 -B5 volumes || true
	@echo -e "\n=== Testing file access ==="
	@docker compose run --rm caddy ls -la /etc/caddy/ || $(call log_warn,"Caddy not accessible")

.PHONY: test-caddy-syntax
test-caddy-syntax: ## Test Caddy configuration syntax
	$(call log_info,"Testing Caddy configuration syntax...")
	@docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile || \
		$(call log_error,"Caddy configuration has syntax errors")

.PHONY: debug-secrets
debug-secrets: ## Debug secrets file issues
	$(call log_info,"Debugging secrets configuration...")
	@echo "=== Checking secrets files ==="
	@ls -la secrets/ || echo "No secrets directory"
	@if [ -d "secrets/.docker_secrets" ]; then \
		echo "=== Docker secrets files ==="; \
		ls -la secrets/.docker_secrets/; \
	else \
		echo "No docker secrets directory found"; \
	fi
	@echo "=== Testing secrets decryption ==="
	@./edit-secrets.sh --test || echo "Secrets decryption failed"

##@ Development

.PHONY: dev-start
dev-start: ## Start in development mode with verbose logging
	$(call log_info,"Starting in development mode...")
	@DEBUG=1 ./startup.sh --skip-health

.PHONY: shell
shell: ## Get shell access to a container (Usage: make shell SERVICE=vaultwarden)
ifndef SERVICE
	$(call log_error,"SERVICE parameter required. Usage: make shell SERVICE=vaultwarden")
	@exit 1
endif
	$(call log_info,"Opening shell in $(SERVICE) container...")
	@docker compose exec $(SERVICE) /bin/sh || docker compose exec $(SERVICE) /bin/bash

.PHONY: dry-run
dry-run: ## Show what startup would do without executing
	$(call log_info,"Running startup in dry-run mode...")
	@./startup.sh --dry-run

##@ Environment

.PHONY: env-check
env-check: ## Validate environment configuration
	$(call log_info,"Checking environment configuration...")
	@if [ ! -f "$(ENV_FILE)" ]; then \
		$(call log_error,"Environment file $(ENV_FILE) not found"); \
		exit 1; \
	fi
	@echo "✓ Environment file exists"
	@if [ -z "$(DOMAIN)" ]; then \
		$(call log_error,"DOMAIN not set in $(ENV_FILE)"); \
		exit 1; \
	fi
	@echo "✓ DOMAIN is set: $(DOMAIN)"
	@if [ -z "$(ADMIN_EMAIL)" ]; then \
		$(call log_error,"ADMIN_EMAIL not set in $(ENV_FILE)"); \
		exit 1; \
	fi
	@echo "✓ ADMIN_EMAIL is set: $(ADMIN_EMAIL)"
	$(call log_success,"Environment configuration is valid")

.PHONY: env-info
env-info: ## Show current environment information
	$(call log_info,"Current environment information:")
	@echo "Domain: $(DOMAIN)"
	@echo "Admin Email: $(ADMIN_EMAIL)"
	@echo "Project State Directory: $(PROJECT_STATE_DIR)"
	@echo "User ID: $(PUID)"
	@echo "Group ID: $(PGID)"
	@echo "Timezone: $(TZ)"

##@ Automation

.PHONY: install-cron
install-cron: ## Install automated maintenance cron jobs
	$(call log_info,"Installing automated maintenance tasks...")
	@./cron-setup.sh --install

.PHONY: remove-cron
remove-cron: ## Remove automated maintenance cron jobs
	$(call log_info,"Removing automated maintenance tasks...")
	@./cron-setup.sh --remove

.PHONY: show-cron
show-cron: ## Show currently installed cron jobs
	$(call log_info,"Currently installed cron jobs:")
	@crontab -l 2>/dev/null | grep -E "(VaultWarden-OCI|$(shell pwd))" || echo "No VaultWarden cron jobs found"

##@ Quick Actions

.PHONY: quick-restart
quick-restart: fix-permissions clean-secrets up ## Quick troubleshooting restart

.PHONY: full-reset
full-reset: emergency-cleanup update-cf-ips up ## Full system reset with updates

.PHONY: production-start
production-start: env-check update-cf-ips strict-start ## Production-ready startup

.PHONY: first-time-setup
first-time-setup: env-check init-secrets install-cron up ## Complete first-time setup

# Aliases for common typos and variations
.PHONY: satrt start stats stat log secrets
satrt start: up
stats stat: status  
log: logs
secrets: edit-secrets

# Compatibility aliases
.PHONY: update-secrets-file edit-secrets-file
update-secrets-file edit-secrets-file: edit-secrets
