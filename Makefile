# VaultWarden-OCI Makefile
# Optimized for the current codebase

# ---------------------------------------------------------------------------
# help target uses the ##@ (section) + ## (target) convention popularised by
# controller-runtime / kubebuilder.  Sections are declared with ##@ TITLE on
# a line by itself; individual targets use ## Description inline.
# ---------------------------------------------------------------------------

.PHONY: help \
        setup init-secrets edit-secrets test-secrets test-email \
        up down restart start stop status \
        health health-quick health-email \
        logs logs-tail logs-postfix logs-vaultwarden logs-caddy logs-fail2ban \
        backup backup-full backup-emergency list-backups backup-status \
        restore restore-db restore-remote \
        update update-system \
        maintenance maintenance-full update-dns \
        key-rotate key-show key-health \
        breakglass-create breakglass-status breakglass-remove \
        systemd-install systemd-remove systemd-status systemd-validate timers \
        uninstall uninstall-dry-run \
        dev-setup test test-config dry-run \
        db-maint db-backup \
        clean clean-all prune \
        info shell version watch monitor safe-restart fmt config lint diagnose

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
COMPOSE_FILE          ?= docker-compose.yml
COMPOSE_PROJECT_NAME  ?= vaultwarden-oci
DOCKER_COMP           ?= $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
# COMPOSE_DOCKER_CLI_BUILD is deprecated in Docker 23+ (BuildKit is on by default).
DOCKER_BUILDKIT       ?= 1

# Service names
SERVICES          = vaultwarden caddy fail2ban postfix
CORE_SERVICES     = vaultwarden caddy
OPTIONAL_SERVICES = watchtower backup

