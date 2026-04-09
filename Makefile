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

# ── Restore configuration ───────────────────────────────────────────────────
# Override on the command line to target a specific archive, e.g.:
#   sudo make restore BACKUP_FILE=backups/db/vaultwarden-db-20250101-120000.age
BACKUP_FILE ?=

# ── Phony targets ───────────────────────────────────────────────────────────
.PHONY: help \
        setup init-secrets edit-secrets test-secrets test-email \
        up down restart status logs \
        backup restore restore-preflight \
        key-health key-backup key-escrow \
        update check-updates update-system update-dns \
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
# ── Pre-flight: refuse to start with the dev-only override present. ─────────
# docker-compose.override.yml is the local-development override created by
# copying docker-compose.override.dev.yml.example. Production hosts should not
# carry it at all; if it is present, abort before docker compose implicitly
# loads it and applies debug settings, relaxed hardening, or loopback-only
# development port mappings.
	@if [ -f "docker-compose.override.yml" ]; then \
		echo "$(RED)ERROR: docker-compose.override.yml exists.$(NC)"; \
		echo "$(RED)       This file is for local development only and must not$(NC)"; \
		echo "$(RED)       be present on a production host. Remove it, then$(NC)"; \
		echo "$(RED)       re-run: sudo make up$(NC)"; \
		exit 1; \
	fi
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(YELLOW)No secrets file found. Initializing...$(NC)"; \
		./setup-secrets.sh; \
	fi
# ── Pre-flight: verify the decoded admin_token secret file is non-empty. ────
# secrets/secrets.yaml being present only means the SOPS-encrypted source
# exists. The decoded file in secrets/.docker_secrets/ is written by
# setup-secrets.sh (or edit-secrets.sh). An empty file causes VaultWarden to
# start with admin panel DISABLED — confusing and hard to diagnose.
# `test -s` = file exists AND size > 0.
	@if ! test -s secrets/.docker_secrets/admin_token; then \
		echo "$(RED)ERROR: secrets/.docker_secrets/admin_token is missing or empty.$(NC)"; \
		echo "$(RED)       Run ./setup-secrets.sh (or make init-secrets) to generate secrets.$(NC)"; \
		exit 1; \
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

# ---------------------------------------------------------------------------
# restore-preflight: sanity-check the host before launching restore.sh.
#
# A panicked admin on a fresh or broken host gets clear, actionable error
# messages instead of a cryptic age/tar failure buried in restore output.
#
# Three checks (all must pass):
#   1. Docker daemon is reachable — restore.sh needs docker compose.
#   2. Secrets file is present and decryptable — the age key must be in
#      place before a restore is attempted (uses edit-secrets.sh --list,
#      the same path exercised by `make test-secrets`).
#   3. BACKUP_FILE exists — only validated when the caller has explicitly
#      set BACKUP_FILE=…; omitting it is still valid (restore.sh prompts
#      interactively).
# ---------------------------------------------------------------------------
restore-preflight: ## Pre-flight checks before restore (docker, secrets, backup file)
	$(call require-root)
	@echo "$(BLUE)Running restore pre-flight checks...$(NC)"
	@if ! docker info > /dev/null 2>&1; then \
		echo "$(RED)ERROR: Docker daemon is not running or not reachable.$(NC)"; \
		echo "$(RED)       Start Docker first: sudo systemctl start docker$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)  ✓ Docker daemon is reachable$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(RED)ERROR: secrets/secrets.yaml not found.$(NC)"; \
		echo "$(RED)       Run: sudo make setup  (or: sudo ./setup.sh ...)$(NC)"; \
		exit 1; \
	fi
	@if ! ./edit-secrets.sh --list > /dev/null 2>&1; then \
		echo "$(RED)ERROR: Cannot decrypt secrets/secrets.yaml — age key may be missing or wrong.$(NC)"; \
		echo "$(RED)       Ensure your age key is present (SOPS_AGE_KEY_FILE in .env) then re-run.$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)  ✓ Secrets file is present and decryptable$(NC)"
	@if [ -n "$(BACKUP_FILE)" ]; then \
		if [ ! -f "$(BACKUP_FILE)" ]; then \
			echo "$(RED)ERROR: Backup file not found: $(BACKUP_FILE)$(NC)"; \
			echo "$(RED)       Run: make backup  or specify a valid path with BACKUP_FILE=<path>$(NC)"; \
			exit 1; \
		fi; \
		echo "$(GREEN)  ✓ Backup file exists: $(BACKUP_FILE)$(NC)"; \
	fi
	@echo "$(GREEN)Pre-flight checks passed. Proceeding with restore...$(NC)"

restore: restore-preflight ## Restore from backup (interactive); optionally set BACKUP_FILE=<path>
	$(call require-root)
	@echo "$(YELLOW)Starting restore process...$(NC)"
	@if [ -n "$(BACKUP_FILE)" ]; then \
		./restore.sh "$(BACKUP_FILE)"; \
	else \
		./restore.sh; \
	fi

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

check-updates: ## Show available image updates without applying them
	@echo "$(BLUE)Checking configured image tags against remote registries...$(NC)"
	@bash -eu -o pipefail -c '\
		set -a; source .env.example; set +a; \
		images="ghcr.io/dani-garcia/vaultwarden:$${VAULTWARDEN_VERSION} ghcr.io/caddybuilds/caddy-cloudflare:$${CADDY_VERSION} boky/postfix:$${POSTFIX_VERSION} crazymax/fail2ban:$${FAIL2BAN_VERSION} busybox:$${BUSYBOX_VERSION}"; \
		for image in $$images; do \
			echo "$(YELLOW)==> $$image$(NC)"; \
			if docker manifest inspect "$$image" >/dev/null 2>&1; then \
				echo "$(GREEN)Available$(NC)"; \
			else \
				echo "$(RED)Not found or registry unavailable$(NC)"; \
			fi; \
		done'

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
