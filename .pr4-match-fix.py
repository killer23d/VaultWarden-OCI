from pathlib import Path
import re

TOKEN_HELPER = r'''_ufw_has_range_port() {
    local status="$1" cidr="$2" port="$3" line token i
    local -a fields=()

    while IFS= read -r line; do
        fields=()
        read -ra fields <<< "$line"
        (( ${#fields[@]} >= 4 )) || continue
        [[ "${fields[0]}" == "${port}/tcp" ]] || continue

        i=1
        if [[ "${fields[$i]:-}" == "(v6)" ]]; then
            i=$((i + 1))
        fi
        if [[ "${fields[$i]:-}" == "on" ]]; then
            i=$((i + 2))
        fi
        [[ "${fields[$i]:-}" == "ALLOW" ]] || continue
        i=$((i + 1))
        if [[ "${fields[$i]:-}" == "IN" ]]; then
            i=$((i + 1))
        fi

        for (( ; i<${#fields[@]}; i++ )); do
            token="${fields[$i]}"
            token="${token%#*}"
            [[ "$token" == "$cidr" ]] && return 0
        done
    done <<< "$status"
    return 1
}
'''

for name in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    p = Path(name)
    text = p.read_text()
    pattern = re.compile(r'(?ms)^    _ufw_has_range_port\(\) \{.*?^    \}\n' if name.endswith('maintenance-update-firewall.sh') else r'(?ms)^_ufw_has_range_port\(\) \{.*?^\}\n')
    replacement = ''.join('    ' + line if line else line for line in TOKEN_HELPER.splitlines(True)) if name.endswith('maintenance-update-firewall.sh') else TOKEN_HELPER
    updated, count = pattern.subn(replacement.rstrip() + '\n', text, count=1)
    if count != 1:
        raise SystemExit(f'could not replace _ufw_has_range_port in {name}: {count}')
    p.write_text(updated)
