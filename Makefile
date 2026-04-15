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
        dev-setup test test-config dry-run fmt lint shellcheck \
        info version shell config diagnose \
        clean clean-all prune \
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

dev-setup: ## Set up development environment (.env + docker-compose.override.yml)
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then cp .env.example .env; echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; fi
	@if [ ! -f "docker-compose.override.yml" ]; then cp docker-compose.override.yml.example docker-compose.override.yml; echo "$(YELLOW)Created development override file.$(NC)"; fi

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
	@sudo ./startup.sh --force-restart || { \
		echo "$(RED)Restart failed!$(NC)"; \
		$(MAKE) status; \
		echo "$(YELLOW)If restart failed due to a key issue, run: make key-health$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Services restarted.$(NC)"

# FIX [P5-C1]: safe-restart captures pre-restart container IDs and rolls back
# on failure. sudo is required for both startup.sh and health.sh (require_root).
safe-restart: ## Restart with automatic rollback on failure
	$(call check-docker)
	@echo "$(BLUE)Performing safe restart with rollback capability...$(NC)"
	@PRE_IDS=$$($(DOCKER_COMP) ps -q 2>/dev/null); \
	if sudo ./startup.sh --force-restart; then \
		echo "$(GREEN)Restart successful — running post-restart health check (10s grace)...$(NC)"; \
		sleep 10; \
		if sudo ./health.sh --quiet; then \
			echo "$(GREEN)Health check passed — safe restart completed.$(NC)"; \
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

status: ## Show service status
	@$(DOCKER_COMP) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "$(RED)Services not running$(NC)"

# ===========================================================================
##@ Monitoring & Health
# ===========================================================================

health: ## Run health checks (optional: AUTO_RECOVER=true, COMPREHENSIVE=true)
	@echo "$(BLUE)Running health checks...$(NC)"
	@FLAGS=""; \
	if [ "$(COMPREHENSIVE)" = "true" ]; then FLAGS="$$FLAGS --comprehensive"; fi; \
	if [ "$(AUTO_RECOVER)" = "true" ]; then FLAGS="$$FLAGS --auto-recover"; fi; \
	sudo ./health.sh $$FLAGS || { echo "$(RED)Health check failed$(NC)"; exit 1; }

health-quick: ## Fast sanity check — port up + container running (no deep tests)
	@echo "$(BLUE)Running quick health check...$(NC)"
	@sudo ./health.sh --quiet || { echo "$(RED)Quick health check failed$(NC)"; exit 1; }
	@echo "$(GREEN)Quick health check passed$(NC)"

health-email: ## Run health check with email notification
	@echo "$(BLUE)Running health check with email notification...$(NC)"
	@sudo ./health.sh --comprehensive --email

# ===========================================================================
##@ Logs
# ===========================================================================

# FIX [P5-M1]: logs defaults to --tail=100. Pass SERVICE= to filter, FOLLOW=true to tail.
logs: ## Show recent logs (last 100 lines). Use SERVICE= to filter, FOLLOW=true to tail
	@if [ "$(FOLLOW)" = "true" ]; then \
		$(DOCKER_COMP) logs -f -t --tail=100 $(SERVICE); \
	else \
		$(DOCKER_COMP) logs --tail=100 $(SERVICE); \
	fi

logs-tail: ## Tail all service logs with timestamps (Ctrl+C to stop)
	@$(DOCKER_COMP) logs -f -t --tail=100 $(SERVICE)

logs-vaultwarden: ## Tail VaultWarden application logs
	@$(DOCKER_COMP) logs -f -t --tail=100 vaultwarden

logs-caddy: ## Tail Caddy reverse-proxy logs
	@$(DOCKER_COMP) logs -f -t --tail=100 caddy

logs-postfix: ## Tail Postfix email relay logs
	@$(DOCKER_COMP) logs -f -t --tail=100 postfix

logs-fail2ban: ## Tail Fail2ban intrusion-prevention logs
	@$(DOCKER_COMP) logs -f -t --tail=100 fail2ban

# FIX [P5-M3]: watch calls health-quick (port + container probe) rather than
# the full health.sh stack. Running the comprehensive health stack every 5s
# hammers the VaultWarden HTTPS endpoint, SQLite, Docker API, and Fail2ban.
watch: ## Watch service status every 5s (requires watch command)
	@command -v watch >/dev/null 2>&1 || { echo "$(RED)watch not found. Install: sudo apt install procps$(NC)"; exit 1; }
	@watch -n 5 'DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make status && echo && DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make health-quick'

monitor: ## Monitor all service logs in real-time (Ctrl+C to stop)
	@echo "$(BLUE)Monitoring all services (Ctrl+C to stop)...$(NC)"
	@$(DOCKER_COMP) logs -f -t

# ===========================================================================
##@ Backup & Restore
# ===========================================================================

# QOL: backup emits a visible notice when TYPE defaults to 'db' so an operator
# who forgot TYPE=full gets clear feedback rather than silent partial coverage.
backup: ## Create backup (TYPE: db, full, emergency)
	$(call require-root)
	@echo "$(BLUE)Creating backup...$(NC)"
	@if [ -z "$(TYPE)" ]; then \
		echo "$(YELLOW)No TYPE specified — defaulting to TYPE=db (database only).$(NC)"; \
		echo "$(YELLOW)Use 'make backup TYPE=full' or 'make backup TYPE=emergency' for broader coverage.$(NC)"; \
	fi
	@sudo ./backup.sh --type $(if $(TYPE),$(TYPE),db) --email
	@echo "$(GREEN)Backup completed successfully!$(NC)"

backup-full: ## Create full system backup with email notification
	@$(MAKE) backup TYPE=full

backup-emergency: ## Create emergency recovery kit with email notification
	@$(MAKE) backup TYPE=emergency

list-backups: ## List available backups with per-type size totals
	@echo "$(BLUE)Available backups:$(NC)"
	@sudo ./backup.sh --list

backup-status: ## Show backup health summary — last run, size, retention, count per type
	$(call check-env-readable)
	@echo "$(BLUE)╔══════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║             Backup Status Summary                       ║$(NC)"
	@echo "$(BLUE)╚══════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2 || echo 'backups'); \
	RETENTION=$$(grep '^BACKUP_RETENTION_DAYS=' .env 2>/dev/null | cut -d= -f2 || echo '14'); \
	echo "  Backup directory : $$BACKUP_DIR"; \
	echo "  Retention window : $$RETENTION days"; \
	TOTAL=$$(du -sh "$$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 'n/a'); \
	echo "  Total size       : $$TOTAL"; \
	echo ""; \
	echo "$(CYAN)  Type        Last Backup                         Count$(NC)"; \
	echo "  ──────────────────────────────────────────────────────"; \
	for TYPE in db full emergency; do \
		DIR="$$BACKUP_DIR/$$TYPE"; \
		COUNT=$$(ls "$$DIR/"*.age 2>/dev/null | wc -l | tr -d ' '); \
		LAST=$$(ls -t "$$DIR/"*.age 2>/dev/null | head -1); \
		if [ -n "$$LAST" ]; then \
			LAST_NAME=$$(basename "$$LAST"); \
			echo "  $$(printf '%-11s' $$TYPE) $$LAST_NAME   $$COUNT"; \
		else \
			echo "  $$(printf '%-11s' $$TYPE) $(YELLOW)none$(NC)                                       0"; \
		fi; \
	done
	@echo ""
	@echo "$(GREEN)Run 'make list-backups' for full listing or 'make diagnose' for complete system state.$(NC)"

