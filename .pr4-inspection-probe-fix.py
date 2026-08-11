from pathlib import Path
p = Path('tests/suites/operations/case-firewall-update.bash')
t = p.read_text()
old = '''_run(){ "$@"; }
log_info(){ :; }
log_success(){ :; }
log_error(){ printf 'ERROR: %s\\n' "$*" >&2; }
EOF_DOCKER_DROPIN
'''
new = '''_run(){ "$@"; }
log_info(){ :; }
log_success(){ :; }
log_error(){ printf 'ERROR: %s\\n' "$*" >&2; }
# The real installer is root-only. This isolated probe runs unprivileged, so
# model the root ownership that setup-systemd.sh establishes in production.
chown(){ :; }
stat(){
    if [[ "${1:-}" == "-c" && "${3:-}" == "$DOCKER_RUNTIME_DROPIN" ]]; then
        case "${2:-}" in
            %U) printf 'root\\n' ;;
            %G) printf 'root\\n' ;;
            %a) printf '644\\n' ;;
            *) command stat "$@" ;;
        esac
    else
        command stat "$@"
    fi
}
EOF_DOCKER_DROPIN
'''
if old not in t:
    raise SystemExit('Docker drop-in probe prelude anchor missing')
p.write_text(t.replace(old, new, 1))
