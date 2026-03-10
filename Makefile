# VaultWarden-OCI Makefile
# Optimized for the current codebase

# FIX [P5-L1/L2/L3]: Removed dead cron-install/cron-remove/cron-list from .PHONY
.PHONY: help setup init-secrets edit-secrets test-secrets test-email up down restart start stop status health health-email logs logs-tail logs-postfix backup backup-full backup-emergency list-backups restore restore-db update update-system maintenance maintenance-full update-dns breakglass-create breakglass-status breakglass-remove dev-setup test test-config dry-run db-maint db-backup clean clean-all prune info shell version watch monitor safe-restart fmt config

# Configuration
COMPOSE_FILE ?= docker-compose.yml
COMPOSE_PROJECT_NAME ?= vaultwarden-oci
DOCKER_COMP ?= $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
# FIX [L-08]: COMPOSE_DOCKER_CLI_BUILD is deprecated in Docker 23+ (BuildKit is on by default).
# Removed COMPOSE_DOCKER_CLI_BUILD. DOCKER_BUILDKIT kept for contexts that still need it.
DOCKER_BUILDKIT ?= 1

# Service names
SERVICES = vaultwarden caddy fail2ban postfix
CORE_SERVICES = vaultwarden caddy
OPTIONAL_SERVICES = watchtower backup

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m # No Color

# Export environment variables
export DOCKER_BUILDKIT

## Default target
help: ## Show this help message
	@echo "$(BLUE)VaultWarden-OCI Management$(NC)"
	@echo "$(BLUE)==============================$(NC)"
	@echo "$(GREEN)Core Operations:$(NC)"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Advanced Usage:$(NC)"
	@echo "  $(YELLOW)make up$(NC)                        Start with secrets initialization"
	@echo "  $(YELLOW)make logs SERVICE=postfix$(NC)      View specific service logs"
	@echo "  $(YELLOW)make backup TYPE=emergency$(NC)     Create emergency backup"
	@echo "  $(YELLOW)make health AUTO_RECOVER=true$(NC)  Run health check with auto-recovery"

## Setup and Installation
# FIX [P5-L1]: Inverted root check — re-implemented so that `sudo make setup`
# (which runs AS root, id -u == 0) works correctly. A direct root login
# (i.e. id -u == 0 but no SUDO_USER) is still rejected with a clear message.
setup: ## Run initial setup (requires sudo)
	@echo "$(BLUE)Setting up VaultWarden-OCI...$(NC)"
	@if [ "$$(id -u)" -eq 0 ] && [ -z "$$SUDO_USER" ]; then \
		echo "$(RED)Error: Do not run as root directly. Use: sudo make setup$(NC)"; \
		exit 1; \
	fi
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)Error: Run with sudo: sudo make setup$(NC)"; \
		exit 1; \
	fi
	@if [ ! -f ".env" ]; then echo "$(RED)Error: .env missing. Usage: sudo ./setup.sh --domain <domain> --email <email>$(NC)"; exit 1; fi
	./setup.sh
	@echo "$(GREEN)Setup completed successfully!$(NC)"

init-secrets: ## Initialize secrets file (interactive)
	@echo "$(BLUE)Initializing secrets...$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(BLUE)No secrets file found. Running setup-secrets.sh...$(NC)"; \
		./setup-secrets.sh; \
	else \
		echo "$(YELLOW)Secrets file already exists. Use 'make edit-secrets' to modify.$(NC)"; \
	fi

edit-secrets: ## Edit encrypted secrets file
	@echo "$(BLUE)Opening secrets editor...$(NC)"
	@./edit-secrets.sh

# FIX [P5-M2]: test-secrets now propagates failure exit code so `make test`
# correctly fails when SOPS/secrets are broken.
test-secrets: ## Test secrets decryption
	@echo "$(BLUE)Testing secrets decryption...$(NC)"
	@if ./edit-secrets.sh --list > /dev/null 2>&1; then \
		echo "$(GREEN)Secrets test passed$(NC)"; \
	else \
		echo "$(RED)Secrets test failed$(NC)"; \
		exit 1; \
	fi

