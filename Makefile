# ===========================================================================
# VaultWarden-OCI — Makefile
# ===========================================================================
# Usage:
#   sudo ./setup.sh install --domain <domain> --email <email> — First-time installation
#   sudo make up             — Start services (root-operated production path)
#   sudo make down           — Stop services
#   sudo make restart        — Restart services
#   sudo make safe-restart   — Restart with automatic rollback on failure
#   sudo make status         — Show service status
#   sudo make health         — Run health checks
#   sudo make logs           — Follow service logs
#   make help                — Show normal admin/day-2 targets
#   make help-all            — Show every target, including dashboard/API/advanced targets
# ===========================================================================

# Freeze documented operator inputs before any parse-time shell invocation.
# GNU Make 4.4's shell-export feature exports command-line variables to
# $(shell ...), so capture their raw values before the first such expansion.
EMAIL_TEST_TRANSPORT ?= configured
QUEUE_ID ?=
EMAIL_QUEUE_TAIL ?= 200
EMAIL_QUEUE_BODY ?= false

override EMAIL_TEST_TRANSPORT := $(value EMAIL_TEST_TRANSPORT)
override QUEUE_ID := $(value QUEUE_ID)
override EMAIL_QUEUE_TAIL := $(value EMAIL_QUEUE_TAIL)
override EMAIL_QUEUE_BODY := $(value EMAIL_QUEUE_BODY)

export EMAIL_TEST_TRANSPORT QUEUE_ID EMAIL_QUEUE_TAIL EMAIL_QUEUE_BODY

# ── Colour helpers ──────────────────────────────────────────────────────────
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
CYAN   := \033[0;36m
NC     := \033[0m

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT_ROOT         ?= $(shell pwd)
COMPOSE_FILE         ?= docker-compose.yml
COMPOSE_PROJECT_NAME ?= vaultwarden-oci
DOCKER_COMP          ?= $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

SERVICES          = vaultwarden caddy postfix
CORE_SERVICES     = vaultwarden caddy

# Override on the command line to target a specific archive, e.g.:
#   sudo make restore BACKUP_FILE=backups/db/vaultwarden-db-20250101-120000.age
BACKUP_FILE ?=
# Optional first install data volume: sudo ./setup.sh install --domain <domain> --email <email> --data-device /dev/sdb
DATA_DEVICE ?=

# ── Phony targets ───────────────────────────────────────────────────────────
.PHONY: help help-all \
        setup sync-env edit-env init-secrets edit-secrets test-secrets test-email email-queue email-queue-summary email-queue-inspect email-queue-retry email-queue-retry-all email-queue-delete email-queue-logs email-queue-purge email-queue-clear \
        up down restart start stop safe-restart status operations \
        health health-quick health-report test-email smoke-test drill \
        logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec \
        watch monitor \
        backup backup-full backup-emergency list-backups backup-status \
        restore restore-preflight restore-db restore-remote \
        key-health key-backup key-escrow key-rotate key-show key-install \
        update check-updates update-system update-dns \
        maintenance maintenance-full \
        db-maint db-backup \
        install-systemd remove-systemd systemd-status systemd-validate timers schedule \
        breakglass-create breakglass-status breakglass-remove \
        dev-setup fix-permissions test-config dry-run \
        info version shell config diagnose \
        clean clean-all prune \
        unban crowdsec-status crowdsec-alerts security-report \
        uninstall uninstall-dry-run \
        docs backup-manifest

# ── Root invocation policy ────────────────────────────────────────────────────
# Most non-operator helper targets should run as the normal login user to avoid
# repository ownership drift from accidental `sudo make ...`.
#
# Production/admin lifecycle and day-2 operations are root-operated. This guard is
# intentionally target-aware: it allows `sudo make up` / `sudo make restart` while
# still blocking accidental root execution of targets that should stay non-root.
#
# Recursive make calls are exempt so root-required targets can safely call helper
# targets internally, for example `sudo make key-rotate` calling `make key-health`.
ROOT_ALLOWED_TARGETS := \
	setup sync-env edit-env init-secrets edit-secrets test-secrets test-email email-queue email-queue-summary email-queue-inspect email-queue-retry email-queue-retry-all email-queue-delete email-queue-logs email-queue-purge email-queue-clear health-email up down start stop restart safe-restart status operations \
	health health-quick health-report logs logs-tail logs-vaultwarden logs-caddy logs-postfix logs-crowdsec fix-permissions \
	backup backup-full backup-emergency list-backups backup-status \
	restore restore-preflight restore-db restore-remote \
	key-backup key-escrow key-rotate key-health key-show key-install \
	update update-system update-dns maintenance maintenance-full db-maint db-backup \
	install-systemd remove-systemd systemd-status systemd-validate \
	unban crowdsec-status crowdsec-alerts security-report smoke-test drill \
	breakglass-create breakglass-status breakglass-remove \
	uninstall uninstall-dry-run diagnose prune

ROOT_NEUTRAL_TARGETS := help help-all version

_REQUESTED_TARGETS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),help)
_ROOT_DISALLOWED_TARGETS := $(filter-out $(ROOT_ALLOWED_TARGETS) $(ROOT_NEUTRAL_TARGETS),$(_REQUESTED_TARGETS))

ifeq ($(MAKELEVEL),0)
ifneq ($(strip $(_ROOT_DISALLOWED_TARGETS)),)
ifeq ($(shell id -u),0)
$(error Do not run these make target(s) as root/sudo: $(_ROOT_DISALLOWED_TARGETS). Run as your normal user: make $(_ROOT_DISALLOWED_TARGETS))
endif
endif
endif

