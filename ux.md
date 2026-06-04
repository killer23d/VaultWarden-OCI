***

## 1. Progress Feedback During Long Phases

**Why:** `setup.sh` runs 6+ sequential phases (system → storage → env → secrets → firewall → systemd). Right now each phase just emits log lines as they appear. Users have no sense of "how far along" they are, leading to anxiety during the 3–8 minute install.

**Fix — Add a phase progress bar to `lib/log.sh`:**

```bash
# lib/log.sh — add this function
# Usage: log_phase 3 6 "Secrets bootstrap"
log_phase() {
    local current="$1" total="$2" label="$3"
    local filled=$(( current * 20 / total ))
    local empty=$(( 20 - filled ))
    local bar=""
    bar+=$(printf '█%.0s' $(seq 1 $filled))
    bar+=$(printf '░%.0s' $(seq 1 $empty))
    printf '%s[%s/%s] [%s] %s%s\n' \
        "${COLOR_BOLD}" "$current" "$total" "$bar" "$label" "${COLOR_RESET}"
}
```

**In `setup.sh` main():**

```bash
# Replace bare log_info "=== Phase N: ... ===" lines with:
log_phase 1 6 "System setup"
"${SCRIPT_DIR}/utilities/setup-system.sh" ...

log_phase 2 6 "Storage setup"
"${SCRIPT_DIR}/utilities/setup-storage.sh" ...

log_phase 3 6 "Environment configuration"
# etc.
```


***

## 2. Spinner for Silent Background Operations

**Why:** Several utilities (SOPS download, Docker pull, package install) are silent for 15–60 seconds. Without feedback, users can't tell if the process is hung or working.

**Fix — Add a spinner utility to `lib/log.sh`:**

```bash
# lib/log.sh
_spinner_pid=""

spinner_start() {
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf '\r%s %s %s' "${COLOR_CYAN}" "${frames[$((i % 10))]}" "$msg${COLOR_RESET}"
            sleep 0.1
            (( i++ ))
        done
    ) &
    _spinner_pid=$!
}

spinner_stop() {
    local success="${1:-true}"
    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null || true
        _spinner_pid=""
    fi
    if [[ "$success" == "true" ]]; then
        printf '\r%s ✔  Done.%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
    else
        printf '\r%s ✖  Failed.%s\n' "${COLOR_BOLD_RED}" "${COLOR_RESET}"
    fi
}
```

**Usage in `lib/common.sh` `download_file()`:**

```bash
download_file() {
    local url="$1" dest="$2"
    spinner_start "Downloading $(basename "$dest")..."
    if curl -fsSL "$url" -o "$dest"; then
        spinner_stop "true"
    else
        spinner_stop "false"
        return 1
    fi
}
```


***

## 3. Dashboard Live Stats Refresh Is Missing

**Why:** `draw_live_stats()` only runs once per `clear` cycle. If a container starts/stops while the menu is open, the user sees stale state. This is especially jarring when they trigger `Start` from menu option `1` but the stats header still shows `Stopped`.

**Fix — Refresh stats after every action that changes container state:**

```bash
# dashboard.sh — in run_cmd() and run_sudo_cmd(), add a stats refresh signal
run_cmd() {
    local label="$1"; shift
    # ... existing run logic ...
    _press_enter
    # Mark that live stats need a full redraw on next loop tick
    # (already handled — the while true; do clear loop redraws on every iteration)
    # Explicitly force re-entry to main menu after ops that change stack state:
    case "$label" in
        *"make up"*|*"make down"*|*"make restart"*|*"update"*)
            ACTIVE_MENU="main"   # force redraw of live stats immediately
            ;;
    esac
}
```


***

## 4. `dashboard.sh` TZ Is Hardcoded to Pacific Time

**Why:** `TZ_DISPLAY="America/Vancouver"` is hardcoded. Users deploying in EU, Asia, or any other timezone see timestamps in the wrong local time with no way to change it without editing the script.

**Fix — Read timezone from `.env` with a fallback:**

```bash
# dashboard.sh — replace the hardcoded TZ_DISPLAY line:
TZ_DISPLAY="$(_read_env_var DASHBOARD_TZ "America/Vancouver")"

# And add to .env.example:
# DASHBOARD_TZ=America/Vancouver   # Timezone for dashboard timestamps (e.g. UTC, Europe/Berlin)
```


***

## 5. `setup.sh` Post-Install Summary Scrolls Off Screen

**Why:** The post-install summary dumps the Age key, admin token, Caddy password, and a 7-step next-steps checklist in one massive block. On terminals with small scroll buffers, the critical key section gets pushed off screen before the user can save it.

**Fix — Paginate the summary into distinct "screens":**

```bash
show_post_install_summary() {
    local mode="${1:-interactive}"

    # --- Screen 1: CRITICAL CREDENTIALS ONLY ---
    clear
    printf '%s' "${COLOR_RED}"
    cat << 'CRED_BANNER'
  ╔═══════════════════════════════════════════════════════╗
  ║  🚨 SAVE THESE NOW — NOT SHOWN AGAIN                  ║
  ╚═══════════════════════════════════════════════════════╝
CRED_BANNER
    printf '%s' "${COLOR_RESET}"
    printf '\n%s[^1_1] AGE SECRET KEY%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"
    printf '\n%s[^1_2] VAULTWARDEN ADMIN TOKEN%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_GREEN}" "${vw_admin_plain}" "${COLOR_RESET}"
    printf '\n%s[^1_3] CADDY ADMIN PASSWORD%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_GREEN}" "${caddy_admin_plain}" "${COLOR_RESET}"
    printf '\n%s[^1_4] BACKUP PASSPHRASE%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_GREEN}" "${backup_pass_plain}" "${COLOR_RESET}"

    printf '\n%s Press [Enter] ONLY after saving all credentials above...%s\n' \
        "${COLOR_RED}" "${COLOR_RESET}"
    [[ -t 0 ]] && read -r

    # --- Screen 2: NEXT STEPS (after credentials are saved) ---
    clear
    printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '1. Edit .env:           %s%s%s\n' "${COLOR_YELLOW}" "$env_edit_cmd" "${COLOR_RESET}"
    # ... rest of next steps ...
}
```


***

## 6. Missing Confirmation Before Destructive `make down` / Docker Commands

**Why:** The main menu has option `[^1_3] Stop Services` which immediately runs `make down`. There is no "are you sure?" guard — one accidental keystroke stops the live vault, potentially during active user sessions.

**Fix — Add a lightweight confirmation wrapper for stop/restart actions:**

```bash
# dashboard.sh — add helper
_confirm_destructive() {
    local action="$1"
    echo ""
    printf '%s Are you sure you want to %s? [y/N]: %s' "${YLW}" "$action" "${NC}"
    local ans
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

# In handle_main_menu():
3)
    if _confirm_destructive "stop all VaultWarden services"; then
        run_cmd "make down" make -C "${REPO_ROOT}" down
    else
        echo -e "${YLW} Operation cancelled.${NC}"
        sleep 1
    fi
    ;;
```


***

## 7. No Visual Distinction Between Informational vs. Destructive Menu Items

**Why:** In `draw_advanced_menu()`, all numbered options use `${GRN}` (green) except option 7 (Uninstall) which uses `${RED}`. But `[^1_6] Prune Docker Resources` is also destructive (removes images/volumes) yet is colored green, visually identical to safe options.

**Fix — Consistently color destructive items red:**

```bash
draw_advanced_menu() {
    echo -e " ${BLD}Advanced & Maintenance${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Export Recovery Kit"
    echo -e "  [ ${GRN}2${NC} ] Update Stack Images"
    echo -e "  [ ${GRN}3${NC} ] Database Maintenance / Vacuum"
    echo -e "  [ ${GRN}4${NC} ] Fix File Permissions"
    echo -e "  [ ${GRN}5${NC} ] Systemd Timer Status"
    echo -e "  [ ${YLW}6${NC} ] Prune Docker Resources"      # ← yellow = caution
    echo -e "  [ ${RED}7${NC} ] Uninstall VaultWarden-OCI"   # ← red = destructive
    draw_divider
    echo -e "  [ ${GRN}b${NC} ] Back to Main Menu"
    echo ""
}
```


***

## 8. `log_header()` Uses Dynamic String Length — Breaks on Non-ASCII

**Why:** `log_header()` in `lib/log.sh` calculates the underline length via `${#message}`, which counts bytes, not display characters. Emoji (like 🚨 in setup messages) are multi-byte — the underline renders shorter than the text, breaking visual alignment.

**Fix:**

```bash
log_header() {
    local message="$*"
    # Use printf %s | wc -m for character count (handles multibyte/emoji)
    local len
    len=$(printf '%s' "$message" | wc -m 2>/dev/null || echo "${#message}")
    local line
    line=$(printf '═%.0s' $(seq 1 "$len"))
    printf '\n'
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s%s%s\n' "${COLOR_BOLD}" "${line}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_BOLD}" "${message}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_BOLD}" "${line}" "${COLOR_RESET}"
    else
        printf '%s\n%s\n%s\n' "$line" "$message" "$line"
    fi
    printf '\n'
}
```


