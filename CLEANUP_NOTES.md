# CLEANUP_NOTES.md — Facade Removal & Modular Lib Refactor

## What Changed

### PASS A — Facade Removed from lib/common.sh

`lib/common.sh` was a monolithic file containing all logging, validation,
configuration, and utility functions. It has been refactored into four files:

| File | Contents | Dependencies |
|------|----------|--------------|
| `lib/log.sh` | COLOR_*, log_* functions, level filtering | none |
| `lib/validate.sh` | validate_email/domain/port/ip/url | none |
| `lib/config.sh` | load_env_file, get_config_value, require_config | auto-loads log.sh |
| `lib/common.sh` | privilege, system, filesystem, network, lifecycle | requires log.sh first |

### PASS B — Domain Lib Self-Sufficiency

Each domain lib that calls log_* internally now self-loads log.sh if it has
not already been loaded. The idempotency guard in log.sh (`VW_LOG_LIB_LOADED`)
prevents double-loading.

Libs updated:
- `lib/crypto.sh` — added self-load of log.sh
- `lib/docker.sh` — added self-load of log.sh
- `lib/backup-utils.sh` — replaced explicit dependency assertions with self-load of log.sh
- `lib/storage.sh` — added self-load of log.sh
- `lib/email.sh` — added self-load of log.sh
- `lib/maintenance-utils.sh` — added self-load of log.sh
- `lib/secrets.sh` — added self-load of log.sh (crypto.sh also does this, but explicit is clearer)

### PASS C — Caller Source Block Updates

Every caller script now sources exactly the libs it uses, in explicit
dependency order:

```bash
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/config.sh"   # if caller uses load_env_file / get_config_value
source "${LIB_DIR}/validate.sh" # if caller uses validate_email / validate_domain
source "${LIB_DIR}/common.sh"
init_common_lib "$0"
# ... domain libs as needed
```

Only `setup.sh` sources `validate.sh` (it calls `validate_domain` and
`validate_email`). All other scripts define their own local validate helpers.

Scripts updated: setup.sh, startup.sh, edit-secrets.sh, utilities/restore-run.sh,
utilities/backup-run.sh, utilities/maintenance-{db-maint,email,health,run,
update-dns,update-firewall,update}.sh, utilities/pre-production-drill.sh,
utilities/secrets-{edit,export-recovery-kit,list,rotate,view}.sh,
utilities/setup-{crowdsec,env,firewall,secrets,storage,system,systemd}.sh,
utilities/smoke-test.sh.

## Architectural Decisions

### Decision 1: HOST_ARCH / GITHUB_ARCH added to init_common_lib()

**Override of:** problem-statement header mentioning these as "exported by
init_common_lib" without specifying existing implementation.

**Reason:** The header for `lib/common.sh` explicitly lists
`HOST_ARCH, GITHUB_ARCH (exported by init_common_lib)`. Added a simple
`uname -m` → GitHub release asset arch string mapping (x86_64→amd64,
aarch64→arm64, armv7l→arm) to init_common_lib(). GITHUB_ARCH intentionally
uses bare arch names (`amd64`, `arm64`, `arm`) that match GitHub release
asset filenames, not Docker platform strings (`linux/amd64`). If a Docker
platform string is ever needed separately, derive it at call site as
`"linux/${GITHUB_ARCH}"`.

### Decision 2: lib/secrets.sh keeps explicit log.sh self-load

**Reason:** secrets.sh sources crypto.sh which self-loads log.sh, so the
self-load in secrets.sh is technically redundant. However, explicit is
better than implicit. If crypto.sh's loading pattern ever changes, secrets.sh
will still be self-sufficient without a silent regression.

**Structural note:** `_SECRETS_LIB_DIR` is intentionally **not** unset
immediately after the `log.sh` self-load — it is reused on the very next
line to source `crypto.sh`, then unset after that call. This is a deliberate
deviation from other domain libs (which unset their `_VW_*_LIB_DIR` right
after the self-load) because secrets.sh needs the directory for two source
calls, not one.

### Decision 3: lib/validate.sh is standalone (no log dependency)

The validate functions (`validate_email`, `validate_domain`, etc.) return
boolean exit codes only — they do not call log_*. This makes validate.sh
truly self-sufficient with no dependencies, which is the cleanest design.
Callers that want to log the validation result handle that themselves.

### Decision 4: lib/config.sh auto-loads log.sh at source time

The problem statement specifies config.sh sources log.sh directly. The
auto-load pattern `[[ -n "${VW_LOG_LIB_LOADED:-}" ]] || source ...` is used
(same as domain libs) so config.sh works both when pre-loaded by a caller
and when sourced standalone.

### Decision 5: backup-utils.sh dependency assertions replaced with self-load

**Override of:** original code that used `declare -f` to assert log functions
are available and abort if not found.

**Reason:** The self-load pattern is architecturally superior: instead of
aborting at source time (which forces a strict load order on callers), the
lib becomes self-sufficient. Any caller that previously sourced log.sh before
backup-utils.sh will continue to work (idempotency guard prevents double-load).

## Load Order (Canonical)

```
log.sh          ← no deps; always first
validate.sh     ← no deps; after log.sh (or standalone)
config.sh       ← auto-loads log.sh; after log.sh
common.sh       ← requires log.sh; optionally benefits from config.sh
  init_common_lib "$0"
crypto.sh       ← auto-loads log.sh
docker.sh       ← auto-loads log.sh
secrets.sh      ← auto-loads log.sh; sources crypto.sh
backup-utils.sh ← auto-loads log.sh
storage.sh      ← auto-loads log.sh
email.sh        ← auto-loads log.sh
maintenance-utils.sh ← auto-loads log.sh; requires config.sh
```