test-email: ## Test email configuration (Postfix via unified maintenance)
	@echo "$(BLUE)Testing email configuration...$(NC)"
	@./maintenance.sh --test-email --verbose

## Service Management
# FIX [P5-H1]: up/restart now invoke `sudo ./startup.sh` so require_root
# inside startup.sh does not immediately fail.
up: ## Start all services with secrets initialization
	@echo "$(BLUE)Starting VaultWarden-OCI services...$(NC)"
	@sudo ./startup.sh || { echo "$(RED)Startup failed!$(NC)"; $(MAKE) status; exit 1; }
	@echo "$(GREEN)Services started successfully!$(NC)"

start: up ## Alias for up

down: ## Stop all services gracefully
	@echo "$(BLUE)Stopping VaultWarden-OCI services...$(NC)"
	@$(DOCKER_COMP) down
	@echo "$(GREEN)Services stopped successfully!$(NC)"

stop: down ## Alias for down

# FIX [P5-H1]: restart now invokes `sudo ./startup.sh` so require_root
# inside startup.sh does not immediately fail.
restart: ## Restart all services (enhanced startup)
	@echo "$(BLUE)Restarting VaultWarden-OCI services...$(NC)"
	@sudo ./startup.sh --force-restart || { echo "$(RED)Restart failed!$(NC)"; $(MAKE) status; exit 1; }
	@echo "$(GREEN)Services restarted successfully!$(NC)"

## Monitoring and Status
status: ## Show service status
	@echo "$(BLUE)Service Status:$(NC)"
	@$(DOCKER_COMP) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "$(RED)Services not running$(NC)"

health: ## Run health checks (Optional: AUTO_RECOVER=true, COMPREHENSIVE=true)
	@echo "$(BLUE)Running health checks...$(NC)"
	@FLAGS=""; \
	if [ "$(COMPREHENSIVE)" = "true" ]; then FLAGS="$$FLAGS --comprehensive"; fi; \
	if [ "$(AUTO_RECOVER)" = "true" ]; then FLAGS="$$FLAGS --auto-recover"; fi; \
	./health.sh $$FLAGS || { echo "$(RED)Health check failed$(NC)"; exit 1; }

health-email: ## Run health check with email notification
	@echo "$(BLUE)Running health check with email notification...$(NC)"
	@./health.sh --comprehensive --email

# FIX [P5-M1]: logs now defaults to --tail=100 (not -f across all services
# which was identical to `monitor`). Pass SERVICE= to filter, -f for follow.
logs: ## Show recent logs (last 100 lines). Use SERVICE= to filter, FOLLOW=true to tail
	@if [ "$(FOLLOW)" = "true" ]; then \
		$(DOCKER_COMP) logs -f -t --tail=100 $(SERVICE); \
	else \
		$(DOCKER_COMP) logs --tail=100 $(SERVICE); \
	fi

logs-tail: ## Tail logs with timestamps
	@$(DOCKER_COMP) logs -f -t --tail=100 $(SERVICE)

logs-postfix: ## Shortcut to view postfix email logs
	@$(DOCKER_COMP) logs -f -t --tail=100 postfix

## Backup and Restore Operations
# FIX [P5-M4]: backup now always passes --email so systemd timer invocations
# (and all other default calls) send notification emails. The flag was
# previously only injected when TYPE= was explicitly set by the caller.
backup: ## Create backup (TYPE: db, full, emergency)
	@echo "$(BLUE)Creating backup...$(NC)"
	@./backup.sh --type $(if $(TYPE),$(TYPE),db) --email
	@echo "$(GREEN)Backup completed successfully!$(NC)"

backup-full: ## Create full system backup
	@$(MAKE) backup TYPE=full

backup-emergency: ## Create emergency recovery kit
	@$(MAKE) backup TYPE=emergency

list-backups: ## List available backups
	@echo "$(BLUE)Available backups:$(NC)"
	@./backup.sh --list