***

## 9. `setup.sh` `--dry-run` Has No Visual Differentiation After Log Lines

**Why:** `DRY_RUN=true` sets a flag but most phase scripts don't visually prefix every action line. A user running `--dry-run` to preview can easily confuse dry-run output with real execution because log lines look identical.

**Fix — Add a persistent DRY RUN banner to every log line when `DRY_RUN=true`:**

```bash
# lib/log.sh — modify log_info() to check DRY_RUN:
log_info() {
    _should_log "INFO" || return 0
    local ts tag prefix=""
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"
    [[ "${DRY_RUN:-false}" == "true" ]] && prefix="${COLOR_BLUE}[DRY RUN] ${COLOR_RESET}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] INFO%s %s%s\n' \
            "${COLOR_CYAN}" "$ts" "$tag" "${COLOR_RESET}" "$prefix" "$*"
    else
        printf '[%s] [%s] INFO %s%s\n' "$ts" "$tag" "${prefix:+[DRY RUN] }" "$*"
    fi
}
```


***

## 10. `_press_enter` Prompt Is Inconsistent Across Scripts

**Why:** `dashboard.sh` uses the `_press_enter()` function with proper `${INV}` reverse-video styling. However, `setup.sh` uses raw `read -r` calls in several places (e.g., the `--force` ACK prompt and post-install credential page) without any visual prompt, leaving the cursor sitting at a blank line with no cue.

**Fix — Move `_press_enter` into `lib/common.sh` as a shared utility:**

```bash
# lib/common.sh — add:
press_enter_to_continue() {
    local msg="${1:- Press [Enter] to continue...}"
    local _dummy
    printf '\n'
    if [[ -t 1 ]]; then
        printf '\e[7m%s\e[0m\n' "$msg"   # reverse video, no external dep
    else
        printf '%s\n' "$msg"
    fi
    read -r _dummy
}
```

**Replace bare `read -r` calls in `setup.sh`:**

```bash
# Before: read -r (blank, silent)
# After:
press_enter_to_continue " Press [Enter] ONLY after saving all credentials above..."
```


***

## 11. No `--version` Flag

**Why:** The `VERSION` file exists at repo root, but neither `setup.sh` nor `dashboard.sh` exposes it via `--version`. Users filing bug reports can't easily state which version they're running, and the dashboard header shows no version string.

**Fix — Add to `setup.sh` argument parsing:**

```bash
# setup.sh — in the argument parser, before other flags:
--version|-V)
    printf 'VaultWarden-OCI %s\n' "$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
    exit 0
    ;;
```

**And in `dashboard.sh` `draw_header()`:**

```bash
draw_header() {
    local now_pt version
    now_pt="$(TZ="${TZ_DISPLAY}" date '+%Y-%m-%d %H:%M PT' 2>/dev/null || date '+%Y-%m-%d %H:%M')"
    version="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "?")"
    echo -e "${INV} VaultWarden-OCI v${version} — Operations Dashboard    ${now_pt} ${NC}"
}
```


***

## 12. `draw_live_stats` Backup Log Last-Result Parsing Is Fragile

**Why:** The last backup result line uses:

```bash
grep -E '(PASS|FAIL|ERROR|SUCCESS)' "${STATE_DIR}/logs/backup.log" | tail -1
```

If the log contains a multi-word line like `"ERROR: Disk full during full backup"`, the entire raw log line is printed with no color coding, no timestamp, and no truncation — it can overflow the stats header width on narrow terminals.

**Fix:**

```bash
# dashboard.sh — replace the _last_backup_line block:
local _last_result _result_color
_last_result=$(grep -oE '(PASS|FAIL|ERROR|SUCCESS)' \
    "${STATE_DIR}/logs/backup.log" 2>/dev/null | tail -1 || echo "UNKNOWN")

case "$_last_result" in
    PASS|SUCCESS) _result_color="${GRN}" ;;
    FAIL|ERROR)   _result_color="${RED}" ;;
    *)            _result_color="${YLW}" ;;
esac

echo -e " ${BLD}Last backup result:${NC}  ${_result_color}${_last_result}${NC}"
```

<span style="display:none">[^1_10][^1_11][^1_12][^1_13][^1_14][^1_15][^1_5][^1_7][^1_8][^1_9]</span>

<div align="center">⁂</div>

[^1_1]: https://github.com/dani-garcia/vaultwarden

[^1_2]: https://github.com/dani-garcia/vaultwarden/releases

[^1_3]: https://github.com/epiecs/vaultwarden-server

[^1_4]: https://github.com/dani-garcia/vaultwarden/discussions/1802

[^1_5]: https://github.com/dani-garcia/vaultwarden/blob/main/src/main.rs

[^1_6]: https://www.reddit.com/r/Proxmox/comments/1pldxsa/where_is_directory_bind_for_oci/

[^1_7]: https://github.com/Sunwood-ai-labs/vaultwarden-docker-compose/releases

[^1_8]: https://www.youtube.com/watch?v=M1P3MiwyiWI

[^1_9]: https://github.com/obaidabit/vaultwarden

[^1_10]: https://hub.docker.com/r/vaultwarden/server

[^1_11]: https://github.com/dani-garcia/vaultwarden/discussions/2052

[^1_12]: https://www.youtube.com/watch?v=KLwmCfGN7e0

[^1_13]: https://github.com/dani-garcia/vaultwarden/discussions/2275

[^1_14]: https://community-scripts.github.io/ProxmoxVE/scripts?id=vaultwarden

[^1_15]: https://github.com/czyt/vaultwarden-binary/releases


---

***

## 13. `smoke-test.sh` Has No Elapsed Time or ETA

**Why:** The smoke test runs 12+ checks that include HTTP probes, SOPS decryption, Docker queries, and filesystem scans. With `--quiet` off, the user sees checks fly by with no timing info. If one check hangs (e.g., `curl` hitting a timeout), there's no indication of how long has been spent or which check is responsible.

**Fix — Wrap each check with a timing shim in `smoke-test.sh`:**

```bash
# smoke-test.sh — add at top, after declare arrays:
_CHECK_START=$(date +%s%N)

_timed_check() {
    local label="$1"; shift
    local t_start t_end elapsed_ms
    t_start=$(date +%s%N)
    "$@"
    t_end=$(date +%s%N)
    elapsed_ms=$(( (t_end - t_start) / 1000000 ))
    # Only surface slow checks (>2s) to avoid noise
    if (( elapsed_ms > 2000 )) && [[ "$QUIET" == false ]]; then
        log_warn "  ↳ slow check '${label}': ${elapsed_ms}ms"
    fi
}

# Wrap each check call in main():
main() {
    require_root
    trap '_print_summary' EXIT
    [[ "$QUIET" == false ]] && log_header "VaultWarden-OCI Smoke Test"
    load_env_file 2>/dev/null || true

    _timed_check "env-file"          check_env_file
    _timed_check "domain"            check_domain_configured
    _timed_check "containers"        check_containers_running
    _timed_check "tls"               check_tls_certificate
    _timed_check "http"              check_http_endpoints
    _timed_check "age-key"           check_age_key
    _timed_check "secrets"           check_secrets_decryptable
    _timed_check "docker-secrets"    check_docker_secrets_materialized
    _timed_check "backup"            check_backup_exists
    _timed_check "systemd-timers"    check_systemd_timers
    _timed_check "crowdsec"          check_crowdsec
    _timed_check "disk-space"        check_disk_space

    (( _FAIL == 0 ))
}
```


***

## 14. `restore-run.sh` Error Messages Lack Actionable Next Steps

**Why:** When `restore-run.sh` fails to find `.env`, the error block is well written. But for errors deeper in the restore pipeline (decryption failure, Docker not running, lock contention), the error message is just `log_error "..."` with no "here's what to do" hint. A user in disaster recovery mode is already stressed — actionable guidance is critical.

**Fix — Add a `log_hint()` function to `lib/log.sh` for post-error guidance:**

```bash
# lib/log.sh — add:
log_hint() {
    _should_log "INFO" || return 0
    local ts tag
    ts=$(_get_timestamp); tag="${_VW_CALLING_SCRIPT:-log.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] HINT → %s%s\n' \
            "${COLOR_BLUE}" "$ts" "$tag" "$*" "${COLOR_RESET}"
    else
        printf '[%s] [%s] HINT → %s\n' "$ts" "$tag" "$*"
    fi
}
export -f log_hint
```

**Usage in `restore-run.sh`:**

```bash
# Before (existing):
log_error "SOPS decryption failed for ${backup_file}"

# After:
log_error "SOPS decryption failed for ${backup_file}"
log_hint  "Verify your age key is in place: ls -la \${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
log_hint  "Test decryption manually: SOPS_AGE_KEY_FILE=<path> sops -d secrets/secrets.yaml"
```


***

## 15. `Makefile` `setup` Target Silently Ignores `--domain`/`--email` Not Being Pre-Set

