#!/usr/bin/env bash
# cron-setup.sh - Install or remove cron jobs for VaultWarden health checks and maintenance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

source "$PROJECT_ROOT/lib/common.sh"
init_common_lib "$0"

ACTION="--install"  # --install or --remove
HEALTH_TIME="0 6 * * *"   # Default: every day at 06:00
MAINT_TIME="30 6 * * 0"   # Default: weekly maintenance Sunday 06:30
USER_NAME="${SUDO_USER:-$USER}"

show_help() {
  cat << 'EOF'
VaultWarden Cron Setup

USAGE:
  sudo ./cron-setup.sh [--install|--remove] [--health "CRON_EXPR"] [--maint "CRON_EXPR"]

OPTIONS:
  --install            Install/update cron jobs (default)
  --remove             Remove installed cron jobs
  --health "CRON"      Cron expression for health check (default: "0 6 * * *")
  --maint  "CRON"      Cron expression for maintenance (default: "30 6 * * 0")
  --help               Show this help

Installed cron jobs:
  - Health check: runs health.sh with comprehensive checks and email alerts
  - Maintenance: runs maintenance.sh standard cleanup weekly

Examples:
  sudo ./cron-setup.sh --install
  sudo ./cron-setup.sh --health "0 */6 * * *"   # every 6 hours
  sudo ./cron-setup.sh --remove
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install|--remove)
      ACTION="$1"; shift ;;
    --health)
      HEALTH_TIME="$2"; shift 2 ;;
    --maint)
      MAINT_TIME="$2"; shift 2 ;;
    --help)
      show_help; exit 0 ;;
    *)
      log_error "Unknown option: $1"; show_help; exit 1 ;;
  esac
done

# Ensure running as root to modify system crontab
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root (sudo)."
  exit 1
fi

install_cron() {
  log_info "Installing/updating VaultWarden cron jobs for user: $USER_NAME"

  # Current crontab for user
  local tmpfile
  tmpfile=$(mktemp)
  crontab -u "$USER_NAME" -l 2>/dev/null > "$tmpfile" || true

  # Remove existing VaultWarden entries
  sed -i '/# VAULTWARDEN-HEALTH/ d' "$t
