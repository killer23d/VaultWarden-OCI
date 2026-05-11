# ===========================================================================
# VaultWarden-OCI — Makefile
# ===========================================================================
# Usage:
#   sudo make setup          — First-time installation
#   make up                  — Start services (user must be in `docker` group)
#   make down                — Stop services
#   make restart             — Restart services
#   make safe-restart        — Restart with automatic rollback on failure
#   make status              — Show service status
#   make health              — Run health checks
#   make logs                — Follow service logs
#   make help                — Show all available targets
# ===========================================================================

# ── Colour helpers ──────────────────────────────────────────────────────────
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
CYAN   := \033[0;36m
NC     := \033[0m

# ── Configuration ────────────────────────────────────────────────────────────
COMPOSE_FILE         ?= docker-compose.yml
COMPOSE_PROJECT_NAME ?= vaultwarden-oci
DOCKER_COMP          ?= $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

SERVICES          = vaultwarden caddy fail2ban postfix
CORE_SERVICES     = vaultwarden caddy

# Override on the command line to target a specific archive, e.g.:
#   sudo make restore BACKUP_FILE=backups/db/vaultwarden-db-20250101-120000.age
BACKUP_FILE ?=
# Optional: sudo make setup DATA_DEVICE=/dev/sdb
DATA_DEVICE ?=

# ── Phony targets ───────────────────────────────────────────────────────────
.PHONY: help \
        setup init-secrets edit-secrets test-secrets test-email \
        up down restart start stop safe-restart status \
        health health-quick health-email \
        logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-fail2ban \
        watch monitor \
        backup backup-full backup-emergency list-backups backup-status \
        restore restore-preflight restore-db restore-remote \
        key-health key-backup key-escrow key-rotate key-show key-install \
        update check-updates update-system update-dns \
        maintenance maintenance-full \
        db-maint db-backup \
        install-systemd remove-systemd systemd-status systemd-validate timers \
        breakglass-create breakglass-status breakglass-remove \
        dev-setup fix-permissions test test-config dry-run fmt lint shellcheck \
        info version shell config diagnose \
        clean clean-all prune \
        unban \
        uninstall uninstall-dry-run

# ── Helpers ──────────────────────────────────────────────────────────────────
# require-root: used for targets that genuinely need elevated privileges
# (setup, backup, restore, key operations, maintenance, systemd, uninstall).
# Service management targets (up, down, restart) rely on the user being in
# the `docker` group instead.
define require-root
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)Error: Run with sudo: sudo make $@$(NC)"; \
		exit 1; \
	fi
endef

# check-docker: lightweight guard used by `up` and `down`.
# Verifies the Docker daemon is reachable without requiring root.
define check-docker
	@if ! docker info > /dev/null 2>&1; then \
		echo "$(RED)Error: Cannot connect to the Docker daemon.$(NC)"; \
		echo "$(RED)       Either Docker is not running, or your user is not in the docker group.$(NC)"; \
		echo "$(YELLOW)       Fix: sudo usermod -aG docker $$USER  then log out and back in.$(NC)"; \
		echo "$(YELLOW)       Or start Docker: sudo systemctl start docker$(NC)"; \
		exit 1; \
	fi
endef

# check-env-readable: guard for targets that read .env directly.
# Emits a clear error and actionable fix when .env exists but is not readable
# by the current user (e.g. root:root 600 with a non-root invoking user).
# Safe to call when .env does not exist — the guard only fires when the file
# is present but unreadable.
define check-env-readable
	@if [ -f ".env" ] && [ ! -r ".env" ]; then \
		echo "$(RED)Error: .env is not readable by $$(id -un).$(NC)"; \
		echo "$(YELLOW)Fix: sudo chown $$(id -un):$$(id -gn) .env$(NC)"; \
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
	     /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-24s$(NC) %s\n", $$1, $$2 }' \
	    $(MAKEFILE_LIST)
	@echo ""
	@echo "$(CYAN)Examples:$(NC)"
	@echo "  $(GREEN)make up$(NC)                          Start with secrets initialization"
	@echo "  $(GREEN)make logs SERVICE=caddy$(NC)          View caddy logs"
	@echo "  $(GREEN)make health AUTO_RECOVER=true$(NC)    Health check with auto-recovery"
	@echo "  $(GREEN)make safe-restart$(NC)                Restart with automatic rollback"
	@echo "  $(GREEN)make restore$(NC)                     Interactive restore"
	@echo "  $(GREEN)make diagnose$(NC)                    Full diagnostic dump"
	@echo "  $(GREEN)make backup-status$(NC)               Backup health summary"
	@echo "  $(GREEN)make lint$(NC)                        Shellcheck all scripts"
	@echo ""

# ===========================================================================
##@ Setup & Installation
# ===========================================================================

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
	@SETUP_ARGS=""; \
	[ -n "$(DATA_DEVICE)" ] && SETUP_ARGS="$$SETUP_ARGS --data-device $(DATA_DEVICE)"; \
	if ./setup.sh $$SETUP_ARGS 2>&1 | tee -a setup.log; then \
		echo "$(GREEN)==> setup.sh completed$(NC)" | tee -a setup.log; \
	else \
		echo "$(RED)==> FAILED: setup.sh — check setup.log for details; re-run: sudo make setup$(NC)" | tee -a setup.log; \
		exit 1; \
	fi
	@echo "$(GREEN)Setup completed successfully!$(NC)" | tee -a setup.log

dev-setup: ## Set up development environment (.env + docker-compose.override.yml)
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then cp .env.example .env; echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; fi
	@if [ ! -f "docker-compose.override.yml" ]; then cp docker-compose.override.yml.example docker-compose.override.yml; echo "$(YELLOW)Created development override file.$(NC)"; fi

fix-permissions: ## Fix file ownership after sudo operations leave root-owned files
	$(call require-root)
	@echo "$(BLUE)Fixing file ownership...$(NC)"
	@REAL_USER=$$(logname 2>/dev/null || echo "$${SUDO_USER:-ubuntu}"); \
	REAL_GROUP=$$(id -gn "$$REAL_USER" 2>/dev/null || echo "$$REAL_USER"); \
	echo "$(CYAN)  Target user : $$REAL_USER:$$REAL_GROUP$(NC)"; \
	echo ""; \
	for item in \
	    CHANGELOG.md Makefile README.md VERSION \
	    backup.sh create-breakglass-admin.sh edit-secrets.sh \
	    maintenance.sh restore.sh \
	    setup.sh startup.sh uninstall-vaultwarden.sh \
	    backups caddy docs fail2ban lib logs ssl systemd \
	    docker-compose.yml.example docker-compose.override.yml.example .env.example .sops.yaml \
	    .gitattributes .gitignore; do \
	    [ -e "$$item" ] && chown -R "$$REAL_USER:$$REAL_GROUP" "$$item" 2>/dev/null && \
	        echo "$(GREEN)  ✓ $$item$(NC)" || true; \
	done; \
	if [ -f ".env" ]; then \
	    chown "$$REAL_USER:$$REAL_GROUP" .env; \
	    chmod 600 .env; \
	    echo "$(GREEN)  ✓ .env → $$REAL_USER:$$REAL_GROUP (mode 600)$(NC)"; \
	fi; \
	if [ -f "docker-compose.yml" ]; then \
	    chown "$$REAL_USER:$$REAL_GROUP" docker-compose.yml; \
	    echo "$(GREEN)  ✓ docker-compose.yml$(NC)"; \
	fi; \
	if [ -f "docker-compose.override.yml" ]; then \
	    chown "$$REAL_USER:$$REAL_GROUP" docker-compose.override.yml; \
	    echo "$(GREEN)  ✓ docker-compose.override.yml$(NC)"; \
	fi; \
		if [ -f "caddy/entrypoint.sh" ] && [ ! -x "caddy/entrypoint.sh" ]; then \
	    chmod +x "caddy/entrypoint.sh"; \
	    echo "$(GREEN)  ✓ caddy/entrypoint.sh → +x$(NC)"; \
	fi; \
	if [ -d "secrets/keys" ]; then \
	    chown "$$REAL_USER:$$REAL_GROUP" secrets/keys; \
	    find secrets/keys -maxdepth 1 -name "*.txt" -exec chown "$$REAL_USER:$$REAL_GROUP" {} \; \
	              -exec chmod 600 {} \; 2>/dev/null; \
	    echo "$(GREEN)  ✓ secrets/keys/ → $$REAL_USER:$$REAL_GROUP (keys 600)$(NC)"; \
	fi; \
	if [ -d "/etc/vaultwarden" ]; then \
	    chmod 700 /etc/vaultwarden; \
	    chown root:root /etc/vaultwarden; \
	    if [ -f "/etc/vaultwarden/age-key.txt" ]; then \
	        chmod 600 /etc/vaultwarden/age-key.txt; \
	        chown root:root /etc/vaultwarden/age-key.txt; \
	        echo "$(GREEN)  ✓ /etc/vaultwarden/age-key.txt → root:root 600$(NC)"; \
	    fi; \
	    echo "$(GREEN)  ✓ /etc/vaultwarden/ → root:root 700$(NC)"; \
	fi; \
	echo ""; \
	echo "$(GREEN)File ownership fixed for user $$REAL_USER.$(NC)"; \
	echo "$(CYAN)Note: secrets/.docker_secrets/ is intentionally left restricted (root:root 444).$(NC)"; \
	echo "$(CYAN)      /etc/vaultwarden/ is intentionally root:root 700 (system key store).$(NC)"

init-secrets: ## Initialize secrets file (interactive)
	@echo "$(BLUE)Initializing secrets...$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(BLUE)No secrets file found. Running setup.sh secrets...$(NC)"; \
		./setup.sh secrets; \
	else \
		echo "$(YELLOW)Secrets file already exists. Use 'make edit-secrets' to modify.$(NC)"; \
	fi

edit-secrets: ## Edit encrypted secrets file
	@echo "$(BLUE)Opening secrets editor...$(NC)"
	@./edit-secrets.sh

test-secrets: ## Test secrets decryption
	@echo "$(BLUE)Testing secrets decryption...$(NC)"
	@if ./edit-secrets.sh list > /dev/null 2>&1; then \
		echo "$(GREEN)Secrets decryption: OK$(NC)"; \
	else \
		echo "$(RED)Secrets decryption: FAILED$(NC)"; \
		exit 1; \
	fi

test-email: ## Send a test email notification
	@echo "$(BLUE)Sending test email...$(NC)"
	@./maintenance.sh test-email

# ===========================================================================
##@ Service Management
# ===========================================================================

# up / down / restart do NOT require root. The invoking user must be a member
# of the `docker` group. If not, `check-docker` prints a clear fix command.
# startup.sh handles secrets initialisation, secrets pre-flight checks, and
# the post-start health poll — do not replace it with a bare `docker compose up`.

up: ## Start all services (runs startup.sh for health checks)
	$(call check-docker)
	@echo "$(BLUE)Starting VaultWarden services...$(NC)"
# ── Pre-flight: refuse to start with the dev-only override present. ─────────
# docker-compose.override.yml is the local-development override.
# Production hosts must not carry it; if present, abort before compose
# silently loads it and applies debug settings or dev port mappings.
	@if [ -f "docker-compose.override.yml" ]; then \
		echo "$(RED)ERROR: docker-compose.override.yml exists.$(NC)"; \
		echo "$(RED)       This file is for local development only and must not$(NC)"; \
		echo "$(RED)       be present on a production host. Remove it, then$(NC)"; \
		echo "$(RED)       re-run: make up$(NC)"; \
		exit 1; \
	fi
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(YELLOW)No secrets file found. Initializing...$(NC)"; \
		./setup.sh secrets; \
	fi
# ── Pre-flight: admin_token decoded-secret guard. ───────────────────────────
# MAKEFILE-UP1 FIX [MEDIUM]: startup.sh's prepare_docker_secrets() is the
# authoritative component that creates secrets/.docker_secrets/ from the
# SOPS-encrypted secrets.yaml.  Running a hard abort here (before startup.sh)
# created a chicken-and-egg failure on fresh clones and re-provisions: the
# decoded files cannot exist until startup.sh decrypts them, but the old
# guard refused to call startup.sh until the decoded files existed.
#
# New behaviour:
#   - If secrets.yaml is ABSENT → secrets were never initialised; abort and
#     direct the operator to ./setup.sh secrets  (unchanged intent).
#   - If secrets.yaml is PRESENT but admin_token is missing/empty → warn and
#     continue; startup.sh will decrypt and regenerate the docker-secret files.
#     If decryption itself fails (wrong/missing Age key), startup.sh's own
#     check_age_key_health_preflight() provides the actionable error message.
	@if ! test -f "secrets/secrets.yaml"; then \
		echo "$(RED)ERROR: secrets/secrets.yaml not found — secrets have never been initialised.$(NC)"; \
		echo "$(RED)       Run: ./setup.sh secrets  (or: make init-secrets)$(NC)"; \
		exit 1; \
	elif ! test -s "secrets/.docker_secrets/admin_token"; then \
		echo "$(YELLOW)WARN: secrets/.docker_secrets/admin_token is absent or empty.$(NC)"; \
		echo "$(YELLOW)      startup.sh will attempt to decrypt secrets.yaml and create it now.$(NC)"; \
		echo "$(YELLOW)      If this fails, run: make key-health  for diagnostics.$(NC)"; \
	fi
	@sudo ./startup.sh || { \
		echo "$(RED)Startup failed!$(NC)"; \
		$(MAKE) status; \
		echo ""; \
		echo "$(YELLOW)If startup failed due to a missing or misconfigured Age key:$(NC)"; \
		echo "$(YELLOW)  Diagnose: make key-health$(NC)"; \
		echo "$(YELLOW)  Auto-fix: sudo make key-install$(NC)"; \
		CONFIGURED_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
		[ -n "$$CONFIGURED_KEY" ] && echo "$(YELLOW)  Configured key path (from .env): $$CONFIGURED_KEY$(NC)"; \
		echo "$(YELLOW)  Canonical production path:        /etc/vaultwarden/age-key.txt$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Services started successfully!$(NC)"

start: up ## Alias for up

down: ## Stop all services gracefully
	$(call check-docker)
	@echo "$(BLUE)Stopping VaultWarden services...$(NC)"
	@$(DOCKER_COMP) down
	@echo "$(GREEN)Services stopped.$(NC)"

stop: down ## Alias for down

restart: ## Restart all services (via startup.sh)
	$(call check-docker)
	@echo "$(BLUE)Restarting VaultWarden services...$(NC)"
	@sudo ./startup.sh --force || { \
		echo "$(RED)Restart failed!$(NC)"; \
		$(MAKE) status; \
		echo "$(YELLOW)If restart failed due to a key issue, run: make key-health$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Services restarted.$(NC)"

safe-restart: ## Restart with automatic rollback on failure
	$(call check-docker)
	@echo "$(BLUE)Safe restart with rollback capability...$(NC)"
	@PRE_IDS=$$(docker compose ps -q 2>/dev/null || true); \
	if sudo ./startup.sh --force; then \
		echo "$(GREEN)Safe restart completed successfully.$(NC)"; \
	else \
		echo "$(RED)Restart failed! Attempting rollback...$(NC)"; \
		if [ -n "$$PRE_IDS" ]; then \
			docker compose down || true; \
			docker compose up -d || true; \
			echo "$(YELLOW)Rollback attempted. Check service status.$(NC)"; \
		fi; \
		$(MAKE) status; \
		exit 1; \
	fi

status: ## Show service status, backup health, disk usage, and Fail2Ban summary
	$(call check-docker)
	@echo "$(BLUE)VaultWarden Service Status:$(NC)"
	@$(DOCKER_COMP) ps
	@echo ""
	@echo "$(CYAN)Resource usage:$(NC)"
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep -E "vaultwarden|caddy|fail2ban|postfix" || true
	@echo ""
	@echo "$(CYAN)Backup status:$(NC)"
	@STATE_DIR=$$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2-); \
	STATE_DIR=$${STATE_DIR:-/var/lib/vaultwarden}; \
	BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2-); \
	BACKUP_DIR=$${BACKUP_DIR:-$$STATE_DIR/backups}; \
	for btype in db full emergency; do \
		DIR="$$BACKUP_DIR/$$btype"; \
		if [ -d "$$DIR" ]; then \
			LATEST=$$(find "$$DIR" -name "*.age" -type f 2>/dev/null | sort | tail -1); \
			if [ -n "$$LATEST" ]; then \
				TS=$$(basename "$$LATEST" | grep -oE '[0-9]{8}[_-][0-9]{6}' | head -1 || true); \
				SIZE=$$(du -sh "$$LATEST" 2>/dev/null | cut -f1 || echo "?"); \
				echo "  $(GREEN)$$btype$(NC): $$(basename $$LATEST)  ($$SIZE)  $$TS"; \
			else \
				echo "  $(YELLOW)$$btype$(NC): no backups found"; \
			fi; \
		else \
			echo "  $(YELLOW)$$btype$(NC): backup directory not found ($$DIR)"; \
		fi; \
	done
	@echo ""
	@echo "$(CYAN)Disk usage:$(NC)"
	@STATE_DIR=$$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2-); \
	STATE_DIR=$${STATE_DIR:-/var/lib/vaultwarden}; \
	BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2-); \
	BACKUP_DIR=$${BACKUP_DIR:-$$STATE_DIR/backups}; \
	for DIR in "$$STATE_DIR" "$$BACKUP_DIR"; do \
		if [ -d "$$DIR" ]; then \
			AVAIL=$$(df -h "$$DIR" 2>/dev/null | awk 'END {print $$4}'); \
			USED=$$(df -h "$$DIR" 2>/dev/null | awk 'END {printf "%s/%s (%s used)", $$3, $$2, $$5}'); \
			echo "  $$DIR — available: $$AVAIL  ($$USED)"; \
		fi; \
	done
	@echo ""
	@echo "$(CYAN)Fail2Ban bans:$(NC)"
	@if docker inspect vaultwarden_fail2ban --format '{{.State.Running}}' 2>/dev/null | grep -q true; then \
		docker exec vaultwarden_fail2ban sh -c \
		  'fail2ban-client status 2>/dev/null | grep "Jail list" | sed "s/.*Jail list://;s/,/ /g" | tr -s " " "\n" | grep -v "^$$"' \
		  2>/dev/null | while read -r jail; do \
		    COUNT=$$(docker exec vaultwarden_fail2ban sh -c "fail2ban-client status $$jail 2>/dev/null | grep 'Currently banned' | awk '{print \$$NF}'" 2>/dev/null || echo 0); \
		    echo "  $$jail: $$COUNT banned IP(s)"; \
		done || echo "  $(YELLOW)fail2ban-client not responding$(NC)"; \
	else \
		echo "  $(YELLOW)fail2ban container not running$(NC)"; \
	fi