**Why:** `make setup` checks that `.env` exists but immediately calls `./setup.sh` without `--domain` or `--email`. If the user runs `make setup` from a fresh clone following the README, `setup.sh` prints the help text and exits with code 1 — but the Makefile shows `==> FAILED: setup.sh` with no explanation of *why* it failed.

**Fix — Add a preflight check in the `setup` target:**

```makefile
setup: ## Run initial setup (requires sudo)
	$(call require-root)
	@if [ ! -f ".env" ]; then \
		echo "$(RED)Error: .env is missing.$(NC)"; \
		echo "$(YELLOW)Run setup directly instead:$(NC)"; \
		echo "$(GREEN)  sudo ./setup.sh install --domain vault.example.com --email you@example.com$(NC)"; \
		exit 1; \
	fi
	@# Validate .env has real DOMAIN/ADMIN_EMAIL values
	@if grep -qE '^DOMAIN=(vault\.example\.com|$$|CHANGE_ME)' .env 2>/dev/null; then \
		echo "$(RED)Error: DOMAIN is still a placeholder in .env.$(NC)"; \
		echo "$(YELLOW)Set your real domain before running setup:$(NC)"; \
		echo "$(GREEN)  sudo ./setup.sh install --domain your.real.domain --email you@example.com$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)==> Running setup.sh$(NC)" | tee -a setup.log
	# ... rest of target unchanged
```


***

## 16. `dashboard.sh` Unban IP Input Has No Validation

**Why:** In `handle_security_menu()`, the "Unban an IP" option strips whitespace from user input but runs `cscli decisions delete --ip "${ip_to_unban}"` with zero validation. A typo like `192.168.1` (incomplete) or a stray special character would be passed directly to `cscli` and could produce confusing output or a command injection risk via shell expansion.

**Fix — Validate using the existing `validate_ip` from `lib/validate.sh`:**

```bash
# dashboard.sh — source validate.sh at top alongside other libs:
# (add to the source block near REPO_ROOT setup)
[[ -f "${REPO_ROOT}/lib/validate.sh" ]] && source "${REPO_ROOT}/lib/validate.sh"

# In handle_security_menu() case 2:
2)
    echo ""
    local ip_to_unban
    printf " Enter IP address to unban: "
    read -r ip_to_unban
    ip_to_unban="${ip_to_unban//[[:space:]]/}"
    if [[ -z "${ip_to_unban}" ]]; then
        echo -e "${YLW} No IP entered — operation cancelled.${NC}"
        _press_enter; return
    fi
    # Validate before passing to cscli
    if ! validate_ip "${ip_to_unban}" 2>/dev/null; then
        echo -e "${RED} Invalid IP address format: '${ip_to_unban}'${NC}"
        echo -e "${YLW} Expected format: 192.168.1.100${NC}"
        _press_enter; return
    fi
    # Proceed with validated IP only
    run_sudo_cmd "sudo cscli decisions delete --ip ${ip_to_unban}" \
        cscli decisions delete --ip "${ip_to_unban}"
    ;;
```


***

## 17. `setup.sh` `--force` Warning Is Buried Mid-Log, Not Visually Distinct

**Why:** The `--force` flag regenerates the Age encryption key and permanently orphans all existing encrypted backups. The warning is emitted via `log_error` lines — but those are the same color/weight as every other error, so the severity doesn't visually register.

**Fix — Use a boxed warning banner for this specific case:**

```bash
# setup.sh — replace the log_error block for --force with:
_warn_force_destructive() {
    local border
    border=$(printf '═%.0s' {1..62})
    printf '\n%s╔%s╗%s\n' "${COLOR_BOLD_RED}" "$border" "${COLOR_RESET}"
    printf '%s║  %-60s  ║%s\n' "${COLOR_BOLD_RED}" "⚠  DESTRUCTIVE: --force WILL ROTATE YOUR AGE KEY" "${COLOR_RESET}"
    printf '%s║  %-60s  ║%s\n' "${COLOR_BOLD_RED}" "   All existing encrypted backups become UNRECOVERABLE" "${COLOR_RESET}"
    printf '%s║  %-60s  ║%s\n' "${COLOR_BOLD_RED}" "   unless you export a recovery kit FIRST." "${COLOR_RESET}"
    printf '%s║%s║%s\n' "${COLOR_BOLD_RED}" "$(printf ' %.0s' {1..62})" "${COLOR_RESET}"
    printf '%s║  %-60s  ║%s\n' "${COLOR_BOLD_RED}" "   Run first: ./utilities/secrets-export-recovery-kit.sh" "${COLOR_RESET}"
    printf '%s╚%s╝%s\n\n' "${COLOR_BOLD_RED}" "$border" "${COLOR_RESET}"
}

# Replace the log_error block:
if [[ "$FORCE" == "true" ]] && [[ "${VW_FORCE_ACK:-}" != "I_UNDERSTAND_LOSING_OLD_BACKUPS" ]]; then
    _warn_force_destructive
    read -r -p "Type YES to confirm you have exported a recovery kit: " _force_answer
    # ... rest unchanged
fi
```


***

## 18. `lib/log.sh` Timestamps Use 24-hour Local Time With No Date

**Why:** `_get_timestamp()` returns only `HH:MM:SS`. For operations that run overnight (e.g., systemd-triggered backup/maintenance), or when reviewing a log after the fact, the time alone is ambiguous — you can't tell which day the log entry is from without cross-referencing `journalctl`.

**Fix — Add an optional date-prefix flag and use ISO format for file-redirected output:**

```bash
# lib/log.sh — update _get_timestamp():
_get_timestamp() {
    if [[ "$LOG_TIMESTAMP" != "true" ]]; then
        printf ''
        return
    fi
    # If stdout is NOT a terminal (e.g., redirected to a log file),
    # include the date for unambiguous log review.
    if [[ ! -t 1 ]]; then
        date '+%Y-%m-%d %H:%M:%S'
    else
        date '+%H:%M:%S'
    fi
}
```


***

## 19. `maintenance.sh` Dispatcher Has No `--help` Propagation to Subcommands

**Why:** Running `./maintenance.sh health --help` should show the health subcommand's help. But the dispatcher uses `exec "$SCRIPT_DIR/utilities/maintenance-health.sh" "$@"` — which works, but the top-level `help` case calls `exec "$0"` (re-executes itself with no args), which recurses and shows only the top-level usage, not the subcommand help. This is confusing for users exploring options.

**Fix — Reroute `<subcommand> --help` to the right utility directly:**

```bash
# maintenance.sh — update the dispatcher:
_TASK="${1}"; shift || true

# If the next arg is --help or -h, show subcommand-specific help
_HELP_FLAG=false
for _arg in "$@"; do
    [[ "$_arg" == "--help" || "$_arg" == "-h" ]] && _HELP_FLAG=true
done

case "$_TASK" in
    health)         exec "$SCRIPT_DIR/utilities/maintenance-health.sh" "$@" ;;
    update)         exec "$SCRIPT_DIR/utilities/maintenance-update.sh" "$@" ;;
    db-maint)       exec "$SCRIPT_DIR/utilities/maintenance-db-maint.sh" "$@" ;;
    test-email)     exec "$SCRIPT_DIR/utilities/maintenance-email.sh" "$@" ;;
    update-dns)     exec "$SCRIPT_DIR/utilities/maintenance-update-dns.sh" "$@" ;;
    update-firewall) exec "$SCRIPT_DIR/utilities/maintenance-update-firewall.sh" "$@" ;;
    run)            exec "$SCRIPT_DIR/utilities/maintenance-run.sh" "$@" ;;
    help|--help|-h) exec "$0" ;;  # show top-level help (no args)
    *)
        echo "ERROR: Unknown subcommand: '$_TASK'" >&2
        echo "Valid subcommands: health update db-maint test-email update-dns update-firewall run" >&2
        echo "Run './maintenance.sh help' to see all options." >&2
        exit 1
        ;;
esac
```


***

## 20. `dashboard.sh` Has No Input Timeout on the Main Read Loop

**Why:** `read -r -p " Enter option : " opt` blocks indefinitely. If the dashboard is left open on an unattended terminal, the live stats header (showing container state, ban count, last backup) stales without refreshing. A user could look at `Stopped` status for hours without realizing a container has since restarted.

**Fix — Add a `read` timeout that auto-refreshes:**

```bash
# dashboard.sh — in the main event loop:
while true; do
    clear
    draw_header
    draw_live_stats
    case "${ACTIVE_MENU}" in
        main)     draw_main_menu     ;;
        # ... other menus
    esac

    local opt
    # Timeout after 60s and redraw — keeps live stats fresh.
    # -t 0 returns immediately on non-interactive stdin (piped input).
    if read -r -t 60 -p " Enter option  : " opt 2>/dev/null; then
        : # user typed something
    else
        # Timeout — loop back and redraw live stats
        continue
    fi

    opt="${opt//[[:space:]]/}"
    opt="${opt,,}"
    # ... rest of dispatch unchanged
done
```


***

## 21. `setup.sh` Secrets Phase Summary Repeats Commands Already Shown

