#!/usr/bin/env bash
# ===========================================================================
# dashboard.sh — VaultWarden-OCI Operations Dashboard
# AMTM-style interactive terminal menu for the VaultWarden-OCI deployment.
# ===========================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Repository / environment constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/common.sh"
init_common_lib "$0"
[[ -f "${REPO_ROOT}/lib/validate.sh" ]] && source "${REPO_ROOT}/lib/validate.sh"

# ---------------------------------------------------------------------------
# Color / style aliases
# ---------------------------------------------------------------------------
INV="${COLOR_INVERT}"
BLD="${COLOR_BOLD}"
CYN="${COLOR_CYAN}"
GRN="${COLOR_GREEN}"
RED="${COLOR_RED}"
YLW="${COLOR_YELLOW}"
NC="${COLOR_RESET}"

# Read a single variable from .env without sourcing the whole file.
_read_env_var() {
    local var="$1" default="$2"
    if [[ -f "${REPO_ROOT}/.env" && -r "${REPO_ROOT}/.env" ]]; then
        local val
        val="$(grep -E "^${var}=" "${REPO_ROOT}/.env" 2>/dev/null \
            | cut -d= -f2- | head -1 || true)"
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

# Dashboard timestamps: read TZ from .env (ux.md #4), default UTC.
TZ_DISPLAY="$(_read_env_var TZ "UTC")"

# Divider line
DIVIDER="--------------------------------------------------"

# ---------------------------------------------------------------------------
# State: current active menu
# ---------------------------------------------------------------------------
ACTIVE_MENU="main"

# ---------------------------------------------------------------------------
# Signal / cleanup trap
# ---------------------------------------------------------------------------
_cleanup() {
    printf '%s' "${NC}"
    echo ""
    echo -e "${GRN} Goodbye!${NC}"
    exit 0
}
trap '_cleanup' INT TERM

# ---------------------------------------------------------------------------
# Utility: convert epoch seconds to a timezone-aware timestamp string
# ---------------------------------------------------------------------------
_epoch_to_pt() {
    local epoch="$1"
    TZ="${TZ_DISPLAY}" date -d "@${epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || TZ="${TZ_DISPLAY}" date -r "${epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || echo "(unknown)"
}

# ---------------------------------------------------------------------------
# Utility: run a command, stream output, show result, prompt to continue
# ---------------------------------------------------------------------------
run_cmd() {
    local label="$1"; shift
    echo ""
    echo -e "${BLD} Running: ${label}${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"
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
# Utility: reverse-video "Press Enter" anchor
# ---------------------------------------------------------------------------
_press_enter() {
    echo ""
    press_enter_to_continue " Press [Enter] to return to the menu..."
}

# ---------------------------------------------------------------------------
# Utility: confirm before a destructive action
#
# Uses tr '[:upper:]' '[:lower:]' for case-folding instead of ${answer,,}
# to remain POSIX-portable across all bash versions and OCI image locales.
# ---------------------------------------------------------------------------
_confirm_destructive() {
    local action="$1"
    local answer answer_lc
    echo ""
    echo -e "${RED}${BLD}Caution:${NC} ${YLW}${action}${NC}"
    printf " Are you sure? [y/N]: "
    read -r answer
    answer_lc="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    [[ "${answer_lc}" == "y" || "${answer_lc}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# show_help — printed when --help / -h is passed
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
VaultWarden-OCI Operations Dashboard

USAGE:
    sudo ./dashboard.sh [OPTIONS]

DESCRIPTION:
    AMTM-style interactive terminal dashboard for VaultWarden-OCI. Displays
    live stack health, disk usage, CrowdSec bans, backup status, and email
    queue at a glance. Provides submenus for backup, security, secrets, and
    advanced operations. Auto-refreshes every 60 seconds.

OPTIONS:
    --help, -h    Show this help and exit
    --version, -V Print the VaultWarden-OCI version and exit

KEYBOARD SHORTCUTS:
    e/q           Exit dashboard
    b/s/k/a/i     Open Backup, Security, Secrets, Advanced, or Identity menus

EXAMPLES:
    sudo ./dashboard.sh          # Launch dashboard
    ./dashboard.sh --help        # Show this help
EOF
}

# ---------------------------------------------------------------------------
# _show_changelog  (ux.md #44)
#
# Reads CHANGELOG.md and pretty-prints every line under the first
# "## [Unreleased]" heading until the next "## [" heading.
# Category headers (### Added / ### Changed / ### Fixed) are coloured.
# Exits cleanly when CHANGELOG.md is absent.
# ---------------------------------------------------------------------------
_show_changelog() {
    local changelog="${REPO_ROOT}/CHANGELOG.md"

    if [[ ! -f "${changelog}" ]]; then
        echo -e "${YLW} CHANGELOG.md not found in ${REPO_ROOT}${NC}"
        return 0
    fi

    # Extract lines between first "## [Unreleased]" and the next "## [" block.
    local in_section=false
    local printed=false
    local line

    echo ""
    echo -e "${INV} CHANGELOG — What's New ${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"

    while IFS= read -r line; do
        # Detect start of Unreleased section
        if [[ "${line}" =~ ^##[[:space:]]\[Unreleased\] ]]; then
            in_section=true
            continue
        fi

        # Detect start of the next versioned section — stop
        if [[ "${in_section}" == true && "${line}" =~ ^##[[:space:]]\[ ]]; then
            break
        fi

        [[ "${in_section}" != true ]] && continue

        # Colour-code category headers
        if [[ "${line}" =~ ^###[[:space:]]Added ]]; then
            echo -e "${GRN}${line}${NC}"
            printed=true
        elif [[ "${line}" =~ ^###[[:space:]]Changed ]]; then
            echo -e "${YLW}${line}${NC}"
            printed=true
        elif [[ "${line}" =~ ^###[[:space:]]Fixed ]]; then
            echo -e "${CYN}${line}${NC}"
            printed=true
        elif [[ "${line}" =~ ^###[[:space:]] ]]; then
            # Any other ### heading — bold white
            echo -e "${BLD}${line}${NC}"
            printed=true
        else
            echo "${line}"
            [[ -n "${line// /}" ]] && printed=true
        fi
    done < "${changelog}"

    if [[ "${printed}" != true ]]; then
        echo -e "${YLW} (No unreleased changes documented yet)${NC}"
    fi

    echo -e "${CYN}${DIVIDER}${NC}"
}

# ---------------------------------------------------------------------------
# _show_changelog_on_update  (ux.md #44)
#
# Called automatically after a successful stack update (Advanced menu
# option 2).  Shows the changelog and pauses so the operator can read it.
# ---------------------------------------------------------------------------
_show_changelog_on_update() {
    echo ""
    echo -e "${GRN}${BLD} Update complete.${NC} Here is what changed in this release:"
    _show_changelog
    _press_enter
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
    local now_pt version
    now_pt="$(TZ="${TZ_DISPLAY}" date '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || date '+%Y-%m-%d %H:%M')"
    version="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null | tr -d '[:space:]' \
        || echo '?')"
    echo -e "${INV} VaultWarden-OCI v${version} — Operations Dashboard   ${now_pt} ${NC}"
}

# ---------------------------------------------------------------------------
# draw_divider
# ---------------------------------------------------------------------------
draw_divider() {
    echo -e "${CYN}${DIVIDER}${NC}"
}

# ---------------------------------------------------------------------------
# _container_status_plain  — plain text Running / Stopped (no color codes)
# _container_status        — color-coded Running / Stopped
# ---------------------------------------------------------------------------
_container_status_plain() {
    local name="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        printf 'Running'
    else
        printf 'Stopped'
    fi
}

_container_status() {
    local status
    status="$(_container_status_plain "$1")"
    if [[ "${status}" == "Running" ]]; then
        printf "${GRN}Running${NC}"
    else
        printf "${RED}Stopped${NC}"
    fi
}

# ---------------------------------------------------------------------------
# _container_uptime  — "Xd Yh" / "Xh Ym" / "Xm" uptime string (ux.md #47)
#
# Docker's {{.State.StartedAt}} returns RFC 3339 with nanoseconds, e.g.
#   2026-06-01T12:00:00.123456789Z
# Both the GNU 'date -d' and BSD 'date -j' paths strip the fractional-second
# component before parsing to avoid silent failures on older glibc/coreutils.
# ---------------------------------------------------------------------------
_container_uptime() {
    local container="$1"
    local started_at started_at_clean start_epoch now_epoch delta days hours mins

    started_at=$(docker inspect --format '{{.State.StartedAt}}' \
        "${container}" 2>/dev/null) || { printf 'unknown'; return; }

    # Strip nanoseconds: "2026-06-01T12:00:00.123456789Z" -> "2026-06-01T12:00:00Z"
    started_at_clean="${started_at%%.*}Z"

    start_epoch=$(date -d "${started_at_clean}" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${started_at_clean}" +%s 2>/dev/null \
        || echo 0)

    [[ "${start_epoch}" =~ ^[0-9]+$ && "${start_epoch}" -gt 0 ]] \
        || { printf 'unknown'; return; }

    now_epoch=$(date +%s)
    delta=$(( now_epoch - start_epoch ))
    (( delta < 0 )) && delta=0

    days=$(( delta / 86400 ))
    hours=$(( (delta % 86400) / 3600 ))
    mins=$(( (delta % 3600) / 60 ))

    if   (( days  > 0 )); then printf '%dd %dh' "${days}"  "${hours}"
    elif (( hours > 0 )); then printf '%dh %dm' "${hours}" "${mins}"
    else                       printf '%dm'     "${mins}"
    fi
}

# ---------------------------------------------------------------------------
# _crowdsec_status  — Running (green) / Stopped (red) via systemd
# ---------------------------------------------------------------------------
_crowdsec_status() {
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        printf "${GRN}Running${NC}"
    else
        printf "${RED}Stopped${NC}"
    fi
}

# ---------------------------------------------------------------------------
# _cf_worker_status  — Running (green) / Stopped (red) via systemd
# ---------------------------------------------------------------------------
_cf_worker_status() {
    if systemctl is-active --quiet \
            crowdsec-cloudflare-worker-bouncer.service 2>/dev/null; then
        printf "${GRN}Running${NC}"
    else
        printf "${RED}Stopped${NC}"
    fi
}

# ---------------------------------------------------------------------------
# _secrets_health  (ux.md #23)
#
# Scans .env for CHANGE_ME / CHANGEME placeholder values and returns a
# single color-coded status string.
#
# Uses 'tr [:lower:] [:upper:]' for case-folding instead of ${val^^} to
# remain portable across all bash versions (${^^} requires Bash 4.0+, which
# is unavailable on macOS / some minimal OCI base images).  The rest of this
# script already uses tr for the same reason (_confirm_destructive, main loop).
# ---------------------------------------------------------------------------
_secrets_health() {
    local env_file="${REPO_ROOT}/.env"

    if [[ ! -f "${env_file}" || ! -r "${env_file}" ]]; then
        printf "${RED}Secrets file missing (.env)${NC}"
        return
    fi

    local -a unset_keys=()
    local key val val_upper
    while IFS='=' read -r key val; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// /}" ]] && continue
        val_upper="$(printf '%s' "${val}" | tr '[:lower:]' '[:upper:]')"
        if [[ "${val_upper}" == *CHANGE_ME* || "${val_upper}" == *CHANGEME* ]]; then
            unset_keys+=("${key}")
        fi
    done < <(grep -v '^[[:space:]]*#' "${env_file}" | grep '=')

    local count=${#unset_keys[@]}
    if   (( count == 0 )); then
        printf "${GRN}All secrets configured${NC}"
    elif (( count == 1 )); then
        printf "${YLW}1 secret needs attention: %s${NC}" "${unset_keys[0]}"
    elif (( count <= 4 )); then
        printf "${YLW}%d secrets need attention: %s${NC}" \
            "${count}" "${unset_keys[*]}"
    else
        printf "${YLW}%d secrets need attention — run: grep CHANGE_ME .env${NC}" \
            "${count}"
    fi
}

# ---------------------------------------------------------------------------
# draw_live_stats
# ---------------------------------------------------------------------------
draw_live_stats() {
    draw_divider

    # --- Stack Health ---
    local vw_stat caddy_stat pf_stat vw_plain vw_uptime=""
    vw_stat="$(_container_status "${CONTAINER_VW}")"
    caddy_stat="$(_container_status "${CONTAINER_CADDY}")"
    pf_stat="$(_container_status "${CONTAINER_POSTFIX}")"
    vw_plain="$(_container_status_plain "${CONTAINER_VW}")"
    [[ "${vw_plain}" == "Running" ]] \
        && vw_uptime=" (up $(_container_uptime "${CONTAINER_VW}"))"
    echo -e " ${BLD}Stack:${NC}  VaultWarden ${vw_stat}${vw_uptime}  |  Caddy ${caddy_stat}  |  Postfix ${pf_stat}"

    # --- Disk Space ---
    local disk_info
    if [[ -d "${STATE_DIR}" ]]; then
        disk_info="$(df -h "${STATE_DIR}" 2>/dev/null \
            | awk 'NR==2 {printf "%s free of %s on %s", $4, $2, $6}')"
    else
        disk_info="(${STATE_DIR} not mounted)"
    fi
    echo -e " ${BLD}Disk:${NC}   ${disk_info}"

    # --- CrowdSec bans ---
    local ban_count ban_color
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        ban_count="$(sudo cscli decisions list -o raw 2>/dev/null \
            | tail -n +2 | wc -l || echo 0)"
    else
        ban_count="N/A (CrowdSec inactive)"
    fi

    if [[ "${ban_count}" =~ ^[0-9]+$ ]]; then
        if   (( ban_count == 0 )); then ban_color="${GRN}"
        elif (( ban_count <  20 )); then ban_color="${YLW}"
        else                            ban_color="${RED}"
        fi
        echo -e " ${BLD}CrowdSec bans:${NC}  ${ban_color}${ban_count}${NC}"
    else
        echo -e " ${BLD}CrowdSec bans:${NC}  ${YLW}${ban_count}${NC}"
    fi

    # --- CrowdSec + CF Worker status ---
    local cs_stat cf_stat
    cs_stat="$(_crowdsec_status)"
    cf_stat="$(_cf_worker_status)"
    echo -e " ${BLD}CrowdSec status:${NC}  ${cs_stat}"
    echo -e " ${BLD}CF Worker status:${NC}  ${cf_stat}"

    # --- Secrets Health (ux.md #23) ---
    local secrets_stat
    secrets_stat="$(_secrets_health)"
    echo -e " ${BLD}Secrets health:${NC}   ${secrets_stat}"

    # --- Last Backup ---
    local last_backup_str newest_age
    newest_age="$(find "${BACKUP_DIR}" -name '*.age' -type f 2>/dev/null \
        | sort | tail -1 || true)"
    if [[ -n "${newest_age}" ]]; then
        local mtime
        mtime="$(stat -c '%Y' "${newest_age}" 2>/dev/null \
            || stat -f '%m' "${newest_age}" 2>/dev/null || echo 0)"
        last_backup_str="$(_epoch_to_pt "${mtime}")"
    else
        last_backup_str="${YLW}No backups found${NC}"
    fi
    echo -e " ${BLD}Last backup:${NC}  ${last_backup_str}"

    # --- Last Backup Result (ux.md #12) ---
    local _last_result _result_color
    _last_result=$(grep -oE '(PASS|FAIL|ERROR|SUCCESS)' \
        "${STATE_DIR}/logs/backup.log" 2>/dev/null | tail -1 || true)
    _last_result="${_last_result:-UNKNOWN}"
    case "${_last_result}" in
        PASS|SUCCESS) _result_color="${GRN}" ;;
        FAIL|ERROR)   _result_color="${RED}" ;;
        *)            _result_color="${YLW}" ;;
    esac
    echo -e " ${BLD}Last backup result:${NC}  ${_result_color}${_last_result}${NC}"

    # --- Systemd Timers ---
    local _timer_output
    _timer_output=$(systemctl list-timers --no-pager 2>/dev/null \
        | grep vaultwarden || true)
    if [[ -n "${_timer_output}" ]]; then
        echo -e " ${BLD}Timers:${NC}"
        printf '%s\n' "${_timer_output}" \
            | awk '{printf "    %-40s → %s %s\n", $NF, $1, $2}'
    else
        echo -e " ${BLD}Timers:${NC}  ${YLW}(systemd not available)${NC}"
    fi

    # --- Email Queue ---
    local queue_count=0 queue_str
    if docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -qx "${CONTAINER_POSTFIX}"; then
        queue_count="$(docker exec "${CONTAINER_POSTFIX}" mailq 2>/dev/null \
            | grep -c '^[0-9A-F]' || true)"
        queue_count="${queue_count:-0}"
    fi
    if   [[ "${queue_count}" -eq 0 ]]; then
        queue_str="${GRN}Healthy${NC}"
    elif [[ "${queue_count}" -lt 5 ]]; then
        queue_str="${YLW}${queue_count} message(s) queued${NC}"
    else
        queue_str="${RED}${queue_count} message(s) queued${NC}"
    fi
    echo -e " ${BLD}Email Queue:${NC}  ${queue_str}"

    # --- Recent Auth Failures (last 1h) ---
    local auth_fails=0 auth_color since_ts
    since_ts="$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
        || date -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
    if docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -qE "${CONTAINER_VW}|${CONTAINER_CADDY}"; then
        auth_fails="$(docker logs "${CONTAINER_VW}" --since "${since_ts}" \
            2>&1 | grep -ciE 'invalid|fail' || true)"
        auth_fails="${auth_fails:-0}"
        local caddy_fails
        caddy_fails="$(docker logs "${CONTAINER_CADDY}" --since "${since_ts}" \
            2>&1 | grep -ciE 'invalid|fail' || true)"
        caddy_fails="${caddy_fails:-0}"
        auth_fails=$(( auth_fails + caddy_fails ))
    fi
    if   (( auth_fails ==  0 )); then auth_color="${GRN}"
    elif (( auth_fails <  10 )); then auth_color="${YLW}"
    else                              auth_color="${RED}"
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
    echo -e "  [ ${GRN}1${NC} ] Start/Restart Stack     (safe)"
    echo -e "  [ ${RED}2${NC} ] Stop Stack              (destructive)"
    echo -e "  [ ${GRN}3${NC} ] Quick Health Check      (status)"
    echo -e "  [ ${GRN}4${NC} ] View App Logs           (tail)"
    echo -e "  [ ${GRN}d${NC} ] Full Diagnostic Dump    (report)"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Backup & Restore Menu       (4 options)"
    echo -e "  [ ${GRN}s${NC} ] Security & CrowdSec Menu    (5 options)"
    echo -e "  [ ${GRN}k${NC} ] Secrets & Key Management    (4 options)"
    echo -e "  [ ${GRN}a${NC} ] Advanced & Maintenance      (8 options)"
    echo -e "  [ ${GRN}i${NC} ] Identity, Email & Admin     (4 options)"
    draw_divider
    echo -e "  [ ${RED}e/q${NC} ] Exit Dashboard"
    echo ""
    echo -e " ${CYN}Tip:${NC} Use e/q to exit, b/s/k/a/i for submenus, Ctrl-C anytime."
    echo ""
}

handle_main_menu() {
    local opt="$1"
    case "${opt}" in
        1)
            _check_script "${REPO_ROOT}/startup.sh" || return
            run_sudo_cmd "sudo ./startup.sh --force" \
                "${REPO_ROOT}/startup.sh" --force
            # Force live-stats redraw so container state is fresh (ux.md #3).
            ACTIVE_MENU="main"
            ;;
        2)
            if _confirm_destructive "Stop all VaultWarden services"; then
                run_cmd "make down" make -C "${REPO_ROOT}" down
                # Force live-stats redraw so container state is fresh (ux.md #3).
                ACTIVE_MENU="main"
            else
                echo -e "${YLW} Operation cancelled.${NC}"
                sleep 1
            fi
            ;;
        3)
            _check_script "${REPO_ROOT}/maintenance.sh" || return
            run_sudo_cmd "sudo ./maintenance.sh health" \
                "${REPO_ROOT}/maintenance.sh" health
            ;;
        4)
            # Subshell + INT trap: Ctrl-C stops the tail, returns to menu (ux.md #33).
            local _log_container="${CONTAINER_VW}"
            local _log_lines=100
            echo ""
            echo -e "${BLD} Tailing logs for ${_log_container} (Ctrl+C to return to menu)${NC}"
            echo -e "${CYN}${DIVIDER}${NC}"
            ( trap 'exit 0' INT
              docker logs --tail "${_log_lines}" --follow \
                  "${_log_container}" 2>&1 ) || true
            echo -e "${CYN}${DIVIDER}${NC}"
            _press_enter
            ;;
        d)
            run_cmd "make diagnose" make -C "${REPO_ROOT}" diagnose
            ;;
        b) ACTIVE_MENU="backup"   ;;
        s) ACTIVE_MENU="security" ;;
        k) ACTIVE_MENU="secrets"  ;;
        a) ACTIVE_MENU="advanced" ;;
        i) ACTIVE_MENU="identity" ;;
        e|q) _cleanup ;;
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
    echo -e " ${CYN}Tip:${NC} Use b to return to Main Menu, e/q to exit, Ctrl-C anytime."
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
        e|q) _cleanup ;;
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
    echo -e " ${CYN}Tip:${NC} Use b to return to Main Menu, e/q to exit, Ctrl-C anytime."
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
            if ! validate_ip "${ip_to_unban}" 2>/dev/null; then
                echo -e "${RED} Invalid IP address format: '${ip_to_unban}'${NC}"
                echo -e "${YLW} Expected dotted-quad IPv4, for example 192.0.2.10${NC}"
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
            run_sudo_cmd "sudo cscli metrics" cscli metrics
            ;;
        b) ACTIVE_MENU="main" ;;
        e|q) _cleanup ;;
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
    echo -e " ${CYN}Tip:${NC} Use b to return to Main Menu, e/q to exit, Ctrl-C anytime."
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
        e|q) _cleanup ;;
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
    echo -e "  [ ${YLW}6${NC} ] Prune Docker Resources      (caution)"
    echo -e "  [ ${RED}7${NC} ] Uninstall VaultWarden-OCI  (destructive)"
    echo -e "  [ ${GRN}c${NC} ] View Changelog"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
    echo -e " ${CYN}Tip:${NC} Use b to return to Main Menu, e/q to exit, Ctrl-C anytime."
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
            # Run update, then automatically show the changelog (ux.md #44).
            run_cmd "make update" make -C "${REPO_ROOT}" update
            _show_changelog_on_update
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
            if _confirm_destructive \
                    "Prune Docker resources used by the stack"; then
                run_cmd "make prune" make -C "${REPO_ROOT}" prune
            else
                echo -e "${YLW} Prune cancelled.${NC}"
                _press_enter
            fi
            ;;
        7)
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
        c)
            # Stand-alone changelog viewer (ux.md #44).
            _show_changelog
            _press_enter
            ;;
        b) ACTIVE_MENU="main" ;;
        e|q) _cleanup ;;
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
    echo -e " ${CYN}Tip:${NC} Use b to return to Main Menu, e/q to exit, Ctrl-C anytime."
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
                | grep -iE '401|403|rate' \
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
        e|q) _cleanup ;;
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
    case "${1:-}" in
        --help|-h|help) show_help; exit 0 ;;
        --version|-V) print_project_version "VaultWarden-OCI" "${REPO_ROOT}"; exit 0 ;;
    esac

    if [[ ! -t 0 || ! -t 1 ]]; then
        log_error "dashboard.sh requires an interactive terminal."
        log_hint "Re-run in a local terminal or SSH session with a TTY: sudo ./dashboard.sh"
        exit 1
    fi

    # Root guard: several operations require sudo; ensure we are running as root.
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED} Error:${NC} This script must be run as root." >&2
        echo -e " Re-run with: ${BLD}sudo $0${NC}" >&2
        exit 1
    fi

    # Ensure we are running from the repo root so relative paths and make work.
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
        # Timeout after 60 s and redraw — keeps live stats fresh (ux.md #20).
        # On non-interactive stdin (piped input) read returns immediately.
        if ! read -r -t 60 -p " Enter option  : " opt 2>/dev/null; then
            # Timeout — loop back and redraw without processing input.
            continue
        fi

        # Normalize: trim whitespace, convert to lowercase.
        # Use tr instead of ${opt,,} for POSIX portability across all bash
        # versions and OCI image locales (avoids Bash 4.0+ dependency).
        opt="${opt//[[:space:]]/}"
        opt="$(printf '%s' "${opt}" | tr '[:upper:]' '[:lower:]')"

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