# ===========================================================================
##@ Health & Monitoring
# ===========================================================================

health: ## Run health checks (set AUTO_RECOVER=true to auto-recover)
	@echo "$(BLUE)Running health checks...$(NC)"
	@sudo ./maintenance.sh health $(if $(filter true,$(AUTO_RECOVER)),--fix,)

health-quick: ## Quick health check (essential services only)
	@echo "$(BLUE)Running quick health check...$(NC)"
	@sudo ./maintenance.sh health --comprehensive

health-email: ## Test email health
	@echo "$(BLUE)Testing email health and sending notification...$(NC)"
	@sudo ./maintenance.sh health --report

watch: ## Watch service logs in real-time (Ctrl+C to stop)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f

monitor: ## Continuous health monitoring (30s intervals, Ctrl+C to stop)
	@echo "$(BLUE)Starting continuous monitoring (30s intervals)...$(NC)"
	@while true; do \
		clear; \
		echo "$(CYAN)=== VaultWarden Monitor — $$(date) ===$(NC)"; \
		$(DOCKER_COMP) ps; \
		echo ""; \
		docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep -E "vaultwarden|caddy|fail2ban|postfix" || true; \
		sleep 30; \
	done

unban: ## Unban an IP from all fail2ban jails (IP=<address> required)
	$(call require-root)
	@if [ -z "$(IP)" ]; then \
		echo "$(RED)Error: IP address required. Usage: sudo make unban IP=<address>$(NC)"; \
		echo "$(CYAN)Example: sudo make unban IP=203.0.113.42$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Unbanning $(IP) from all fail2ban jails...$(NC)"
	@if ! docker inspect vaultwarden_fail2ban --format '{{.State.Running}}' 2>/dev/null | grep -q true; then \
		echo "$(RED)Error: fail2ban container is not running.$(NC)"; \
		echo "$(YELLOW)Start the stack first: make up$(NC)"; \
		exit 1; \
	fi
	@JAILS=$$(docker exec vaultwarden_fail2ban fail2ban-client status 2>/dev/null \
		| grep 'Jail list' | sed 's/.*Jail list://;s/,/ /g' | tr -s ' ' '\n' | grep -v '^$$'); \
	 FOUND=0; \
	 for jail in $$JAILS; do \
		if docker exec vaultwarden_fail2ban fail2ban-client status "$$jail" 2>/dev/null \
			| grep -q '$(IP)'; then \
			echo "  $(CYAN)Unbanning $(IP) from jail: $$jail$(NC)"; \
			docker exec vaultwarden_fail2ban fail2ban-client set "$$jail" unbanip '$(IP)' \
				&& echo "  $(GREEN)✓ Unbanned from $$jail$(NC)" \
				|| echo "  $(YELLOW)⚠ Could not unban from $$jail (may have expired)$(NC)"; \
			FOUND=1; \
		fi; \
	 done; \
	 if [ "$$FOUND" -eq 0 ]; then \
		echo "$(YELLOW)$(IP) is not currently banned in any jail.$(NC)"; \
	 fi