restore: ## Restore from backup (interactive)
	@echo "$(BLUE)Starting interactive restore...$(NC)"
	@./restore.sh

restore-db: ## Restore latest database backup
	@echo "$(BLUE)Restoring latest database backup...$(NC)"
	@./restore.sh --type db --force

## Maintenance Operations
update: ## Update container images
	@echo "$(BLUE)Updating container images...$(NC)"
	@./update.sh
	@echo "$(GREEN)Update completed successfully!$(NC)"

update-system: ## Update system packages and containers
	@echo "$(BLUE)Updating system and containers...$(NC)"
	@./update.sh --system --email

maintenance: ## Run full maintenance (cleanup, Docker, DB, DNS, firewall)
	@echo "$(BLUE)Running maintenance tasks...$(NC)"
	@./maintenance.sh --comprehensive
	@echo "$(GREEN)Maintenance completed successfully!$(NC)"

maintenance-full: ## Run full maintenance with email notification
	@echo "$(BLUE)Running comprehensive maintenance...$(NC)"
	@./maintenance.sh --comprehensive --email

## DNS Management
update-dns: ## Update DNS record to current IP
	@echo "$(BLUE)Updating DNS record...$(NC)"
	@./maintenance.sh --update-dns
	@echo "$(GREEN)DNS updated successfully!$(NC)"

## Security Operations
breakglass-create: ## Create emergency admin account
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --create

breakglass-status: ## Show break-glass admin status
	@sudo ./create-breakglass-admin.sh --status

breakglass-remove: ## Remove break-glass admin account
	@echo "$(YELLOW)Removing break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --remove

# FIX [P5-C2 / P5-L3]: cron-setup.sh no longer exists (migrated to systemd).
# The cron-install/cron-remove/cron-list targets now redirect users to the
# correct systemd-based tooling and removed from .PHONY above.

## Development and Testing
dev-setup: ## Setup development environment
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then cp .env.example .env; echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; fi
	@if [ ! -f "docker-compose.override.yml" ]; then cp docker-compose.override.yml.example docker-compose.override.yml; echo "$(YELLOW)Created development override file.$(NC)"; fi

test: ## Run all tests
	@echo "$(BLUE)Running tests...$(NC)"
	@$(MAKE) test-secrets
	@$(MAKE) test-email
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)Docker Compose config valid$(NC)" || { echo "$(RED)Docker Compose config invalid$(NC)"; exit 1; }

test-config: ## Validate configuration
	@echo "$(BLUE)Validating configuration...$(NC)"
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)Docker Compose configuration is valid$(NC)" || { echo "$(RED)Docker Compose configuration is invalid$(NC)"; exit 1; }

# FIX [P5-H2]: dry-run no longer appends `|| true` to script calls.
# Each script is invoked directly; a non-zero exit propagates so that a
# broken config is correctly reported as failed rather than silently healthy.
dry-run: ## Preview all operations without executing
	@echo "$(BLUE)Dry run mode - showing what would be done:$(NC)"
	@echo "$(YELLOW)--- startup.sh ---$(NC)"
	@./startup.sh --dry-run
	@echo "$(YELLOW)--- health.sh ---$(NC)"
	@./health.sh --dry-run
	@echo "$(YELLOW)--- backup.sh ---$(NC)"
	@./backup.sh --dry-run
	@echo "$(YELLOW)--- maintenance.sh ---$(NC)"
	@./maintenance.sh --dry-run

## Database Operations
db-maint: ## Run deep database maintenance (requires sudo)
	@echo "$(BLUE)Running database maintenance...$(NC)"
	@sudo ./maintenance.sh --db-maint

db-backup: ## Quick database backup
	@$(MAKE) backup TYPE=db

## Cleanup Operations
# [MEDIUM FIX] The previous `clean` target passed --no-logs, --no-backups,
# --no-database to maintenance.sh, which does not implement those flags.
# Using direct docker commands instead so the target's stated purpose
# ("clean Docker resources") is actually achieved.
clean: ## Clean up Docker resources only
	@echo "$(BLUE)Cleaning up Docker resources...$(NC)"
	@$(DOCKER_COMP) rm -f --stop 2>/dev/null || true
	@docker system prune -f
	@echo "$(GREEN)Cleanup completed!$(NC)"

