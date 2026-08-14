from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "setup.sh",
    "# operator explicitly wants mutable upstream versions for this run.\n",
    "# operator explicitly wants mutable upstream versions. Environment generation\n"
    "# persists supported mutable image/CrowdSec tags in .env until they are re-pinned.\n",
)
replace_once(
    "setup.sh",
    "  --use-latest        Explicit override: use current live upstream component versions\n"
    "                      for this run instead of the repository-pinned normal defaults.\n"
    "                      Caddy remains pinned because xcaddy builds require a version tag.\n",
    "  --use-latest        Explicit override: opt into mutable upstream component versions.\n"
    "                      Environment generation writes supported image/CrowdSec version\n"
    "                      fields as 'latest' in .env; later pulls remain mutable until\n"
    "                      those fields are re-pinned. SOPS resolves latest for setup.\n"
    "                      Caddy remains pinned because xcaddy builds require a version tag.\n",
)
replace_once(
    "setup.sh",
    '        log_info "SOPS version: will resolve latest from GitHub because --use-latest was requested"\n',
    '        log_info "SOPS version: will resolve latest from GitHub because --use-latest was requested"\n'
    '        log_warn "--use-latest also persists mutable supported image/CrowdSec version tags in .env until they are re-pinned."\n',
)

replace_once(
    "utilities/setup-env.sh",
    "    --use-latest          Explicit override: set supported component versions to latest;\n"
    "                          Caddy remains pinned because xcaddy builder tags require\n"
    "                          an explicit version.\n",
    "    --use-latest          Explicit override: write supported image/CrowdSec version fields\n"
    "                          as 'latest' in .env. This persists across later pulls until\n"
    "                          those fields are re-pinned. Caddy remains pinned because\n"
    "                          xcaddy builder tags require an explicit version.\n",
)
replace_once(
    "utilities/setup-env.sh",
    '    if [[ "$USE_LATEST" == "true" ]]; then\n        local temp2\n',
    '    if [[ "$USE_LATEST" == "true" ]]; then\n'
    '        log_warn "--use-latest is writing persistent mutable version tags to .env; re-pin those fields to return to reproducible updates."\n'
    '        local temp2\n',
)

replace_once(
    "docs/SCRIPTS.md",
    "`setup-system.sh` fails closed outside Ubuntu 24.04 LTS Noble and outside amd64/arm64. Production setup uses repository-pinned component/tool versions by default. The explicit `--use-latest` override remains available for operator-requested live-version runs and is outside the normal/golden path.\n",
    "`setup-system.sh` fails closed outside Ubuntu 24.04 LTS Noble and outside amd64/arm64. Production setup uses repository-pinned component/tool versions by default. The explicit `--use-latest` override remains available for operator-requested live-version runs and is outside the normal/golden path. For supported image/CrowdSec fields, that override writes literal `latest` values into the generated `.env`; later pulls therefore remain mutable until the operator re-pins those fields. Caddy and yq stay exact-pinned; SOPS resolves its latest stable release only for the setup-system invocation.\n",
)

replace_once(
    "docs/PROJECT-BOUNDARY.md",
    "The project is pre-release. `VERSION` is a development identifier until the first real release. Production setup consumes source-controlled version pins by default. An explicit `--use-latest` override remains available for operator-requested live-version runs, but it is outside the normal/golden path. Runtime host code targets Ubuntu 24.04 LTS Noble on amd64/arm64 and may use its GNU toolchain directly.\n",
    "The project is pre-release. `VERSION` is a development identifier until the first real release. Production setup consumes source-controlled version pins by default. An explicit `--use-latest` override remains available for operator-requested live-version runs, but it is outside the normal/golden path. For supported image/CrowdSec fields, the override writes literal `latest` values into `.env`, intentionally keeping later pulls mutable until the operator re-pins those fields. Caddy and yq remain exact-pinned; SOPS latest resolution applies only to the setup-system invocation. Runtime host code targets Ubuntu 24.04 LTS Noble on amd64/arm64 and may use its GNU toolchain directly.\n",
)

replace_once(
    "docs/DEPLOYMENT.md",
    "The normal production lifecycle is root-operated. A Docker-group re-login is not a required deployment phase for the supported operator path.\n\n",
    """The normal production lifecycle is root-operated. A Docker-group re-login is not a required deployment phase for the supported operator path.

### Optional mutable-version override

Normal production setup uses the repository-pinned versions. `--use-latest` is an explicit operator opt-in outside the golden path:

```bash
sudo ./setup.sh install \\
  --domain vault.yourdomain.com \\
  --email admin@yourdomain.com \\
  --use-latest
```

This override is intentionally persistent for supported image and CrowdSec version fields: environment generation writes literal `latest` values into `.env`, so later image pulls or CrowdSec setup can resolve newer versions until those fields are restored to exact pins. Caddy and yq remain exact-pinned. SOPS resolves the latest stable release only for the setup-system invocation. `--auto` does not imply `--use-latest`.

""",
)

old_test = """grep -Fq 'Production setup uses repository-pinned component/tool versions by default.' docs/SCRIPTS.md \\
    || fail 'operator docs must state that normal production setup is source-pinned'
grep -Fq 'The explicit `--use-latest` override remains available for operator-requested live-version runs and is outside the normal/golden path.' docs/SCRIPTS.md \\
    || fail 'operator docs must retain the explicit --use-latest override contract'
! grep -Fq 'mutable latest-version resolution is not part of the operator interface' docs/SCRIPTS.md \\
    || fail 'operator docs must not deny the supported --use-latest override'
"""
new_test = """grep -Fq 'Production setup uses repository-pinned component/tool versions by default.' docs/SCRIPTS.md \\
    || fail 'operator docs must state that normal production setup is source-pinned'
grep -Fq 'The explicit `--use-latest` override remains available for operator-requested live-version runs and is outside the normal/golden path.' docs/SCRIPTS.md \\
    || fail 'operator docs must retain the explicit --use-latest override contract'
grep -Fq 'writes literal `latest` values into the generated `.env`; later pulls therefore remain mutable until the operator re-pins those fields.' docs/SCRIPTS.md \\
    || fail 'operator docs must explain that latest image/CrowdSec state persists in .env'
! grep -Fq 'mutable latest-version resolution is not part of the operator interface' docs/SCRIPTS.md \\
    || fail 'operator docs must not deny the supported --use-latest override'
! grep -Fq 'for this run instead of the repository-pinned normal defaults' setup.sh \\
    || fail 'setup help must not describe persistent latest tags as run-local'
grep -Fq "fields as 'latest' in .env; later pulls remain mutable until" setup.sh \\
    || fail 'setup help must disclose persistent mutable .env tags'
grep -Fq "as 'latest' in .env. This persists across later pulls until" utilities/setup-env.sh \\
    || fail 'setup-env help must disclose persistent mutable .env tags'
grep -Fq 'run: ./tests/run-tests.sh all' .github/workflows/canonical-tests.yml \\
    || fail 'CI must execute the canonical permanent test entrypoint exactly'
"""
replace_once("tests/suites/foundation/case-runner-contracts.bash", old_test, new_test)