# ===========================================================================
##@ Logs
# ===========================================================================

SERVICE ?= vaultwarden

logs: ## View service logs (SERVICE=<name> to filter, default: vaultwarden)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f $(SERVICE)

logs-tail: ## Tail last 100 lines of all service logs
	$(call check-docker)
	@$(DOCKER_COMP) logs --tail=100

logs-vaultwarden: ## Tail vaultwarden logs
	$(call check-docker)
	@$(DOCKER_COMP) logs -f vaultwarden

logs-caddy: ## Tail caddy logs
	$(call check-docker)
	@$(DOCKER_COMP) logs -f caddy

logs-postfix: ## Tail postfix logs
	$(call check-docker)
	@$(DOCKER_COMP) logs -f postfix

logs-fail2ban: ## Tail fail2ban logs
	$(call check-docker)
	@$(DOCKER_COMP) logs -f fail2ban

# ===========================================================================
##@ Backup & Restore
# ===========================================================================

backup: ## Run incremental database backup
	$(call require-root)
	@echo "$(BLUE)Running database backup...$(NC)"
	@./backup.sh run db

backup-full: ## Run full backup (database + attachments + config)
	$(call require-root)
	@echo "$(BLUE)Running full backup...$(NC)"
	@./backup.sh run full

backup-emergency: ## Create emergency backup kit
	$(call require-root)
	@echo "$(BLUE)Creating emergency backup...$(NC)"
	@./backup.sh run emergency

