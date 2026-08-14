from pathlib import Path

for path in ('utilities/backup-run.sh', 'utilities/restore-run.sh'):
    p = Path(path)
    text = p.read_text()
    text = text.replace("stat -f -c '%T' /dev/shm", "stat --file-system --format='%T' /dev/shm")
    p.write_text(text)
