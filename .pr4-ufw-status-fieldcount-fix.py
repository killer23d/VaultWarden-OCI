from pathlib import Path

for path in ('utilities/setup-firewall.sh', 'utilities/maintenance-update-firewall.sh'):
    p = Path(path)
    text = p.read_text()
    marker = '_ufw_has_range_port() {'
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f'{path}: _ufw_has_range_port missing')
    end = text.find('\n}\n', start)
    if end < 0:
        raise SystemExit(f'{path}: _ufw_has_range_port end missing')
    block = text[start:end + 3]
    old = '(( ${#fields[@]} >= 4 )) || continue'
    if block.count(old) != 1:
        raise SystemExit(f'{path}: expected one field-count check in _ufw_has_range_port')
    block = block.replace(old, '(( ${#fields[@]} >= 3 )) || continue', 1)
    p.write_text(text[:start] + block + text[end + 3:])