**Why:** In both `auto` and `interactive` mode, `show_post_install_summary()` prints the `edit-secrets.sh rotate` commands for Cloudflare tokens in the "Configure secrets" step AND again in the "Inject CrowdSec CF secrets" step — identical commands, copy-pasted twice. This creates noise and makes users unsure whether they need to run these once or twice.

**Fix — Deduplicate using a `_cf_secret_cmds` variable:**

```bash
show_post_install_summary() {
    # ...
    # Define once, reference twice
    local _cf_cmds
    _cf_cmds=$(cat <<'CF'
   sudo ./edit-secrets.sh rotate cloudflare_zone_id
   sudo ./edit-secrets.sh rotate cf_account_id
   sudo ./edit-secrets.sh rotate cf_worker_bouncer_token
CF
)

    printf '2. Configure secrets:   %s./setup.sh secrets%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
    printf '3. Set CF + CrowdSec tokens:\n%s\n' "$_cf_cmds"
    printf '   Then run: %ssudo ./utilities/setup-crowdsec.sh%s\n' \
        "${COLOR_YELLOW}" "${COLOR_RESET}"
    # Step 4 no longer repeats the same CF commands
    printf '4. Start services: %smake up%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
}
```


***

## 22. `validate.sh` `validate_email` Rejects Valid Subdomained Addresses

**Why:** The current regex `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$` fails to match valid emails like `user@mail.subdomain.example.com` because `[a-zA-Z0-9.-]+` requires the dot to be followed by `[a-zA-Z]{2,}` at the end — but subdomain emails with hyphens in the domain pass inconsistently. More critically, it rejects new TLDs longer than what the TLD list had when the regex was written.

**Fix — Modernize the regex to handle realistic RFC 5321 email shapes:**

```bash
# lib/validate.sh — replace validate_email():
validate_email() {
    local email="$1"
    # RFC 5321: maximum total length is 254 characters.
    [[ ${#email} -le 254 ]] || return 1
    # local-part: up to 64 chars; domain: at least one dot, valid chars
    local local_part domain
    local_part="${email%%@*}"
    domain="${email#*@}"
    [[ ${#local_part} -le 64 ]] || return 1
    [[ ${#domain} -le 253 ]] || return 1
    # local-part: alphanumeric + . _ % + - (no leading/trailing dots)
    [[ "$local_part" =~ ^[a-zA-Z0-9_%+][a-zA-Z0-9._%+-]*[a-zA-Z0-9_%+]$|^[a-zA-Z0-9_%+]$ ]] || return 1
    # domain: labels separated by dots, each label 1–63 chars, ending with TLD 2+ chars
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || return 1
    return 0
}
```


***

## 23. `dashboard.sh` Status Bar Has No Visual Indicator for `CHANGE_ME` Secrets

**Why:** The live stats bar shows container health and disk space but gives no indication if any secrets in `secrets.yaml` still contain `CHANGE_ME` placeholders. A user could start the stack with a `CHANGE_ME` SMTP password and never notice until email delivery silently fails.

**Fix — Add a placeholder warning check to `draw_live_stats()`:**

```bash
# dashboard.sh — add to draw_live_stats(), after the disk line:

# --- Placeholder secrets check ---
_placeholder_check() {
    local secrets_file="${REPO_ROOT}/secrets/secrets.yaml"
    if [[ ! -f "$secrets_file" ]]; then
        printf "${YLW}secrets.yaml not found${NC}"
        return
    fi
    # Check decrypted output for CHANGE_ME values without storing key material
    local count=0
    if command -v sops >/dev/null 2>&1; then
        count=$(sops -d "$secrets_file" 2>/dev/null \
            | grep -c 'CHANGE_ME' || echo 0)
    fi
    if (( count > 0 )); then
        printf "${RED}⚠  ${count} CHANGE_ME placeholder(s) still set${NC}"
    else
        printf "${GRN}OK${NC}"
    fi
}

local _ph_status
_ph_status="$(_placeholder_check)"
echo -e " ${BLD}Secrets health:${NC}  ${_ph_status}"
```


---

# Continue on with another list of improvements.

Now I have a thorough picture of all remaining scripts. Here is the third batch of UI/UX improvements:

***

## 24. `backup-run.sh` Has No Human-Readable Size in the Completion Summary

**Why:** After a backup completes, the script logs file paths but no size. Users have no immediate confirmation of whether a "full backup" wrote 2 MB or 2 GB — two very different outcomes, one of which signals a likely failure silently.

**Fix — Add a size report line to the backup completion log:**

```bash
# utilities/backup-run.sh — add this helper and call it after backup creation:
_log_backup_size() {
    local backup_file="$1"
    if [[ ! -f "$backup_file" ]]; then
        log_warn "Backup file not found for size check: $backup_file"
        return
    fi
    local size_bytes size_human
    size_bytes=$(stat -c '%s' "$backup_file" 2>/dev/null \
        || stat -f '%z' "$backup_file" 2>/dev/null || echo 0)
    if (( size_bytes < 1024 )); then
        size_human="${size_bytes} B"
    elif (( size_bytes < 1048576 )); then
        size_human="$(( size_bytes / 1024 )) KB"
    elif (( size_bytes < 1073741824 )); then
        size_human="$(( size_bytes / 1048576 )) MB"
    else
        size_human="$(( size_bytes / 1073741824 )) GB"
    fi
    log_success "Backup created: $(basename "$backup_file") (${size_human})"
    # Warn if suspiciously small (< 4KB likely indicates empty/failed backup)
    if (( size_bytes < 4096 )); then
        log_warn "Backup file is unusually small (${size_human}) — verify integrity: sudo ./backup.sh verify"
    fi
}
```


***

## 25. `pre-production-drill.sh` Passes/Fails Are All the Same Visual Weight

**Why:** `_step_pass()` uses `log_success` (green `✓`) and `_step_fail()` uses `log_error` (red `✗`), but the final summary just prints raw counts with `printf`. When 11 steps pass and 1 fails, the failure count is buried in the same prose block as the pass count — it doesn't visually stand out and could be missed on a quick scroll.

**Fix — Make the final summary color-aware and failure-prominent:**

```bash
# utilities/pre-production-drill.sh — replace the final summary block:
_print_drill_summary() {
    printf '\n'
    log_header "Pre-Production Drill Summary"

    printf '  %s%-10s%s %d / %d steps\n' \
        "${COLOR_GREEN}" "Passed:" "${COLOR_RESET}" "$_STEPS_PASSED" "$_STEPS_TOTAL"

    if (( _STEPS_SKIPPED > 0 )); then
        printf '  %s%-10s%s %d\n' \
            "${COLOR_YELLOW}" "Skipped:" "${COLOR_RESET}" "$_STEPS_SKIPPED"
    fi

    if (( _STEPS_FAILED > 0 )); then
        printf '\n'
        printf '  %s%-10s%s %d\n' \
            "${COLOR_BOLD_RED}" "FAILED:" "${COLOR_RESET}" "$_STEPS_FAILED"
        printf '\n'
        printf '  %sFailed steps:%s\n' "${COLOR_BOLD_RED}" "${COLOR_RESET}"
        for step in "${_FAILED_STEPS[@]}"; do
            printf '    %s• %s%s\n' "${COLOR_RED}" "$step" "${COLOR_RESET}"
        done
        printf '\n'
        log_error "Drill FAILED — resolve the issues above before go-live."
        return 1
    else
        printf '\n'
        log_success "All drill steps passed — stack is ready for production go-live."
    fi
}
```


***

## 26. `startup.sh` `_STARTUP_WARNINGS` Array Is Populated But Never Displayed on Success

**Why:** `startup.sh` accumulates non-fatal warnings in `_STARTUP_WARNINGS=()` during startup. Looking at the code, functions append to this array but the final success banner never iterates and displays it. So warnings about email misconfiguration, placeholder secrets, or skipped health checks disappear silently after a successful start.

**Fix — Print the warnings array in the post-startup banner:**

```bash
# startup.sh — in the post-startup success banner function, add:
_print_startup_banner() {
    log_header "VaultWarden-OCI Started Successfully"
    log_success "Domain   : ${DOMAIN:-unknown}"
    log_success "State dir: ${PROJECT_STATE_DIR:-unknown}"

    if (( ${#_STARTUP_WARNINGS[@]} > 0 )); then
        printf '\n'
        log_warn "Startup completed with ${#_STARTUP_WARNINGS[@]} warning(s):"
        for w in "${_STARTUP_WARNINGS[@]}"; do
            printf '  %s⚠  %s%s\n' "${COLOR_YELLOW}" "$w" "${COLOR_RESET}"
        done
        printf '\n'
        log_warn "These warnings are non-fatal but should be resolved before production use."
    fi
}
```


***

## 27. `secrets-rotate.sh` `--help` Dynamically Lists Fields But Falls Back Silently

**Why:** The `show_help()` in `secrets-rotate.sh` dynamically pulls field names from `secrets-schema.yaml` via `yq`. If `yq` is not installed — which is common on a freshly provisioned OCI instance — the help silently prints `(schema not available — run after setup.sh install)` with no guidance on *why* it's unavailable or how to fix it.

**Fix — Surface the reason and provide a fallback static list:**

