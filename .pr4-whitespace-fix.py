from pathlib import Path
for name in ('utilities/maintenance-update-firewall.sh',):
    p = Path(name)
    lines = p.read_text().splitlines()
    p.write_text('\n'.join(line.rstrip() for line in lines) + '\n')
