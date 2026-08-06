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
source "${REPO_ROOT}/lib/config.sh"
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

STATE_DIR="/var/lib/vaultwarden"
BACKUP_DIR="${STATE_DIR}/backups"
TZ_DISPLAY="UTC"

_load_dashboard_config() {
    load_project_environment || return 1
    STATE_DIR="$(get_config_value PROJECT_STATE_DIR /var/lib/vaultwarden)"
    BACKUP_DIR="$(get_config_value BACKUP_DIR "${STATE_DIR}/backups")"
    TZ_DISPLAY="$(get_config_value TZ UTC)"
}

# Container names (must match docker-compose.yml)
CONTAINER_VW="vaultwarden_app"
CONTAINER_CADDY="vaultwarden_caddy"
CONTAINER_POSTFIX="vaultwarden_postfix"

# Divider line
DIVIDER="--------------------------------------------------"

# ---------------------------------------------------------------------------
# State: current active menu and redraw-local snapshots
# ---------------------------------------------------------------------------
ACTIVE_MENU="main"
declare -A DASHBOARD_SERVICE_STATE=()
declare -A DASHBOARD_SERVICE_HEALTH=()
declare -A DASHBOARD_SERVICE_CONTAINER=()
declare -A DASHBOARD_SERVICE_STARTED_AT=()
DASHBOARD_COMPOSE_SNAPSHOT_OK=false
NEWEST_BACKUP_PATH=""
NEWEST_BACKUP_MTIME=0

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
# Redraw-local Docker Compose snapshot and container presentation helpers
# ---------------------------------------------------------------------------
_capture_dashboard_process_snapshot() {
    local compose_output="" rows="" inspect_output=""
    local service container state health started_at
    local -a services=(vaultwarden caddy postfix)
    local -a inspect_targets=()
    local -A service_by_container=()

    DASHBOARD_SERVICE_STATE=()
    DASHBOARD_SERVICE_HEALTH=()
    DASHBOARD_SERVICE_CONTAINER=()
    DASHBOARD_SERVICE_STARTED_AT=()
    DASHBOARD_COMPOSE_SNAPSHOT_OK=false

    command -v jq >/dev/null 2>&1 || return 1
    if ! compose_output=$(docker compose --project-name vaultwarden-oci \
        ps --all --format json 2>/dev/null); then
        return 1
    fi
    if ! rows=$(printf '%s\n' "${compose_output}" | jq -r -s \
        --arg vw_container "${CONTAINER_VW}" \
        --arg caddy_container "${CONTAINER_CADDY}" \
        --arg postfix_container "${CONTAINER_POSTFIX}" '
        (if length == 1 and (.[0] | type) == "array" then .[0] else . end)
        | .[]
        | (.Name // .Names // "") as $container
        | select(
$container == $vw_container
or $container == $caddy_container
or $container == $postfix_container
          )
        | [
(if $container == $vw_container then "vaultwarden"
 elif $container == $caddy_container then "caddy"
 else "postfix"
 end),
$container,
((.State // "unknown") | tostring | ascii_downcase),
((.Health // "") | tostring | ascii_downcase)
          ]
        | @tsv
    ' 2>/dev/null); then
        return 1
    fi

    while IFS=$'\t' read -r service container state health; do
        [[ -n "${service}" ]] || continue
        DASHBOARD_SERVICE_STATE["${service}"]="${state}"
        DASHBOARD_SERVICE_HEALTH["${service}"]="${health}"
        DASHBOARD_SERVICE_CONTAINER["${service}"]="${container}"
    done <<< "${rows}"
    DASHBOARD_COMPOSE_SNAPSHOT_OK=true

    for service in "${services[@]}"; do
        state="${DASHBOARD_SERVICE_STATE[${service}]:-}"
        container="${DASHBOARD_SERVICE_CONTAINER[${service}]:-}"
        if [[ "${state}" == "running" && -n "${container}" ]]; then
            inspect_targets+=("${container}")
            service_by_container["${container}"]="${service}"
        fi
    done
    ((${#inspect_targets[@]} > 0)) || return 0

    inspect_output=""
    if inspect_output=$(docker inspect --format '{{.Name}}|{{.State.StartedAt}}' \
        "${inspect_targets[@]}" 2>/dev/null); then
        :
    fi
    while IFS='|' read -r container started_at; do
        container="${container#/}"
        service="${service_by_container[${container}]:-}"
        [[ -n "${service}" && -n "${started_at}" ]] || continue
        DASHBOARD_SERVICE_STARTED_AT["${service}"]="${started_at}"
    done <<< "${inspect_output}"
}

_container_status_plain() {
    local service="$1" state health
    if [[ "${DASHBOARD_COMPOSE_SNAPSHOT_OK}" != "true" ]]; then
        printf 'Unknown'
        return
    fi
    if [[ -z "${DASHBOARD_SERVICE_STATE[${service}]+_}" ]]; then
        printf 'Missing'
        return
    fi

    state="${DASHBOARD_SERVICE_STATE[${service}]}"
    health="${DASHBOARD_SERVICE_HEALTH[${service}]:-}"
    case "${state}" in
        running)
            case "${health}" in
                healthy|'') printf 'Running' ;;
                starting)   printf 'Starting' ;;
                unhealthy)  printf 'Unhealthy' ;;
                *)          printf 'Running (health unknown)' ;;
            esac
            ;;
        exited|dead) printf 'Stopped' ;;
        created)     printf 'Created' ;;
        restarting)  printf 'Restarting' ;;
        paused)      printf 'Paused' ;;
        removing)    printf 'Removing' ;;
        unknown|'')  printf 'Unknown' ;;
        *)           printf 'Unknown (%s)' "${state}" ;;
    esac
}

