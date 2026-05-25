#!/usr/bin/env bash
# ===========================================================================
# dashboard.sh — VaultWarden-OCI Operations Dashboard
# AMTM-style interactive terminal menu for the VaultWarden-OCI deployment.
# ===========================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# ANSI color / style variables
# ---------------------------------------------------------------------------
INV="\033[7m"    # Reverse video  — header bar and Enter-anchor only
BLD="\033[1m"    # Bold           — section headers, important labels
CYN="\033[1;36m" # Cyan           — dividers and sub-headers
GRN="\033[1;32m" # Green          — healthy status, menu shortcut key
RED="\033[1;31m" # Red            — errors, destructive option keys
YLW="\033[1;33m" # Yellow         — warnings, non-fatal errors, prompts
NC="\033[0m"     # Reset

# ---------------------------------------------------------------------------
# Repository / environment constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# Read PROJECT_STATE_DIR from .env if present; fall back to default.
_read_env_var() {
    local var="$1" default="$2"
    if [[ -f "${REPO_ROOT}/.env" && -r "${REPO_ROOT}/.env" ]]; then
        local val
        val="$(grep -E "^${var}=" "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- | head -1 || true)"
        printf '%s' "${val:-${default}}"
    else
        printf '%s' "${default}"
    fi
}

STATE_DIR="$(_read_env_var PROJECT_STATE_DIR /var/lib/vaultwarden)"
BACKUP_DIR="$(_read_env_var BACKUP_DIR "${STATE_DIR}/backups")"

# Container names (must match docker-compose.yml)
CONTAINER_VW="vaultwarden_app"
CONTAINER_CADDY="vaultwarden_caddy"
CONTAINER_POSTFIX="vaultwarden_postfix"

# Pacific Time zone for all human-readable timestamps
TZ_DISPLAY="America/Vancouver"

# Divider line length
DIVIDER="--------------------------------------------------"

# ---------------------------------------------------------------------------
# State: current active menu
# ---------------------------------------------------------------------------
ACTIVE_MENU="main"

# ---------------------------------------------------------------------------
# Signal / cleanup trap
# ---------------------------------------------------------------------------
_cleanup() {
    printf "${NC}"
    echo ""
    echo -e "${GRN} Goodbye!${NC}"
    exit 0
}
trap '_cleanup' INT TERM

# ---------------------------------------------------------------------------
# Utility: convert epoch seconds to Pacific Time string
# ---------------------------------------------------------------------------
_epoch_to_pt() {
    local epoch="$1"
    TZ="${TZ_DISPLAY}" date -d "@${epoch}" '+%Y-%m-%d %H:%M PT' 2>/dev/null \
        || date -r "${epoch}" '+%Y-%m-%d %H:%M PT' 2>/dev/null \
        || echo "(unknown)"
}

# ---------------------------------------------------------------------------
# Utility: run a command, stream output, keep exit status, show anchor prompt
# ---------------------------------------------------------------------------
run_cmd() {
    local label="$1"; shift
    echo ""
    echo -e "${BLD} Running: ${label}${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"
    # Run with restored default IFS so child commands behave normally
    if (IFS=" "; "$@"); then
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${GRN} Command completed successfully.${NC}"
    else
        local rc=$?
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${YLW} Command exited with status ${rc}.${NC}"
    fi
    _press_enter
}

# ---------------------------------------------------------------------------
# Utility: run via sudo preserving set -e behaviour outside subshell
# ---------------------------------------------------------------------------
run_sudo_cmd() {
    local label="$1"; shift
    echo ""
    echo -e "${BLD} Running: ${label}${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"
    if (IFS=" "; sudo "$@"); then
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${GRN} Command completed successfully.${NC}"
    else
        local rc=$?
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${YLW} Command exited with status ${rc}.${NC}"
    fi
    _press_enter
}

# ---------------------------------------------------------------------------
# Utility: "Press Enter to return to the menu" anchor
# ---------------------------------------------------------------------------
_press_enter() {
    local _dummy
    echo ""
    echo -e "${INV} Press [Enter] to return to the menu... ${NC}"
    read -r _dummy
}