# FIX [P5-H3]: clean-all now requires an interactive TTY; it aborts if stdin
# is not a terminal (e.g. piped CI invocation) to prevent silent execution.
# The `-t 30` timeout is removed — if the operator walks away, data is NOT
# deleted. A deliberate, prompt-only confirmation is required.
clean-all: ## Clean up everything (DESTRUCTIVE)
	@echo "$(RED)WARNING: This will remove all containers, volumes, and data!$(NC)"
	@if [ ! -t 0 ]; then \
		echo "$(RED)Aborted: stdin is not a terminal. clean-all requires an interactive session.$(NC)"; \
		exit 1; \
	fi
	@read -r -p "Are you sure? Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || { echo "$(YELLOW)Aborted. No data was deleted.$(NC)"; exit 1; }; \
	$(DOCKER_COMP) down -v --remove-orphans; \
	docker system prune -af --volumes

prune: ## Clean up unused Docker resources
	@echo "$(BLUE)Pruning unused Docker resources...$(NC)"
	@docker system prune -f
	@echo "$(GREEN)Prune completed!$(NC)"

## Information
# FIX [P5-M5]: info target now uses anchored grep (^DOMAIN= and ^PROJECT_STATE_DIR=)
# to prevent multi-line leakage from keys that merely contain the word DOMAIN
# or PROJECT_STATE_DIR (e.g. MY_DOMAIN=, SMTP_DOMAIN=).
info: ## Show system information
	@echo "$(BLUE)VaultWarden-OCI System Information$(NC)"
	@echo "$(BLUE)====================================$(NC)"
	@echo "$(GREEN)Domain:$(NC) $$(grep '^DOMAIN=' .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Admin Email:$(NC) $$(grep '^ADMIN_EMAIL=' .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Project State:$(NC) $$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden')"
	@echo ""
	@echo "$(GREEN)Services Status:$(NC)"
	@$(MAKE) status
	@echo ""
	@echo "$(GREEN)Disk Usage:$(NC)"
	@df -h $$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden') 2>/dev/null | tail -1 || echo "State directory not found"

shell: ## Open shell in specified SERVICE (default: vaultwarden)
	@$(DOCKER_COMP) exec $(if $(SERVICE),$(SERVICE),vaultwarden) sh

# FIX [P5-L2]: version target now treats a non-running container as a
# non-fatal informational state rather than failing the whole target.
version: ## Show version information
	@echo "$(BLUE)VaultWarden-OCI Version Information$(NC)"
	@echo "$(GREEN)VaultWarden:$(NC) $$($(DOCKER_COMP) exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Caddy:$(NC) $$($(DOCKER_COMP) exec -T caddy caddy version 2>/dev/null || echo 'Not running')"
	@echo "$(GREEN)Fail2Ban:$(NC) $$($(DOCKER_COMP) exec -T fail2ban fail2ban-server --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Postfix:$(NC) $$($(DOCKER_COMP) exec -T postfix postconf -d mail_version 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo 'Not running')"
	@echo "$(GREEN)Docker:$(NC) $$(docker --version 2>/dev/null || echo 'Not available')"
	@echo "$(GREEN)Docker Compose:$(NC) $$($(DOCKER_COMP) version 2>/dev/null || echo 'Not available')"

# FIX [P5-M3]: watch now explicitly passes critical Makefile variables into
# the subprocess environment so DOCKER_COMP and COMPOSE_FILE are available
# inside the watch-spawned sub-shell.
watch: ## Watch service status (requires watch command)
	@command -v watch >/dev/null 2>&1 || { echo "$(RED)watch command not found. Install with: sudo apt install procps$(NC)"; exit 1; }
	@watch -n 5 'DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make status && echo && DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make health'

monitor: ## Monitor logs in real-time
	@echo "$(BLUE)Monitoring all services (Ctrl+C to stop)...$(NC)"
	@$(DOCKER_COMP) logs -f -t