```bash
# utilities/secrets-rotate.sh — update the show_help() schema section:
if command -v yq > /dev/null 2>&1 \
        && [[ -f "${PROJECT_ROOT}/secrets-schema.yaml" ]]; then
    while IFS= read -r _hkey; do
        local _hlabel
        _hlabel=$(schema_field_safe "$_hkey" label 2>/dev/null)
        if [[ -n "$_hlabel" ]]; then
            printf '    %-35s (%s)\n' "$_hkey" "$_hlabel"
        else
            printf '    %s\n' "$_hkey"
        fi
    done < <(schema_keys)
else
    # Identify the exact reason for fallback so the user can fix it
    if ! command -v yq > /dev/null 2>&1; then
        printf '    %s(yq not installed — install with: snap install yq  or  apt install yq)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}" >&2
    elif [[ ! -f "${PROJECT_ROOT}/secrets-schema.yaml" ]]; then
        printf '    %s(secrets-schema.yaml not found — run setup.sh install first)%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}" >&2
    fi
    # Static fallback so --help is still useful without yq
    printf '    %-35s (auto-generated admin token)\n' "admin_token"
    printf '    %-35s (bcrypt hash for Caddy)\n'      "caddy_admin_password"
    printf '    %-35s (backup encryption passphrase)\n' "backup_passphrase"
    printf '    %-35s (Cloudflare DNS API token)\n'   "caddy_cloudflare_dns_token"
    printf '    %-35s (SMTP relay password)\n'         "smtp_password"
    printf '    %-35s (email API key)\n'               "email_api_token"
    printf '    ... run after setup.sh install for the full list\n'
fi
```


***

## 28. `lib/email.sh` Rate-Limit Failure Message Has No Retry ETA

**Why:** When email rate-limiting trips (the `_rate_limit_check` function), `send_notification_email` returns non-zero with a log message, but the message doesn't tell the operator *when* the rate limit window resets. They're left guessing whether to wait 5 minutes or 24 hours.

**Fix — Surface the reset time in the rate-limit warning:**

```bash
# lib/email.sh — update the rate-limit exceeded message wherever it fires:
_rate_limit_exceeded_msg() {
    local rate_dir="$1"
    local window_file="${rate_dir}/.window_start"
    local reset_msg="unknown"

    if [[ -f "$window_file" ]]; then
        local window_start window_seconds reset_epoch
        window_start=$(cat "$window_file" 2>/dev/null || echo 0)
        # Default window: 3600s (1 hour) — adjust to match your _rate_limit_check logic
        window_seconds="${EMAIL_RATE_WINDOW_SECONDS:-3600}"
        reset_epoch=$(( window_start + window_seconds ))
        local now
        now=$(date +%s)
        if (( reset_epoch > now )); then
            local remaining=$(( reset_epoch - now ))
            local mins=$(( remaining / 60 ))
            local secs=$(( remaining % 60 ))
            reset_msg="resets in ${mins}m ${secs}s (at $(date -d "@${reset_epoch}" '+%H:%M' 2>/dev/null || date -r "$reset_epoch" '+%H:%M'))"
        else
            reset_msg="window may have already reset — try: ./maintenance.sh test-email"
        fi
    fi

    log_warn "Email rate limit reached — ${reset_msg}"
    log_warn "To reset manually: clear_email_rate_limit"
}
```


***

## 29. `dashboard.sh` Submenus Have No Item Count in the Main Menu

**Why:** The main menu shows `[ b ] Backup & Restore` with no indication of how many options are inside. Users have to open each submenu to explore. This is a minor discoverability issue but adds navigation friction, especially for new operators learning the tool.

**Fix — Add a parenthetical item count to each main menu entry:**

```bash
# dashboard.sh — update draw_main_menu():
draw_main_menu() {
    echo -e " ${BLD}Main Menu${NC}"
    echo ""
    echo -e "  [ ${GRN}1${NC} ] Stack Control         (start / stop / restart / status)"
    echo -e "  [ ${GRN}2${NC} ] View Logs             (vaultwarden / caddy / postfix / all)"
    echo -e "  [ ${GRN}b${NC} ] Backup & Restore      (4 options)"
    echo -e "  [ ${GRN}s${NC} ] Security & CrowdSec   (5 options)"
    echo -e "  [ ${GRN}k${NC} ] Secrets & Keys        (4 options)"
    echo -e "  [ ${GRN}a${NC} ] Advanced & Maint.     (7 options)"
    echo -e "  [ ${GRN}i${NC} ] Identity, Email & Admin (4 options)"
    draw_divider
    echo -e "  [ ${RED}q${NC} ] Quit"
    echo ""
}
```


***

## 30. `setup.sh` Phase Failures Print Generic "Phase N failed" With No Suggestion

**Why:** When a phase fails, `setup.sh` logs `log_error "System setup failed"` and exits. This tells the operator *that* it failed but not *what to do next* — should they fix a dependency, re-run `--skip-deps`, check a log file, or look at a specific service?

**Fix — Add per-phase recovery hints to `lib/log.sh` via a new `log_recovery()` pattern and use it in `setup.sh`:**

```bash
# setup.sh — replace bare phase error handling:

# Phase 1
"${SCRIPT_DIR}/utilities/setup-system.sh" ... || {
    log_error "Phase 1 (System setup) failed"
    log_hint  "Check for missing packages: sudo apt-get update && sudo apt-get install -y docker.io age sops"
    log_hint  "Re-run just this phase: sudo ./utilities/setup-system.sh"
    log_hint  "Or skip it if deps are installed: sudo ./setup.sh install --domain ... --skip-deps"
    exit 1
}

# Phase 2
"${SCRIPT_DIR}/utilities/setup-storage.sh" ... || {
    log_error "Phase 2 (Storage setup) failed"
    log_hint  "If using a data device, verify it exists: ls -la \${DATA_VOLUME_DEVICE}"
    log_hint  "Re-run just this phase: sudo ./utilities/setup-storage.sh"
    exit 1
}

# Phase 4
"${SCRIPT_DIR}/utilities/setup-secrets.sh" ... || {
    log_error "Phase 4 (Secrets bootstrap) failed"
    log_hint  "Verify the age key was created: ls -la /etc/vaultwarden/age-key.txt"
    log_hint  "Re-run secrets only: sudo ./setup.sh secrets"
    exit 1
}
```


***

## 31. `restore-run.sh` Interactive Mode Has No Preview of Available Backups Before Selecting

**Why:** The interactive restore flow asks the user to select a backup, but there is no "here are the backups available on this machine" listing shown *before* the selection prompt. Users have to know to run `./backup.sh list` separately first, or guess what's available.

**Fix — Auto-display available backups at the start of interactive mode:**

```bash
# utilities/restore-run.sh — at the top of the interactive restore function,
# before the selection prompt:
_show_available_backups() {
    local base_dir="$1"
    printf '\n%s Available backups:%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
    printf '%s──────────────────────────────────────────────────%s\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}"

    local found=0
    for type_dir in "${base_dir}/db" "${base_dir}/full" "${base_dir}/emergency"; do
        [[ -d "$type_dir" ]] || continue
        local type_label
        type_label=$(basename "$type_dir")
        while IFS= read -r -d '' f; do
            local fname size_kb age_days
            fname=$(basename "$f")
            size_kb=$(( $(stat -c '%s' "$f" 2>/dev/null || echo 0) / 1024 ))
            age_days=$(_backup_filename_age_days "$f" 2>/dev/null || echo "?")
            printf '  [%s] %-50s  %4d KB  %s days old\n' \
                "$type_label" "$fname" "$size_kb" "$age_days"
            (( found++ ))
        done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null | sort -z)
    done

    if (( found == 0 )); then
        printf '  %s(no backups found in %s)%s\n' \
            "${COLOR_YELLOW}" "$base_dir" "${COLOR_RESET}"
    fi
    printf '%s──────────────────────────────────────────────────%s\n\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}"
}
```


***

## 32. `lib/common.sh` `retry_with_backoff` Gives No Visual Progress Between Retries

**Why:** `retry_with_backoff 5 2 some_command` waits silently between attempts — the operator sees only `Attempt N failed, retrying in Xs...` but has no indication of how many total attempts remain or what the total wait time could be.

**Fix — Enhance the retry log line to show remaining attempts and total max wait:**

```bash
# lib/common.sh — update retry_with_backoff():
retry_with_backoff() {
    local max_attempts="$1"
    local initial_delay="$2"
    shift 2
    local delay="$initial_delay"
    local i
    # Pre-compute total max wait for the operator's awareness
    local total_wait=0
    local d="$initial_delay"
    for (( j=1; j<max_attempts; j++ )); do
        total_wait=$(( total_wait + d ))
        d=$(( d * 2 ))
    done

    for ((i=1; i<=max_attempts; i++)); do
        if "$@"; then
            return 0
        fi
        if [[ $i -lt $max_attempts ]]; then
            local remaining=$(( max_attempts - i ))
            log_warn "Attempt ${i}/${max_attempts} failed — retrying in ${delay}s" \
                "(${remaining} attempt(s) left, max total wait: ${total_wait}s)"
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
    done

    log_error "All ${max_attempts} attempts failed for command: $1"
    return 1
}
```