# ---------------------------------------------------------------------------
# Utility: warn on missing script
# ---------------------------------------------------------------------------
_check_script() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        echo -e "${YLW} Warning: ${path} not found — skipping.${NC}"
        _press_enter
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# draw_header
# ---------------------------------------------------------------------------
draw_header() {
    local now_pt
    now_pt="$(TZ="${TZ_DISPLAY}" date '+%Y-%m-%d %H:%M PT' 2>/dev/null || date '+%Y-%m-%d %H:%M')"
    echo -e "${INV} VaultWarden-OCI - Operations Dashboard              ${now_pt} ${NC}"
}

# ---------------------------------------------------------------------------
# draw_divider
# ---------------------------------------------------------------------------
draw_divider() {
    echo -e "${CYN}${DIVIDER}${NC}"
}

# ---------------------------------------------------------------------------
# _container_status  — print Running (green) or Stopped (red)
# ---------------------------------------------------------------------------
_container_status() {
    local name="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        printf "${GRN}Running${NC}"
    else
        printf "${RED}Stopped${NC}"
    fi
}

# ---------------------------------------------------------------------------
# draw_live_stats
# ---------------------------------------------------------------------------
draw_live_stats() {
    draw_divider

    # --- Stack Health ---
    local vw_stat caddy_stat pf_stat
    vw_stat="$(_container_status "${CONTAINER_VW}")"
    caddy_stat="$(_container_status "${CONTAINER_CADDY}")"
    pf_stat="$(_container_status "${CONTAINER_POSTFIX}")"
    echo -e " ${BLD}Stack:${NC}  VaultWarden ${vw_stat}  |  Caddy ${caddy_stat}  |  Postfix ${pf_stat}"

    # --- Disk Space ---
    local disk_info
    if [[ -d "${STATE_DIR}" ]]; then
        disk_info="$(df -h "${STATE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%s free of %s on %s", $4, $2, $6}')"
    else
        disk_info="(${STATE_DIR} not mounted)"
    fi
    echo -e " ${BLD}Disk:${NC}   ${disk_info}"

    # --- CrowdSec bans ---
    local ban_count ban_color
    if systemctl is-active crowdsec >/dev/null 2>&1; then
        ban_count="$(sudo cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l || echo 0)"
    else
        ban_count="N/A (CrowdSec inactive)"
    fi

    if [[ "${ban_count}" =~ ^[0-9]+$ ]]; then
        if (( ban_count == 0 )); then
            ban_color="${GRN}"
        elif (( ban_count < 20 )); then
            ban_color="${YLW}"
        else
            ban_color="${RED}"
        fi
        echo -e " ${BLD}CrowdSec bans:${NC}  ${ban_color}${ban_count}${NC}"
    else
        echo -e " ${BLD}CrowdSec bans:${NC}  ${YLW}${ban_count}${NC}"
    fi
    echo -e " ${BLD}CrowdSec metrics:${NC}  (open Security menu and select CrowdSec Metrics)"

    # --- Last Backup ---
    local last_backup_str
    local newest_age
    newest_age="$(find "${BACKUP_DIR}" -name "*.age" -type f 2>/dev/null | sort | tail -1 || true)"
    if [[ -n "${newest_age}" ]]; then
        local mtime
        mtime="$(stat -c '%Y' "${newest_age}" 2>/dev/null || stat -f '%m' "${newest_age}" 2>/dev/null || echo 0)"
        last_backup_str="$(_epoch_to_pt "${mtime}")"
    else
        last_backup_str="${YLW}No backups found${NC}"
    fi
    echo -e " ${BLD}Last backup:${NC}  ${last_backup_str}"

    # --- Email Queue ---
    local queue_count=0 queue_str
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_POSTFIX}"; then
        queue_count="$(docker exec "${CONTAINER_POSTFIX}" mailq 2>/dev/null | grep -c '^[0-9A-F]' || true)"
        queue_count="${queue_count:-0}"
    fi
    if [[ "${queue_count}" -eq 0 ]]; then
        queue_str="${GRN}Healthy${NC}"
    elif [[ "${queue_count}" -lt 5 ]]; then
        queue_str="${YLW}${queue_count} message(s) queued${NC}"
    else
        queue_str="${RED}${queue_count} message(s) queued${NC}"
    fi
    echo -e " ${BLD}Email Queue:${NC}  ${queue_str}"

    # --- Recent Auth Failures (last 1h) ---
    local auth_fails=0 auth_color
    local since_ts
    since_ts="$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "${CONTAINER_VW}|${CONTAINER_CADDY}"; then
        auth_fails="$(docker logs "${CONTAINER_VW}" --since "${since_ts}" 2>&1 \
            | grep -ciE 'invalid|fail' || true)"
        auth_fails="${auth_fails:-0}"
        local caddy_fails
        caddy_fails="$(docker logs "${CONTAINER_CADDY}" --since "${since_ts}" 2>&1 \
            | grep -ciE 'invalid|fail' || true)"
        caddy_fails="${caddy_fails:-0}"
        auth_fails=$(( auth_fails + caddy_fails ))
    fi
    if (( auth_fails == 0 )); then
        auth_color="${GRN}"
    elif (( auth_fails < 10 )); then
        auth_color="${YLW}"
    else
        auth_color="${RED}"
    fi
    echo -e " ${BLD}Recent Auth Fails (1h):${NC}  ${auth_color}${auth_fails}${NC}"

    draw_divider
}

