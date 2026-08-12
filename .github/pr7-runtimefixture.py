from pathlib import Path

p = Path('tests/suites/security/case-secrets.bash')
lines = p.read_text().splitlines(True)
section = next(i for i, line in enumerate(lines) if line.startswith('check_recovery_kit_schema_truth()'))
case_start = next(i for i in range(section, len(lines)) if lines[i].lstrip().startswith('runtime_required_case() ('))
case_end = next(i for i in range(case_start + 1, len(lines)) if lines[i].startswith('  )'))
insert_at = next(i for i in range(case_start, case_end) if lines[i].strip() == 'log_success() { :; }') + 1
fixture_mock = '''    create_sensitive_workspace() {
      local dir="$work/volatile-${1:-sensitive}"
      rm -rf -- "$dir"
      mkdir -p "$dir"
      chmod 0700 "$dir"
      printf '%s\\n' "$dir"
    }
    remove_sensitive_workspace() { rm -rf -- "$1"; }
'''
lines[insert_at:insert_at] = [fixture_mock]
p.write_text(''.join(lines))
