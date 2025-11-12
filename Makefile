# VaultWarden-OCI-NG Makefile
# Enhanced: Supports standardized error handling and comprehensive automation
# Version: 2.0 - Production Ready

.PHONY: help setup up down restart status logs health backup restore update maintenance clean dev-setup test-secrets

# Configuration
COMPOSE_FILE ?= docker-compose.yml
COMPOSE_PROJECT_NAME ?= vaultwarden-oci
DOCKER_BUILDKIT ?= 1
COMPOSE_DOCKER_CLI_BUILD ?= 1

# Service names
SERVICES = vaultwarden caddy fail2ban
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
export COMPOSE_DOCKER_CLI_BUILD

## Default target
help: ## Show this help message
	@echo "$(BLUE)VaultWarden-OCI-NG Management$(NC)"
	@echo "$(BLUE)==============================$(NC)"
	@echo ""
	@echo "$(GREEN)Core Operations:$(NC)"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Advanced Usage:$(NC)"
	@echo "  $(YELLOW)make up PROFILE=watchtower$(NC)    Start with auto-updates"
	@echo "  $(YELLOW)make logs SERVICE=vaultwarden$(NC) View specific service logs"
	@echo "  $(YELLOW)make backup TYPE=emergency$(NC)    Create emergency backup"
	@echo "  $(YELLOW)make health COMPREHENSIVE=1$(NC)   Run comprehensive health check"

## Setup and Installation
setup: ## Run initial setup (requires sudo)
	@echo "$(BLUE)Setting up VaultWarden-OCI-NG...$(NC)"
	@if [ "$$(id -u)" -eq 0 ]; then \
		echo "$(RED)Error: Please run 'sudo make setup' or run setup.sh directly$(NC)"; \
		exit 1; \
	fi
	@if [ ! -f ".env" ]; then \
		echo "$(RED)Error: .env file not found. Please provide --domain and --email$(NC)"; \
		echo "Usage: sudo ./setup.sh --domain vault.example.com --email admin@example.com"; \
		exit 1; \
	fi
	sudo ./setup.sh
	@echo "$(GREEN)Setup completed successfully!$(NC)"

init-secrets: ## Initialize secrets file (interactive)
	@echo "$(BLUE)Initializing secrets...$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		./edit-secrets.sh --init; \
	else \
		echo "$(YELLOW)Secrets file already exists. Use 'make edit-secrets' to modify.$(NC)"; \
	fi

edit-secrets: ## Edit encrypted secrets file
	@echo "$(BLUE)Opening secrets editor...$(NC)"
	./edit-secrets.sh

test-secrets: ## Test secrets decryption
	@echo "$(BLUE)Testing secrets decryption...$(NC)"
	@./edit-secrets.sh --test && echo "$(GREEN)Secrets test passed$(NC)" || echo "$(RED)Secrets test failed$(NC)"

## Service Management
up: ## Start all services
	@echo "$(BLUE)Starting VaultWarden-OCI services...$(NC)"
ifdef PROFILE
	docker compose --profile $(PROFILE) up -d
else
	docker compose up -d
endif
	@echo "$(GREEN)Services started successfully!$(NC)"
	@$(MAKE) status

down: ## Stop all services
	@echo "$(BLUE)Stopping VaultWarden-OCI services...$(NC)"
	docker compose down
	@echo "$(GREEN)Services stopped successfully!$(NC)"

restart: ## Restart all services (enhanced startup)
	@echo "$(BLUE)Restarting VaultWarden-OCI services...$(NC)"
	# BEST PRACTICE FIX: Removed --skip-dns as it's no longer a valid flag for startup.sh
	@./startup.sh --force-restart || { \
		echo "$(RED)Restart failed, checking status...$(NC)"; \
		$(MAKE) status; \
		exit 1; \
	}
	@echo "$(GREEN)Services restarted successfully!$(NC)"

start: ## Start services with comprehensive startup script
	@echo "$(BLUE)Starting services with full initialization...$(NC)"
	@./startup.sh || { \
		echo "$(RED)Startup failed, checking status...$(NC)"; \
		$(MAKE) status; \
		exit 1; \
	}

stop: ## Stop services gracefully
	@echo "$(BLUE)Stopping services gracefully...$(NC)"
	@./startup.sh --down || docker compose down

## Monitoring and Status
status: ## Show service status
	@echo "$(BLUE)Service Status:$(NC)"
	@docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "$(RED)Services not running$(NC)"

health: ## Run health checks
	@echo "$(BLUE)Running health checks...$(NC)"
ifdef COMPREHENSIVE
	@./health.sh --comprehensive || { \
		echo "$(RED)Health check failed$(NC)"; \
		exit 1; \
	}