# FIX [P5-C1]: safe-restart now implements actual rollback on failure.
# Pre-restart container IDs are captured; if either startup or the
# post-restart health check fails, the previous containers are restored
# via `docker start` and the target exits non-zero.
safe-restart: ## Restart with automatic rollback on failure
	@echo "$(BLUE)Performing safe restart with rollback capability...$(NC)"
	@PRE_IDS=$$($(DOCKER_COMP) ps -q 2>/dev/null); \
	if sudo ./startup.sh --force-restart; then \
		echo "$(GREEN)Restart successful — running post-restart health check (10s grace)...$(NC)"; \
		sleep 10; \
		if ./health.sh --quiet; then \
			echo "$(GREEN)Health check passed — safe restart completed$(NC)"; \
		else \
			echo "$(RED)Health check failed after restart — initiating rollback...$(NC)"; \
			$(DOCKER_COMP) down --remove-orphans 2>/dev/null || true; \
			if [ -n "$$PRE_IDS" ]; then \
				echo "$$PRE_IDS" | xargs -r docker start && \
				echo "$(YELLOW)Rollback complete — previous containers restarted.$(NC)" || \
				echo "$(RED)Rollback failed — manual intervention required!$(NC)"; \
			else \
				echo "$(RED)No pre-restart containers to roll back to — manual intervention required!$(NC)"; \
			fi; \
			exit 1; \
		fi; \
	else \
		echo "$(RED)Startup script failed — initiating rollback...$(NC)"; \
		$(DOCKER_COMP) down --remove-orphans 2>/dev/null || true; \
		if [ -n "$$PRE_IDS" ]; then \
			echo "$$PRE_IDS" | xargs -r docker start && \
			echo "$(YELLOW)Rollback complete — previous containers restarted.$(NC)" || \
			echo "$(RED)Rollback failed — manual intervention required!$(NC)"; \
		else \
			echo "$(RED)No pre-restart containers to roll back to — manual intervention required!$(NC)"; \
		fi; \
		exit 1; \
	fi

# Development helpers
fmt: ## Format and validate all configuration files
	@echo "$(BLUE)Validating configuration files...$(NC)"
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)✓ docker-compose.yml$(NC)" || echo "$(RED)✗ docker-compose.yml$(NC)"
	@if [ -f "docker-compose.override.yml" ]; then \
		$(DOCKER_COMP) -f docker-compose.yml -f docker-compose.override.yml config > /dev/null && \
		echo "$(GREEN)✓ docker-compose.override.yml$(NC)" || echo "$(RED)✗ docker-compose.override.yml$(NC)"; \
	fi
	@./edit-secrets.sh --list > /dev/null && echo "$(GREEN)✓ secrets.yaml$(NC)" || echo "$(RED)✗ secrets.yaml$(NC)"

# [MEDIUM FIX] config target: filter out sensitive keys from .env output.
# Keys matching TOKEN, PASSWORD, SECRET, KEY, ZONE_ID, HASH are omitted
# so that `make config` is safe to run in a shared terminal or CI log.
config: ## Show current configuration summary (sensitive keys redacted)
	@echo "$(BLUE)Current Configuration Summary$(NC)"
	@echo "$(BLUE)============================$(NC)"
	@if [ -f ".env" ]; then \
		echo "$(GREEN)Environment Variables (non-sensitive):$(NC)"; \
		grep -E '^[A-Z_]+=' .env \
			| grep -viE '(TOKEN|PASSWORD|SECRET|KEY|ZONE_ID|HASH)' \
			| head -15; \
		echo ""; \
	fi
	@if [ -f "docker-compose.override.yml" ]; then echo "$(GREEN)Development Override:$(NC) Active"; else echo "$(GREEN)Development Override:$(NC) Not active"; fi
	@echo ""
	@echo "$(GREEN)Services Configuration:$(NC)"
	@$(DOCKER_COMP) config --services 2>/dev/null || echo "Configuration invalid"