list-backups: ## List available backups with sizes
	$(call require-root)
	@echo "$(BLUE)Available backups:$(NC)"
	@./backup.sh list

backup-status: ## Show backup health summary
	$(call require-root)
	@./backup.sh list

restore: ## Interactive restore (guided)
	$(call require-root)
	@echo "$(BLUE)Starting interactive restore...$(NC)"
	@./restore.sh interactive $(if $(BACKUP_FILE),--file $(BACKUP_FILE),)

restore-preflight: ## Preview restore prerequisites without executing
	$(call require-root)
	@echo "$(BLUE)Running restore preflight (dry-run)...$(NC)"
	@./restore.sh interactive --dry-run $(if $(BACKUP_FILE),--file $(BACKUP_FILE),)

restore-db: ## Restore database only from latest backup
	$(call require-root)
	@echo "$(BLUE)Restoring database from latest backup...$(NC)"
	@./restore.sh latest db

restore-remote: ## Restore from remote storage (rclone)
	$(call require-root)
	@echo "$(BLUE)Restoring from remote storage...$(NC)"
	@./restore.sh interactive --remote

# ===========================================================================
##@ Key Management
# ===========================================================================

key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Health Check:$(NC)"
	@echo ""
	@CONFIGURED_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	CONFIGURED_KEY=$${CONFIGURED_KEY:-secrets/keys/age-key.txt}; \
	echo "$(CYAN)  Configured key path (SOPS_AGE_KEY_FILE): $$CONFIGURED_KEY$(NC)"; \
	echo "$(CYAN)  Canonical production path:                /etc/vaultwarden/age-key.txt$(NC)"
	@CONFIGURED_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	CONFIGURED_KEY=$${CONFIGURED_KEY:-secrets/keys/age-key.txt}; \
	bash -c "source lib/common.sh; init_common_lib startup.sh; \
	         source lib/crypto.sh; \
	         if check_age_key_health \"$$CONFIGURED_KEY\"; then \
	           echo \"$(GREEN)  ✓ Age key is healthy$(NC)\"; \
	         else \
	           echo \"$(RED)  ✗ Age key health check FAILED$(NC)\"; \
	           echo \"\"; \
	           echo \"$(YELLOW)  Remediation:$(NC)\"; \
	           echo \"$(YELLOW)       sudo make key-install$(NC)\"; \
	           echo \"$(YELLOW)       make key-health$(NC)\"; \
	           echo \"\"; \
	           echo \"$(YELLOW)  Or install manually:$(NC)\"; \
	           echo \"$(YELLOW)       sudo install -d -m 700 /etc/vaultwarden$(NC)\"; \
	           echo \"$(YELLOW)       sudo install -m 600 secrets/keys/age-key.txt /etc/vaultwarden/age-key.txt$(NC)\"; \
	           echo \"$(YELLOW)       sudo chown root:root /etc/vaultwarden /etc/vaultwarden/age-key.txt$(NC)\"; \
	           echo \"$(YELLOW)       # Set SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in .env$(NC)\"; \
	           echo \"$(YELLOW)       make key-health$(NC)\"; \
	           exit 1; \
	         fi"