# ===========================================================================
# MAIN MENU
# ===========================================================================
draw_main_menu() {
    echo -e " ${BLD}Main Menu${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Start/Restart Stack"
    echo -e "  [ ${GRN}2${NC} ] Stop Stack"
    echo -e "  [ ${GRN}3${NC} ] Quick Health Check"
    echo -e "  [ ${GRN}4${NC} ] View App Logs"
    echo -e "  [ ${GRN}d${NC} ] Full Diagnostic Dump"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Backup & Restore Menu"
    echo -e "  [ ${GRN}s${NC} ] Security & CrowdSec Menu"
    echo -e "  [ ${GRN}k${NC} ] Secrets & Key Management Menu"
    echo -e "  [ ${GRN}a${NC} ] Advanced & Maintenance Menu"
    echo -e "  [ ${GRN}i${NC} ] Identity, Email & Admin Menu"
    draw_divider
    echo -e "  [ ${RED}e${NC} ] Exit Dashboard"
    echo ""
}

handle_main_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            _check_script "${REPO_ROOT}/startup.sh" || return
            run_sudo_cmd "sudo ./startup.sh --force" \
                "${REPO_ROOT}/startup.sh" --force
            ;;
        2)
            run_cmd "make down" make -C "${REPO_ROOT}" down
            ;;
        3)
            _check_script "${REPO_ROOT}/maintenance.sh" || return
            run_sudo_cmd "sudo ./maintenance.sh health" \
                "${REPO_ROOT}/maintenance.sh" health
            ;;
        4)
            run_cmd "make logs-tail" make -C "${REPO_ROOT}" logs-tail
            ;;
        d)
            run_cmd "make diagnose" make -C "${REPO_ROOT}" diagnose
            ;;
        b) ACTIVE_MENU="backup"   ;;
        s) ACTIVE_MENU="security" ;;
        k) ACTIVE_MENU="secrets"  ;;
        a) ACTIVE_MENU="advanced" ;;
        i) ACTIVE_MENU="identity" ;;
        e)
            _cleanup
            ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# SUBMENU B — Backup & Restore
# ===========================================================================
draw_backup_menu() {
    echo -e " ${BLD}Backup & Restore${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Incremental DB Backup"
    echo -e "  [ ${GRN}2${NC} ] Full System Backup"
    echo -e "  [ ${GRN}3${NC} ] Interactive Restore"
    echo -e "  [ ${GRN}4${NC} ] Backup Status / Health"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}

handle_backup_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            _check_script "${REPO_ROOT}/backup.sh" || return
            run_sudo_cmd "sudo ./backup.sh run db" \
                "${REPO_ROOT}/backup.sh" run db
            ;;
        2)
            _check_script "${REPO_ROOT}/backup.sh" || return
            run_sudo_cmd "sudo ./backup.sh run full" \
                "${REPO_ROOT}/backup.sh" run full
            ;;
        3)
            _check_script "${REPO_ROOT}/restore.sh" || return
            run_sudo_cmd "sudo ./restore.sh interactive" \
                "${REPO_ROOT}/restore.sh" interactive
            ;;
        4)
            run_cmd "make backup-status" make -C "${REPO_ROOT}" backup-status
            ;;
        b) ACTIVE_MENU="main" ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# SUBMENU S — Security & CrowdSec
