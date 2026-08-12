from pathlib import Path
import re

p = Path('utilities/setup-secrets.sh')
t = p.read_text()

old_help = '''    BREAKGLASS_AUTO_EXPIRY_HOURS Hours after creation before the account is auto-removed
                                 (default: 2). Scheduler priority:
                                   1. `at` + atd running
                                   2. `at` present (tries on-demand activation)
                                   3. systemd-run transient timer (survives reboots)
                                   4. background sleep subshell (lost on reboot)
'''
new_help = '''    BREAKGLASS_AUTO_EXPIRY_HOURS Hours after creation before the account is auto-removed
                                 (default: 2; must be a positive integer).
                                 Expiry requires a systemd transient timer that
                                 is verified active before creation succeeds.
'''
if old_help not in t:
    raise SystemExit('breakglass help scheduler block not found')
t = t.replace(old_help, new_help, 1)

schedule = r'''    schedule_auto_cleanup() {
        local expiry_hours="$BREAKGLASS_AUTO_EXPIRY_HOURS"
        local bg_user="$BREAKGLASS_USER"

        if ! [[ "$expiry_hours" =~ ^[1-9][0-9]*$ ]]; then
            log_error "BREAKGLASS_AUTO_EXPIRY_HOURS must be a positive integer; account creation is aborted."
            return 1
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would schedule verified systemd auto-cleanup in ${expiry_hours}h"
            return 0
        fi

        local script_abs
        script_abs=$(readlink -f "$0") || {
            log_error "Could not resolve the break-glass cleanup command path; account creation is aborted."
            return 1
        }
        local expiry_epoch=$(( $(date +%s) + expiry_hours * 3600 ))
        local expiry_human
        expiry_human=$(date -d "@${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || date -r "${expiry_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
            || date -u -d "${expiry_hours} hours" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
            || echo "in ${expiry_hours} hour(s)")

        local unit_name="vw-breakglass-cleanup"
        if ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
            log_error "Break-glass expiry requires systemd-run and systemctl; account creation is aborted."
            return 1
        fi
        if ! systemd-run --quiet --collect \
                --on-active="${expiry_hours}h" \
                --unit="$unit_name" \
                --description="VaultWarden breakglass auto-cleanup for ${bg_user}" \
                -- /usr/bin/env bash "$script_abs" breakglass remove --user "$bg_user" --force 2>/dev/null; then
            log_error "Could not schedule break-glass expiry with systemd; account creation is aborted."
            return 1
        fi
        if ! systemctl is-active --quiet "${unit_name}.timer"; then
            systemctl stop "${unit_name}.timer" "${unit_name}.service" >/dev/null 2>&1 || true
            log_error "Break-glass expiry timer could not be verified active; account creation is aborted."
            return 1
        fi
        log_success "Auto-cleanup scheduled and verified via systemd at ${expiry_human}"
        return 0
    }
'''
pattern = re.compile(r'^    schedule_auto_cleanup\(\) \{\n.*?\n\}\n(?=\n    create_breakglass_user\(\) \{)', re.M | re.S)
t, n = pattern.subn(schedule.rstrip('\n'), t, count=1)
if n != 1:
    raise SystemExit('breakglass schedule_auto_cleanup function not found')

old_remove = '''    remove_breakglass_user() {
        if [[ "$DRY_RUN" == "true" ]]; then
'''
new_remove = '''    remove_breakglass_user() {
        local force_remove=false
        [[ "${1:-}" == "--force" ]] && force_remove=true

        if [[ "$DRY_RUN" == "true" ]]; then
'''
if old_remove not in t:
    raise SystemExit('remove_breakglass_user start not found')
t = t.replace(old_remove, new_remove, 1)
old_prompt = '''        if [[ "$FORCE" != "true" ]]; then
            echo ""
            log_warn "This will permanently remove the break-glass admin account."
'''
new_prompt = '''        if [[ "$FORCE" != "true" && "$force_remove" != "true" ]]; then
            echo ""
            log_warn "This will permanently remove the break-glass admin account."
'''
if old_prompt not in t:
    raise SystemExit('remove_breakglass_user prompt gate not found')
t = t.replace(old_prompt, new_prompt, 1)

old_expiry_display = '''        if (( BREAKGLASS_AUTO_EXPIRY_HOURS > 0 )); then
            printf '%b\\
' "Expiry:    ${COLOR_YELLOW}${expiry_human} (auto-cleanup in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h)${COLOR_RESET}"
        else
            printf '%b\\
' "Expiry:    ${COLOR_CYAN}None — auto-expiry disabled. Remove manually with: sudo $0 breakglass remove${COLOR_RESET}"
        fi
'''
new_expiry_display = '''        printf '%b\\
' "Expiry:    ${COLOR_YELLOW}${expiry_human} (verified auto-cleanup in ${BREAKGLASS_AUTO_EXPIRY_HOURS}h)${COLOR_RESET}"
'''
if old_expiry_display not in t:
    raise SystemExit('breakglass expiry display block not found')
t = t.replace(old_expiry_display, new_expiry_display, 1)
p.write_text(t)

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = '''! grep -Fq 'may be scheduled via' utilities/setup-secrets.sh || fail "break-glass status still advertises a removed scheduler fallback"
'''
checks = '''! grep -Fq 'Scheduler priority:' utilities/setup-secrets.sh || fail "break-glass help still documents the removed scheduler ladder"
! grep -Fq 'Auto-expiry disabled' utilities/setup-secrets.sh || fail "break-glass still allows expiry to be disabled"
grep -Fq '[[ "$expiry_hours" =~ ^[1-9][0-9]*$ ]]' utilities/setup-secrets.sh || fail "break-glass expiry does not require a positive integer"
grep -Fq 'local force_remove=false' utilities/setup-secrets.sh || fail "break-glass rollback lacks an internal force-removal path"
grep -Fq '[[ "$FORCE" != "true" && "$force_remove" != "true" ]]' utilities/setup-secrets.sh || fail "break-glass internal rollback can still prompt"
grep -Fq -- '-- /usr/bin/env bash "$script_abs" breakglass remove --user "$bg_user" --force' utilities/setup-secrets.sh || fail "break-glass systemd cleanup is not passed as direct argv"
! grep -Fq 'systemctl is-system-running' utilities/setup-secrets.sh || fail "break-glass expiry rejects usable degraded systemd hosts before scheduling"
'''
if anchor not in t:
    raise SystemExit('breakglass test anchor not found')
t = t.replace(anchor, anchor + checks, 1)
p.write_text(t)
