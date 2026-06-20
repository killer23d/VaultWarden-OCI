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
    local rc=0
    if [[ $EUID -eq 0 ]]; then
        (IFS=" "; "$@") || rc=$?
    else
        if ! sudo -n true 2>/dev/null; then
            echo -e "${YLW} Sudo credentials are unavailable or expired.${NC}"
            echo -e " Re-authenticate with ${BLD}sudo -v${NC}, then retry."
            _press_enter
            return
        fi
        (IFS=" "; sudo "$@") || rc=$?
    fi

    if (( rc == 0 )); then
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${GRN} Command completed successfully.${NC}"
    else
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${YLW} Command exited with status ${rc}.${NC}"
    fi
    _press_enter
}

# ---------------------------------------------------------------------------
# Utility: run a normal-user command from a root-launched dashboard.
# If the dashboard was launched with sudo, drop back to SUDO_USER.
# ---------------------------------------------------------------------------
run_user_cmd() {
    local label="$1"; shift
    echo ""
    echo -e "${BLD} Running: ${label}${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"

    local rc=0
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "$SUDO_USER" -- "$@" || rc=$?
    else
        "$@" || rc=$?
    fi

    if (( rc == 0 )); then
        echo -e "${CYN}${DIVIDER}${NC}"
        echo -e "${GRN} Command completed successfully.${NC}"
    else
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
# show_help — printed when --help / -h is passed
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
VaultWarden-OCI Operations Dashboard

USAGE:
    sudo ./dashboard.sh [OPTIONS]

DESCRIPTION:
    AMTM-style interactive terminal dashboard for VaultWarden-OCI. Displays
    live stack health, disk usage, CrowdSec bans, backup status, rclone
    remote status, and email queue at a glance. Provides submenus for backup,
    security, secrets, and advanced operations. Auto-refreshes every 60 s.

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
    version="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null \
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
# _secrets_health
#
# Scans .env for CHANGE_ME / CHANGEME placeholder values and returns a
# single color-coded status string.
# ---------------------------------------------------------------------------
_secrets_health() {
    local env_file="${REPO_ROOT}/.env"

    if [[ ! -f "${env_file}" || ! -r "${env_file}" ]]; then
        printf "${RED}Secrets file missing (.env)${NC}"
        return
    fi

    local -a unset_keys=()
    local key rest val val_upper
    while IFS='=' read -r key rest; do
        [[ -z "${key// /}"            ]] && continue  # blank line
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue  # comment line
        [[ "${rest}" != *=* && -z "${rest}" ]] && continue  # key with no value at all
        val="${rest}"
        val_upper="$(printf '%s' "${val}" | tr '[:lower:]' '[:upper:]')"
        if [[ "${val_upper}" == *CHANGE_ME* || "${val_upper}" == *CHANGEME* ]]; then
            unset_keys+=("${key}")
        fi
    done < "${env_file}"

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
# _last_backup_result
#
# Derives the result of the most recent backup run from the artefacts that
# backup-run.sh always writes alongside each encrypted archive:
#
#   PASS       — .age + .sha256 + .meta all present  (successful, verified)
#   WARN       — .age + .sha256 present, .meta absent (completed, no metadata)
#   INCOMPLETE — .age present but no .sha256 sidecar  (may be a partial write)
#   N/A        — no .age archives found anywhere under BACKUP_DIR
#
# Search covers all backup-type subdirectories (db/, full/, emergency/) so
# it always reflects the single newest archive regardless of type.
#
# No external log file is required; this is entirely artefact-driven and will
# update on every dashboard refresh after each backup run.
# ---------------------------------------------------------------------------
_last_backup_result() {
    local newest_file="" newest_mtime=0

    # Walk every type subdirectory that may exist under BACKUP_DIR.
    local type_dir file file_mtime
    for type_dir in "${BACKUP_DIR}/db" "${BACKUP_DIR}/full" "${BACKUP_DIR}/emergency"; do
        [[ -d "${type_dir}" ]] || continue
        while IFS= read -r -d '' file; do
            file_mtime="$(stat -c '%Y' "${file}" 2>/dev/null \
                || stat -f '%m' "${file}" 2>/dev/null \
                || echo 0)"
            if (( file_mtime > newest_mtime )); then
                newest_mtime=${file_mtime}
                newest_file=${file}
            fi
        done < <(find "${type_dir}" -maxdepth 1 -name '*.age' -type f -print0 2>/dev/null)
    done

    # No archives found at all.
    if [[ -z "${newest_file}" ]]; then
        printf '%s(N/A — no backups found)%s' "${YLW}" "${NC}"
        return
    fi

    # Determine result from sidecar artefacts.
    local sha256_file="${newest_file}.sha256"
    local meta_file="${newest_file}.meta"

    if [[ -f "${sha256_file}" && -f "${meta_file}" ]]; then
        printf '%sPASS%s' "${GRN}" "${NC}"
    elif [[ -f "${sha256_file}" ]]; then
        printf '%sWARN (no .meta sidecar)%s' "${YLW}" "${NC}"
    else
        printf '%sINCOMPLETE (no .sha256 sidecar)%s' "${RED}" "${NC}"
    fi
}

# ---------------------------------------------------------------------------
# _rclone_status
#
# Returns a single color-coded status line describing rclone availability:
#
#   Ready      — binary present + RCLONE_REMOTE_NAME set in .env
#   Not configured  — binary present but RCLONE_REMOTE_NAME is missing/placeholder
#   Not installed   — rclone binary not found on PATH
#
# Intentionally does NOT perform a live network probe (rclone lsd …) because
# the dashboard redraws every 60 s and a slow / failed network call would
# stall the UI. The operator can trigger a live sync via the Backup menu.
# ---------------------------------------------------------------------------
_rclone_status() {
    # Check binary availability first.
    if ! command -v rclone &>/dev/null; then
        printf '%sNot installed%s' "${YLW}" "${NC}"
        return
    fi

    # Read the configured remote name from .env.
    local remote_name
    remote_name="$(_read_env_var RCLONE_REMOTE_NAME "")"

    # Strip surrounding whitespace and treat placeholder values as unset.
    remote_name="$(printf '%s' "${remote_name}" | tr -d '[:space:]')"
    local upper_name
    upper_name="$(printf '%s' "${remote_name}" | tr '[:lower:]' '[:upper:]')"

    if [[ -z "${remote_name}" \
        || "${upper_name}" == *CHANGE_ME* \
        || "${upper_name}" == *CHANGEME* ]]; then
        printf '%sNot configured (set RCLONE_REMOTE_NAME in .env)%s' "${YLW}" "${NC}"
        return
    fi

    printf '%sReady%s  (remote: %s)' "${GRN}" "${NC}" "${remote_name}"
}

# ---------------------------------------------------------------------------
# draw_live_stats
# ---------------------------------------------------------------------------
draw_live_stats() {
    draw_divider

    # --- Stack Health ---
    local vw_plain vw_stat caddy_stat pf_stat vw_uptime=""
    vw_plain="$(_container_status_plain "${CONTAINER_VW}")"
    if [[ "${vw_plain}" == "Running" ]]; then
        vw_stat="${GRN}Running${NC}"
        vw_uptime=" (up $(_container_uptime "${CONTAINER_VW}"))"
    else
        vw_stat="${RED}Stopped${NC}"
    fi
    caddy_stat="$(_container_status "${CONTAINER_CADDY}")"
    pf_stat="$(_container_status "${CONTAINER_POSTFIX}")"
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

    # --- Last Backup Result ---
    # Derived from .sha256 / .meta sidecar artefacts written by backup-run.sh.
    # Does not rely on any external log file.
    local last_result_str
    last_result_str="$(_last_backup_result)"
    echo -e " ${BLD}Last result:${NC}  ${last_result_str}"

    # --- Rclone Status ---
    local rclone_stat
    rclone_stat="$(_rclone_status)"
    echo -e " ${BLD}Rclone:${NC}  ${rclone_stat}"

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
    echo -e "  [ ${GRN}b${NC} ] Backup & Restore Menu       (7 options)"
    echo -e "  [ ${GRN}s${NC} ] Security & CrowdSec Menu    (5 options)"
    echo -e "  [ ${GRN}k${NC} ] Secrets & Key Management    (4 options)"
    echo -e "  [ ${GRN}a${NC} ] Advanced & Maintenance      (7 options)"
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
            run_sudo_cmd "sudo make restart" \
                make -C "${REPO_ROOT}" restart
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
            run_user_cmd "make health" make -C "${REPO_ROOT}" health
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
    echo -e "  [ ${GRN}5${NC} ] Sync Latest Backup to Rclone Remote"
    echo -e "  [ ${GRN}6${NC} ] Full Verify + Sync to Rclone Remote"
    echo -e "  [ ${GRN}7${NC} ] Copy All Local Backups to Rclone Remote"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
    echo -e " ${CYN}Tip:${NC} Options 5-7 require RCLONE_REMOTE_NAME to be set in .env."
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
            run_sudo_cmd "sudo make backup-status" make -C "${REPO_ROOT}" backup-status
            ;;
        5)
            # Sync the most recent backup archive to the configured rclone remote.
            # backup.sh --rclone is non-fatal on network failure by design, so the
            # local archive is never at risk.
            _check_script "${REPO_ROOT}/backup.sh" || return
            local remote_name
            remote_name="$(_read_env_var RCLONE_REMOTE_NAME "")"
            remote_name="$(printf '%s' "${remote_name}" | tr -d '[:space:]')"
            if [[ -z "${remote_name}" ]]; then
                echo -e "${YLW} RCLONE_REMOTE_NAME is not set in .env — cannot sync.${NC}"
                echo -e " Edit .env and add: RCLONE_REMOTE_NAME=<your-remote>"
                _press_enter
                return
            fi
            run_sudo_cmd "sudo ./backup.sh run db --rclone" \
                "${REPO_ROOT}/backup.sh" run db --rclone
            ;;
        6)
            # Full end-to-end verification (decrypt + integrity check) followed
            # by an rclone sync. Fatal on verification failure before any upload.
            _check_script "${REPO_ROOT}/backup.sh" || return
            local remote_name
            remote_name="$(_read_env_var RCLONE_REMOTE_NAME "")"
            remote_name="$(printf '%s' "${remote_name}" | tr -d '[:space:]')"
            if [[ -z "${remote_name}" ]]; then
                echo -e "${YLW} RCLONE_REMOTE_NAME is not set in .env — cannot sync.${NC}"
                echo -e " Edit .env and add: RCLONE_REMOTE_NAME=<your-remote>"
                _press_enter
                return
            fi
            run_sudo_cmd "sudo ./backup.sh run db --full-verification --rclone" \
                "${REPO_ROOT}/backup.sh" run db --full-verification --rclone
            ;;
        7)
            # Copy every retained local archive and sidecar to its matching
            # db/full/emergency remote folder, then apply configured retention.
            _check_script "${REPO_ROOT}/backup.sh" || return
            local remote_name
            remote_name="$(_read_env_var RCLONE_REMOTE_NAME "")"
            remote_name="$(printf '%s' "${remote_name}" | tr -d '[:space:]')"
            if [[ -z "${remote_name}" ]]; then
                echo -e "${YLW} RCLONE_REMOTE_NAME is not set in .env — cannot sync.${NC}"
                echo -e " Edit .env and add: RCLONE_REMOTE_NAME=<your-remote>"
                _press_enter
                return
            fi
            run_sudo_cmd "./backup.sh sync" \
                "${REPO_ROOT}/backup.sh" sync
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
            run_user_cmd "./utilities/secrets-edit.sh" "${edit_sh}"
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
            run_user_cmd "./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"
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
            if _confirm_destructive \
                    "Prune Docker resources used by the stack"; then
                run_cmd "make prune" \
                    env DASHBOARD_CONFIRMED=true make -C "${REPO_ROOT}" prune
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
            run_user_cmd "make test-email" make -C "${REPO_ROOT}" test-email
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