_container_status() {
    local status
    status="$(_container_status_plain "$1")"
    case "${status}" in
        Running)           printf '%s%s%s' "${GRN}" "${status}" "${NC}" ;;
        Stopped|Unhealthy) printf '%s%s%s' "${RED}" "${status}" "${NC}" ;;
        *)                 printf '%s%s%s' "${YLW}" "${status}" "${NC}" ;;
    esac
}

# ---------------------------------------------------------------------------
# _container_uptime — format a start time captured by the redraw snapshot
# ---------------------------------------------------------------------------
_container_uptime() {
    local service="$1"
    local started_at started_at_clean start_epoch now_epoch delta days hours mins

    started_at="${DASHBOARD_SERVICE_STARTED_AT[${service}]:-}"
    [[ -n "${started_at}" ]] || { printf 'unknown'; return; }

    started_at_clean="${started_at%%.*}"
    started_at_clean="${started_at_clean%Z}Z"

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

_container_summary() {
    local service="$1" status
    status="$(_container_status "${service}")"
    if [[ "${DASHBOARD_SERVICE_STATE[${service}]:-}" == "running" ]]; then
        printf '%s (up %s)' "${status}" "$(_container_uptime "${service}")"
    else
        printf '%s' "${status}"
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
        printf "${RED}.env missing${NC}"
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
        printf "${GRN}No placeholders found${NC}"
    elif (( count == 1 )); then
        printf "${YLW}1 placeholder remains: %s${NC}" "${unset_keys[0]}"
    elif (( count <= 4 )); then
        printf "${YLW}%d placeholders remain: %s${NC}" \
            "${count}" "${unset_keys[*]}"
    else
        printf "${YLW}%d placeholders remain — run: grep CHANGE_ME .env${NC}" \
            "${count}"
    fi
}

# ---------------------------------------------------------------------------
# _capture_newest_backup — retain path and timestamp from one directory pass
# ---------------------------------------------------------------------------
_capture_newest_backup() {
    local backup_file backup_mtime
    NEWEST_BACKUP_PATH=""
    NEWEST_BACKUP_MTIME=0

    while IFS= read -r -d '' backup_file; do
        backup_mtime="$(stat -c '%Y' "${backup_file}" 2>/dev/null \
            || stat -f '%m' "${backup_file}" 2>/dev/null || echo 0)"
        if [[ "${backup_mtime}" =~ ^[0-9]+$ ]] \
            && (( backup_mtime > NEWEST_BACKUP_MTIME )); then
            NEWEST_BACKUP_PATH="${backup_file}"
            NEWEST_BACKUP_MTIME="${backup_mtime}"
        fi
    done < <(find "${BACKUP_DIR}" -name '*.age' -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# _rclone_status
#
# Returns a single color-coded status line describing rclone availability:
#
#   Configured (not probed) — binary present + RCLONE_REMOTE_NAME configured
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

    local remote_name="${RCLONE_REMOTE_NAME:-}"

    # Strip surrounding whitespace and treat placeholder values as unset.
    remote_name="$(printf '%s' "${remote_name}" | tr -d '[:space:]')"
    local upper_name
    upper_name="$(printf '%s' "${remote_name}" | tr '[:lower:]' '[:upper:]')"

    if [[ -z "${remote_name}" \
        || "${upper_name}" == *CHANGE_ME* \
        || "${upper_name}" == *CHANGEME* ]]; then
        printf '%sNot configured (set RCLONE_REMOTE_NAME)%s' "${YLW}" "${NC}"
        return
    fi

    printf '%sConfigured (not probed)%s  (remote: %s)' "${GRN}" "${NC}" "${remote_name}"
}

# ---------------------------------------------------------------------------
# draw_live_stats
# ---------------------------------------------------------------------------

draw_live_stats() {
    draw_divider

    # --- Stack Health ---
    local vw_stat caddy_stat pf_stat
    _capture_dashboard_process_snapshot || true
    vw_stat="$(_container_summary vaultwarden)"
    caddy_stat="$(_container_summary caddy)"
    pf_stat="$(_container_summary postfix)"
    echo -e " ${BLD}Stack:${NC}  VaultWarden ${vw_stat}  |  Caddy ${caddy_stat}  |  Postfix ${pf_stat}"

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
    local ban_count ban_color cscli_output cscli_rc=0
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        cscli_output="$(cscli decisions list -o raw 2>/dev/null)" || cscli_rc=$?
        if (( cscli_rc == 0 )); then
            ban_count="$(printf '%s\n' "${cscli_output}" | tail -n +2 | grep -c . || true)"
        else
            ban_count="Unknown"
        fi
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

    # --- Config placeholder scan (ux.md #23) ---
    local secrets_stat
    secrets_stat="$(_secrets_health)"
    echo -e " ${BLD}Config placeholders:${NC}   ${secrets_stat}"

    # --- Last Backup ---
    local last_backup_str
    _capture_newest_backup
    if [[ -n "${NEWEST_BACKUP_PATH}" ]]; then
        last_backup_str="$(_epoch_to_pt "${NEWEST_BACKUP_MTIME}") ($(basename "${NEWEST_BACKUP_PATH}"))"
    else
        last_backup_str="${YLW}No backups found${NC}"
    fi
    echo -e " ${BLD}Last backup:${NC}  ${last_backup_str}"

    # --- Rclone Status ---

    local rclone_stat
    rclone_stat="$(_rclone_status)"
    echo -e " ${BLD}Rclone:${NC}  ${rclone_stat}"

    # --- Systemd Timers ---
    local _timer_output _timer_rc=0
    _timer_output=$(systemctl list-timers --no-pager 2>/dev/null) || _timer_rc=$?
    if (( _timer_rc != 0 )); then
        echo -e " ${BLD}Timers:${NC}  ${YLW}Unknown${NC}"
    elif grep -q vaultwarden <<< "${_timer_output}"; then
        echo -e " ${BLD}Timers:${NC}"
        grep vaultwarden <<< "${_timer_output}" \
            | awk '{printf "    %-40s → %s %s\n", $NF, $1, $2}'
    else
        echo -e " ${BLD}Timers:${NC}  ${YLW}No VaultWarden timers listed${NC}"
    fi

    # --- Email Queue ---
    local queue_count="" queue_str queue_rc=0
    if [[ -x "${REPO_ROOT}/utilities/email-queue.sh" ]]; then
        queue_count="$(timeout 3 "${REPO_ROOT}/utilities/email-queue.sh" \
            summary --quiet 2>/dev/null)" || queue_rc=$?
        (( queue_rc == 0 )) || queue_count=""
    fi
    if [[ ! "${queue_count}" =~ ^[0-9]+$ ]]; then
        queue_str="${YLW}Unknown${NC}"
    elif (( queue_count == 0 )); then
        queue_str="${GRN}0 queued${NC}"
    elif (( queue_count < 5 )); then
        queue_str="${YLW}${queue_count} queued${NC}"
    else
        queue_str="${RED}${queue_count} queued${NC}"
    fi
    echo -e " ${BLD}Email Queue:${NC}  ${queue_str}"

    draw_divider
}

# ===========================================================================
# MAIN MENU
# ===========================================================================
draw_main_menu() {
    echo -e " ${BLD}Main Menu${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Start/Restart Stack"
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
                run_sudo_cmd "sudo make down" make -C "${REPO_ROOT}" down
                # Force live-stats redraw so container state is fresh (ux.md #3).
                ACTIVE_MENU="main"
            else
                echo -e "${YLW} Operation cancelled.${NC}"
                sleep 1
            fi
            ;;
        3)
            run_sudo_cmd "sudo make health-quick" make -C "${REPO_ROOT}" health-quick
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
    echo -e "  [ ${GRN}1${NC} ] DB Snapshot Backup"
    echo -e "  [ ${GRN}2${NC} ] Full System Backup"
    echo -e "  [ ${GRN}3${NC} ] Interactive Restore"
    echo -e "  [ ${GRN}4${NC} ] Backup Inventory"
    draw_divider
    echo -e "  [ ${GRN}5${NC} ] Create + Sync New DB Backup"
    echo -e "  [ ${GRN}6${NC} ] Create + Fully Verify + Sync DB Backup"
    echo -e "  [ ${GRN}7${NC} ] Copy All Local Backups to Rclone Remote"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
    echo -e " ${CYN}Tip:${NC} Options 5-7 use the configured RCLONE_REMOTE_NAME."
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
            _check_script "${REPO_ROOT}/backup.sh" || return
            run_sudo_cmd "sudo ./backup.sh run db --rclone" \
                "${REPO_ROOT}/backup.sh" run db --rclone
            ;;
        6)
            _check_script "${REPO_ROOT}/backup.sh" || return
            run_sudo_cmd "sudo ./backup.sh run db --full-verification --rclone" \
                "${REPO_ROOT}/backup.sh" run db --full-verification --rclone
            ;;
        7)
            _check_script "${REPO_ROOT}/backup.sh" || return
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
            run_sudo_cmd "sudo make unban IP=${ip_to_unban}" \
                make -C "${REPO_ROOT}" unban "IP=${ip_to_unban}"
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
            run_sudo_cmd "sudo ./utilities/secrets-edit.sh" "${edit_sh}"
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
            run_sudo_cmd "sudo ./utilities/secrets-export-recovery-kit.sh" "${kit_sh}"
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
    echo -e "  [ ${GRN}1${NC} ] Email Operations"
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
            ACTIVE_MENU="email_operations"
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
# SUBMENU I.1 — Email Operations
# ===========================================================================
draw_email_operations_menu() {
    echo -e " ${BLD}Email Operations${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Configured production route"
    echo -e "  [ ${GRN}2${NC} ] All exact transports"
    echo -e "  [ ${GRN}3${NC} ] HTTP API only"
    echo -e "  [ ${GRN}4${NC} ] Postfix sidecar only"
    echo -e "  [ ${GRN}5${NC} ] Direct SMTP only"
    echo -e "  [ ${GRN}6${NC} ] Postfix queue operations"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Identity, Email & Admin"
    echo ""
    echo -e " ${CYN}Tip:${NC} Exact transport tests do not use production-route fallback."
    echo -e " ${CYN}Tip:${NC} Use b to return, e/q to exit, Ctrl-C anytime."
    echo ""
}
handle_email_operations_menu() {
    local opt="$1" transport=""
    case "${opt}" in
        1) transport="configured" ;;
        2) transport="all" ;;
        3) transport="api" ;;
        4) transport="sidecar" ;;
        5) transport="direct" ;;
        6)
            ACTIVE_MENU="email_queue"
            return
            ;;
        b)
            ACTIVE_MENU="identity"
            return
            ;;
        e|q) _cleanup ;;
        *)
            echo -e "${YLW} Invalid option. Please try again.${NC}"
            sleep 1
            return
            ;;
    esac
    run_sudo_cmd \
        "sudo make test-email EMAIL_TEST_TRANSPORT=${transport}" \
        make -C "${REPO_ROOT}" test-email "EMAIL_TEST_TRANSPORT=${transport}"
}

