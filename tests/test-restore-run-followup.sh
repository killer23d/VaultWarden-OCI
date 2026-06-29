#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/utilities/restore-run.sh"
fail(){ echo "not ok - $*" >&2; exit 1; }
pass(){ echo "ok - $*"; }

require_pattern(){ local pat="$1" msg="$2"; grep -Eq "$pat" "$SCRIPT" || fail "$msg"; }
reject_pattern(){ local pat="$1" msg="$2"; ! grep -Eq "$pat" "$SCRIPT" || fail "$msg"; }

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

require_pattern '_rollback_rotation' 'restore-run must define transactional key-rotation rollback'
require_pattern 'refusing to start services automatically' 'restore-run must fail loudly before startup when key rotation fails'
require_pattern 'Post-promotion SOPS validation failed' 'restore-run must validate promoted rekey artifacts'
pass 'restore-run has rollback and fail-loud key rotation safeguards'

require_pattern 'RESTORE_DECRYPT_AGE_KEY_FILE="\$supplied_path"' 'restore-supplied key must be stored in restore-scoped variable'
require_pattern 'RESTORE_DECRYPT_AGE_KEY_FILE="\$configured_key"' 'blank Age prompt must use configured key as restore decrypt key'
require_pattern 'For normal same-server restore, press Enter to use the currently configured key' 'Age prompt must document Enter as same-server path'
require_pattern 'Only paste an AGE-SECRET-KEY-1\.\.\. value if this backup was encrypted' 'Age prompt must reserve pasted keys for old/offline keys'
require_pattern 'SOPS_AGE_KEY_FILE="\$operational_sops_age_key_file" "\$\{PROJECT_ROOT\}/utilities/backup-run\.sh" run emergency --quiet' 'pre-restore emergency snapshot must receive operational SOPS key explicitly'
require_pattern 'selected backup decrypt key: \$\{RESTORE_DECRYPT_AGE_KEY_FILE:-<not resolved>\}' 'preflight diagnostic must identify selected backup decrypt key separately'
require_pattern 'Fix current SOPS decryptability, or intentionally skip the safety snapshot with --no-backup' 'preflight diagnostic must explain --no-backup escape hatch'
reject_pattern 'local AGE_KEY_FILE; AGE_KEY_FILE="\$\(get_config_value "SOPS_AGE_KEY_FILE"' 'restore main must not use AGE_KEY_FILE for selected backup decrypt key'
pass 'restore-run separates restore decrypt key from operational SOPS key'

bash -n "$SCRIPT"
pass 'bash -n utilities/restore-run.sh'
printf '1..7\n'