else
	@./health.sh || { \
		echo "$(RED)Health check failed$(NC)"; \
		exit 1; \
	}
endif

health-email: ## Run health check with email notification
	@echo "$(BLUE)Running health check with email notification...$(NC)"
	@./health.sh --comprehensive --email

logs: ## Show logs for all services or specific SERVICE
ifdef SERVICE
	docker compose logs -f $(SERVICE)
else
	docker compose logs -f
endif

logs-tail: ## Tail logs with timestamps
ifdef SERVICE
	docker compose logs -f -t --tail=100 $(SERVICE)
else
	docker compose logs -f -t --tail=100
endif

## Backup and Restore Operations
backup: ## Create backup (TYPE: db, full, emergency)
	@echo "$(BLUE)Creating backup...$(NC)"
ifdef TYPE
	@./backup.sh --type $(TYPE) --email || { \
		echo "$(RED)Backup failed$(NC)"; \
		exit 1; \
	}
else
	@./backup.sh --type db || { \
		echo "$(RED)Backup failed$(NC)"; \
		exit 1; \
	}
endif
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
	@./update.sh || { \
		echo "$(RED)Update failed$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Update completed successfully!$(NC)"

update-system: ## Update system packages and containers
	@echo "$(BLUE)Updating system and containers...$(NC)"
	@./update.sh --system --email || { \
		echo "$(RED)System update failed$(NC)"; \
		exit 1; \
	}

maintenance: ## Run basic maintenance
	@echo "$(BLUE)Running maintenance tasks...$(NC)"
	@./maintenance.sh || { \
		echo "$(RED)Maintenance failed$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Maintenance completed successfully!$(NC)"

maintenance-full: ## Run comprehensive maintenance
	@echo "$(BLUE)Running comprehensive maintenance...$(NC)"
	@./maintenance.sh --comprehensive --email || { \
		echo "$(RED)Comprehensive maintenance failed$(NC)"; \
		exit 1; \
	}

## DNS Management
update-dns: ## Update DNS record to current IP
	@echo "$(BLUE)Updating DNS record...$(NC)"
	@./update-dns.sh || { \
		echo "$(RED)DNS update failed$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)DNS updated successfully!$(NC)"

## Security Operations
breakglass-create: ## Create emergency admin account
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	sudo ./create-breakglass-admin.sh --create

breakglass-status: ## Show break-glass admin status
	sudo ./create-breakglass-admin.sh --status

breakglass-remove: ## Remove break-glass admin account
	@echo "$(YELLOW)Removing break-glass admin account...$(NC)"
	sudo ./create-breakglass-admin.sh --remove

## Automation Setup
cron-install: ## Install cron jobs for automation
	@echo "$(BLUE)Installing automation cron jobs...$(NC)"
	sudo ./cron-setup.sh --install

cron-remove: ## Remove cron jobs
	@echo "$(BLUE)Removing cron jobs...$(NC)"
	sudo ./cron-setup.sh --remove

cron-list: ## List current cron jobs
	sudo ./cron-setup.sh --list

## Development and Testing
dev-setup: ## Setup development environment
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then \
		cp .env.example .env; \
		echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; \
	fi
	@if [ ! -f "docker-compose.override.yml" ]; then \
		cp docker-compose.override.yml.example docker-compose.override.yml; \
		echo "$(YELLOW)Created development override file.$(NC)"; \
	fi

test: ## Run all tests
	@echo "$(BLUE)Running tests...$(NC)"
	@$(MAKE) test-secrets
	@docker compose config > /dev/null && echo "$(GREEN)Docker Compose config valid$(NC)" || echo "$(RED)Docker Compose config invalid$(NC)"

test-config: ## Validate configuration
	@echo "$(BLUE)Validating configuration...$(NC)"
	@docker compose config > /dev/null && echo "$(GREEN)Docker Compose configuration is valid$(NC)" || { \
		echo "$(RED)Docker Compose configuration is invalid$(NC)"; \
		exit 1; \
	}

dry-run: ## Show what operations would do without executing
	@echo "$(BLUE)Dry run mode - showing what would be done:$(NC)"
	@./startup.sh --dry-run
	@./health.sh --dry-run
	@./backup.sh --dry-run

## Database Operations
db-maint: ## Run database maintenance
	@echo "$(BLUE)Running database maintenance...$(NC)"
	@./db-maint.sh || { \
		echo "$(RED)Database maintenance failed$(NC)"; \
		exit 1; \
	}

db-backup: ## Quick database backup
	@$(MAKE) backup TYPE=db

## Cleanup Operations
clean: ## Clean up Docker resources
	@echo "$(BLUE)Cleaning up Docker resources...$(NC)"
	@./maintenance.sh --no-logs --no-backups --no-database || true
	@echo "$(GREEN)Cleanup completed!$(NC)"

clean-all: ## Clean up everything (DESTRUCTIVE)
	@echo "$(RED)WARNING: This will remove all containers, volumes, and data!$(NC)"
	@read -p "Are you sure? Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || exit 1
	docker compose down -v --remove-orphans
	docker system prune -af --volumes

prune: ## Clean up unused Docker resources
	@echo "$(BLUE)Pruning unused Docker resources...$(NC)"
	docker system prune -f
	@echo "$(GREEN)Prune completed!$(NC)"

## Information
info: ## Show system information
	@echo "$(BLUE)VaultWarden-OCI-NG System Information$(NC)"
	@echo "$(BLUE)====================================$(NC)"
	@echo "$(GREEN)Domain:$(NC) $$(grep DOMAIN .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Admin Email:$(NC) $$(grep ADMIN_EMAIL .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Project State:$(NC) $$(grep PROJECT_STATE_DIR .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden')"
	@echo ""
	@echo "$(GREEN)Services Status:$(NC)"
	@$(MAKE) status
	@echo ""
	@echo "$(GREEN)Disk Usage:$(NC)"
	@df -h $$(grep PROJECT_STATE_DIR .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden') 2>/dev/null | tail -1 || echo "State directory not found"

shell: ## Open shell in specified SERVICE (default: vaultwarden)
ifdef SERVICE
	docker compose exec $(SERVICE) sh
else
	docker compose exec vaultwarden sh
endif

version: ## Show version information
	@echo "$(BLUE)VaultWarden-OCI-NG Version Information$(NC)"
	@echo "$(GREEN)VaultWarden:$(NC) $$(docker compose exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Caddy:$(NC) $$(docker compose exec -T caddy caddy version 2>/dev/null || echo 'Not running')"
	@echo "$(GREEN)Fail2Ban:$(NC) $$(docker compose exec -T fail2ban fail2ban-server --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Docker:$(NC) $$(docker --version)"
	@echo "$(GREEN)Docker Compose:$(NC) $$(docker compose version)"

# Advanced targets for automation
watch: ## Watch service status (requires watch command)
	@command -v watch >/dev/null 2>&1 || { echo "$(RED)watch command not found. Install with: sudo apt install procps$(NC)"; exit 1; }
	watch -n 5 'make status && echo && make health'

monitor: ## Monitor logs in real-time
	@echo "$(BLUE)Monitoring all services (Ctrl+C to stop)...$(NC)"
	docker compose logs -f -t

# Error handling examples for automation
safe-restart: ## Restart with automatic rollback on failure
	@echo "$(BLUE)Performing safe restart with rollback capability...$(NC)"
	@if ./startup.sh --force-restart; then \
		echo "$(GREEN)Restart successful$(NC)"; \
		sleep 10; \
		if ./health.sh --quiet; then \
			echo "$(GREEN)Health check passed - restart completed$(NC)"; \
		else \
			echo "$(RED)Health check failed after restart - consider rollback$(NC)"; \
			exit 1; \
		fi; \
	else \
		echo "$(RED)Startup script failed$(NC)"; \
		exit 1; \
	fi

# Development helpers
fmt: ## Format and validate all configuration files
	@echo "$(BLUE)Validating configuration files...$(NC)"
	@docker compose config > /dev/null && echo "$(GREEN)✓ docker-compose.yml$(NC)" || echo "$(RED)✗ docker-compose.yml$(NC)"
	@if [ -f "docker-compose.override.yml" ]; then \
		docker compose -f docker-compose.yml -f docker-compose.override.yml config > /dev/null && \
		echo "$(GREEN)✓ docker-compose.override.yml$(NC)" || echo "$(RED)✗ docker-compose.override.yml$(NC)"; \
	fi
	@./edit-secrets.sh --test > /dev/null && echo "$(GREEN)✓ secrets.yaml$(NC)" || echo "$(RED)✗ secrets.yaml$(NC)"

# Show configuration summary
config: ## Show current configuration summary
	@echo "$(BLUE)Current Configuration Summary$(NC)"
	@echo "$(BLUE)============================$(NC)"
	@if [ -f ".env" ]; then \
		echo "$(GREEN)Environment Variables:$(NC)"; \
		grep -E '^[A-Z_]+=' .env | head -10; \
		echo ""; \
	fi
	@if [ -f "docker-compose.override.yml" ]; then \
		echo "$(GREEN)Development Override:$(NC) Active"; \
	else \
		echo "$(GREEN)Development Override:$(NC) Not active"; \
	fi
	@echo ""
	@echo "$(GREEN)Services Configuration:$(NC)"
	@docker compose config --services 2>/dev/null || echo "Configuration invalid"