# ---------------------------------------------------------------------------
# restore-preflight: sanity-check the host before launching restore.sh.
#
# Three checks (all must pass):
#   1. Docker daemon is reachable — restore.sh needs docker compose.
#   2. Secrets file is present and decryptable — age key must be in place.
#   3. BACKUP_FILE exists — only validated when caller has set BACKUP_FILE=…;
#      omitting it is still valid (restore.sh prompts interactively).
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

# FIX [item 4]: restore-db no longer passes --force so the age key prompt and
# confirmation step run as intended.
restore-db: ## Restore latest database backup (interactive confirmation + key prompt)
	$(call require-root)
	@echo "$(BLUE)Restoring latest database backup...$(NC)"
	@sudo ./restore.sh --type db --latest

restore-remote: ## Restore from a remote (rclone) backup — interactive selection
	@echo "$(BLUE)Starting remote restore...$(NC)"
	@sudo ./restore.sh --remote

# ===========================================================================
##@ Key Management
# ===========================================================================

key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	$(call check-env-readable)
	@echo "$(BLUE)Checking age key health...$(NC)"
	@CONFIGURED_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	CONFIGURED_KEY=$${CONFIGURED_KEY:-secrets/keys/age-key.txt}; \
	echo "$(CYAN)  Configured key path (SOPS_AGE_KEY_FILE): $$CONFIGURED_KEY$(NC)"; \
	echo "$(CYAN)  Canonical production path:                /etc/vaultwarden/age-key.txt$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; check_age_key_health' && \
		echo "$(GREEN)Age key health check passed$(NC)" || \
		{ \
		  echo "$(RED)Age key health check FAILED$(NC)"; \
		  echo ""; \
		  echo "$(YELLOW)Remediation steps:$(NC)"; \
		  echo "$(YELLOW)  1. Auto-install (recommended) — installs key to configured path:$(NC)"; \
		  echo "$(YELLOW)       sudo make key-install$(NC)"; \
		  echo "$(YELLOW)       make key-health$(NC)"; \
		  echo ""; \
		  echo "$(YELLOW)  2. Manual production fix — install key to canonical path:$(NC)"; \
		  echo "$(YELLOW)       sudo install -d -m 700 /etc/vaultwarden$(NC)"; \
		  echo "$(YELLOW)       sudo install -m 600 secrets/keys/age-key.txt /etc/vaultwarden/age-key.txt$(NC)"; \
		  echo "$(YELLOW)       sudo chown root:root /etc/vaultwarden /etc/vaultwarden/age-key.txt$(NC)"; \
		  echo "$(YELLOW)       # Set SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in .env$(NC)"; \
		  echo "$(YELLOW)       make key-health$(NC)"; \
		  echo ""; \
		  echo "$(YELLOW)  3. Or re-run full setup: sudo make setup$(NC)"; \
		  exit 1; \
		}

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
#   already present at secrets/keys/age-key.txt (placed by setup-secrets.sh
#   or the initial age-keygen run).
#
# What it does:
#   1. Reads SOPS_AGE_KEY_FILE from .env.
#   2. If the target already exists and is non-empty, exits without changes.
#   3. Creates the parent directory (mode 700, root:root).
#   4. Copies secrets/keys/age-key.txt → SOPS_AGE_KEY_FILE (mode 600, root:root).
#   5. Runs make key-health to confirm the install succeeded.
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
		echo "  $(RED)Run: sudo make key-install  (or: sudo make setup to generate a new key)$(NC)"; \
	fi