# ===========================================================================
draw_security_menu() {
    echo -e " ${BLD}Security & CrowdSec${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] View Active Bans"
    echo -e "  [ ${GRN}2${NC} ] Unban an IP"
    echo -e "  [ ${GRN}3${NC} ] View Security Report"
    echo -e "  [ ${GRN}4${NC} ] Tail CrowdSec Logs"
    echo -e "  [ ${GRN}5${NC} ] CrowdSec Metrics"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}

handle_security_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            echo ""
            echo -e "${BLD} Running: sudo cscli decisions list${NC}"
            draw_divider
            if sudo cscli decisions list; then
                echo -e "${GRN} Done.${NC}"
            else
                echo -e "${YLW} cscli exited with a non-zero status.${NC}"
            fi
            _press_enter
            ;;
        2)
            echo ""
            local ip_to_unban
            printf " Enter IP address to unban: "
            read -r ip_to_unban
            ip_to_unban="${ip_to_unban//[[:space:]]/}"
            if [[ -z "${ip_to_unban}" ]]; then
                echo -e "${YLW} No IP entered — operation cancelled.${NC}"
                _press_enter
                return
            fi
            echo ""
            echo -e "${BLD} Running: sudo cscli decisions delete --ip ${ip_to_unban}${NC}"
            draw_divider
            if sudo cscli decisions delete --ip "${ip_to_unban}"; then
                echo -e "${GRN} Unbanned: ${ip_to_unban}${NC}"
            else
                echo -e "${YLW} IP not found or cscli error.${NC}"
            fi
            _press_enter
            ;;
        3)
            run_cmd "make security-report" make -C "${REPO_ROOT}" security-report
            ;;
        4)
            run_cmd "make logs-crowdsec" make -C "${REPO_ROOT}" logs-crowdsec
            ;;
        5)
            run_sudo_cmd "sudo cscli metrics" \
                "${REPO_ROOT}/sudo cscli metrics"
            ;;
        b) ACTIVE_MENU="main" ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# SUBMENU K — Secrets & Key Management
# ===========================================================================
draw_secrets_menu() {
    echo -e " ${BLD}Secrets & Key Management${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Key Health Check"
    echo -e "  [ ${GRN}2${NC} ] Edit Secrets"
    echo -e "  [ ${GRN}3${NC} ] Generate Escrow Backup"
    echo -e "  [ ${GRN}4${NC} ] Breakglass Admin Status"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}

handle_secrets_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            run_cmd "make key-health" make -C "${REPO_ROOT}" key-health
            ;;
        2)
            local edit_sh="${REPO_ROOT}/utilities/secrets-edit.sh"
            _check_script "${edit_sh}" || return
            run_cmd "./utilities/secrets-edit.sh" "${edit_sh}"
            ;;
        3)
            run_cmd "make key-escrow" make -C "${REPO_ROOT}" key-escrow
            ;;
        4)
            run_cmd "make breakglass-status" make -C "${REPO_ROOT}" breakglass-status
            ;;
        b) ACTIVE_MENU="main" ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# SUBMENU A — Advanced & Maintenance
# ===========================================================================
draw_advanced_menu() {
    echo -e " ${BLD}Advanced & Maintenance${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Export Recovery Kit"
    echo -e "  [ ${GRN}2${NC} ] Update Stack Images"
    echo -e "  [ ${GRN}3${NC} ] Database Maintenance / Vacuum"
    echo -e "  [ ${GRN}4${NC} ] Fix File Permissions"
    echo -e "  [ ${GRN}5${NC} ] Systemd Timer Status"
    echo -e "  [ ${GRN}6${NC} ] Prune Docker Resources"
    echo -e "  [ ${RED}7${NC} ] Uninstall VaultWarden-OCI"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}

