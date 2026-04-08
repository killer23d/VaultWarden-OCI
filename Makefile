# ===========================================================================
# VaultWarden-OCI — Makefile
# ===========================================================================
# Usage:
#   sudo make setup          — First-time installation
#   make up                  — Start services
#   make down                — Stop services
#   make status              — Show service status
#   make logs                — Follow service logs
#   make help                — Show this help
# ===========================================================================

# ── Colour helpers ──────────────────────────────────────────────────────────
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
NC     := \033[0m

# ── Phony targets ───────────────────────────────────────────────────────────
.PHONY: help \
        setup init-secrets edit-secrets test-secrets test-email \
        up down restart status logs \
        backup restore \
        key-health key-backup key-escrow \
        update update-system update-dns \
        maintenance maintenance-full \
        install-systemd remove-systemd systemd-status systemd-validate \
        test fmt lint shellcheck \
        uninstall

# ── Helpers ─────────────────────────────────────────────────────────────────
define require-root
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)Error: Run with sudo: sudo make $@$(NC)"; \
		exit 1; \
	fi
endef

# ===========================================================================
##@ Help
# ===========================================================================

help: ## Show this help message
	@echo ""
	@echo "$(BLUE)VaultWarden-OCI — Available Targets$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf ""} \
	     /^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) } \
	     /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2 }' \
	    $(MAKEFILE_LIST)
	@echo ""

# ===========================================================================
##@ Setup & Installation
# ===========================================================================

# FIX [P5-L1]: Inverted root check — sudo make setup (id -u == 0 + SUDO_USER)
# works; direct root login (id -u == 0, no SUDO_USER) is rejected.
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
	@echo "$(BLUE)==> Running setup.sh$(NC)" | tee -a setup.log
	@if ./setup.sh 2>&1 | tee -a setup.log; then \
		echo "$(GREEN)==> setup.sh completed$(NC)" | tee -a setup.log; \
	else \
		echo "$(RED)==> FAILED: setup.sh — check setup.log for details; re-run: sudo make setup$(NC)" | tee -a setup.log; \
		exit 1; \
	fi
	@echo "$(GREEN)Setup completed successfully!$(NC)" | tee -a setup.log

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

# FIX [P5-M2]: propagate failure exit code so `make test` fails correctly.
test-secrets: ## Test secrets decryption
	@echo "$(BLUE)Testing secrets decryption...$(NC)"
	@if ./edit-secrets.sh --list > /dev/null 2>&1; then \
		echo "$(GREEN)Secrets decryption: OK$(NC)"; \
	else \
		echo "$(RED)Secrets decryption: FAILED$(NC)"; \
		exit 1; \
	fi

test-email: ## Send a test email notification
	@echo "$(BLUE)Sending test email...$(NC)"
	@./backup.sh --test-email

# ===========================================================================
##@ Service Management
# ===========================================================================

up: ## Start all services with secrets initialization
	$(call require-root)
	@echo "$(BLUE)Starting VaultWarden services...$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(YELLOW)No secrets file found. Initializing...$(NC)"; \
		./setup-secrets.sh; \
	fi
	@docker compose up -d
	@echo "$(GREEN)Services started successfully!$(NC)"

down: ## Stop all services
	$(call require-root)
	@echo "$(BLUE)Stopping VaultWarden services...$(NC)"
	@docker compose down
	@echo "$(GREEN)Services stopped.$(NC)"

restart: ## Restart all services
	$(call require-root)
	@echo "$(BLUE)Restarting VaultWarden services...$(NC)"
	@docker compose restart
	@echo "$(GREEN)Services restarted.$(NC)"

status: ## Show service status
	@docker compose ps

logs: ## Follow service logs (Ctrl+C to stop)
	@docker compose logs -f

# ===========================================================================
##@ Backup & Restore
# ===========================================================================

backup: ## Run manual backup
	$(call require-root)
	@echo "$(BLUE)Running backup...$(NC)"
	@./backup.sh
	@echo "$(GREEN)Backup completed!$(NC)"

restore: ## Restore from backup (interactive)
	$(call require-root)
	@echo "$(YELLOW)Starting restore process...$(NC)"
	@./restore.sh

# ===========================================================================
##@ Key Management
# ===========================================================================

key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	@echo "$(BLUE)Checking age key health...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; check_age_key_health' && \
		echo "$(GREEN)Age key health check passed$(NC)" || \
		{ echo "$(RED)Age key health check FAILED — run: sudo make setup$(NC)"; exit 1; }

