from pathlib import Path

p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()

# The setup-secrets transaction fixture already provides an explicit temporary
# workspace path. Mark that fixture as test mode so the production root-only
# workspace helper cannot be bypassed outside tests.
old = '''    export VW_SETUP_SECRETS_TMP_DIR="$TMP/run-tmp"\n    mkdir -p "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets"\n'''
new = '''    export VW_SETUP_SECRETS_TMP_DIR="$TMP/run-tmp"\n    export VW_TEST_MODE=true\n    mkdir -p "$PROJECT_STATE_DIR/config" "$PROJECT_STATE_DIR/secrets"\n'''
if old not in t:
    raise SystemExit('setup-secrets transaction test hook anchor missing')
t = t.replace(old, new, 1)

# The runtime-required recovery fixture publishes a recovery kit as an ordinary
# test user. Mock only its volatile workspace allocation; production root and
# backing verification remain covered by the focused helper regressions.
lines = t.splitlines(True)
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