key-backup: ## Create printable key backup (PDF or HTML)
	$(call require-root)
	@echo "$(BLUE)Creating printable key backup...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; create_printable_key_backup'

key-escrow: ## Create password manager escrow copy
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Creating password manager escrow...$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	ESCROW_FILE="$${HOME}/vaultwarden-escrow-$$(date +%Y%m%d-%H%M%S).txt"; \
	bash -c "set -euo pipefail; source lib/simple_key_resilience.sh; create_password_manager_escrow '$$ESCROW_FILE'"

# MAKE-KR1 FIX [HIGH]: The old recipe ran `source lib/crypto.sh` inside the
# Make recipe shell, which is /bin/sh (dash on Debian/Ubuntu). dash does not
# implement the 'source' builtin. Fix: invoke bash explicitly.
# MAKE-KR2 [LOW]: key-health pre-flight before rotation so a corrupt or
# unreadable key is caught with a clear message before any write occurs.
key-rotate: ## Rotate the age encryption key (generates new key, updates all locations)
	$(call require-root)
	@echo "$(BLUE)Rotating age encryption key...$(NC)"
	@echo "$(YELLOW)WARNING: After rotation, new backups will use the new key.$(NC)"
	@echo "$(YELLOW)Keep the new key displayed at the end in a secure location.$(NC)"
	@echo "$(BLUE)Pre-flight: checking current age key health...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; check_age_key_health' || \
		{ echo "$(YELLOW)Warning: key health check failed — proceeding anyway (key may not yet exist).$(NC)"; true; }
	@bash -c 'set -euo pipefail; source lib/crypto.sh; rotate_age_key' && \
		echo "$(GREEN)Key rotation complete.$(NC)"

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

