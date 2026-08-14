from pathlib import Path
import re


def edit(path, fn):
    p = Path(path)
    old = p.read_text()
    new = fn(old)
    if new != old:
        p.write_text(new)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    return text.replace(old, new, 1)


def fix_runner(text):
    old = "grep -Fq 'SOPS_VERSION_CLI_SET=true' utilities/setup-system.sh \\\n    || fail 'setup-system must track explicit --sops-version ownership'\n"
    text = replace_once(text, old, "", "runner obsolete CLI ownership assertion")
    old = "awk '/install_sops\\(\\)/,/^}/' utilities/setup-system.sh | grep -Fq 'if [[ \"$USE_LATEST\" == \"true\" ]]' \\\n    || fail 'SOPS latest resolution must be owned by explicit --use-latest'\n"
    text = replace_once(text, old, "", "runner obsolete latest assertion")
    return text


edit('tests/suites/foundation/case-runner-contracts.bash', fix_runner)


def fix_operator_ui(text):
    old = 'TMP_PROMPT_PROSE="$(mktemp "$ROOT/reports/operator-ui-prose.XXXXXX.md")"'
    new = 'TMP_PROMPT_PROSE="$(mktemp "${TMPDIR:-/tmp}/operator-ui-prose.XXXXXX.md")"'
    return replace_once(text, old, new, "operator UI prose fixture")


edit('tests/suites/operations/case-operator-ui.bash', fix_operator_ui)

production = [
    'lib/config.sh', 'lib/backup-utils.sh', 'lib/health-alerts.sh', 'lib/operations.sh',
    'lib/schema.sh', 'lib/migrate.sh', 'utilities/smoke-test.sh', 'utilities/setup-systemd.sh',
    'utilities/backup-run.sh', 'utilities/maintenance-health.sh', 'utilities/restore-run.sh',
]

bsd_segment = re.compile(r"\s+\|\|\s+stat -f(?:\s+)?(?:'[^']*'|\"[^\"]*\"|%[^\s]+)\s+(?:\"[^\"]*\"|[^\s|;)]+)\s+2>/dev/null")
for path in production:
    def simplify(text):
        lines = []
        for line in text.splitlines(True):
            line2 = bsd_segment.sub('', line)
            if re.fullmatch(r'\s*\\\s*\n?', line2):
                continue
            lines.append(line2)
        return ''.join(lines)
    edit(path, simplify)


def fix_config(text):
    old = "    if metadata=\"$(stat -c '%a:%u:%g' -- \"$file\" 2>/dev/null)\"; then\n        :\n    elif metadata=\"$(stat -f '%Lp:%u:%g' \"$file\" 2>/dev/null)\"; then\n        :\n    else\n        return 1\n    fi\n"
    new = "    if ! metadata=\"$(stat -c '%a:%u:%g' -- \"$file\" 2>/dev/null)\"; then\n        return 1\n    fi\n"
    return replace_once(text, old, new, "config GNU metadata")


edit('lib/config.sh', fix_config)


def fix_health(text):
    return text.replace("path_identity=\"$(stat -f '%i' \"$path\" 2>/dev/null)\"", "path_identity=\"$(stat -c '%i' -- \"$path\" 2>/dev/null)\"")


edit('lib/health-alerts.sh', fix_health)


def fix_crypto(text):
    return text.replace('log_error "  Oracle/RHEL/CentOS: sudo dnf install httpd-tools"', 'log_error "  Ubuntu 24.04: sudo apt-get install apache2-utils"')


edit('lib/crypto.sh', fix_crypto)


def fix_systemd(text):
    old = "_sha256() {\n    if command -v sha256sum &>/dev/null; then\n        sha256sum \"$1\" | awk '{print $1}'\n    else\n        shasum -a 256 \"$1\" | awk '{print $1}'\n    fi\n}\n"
    new = "_sha256() {\n    sha256sum -- \"$1\" | awk '{print $1}'\n}\n"
    return replace_once(text, old, new, "systemd sha256")


edit('utilities/setup-systemd.sh', fix_systemd)


def fix_backup_run(text):
    text = text.replace('if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then', 'if ! command -v sha256sum >/dev/null 2>&1; then')
    text = text.replace('log_error "Neither sha256sum nor shasum is available for checksum generation."', 'log_error "Required GNU sha256sum command is unavailable."')
    return text


edit('utilities/backup-run.sh', fix_backup_run)