# ===========================================================================
# SUBMENU I.1.1 — Postfix Queue Operations
# ===========================================================================
draw_email_queue_menu() {
    echo -e " ${BLD}Postfix Queue Operations${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Queue summary"
    echo -e "  [ ${GRN}2${NC} ] List queued messages"
    echo -e "  [ ${GRN}3${NC} ] Inspect a message"
    echo -e "  [ ${GRN}4${NC} ] Retry a message"
    echo -e "  [ ${RED}5${NC} ] Delete a message"
    echo -e "  [ ${YLW}6${NC} ] Retry all queued messages"
    echo -e "  [ ${GRN}7${NC} ] View Postfix logs"
    echo -e "  [ ${RED}8${NC} ] Purge current queue snapshot"
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Email Operations"
    echo ""
    echo -e " ${CYN}Tip:${NC} Destructive confirmation is owned by the queue utility."
    echo -e " ${CYN}Tip:${NC} Queue IDs remain case-sensitive."
    echo ""
}

_prompt_email_queue_id() {
    local prompt="$1" queue_id=""
    printf ' %s: ' "$prompt" >&2
    IFS= read -r queue_id || queue_id=""
    queue_id="$(printf '%s' "$queue_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$queue_id" ]]; then
        echo -e "${YLW} Queue ID must not be empty.${NC}" >&2
        _press_enter
        return 1
    fi
    printf '%s\n' "$queue_id"
}