# ── Helpers ──────────────────────────────────────────────────────────────────
# require-root: used for targets that genuinely need elevated privileges
# (setup, backup, restore, key operations, maintenance, systemd, uninstall).
# Production service management targets are root-operated.
define require-root
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)Error: Run with sudo: sudo make $@$(NC)"; \
		exit 1; \
	fi
endef

# check-docker: lightweight guard used after privilege checks.
# Verifies the Docker daemon is reachable.
define check-docker
	@if ! docker info > /dev/null 2>&1; then \
		echo "$(RED)Error: Cannot connect to the Docker daemon.$(NC)"; \
		echo "$(RED)       Docker may not be running or root cannot reach it.$(NC)"; \
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

# Dashboard compatibility note:
# Several targets in this Makefile are consumed by dashboard and automation
# flows as a stable command API. Do not rename or remove targets without first
# searching dashboard.sh, docs, workflows, and any external dashboard config.
# Prefer hiding advanced/developer targets from `make help` and keeping full
# discovery in `make help-all`.

help: ## Show normal admin/day-2 commands
	@echo ""
	@echo "$(BLUE)VaultWarden-OCI — Normal Admin Commands$(NC)"
	@echo ""
	@echo "$(YELLOW)Service lifecycle$(NC)"
	@echo "  $(GREEN)start$(NC)                    Start all services through startup.sh"
	@echo "  $(GREEN)stop$(NC)                     Stop all services gracefully"
	@echo "  $(GREEN)restart$(NC)                  Recreate services without pulling images"
	@echo "  $(GREEN)status$(NC)                   Show service, backup, disk, and CrowdSec summary"
	@echo "  $(GREEN)logs$(NC)                     View logs (SERVICE=caddy|vaultwarden|postfix)"
	@echo ""
	@echo "$(YELLOW)Health and diagnostics$(NC)"
	@echo "  $(GREEN)health$(NC)                   Full health check (AUTO_RECOVER=true enables safe fixes)"
	@echo "  $(GREEN)health-quick$(NC)             Concise health check"
	@echo "  $(GREEN)test-email$(NC)               Test configured or exact email delivery transports"
	@echo "  $(GREEN)test-secrets$(NC)             Verify SOPS/Age secret decryption"
	@echo "  $(GREEN)diagnose$(NC)                 Collect versions, status, key state, disk, and logs"
	@echo ""
	@echo "$(YELLOW)Backup and restore$(NC)"
	@echo "  $(GREEN)backup$(NC)                   Run DB snapshot backup"
	@echo "  $(GREEN)backup-full$(NC)              Run full backup"
	@echo "  $(GREEN)backup-status$(NC)            Show backup inventory (run with sudo)"
	@echo "  $(GREEN)list-backups$(NC)             List local backups (run with sudo)"
	@echo "  $(GREEN)restore$(NC)                  Guided restore"
	@echo "  $(GREEN)restore-remote$(NC)           Restore from rclone remote"
	@echo "  $(GREEN)restore-db$(NC)               Restore database only"
	@echo ""
	@echo "$(YELLOW)Operations$(NC)"
	@echo "  $(GREEN)sync-env$(NC)                 Sync repo .env to generated installed runtime env files"
	@echo "  $(GREEN)maintenance$(NC)              Run routine maintenance"
	@echo "  $(GREEN)update$(NC)                   Update container images and restart"
	@echo "  $(GREEN)timers$(NC)                   Show systemd timers"
	@echo "  $(GREEN)systemd-status$(NC)           Show systemd unit status"
	@echo "  $(GREEN)breakglass-create$(NC)        Create emergency admin account"
	@echo "  $(GREEN)breakglass-status$(NC)        Check emergency admin account"
	@echo ""
	@echo "$(CYAN)Need everything? Run $(GREEN)make help-all$(NC) for dashboard/stable API, advanced admin, validation, and legacy targets.$(NC)"
	@echo ""

help-all: ## Show every target, including dashboard/API, advanced, validation, and legacy commands
	@echo ""
	@echo "$(BLUE)VaultWarden-OCI — All Targets$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf ""} \
	     /^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) } \
	     /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-24s$(NC) %s\n", $$1, $$2 }' \
	    $(MAKEFILE_LIST)
	@echo ""
	@echo "$(CYAN)Classification guide:$(NC)"
	@echo "  normal admin        shown by make help"
	@echo "  dashboard/stable API retained for dashboard and automation compatibility"
	@echo "  advanced admin      powerful or specialized operations"
	@echo "  validation/docs     operator diagnostics and generated documentation"
	@echo "  legacy/deprecated   backward-compatible aliases"
	@echo ""

# ===========================================================================
##@ Advanced Admin — Setup & Installation
# ===========================================================================

setup:
	@echo "$(YELLOW)The supported first-install command is:$(NC)"
	@echo "$(GREEN)  sudo ./setup.sh install --domain <your-domain> --email <your-email>$(NC)"
	@echo "$(YELLOW)This Make target is guidance only and does not perform installation.$(NC)"
	@exit 1

dev-setup: ## Set up development environment (.env + docker-compose.override.yml)
	@echo "$(BLUE)Setting up development environment...$(NC)"
	@if [ ! -f ".env" ]; then cp .env.example .env; echo "$(YELLOW)Created .env from example. Please configure it.$(NC)"; fi
	@if [ ! -f "docker-compose.override.yml" ]; then cp docker-compose.override.yml.example docker-compose.override.yml; echo "$(YELLOW)Created development override file.$(NC)"; fi