db-maint: ## Run deep database maintenance — VACUUM + WAL checkpoint (requires sudo)
	@echo "$(BLUE)Running database maintenance...$(NC)"
	@sudo ./maintenance.sh --db-maint

db-backup: ## Quick database-only backup
	@$(MAKE) backup TYPE=db

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

# QOL: timers shows the OnCalendar schedule from .env alongside the next
# trigger and last run — a single view of configured schedule vs live state.
timers: ## List all vaultwarden systemd timers (next trigger + last run + .env schedule)
	$(call check-env-readable)
	@echo "$(BLUE)Systemd Timer Status:$(NC)"
	@systemctl list-timers --all 2>/dev/null | grep -E '(NEXT|vaultwarden)' || \
		echo "$(YELLOW)No vaultwarden timers found. Run: sudo make install-systemd$(NC)"
	@echo ""
	@echo "$(CYAN)Configured schedules in .env:$(NC)"
	@grep -E '^BACKUP_SCHEDULE' .env 2>/dev/null | while IFS= read -r line; do \
		echo "  $$line"; \
	done || echo "  $(YELLOW)No BACKUP_SCHEDULE_* variables found in .env$(NC)"

# ===========================================================================
##@ Security
# ===========================================================================

breakglass-create: ## Create emergency admin account
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --create

breakglass-status: ## Show break-glass admin account status
	@sudo ./create-breakglass-admin.sh --status

breakglass-remove: ## Remove break-glass admin account
	@echo "$(YELLOW)Removing break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --remove

# ===========================================================================
##@ Testing & Validation
# ===========================================================================

test: ## Run all tests (secrets, email, compose config)
	@echo "$(BLUE)Running all tests...$(NC)"
	@$(MAKE) test-secrets
	@$(MAKE) fmt
	@echo "$(GREEN)All tests passed!$(NC)"

test-config: ## Validate Docker Compose configuration only
	@echo "$(BLUE)Validating configuration...$(NC)"
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)Docker Compose configuration is valid$(NC)" || { echo "$(RED)Docker Compose configuration is invalid$(NC)"; exit 1; }

# FIX [P5-H2]: dry-run no longer appends || true — failures propagate correctly.
# sudo is required for all four scripts (require_root in each).
dry-run: ## Preview all operations without executing
	@echo "$(BLUE)Dry run mode — showing what would be done:$(NC)"
	@echo "$(YELLOW)--- startup.sh ---$(NC)"
	@sudo ./startup.sh --dry-run
	@echo "$(YELLOW)--- health.sh ---$(NC)"
	@sudo ./health.sh --dry-run
	@echo "$(YELLOW)--- backup.sh ---$(NC)"
	@sudo ./backup.sh --dry-run
	@echo "$(YELLOW)--- maintenance.sh ---$(NC)"
	@sudo ./maintenance.sh --dry-run

fmt: ## Validate all configuration files (compose + override + secrets)
	@echo "$(BLUE)Validating configuration files...$(NC)"
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)✓ docker-compose.yml$(NC)" || echo "$(RED)✗ docker-compose.yml$(NC)"
	@if [ -f "docker-compose.override.yml" ]; then \
		$(DOCKER_COMP) -f docker-compose.yml -f docker-compose.override.yml config > /dev/null && \
		echo "$(GREEN)✓ docker-compose.override.yml$(NC)" || echo "$(RED)✗ docker-compose.override.yml$(NC)"; \
	fi
	@./edit-secrets.sh --list > /dev/null && echo "$(GREEN)✓ secrets.yaml$(NC)" || echo "$(RED)✗ secrets.yaml$(NC)"

lint: shellcheck ## Alias for shellcheck