# ---------------------------------------------------------------------------
# key-install: install the Age private key from secrets/keys/age-key.txt to
# the path configured in SOPS_AGE_KEY_FILE (default: /etc/vaultwarden/age-key.txt).
#
# This is the fast-path fix for the most common startup failure:
#   "Age key missing: /etc/vaultwarden/age-key.txt"
#
# When to use:
#   SOPS_AGE_KEY_FILE in .env points to /etc/vaultwarden/age-key.txt (or any
#   system path) but the file does not yet exist there, while the key is
#   already present at secrets/keys/age-key.txt (placed by setup.sh secrets
#   or the initial age-keygen run).
#
# What it does:
#   1. Reads SOPS_AGE_KEY_FILE from .env.
#   2. Self-referential path check (CONFIGURED == REPO_KEY):
#      - File exists  → informational message, exit 0 (no install needed).
#      - File missing → actionable error directing to ./setup.sh secrets, exit 1.
#   3. If target already exists and is non-empty, exits without changes.
#   4. Creates the parent directory (mode 700, root:root).
#   5. Copies secrets/keys/age-key.txt → SOPS_AGE_KEY_FILE (mode 600, root:root).
#   6. Runs make key-health to confirm the install succeeded.
#
# Important:
#   - Requires sudo (modifies /etc or another system path).
#   - Does NOT generate a new key — it only installs an existing one.
#   - If secrets/keys/age-key.txt is also missing, run: sudo make setup
# ---------------------------------------------------------------------------
key-install: ## Install Age key from secrets/keys/ to the path in SOPS_AGE_KEY_FILE
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Installing Age key...$(NC)"
	@CONFIGURED_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	CONFIGURED_KEY=$${CONFIGURED_KEY:-/etc/vaultwarden/age-key.txt}; \
	REPO_KEY="secrets/keys/age-key.txt"; \
	echo "  Target path  : $$CONFIGURED_KEY"; \
	echo "  Source key   : $$REPO_KEY"; \
	echo ""; \
	if [ "$$CONFIGURED_KEY" = "$$REPO_KEY" ]; then \
		echo "$(CYAN)  Note: SOPS_AGE_KEY_FILE points at the repo-local key (Stage 1 / dev path).$(NC)"; \
		echo "$(CYAN)        Installation to a system path is not needed at this lifecycle stage.$(NC)"; \
		echo "$(CYAN)        The key is used in-place from: $$REPO_KEY$(NC)"; \
		echo ""; \
		if [ -s "$$CONFIGURED_KEY" ]; then \
			echo "$(GREEN)  ✓ Key file exists and is non-empty at $$CONFIGURED_KEY$(NC)"; \
			echo "$(GREEN)    Run 'make key-health' to verify decryption integrity.$(NC)"; \
			exit 0; \
		else \
			echo "$(RED)  ✗ Key file NOT FOUND at $$CONFIGURED_KEY$(NC)"; \
			echo "$(RED)    Secrets have not been initialised on this host yet.$(NC)"; \
			echo "$(RED)    Run: ./setup.sh secrets  (or: make init-secrets)$(NC)"; \
			exit 1; \
		fi; \
	fi; \
	if [ -s "$$CONFIGURED_KEY" ]; then \
		echo "$(GREEN)  ✓ Key already present at $$CONFIGURED_KEY — no action needed.$(NC)"; \
		echo "$(GREEN)    Run 'make key-health' to verify integrity.$(NC)"; \
		exit 0; \
	fi; \
	if [ ! -f "$$REPO_KEY" ]; then \
		echo "$(RED)ERROR: Source key not found at $$REPO_KEY$(NC)"; \
		echo "$(RED)       No key to install. Run: sudo make setup to generate one.$(NC)"; \
		exit 1; \
	fi; \
	TARGET_DIR=$$(dirname "$$CONFIGURED_KEY"); \
	echo "$(BLUE)  Creating parent directory: $$TARGET_DIR$(NC)"; \
	install -d -m 700 "$$TARGET_DIR"; \
	chown root:root "$$TARGET_DIR"; \
	echo "$(BLUE)  Copying key to: $$CONFIGURED_KEY$(NC)"; \
	install -m 600 "$$REPO_KEY" "$$CONFIGURED_KEY"; \
	chown root:root "$$CONFIGURED_KEY"; \
	echo "$(GREEN)  ✓ Key installed at $$CONFIGURED_KEY (mode 600, root:root)$(NC)"; \
	echo ""
	@echo "$(BLUE)Verifying installation with key-health...$(NC)"
	@$(MAKE) key-health