***

## 33. `dashboard.sh` Has No `watch`-Style Auto-Refresh for Log Tailing

**Why:** Menu option "View Logs" runs `docker logs --tail 50 --follow`, which streams logs directly to the terminal. When the user presses `Ctrl+C` to stop tailing, the `INT` trap fires and exits the entire dashboard instead of returning to the menu. This is a significant UX bug — log viewing terminates the operator's session.

**Fix — Run log tailing in a subshell so `INT` is locally caught:**

```bash
# dashboard.sh — in handle_main_menu() or a logs submenu handler:
_tail_logs() {
    local container="$1" lines="${2:-50}"
    echo ""
    echo -e "${BLD} Tailing logs for: ${container}${NC}"
    echo -e "${CYN}${DIVIDER}${NC}"
    echo -e "${YLW} Press Ctrl+C to stop tailing and return to menu...${NC}"
    echo ""
    # Run in a subshell — INT kills only the subshell, not the dashboard
    (
        trap 'exit 0' INT
        docker logs --tail "$lines" --follow "$container" 2>&1
    ) || true
    echo ""
    echo -e "${CYN}${DIVIDER}${NC}"
    echo -e "${GRN} Log stream ended.${NC}"
    _press_enter
}
```


***

## 34. `setup.sh` Entropy Wait Has No User-Visible Countdown

**Why:** `setup.sh` exports `ENTROPY_THRESHOLD=200` and `ENTROPY_MAX_WAIT=60`, and somewhere in the secrets phase a wait loop blocks until `/proc/sys/kernel/random/entropy_avail` reaches threshold. On low-entropy VMs (common in OCI free-tier instances), this can silently stall for 30–60 seconds with no output.

**Fix — Add an entropy wait progress display to `lib/crypto.sh` or wherever the wait loop lives:**

```bash
# lib/crypto.sh — add or update the entropy wait function:
wait_for_entropy() {
    local threshold="${ENTROPY_THRESHOLD:-200}"
    local max_wait="${ENTROPY_MAX_WAIT:-60}"
    local entropy_file="/proc/sys/kernel/random/entropy_avail"

    [[ -f "$entropy_file" ]] || return 0  # non-Linux: skip

    local current waited=0
    current=$(cat "$entropy_file" 2>/dev/null || echo 9999)
    if (( current >= threshold )); then return 0; fi

    printf '\n'
    log_warn "Low system entropy (${current} < ${threshold}) — waiting for entropy pool to fill..."
    log_warn "On cloud VMs, install haveged to speed this up: sudo apt install haveged"

    while (( waited < max_wait )); do
        current=$(cat "$entropy_file" 2>/dev/null || echo 9999)
        if (( current >= threshold )); then
            printf '\r%s ✔  Entropy ready: %d bits (waited %ds)%s\n' \
                "${COLOR_GREEN}" "$current" "$waited" "${COLOR_RESET}"
            return 0
        fi
        # Show live countdown every 5 seconds
        if (( waited % 5 == 0 )); then
            printf '\r%s ⏳ Entropy: %d/%d bits — %ds elapsed, max %ds...%s' \
                "${COLOR_YELLOW}" "$current" "$threshold" "$waited" "$max_wait" "${COLOR_RESET}"
        fi
        sleep 1
        (( waited++ ))
    done

    printf '\n'
    log_warn "Entropy threshold not reached after ${max_wait}s (current: ${current})"
    log_warn "Proceeding anyway — key generation quality may be reduced on this VM."
    return 0  # non-fatal
}
```


***

## 35. `Makefile` `help` Output Has No Grouping for Dangerous vs. Safe Targets

**Why:** `make help` uses the `awk` pattern to extract `##` doc comments into a nicely formatted list, and `##@` groups create sections. However, destructive targets like `uninstall`, `prune`, `clean-all`, and `breakglass-create` are mixed into sections alongside read-only operations (`status`, `health`, `logs`). There's no visual distinction to warn an operator running `make help` on a production box.

**Fix — Add a dedicated `##@ ⚠ Destructive Operations` group and move dangerous targets into it:**

```makefile
# Makefile — restructure the target groupings:

##@ ⚠  Destructive Operations (read warnings carefully)

uninstall: ## DESTRUCTIVE: Remove VaultWarden-OCI from this host
	$(call require-root)
	@echo "$(RED)╔══════════════════════════════════════════╗$(NC)"
	@echo "$(RED)║  UNINSTALL: All data will be removed.    ║$(NC)"
	@echo "$(RED)╚══════════════════════════════════════════╝$(NC)"
	@printf "$(RED)Type YES to confirm: $(NC)"; read ans; [ "$$ans" = "YES" ] || exit 1
	@bash ./utilities/uninstall-vaultwarden.sh

clean-all: ## DESTRUCTIVE: Remove ALL generated files, logs, and Docker volumes
	$(call require-root)
	@printf "$(RED)This removes all local data. Type YES to confirm: $(NC)"; \
	 read ans; [ "$$ans" = "YES" ] || exit 1
	# ... rest of target

prune: ## Remove unused Docker images and volumes (may free disk but cannot be undone)
	$(call check-docker)
	@printf "$(YELLOW)Prune Docker resources? [y/N]: $(NC)"; \
	 read ans; [ "$${ans,,}" = "y" ] || exit 0
	$(DOCKER_COMP) -f $(COMPOSE_FILE) down --remove-orphans
	docker system prune -f
```


---

***

## 36. `backup.sh list` Has No Table Formatting — Pure Log Lines

**Why:** `./backup.sh list` runs through `backup-run.sh` and emits each backup via `log_info` in the form `[timestamp] [backup-run.sh] INFO /var/lib/vaultwarden/backups/db/vw_db_2026...age`. These are raw log lines — no columns, no alignment, no size, no age coloring — making it hard to scan 15+ backups visually.

**Fix — Replace `log_info` calls in the list path with a formatted table renderer:**

```bash
# utilities/backup-run.sh — replace raw log_info listing with:
_print_backup_table() {
    local base_dir="$1"
    local types=("db" "full" "emergency")
    local has_any=0

    printf '\n%s%-12s %-52s %8s %6s%s\n' \
        "${COLOR_BOLD}" "TYPE" "FILENAME" "SIZE" "AGE" "${COLOR_RESET}"
    printf '%s%s%s\n' "${COLOR_CYAN}" \
        "$(printf '─%.0s' {1..82})" "${COLOR_RESET}"

    for type in "${types[@]}"; do
        local type_dir="${base_dir}/${type}"
        [[ -d "$type_dir" ]] || continue
        while IFS= read -r -d '' f; do
            local fname size_kb age_days age_color
            fname=$(basename "$f")
            size_kb=$(( $(stat -c '%s' "$f" 2>/dev/null || echo 0) / 1024 ))
            age_days=$(_backup_filename_age_days "$f" 2>/dev/null || echo "?")
            # Color-code by age: green <3d, yellow <14d, red >=14d
            if [[ "$age_days" =~ ^[0-9]+$ ]]; then
                (( age_days < 3 ))  && age_color="${COLOR_GREEN}"
                (( age_days >= 3 && age_days < 14 )) && age_color="${COLOR_YELLOW}"
                (( age_days >= 14 )) && age_color="${COLOR_RED}"
            else
                age_color="${COLOR_RESET}"
            fi
            printf '%-12s %-52s %6d KB %s%5s d%s\n' \
                "$type" "$fname" "$size_kb" \
                "$age_color" "$age_days" "${COLOR_RESET}"
            (( has_any++ ))
        done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null | sort -z)
    done

    if (( has_any == 0 )); then
        printf '  %s(no backups found)%s\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
    fi
    printf '\n'
}
```


***

## 37. `maintenance-run.sh` Phase Labels Are Inconsistent With `setup.sh`

**Why:** `setup.sh` uses `log_header "=== Phase N: ... ==="` for each phase, while `maintenance-run.sh` uses `log_info "=== Phase N: ... ==="` (lowercase, no header weight). This means maintenance runs look visually lighter and harder to scan in `journalctl` output than setup runs — especially when diagnosing a 3am automated maintenance failure.

**Fix — Standardize on `log_header` for all phase boundaries:**

```bash
# utilities/maintenance-run.sh — replace log_info phase labels:

# Before:
log_info "=== Phase 1: System Cleanup ==="
log_info "=== Phase 2: SAFE System Optimization ==="
log_info "=== Phase 3: SAFE Security & Network Maintenance ==="

# After:
log_header "Phase 1 — System Cleanup"
log_header "Phase 2 — System Optimization"
log_header "Phase 3 — Security & Network Maintenance"
```

Also standardize the maintenance summary exit message — currently it varies between scripts:

```bash
# maintenance-run.sh — unified exit summary:
_print_maintenance_summary() {
    local overall="$1"  # 0=success, 1=minor, 2=critical
    printf '\n'
    log_header "Maintenance Summary"
    case "$overall" in
        0) log_success "All maintenance phases completed successfully." ;;
        1) log_warn    "Maintenance completed with minor issues — review above." ;;
        2) log_error   "Maintenance completed with CRITICAL failures — action required." ;;
    esac
    printf '  Duration: %s\n' "$(_elapsed_since "${_MAINT_START_EPOCH:-0}")"
}
```