fix-permissions: ## Repair known VaultWarden-OCI permission drift
	$(call require-root)
	@utilities/repair-permissions.sh

init-secrets: ## Initialize secrets file (interactive; root required)
	$(call require-root)
	@echo "$(BLUE)Initializing secrets...$(NC)"
	@SECRETS_PATH=$$(bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; printf "%s" "$$SECRETS_FILE"') || exit 1; \
	if [ ! -f "$$SECRETS_PATH" ]; then \
		echo "$(BLUE)No secrets file found. Running setup.sh secrets...$(NC)"; \
		./setup.sh secrets; \
	else \
		echo "$(YELLOW)Secrets file already exists. Use 'make edit-secrets' to modify.$(NC)"; \
	fi

sync-env: ## Sync repo .env to generated runtime env files (root required)
	$(call require-root)
	@./utilities/env-edit.sh sync

edit-env: ## Interactively edit repo .env and sync on change (root required)
	$(call require-root)
	@./utilities/env-edit.sh edit

edit-secrets: ## Edit encrypted secrets file
	$(call require-root)
	@echo "$(BLUE)Opening secrets editor...$(NC)"
	@./utilities/secrets-edit.sh

test-secrets: ## Test secrets decryption
	$(call require-root)
	@echo "$(BLUE)Testing secrets decryption...$(NC)"
	@if ./utilities/secrets-list.sh > /dev/null 2>&1; then \
		echo "$(GREEN)Secrets decryption: OK$(NC)"; \
	else \
		echo "$(RED)Secrets decryption: FAILED$(NC)"; \
		exit 1; \
	fi

test-email: ## Test configured or exact email delivery transports (EMAIL_TEST_TRANSPORT=...)
	$(call require-root)
	@echo "$(BLUE)Testing email delivery transport: $${EMAIL_TEST_TRANSPORT}$(NC)"
	@./maintenance.sh test-email --transport "$${EMAIL_TEST_TRANSPORT}" --verbose

email-queue: ## Show the human-readable Postfix email queue
	$(call require-root)
	@./utilities/email-queue.sh status

email-queue-summary: ## Summarize the Postfix queue safely
	$(call require-root)
	@./utilities/email-queue.sh summary

email-queue-inspect: ## Inspect QUEUE_ID headers/envelope (EMAIL_QUEUE_BODY=true includes body)
	$(call require-root)
	@if [ "$${EMAIL_QUEUE_BODY}" = "true" ]; then \
		./utilities/email-queue.sh inspect "$${QUEUE_ID}" --body; \
	else \
		./utilities/email-queue.sh inspect "$${QUEUE_ID}"; \
	fi

email-queue-retry: ## Retry one exact QUEUE_ID
	$(call require-root)
	@./utilities/email-queue.sh retry "$${QUEUE_ID}"

email-queue-retry-all: ## Retry all queued messages after exact confirmation
	$(call require-root)
	@./utilities/email-queue.sh retry --all

email-queue-delete: ## Delete one exact QUEUE_ID; requires verified long IDs
	$(call require-root)
	@./utilities/email-queue.sh delete "$${QUEUE_ID}"

email-queue-logs: ## Show Postfix logs (QUEUE_ID optional, EMAIL_QUEUE_TAIL default 200)
	$(call require-root)
	@if [ -n "$${QUEUE_ID}" ]; then \
		./utilities/email-queue.sh logs "$${QUEUE_ID}" --tail "$${EMAIL_QUEUE_TAIL}"; \
	else \
		./utilities/email-queue.sh logs --tail "$${EMAIL_QUEUE_TAIL}"; \
	fi

email-queue-purge: ## Purge identity matches; requires verified long IDs
	$(call require-root)
	@./utilities/email-queue.sh purge --snapshot

email-queue-clear: ## Deprecated long-ID-gated alias for snapshot purge
	$(call require-root)
	@./utilities/email-queue.sh clear

# ===========================================================================
##@ Normal Admin + Dashboard Stable API — Service Management
# ===========================================================================

# Production lifecycle targets are root-operated. Non-root invocations fail
# fast with an explicit sudo make command.
# startup.sh handles secrets initialisation, secrets pre-flight checks, and
# the post-start health poll — do not replace it with a bare `docker compose up`.

up: ## Start all services (runs startup.sh for health checks; root required)
	$(call require-root)
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
		echo "$(RED)       re-run: sudo make up$(NC)"; \
		exit 1; \
	fi
# ── Pre-flight: encrypted secrets guard. ────────────────────────────────────
# startup.sh is responsible for decrypting secrets.yaml into
# /run/vaultwarden-oci/secrets. Do not require decoded runtime secret files
# here; they are created during root startup.
	@SECRETS_PATH=$$(bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; printf "%s" "$$SECRETS_FILE"') || exit 1; \
	if ! test -f "$$SECRETS_PATH"; then \
		echo "$(RED)ERROR: secrets/secrets.yaml not found — secrets have not been initialized.$(NC)"; \
		echo "$(RED)       Run: sudo make init-secrets$(NC)"; \
		echo "$(RED)       Then re-run: sudo make up$(NC)"; \
		exit 1; \
	fi
	@./startup.sh || { \
		echo "$(RED)Startup failed!$(NC)"; \
		$(MAKE) status; \
		echo ""; \
		echo "$(YELLOW)If startup failed due to a missing or misconfigured Age key:$(NC)"; \
		echo "$(YELLOW)  Diagnose: sudo make key-health$(NC)"; \
		echo "$(YELLOW)  Auto-fix: sudo make key-install$(NC)"; \
		echo "$(YELLOW)  The configured key from the selected runtime environment was not replaced by a fallback.$(NC)"; \
		echo "$(YELLOW)  Canonical production path:        /etc/vaultwarden/age-key.txt$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Services started successfully!$(NC)"

start: up ## Alias for up

down: ## Stop all services gracefully (root required)
	$(call require-root)
	$(call check-docker)
	@echo "$(BLUE)Stopping VaultWarden services...$(NC)"
	@./startup.sh stop
	@echo "$(GREEN)Services stopped.$(NC)"

stop: down ## Alias for down

restart: ## Recreate all services using locally installed images (root required)
	$(call require-root)
	$(call check-docker)
	@echo "$(BLUE)Restarting VaultWarden services without pulling images...$(NC)"
	@./startup.sh --force --skip-pull || { \
		echo "$(RED)Restart failed!$(NC)"; \
		$(MAKE) status; \
		echo "$(YELLOW)If restart failed due to a key issue, run: sudo make key-health$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)Services restarted.$(NC)"

safe-restart: ## Restart with automatic rollback on failure (root required)
	$(call require-root)
	@echo "$(BLUE)Safe restart with rollback capability...$(NC)"
	@./utilities/safe-restart.sh

status: ## Show service status, backup inventory, disk usage, and CrowdSec ban summary
	$(call require-root)
	$(call check-docker)
	@echo "$(BLUE)VaultWarden Service Status:$(NC)"
	@$(DOCKER_COMP) ps
	@echo ""
	@echo "$(CYAN)Resource usage:$(NC)"
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep -E "vaultwarden|caddy|postfix" || true
	@echo ""
	@echo "$(CYAN)Backup status:$(NC)"
	@bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; \
	STATE_DIR=$${PROJECT_STATE_DIR:?}; \
	BACKUP_DIR=$${BACKUP_DIR:-$$STATE_DIR/backups}; \
	for btype in db full emergency; do \
		DIR="$$BACKUP_DIR/$$btype"; \
		if [ -d "$$DIR" ]; then \
			LATEST=$$(find "$$DIR" -name "*.age" -type f 2>/dev/null | sort | tail -1); \
			if [ -n "$$LATEST" ]; then \
				TS=$$(basename "$$LATEST" | grep -oE "[0-9]{8}[_-][0-9]{6}" | head -1 || true); \
				SIZE=$$(du -sh "$$LATEST" 2>/dev/null | cut -f1 || echo "?"); \
				echo "  $(GREEN)$$btype$(NC): $$(basename $$LATEST)  ($$SIZE)  $$TS"; \
			else \
				echo "  $(YELLOW)$$btype$(NC): no backups found"; \
			fi; \
		else \
			echo "  $(YELLOW)$$btype$(NC): backup directory not found ($$DIR)"; \
			fi; \
		done'
	@echo ""
	@echo "$(CYAN)Disk usage:$(NC)"
	@bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; \
	STATE_DIR=$${PROJECT_STATE_DIR:?}; \
	BACKUP_DIR=$${BACKUP_DIR:-$$STATE_DIR/backups}; \
	for DIR in "$$STATE_DIR" "$$BACKUP_DIR"; do \
		if [ -d "$$DIR" ]; then \
			AVAIL=$$(df -h "$$DIR" 2>/dev/null | awk "END {print \$$4}"); \
			USED=$$(df -h "$$DIR" 2>/dev/null | awk "END {printf \"%s/%s (%s used)\", \$$3, \$$2, \$$5}"); \
			echo "  $$DIR — available: $$AVAIL  ($$USED)"; \
			fi; \
		done'
	@echo ""
	@echo "$(CYAN)CrowdSec bans:$(NC)"
	@if systemctl is-active crowdsec >/dev/null 2>&1; then \
		CSCLI_OUT=$$(cscli decisions list -o raw 2>&1); \
		CSCLI_RC=$$?; \
		if [ "$$CSCLI_RC" -eq 0 ]; then \
			COUNT=$$(printf '%s\n' "$$CSCLI_OUT" | tail -n +2 | grep -c . || true); \
			echo "  Active bans: $$COUNT"; \
		else \
			echo "  Active bans: $(YELLOW)unknown (cscli query failed)$(NC)"; \
			printf '%s\n' "$$CSCLI_OUT" | head -5 | sed 's/^/    /'; \
		fi; \
	else \
		echo "  $(YELLOW)CrowdSec is not running$(NC)"; \
	fi

operations: ## Show active or interrupted VaultWarden operations
	$(call require-root)
	@./utilities/operations-status.sh

# ===========================================================================
##@ Normal Admin + Advanced Admin — Health & Monitoring
# ===========================================================================

health: ## Run health checks (set AUTO_RECOVER=true to auto-recover; root required)
	$(call require-root)
	@echo "$(BLUE)Running health checks...$(NC)"
	@VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ./utilities/maintenance-health.sh $(if $(filter true,$(AUTO_RECOVER)),--fix,)

health-quick: ## Quick health check (concise output; root required)
	$(call require-root)
	@echo "$(BLUE)Running quick health check...$(NC)"
	@VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ./utilities/maintenance-health.sh --quiet

health-report: ## Run health check and write a timestamped report file (root required)
	$(call require-root)
	@echo "$(BLUE)Running health checks with report output...$(NC)"
	@VAULTWARDEN_INTERNAL_HEALTH_CHECK=true ./utilities/maintenance-health.sh --report

health-email: test-email ## Backward-compatible alias for test-email

smoke-test: ## Run pre-production smoke test against the live stack (root required)
	$(call require-root)
	@utilities/smoke-test.sh

drill: ## Run non-destructive pre-production dry-run drill (root required)
	$(call require-root)
	@utilities/pre-production-drill.sh

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
		docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | grep -E "vaultwarden|caddy|postfix" || true; \
		sleep 30; \
	done

unban: ## Unban an IP from CrowdSec (IP=<address> required)
	$(call require-root)
	@if [ -z "$(IP)" ]; then \
		echo "$(RED)Error: IP address required. Usage: sudo make unban IP=<address>$(NC)"; \
		echo "$(CYAN)Example: sudo make unban IP=203.0.113.42$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Unbanning $(IP) from CrowdSec...$(NC)"
	@if ! systemctl is-active crowdsec >/dev/null 2>&1; then \
		echo "$(RED)Error: CrowdSec is not running.$(NC)"; \
		echo "$(YELLOW)Start it first: sudo systemctl start crowdsec$(NC)"; \
		exit 1; \
	fi
	@CSCLI_OUT=$$(cscli decisions delete --ip '$(IP)' 2>&1); \
	CSCLI_RC=$$?; \
	printf '%s\n' "$$CSCLI_OUT"; \
	if [ "$$CSCLI_RC" -eq 0 ]; then \
		echo "$(GREEN)Unbanned $(IP) from CrowdSec$(NC)"; \
	elif printf '%s\n' "$$CSCLI_OUT" | grep -Eiq 'not found|no decisions?|0 decisions?|0 deleted'; then \
		echo "$(YELLOW)$(IP) was not found in CrowdSec ban list or may have already expired.$(NC)"; \
	else \
		echo "$(RED)CrowdSec unban failed; see cscli output above.$(NC)"; \
		exit "$$CSCLI_RC"; \
	fi

# ===========================================================================
##@ Normal Admin + Dashboard Stable API — Logs
# ===========================================================================

SERVICE ?= vaultwarden

logs: ## View service logs (SERVICE=<name> to filter, default: vaultwarden; root required)
	$(call require-root)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f $(SERVICE)

logs-tail: ## Tail last 100 lines of all service logs (root required)
	$(call require-root)
	$(call check-docker)
	@$(DOCKER_COMP) logs --tail=100

logs-vaultwarden: ## Tail vaultwarden logs (root required)
	$(call require-root)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f vaultwarden

logs-caddy: ## Tail caddy logs (root required)
	$(call require-root)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f caddy

logs-postfix: ## Tail postfix logs (root required)
	$(call require-root)
	$(call check-docker)
	@$(DOCKER_COMP) logs -f postfix

logs-crowdsec: ## Tail CrowdSec logs (root required)
	$(call require-root)
	@journalctl -u crowdsec -f --no-pager

crowdsec-status: ## Show CrowdSec metrics and active bans (root required)
	$(call require-root)
	@cscli metrics
	@echo ""
	@cscli decisions list

crowdsec-alerts: ## Show recent CrowdSec alerts (last 24h; root required)
	$(call require-root)
	@cscli alerts list --since 24h

security-report: ## Single-command security event summary (last 1h; root required)
	$(call require-root)
	@echo "=== Active Bans ==="
	@cscli decisions list
	@echo ""
	@echo "=== Recent Alerts (1h) ==="
	@cscli alerts list --since 1h
	@echo ""
	@echo "=== Caddy Auth Failures ==="
	@docker logs vaultwarden_caddy 2>&1 | grep -i "401\|403\|rate" | tail -20
	@echo ""
	@echo "=== Vaultwarden Auth Failures ==="
	@docker logs vaultwarden_app 2>&1 | grep -i "fail\|error\|unauthorized\|invalid" | tail -20

# ===========================================================================
##@ Normal Admin + Dashboard Stable API — Backup & Restore
# ===========================================================================

backup: ## Run DB snapshot backup
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

list-backups: ## List available backups with sizes (root required via Makefile)
	$(call require-root)
	@echo "$(BLUE)Available backups:$(NC)"
	@./backup.sh list

backup-status: ## Show backup inventory (root required via Makefile)
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
##@ Advanced Admin — Key Management
# ===========================================================================

key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Health Check:$(NC)"
	@echo ""
	@bash -c "source lib/log.sh; source lib/config.sh; source lib/common.sh; init_common_lib startup.sh; \
	         source lib/crypto.sh; \
	         load_project_environment >/dev/null 2>&1 || exit 1; \
	         KEY_FILE=\$$(resolve_age_key_path) || exit 1; \
	         echo \"$(CYAN)  Resolved active key path: \$$KEY_FILE$(NC)\"; \
	         echo \"$(CYAN)  Canonical production path: /etc/vaultwarden/age-key.txt$(NC)\"; \
	         if check_age_key_health; then \
	           echo \"$(GREEN)  ✓ Age key is healthy$(NC)\"; \
	         else \
	           echo \"$(RED)  ✗ Age key health check FAILED$(NC)\"; \
	           echo \"\"; \
	           echo \"$(YELLOW)  Remediation:$(NC)\"; \
	           echo \"$(YELLOW)       sudo make key-install$(NC)\"; \
	           echo \"$(YELLOW)       sudo make key-health$(NC)\"; \
	           echo \"\"; \
	           echo \"$(YELLOW)  Or install manually:$(NC)\"; \
	           echo \"$(YELLOW)       sudo install -d -m 700 -o root -g root /etc/vaultwarden$(NC)\"; \
	           echo \"$(YELLOW)       sudo install -m 600 -o root -g root secrets/keys/age-key.txt /etc/vaultwarden/age-key.txt$(NC)\"; \
	           echo \"$(YELLOW)       # Set SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt in the canonical runtime environment$(NC)\"; \
	           echo \"$(YELLOW)       sudo make key-health$(NC)\"; \
	           exit 1; \
	         fi"

# ---------------------------------------------------------------------------
# key-install: install the Age private key from secrets/keys/age-key.txt to
# the path selected by the canonical runtime environment.
#
# This is the fast-path fix for the most common startup failure:
#   "Age key missing: /etc/vaultwarden/age-key.txt"
#
# When to use:
#   SOPS_AGE_KEY_FILE in the selected runtime environment points to
#   /etc/vaultwarden/age-key.txt (or another system path) but the file does
#   not yet exist there, while the key is
#   already present at secrets/keys/age-key.txt (placed by setup.sh secrets
#   or the initial age-keygen run).
#
# What it does:
#   1. Reads SOPS_AGE_KEY_FILE from the canonical selected runtime environment.
#   2. Self-referential path check (CONFIGURED == REPO_KEY):
#      - File exists  → informational message, exit 0 (no install needed).
#      - File missing → actionable error directing to sudo make init-secrets, exit 1.
#   3. If target already exists and is non-empty, exits without changes.
#   4. Creates the parent directory (mode 700, root:root).
#   5. Copies secrets/keys/age-key.txt → SOPS_AGE_KEY_FILE (mode 600, root:root).
#   6. Runs sudo make key-health to confirm the install succeeded.
#
# Important:
#   - Requires sudo (modifies /etc or another system path).
#   - Does NOT generate a new key — it only installs an existing one.
#   - If secrets/keys/age-key.txt is also missing, run the supported setup.sh install command.
# ---------------------------------------------------------------------------
key-install: ## Install Age key from secrets/keys/ to the path in SOPS_AGE_KEY_FILE
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Installing Age key...$(NC)"
	@CONFIGURED_KEY=$$(bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; printf "%s" "$$SOPS_AGE_KEY_FILE"') || exit 1; \
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
			echo "$(GREEN)    Run 'sudo make key-health' to verify decryption integrity.$(NC)"; \
			exit 0; \
		else \
			echo "$(RED)  ✗ Key file NOT FOUND at $$CONFIGURED_KEY$(NC)"; \
			echo "$(RED)    Secrets have not been initialised on this host yet.$(NC)"; \
			echo "$(RED)    Run: sudo make init-secrets$(NC)"; \
			exit 1; \
		fi; \
	fi; \
	if [ -s "$$CONFIGURED_KEY" ]; then \
		echo "$(GREEN)  ✓ Key already present at $$CONFIGURED_KEY — no action needed.$(NC)"; \
		echo "$(GREEN)    Run 'sudo make key-health' to verify integrity.$(NC)"; \
		exit 0; \
	fi; \
	if [ ! -f "$$REPO_KEY" ]; then \
		echo "$(RED)ERROR: Source key not found at $$REPO_KEY$(NC)"; \
		echo "$(RED)       No key to install. Run: sudo ./setup.sh install --domain <domain> --email <email>$(NC)"; \
		exit 1; \
	fi; \
	TARGET_DIR=$$(dirname "$$CONFIGURED_KEY"); \
	echo "$(BLUE)  Creating parent directory: $$TARGET_DIR$(NC)"; \
	install -d -m 700 -o root -g root "$$TARGET_DIR"; \
	echo "$(BLUE)  Copying key to: $$CONFIGURED_KEY$(NC)"; \
	install -m 600 -o root -g root "$$REPO_KEY" "$$CONFIGURED_KEY"; \
	echo "$(GREEN)  ✓ Key installed at $$CONFIGURED_KEY (mode 600, root:root)$(NC)"; \
	echo ""
	@echo "$(BLUE)Verifying installation with key-health...$(NC)"
	@$(MAKE) key-health

key-show: ## Show current age public key and key file path/status
	$(call require-root)
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Status:$(NC)"
	@bash -c "source lib/log.sh; source lib/config.sh; source lib/common.sh; init_common_lib key-show; \
	         source lib/crypto.sh; \
	         load_project_environment >/dev/null 2>&1 || exit 1; \
	         KEY_FILE=\$$(resolve_age_key_path 2>/dev/null || true); \
	         if [[ -z \"\$$KEY_FILE\" ]]; then KEY_DISPLAY='<not resolved>'; else KEY_DISPLAY=\"\$$KEY_FILE\"; fi; \
	         echo \"  Key file : \$$KEY_DISPLAY\"; \
	         if [[ -n \"\$$KEY_FILE\" && -f \"\$$KEY_FILE\" ]]; then \
	           echo \"  Status   : $(GREEN)present$(NC)\"; \
	           echo \"  Perms    : \$$(stat -c '%a' \"\$$KEY_FILE\" 2>/dev/null || stat -f '%A' \"\$$KEY_FILE\" 2>/dev/null || echo unknown)\"; \
	           PUB=\$$(age-keygen -y \"\$$KEY_FILE\" 2>/dev/null || grep '# public key:' \"\$$KEY_FILE\" 2>/dev/null | awk '{print \$$NF}' || true); \
	           [ -n \"\$$PUB\" ] && echo \"  Public   : \$$PUB\" || echo \"  Public   : $(YELLOW)(not available)$(NC)\"; \
	           echo \"  Health   : use sudo make key-health for authoritative validation\"; \
	         else \
	           echo \"  Status   : $(RED)MISSING$(NC)\"; \
	           echo \"  Run: sudo make key-install\"; \
	         fi"

key-backup: ## Create local Age key copy for manual offline transfer
	$(call require-root)
	@echo "$(BLUE)Create local Age key copy for manual offline transfer$(NC)"
	@bash -c "source lib/log.sh; source lib/config.sh; source lib/common.sh; init_common_lib key-backup; \
	         source lib/crypto.sh; \
	         load_project_environment >/dev/null 2>&1 || exit 1; \
	         KEY_FILE=\$$(resolve_age_key_path) || exit 1; \
	         BACKUP_DEST=\"\$$HOME/age-key-backup-\$$(date +%Y%m%d-%H%M%S).txt\"; \
	         cp \"\$$KEY_FILE\" \"\$$BACKUP_DEST\"; \
	         chmod 600 \"\$$BACKUP_DEST\"; \
	         echo \"$(GREEN)Local key copy created at: \$$BACKUP_DEST$(NC)\"; \
	         echo \"$(YELLOW)NOT OFFLINE YET: move this copy to offline custody, verify it, then remove the local transfer copy.$(NC)\""

key-escrow: ## Generate password-manager Age key escrow file
	$(call require-root)
	@echo "$(BLUE)Age Key Escrow$(NC)"
	@bash -c "source lib/log.sh; source lib/config.sh; source lib/common.sh; init_common_lib startup.sh; \
	        source lib/crypto.sh; \
	        load_project_environment >/dev/null 2>&1 || exit 1; \
	        KEY_FILE=\$$(resolve_age_key_path) || exit 1; \
	        ESCROW_DEST=\"\$$HOME/age-key-escrow-\$$(date +%Y%m%d-%H%M%S).txt\"; \
	        AGE_KEY_FILE=\"\$$KEY_FILE\" create_password_manager_escrow \"\$$ESCROW_DEST\""

key-rotate: ## Rotate age encryption key (re-encrypts all secrets)
	$(call require-root)
	$(call check-env-readable)
	@./utilities/key-rotate.sh

# ===========================================================================
##@ Normal Admin + Advanced Admin — Updates
# ===========================================================================

update: ## Update all container images and restart
	$(call require-root)
	@echo "$(BLUE)Updating VaultWarden-OCI...$(NC)"
	@./maintenance.sh update --all

check-updates: ## Check for available container image updates (no restart)
	$(call check-docker)
	@echo "$(BLUE)Checking for container updates...$(NC)"
	@$(DOCKER_COMP) pull --dry-run 2>/dev/null || $(DOCKER_COMP) pull

update-system: ## Direct host OS package update (not full managed VaultWarden update)
	$(call require-root)
	@echo "$(BLUE)Updating host OS packages directly...$(NC)"
	@echo "$(YELLOW)This target runs the host package manager directly; it does not create a VaultWarden pre-update backup or run the managed Compose restart/health workflow.$(NC)"
	@echo "$(YELLOW)Host package updates may still restart system services or require a reboot.$(NC)"
	@echo "$(YELLOW)For the managed VaultWarden update workflow, use: sudo make update$(NC)"
	@./maintenance.sh update --system --skip-backup

update-dns: ## Update Cloudflare DNS records
	$(call require-root)
	@echo "$(BLUE)Updating DNS records...$(NC)"
	@./maintenance.sh update-dns

# ===========================================================================
##@ Normal Admin + Advanced Admin — Maintenance
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
##@ Normal Admin + Advanced Admin — Systemd Integration
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
	$(call require-root)
	@./setup.sh systemd status

systemd-validate: ## Validate systemd unit files
	$(call require-root)
	@echo "$(BLUE)Validating systemd units...$(NC)"
	@./setup.sh systemd validate

timers: ## Show scheduled systemd timer status
	@echo "$(BLUE)Scheduled Timers:$(NC)"
	@systemctl list-timers --all 2>/dev/null | grep -E "vaultwarden|ACTIVATES" || echo "  No vaultwarden timers found"

schedule: ## Show vaultwarden timer schedules (next/last run times)
	@echo "$(BLUE)VaultWarden Timer Schedules:$(NC)"
	@if systemctl list-timers 'vaultwarden-*' --no-pager 2>/dev/null | grep -q vaultwarden; then \
		systemctl list-timers 'vaultwarden-*' --no-pager 2>/dev/null; \
	elif systemctl list-timers --all --no-pager 2>/dev/null | grep -q vaultwarden; then \
		systemctl list-timers --all --no-pager 2>/dev/null | grep -E "vaultwarden|NEXT|LEFT|LAST|PASSED|UNIT|ACTIVATES"; \
	else \
		echo "  $(YELLOW)No vaultwarden timers found (systemd may not be running or units not installed)$(NC)"; \
		echo "  Run 'sudo make install-systemd' to install timer units."; \
	fi

# ===========================================================================
##@ Normal Admin — Break-Glass Admin
# ===========================================================================

breakglass-create: ## Create emergency break-glass admin account
	$(call require-root)
	@echo "$(BLUE)Creating break-glass admin account...$(NC)"
	@utilities/setup-secrets.sh breakglass create

breakglass-status: ## Check break-glass admin account status
	$(call require-root)
	@echo "$(BLUE)Break-glass admin status:$(NC)"
	@utilities/setup-secrets.sh breakglass status

breakglass-remove: ## Remove break-glass admin account
	$(call require-root)
	@echo "$(BLUE)Removing break-glass admin account...$(NC)"
	@utilities/setup-secrets.sh breakglass remove

# ===========================================================================
##@ Operator Validation + Development Utilities
# ===========================================================================

test-config: ## Validate docker-compose configuration
	$(call check-docker)
	@echo "$(BLUE)Validating docker-compose configuration...$(NC)"
	@$(DOCKER_COMP) config --quiet && echo "$(GREEN)Configuration is valid.$(NC)"

dry-run: ## Show what startup would do without executing
	@echo "$(BLUE)Startup dry run...$(NC)"
	@./startup.sh --dry-run

# ===========================================================================
##@ Normal Admin + Dashboard Stable API — Information & Diagnostics
# ===========================================================================

info: ## Show deployment information
	@echo "$(BLUE)VaultWarden-OCI Deployment Info:$(NC)"
	@echo ""
	@bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; \
		echo "  Config    : $$VW_CONFIG_SELECTED_ENV_FILE"; \
		echo "  Domain    : $${DOMAIN:-}"; \
		echo "  Admin     : $${ADMIN_EMAIL:-}"; \
		echo "  State Dir : $${PROJECT_STATE_DIR:-}"; \
		DATA_DEV=$${DATA_VOLUME_DEVICE:-}; \
		DATA_MNT=$${DATA_VOLUME_MOUNT:-}; \
		if [ -n "$$DATA_DEV" ]; then \
			MOUNTED=$$(mountpoint -q "$$DATA_MNT" 2>/dev/null && echo "$(GREEN)mounted$(NC)" || echo "$(RED)NOT MOUNTED$(NC)"); \
			echo "  Volume    : $$DATA_DEV → $$DATA_MNT  [$$MOUNTED]"; \
		else \
			echo "  Volume    : boot-only mode"; \
		fi'
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
	$(call require-root)
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
	@bash -c 'source lib/log.sh; source lib/config.sh; load_project_environment >/dev/null || exit 1; \
	STATE_DIR=$${PROJECT_STATE_DIR:?}; \
	DATA_DEV=$${DATA_VOLUME_DEVICE:-}; \
	DATA_MNT=$${DATA_VOLUME_MOUNT:-}; \
	echo "  Config    : $$VW_CONFIG_SELECTED_ENV_FILE"; \
	if [ -n "$$DATA_DEV" ]; then \
		echo "  Mode      : separate-volume ($$DATA_DEV → $$DATA_MNT)"; \
		mountpoint -q "$$DATA_MNT" 2>/dev/null \
			&& echo "  Mount     : $(GREEN)active$(NC)" \
			|| echo "  Mount     : $(RED)NOT MOUNTED$(NC)"; \
	else \
		echo "  Mode      : boot-only"; \
	fi; \
	df -h "$$STATE_DIR" 2>/dev/null || true'
	@echo ""
	@echo "$(CYAN)--- Key Health ---$(NC)"
	@$(MAKE) key-health 2>/dev/null || echo "key-health: failed"
	@echo ""
	@echo "$(CYAN)--- Recent Logs (last 20 lines each) ---$(NC)"
	@$(DOCKER_COMP) logs --tail=20 2>/dev/null || true

# ===========================================================================
##@ Advanced Admin — Cleanup
# ===========================================================================

clean: ## Remove generated files (logs, temp files)
	@echo "$(BLUE)Cleaning generated files...$(NC)"
	@rm -f setup.log
	@echo "$(GREEN)Clean complete.$(NC)"

# ===========================================================================
##@ Advanced Admin — ⚠ Destructive Operations
# ===========================================================================

clean-all: ## Remove generated logs/temp files — services will re-init runtime secrets on next start
	@echo "$(YELLOW)WARNING: This will remove generated logs/temp files.$(NC)"
	@echo "$(YELLOW)         Run 'sudo make up' afterwards to regenerate runtime secrets from secrets.yaml.$(NC)"
	@printf "Continue? [yes/no] (default: no): "; \
	read -r confirm; \
	if [ "$$confirm" = "yes" ]; then \
		rm -f setup.log; \
		echo "$(GREEN)Full clean complete.$(NC)"; \
	else \
		echo "Cancelled."; \
	fi

prune: ## Remove unused Docker resources (images, containers, networks) — cannot be undone
	$(call require-root)
	$(call check-docker)
	@# Allow dashboard.sh (which already confirmed) to bypass the interactive prompt.
	@# Direct terminal invocations still require explicit confirmation.
	@if [ "${DASHBOARD_CONFIRMED}" != "true" ]; then \
		if [ ! -t 0 ]; then \
			echo "$(RED)Error: 'make prune' requires an interactive terminal.$(NC)"; \
			echo "$(YELLOW)Re-run in a TTY: sudo make prune$(NC)"; \
			exit 1; \
		fi; \
		echo "$(YELLOW)WARNING: This will permanently remove unused Docker resources.$(NC)"; \
		printf "Continue? [yes/no] (default: no): "; \
		read -r confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled."; \
			exit 0; \
		fi; \
	fi
	@docker system prune -f
	@echo "$(GREEN)Prune complete.$(NC)"

uninstall: ## Remove VaultWarden-OCI, all data, secrets, and containers from this host
	$(call require-root)
	@echo "$(RED)WARNING: This will permanently remove VaultWarden-OCI from this system.$(NC)"
	@echo "$(RED)         All data, secrets, and containers will be deleted.$(NC)"
	@sudo utilities/uninstall-vaultwarden.sh run

uninstall-dry-run: ## Preview what uninstall would remove without making any changes
	@utilities/uninstall-vaultwarden.sh run --dry-run

# ===========================================================================
##@ Developer/Test — Documentation
# ===========================================================================

docs: ## Regenerate docs/COMMAND-REFERENCE.md from live script --help and Makefile targets
	@bash utilities/write-command-reference.sh

backup-manifest: ## Show what is included and excluded in a full/emergency backup
	@bash -c 'source utilities/backup-run.sh 2>/dev/null; print_backup_manifest'
