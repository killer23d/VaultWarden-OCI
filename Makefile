# ===========================================================================
# VaultWarden-OCI — Makefile
# ===========================================================================
#
# Targets
# -------
#   help                Show this help
#   setup               Full first-time setup (root)
#   dev-setup           Create .env + docker-compose.override.yml for dev
#   fix-permissions     Restore ownership after sudo leaves root-owned files
#   start               Start production services
#   stop                Stop services
#   restart             Restart services
#   status              Show container status
#   logs                Tail all service logs
#   ps                  Show running containers
#   update              Pull latest images and restart
#   update-check        Check for image updates (no pull)
#   backup              Manual backup
#   restore             Interactive restore wizard
#   backup-pull         Pull latest backup from remote
#   backup-push         Push latest backup to remote
#   backup-list         List available backups
#   backup-clean        Prune old backups
#   health              Run health checks
#   maintenance         Run maintenance tasks
#   test                Full test suite
#   test-config         Validate .env + docker-compose.yml
#   dry-run             Show what `make start` would do
#   fmt                 Format shell scripts with shfmt
#   lint / shellcheck   Run shellcheck on all shell scripts
#   init-secrets        Initialise secrets file (interactive)
#   edit-secrets        Edit encrypted secrets
#   test-secrets        Test SOPS decryption
#   rotate-secrets      Rotate encryption keys
#   key-install         Install age key to system location (root)
#   install-key-root    Alias for key-install (legacy)
#   key-health          Check age key health
#   key-show            Show age public key + path
#   key-backup          Back up age key to secure location
#   key-escrow          Generate encrypted escrow package
#   ssl-renew           Force TLS certificate renewal
#   ssl-status          Show TLS certificate status
#   fail2ban-status     Show fail2ban jail status
#   fail2ban-unban      Unban an IP  (IP=x.x.x.x)
#   fail2ban-reload     Reload fail2ban config
#   notify-test         Send a test notification
#   email-test          Alias for notify-test
#   smtp-test           Test SMTP connectivity
#   compose-validate    Validate docker-compose files
#   pre-flight-check    Run pre-flight checks
#   breakglass-admin    Create emergency admin account
#   check-domain        Validate domain DNS resolution
#   clean               Remove generated runtime files
#   prune               Remove stopped containers + dangling images
#   purge               Destroy all data (DESTRUCTIVE)
#   uninstall           Fully remove VaultWarden-OCI
# ===========================================================================

# --- Tool paths (override via environment if needed) ---
SOPS    ?= sops
DOCKER  ?= docker
COMPOSE ?= docker compose