***

## 38. `startup.sh` Ignores `--dry-run` for the Docker Pull Step

**Why:** `startup.sh` has a `DRY_RUN=true` path that skips most actions. However, the `docker compose pull` step checks `SKIP_PULL` but not `DRY_RUN` — meaning `./startup.sh --dry-run` actually pulls images. On a metered OCI instance, this silently consumes bandwidth and time during what should be a no-op preview.

**Fix:**

```bash
# startup.sh — in the image pull block, add DRY_RUN guard:
if [[ "$SKIP_PULL" != "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker compose pull"
    else
        log_info "Pulling latest images..."
        docker compose -f "${PROJECT_ROOT}/docker-compose.yml" pull || {
            log_warn "docker compose pull failed — continuing with local images"
        }
    fi
fi
```


***

## 39. `lib/log.sh` Has No `log_hint()` Function Despite Being Referenced

**Why:** Multiple scripts (and Improvement \#30 above) reference `log_hint` as the natural "here's what to do next" log level — but `lib/log.sh` only defines `log_info`, `log_warn`, `log_error`, `log_success`, `log_debug`, and `log_header`. If any script calls `log_hint`, it silently falls through as a command-not-found in a subshell or causes `set -e` exits.

**Fix — Add `log_hint` to `lib/log.sh` as a first-class level:**

```bash
# lib/log.sh — add after log_success():
log_hint() {
    _should_log "HINT" || return 0
    local ts tag
    ts=$(_get_timestamp)
    tag="${_VW_CALLING_SCRIPT:-log.sh}"
    if [[ "$LOG_COLORS" == "true" ]]; then
        printf '%s[%s] [%s] HINT  →%s %s\n' \
            "${COLOR_CYAN}" "$ts" "$tag" "${COLOR_RESET}" "$*"
    else
        printf '[%s] [%s] HINT  → %s\n' "$ts" "$tag" "$*"
    fi
}
```

The `→` prefix visually separates hints from informational lines and makes them easy to grep in logs:

```bash
journalctl -u vaultwarden-setup | grep 'HINT'
```


***

## 40. `dashboard.sh` Has No Keyboard Shortcut Help Line at the Bottom

**Why:** The dashboard renders a menu, a divider, and a prompt but no persistent "keyboard hint" footer. New operators don't know they can type `q` to quit, `b` to go back, or that all inputs are case-insensitive. This is a discoverability gap that forces trial-and-error navigation.

**Fix — Add a single-line keyboard legend to `draw_footer()`:**

```bash
# dashboard.sh — add draw_footer() and call it after every menu draw:
draw_footer() {
    printf '%s  %-78s%s\n' "${DIM:-\e[2m}" \
        "  Keys: number/letter = select  |  b = back  |  q = quit  |  Ctrl+C = exit" \
        "${NC}"
}

# Call it at the end of every draw_*_menu function:
draw_main_menu() {
    # ... existing content ...
    draw_footer   # ← add this line at the bottom
}
```


***

## 41. `utilities/setup-env.sh` Validates `--domain` Only for Emptiness, Not Format

**Why:** `setup-env.sh` checks `[[ -z "$DOMAIN" ]]` but does not validate the format. A user passing `--domain vault.example.com/` (trailing slash), `--domain http://vault.example.com` (scheme prefix), or `--domain vault` (no TLD) all pass validation and silently produce a broken `.env` and Caddy config.

**Fix — Add lightweight domain format validation:**

```bash
# utilities/setup-env.sh — add after _parse_args():
_validate_domain() {
    local domain="$1"
    # Must not contain scheme, path, port, or trailing slash
    if [[ "$domain" =~ ^https?:// ]]; then
        log_error "DOMAIN must not include a scheme (http:// or https://)"
        log_hint  "Use: --domain vault.example.com  (not https://vault.example.com)"
        return 1
    fi
    if [[ "$domain" =~ [/:?#] ]]; then
        log_error "DOMAIN must be a plain hostname — no paths, ports, or query strings"
        log_hint  "Use: --domain vault.example.com"
        return 1
    fi
    # Must have at least one dot (basic TLD check)
    if [[ "$domain" != *.* ]]; then
        log_error "DOMAIN appears to be a bare hostname with no TLD: '${domain}'"
        log_hint  "Use a fully qualified domain like: vault.example.com"
        return 1
    fi
    # Must not start or end with a dot or hyphen
    if [[ "$domain" =~ ^[.-] || "$domain" =~ [.-]$ ]]; then
        log_error "DOMAIN must not start or end with a dot or hyphen: '${domain}'"
        return 1
    fi
    return 0
}

# In main(), after _parse_args():
_validate_domain "$DOMAIN" || exit 1
```


***

## 42. `lib/common.sh` `require_root` Error Has No `sudo` Hint

**Why:** When a user runs `./backup.sh run` without `sudo`, `require_root` fires `log_error "This script must be run as root"` and exits. That's correct, but it doesn't tell them *how* to re-run it — especially for newer operators who may not know which exact command to prepend with `sudo`.

**Fix — Echo the exact re-run command with `sudo`:**

```bash
# lib/common.sh — update require_root():
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        # Reconstruct the likely sudo invocation from $0 and original args
        local script_name
        script_name="$(basename "$0")"
        log_hint  "Re-run with: sudo ./${script_name} ${*}"
        exit 1
    fi
}
```


***

## 43. `secrets-rotate.sh` Rotation Doesn't Show a Before/After Confirmation Diff

**Why:** `secrets-rotate.sh` re-encrypts `secrets.yaml` and re-syncs Docker bind-mount files, but gives no "what changed" summary. After rotating `admin_token`, the operator has no terminal confirmation of the new value (truncated) or which services were restarted. They have to manually `sops -d secrets/secrets.yaml` and grep to verify.

**Fix — Print a redacted rotation receipt at the end:**

```bash
# utilities/secrets-rotate.sh — add after successful rotation:
_print_rotation_receipt() {
    local field="$1"
    local new_hash="$2"     # bcrypt/argon hash — safe to show
    local services_restarted=("${@:3}")

    printf '\n'
    log_header "Rotation Complete"
    printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "Field rotated:" "${COLOR_RESET}" "$field"
    printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "New hash prefix:" "${COLOR_RESET}" \
        "${new_hash:0:20}…"
    printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "secrets.yaml:" "${COLOR_RESET}" \
        "re-encrypted ✔"
    printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "Docker secrets:" "${COLOR_RESET}" \
        "re-synced ✔"
    if (( ${#services_restarted[@]} > 0 )); then
        printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "Services restarted:" \
            "${COLOR_RESET}" "${services_restarted[*]}"
    else
        printf '  %s%-22s%s %s\n' "${COLOR_BOLD}" "Services restarted:" \
            "${COLOR_RESET}" "(none — restart manually if needed)"
        log_hint "To apply: sudo ./startup.sh --force"
    fi
    printf '\n'
    log_warn "Save the new credential from the vault admin panel — it is not shown here."
}
```


***

## 44. No `CHANGELOG.md` or Release Notes — Ops Upgrades Are Blind

**Why:** The repo has a `VERSION` file but no `CHANGELOG.md`. When an operator runs `sudo ./maintenance.sh update` to pull a new image or `git pull` to get script updates, they have no way to know what changed between versions — whether a breaking `.env` variable was renamed, a new required secret was added, or a phase order changed. This is especially dangerous around `secrets.yaml` schema changes.

**Fix — Create a minimal `CHANGELOG.md` template and wire it into the dashboard:**

```markdown
<!-- CHANGELOG.md — add to repo root -->
# Changelog

All notable changes to VaultWarden-OCI are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
### Added
- Phase progress bar in setup.sh
- Spinner for silent background operations

### Changed
- dashboard.sh TZ now reads DASHBOARD_TZ from .env

### Breaking
- (none)

---

## [1.0.0-beta] — 2026-06-XX
### Added
- Initial Beta release
```

**Wire into the dashboard update flow:**

```bash
# dashboard.sh — in the "Update Stack" action, after git pull / image pull:
_show_changelog_on_update() {
    local changelog="${REPO_ROOT}/CHANGELOG.md"
    [[ -f "$changelog" ]] || return 0
    echo ""
    echo -e "${BLD} What changed in this update:${NC}"
    # Show just the most recent changelog section (up to first ---  divider)
    awk '/^## \[/{found++} found==1{print} found==2{exit}' "$changelog" \
        | head -20 | sed 's/^/  /'
    echo ""
}
```


---

***

## 45. `uninstall-vaultwarden.sh` Has Its Own Inline Log Functions Instead of Using `lib/log.sh`

**Why:** The script intentionally duplicates `log_info`, `log_warn`, `log_error` inline with the comment *"Keep logging self-contained so uninstall remains safe after a partial or broken installation."* The intent is good, but the inline versions differ slightly — `log_success` prints `OK` instead of `SUCCESS`, `log_error` is bold-red while the rest of the codebase uses regular red, and there is no `log_hint`. This means uninstall output looks visually different from every other script in the suite, which is jarring during an already stressful operation.

**Fix — Keep the self-contained design but normalize the format strings to exactly match `lib/log.sh`:**

```bash
# utilities/uninstall-vaultwarden.sh — replace the inline log functions:
log_info()    { printf '%s[%s] [%s] INFO   %s %s\n' "$_C_CYAN"   "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*"; }
log_success() { printf '%s[%s] [%s] SUCCESS%s %s\n' "$_C_GREEN"  "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*"; }
log_warn()    { printf '%s[%s] [%s] WARN   %s %s\n' "$_C_YELLOW" "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*" >&2; }
log_error()   { printf '%s[%s] [%s] ERROR  %s %s\n' "$_C_RED"    "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*" >&2; }
log_hint()    { printf '%s[%s] [%s] HINT  →%s %s\n' "$_C_CYAN"   "$(_vw_ts)" "$_VW_SCRIPT_NAME" "$_C_RESET" "$*"; }
# Remove bold from _C_RED — lib/log.sh uses regular red for errors:
_C_RED=$'\e[31m'  # was \e[1;31m
```


***

## 46. `restore-run.sh` Dependency Preflight Fails With No Install Command Hint

**Why:** `check_dependencies()` in `restore-run.sh` lists hard dependencies `(docker age age-keygen sqlite3 sha256sum)` and fails with `log_error "Missing required command: $cmd"` for each one missing. It does not tell the operator how to install the missing tool — especially `age` and `age-keygen`, which are non-obvious on OCI Ubuntu instances.

**Fix — Map each hard dependency to its install hint:**

```bash
# utilities/restore-run.sh — replace check_dependencies():
check_dependencies() {
    declare -A _install_hints=(
        [docker]="apt install docker.io  OR  snap install docker"
        [age]="apt install age  OR  snap install age"
        [age-keygen]="installed with 'age' — apt install age"
        [sqlite3]="apt install sqlite3"
        [sha256sum]="apt install coreutils  (should be pre-installed)"
        [rclone]="curl https://rclone.org/install.sh | sudo bash"
    )
    local hard=(docker age age-keygen sqlite3 sha256sum)
    local soft=(rclone)
    local missing_hard=()

    for cmd in "${hard[@]}"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            missing_hard+=("$cmd")
            local hint="${_install_hints[$cmd]:-install $cmd}"
            log_error "Missing required command: ${cmd}"
            log_hint  "  Install with: ${hint}"
        fi
    done

    for cmd in "${soft[@]}"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            local hint="${_install_hints[$cmd]:-install $cmd}"
            log_warn "Optional command not found: ${cmd} (needed for --remote)"
            log_hint "  Install with: ${hint}"
        fi
    done

    if (( ${#missing_hard[@]} > 0 )); then
        log_error "Restore cannot proceed — install the above tools and retry."
        return 1
    fi
    return 0
}
```


***

## 47. `dashboard.sh` `draw_live_stats` Has No Uptime Display for the VaultWarden Container

**Why:** The stats header shows container status (Running/Stopped) but not how long it has been running. Uptime is the single most useful health signal for a vault service — an operator glancing at the dashboard should immediately see `vaultwarden: Running (3d 14h)` vs. `vaultwarden: Running (0m 12s)` (which would indicate a recent crash-restart).

**Fix — Add container uptime to the stats header:**

```bash
# dashboard.sh — add to draw_live_stats():
_container_uptime() {
    local container="$1"
    # docker inspect returns StartedAt in RFC3339; compute delta in seconds
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null) || {
        printf 'unknown'; return
    }
    local start_epoch now_epoch delta
    start_epoch=$(date -d "$started_at" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" +%s 2>/dev/null \
        || echo 0)
    now_epoch=$(date +%s)
    delta=$(( now_epoch - start_epoch ))

    local days=$(( delta / 86400 ))
    local hours=$(( (delta % 86400) / 3600 ))
    local mins=$(( (delta % 3600) / 60 ))

    if   (( days  > 0 )); then printf '%dd %dh'  "$days"  "$hours"
    elif (( hours > 0 )); then printf '%dh %dm'  "$hours" "$mins"
    else                       printf '%dm'       "$mins"
    fi
}

# In draw_live_stats(), replace the plain status line:
local vw_status vw_uptime
vw_status=$(_container_status "vaultwarden")
if [[ "$vw_status" == "Running" ]]; then
    vw_uptime=$(_container_uptime "vaultwarden")
    echo -e " VaultWarden: ${GRN}${vw_status}${NC} (up ${vw_uptime})"
else
    echo -e " VaultWarden: ${RED}${vw_status}${NC}"
fi
```


***

## 48. `lib/config.sh` `load_env_file` Silently Skips Malformed Lines With No Warning

**Why:** If `.env` has a line like `DOMAIN =vault.example.com` (space before `=`) or `export DOMAIN=vault.example.com` (shell export prefix), `load_env_file` silently skips it. The variable never gets set, and downstream scripts fail in confusing, non-obvious ways — e.g., `setup-env.sh` exits because `DOMAIN` is empty, with no clue why.

**Fix — Emit a warning for lines that look like they should be variables but don't match the accepted pattern:**

```bash
# lib/config.sh — in load_env_file(), add a malformed-line detector:
load_env_file() {
    local env_file="${1:-${PROJECT_ROOT}/.env}"
    [[ -f "$env_file" ]] || return 1

    local line lineno=0 malformed=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( lineno++ ))
        # Skip blanks and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Valid: KEY=value or KEY="value"
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # shellcheck disable=SC1090
            local key="${line%%=*}" value="${line#*=}"
            export "$key"="$value"
            continue
        fi
        # Looks like a variable assignment but is malformed
        if [[ "$line" =~ = ]]; then
            malformed+=("  Line ${lineno}: ${line}")
        fi
    done < "$env_file"

    if (( ${#malformed[@]} > 0 )); then
        log_warn ".env has ${#malformed[@]} malformed line(s) that were skipped:"
        for m in "${malformed[@]}"; do
            log_warn "$m"
        done
        log_hint "Valid format: KEY=value  or  KEY=\"value with spaces\""
        log_hint "Common mistakes: spaces around '=', 'export' prefix, missing quotes"
    fi
}
```


***

## 49. `pre-production-drill.sh` Has No Elapsed Time in the Final Summary

**Why:** The drill can take 30 seconds to 3+ minutes depending on whether it decrypts backups and verifies restore paths. The final summary shows pass/fail counts but no total duration. Operators running this as part of a go-live checklist want to know how long the validation took to set expectations for future runs and CI pipelines.

**Fix — Add elapsed time tracking:**

```bash
# utilities/pre-production-drill.sh — add at the very top of main():
_DRILL_START=$(date +%s)

# Replace or update _print_drill_summary() to include duration:
_print_drill_summary() {
    local end_epoch
    end_epoch=$(date +%s)
    local elapsed=$(( end_epoch - _DRILL_START ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local duration_str
    (( mins > 0 )) && duration_str="${mins}m ${secs}s" || duration_str="${secs}s"

    printf '\n'
    log_header "Pre-Production Drill Summary"
    printf '  %s%-12s%s %d / %d   (%s elapsed)\n' \
        "${COLOR_GREEN}" "Passed:" "${COLOR_RESET}" \
        "$_STEPS_PASSED" "$_STEPS_TOTAL" "$duration_str"
    # ... rest of summary (failed steps, etc.) ...
}
```


***

## 50. No `--json` Output Mode for Machine-Readable Status in `backup.sh list` and `health-check`

**Why:** This is a production deployment — it's reasonable to expect monitoring tools (OCI Monitoring, Grafana, a simple cron script) to parse backup status or health state. Right now all output is human-formatted log lines. There's no way to get structured output without screen-scraping.

**Fix — Add `--json` flag to `backup.sh list` and any health-check entry point:**

```bash
# utilities/backup-run.sh — add to list subcommand arg parsing:
JSON_OUTPUT=false
# ... in the 'list' case block:
--json) JSON_OUTPUT=true; shift ;;

# And in _print_backup_table(), add a JSON branch:
if [[ "$JSON_OUTPUT" == "true" ]]; then
    printf '{"backups":['
    local first=true
    for type in db full emergency; do
        local type_dir="${base_dir}/${type}"
        [[ -d "$type_dir" ]] || continue
        while IFS= read -r -d '' f; do
            local fname size_bytes age_days
            fname=$(basename "$f")
            size_bytes=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
            age_days=$(_backup_filename_age_days "$f" 2>/dev/null || echo -1)
            [[ "$first" == "true" ]] && first=false || printf ','
            printf '{"type":"%s","file":"%s","size_bytes":%s,"age_days":%s}' \
                "$type" "$fname" "$size_bytes" "$age_days"
        done < <(find "$type_dir" -name "*.age" -type f -print0 2>/dev/null | sort -z)
    done
    printf ']}\n'
    return 0
fi
# ... else fall through to human table ...
```


***


---
