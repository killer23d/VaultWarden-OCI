from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'lib/operations.sh',
    '''    current_mode="$(stat -c '%a' "$lock_path" 2>/dev/null \\\n || true)"\n''',
    '''    current_mode="$(stat -c '%a' "$lock_path" 2>/dev/null || true)"\n''',
    'operation lock mode',
)
replace_once(
    'lib/operations.sh',
    '''    current_owner="$(stat -c '%U:%G' "$lock_path" 2>/dev/null \\\n || true)"\n''',
    '''    current_owner="$(stat -c '%U:%G' "$lock_path" 2>/dev/null || true)"\n''',
    'operation lock owner',
)
replace_once(
    'lib/operations.sh',
    '''    mode="$(stat -c '%a' "$file" 2>/dev/null \\\n || true)"\n    owner_uid="$(stat -c '%u' "$file" 2>/dev/null \\\n || true)"\n''',
    '''    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"\n    owner_uid="$(stat -c '%u' "$file" 2>/dev/null || true)"\n''',
    'operation state trust stats',
)
replace_once(
    'lib/operations.sh',
    '''    stat -Lc '%d:%i' "$path" 2>/dev/null \\\n\n''',
    '''    stat -Lc '%d:%i' "$path" 2>/dev/null\n''',
    'operation path identity',
)
replace_once(
    'lib/operations.sh',
    '''    mode="$(stat -c '%a' "$path" 2>/dev/null \\\n || true)"\n    owner_uid="$(stat -c '%u' "$path" 2>/dev/null \\\n || true)"\n''',
    '''    mode="$(stat -c '%a' "$path" 2>/dev/null || true)"\n    owner_uid="$(stat -c '%u' "$path" 2>/dev/null || true)"\n''',
    'operation lock validation stats',
)
replace_once(
    'lib/operations.sh',
    '''    if [[ -e "/proc/${pid}/fd/${fd}" ]]; then\n        [[ "$path_identity" == "$fd_identity" ]]\n    else\n        [[ "${path_identity#*:}" == "${fd_identity#*:}" ]]\n    fi\n''',
    '''    [[ "$path_identity" == "$fd_identity" ]]\n''',
    'operation proc identity comparison',
)

replace_once(
    'utilities/maintenance-health.sh',
    '''    owner_uid="$(stat -c '%u' "$lock_path" 2>/dev/null \\\n || true)"\n''',
    '''    owner_uid="$(stat -c '%u' "$lock_path" 2>/dev/null || true)"\n''',
    'health lock owner',
)
replace_once(
    'utilities/maintenance-health.sh',
    '''    open_owner_uid="$(stat -Lc '%u' "/proc/${BASHPID}/fd/${fd}" 2>/dev/null \\\n || true)"\n''',
    '''    open_owner_uid="$(stat -Lc '%u' "/proc/${BASHPID}/fd/${fd}" 2>/dev/null || true)"\n''',
    'health opened lock owner',
)

replace_once(
    'utilities/restore-run.sh',
    '''    stat -c '%d:%i:%u:%a' "$1" 2>/dev/null \\\n\n''',
    '''    stat -c '%d:%i:%u:%a' "$1" 2>/dev/null\n''',
    'restore workspace identity',
)

replace_once(
    'lib/health-alerts.sh',
    '''    identity="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null \\\n        || stat -Lf '%d:%i' "$path" 2>/dev/null)" || return 1\n''',
    '''    identity="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null)" || return 1\n''',
    'health state file identity',
)
replace_once(
    'lib/health-alerts.sh',
    '''    if [[ -e "/proc/${shell_pid}/fd/${fd}" ]]; then\n        path_identity="$(_state_file_identity "$path")" || return 1\n        fd_identity="$(_state_file_identity "/proc/${shell_pid}/fd/${fd}")" || return 1\n    elif [[ -e "/dev/fd/${fd}" ]]; then\n        # Development fallback for BSD hosts. The supported Ubuntu runtime\n        # uses the device-and-inode comparison above through /proc.\n        path_identity="$(stat -c '%i' -- "$path" 2>/dev/null)" || return 1\n        fd_identity="$(stat -Lf '%i' "/dev/fd/${fd}" 2>/dev/null)" || return 1\n    else\n        return 1\n    fi\n''',
    '''    [[ -e "/proc/${shell_pid}/fd/${fd}" ]] || return 1\n    path_identity="$(_state_file_identity "$path")" || return 1\n    fd_identity="$(_state_file_identity "/proc/${shell_pid}/fd/${fd}")" || return 1\n''',
    'health state proc identity',
)