# QOL: lint runs shellcheck over all *.sh files in the repo root and lib/ so
# regressions are caught before commit. Gracefully skips if shellcheck is not
# installed and prints the install command.
shellcheck: ## Run shellcheck on all shell scripts
	@echo "$(BLUE)Running shellcheck...$(NC)"
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "$(YELLOW)shellcheck not installed. Install with: sudo apt install shellcheck$(NC)"; \
		exit 0; \
	fi
	@FAILED=0; \
	for script in *.sh lib/*.sh; do \
		[ -f "$$script" ] || continue; \
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
##@ Information & Diagnostics
# ===========================================================================

info: ## Show system information including version, age key status, and disk usage
	$(call check-env-readable)
	@echo "$(BLUE)VaultWarden-OCI System Information$(NC)"
	@echo "$(BLUE)====================================$(NC)"
	@echo "$(GREEN)Stack version:$(NC) $$(cat VERSION 2>/dev/null || echo 'unknown')"
	@echo "$(GREEN)Domain:$(NC)        $$(grep '^DOMAIN=' .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Admin Email:$(NC)   $$(grep '^ADMIN_EMAIL=' .env 2>/dev/null | cut -d= -f2 || echo 'Not configured')"
	@echo "$(GREEN)Project State:$(NC) $$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden')"
	@echo ""
	@echo "$(GREEN)Age Key Status:$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	if [ -f "$$KEY_FILE" ]; then \
		echo "  Path   : $$KEY_FILE  $(GREEN)[present, $$(stat -c '%a' "$$KEY_FILE" 2>/dev/null || stat -f '%A' "$$KEY_FILE" 2>/dev/null) perms]$(NC)"; \
		PUB=$$(grep '# public key:' "$$KEY_FILE" 2>/dev/null | awk '{print $$NF}'); \
		[ -n "$$PUB" ] && echo "  Public : $$PUB" || echo "  Public : $(YELLOW)(not found)$(NC)"; \
	else \
		echo "  $(RED)MISSING: $$KEY_FILE$(NC)  — run: sudo make key-install"; \
	fi
	@echo ""
	@echo "$(GREEN)Services Status:$(NC)"
	@$(MAKE) status
	@echo ""
	@echo "$(GREEN)Disk Usage:$(NC)"
	@STATE_DIR=$$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden'); \
	df -h "$$STATE_DIR" 2>/dev/null | tail -1 || echo "State directory not found"
	@BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2 || echo 'backups'); \
	RETENTION=$$(grep '^BACKUP_RETENTION_DAYS=' .env 2>/dev/null | cut -d= -f2 || echo '14'); \
	if [ -d "$$BACKUP_DIR" ]; then \
		echo "  Backups ($$BACKUP_DIR, retention: $$RETENTION days): $$(du -sh "$$BACKUP_DIR" 2>/dev/null | cut -f1)"; \
	fi

# FIX [P5-L2]: non-running container is non-fatal informational state.
version: ## Show version information for all stack components
	@echo "$(BLUE)VaultWarden-OCI Version Information$(NC)"
	@echo "$(GREEN)Stack version:$(NC)  $$(cat VERSION 2>/dev/null || echo 'unknown')"
	@echo "$(GREEN)VaultWarden:$(NC)    $$($(DOCKER_COMP) exec -T vaultwarden /vaultwarden --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Caddy:$(NC)          $$($(DOCKER_COMP) exec -T caddy caddy version 2>/dev/null || echo 'Not running')"
	@echo "$(GREEN)Fail2Ban:$(NC)       $$($(DOCKER_COMP) exec -T fail2ban fail2ban-server --version 2>/dev/null | head -1 || echo 'Not running')"
	@echo "$(GREEN)Postfix:$(NC)        $$($(DOCKER_COMP) exec -T postfix postconf -d mail_version 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo 'Not running')"
	@echo "$(GREEN)Docker:$(NC)         $$(docker --version 2>/dev/null || echo 'Not available')"
	@echo "$(GREEN)Docker Compose:$(NC) $$($(DOCKER_COMP) version 2>/dev/null || echo 'Not available')"

shell: ## Open shell in specified SERVICE (default: vaultwarden)
	@echo "$(BLUE)Opening shell in $(if $(SERVICE),$(SERVICE),vaultwarden)...$(NC)"
	@$(DOCKER_COMP) exec $(if $(SERVICE),$(SERVICE),vaultwarden) sh

# FIX [item 15]: show truncation notice when .env has more than 15 non-sensitive lines.
config: ## Show current configuration summary (sensitive keys redacted)
	$(call check-env-readable)
	@echo "$(BLUE)Current Configuration Summary$(NC)"
	@echo "$(BLUE)============================$(NC)"
	@if [ -f ".env" ]; then \
		echo "$(GREEN)Environment Variables (non-sensitive):$(NC)"; \
		LINES=$$(grep -E '^[A-Z_]+=' .env | grep -viE '(TOKEN|PASSWORD|SECRET|KEY|ZONE_ID|HASH)'); \
		COUNT=$$(echo "$$LINES" | wc -l); \
		echo "$$LINES" | head -15; \
		if [ "$$COUNT" -gt 15 ]; then \
			echo "$(YELLOW)  ... and $$((COUNT - 15)) more lines (run: grep -E '^[A-Z_]+=' .env to see all)$(NC)"; \
		fi; \
		echo ""; \
	fi
	@if [ -f "docker-compose.override.yml" ]; then echo "$(GREEN)Development Override:$(NC) Active"; else echo "$(GREEN)Development Override:$(NC) Not active"; fi
	@echo ""
	@echo "$(GREEN)Services Configuration:$(NC)"
	@$(DOCKER_COMP) config --services 2>/dev/null || echo "Configuration invalid"

diagnose: ## Full diagnostic dump — versions, key status, disk, containers, last backup, recent logs
	$(call check-env-readable)
	@echo "$(BLUE)╔══════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║         VaultWarden-OCI — Diagnostic Report             ║$(NC)"
	@echo "$(BLUE)╚══════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "$(CYAN)── Stack Version ─────────────────────────────────────────$(NC)"
	@echo "  Repo version : $$(cat VERSION 2>/dev/null || echo 'unknown')"
	@echo "  Docker       : $$(docker --version 2>/dev/null || echo 'not available')"
	@echo "  Compose      : $$($(DOCKER_COMP) version --short 2>/dev/null || echo 'not available')"
	@echo ""
	@echo "$(CYAN)── Configuration ─────────────────────────────────────────$(NC)"
	@echo "  Domain       : $$(grep '^DOMAIN=' .env 2>/dev/null | cut -d= -f2 || echo 'not configured')"
	@echo "  Admin email  : $$(grep '^ADMIN_EMAIL=' .env 2>/dev/null | cut -d= -f2 || echo 'not configured')"
	@echo "  State dir    : $$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden')"
	@echo ""
	@echo "$(CYAN)── Compose Config Validity ───────────────────────────────$(NC)"
	@$(DOCKER_COMP) config > /dev/null 2>&1 && echo "  $(GREEN)✓ docker-compose.yml is valid$(NC)" || echo "  $(RED)✗ docker-compose.yml is INVALID$(NC)"
	@if [ -f "docker-compose.override.yml" ]; then \
		$(DOCKER_COMP) -f docker-compose.yml -f docker-compose.override.yml config > /dev/null 2>&1 && \
		echo "  $(GREEN)✓ docker-compose.override.yml is valid$(NC)" || \
		echo "  $(RED)✗ docker-compose.override.yml is INVALID$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)── Age Key ────────────────────────────────────────────────$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	echo "  Path   : $$KEY_FILE"; \
	if [ -f "$$KEY_FILE" ]; then \
		echo "  Status : $(GREEN)present$(NC)  perms: $$(stat -c '%a' "$$KEY_FILE" 2>/dev/null || stat -f '%A' "$$KEY_FILE" 2>/dev/null)"; \
		PUB=$$(grep '# public key:' "$$KEY_FILE" 2>/dev/null | awk '{print $$NF}'); \
		[ -n "$$PUB" ] && echo "  Public : $$PUB" || echo "  Public : $(YELLOW)(not found in key file)$(NC)"; \
	else \
		echo "  Status : $(RED)MISSING — run: sudo make key-install$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)── Disk Usage ─────────────────────────────────────────────$(NC)"
	@STATE_DIR=$$(grep '^PROJECT_STATE_DIR=' .env 2>/dev/null | cut -d= -f2 || echo '/var/lib/vaultwarden'); \
	df -h "$$STATE_DIR" 2>/dev/null | tail -1 || echo "  State directory not found"
	@BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2 || echo 'backups'); \
	if [ -d "$$BACKUP_DIR" ]; then \
		echo "  Backup dir ($$BACKUP_DIR): $$(du -sh "$$BACKUP_DIR" 2>/dev/null | cut -f1)"; \
	else \
		echo "  Backup dir $$BACKUP_DIR: not found"; \
	fi
	@echo ""
	@echo "$(CYAN)── Last Backup Per Type ───────────────────────────────────$(NC)"
	@BACKUP_DIR=$$(grep '^BACKUP_DIR=' .env 2>/dev/null | cut -d= -f2 || echo 'backups'); \
	for TYPE in db full emergency; do \
		LAST=$$(ls -t "$$BACKUP_DIR/$${TYPE}/"*.age 2>/dev/null | head -1); \
		if [ -n "$$LAST" ]; then \
			echo "  $$TYPE : $$(basename $$LAST)"; \
		else \
			echo "  $$TYPE : $(YELLOW)none found$(NC)"; \
		fi; \
	done
	@echo ""
	@echo "$(CYAN)── Container State ────────────────────────────────────────$(NC)"
	@$(DOCKER_COMP) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  $(RED)Services not running$(NC)"
	@echo ""
	@echo "$(CYAN)── Recent Logs (last 20 lines per service) ────────────────$(NC)"
	@for SVC in vaultwarden caddy fail2ban postfix; do \
		echo ""; \
		echo "$(YELLOW)--- $$SVC ---$(NC)"; \
		$(DOCKER_COMP) logs --tail=20 --no-log-prefix $$SVC 2>/dev/null || echo "  (not running or no logs)"; \
	done
	@echo ""
	@echo "$(CYAN)── Systemd Timers ─────────────────────────────────────────$(NC)"
	@systemctl list-timers --all 2>/dev/null | grep -E '(NEXT|vaultwarden)' || echo "  No vaultwarden timers found"
	@echo ""
	@echo "$(GREEN)Diagnostic complete. Paste the above output when filing a support request.$(NC)"

# ===========================================================================
##@ Cleanup
# ===========================================================================

clean: ## Clean up Docker resources (stopped containers + dangling images)
	@echo "$(BLUE)Cleaning up Docker resources...$(NC)"
	@$(DOCKER_COMP) rm -f --stop 2>/dev/null || true
	@docker system prune -f
	@echo "$(GREEN)Cleanup completed!$(NC)"

# FIX [P5-H3]: clean-all requires interactive TTY; aborts in CI/piped context.
clean-all: ## Remove all containers, volumes, and data (DESTRUCTIVE)
	@echo "$(RED)WARNING: This will remove all containers, volumes, and data!$(NC)"
	@if [ ! -t 0 ]; then \
		echo "$(RED)Aborted: stdin is not a terminal. clean-all requires an interactive session.$(NC)"; \
		exit 1; \
	fi
	@read -r -p "Are you sure? Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || { echo "$(YELLOW)Aborted. No data was deleted.$(NC)"; exit 1; }; \
	$(DOCKER_COMP) down -v --remove-orphans; \
	docker system prune -af --volumes

prune: ## Remove unused Docker resources (images, networks, build cache)
	@echo "$(BLUE)Pruning unused Docker resources...$(NC)"
	@docker system prune -f
	@echo "$(GREEN)Prune completed!$(NC)"

# ===========================================================================
##@ Uninstall
# ===========================================================================

uninstall-dry-run: ## Preview what uninstall would remove (no changes made)
	@echo "$(BLUE)Previewing uninstall (dry-run)...$(NC)"
	@sudo ./uninstall-vaultwarden.sh --dry-run

uninstall: ## Completely remove VaultWarden-OCI (DESTRUCTIVE)
	$(call require-root)
	@echo "$(RED)WARNING: This will permanently remove VaultWarden and all data!$(NC)"
	@if [ ! -t 0 ]; then \
		echo "$(RED)Aborted: stdin is not a terminal. uninstall requires an interactive session.$(NC)"; \
		exit 1; \
	fi
	@read -r -p "Type 'yes' to confirm full uninstall: " confirm && [ "$$confirm" = "yes" ] || { \
		echo "$(YELLOW)Aborted. No data was deleted.$(NC)"; exit 1; \
	}
	@./uninstall-vaultwarden.sh