key-show: ## Show current age public key and key file path/status
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Status:$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	echo "  Key file : $$KEY_FILE"; \
	if [ -f "$$KEY_FILE" ]; then \
		echo "  Status   : $(GREEN)present$(NC)"; \
		echo "  Perms    : $$(stat -c '%a' "$$KEY_FILE" 2>/dev/null || stat -f '%A' "$$KEY_FILE" 2>/dev/null)"; \
		PUB=$$(grep '# public key:' "$$KEY_FILE" 2>/dev/null | awk '{print $$NF}'); \
		[ -n "$$PUB" ] && echo "  Public   : $$PUB" || echo "  Public   : $(YELLOW)(not found in key file)$(NC)"; \
	else \
		echo "  Status   : $(RED)MISSING$(NC)"; \
		echo "  Run: sudo make key-install  (or: sudo make setup)"; \
	fi

key-backup: ## Backup age key to a secure offline location (interactive)
	$(call require-root)
	@echo "$(BLUE)Age Key Backup$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	if [ ! -f "$$KEY_FILE" ]; then \
		echo "$(RED)ERROR: Key file not found at $$KEY_FILE$(NC)"; \
		exit 1; \
	fi; \
	BACKUP_DEST="$$HOME/age-key-backup-$$(date +%Y%m%d-%H%M%S).txt"; \
	cp "$$KEY_FILE" "$$BACKUP_DEST"; \
	chmod 600 "$$BACKUP_DEST"; \
	echo "$(GREEN)Key backed up to: $$BACKUP_DEST$(NC)"; \
	echo "$(YELLOW)Store this file securely offline!$(NC)"

key-escrow: ## Generate encrypted escrow package (requires GPG or another age key)
	$(call require-root)
	@echo "$(BLUE)Age Key Escrow$(NC)"
	@bash -c "source lib/common.sh; init_common_lib startup.sh; \
	          source lib/crypto.sh; \
	          KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	          KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	          create_key_escrow \"$$KEY_FILE\""

key-rotate: ## Rotate age encryption key (re-encrypts all secrets)
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Rotation$(NC)"
	@echo "$(YELLOW)WARNING: This will generate a new age key and re-encrypt all secrets.$(NC)"
	@echo "$(YELLOW)Ensure you have a backup of the current key before proceeding.$(NC)"
	@echo ""
	@echo "$(BLUE)Running key health pre-flight check...$(NC)"
	@$(MAKE) key-health || { \
		echo "$(RED)Key health check failed. Aborting rotation to prevent data loss.$(NC)"; \
		echo "$(RED)Fix the key issue first: sudo make key-install$(NC)"; \
		exit 1; \
	}
	@echo ""
	@read -p "Continue with key rotation? [y/N] " confirm; \
	if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
		echo "$(YELLOW)Key rotation cancelled.$(NC)"; \
		exit 0; \
	fi
	@bash -c "source lib/common.sh; init_common_lib startup.sh; \
	          source lib/secrets.sh; \
	          rotate_age_key"

