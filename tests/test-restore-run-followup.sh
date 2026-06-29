#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/utilities/restore-run.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }

require_pattern(){ local pat="$1" msg="$2"; rg -q "$pat" "$SCRIPT" || fail "$msg"; }
reject_pattern(){ local pat="$1" msg="$2"; ! rg -q "$pat" "$SCRIPT" || fail "$msg"; }

require_pattern 'get_config_value "DATA_VOLUME_DEVICE" ""' 'restore-run must inspect DATA_VOLUME_DEVICE before readiness skip'
require_pattern 'FORCE.*USE_REMOTE.*-z "\$_configured_data_device"' 'force remote skip must be limited to no data device'
require_pattern 'require_project_state_ready \|\| exit 1' 'storage readiness must still be enforced'
pass 'restore-run refuses to skip storage readiness when DATA_VOLUME_DEVICE is configured'

require_pattern 'bash "\$\{PROJECT_ROOT\}/startup.sh" --skip-pull' 'restore-run must invoke startup.sh --skip-pull'
reject_pattern 'docker compose up -d --remove-orphans' 'restore-run must not directly start docker compose'
pass 'restore-run invokes startup path instead of direct docker compose up'

require_pattern 'local install_env="\$\{STATE_DIR\}/config/install.env"' 'restore-run must target persistent install.env'
require_pattern 'SOPS_AGE_KEY_FILE=\$\{canonical_key\}.*\$install_env|written to \$install_env' 'restore-run must update SOPS_AGE_KEY_FILE in install.env'
pass 'restore-run updates state config install.env when key path changes'

require_pattern 'auto_fix_critical_permissions "\$PROJECT_ROOT"' 'restore-run must run final permission repair'
pass 'restore-run calls final permission repair before startup'

bash -n "$SCRIPT"
pass 'bash -n utilities/restore-run.sh'
printf '1..5\n'