# Terminal colours
RED    = \033[0;31m
GREEN  = \033[0;32m
YELLOW = \033[1;33m
BLUE   = \033[0;34m
CYAN   = \033[0;36m
NC     = \033[0m

export DOCKER_BUILDKIT

# ---------------------------------------------------------------------------
# help — grouped output using ##@ sections and ## descriptions
# ---------------------------------------------------------------------------
help: ## Show this help message
	@echo "$(BLUE)VaultWarden-OCI Management$(NC)"
	@echo "$(BLUE)==============================$(NC)"
	@awk 'BEGIN {FS = ":.*##"; section=""} \
	  /^##@/ { section = substr($$0, 5); printf "\n$(CYAN)%s$(NC)\n", section; next } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  $(YELLOW)%-24s$(NC) %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""
	@echo "$(GREEN)Examples:$(NC)"
	@echo "  $(YELLOW)make up$(NC)                          Start with secrets initialization"
	@echo "  $(YELLOW)make logs SERVICE=caddy$(NC)          View caddy logs"
	@echo "  $(YELLOW)make backup TYPE=emergency$(NC)       Create emergency backup"
	@echo "  $(YELLOW)make health AUTO_RECOVER=true$(NC)    Health check with auto-recovery"
	@echo "  $(YELLOW)make restore$(NC)                     Interactive restore (prompts for key)"
	@echo "  $(YELLOW)make key-rotate$(NC)                  Rotate the age encryption key"
	@echo "  $(YELLOW)make timers$(NC)                      Show all vaultwarden systemd timers"
	@echo "  $(YELLOW)make diagnose$(NC)                    Full diagnostic dump for support/debug"
	@echo "  $(YELLOW)make backup-status$(NC)               Show backup health summary"
	@echo "  $(YELLOW)make lint$(NC)                        Shellcheck all scripts"

# ---------------------------------------------------------------------------
##@ Setup & Installation
# ---------------------------------------------------------------------------

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

# FIX [P5-M2]: propagate failure exit code so `make test` fails correctly.
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
	@sudo ./maintenance.sh --test-email --verbose

# ---------------------------------------------------------------------------
##@ Service Management
# ---------------------------------------------------------------------------

# FIX [P5-H1]: up/restart invoke sudo ./startup.sh so require_root passes.
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

restart: ## Restart all services (enhanced startup)
	@echo "$(BLUE)Restarting VaultWarden-OCI services...$(NC)"
	@sudo ./startup.sh --force-restart || { echo "$(RED)Restart failed!$(NC)"; $(MAKE) status; exit 1; }
	@echo "$(GREEN)Services restarted successfully!$(NC)"

# FIX [P5-C1]: safe-restart captures pre-restart IDs and rolls back on failure.
# sudo is required for ./startup.sh (require_root) and for ./health.sh
# (require_root) used in the post-restart verification step.
safe-restart: ## Restart with automatic rollback on failure
	@echo "$(BLUE)Performing safe restart with rollback capability...$(NC)"
	@PRE_IDS=$$($(DOCKER_COMP) ps -q 2>/dev/null); \
	if sudo ./startup.sh --force-restart; then \
		echo "$(GREEN)Restart successful — running post-restart health check (10s grace)...$(NC)"; \
		sleep 10; \
		if sudo ./health.sh --quiet; then \
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

# ---------------------------------------------------------------------------
##@ Monitoring & Status
# ---------------------------------------------------------------------------

status: ## Show service status
	@echo "$(BLUE)Service Status:$(NC)"
	@$(DOCKER_COMP) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "$(RED)Services not running$(NC)"

health: ## Run health checks (Optional: AUTO_RECOVER=true, COMPREHENSIVE=true)
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

# QOL [item 3]: logs-fail2ban was missing; fail2ban is a first-class service
# and the first place to check for false-positive IP bans.
logs-fail2ban: ## Tail Fail2ban intrusion-prevention logs
	@$(DOCKER_COMP) logs -f -t --tail=100 fail2ban

# FIX [P5-M3] + QOL [item 9]: watch now calls health-quick (port+container probe)
# instead of the full health.sh run.  Running the comprehensive health stack every
# 5 s hammers the VaultWarden HTTPS endpoint, SQLite, Docker API, and Fail2ban;
# health-quick is the right tool for a status-loop context.
watch: ## Watch service status every 5s (requires watch command)
	@command -v watch >/dev/null 2>&1 || { echo "$(RED)watch not found. Install: sudo apt install procps$(NC)"; exit 1; }
	@watch -n 5 'DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make status && echo && DOCKER_COMP="$(DOCKER_COMP)" COMPOSE_FILE="$(COMPOSE_FILE)" make health-quick'

monitor: ## Monitor all service logs in real-time (Ctrl+C to stop)
	@echo "$(BLUE)Monitoring all services (Ctrl+C to stop)...$(NC)"
	@$(DOCKER_COMP) logs -f -t

# QOL [item 2]: Single command that dumps everything needed for a support/debug
# session: version, compose validity, age key, disk, last backup, containers,
# and the last 20 lines from each service.  Does not require any flags.
diagnose: ## Full diagnostic dump — versions, key status, disk, containers, last backup, recent logs
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
		echo "  Status : $(RED)MISSING — backups will fail$(NC)"; \
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

# ---------------------------------------------------------------------------
##@ Backup & Restore
# ---------------------------------------------------------------------------

# QOL [item 5]: backup now emits a visible notice when TYPE defaults to 'db'
# so an operator who forgot TYPE=full gets clear feedback rather than silent
# partial coverage.
backup: ## Create backup (TYPE: db, full, emergency)
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

# QOL [item 14]: backup-status provides a richer summary: last backup time per
# type, total backup dir size, retention window, and number of archives retained.
backup-status: ## Show backup health summary — last run, size, retention, count per type
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

restore: ## Interactive restore — prompts for backup selection and age key
	@echo "$(BLUE)Starting interactive restore...$(NC)"
	@sudo ./restore.sh

# FIX [item 4]: restore-db no longer passes --force so the age key prompt and
# confirmation step run as intended. Use --force explicitly if you need to skip.
restore-db: ## Restore latest database backup (interactive confirmation + key prompt)
	@echo "$(BLUE)Restoring latest database backup...$(NC)"
	@sudo ./restore.sh --type db --latest

restore-remote: ## Restore from a remote (rclone) backup — interactive selection
	@echo "$(BLUE)Starting remote restore...$(NC)"
	@sudo ./restore.sh --remote

# ---------------------------------------------------------------------------
##@ Age Key Management
# ---------------------------------------------------------------------------

# MAKE-KR1 FIX [HIGH]: The old recipe ran:
#   source lib/crypto.sh && rotate_age_key
# inside the Make recipe shell, which is /bin/sh (dash on Debian/Ubuntu).
# dash does not implement the 'source' builtin — it silently fails with
# "sh: 1: source: not found", so rotate_age_key never executed.
# Fix: invoke bash explicitly so 'source' works.
#
# MAKE-KR2 [LOW]: Added key-health pre-flight before rotation so a corrupt
# or unreadable key is caught with a clear message before any write occurs.
key-rotate: ## Rotate the age encryption key (generates new key, updates all locations)
	@echo "$(BLUE)Rotating age encryption key...$(NC)"
	@echo "$(YELLOW)WARNING: After rotation, new backups will use the new key.$(NC)"
	@echo "$(YELLOW)Keep the new key displayed at the end in a secure location.$(NC)"
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)Error: key rotation requires sudo: sudo make key-rotate$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Pre-flight: checking current age key health...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; check_age_key_health' || \
		{ echo "$(YELLOW)Warning: key health check failed — proceeding anyway (key may not yet exist).$(NC)"; true; }
	@bash -c 'set -euo pipefail; source lib/crypto.sh; rotate_age_key' && \
		echo "$(GREEN)Key rotation complete.$(NC)"

key-show: ## Show current age public key and key file path/status
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
		echo "  $(RED)Run: sudo make setup  or  sudo ./setup.sh to generate a key$(NC)"; \
	fi

# MAKE-KH1 [NEW]: Dedicated target for key health check via simple_key_resilience.sh.
# Useful as a standalone diagnostic and as a pre-flight dependency.
key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	@echo "$(BLUE)Checking age key health...$(NC)"
	@bash -c 'set -euo pipefail; source lib/simple_key_resilience.sh; check_age_key_health' && \
		echo "$(GREEN)Age key health check passed$(NC)" || \
		{ echo "$(RED)Age key health check FAILED — run: sudo make setup$(NC)"; exit 1; }

# ---------------------------------------------------------------------------
##@ Maintenance
# ---------------------------------------------------------------------------

update: ## Update container images (briefly stops services)
	@echo "$(YELLOW)NOTE: Services will be briefly stopped during the image update.$(NC)"
	@echo "$(BLUE)Updating container images...$(NC)"
	@./update.sh
	@echo "$(GREEN)Update completed successfully!$(NC)"

update-system: ## Update system packages and containers with email notification
	@echo "$(YELLOW)NOTE: Services will be briefly stopped during the update.$(NC)"
	@echo "$(BLUE)Updating system and containers...$(NC)"
	@./update.sh --system --email

maintenance: ## Run comprehensive maintenance (cleanup, Docker, DB, DNS, firewall)
	@echo "$(BLUE)Running maintenance tasks...$(NC)"
	@sudo ./maintenance.sh --comprehensive
	@echo "$(GREEN)Maintenance completed successfully!$(NC)"

maintenance-full: ## Run full maintenance with email notification
	@echo "$(BLUE)Running comprehensive maintenance...$(NC)"
	@sudo ./maintenance.sh --comprehensive --email

update-dns: ## Update DNS record to current public IP
	@echo "$(BLUE)Updating DNS record...$(NC)"
	@sudo ./maintenance.sh --update-dns
	@echo "$(GREEN)DNS updated successfully!$(NC)"

db-maint: ## Run deep database maintenance — VACUUM + WAL checkpoint (requires sudo)
	@echo "$(BLUE)Running database maintenance...$(NC)"
	@sudo ./maintenance.sh --db-maint

db-backup: ## Quick database-only backup
	@$(MAKE) backup TYPE=db

# ---------------------------------------------------------------------------
##@ Systemd Timers
# ---------------------------------------------------------------------------

systemd-install: ## Install systemd timer units and sync scripts to /opt
	@echo "$(BLUE)Installing systemd timer units...$(NC)"
	@sudo ./setup-systemd.sh --install
	@echo "$(GREEN)Systemd units installed. Run 'make timers' to verify.$(NC)"

systemd-remove: ## Remove all vaultwarden systemd timer units
	@echo "$(YELLOW)Removing systemd timer units...$(NC)"
	@sudo ./setup-systemd.sh --remove

systemd-status: ## Show status of all vaultwarden systemd units
	@sudo ./setup-systemd.sh --status

systemd-validate: ## Validate installed systemd units match current repo scripts
	@echo "$(BLUE)Validating systemd unit/script checksums...$(NC)"
	@sudo ./setup-systemd.sh --validate

# QOL [item 15]: timers now also shows the OnCalendar schedule from .env
# so there is a single view of "configured schedule / next trigger / last run".
timers: ## List all vaultwarden systemd timers (next trigger + last run + .env schedule)
	@echo "$(BLUE)Systemd Timer Status:$(NC)"
	@systemctl list-timers --all 2>/dev/null | grep -E '(NEXT|vaultwarden)' || \
		echo "$(YELLOW)No vaultwarden timers found. Run: sudo make systemd-install$(NC)"
	@echo ""
	@echo "$(CYAN)Configured schedules in .env:$(NC)"
	@grep -E '^BACKUP_SCHEDULE' .env 2>/dev/null | while IFS= read -r line; do \
		echo "  $$line"; \
	done || echo "  $(YELLOW)No BACKUP_SCHEDULE_* variables found in .env$(NC)"

# ---------------------------------------------------------------------------
##@ Security
# ---------------------------------------------------------------------------

breakglass-create: ## Create emergency admin account
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --create

breakglass-status: ## Show break-glass admin account status
	@sudo ./create-breakglass-admin.sh --status

breakglass-remove: ## Remove break-glass admin account
	@echo "$(YELLOW)Removing break-glass admin account...$(NC)"
	@sudo ./create-breakglass-admin.sh --remove

# ---------------------------------------------------------------------------
##@ Uninstall
# ---------------------------------------------------------------------------

uninstall-dry-run: ## Preview what uninstall would remove (no changes made)
	@echo "$(BLUE)Previewing uninstall (dry-run)...$(NC)"
	@sudo ./uninstall-vaultwarden.sh --dry-run

uninstall: ## Full uninstall — removes containers, data, systemd units (DESTRUCTIVE)
	@echo "$(RED)WARNING: This permanently removes VaultWarden and all its data!$(NC)"
	@if [ ! -t 0 ]; then \
		echo "$(RED)Aborted: stdin is not a terminal. uninstall requires an interactive session.$(NC)"; \
		exit 1; \
	fi
	@read -r -p "Type 'yes' to confirm full uninstall: " confirm && [ "$$confirm" = "yes" ] || { \
		echo "$(YELLOW)Aborted. No data was deleted.$(NC)"; exit 1; \
	}
	@sudo ./uninstall-vaultwarden.sh

# ---------------------------------------------------------------------------
##@ Development & Testing
# ---------------------------------------------------------------------------

dev-setup: ## Setup development environment (.env + docker-compose.override.yml)
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then cp .env.example .env; echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; fi
	@if [ ! -f "docker-compose.override.yml" ]; then cp docker-compose.override.yml.example docker-compose.override.yml; echo "$(YELLOW)Created development override file.$(NC)"; fi

test: ## Run all tests (secrets, email, compose config)
	@echo "$(BLUE)Running tests...$(NC)"
	@$(MAKE) test-secrets
	@$(MAKE) test-email
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)Docker Compose config valid$(NC)" || { echo "$(RED)Docker Compose config invalid$(NC)"; exit 1; }

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

fmt: ## Validate all configuration files (compose + secrets)
	@echo "$(BLUE)Validating configuration files...$(NC)"
	@$(DOCKER_COMP) config > /dev/null && echo "$(GREEN)✓ docker-compose.yml$(NC)" || echo "$(RED)✗ docker-compose.yml$(NC)"
	@if [ -f "docker-compose.override.yml" ]; then \
		$(DOCKER_COMP) -f docker-compose.yml -f docker-compose.override.yml config > /dev/null && \
		echo "$(GREEN)✓ docker-compose.override.yml$(NC)" || echo "$(RED)✗ docker-compose.override.yml$(NC)"; \
	fi
	@./edit-secrets.sh --list > /dev/null && echo "$(GREEN)✓ secrets.yaml$(NC)" || echo "$(RED)✗ secrets.yaml$(NC)"

# QOL [item 12]: lint runs shellcheck over all *.sh files in the repo root and
# lib/ so regressions (unquoted variables, SC2086, wrong shell directives) are
# caught before commit.  Gracefully skips if shellcheck is not installed and
# prints the install command.
lint: ## Run shellcheck over all shell scripts (install: sudo apt install shellcheck)
	@echo "$(BLUE)Linting shell scripts with shellcheck...$(NC)"
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "$(YELLOW)shellcheck not installed. Install with: sudo apt install shellcheck$(NC)"; \
		exit 0; \
	fi
	@FAILED=0; \
	for f in *.sh lib/*.sh; do \
		[ -f "$$f" ] || continue; \
		if shellcheck -S warning "$$f"; then \
			echo "  $(GREEN)✓ $$f$(NC)"; \
		else \
			echo "  $(RED)✗ $$f$(NC)"; \
			FAILED=$$((FAILED + 1)); \
		fi; \
	done; \
	if [ "$$FAILED" -gt 0 ]; then \
		echo "$(RED)$$FAILED script(s) failed shellcheck$(NC)"; \
		exit 1; \
	else \
		echo "$(GREEN)All scripts passed shellcheck$(NC)"; \
	fi

# ---------------------------------------------------------------------------
##@ Cleanup
# ---------------------------------------------------------------------------

# FIX [P5-M5]: anchored grep prevents multi-line leakage.
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

# ---------------------------------------------------------------------------
##@ Information
# ---------------------------------------------------------------------------

# QOL [item 1 + item 13]: info now reads VERSION file and shows backup dir size
# + retention window alongside the state directory disk usage.
info: ## Show system information including version, age key status, and disk usage
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
		echo "  $(RED)MISSING: $$KEY_FILE$(NC)  — backups will fail until key is restored"; \
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

shell: ## Open shell in specified SERVICE (default: vaultwarden)
	@echo "$(BLUE)Opening shell in $(if $(SERVICE),$(SERVICE),vaultwarden)...$(NC)"
	@$(DOCKER_COMP) exec $(if $(SERVICE),$(SERVICE),vaultwarden) sh

# QOL [item 1]: version now reads the VERSION file so the repo version is
# always displayed alongside the running container versions.
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

# FIX [item 15]: show truncation notice when .env has more than 15 non-sensitive lines.
config: ## Show current configuration summary (sensitive keys redacted)
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