# ===========================================================================
##@ Updates
# ===========================================================================

update: ## Update all container images and restart
	$(call require-root)
	@echo "$(BLUE)Updating VaultWarden-OCI...$(NC)"
	@./maintenance.sh update

check-updates: ## Check for available container image updates (no restart)
	$(call check-docker)
	@echo "$(BLUE)Checking for container updates...$(NC)"
	@$(DOCKER_COMP) pull --dry-run 2>/dev/null || $(DOCKER_COMP) pull

update-system: ## Update host OS packages
	$(call require-root)
	@echo "$(BLUE)Updating system packages...$(NC)"
	@if command -v apt-get >/dev/null 2>&1; then \
		apt-get update && apt-get upgrade -y; \
	elif command -v yum >/dev/null 2>&1; then \
		yum update -y; \
	elif command -v dnf >/dev/null 2>&1; then \
		dnf update -y; \
	fi

update-dns: ## Update Cloudflare DNS records
	$(call check-env-readable)
	@echo "$(BLUE)Updating DNS records...$(NC)"
	@./maintenance.sh update-dns

# ===========================================================================
##@ Maintenance
# ===========================================================================

maintenance: ## Run routine maintenance tasks
	$(call require-root)
	@echo "$(BLUE)Running maintenance...$(NC)"
	@./maintenance.sh run

maintenance-full: ## Run full maintenance with all checks
	$(call require-root)
	@echo "$(BLUE)Running full maintenance...$(NC)"
	@./maintenance.sh run --comprehensive

db-maint: ## Run database maintenance (VACUUM, integrity check)
	$(call require-root)
	@echo "$(BLUE)Running database maintenance...$(NC)"
	@./maintenance.sh db-maint

db-backup: ## Quick database backup
	$(call require-root)
	@echo "$(BLUE)Running quick database backup...$(NC)"
	@./backup.sh run db

# ===========================================================================
##@ Systemd Integration
# ===========================================================================

install-systemd: ## Install systemd service units and timers
	$(call require-root)
	@echo "$(BLUE)Installing systemd units...$(NC)"
	@./setup.sh systemd install

remove-systemd: ## Remove systemd service units
	$(call require-root)
	@echo "$(BLUE)Removing systemd units...$(NC)"
	@./setup.sh systemd remove

systemd-status: ## Show systemd unit status
	@echo "$(BLUE)Systemd Unit Status:$(NC)"
	@for unit in \
		vaultwarden-db-backup.timer \
		vaultwarden-full-backup.timer \
		vaultwarden-health.timer \
		vaultwarden-maintenance.timer \
		vaultwarden-dns-update.timer \
		vaultwarden-firewall-update.timer \
		vaultwarden-iptables.service \
		vaultwarden-notify-failure.service; do \
		systemctl status "$$unit" --no-pager -l 2>/dev/null \
			|| echo "  $$unit: not found"; \
		echo ""; \
	done

systemd-validate: ## Validate systemd unit files
	$(call require-root)
	@echo "$(BLUE)Validating systemd units...$(NC)"
	@./setup.sh systemd validate

timers: ## Show scheduled systemd timer status
	@echo "$(BLUE)Scheduled Timers:$(NC)"
	@systemctl list-timers --all 2>/dev/null | grep -E "vaultwarden|ACTIVATES" || echo "  No vaultwarden timers found"

# ===========================================================================
##@ Break-Glass Admin
# ===========================================================================

breakglass-create: ## Create emergency break-glass admin account
	$(call require-root)
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	@./create-breakglass-admin.sh create

breakglass-status: ## Check break-glass admin account status
	$(call require-root)
	@echo "$(BLUE)Break-glass admin status:$(NC)"
	@./create-breakglass-admin.sh status

breakglass-remove: ## Remove break-glass admin account
	$(call require-root)
	@echo "$(BLUE)Removing break-glass admin account...$(NC)"
	@./create-breakglass-admin.sh remove --force

# ===========================================================================
##@ Testing & Development
# ===========================================================================

test: ## Run all tests (secrets, config validation)
	@echo "$(BLUE)Running test suite...$(NC)"
	@$(MAKE) test-secrets
	@$(MAKE) test-config
	@echo "$(GREEN)All tests passed.$(NC)"

test-config: ## Validate docker-compose configuration
	$(call check-docker)
	@echo "$(BLUE)Validating docker-compose configuration...$(NC)"
	@$(DOCKER_COMP) config --quiet && echo "$(GREEN)Configuration is valid.$(NC)"

dry-run: ## Show what startup would do without executing
	@echo "$(BLUE)Startup dry run...$(NC)"
	@./startup.sh --dry-run

fmt: ## Format Makefile (check only — no auto-format tool available)
	@echo "$(YELLOW)Note: No auto-formatter for Makefiles. Use consistent tab indentation.$(NC)"

lint: ## Run shellcheck on all shell scripts
	@echo "$(BLUE)Running shellcheck...$(NC)"
	@if command -v shellcheck >/dev/null 2>&1; then \
		find . -name "*.sh" -not -path "./.git/*" -exec shellcheck {} \; && \
		echo "$(GREEN)All scripts passed shellcheck.$(NC)"; \
	else \
		echo "$(YELLOW)shellcheck not installed. Install with: sudo apt-get install shellcheck$(NC)"; \
	fi

shellcheck: lint ## Alias for lint