# --- ANSI colour codes ---
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
CYAN   := \033[0;36m
NC     := \033[0m

# ---------------------------------------------------------------------------
# Internal macros
# ---------------------------------------------------------------------------

# require-root: abort unless running under sudo / as root.
define require-root
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "$(RED)ERROR: This target must be run as root (use: sudo make $@).$(NC)"; \
		exit 1; \
	fi
endef

# check-env-readable: abort unless .env exists and is readable.
define check-env-readable
	@if [ ! -f ".env" ]; then \
		echo "$(RED)ERROR: .env not found. Run: sudo make setup$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -r ".env" ]; then \
		echo "$(RED)ERROR: .env is not readable by $$(id -un).$(NC)"; \
		echo "$(YELLOW)Fix: sudo chown $$(id -un):$$(id -gn) .env$(NC)"; \
		exit 1; \
	fi
endef

# ---------------------------------------------------------------------------
# Phony declarations
# ---------------------------------------------------------------------------
.PHONY: help setup dev-setup start stop restart status logs ps \
        dev-setup fix-permissions test test-config dry-run fmt lint shellcheck \
        update update-check backup restore health maintenance \
        init-secrets edit-secrets test-secrets rotate-secrets \
        key-install key-health key-show key-backup key-escrow \
        install-key-root clean prune purge uninstall \
        breakglass-admin check-domain ssl-renew ssl-status \
        backup-pull backup-push backup-list backup-clean \
        notify-test email-test smtp-test \
        fail2ban-status fail2ban-unban fail2ban-reload \
        compose-validate pre-flight-check

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
help: ## Show this help message
	@echo ""
	@echo "$(CYAN)VaultWarden-OCI$(NC) — available make targets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------------------
# setup / dev-setup
# ---------------------------------------------------------------------------
setup: ## Full first-time setup (requires root)
	$(call require-root)
	@echo "$(BLUE)Running full setup…$(NC)"
	@./setup.sh

dev-setup: ## Set up development environment (.env + docker-compose.override.yml)
	$(call require-root)
	@echo "$(BLUE)Setting up development environment…$(NC)"
	@if [ ! -f ".env" ]; then \
		cp .env.example .env; \
		echo "$(YELLOW)Created .env from template — edit before starting.$(NC)"; \
	fi
	@if [ ! -f "docker-compose.override.yml" ]; then \
		cp docker-compose.override.dev.yml.example docker-compose.override.yml; \
		echo "$(YELLOW)Created development override file.$(NC)"; \
	fi

# ---------------------------------------------------------------------------
# fix-permissions
# ---------------------------------------------------------------------------
fix-permissions: ## Fix file ownership after sudo operations leave root-owned files
	$(call require-root)
	@echo "$(BLUE)Fixing file ownership…$(NC)"
	@REAL_USER=$$(logname 2>/dev/null || echo "$${SUDO_USER:-ubuntu}"); \
	REAL_GROUP=$$(id -gn "$$REAL_USER" 2>/dev/null || echo "$$REAL_USER"); \
	echo "$(CYAN)  Target user : $$REAL_USER:$$REAL_GROUP$(NC)"; \
	echo ""; \
	for item in \
	    CHANGELOG.md Makefile README.md VERSION \
	    backup.sh create-breakglass-admin.sh edit-secrets.sh health.sh \
	    maintenance.sh restore.sh setup-secrets.sh setup-systemd.sh \
	    setup.sh startup.sh uninstall-vaultwarden.sh update.sh \
	    backups caddy docs fail2ban lib logs ssl systemd \
	    docker-compose.yml.example docker-compose.override.yml.example \
	    .env.example .sops.yaml .gitattributes .gitignore; do \
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
	    echo "$(GREEN)  ✓ caddy/entrypoint.sh → executable$(NC)"; \
	fi; \
	echo ""; \
	echo "$(GREEN)File ownership fixed for user $$REAL_USER.$(NC)"; \
	echo "$(CYAN)Note: secrets/ and secrets/.docker_secrets/ are intentionally left restricted.$(NC)"

init-secrets: ## Initialize secrets file (interactive)
	@echo "$(BLUE)Initializing secrets…$(NC)"
	@if [ ! -f "secrets/secrets.yaml" ]; then \
		echo "$(BLUE)No secrets file found. Running setup-secrets.sh…$(NC)"; \
		./setup-secrets.sh; \
	else \
		echo "$(YELLOW)Secrets file already exists. Use 'make edit-secrets' to modify.$(NC)"; \
	fi

edit-secrets: ## Edit encrypted secrets file
	@echo "$(BLUE)Opening secrets editor…$(NC)"
	@./edit-secrets.sh

# FIX [P5-M2]: propagate failure exit code so `make test` fails correctly.
test-secrets: ## Test secrets decryption
	@echo "$(BLUE)Testing secrets decryption…$(NC)"
	@if ./edit-secrets.sh --list > /dev/null 2>&1; then \
		echo "$(GREEN)Secrets decryption: OK$(NC)"; \
	else \
		echo "$(RED)Secrets decryption: FAILED$(NC)"; \
		exit 1; \
	fi

rotate-secrets: ## Rotate encryption keys and re-encrypt secrets
	$(call require-root)
	@echo "$(BLUE)Rotating secrets…$(NC)"
	@./setup-secrets.sh --rotate

# ---------------------------------------------------------------------------
# Docker lifecycle
# ---------------------------------------------------------------------------

# ── Pre-flight: refuse to start with the dev-only override present ─────────
# docker-compose.override.yml is the local-development override.
# It MUST NOT be present in production — it exposes ports, disables TLS,
# and mounts source trees that do not exist on a production host.
# ────────────────────────────────────────────────────────────────────────────
start: ## Start all services (production)
	$(call check-env-readable)
	@if [ -f "docker-compose.override.yml" ]; then \
		echo "$(RED)ERROR: docker-compose.override.yml exists.$(NC)"; \
		echo "$(RED)       This file is for local development only and must not be used in production.$(NC)"; \
		echo "$(YELLOW)       Remove it: rm docker-compose.override.yml$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Starting VaultWarden services…$(NC)"
	@./startup.sh

stop: ## Stop all services
	@echo "$(BLUE)Stopping VaultWarden services…$(NC)"
	@$(COMPOSE) down

restart: ## Restart all services
	@echo "$(BLUE)Restarting VaultWarden services…$(NC)"
	@$(MAKE) stop
	@$(MAKE) start

status: ## Show service status
	@echo "$(BLUE)Service Status:$(NC)"
	@$(COMPOSE) ps

logs: ## Tail logs for all services (Ctrl-C to exit)
	@$(COMPOSE) logs -f

ps: ## Show running containers
	@$(DOCKER) ps --filter "label=com.docker.compose.project"

# ---------------------------------------------------------------------------
# test / lint
# ---------------------------------------------------------------------------
test: ## Run full test suite
	@echo "$(BLUE)Running tests…$(NC)"
	@$(MAKE) test-config
	@$(MAKE) test-secrets
	@$(MAKE) shellcheck
	@echo "$(GREEN)All tests passed.$(NC)"

test-config: ## Validate .env and docker-compose.yml
	$(call check-env-readable)
	@echo "$(BLUE)Validating configuration…$(NC)"
	@$(COMPOSE) config --quiet && echo "$(GREEN)docker-compose config: OK$(NC)"

dry-run: ## Show what 'make start' would do (no side effects)
	$(call check-env-readable)
	@echo "$(BLUE)Dry-run — services that would start:$(NC)"
	@$(COMPOSE) config --services

fmt: ## Format shell scripts with shfmt (if installed)
	@if command -v shfmt >/dev/null 2>&1; then \
		echo "$(BLUE)Formatting shell scripts…$(NC)"; \
		shfmt -w -i 4 -ci *.sh lib/*.sh; \
		echo "$(GREEN)Done.$(NC)"; \
	else \
		echo "$(YELLOW)shfmt not installed — skipping format$(NC)"; \
	fi

lint: shellcheck ## Alias for shellcheck

shellcheck: ## Run shellcheck on all shell scripts
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "$(BLUE)Running shellcheck…$(NC)"; \
		shellcheck -x *.sh lib/*.sh && echo "$(GREEN)shellcheck: OK$(NC)"; \
	else \
		echo "$(YELLOW)shellcheck not installed — skipping$(NC)"; \
	fi

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------
update: ## Pull latest images and restart services
	$(call require-root)
	@echo "$(BLUE)Updating VaultWarden…$(NC)"
	@./update.sh

update-check: ## Check for available image updates (no pull)
	@echo "$(BLUE)Checking for updates…$(NC)"
	@$(DOCKER) compose pull --dry-run 2>&1 | grep -E "Pulling|up to date" || true

# ---------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------
backup: ## Run a manual backup
	$(call require-root)
	@echo "$(BLUE)Running backup…$(NC)"
	@./backup.sh

restore: ## Run interactive restore wizard
	$(call require-root)
	@echo "$(BLUE)Starting restore wizard…$(NC)"
	@./restore.sh

backup-pull: ## Pull latest backup from remote storage
	$(call require-root)
	@echo "$(BLUE)Pulling backup from remote…$(NC)"
	@./backup.sh --pull

backup-push: ## Push latest backup to remote storage
	$(call require-root)
	@echo "$(BLUE)Pushing backup to remote…$(NC)"
	@./backup.sh --push

backup-list: ## List available backups
	@echo "$(BLUE)Available backups:$(NC)"
	@./backup.sh --list

backup-clean: ## Remove old backups beyond retention policy
	$(call require-root)
	@echo "$(BLUE)Cleaning old backups…$(NC)"
	@./backup.sh --clean

# ---------------------------------------------------------------------------
# health / maintenance
# ---------------------------------------------------------------------------
health: ## Run health checks
	$(call check-env-readable)
	@echo "$(BLUE)Running health checks…$(NC)"
	@./health.sh

maintenance: ## Run maintenance tasks (vacuum, integrity check, etc.)
	$(call require-root)
	@echo "$(BLUE)Running maintenance…$(NC)"
	@./maintenance.sh

# ---------------------------------------------------------------------------
# Age key management
# ---------------------------------------------------------------------------
key-install: ## Install age key from repo to system location (requires root)
	$(call require-root)
	@echo "$(BLUE)Age Key Installation$(NC)"
	@REPO_KEY=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	REPO_KEY=$${REPO_KEY:-secrets/keys/age-key.txt}; \
	CONFIGURED_KEY="$${REPO_KEY}"; \
	echo "  Source key : $$REPO_KEY"; \
	echo "  Target key : $$CONFIGURED_KEY"; \
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
	@echo "$(BLUE)Verifying installation with key-health…$(NC)"
	@$(MAKE) key-health

install-key-root: key-install ## Alias for key-install (legacy name)

key-health: ## Check age key health (permissions, decodability, SOPS_AGE_KEY_FILE)
	$(call check-env-readable)
	@echo "$(BLUE)Age Key Health$(NC)"
	@KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	OK=1; \
	if [ ! -f "$$KEY_FILE" ]; then \
		echo "$(RED)  ✗ Key file not found: $$KEY_FILE$(NC)"; \
		echo "$(YELLOW)    Run: sudo make key-install$(NC)"; \
		OK=0; \
	else \
		echo "$(GREEN)  ✓ Key file exists: $$KEY_FILE$(NC)"; \
		PERMS=$$(stat -c '%a' "$$KEY_FILE" 2>/dev/null || stat -f '%A' "$$KEY_FILE" 2>/dev/null); \
		if [ "$$PERMS" = "600" ]; then \
			echo "$(GREEN)  ✓ Permissions: $$PERMS$(NC)"; \
		else \
			echo "$(RED)  ✗ Permissions: $$PERMS (expected 600)$(NC)"; \
			echo "$(YELLOW)       sudo chown root:root /etc/vaultwarden /etc/vaultwarden/age-key.txt$(NC)"; \
			OK=0; \
		fi; \
		OWNER=$$(stat -c '%U:%G' "$$KEY_FILE" 2>/dev/null || stat -f '%Su:%Sg' "$$KEY_FILE" 2>/dev/null); \
		echo "  Owner      : $$OWNER"; \
		PUB=$$(grep '# public key:' "$$KEY_FILE" 2>/dev/null | awk '{print $$NF}'); \
		[ -n "$$PUB" ] && echo "  Public key : $$PUB" || echo "$(YELLOW)  ⚠ Public key comment not found in key file$(NC)"; \
		if ! grep -q '^AGE-SECRET-KEY-' "$$KEY_FILE" 2>/dev/null; then \
			echo "$(RED)  ✗ Key file does not contain a valid age secret key$(NC)"; \
			OK=0; \
		else \
			echo "$(GREEN)  ✓ Key format: OK$(NC)"; \
		fi; \
	fi; \
	if [ "$$OK" = "1" ]; then \
		echo ""; \
		echo "$(GREEN)Age key health: OK$(NC)"; \
	else \
		echo ""; \
		echo "$(RED)Age key health: FAILED$(NC)"; \
		exit 1; \
	fi

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
	@bash -c "source lib/common.sh; init_common_lib startup.sh; source lib/simple_key_resilience.sh; \
	          KEY_FILE=$$(grep '^SOPS_AGE_KEY_FILE=' .env 2>/dev/null | cut -d= -f2); \
	          KEY_FILE=$${KEY_FILE:-secrets/keys/age-key.txt}; \
	          create_key_escrow \"$$KEY_FILE\""

# ---------------------------------------------------------------------------
# SSL
# ---------------------------------------------------------------------------
ssl-renew: ## Force SSL certificate renewal
	$(call require-root)
	@echo "$(BLUE)Forcing SSL certificate renewal…$(NC)"
	@$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile --force

ssl-status: ## Show SSL certificate status
	@echo "$(BLUE)SSL Certificate Status:$(NC)"
	@$(COMPOSE) exec caddy caddy version 2>/dev/null || echo "Caddy not running"

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
fail2ban-status: ## Show fail2ban jail status
	@echo "$(BLUE)fail2ban Status:$(NC)"
	@$(COMPOSE) exec fail2ban fail2ban-client status 2>/dev/null || echo "fail2ban not running"

fail2ban-unban: ## Unban an IP (usage: make fail2ban-unban IP=1.2.3.4)
	$(call require-root)
	@if [ -z "$(IP)" ]; then echo "$(RED)ERROR: IP= required$(NC)"; exit 1; fi
	@$(COMPOSE) exec fail2ban fail2ban-client unban $(IP)

fail2ban-reload: ## Reload fail2ban configuration
	$(call require-root)
	@$(COMPOSE) exec fail2ban fail2ban-client reload

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
notify-test: ## Send a test notification
	$(call check-env-readable)
	@echo "$(BLUE)Sending test notification…$(NC)"
	@bash -c "source lib/common.sh; init_common_lib Makefile; send_notification_email 'VaultWarden Test' 'This is a test notification from make notify-test.'"

email-test: notify-test ## Alias for notify-test

smtp-test: ## Test SMTP connectivity only
	$(call check-env-readable)
	@echo "$(BLUE)Testing SMTP connectivity…$(NC)"
	@bash -c "source lib/common.sh; init_common_lib Makefile; source lib/email.sh; test_smtp_connectivity"

# ---------------------------------------------------------------------------
# compose / pre-flight
# ---------------------------------------------------------------------------
compose-validate: ## Validate docker-compose files without starting
	@echo "$(BLUE)Validating docker-compose configuration…$(NC)"
	@$(COMPOSE) config --quiet && echo "$(GREEN)Configuration valid.$(NC)"

pre-flight-check: ## Run pre-flight checks before starting services
	$(call check-env-readable)
	@echo "$(BLUE)Running pre-flight checks…$(NC)"
	@./startup.sh --preflight

# ---------------------------------------------------------------------------
# breakglass-admin
# ---------------------------------------------------------------------------
breakglass-admin: ## Create a break-glass admin account (emergency access)
	$(call require-root)
	@echo "$(BLUE)Creating break-glass admin account…$(NC)"
	@./create-breakglass-admin.sh

check-domain: ## Validate domain DNS resolution
	$(call check-env-readable)
	@echo "$(BLUE)Checking domain DNS…$(NC)"
	@DOMAIN=$$(grep '^DOMAIN=' .env 2>/dev/null | cut -d= -f2); \
	if [ -z "$$DOMAIN" ]; then echo "$(YELLOW)DOMAIN not set in .env$(NC)"; exit 0; fi; \
	echo "  Domain: $$DOMAIN"; \
	if host "$$DOMAIN" >/dev/null 2>&1; then \
		echo "$(GREEN)  ✓ DNS resolves$(NC)"; \
	else \
		echo "$(RED)  ✗ DNS resolution failed$(NC)"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# clean / prune / purge / uninstall
# ---------------------------------------------------------------------------
clean: ## Remove generated files (.env, docker-compose.yml, override)
	@echo "$(YELLOW)Removing generated files…$(NC)"
	@rm -f .env docker-compose.yml docker-compose.override.yml
	@echo "$(GREEN)Done.$(NC)"

prune: ## Remove stopped containers and dangling images
	$(call require-root)
	@echo "$(BLUE)Pruning Docker resources…$(NC)"
	@$(DOCKER) system prune -f

purge: ## Stop services, remove volumes and generated files (DESTRUCTIVE)
	$(call require-root)
	@echo "$(RED)WARNING: This will destroy all data. Press Ctrl-C to abort.$(NC)"
	@sleep 5
	@$(COMPOSE) down -v --remove-orphans
	@$(MAKE) clean

uninstall: ## Fully uninstall VaultWarden-OCI from this system
	$(call require-root)
	@echo "$(RED)WARNING: This will remove VaultWarden-OCI and all its data.$(NC)"
	@./uninstall-vaultwarden.sh