key-backup: ## Create printable key backup (PDF or HTML)
	$(call require-root)
	@echo "$(BLUE)Creating printable key backup...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; create_printable_key_backup'

key-escrow: ## Create password manager escrow copy
	$(call require-root)
	@echo "$(BLUE)Creating password manager escrow...$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	ESCROW_FILE="$${HOME}/vaultwarden-escrow-$$(date +%Y%m%d-%H%M%S).txt"; \
	bash -c "set -euo pipefail; source lib/simple_key_resilience.sh; create_password_manager_escrow '$$ESCROW_FILE'"

# ===========================================================================
##@ Maintenance
# ===========================================================================

update: ## Update container images (briefly stops services)
	$(call require-root)
	@echo "$(YELLOW)NOTE: Services will be briefly stopped during the image update.$(NC)"
	@echo "$(BLUE)Updating container images...$(NC)"
	@./update.sh
	@echo "$(GREEN)Update completed successfully!$(NC)"

update-system: ## Update system packages and containers with email notification
	$(call require-root)
	@echo "$(YELLOW)NOTE: Services will be briefly stopped during the update.$(NC)"
	@echo "$(BLUE)Updating system and containers...$(NC)"
	@./update.sh --system --email

maintenance: ## Run comprehensive maintenance (cleanup, Docker, DB, DNS, firewall)
	$(call require-root)
	@echo "$(BLUE)Running maintenance tasks...$(NC)"
	@sudo ./maintenance.sh --comprehensive
	@echo "$(GREEN)Maintenance completed successfully!$(NC)"

maintenance-full: ## Run full maintenance with email notification
	$(call require-root)
	@echo "$(BLUE)Running comprehensive maintenance...$(NC)"
	@sudo ./maintenance.sh --comprehensive --email

update-dns: ## Update DNS record to current public IP
	$(call require-root)
	@echo "$(BLUE)Updating DNS record...$(NC)"
	@./update.sh --dns
	@echo "$(GREEN)DNS update completed!$(NC)"

# ===========================================================================
##@ Systemd Integration
# ===========================================================================

install-systemd: ## Install systemd service and timers
	$(call require-root)
	@echo "$(BLUE)Installing systemd units...$(NC)"
	@sudo ./setup-systemd.sh --install
	@echo "$(GREEN)Systemd units installed.$(NC)"

remove-systemd: ## Remove systemd service and timers
	$(call require-root)
	@sudo ./setup-systemd.sh --remove

systemd-status: ## Show systemd unit status
	@sudo ./setup-systemd.sh --status

systemd-validate: ## Validate systemd unit files
	@sudo ./setup-systemd.sh --validate

# ===========================================================================
##@ Testing & Validation
# ===========================================================================

test: ## Run all tests (secrets, email, compose config)
	@echo "$(BLUE)Running all tests...$(NC)"
	@$(MAKE) test-secrets
	@$(MAKE) fmt
	@echo "$(GREEN)All tests passed!$(NC)"

fmt: ## Validate all configuration files (compose + secrets)
	@echo "$(BLUE)Validating configuration files...$(NC)"
	@docker compose config > /dev/null && echo "$(GREEN)✓ docker-compose.yml$(NC)" || echo "$(RED)✗ docker-compose.yml$(NC)"
	@./edit-secrets.sh --list > /dev/null && echo "$(GREEN)✓ secrets.yaml$(NC)" || echo "$(RED)✗ secrets.yaml$(NC)"

lint: shellcheck ## Alias for shellcheck

shellcheck: ## Run shellcheck on all shell scripts
	@echo "$(BLUE)Running shellcheck...$(NC)"
	@FAILED=0; \
	for script in *.sh lib/*.sh; do \
		if shellcheck -S warning "$$script" 2>&1; then \
			echo "$(GREEN)✓ $$script$(NC)"; \
		else \
			echo "$(RED)✗ $$script$(NC)"; \
			FAILED=$$((FAILED + 1)); \
		fi; \
	done; \
	if [ "$$FAILED" -gt 0 ]; then \
		echo "$(RED)$$FAILED script(s) failed shellcheck$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)All scripts passed shellcheck$(NC)"

# ===========================================================================
##@ Uninstall
# ===========================================================================

uninstall: ## Completely remove VaultWarden-OCI (DESTRUCTIVE)
	$(call require-root)
	@echo "$(RED)WARNING: This will permanently remove VaultWarden and all data!$(NC)"
	@echo "$(RED)Press Ctrl+C within 10 seconds to cancel...$(NC)"
	@sleep 10
	@./uninstall-vaultwarden.sh