# ===========================================================================
##@ Information & Diagnostics
# ===========================================================================

info: ## Show deployment information
	$(call check-env-readable)
	@echo "$(BLUE)VaultWarden-OCI Deployment Info:$(NC)"
	@echo ""
	@if [ -f ".env" ]; then \
		echo "  Domain    : $$(grep '^DOMAIN=' .env 2>/dev/null | cut -d= -f2)"; \
		echo "  Admin     : $$(grep '^ADMIN_EMAIL=' .env 2>/dev/null | cut -d= -f2)"; \
		echo "  State Dir : $$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2-)"; \
		DATA_DEV=$$(grep '^DATA_VOLUME_DEVICE=' .env 2>/dev/null | cut -d= -f2-); \
		DATA_MNT=$$(grep '^DATA_VOLUME_MOUNT=' .env 2>/dev/null | cut -d= -f2-); \
		if [ -n "$$DATA_DEV" ]; then \
			MOUNTED=$$(mountpoint -q "$$DATA_MNT" 2>/dev/null && echo "$(GREEN)mounted$(NC)" || echo "$(RED)NOT MOUNTED$(NC)"); \
			echo "  Volume    : $$DATA_DEV → $$DATA_MNT  [$$MOUNTED]"; \
		else \
			echo "  Volume    : boot-only mode"; \
		fi; \
	fi
	@echo "  Version   : $$(cat VERSION 2>/dev/null || echo 'unknown')"
	@echo "  Uptime    : $$(docker inspect --format='{{.State.StartedAt}}' vaultwarden_app 2>/dev/null || echo 'not running')"

version: ## Show current VaultWarden-OCI version
	@cat VERSION 2>/dev/null || echo "VERSION file not found"

shell: ## Open a shell in the vaultwarden container
	$(call check-docker)
	@echo "$(BLUE)Opening shell in vaultwarden container...$(NC)"
	@$(DOCKER_COMP) exec vaultwarden /bin/sh

config: ## Show current docker-compose config (resolved)
	$(call check-docker)
	@$(DOCKER_COMP) config

diagnose: ## Full diagnostic dump (versions, status, health, key, logs tail)
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(BLUE)VaultWarden-OCI Diagnostic Report$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(CYAN)Date:$(NC) $$(date)"
	@echo "$(CYAN)Hostname:$(NC) $$(hostname)"
	@echo "$(CYAN)OS:$(NC) $$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || uname -s)"
	@echo ""
	@echo "$(CYAN)--- Tool Versions ---$(NC)"
	@docker --version 2>/dev/null || echo "docker: not found"
	@docker compose version 2>/dev/null || echo "docker compose: not found"
	@sops --version 2>/dev/null || echo "sops: not found"
	@age --version 2>/dev/null || echo "age: not found"
	@echo ""
	@echo "$(CYAN)--- Container Status ---$(NC)"
	@$(DOCKER_COMP) ps 2>/dev/null || echo "docker compose: not available"
	@echo ""
	@echo "$(CYAN)--- Storage ---$(NC)"
	@STATE_DIR=$$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2-); \
	STATE_DIR=$${STATE_DIR:-/var/lib/vaultwarden}; \
	DATA_DEV=$$(grep '^DATA_VOLUME_DEVICE=' .env 2>/dev/null | cut -d= -f2-); \
	DATA_MNT=$$(grep '^DATA_VOLUME_MOUNT=' .env 2>/dev/null | cut -d= -f2-); \
	if [ -n "$$DATA_DEV" ]; then \
		echo "  Mode      : separate-volume ($$DATA_DEV → $$DATA_MNT)"; \
		mountpoint -q "$$DATA_MNT" 2>/dev/null \
			&& echo "  Mount     : $(GREEN)active$(NC)" \
			|| echo "  Mount     : $(RED)NOT MOUNTED$(NC)"; \
	else \
		echo "  Mode      : boot-only"; \
	fi; \
	df -h "$$STATE_DIR" 2>/dev/null || true
	@echo ""
	@echo "$(CYAN)--- Key Health ---$(NC)"
	@$(MAKE) key-health 2>/dev/null || echo "key-health: failed"
	@echo ""
	@echo "$(CYAN)--- Recent Logs (last 20 lines each) ---$(NC)"
	@$(DOCKER_COMP) logs --tail=20 2>/dev/null || true

# ===========================================================================
##@ Cleanup
# ===========================================================================

clean: ## Remove generated files (logs, temp files)
	@echo "$(BLUE)Cleaning generated files...$(NC)"
	@rm -f setup.log
	@echo "$(GREEN)Clean complete.$(NC)"

clean-all: ## Remove all generated files including secrets cache
	@echo "$(YELLOW)WARNING: This will remove secrets cache. Re-run make up to regenerate.$(NC)"
	@read -p "Continue? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -f setup.log; \
		rm -rf secrets/.docker_secrets; \
		echo "$(GREEN)Full clean complete.$(NC)"; \
	else \
		echo "Cancelled."; \
	fi

prune: ## Remove unused Docker resources (containers, networks, images)
	$(call check-docker)
	@echo "$(BLUE)Pruning unused Docker resources...$(NC)"
	@docker system prune -f
	@echo "$(GREEN)Prune complete.$(NC)"

# ===========================================================================
##@ Uninstall
# ===========================================================================

uninstall: ## Uninstall VaultWarden-OCI (interactive)
	$(call require-root)
	@echo "$(RED)WARNING: This will remove VaultWarden-OCI from this system.$(NC)"
	@./uninstall-vaultwarden.sh run

uninstall-dry-run: ## Show uninstall help (no dry-run mode available)
	@./uninstall-vaultwarden.sh --help