handle_advanced_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            local kit_sh="${REPO_ROOT}/utilities/secrets-export-recovery-kit.sh"
            _check_script "${kit_sh}" || return
            run_cmd "./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"
            ;;
        2)
            run_cmd "make update" make -C "${REPO_ROOT}" update
            ;;
        3)
            run_cmd "make db-maint" make -C "${REPO_ROOT}" db-maint
            ;;
        4)
            run_cmd "make fix-permissions" make -C "${REPO_ROOT}" fix-permissions
            ;;
        5)
            run_cmd "make systemd-status" make -C "${REPO_ROOT}" systemd-status
            ;;
        6)
            run_cmd "make prune" make -C "${REPO_ROOT}" prune
            ;;
        7)
            # Destructive — require explicit confirmation
            echo ""
            echo -e "${RED}${BLD} !! DESTRUCTIVE OPERATION !!${NC}"
            echo -e "${YLW} This will UNINSTALL VaultWarden-OCI from this host.${NC}"
            echo -e "${YLW} All services, data, and configuration will be removed.${NC}"
            echo ""
            local confirm
            printf " Type YES to confirm uninstall, or anything else to cancel: "
            read -r confirm
            if [[ "${confirm}" == "YES" ]]; then
                run_cmd "make uninstall" make -C "${REPO_ROOT}" uninstall
            else
                echo -e "${YLW} Uninstall cancelled.${NC}"
                _press_enter
            fi
            ;;
        b) ACTIVE_MENU="main" ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# SUBMENU I — Identity, Email & Admin
# ===========================================================================
draw_identity_menu() {
    echo -e " ${BLD}Identity, Email & Admin${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Test SMTP Delivery"
    echo -e "  [ ${GRN}2${NC} ] Tail Auth & Access Drops"
    echo -e "  [ ${GRN}3${NC} ] Rotate Vault Admin Token"
    echo -e "  [ ${GRN}4${NC} ] View Breakglass Status"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}

handle_identity_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            run_cmd "make test-email" make -C "${REPO_ROOT}" test-email
            ;;
        2)
            echo ""
            echo -e "${BLD} Running: docker logs ${CONTAINER_CADDY} | grep 401|403|rate (last 20)${NC}"
            draw_divider
            docker logs "${CONTAINER_CADDY}" 2>&1 \
                | grep -iE "401|403|rate" \
                | tail -20 \
                || true
            _press_enter
            ;;
        3)
            local rot_sh="${REPO_ROOT}/utilities/secrets-rotate.sh"
            _check_script "${rot_sh}" || return
            run_cmd "./utilities/secrets-rotate.sh admin_token" \
                "${rot_sh}" admin_token
            ;;
        4)
            run_cmd "make breakglass-status" make -C "${REPO_ROOT}" breakglass-status
            ;;
        b) ACTIVE_MENU="main" ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
}

# ===========================================================================
# Main event loop
# ===========================================================================
main() {
    # Root guard: several operations require sudo; ensure we are running as root.
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED} Error:${NC} This script must be run as root." >&2
        echo -e " Re-run with: ${BLD}sudo $0${NC}" >&2
        exit 1
    fi

    # Ensure we're running from the repo root so relative paths / make work.
    cd "${REPO_ROOT}"

    while true; do
        clear
        draw_header
        draw_live_stats

        case "${ACTIVE_MENU}" in
            main)     draw_main_menu     ;;
            backup)   draw_backup_menu   ;;
            security) draw_security_menu ;;
            secrets)  draw_secrets_menu  ;;
            advanced) draw_advanced_menu ;;
            identity) draw_identity_menu ;;
            *)
                ACTIVE_MENU="main"
                draw_main_menu
                ;;
        esac

        local opt
        read -r -p " Enter option  : " opt
        # Normalize: trim whitespace, convert to lowercase
        opt="${opt//[[:space:]]/}"
        opt="${opt,,}"

        case "${ACTIVE_MENU}" in
            main)     handle_main_menu     "${opt}" ;;
            backup)   handle_backup_menu   "${opt}" ;;
            security) handle_security_menu "${opt}" ;;
            secrets)  handle_secrets_menu  "${opt}" ;;
            advanced) handle_advanced_menu "${opt}" ;;
            identity) handle_identity_menu "${opt}" ;;
        esac
    done
}

main "$@"