handle_email_queue_menu() {
    local opt="$1" queue_id="" tail_lines="200"
    case "${opt}" in
        1)
            run_sudo_cmd "sudo make email-queue-summary" \
                make -C "${REPO_ROOT}" email-queue-summary
            ;;
        2)
            run_sudo_cmd "sudo make email-queue" \
                make -C "${REPO_ROOT}" email-queue
            ;;
        3)
            queue_id=$(_prompt_email_queue_id "Queue ID to inspect") || return
            run_sudo_cmd "sudo make email-queue-inspect QUEUE_ID=${queue_id}" \
                make -C "${REPO_ROOT}" email-queue-inspect "QUEUE_ID=${queue_id}"
            ;;
        4)
            queue_id=$(_prompt_email_queue_id "Queue ID to retry") || return
            run_sudo_cmd "sudo make email-queue-retry QUEUE_ID=${queue_id}" \
                make -C "${REPO_ROOT}" email-queue-retry "QUEUE_ID=${queue_id}"
            ;;
        5)
            queue_id=$(_prompt_email_queue_id "Queue ID to delete") || return
            run_sudo_cmd "sudo make email-queue-delete QUEUE_ID=${queue_id}" \
                make -C "${REPO_ROOT}" email-queue-delete "QUEUE_ID=${queue_id}"
            ;;
        6)
            run_sudo_cmd "sudo make email-queue-retry-all" \
                make -C "${REPO_ROOT}" email-queue-retry-all
            ;;
        7)
            printf ' Optional queue ID (blank for all logs): '
            IFS= read -r queue_id || queue_id=""
            queue_id="$(printf '%s' "$queue_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            printf ' Tail lines [200]: '
            IFS= read -r tail_lines || tail_lines="200"
            tail_lines="$(printf '%s' "${tail_lines:-200}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            run_sudo_cmd "sudo make email-queue-logs QUEUE_ID=${queue_id} EMAIL_QUEUE_TAIL=${tail_lines}" \
                make -C "${REPO_ROOT}" email-queue-logs \
                "QUEUE_ID=${queue_id}" "EMAIL_QUEUE_TAIL=${tail_lines}"
            ;;
        8)
            run_sudo_cmd "sudo make email-queue-purge" \
                make -C "${REPO_ROOT}" email-queue-purge
            ;;
        b)
            ACTIVE_MENU="email_operations"
            ;;
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h|help) show_help; exit 0 ;;
            --version|-V) print_project_version "VaultWarden-OCI" "${REPO_ROOT}"; exit 0 ;;
            *) log_error "Unknown argument: $1"; show_help; exit 1 ;;
        esac
    done

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
    _load_dashboard_config || exit 1

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
            email_operations) draw_email_operations_menu ;;
            email_queue) draw_email_queue_menu ;;
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
            secrets)  handle_secrets_menu "${opt}" ;;
            advanced) handle_advanced_menu "${opt}" ;;
            identity) handle_identity_menu "${opt}" ;;
            email_operations) handle_email_operations_menu "${opt}" ;;
            email_queue) handle_email_queue_menu "${opt}" ;;
        esac
    done
}

main "$@"
