from pathlib import Path


def replace_function(path, name, body):
    p = Path(path)
    lines = p.read_text().splitlines(True)
    start = next((i for i, line in enumerate(lines) if line.startswith(name + '() {')), None)
    if start is None:
        raise SystemExit(f'{path}: {name} not found')
    end = next((i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}'), None)
    if end is None:
        raise SystemExit(f'{path}: {name} end not found')
    lines[start:end + 1] = [body.rstrip() + '\n']
    p.write_text(''.join(lines))


replace_function('utilities/secrets-edit.sh', '_check_editor_forks', r'''_check_editor_forks() {
    local editor_bin arg
    local has_wait=false has_foreground=false has_block=false has_disable_server=false

    editor_bin="$(basename "${EDITOR_CMD[0]}")"
    for arg in "${EDITOR_CMD[@]:1}"; do
        case "$arg" in
            --wait|-w) has_wait=true ;;
            --nofork|-f) has_foreground=true ;;
            --block|-b) has_block=true ;;
            --disable-server) has_disable_server=true ;;
        esac
    done

    case "$editor_bin" in
        code)
            [[ "$has_wait" == "true" ]] && return 0
            log_error "EDITOR 'code' must wait for save. Use: EDITOR='code --wait' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        gvim|mvim)
            [[ "$has_foreground" == "true" ]] && return 0
            log_error "EDITOR '$editor_bin' must stay in the foreground. Use: EDITOR='$editor_bin --nofork' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        atom)
            [[ "$has_wait" == "true" ]] && return 0
            log_error "EDITOR 'atom' must wait for save. Use: EDITOR='atom --wait' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        subl|sublime_text)
            [[ "$has_wait" == "true" ]] && return 0
            log_error "EDITOR '$editor_bin' must wait for save. Use: EDITOR='$editor_bin --wait' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        gedit)
            [[ "$has_wait" == "true" ]] && return 0
            log_error "EDITOR 'gedit' must wait for save. Use: EDITOR='gedit --wait' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        kate)
            [[ "$has_block" == "true" ]] && return 0
            log_error "EDITOR 'kate' must block until the file is closed. Use: EDITOR='kate --block' sudo ./edit-secrets.sh edit"
            return 1
            ;;
        mousepad)
            [[ "$has_disable_server" == "true" ]] && return 0
            log_error "EDITOR 'mousepad' must run without its background server. Use: EDITOR='mousepad --disable-server' sudo ./edit-secrets.sh edit"
            return 1
            ;;
    esac
    return 0
}''')

# Extend the focused regression contract with editor-specific blocking semantics.
p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = "grep -Fq '_check_editor_forks || return 1' utilities/secrets-edit.sh || fail \"known forking editor refusal is not enforced\"\n"
if anchor not in t:
    raise SystemExit('editor regression anchor not found')
checks = r'''grep -Fq "EDITOR='code --wait'" utilities/secrets-edit.sh || fail "VS Code wait remediation missing"
grep -Fq "EDITOR='kate --block'" utilities/secrets-edit.sh || fail "Kate block remediation missing"
grep -Fq "EDITOR='mousepad --disable-server'" utilities/secrets-edit.sh || fail "Mousepad foreground remediation missing"
! grep -Fq 'case "$_editor_str"' utilities/secrets-edit.sh || fail "generic editor flag acceptance remains"
'''
t = t.replace(anchor, anchor + checks, 1)
p.write_text(t)
