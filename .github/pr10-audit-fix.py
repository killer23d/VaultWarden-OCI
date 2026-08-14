from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    'lib/backup-utils.sh',
    '''# Uses a portable awk approach because POSIX df guarantees available blocks\n# in column 4 on both GNU and BSD implementations.\n''',
    '''# Use POSIX df output and sum the available-blocks column.\n''',
    'backup disk-space comment',
)
replace_once(
    'lib/backup-utils.sh',
    '''    local ts_epoch\n    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || \\\n    ts_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts_str" +%s 2>/dev/null) || true\n''',
    '''    local ts_epoch\n    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || true\n''',
    'backup timestamp parsing',
)
replace_once(
    'lib/backup-utils.sh',
    '''# find -exec stat -c%s {} + is GNU-only. On macOS stat -c%s\n# errors and awk sums to 0, reporting all backup sizes as 0 MB.\n#\n# Replaced with a find | while loop using _stat_file_size() (exported by\n# lib/crypto.sh) which selects the correct stat format per platform.\n#\n''',
    '''# Sum backup sizes through the shared GNU-stat helper when available.\n#\n''',
    'backup statistics comment',
)

replace_once(
    'utilities/smoke-test.sh',
    '''    expiry_epoch=$(date -d "$expiry_date_str" +%s 2>/dev/null \\\n        || date -j -f '%b %d %T %Y %Z' "$expiry_date_str" +%s 2>/dev/null || echo 0)\n''',
    '''    expiry_epoch=$(date -d "$expiry_date_str" +%s 2>/dev/null || echo 0)\n''',
    'smoke certificate expiry',
)

replace_once(
    'utilities/maintenance-health.sh',
    '''    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -jf "%b %e %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)\n''',
    '''    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)\n''',
    'health certificate expiry',
)
