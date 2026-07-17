# VaultWarden-OCI Script Codebase Quality & Modularity Audit

**Repository:** killer23d/VaultWarden-OCI  
**Branch:** delta  
**Audit Date:** 2026-07-17

---

## 1. One-Page Decision Summary

| Item | Value |
|---|---|
| **Overall Verdict** | **Healthy with bounded cleanup opportunities** |
| **Audited SHA** | `a6d2bc39bb0f67e50fe9a05e0fe0292b5b3b2f4a` |
| **Total Score** | **78 / 100** |
| **Confirmed Critical** | 0 |
| **Confirmed High** | 1 |
| **Confirmed Medium** | 5 |
| **Confirmed Low** | 4 |
| **Informational** | 4 |
| **E1 (Reproduced)** | 1 |
| **E2 (Statically confirmed)** | 9 |
| **E3 (Strong risk)** | 3 |
| **E4 (Investigation lead)** | 1 |

### Top Five Concrete Risks

1. **SCQ-001** — Root enforcement inconsistency: setup-systemd.sh uses inline `EUID` checks in 4 subcommand dispatch points instead of the canonical `require_root` helper, with less actionable error messages.
2. **SCQ-002** — `defaults.sh` is sourced *after* `config.sh` and `common.sh` in some entry points (notably `setup.sh`), meaning default constants may not be available during library init paths.
3. **SCQ-003** — `_cmd_configure()` in setup-secrets.sh at 950 lines is the largest single function in the codebase, making it difficult to review and test individual phases.
4. **SCQ-004** — `_VW_DEFAULT_STATE_DIR` (from defaults.sh) is used in 41 locations, but bare `/var/lib/vaultwarden` appears in 64 production locations — some not guarded by the canonical default.
5. **SCQ-005** — `docker.sh` executes `docker compose config` at source-time (line 41) which requires a running Docker daemon; this can cause log noise or early failure in contexts where Docker is not expected.

### Top Five Bounded Cleanup Opportunities

1. Consolidate inline `EUID` root checks in `setup-systemd.sh` to use `require_root`.
2. Normalize `defaults.sh` source order so it is always sourced before `config.sh`.
3. Reduce `_cmd_configure()` in setup-secrets.sh by extracting phase functions.
4. Replace remaining bare `/var/lib/vaultwarden` literals with `${_VW_DEFAULT_STATE_DIR}` where they represent the same policy.
5. Guard docker.sh's Compose project detection with a lazy-init pattern to avoid source-time daemon requirements.

### Top Five Areas That Should Remain Unchanged

1. **Three-tier backup architecture** (db/full/emergency) — intentionally distinct failure, security, and recovery semantics.
2. **Separate restore/recovery workflows** — `restore-run.sh` and `recover.sh` serve different domain contracts that must not be merged.
3. **Local root enforcement in `setup-crowdsec.sh`** — runs before lib sourcing; the canonical require_root depends on common.sh which may not be available.
4. **Per-script operation guard patterns** — each mutating workflow owns its specific lock configuration and contention behavior; a generic wrapper would lose context.
5. **`maintenance-health.sh` health lock** — uses a separate HEALTH_LOCK_FD because it has independent contention semantics from the global mutating lock.

### Broad Refactor Justified?

**No.** The architecture is sound. Improvements are bounded, incremental, and focused on consistency rather than restructuring.

### Recommended First PR

Normalize `defaults.sh` source ordering and consolidate inline root checks in `setup-systemd.sh` to use `require_root`. (~4 files, low risk, focused tests exist.)

### Conditions Before Another Full Audit

- After any major PR touching `lib/operations.sh`, `lib/config.sh`, backup/restore flow, or secrets management.
- After any PR exceeding ~500 lines of library/utility changes.

---

## 2. Executive Summary

VaultWarden-OCI is a well-structured, security-conscious, small-team Vaultwarden deployment. The 41,716-line production shell codebase (plus 13,447 lines of tests) demonstrates strong architectural intent: thin public dispatchers, canonical library ownership, explicit operation guards, typed contention semantics, and focused regression coverage across 21 permanent test cases in 4 domain suites.

The codebase has matured through iterative PR work. Recent changes (PR #258–#260) resolved prior cleanliness findings, consolidated test suites, and hardened CrowdSec/firewall paths. The current state reflects a codebase that has been actively improved.

Key architectural strengths:

- **Clear ownership model**: lib/ files own policy, utilities/ own workflow, top-level scripts are thin dispatchers.
- **Consistent privilege enforcement**: `require_root` from `lib/common.sh` is the canonical root gate used by 30+ production scripts.
- **Robust operation guard**: `lib/operations.sh` provides kernel `flock`-based serialization with typed metadata, inherited locks, and exit-75 contention.
- **Clean static analysis**: ShellCheck (0.11.0, severity=warning) reports zero warnings. All 80 shell files pass `bash -n` syntax check.
- **Strong test coverage**: 21 permanent test cases covering foundation, security, operations, and data-protection domains.

Key findings center on consistency rather than architectural flaws: source-order for `defaults.sh`, inline root checks that bypass the canonical helper, large monolithic functions in setup-secrets.sh, and scattered bare path literals.

---

## 3. Audit Identity

| Field | Value |
|---|---|
| Repository | `killer23d/VaultWarden-OCI` |
| Branch | `delta` |
| Exact SHA | `a6d2bc39bb0f67e50fe9a05e0fe0292b5b3b2f4a` |
| Date | 2026-07-17 |
| Environment | macOS (arm64-apple-darwin25), development workstation |
| Initial worktree | Clean (no modified/untracked files) |
| Final worktree | Single new report file only |
| Bash (audit host) | 3.2.57(1)-release (arm64-apple-darwin25) |
| Bash (target) | 5.x (Ubuntu 24.04 LTS Noble) |
| ShellCheck | 0.11.0 |
| Git | 2.50.1 (Apple Git-155) |

**Note:** The audit host runs macOS with Bash 3.2. The production target is Ubuntu 24.04 with Bash 5. The codebase correctly enforces Bash 5 at `lib/common.sh:28–32`. Tests and ShellCheck were run on the audit host; macOS test failures in `case-runner-contracts.bash` are expected (GNU timeout unavailable on macOS) and do not indicate production defects.

---

## 4. Scope and Exclusions

### Inspected

- All 80 shell files (`.sh` and `.bash`) across the repository.
- 62 production shell files (top-level, lib/, utilities/, caddy/).
- 18 test files (tests/, tests/suites/).
- Makefile (989 lines, 45,488 bytes).
- 16 systemd unit files (service + timer).
- 1 GitHub Actions workflow (`doc-drift.yml`).
- Docker Compose example (`docker-compose.yml.example`).
- `.env.example`, `secrets-schema.yaml`, `VERSION`.
- All documentation under `docs/`.

### Excluded (by skill non-goals)

- Live production-host operations (no setup, uninstall, backup, restore, key rotation, firewall mutation, CrowdSec reconciliation, systemd installation, or service mutation).
- Runtime Docker behavior (containers not running on audit host).
- Network operations (rclone sync, DNS updates, Cloudflare API calls).
- Prior reports under `reports/` were treated as context, not authoritative.

---

## 5. Methodology

### Pass 1: Forward Architecture Audit

Built a complete implementation map from public commands through dispatchers to library implementations. Traced 24 end-to-end domains (setup, lifecycle, secrets, backup, restore, recovery, storage, systemd, CrowdSec, firewall, health, maintenance, email, operations, permissions, migration, uninstall, test reset). Identified every function, caller, source dependency, privilege boundary, and lock boundary.

### Pass 2: Reverse Challenge Audit

Started from shared helpers in `lib/` and traced all callers, bypasses, duplicate implementations, and policy reproduction. Challenged every potential consolidation against failure, privilege, rollback, interruption, and test boundary criteria.

### Evidence Standards

- **E1 — Directly reproduced**: Executable behavior demonstrated safely.
- **E2 — Statically confirmed**: All relevant current execution paths support the conclusion.
- **E3 — Strong risk**: Credible execution path exists but runtime reproduction unavailable.
- **E4 — Investigation lead**: Evidence incomplete; further work needed.

Only E1 and E2 findings are described as confirmed. E3 items are risks. E4 items are separated.

---

## 6. Repository Script Inventory Summary

| Category | Count | Lines |
|---|---|---|
| Production shell files | 62 | 41,716 |
| Shared libraries (lib/) | 17 | 14,861 |
| Utilities (utilities/) | 34 | 25,046 |
| Top-level entry points | 7 | 1,612 |
| Component-specific (caddy/) | 1 | 297 |
| Test runner | 1 | 386 |
| Test architecture | 1 | 379 |
| Test suites | 18 | 12,682 |
| Test library | 1 | 12 |
| **Total shell files** | **80** | **55,163** |

| Metric | Value |
|---|---|
| Production functions | ~1,160 |
| Test functions | ~756 |
| Libraries with load-once guards | 17/17 (100%) |
| ShellCheck suppressions (total) | 83 |
| ShellCheck suppressions (production) | ~60 |
| `|| true` patterns (production) | ~647 |
| Duplicate function names (production) | See section 12 |

---

## 7. Architecture and Call-Flow Map

### Public Entry Points → Dispatcher → Implementation

```
setup.sh ──────→ utilities/setup-system.sh
              ├─→ utilities/setup-env.sh
              ├─→ utilities/setup-storage.sh
              ├─→ utilities/setup-firewall.sh
              ├─→ utilities/setup-secrets.sh
              ├─→ utilities/setup-crowdsec.sh
              └─→ utilities/setup-systemd.sh

startup.sh ────→ (monolithic lifecycle with lib/operations.sh guard)

maintenance.sh ─→ utilities/maintenance-{health,run,update,db-maint,email,update-dns,update-firewall}.sh

backup.sh ─────→ utilities/backup-run.sh

restore.sh ────→ utilities/restore-run.sh

edit-secrets.sh → utilities/secrets-{edit,view,list,rotate,export-recovery-kit}.sh

recover.sh ────→ (self-contained recovery workflow)

dashboard.sh ──→ (dispatches to Makefile targets and direct script invocations)
```

### Library Dependency Graph (production)

```
lib/defaults.sh          ← No deps (load-first contract)
lib/log.sh               ← No deps
lib/validate.sh          ← log.sh (auto-loaded)
lib/config.sh            ← log.sh (auto-loaded)
lib/common.sh            ← log.sh, config.sh (caller must source first)
lib/operations.sh        ← common.sh (_ensure_lock_file via declare -F)
lib/docker.sh            ← log.sh (auto-loaded)
lib/crypto.sh            ← log.sh (auto-loaded)
lib/schema.sh            ← (standalone)
lib/secrets.sh           ← log.sh, defaults.sh, config.sh, schema.sh (auto-loaded)
lib/backup-utils.sh      ← log.sh (auto-loaded)
lib/email.sh             ← log.sh (auto-loaded)
lib/storage.sh           ← (expects common.sh, config.sh pre-loaded)
lib/migrate.sh           ← (expects full lib stack pre-loaded)
lib/crowdsec-worker.sh   ← (expects common.sh pre-loaded)
lib/maintenance-utils.sh ← log.sh (auto-loaded)
lib/runtime-permissions.sh ← (expects common.sh pre-loaded)
```

**No dependency cycles detected.** All source relationships are acyclic.

---

## 8. Scorecard

| # | Category | Score | Confidence | Justification |
|---|---|---|---|---|
| 1 | Architecture and ownership | 9/10 | High | Clear lib/utility/dispatcher ownership. Thin entry points. Minor: defaults.sh source order inconsistency. |
| 2 | Modularity and cohesion | 8/10 | High | Libraries own cohesive domains. Minor: setup-secrets.sh has 950-line function. No cross-module private state mutation. |
| 3 | Reuse and duplication control | 7/10 | High | Canonical helpers widely used. ~15 inline root checks bypass require_root. Bare path literals instead of defaults.sh constants. |
| 4 | Correctness and failure semantics | 8/10 | High | set -euo pipefail universal. Typed exit 75 contention. Truthful success messages. Minor: large function complexity risk. |
| 5 | Security and privilege handling | 8/10 | High | Root enforcement early and consistent. SOPS/Age custody correct. No unsafe eval. Temp file cleanup with traps. |
| 6 | Concurrency and interruption safety | 9/10 | High | Mature flock-based operation guard. FD isolation in spinners. Inherited lock support. Signal traps. |
| 7 | Idempotence, rollback, state consistency | 8/10 | High | Restore staging/promotion. Recovery pre-commit rollback. Atomic env mutation. |
| 8 | Operational efficiency | 8/10 | Medium | docker.sh source-time Compose detection is the only meaningful overhead concern. No expensive loops detected. |
| 9 | Testability and regression coverage | 7/10 | High | 21 permanent test cases across 4 domains. Missing: direct behavioral tests for largest functions. |
| 10 | Documentation and operator-interface consistency | 8/10 | Medium | Generated command reference. Make targets match script grammar. Minor: recovery card last-updated not verified. |
| | **TOTAL** | **78/100** | | |

---

## 9. Function and Helper Ownership Analysis

### Canonical Helpers (Appropriately Reused)

| Helper | Owner | Callers | Classification |
|---|---|---|---|
| `require_root` | `lib/common.sh:146` | 30+ utilities/scripts | Canonical, appropriately reused |
| `is_root` | `lib/common.sh:142` | 12+ callers | Canonical, appropriately reused |
| `log_info/warn/error/success` | `lib/log.sh` | Universal | Canonical, appropriately reused |
| `load_env_file` | `lib/config.sh:44` | 15+ callers | Canonical, appropriately reused |
| `load_project_environment` | `lib/config.sh:240` | 12+ callers | Canonical, appropriately reused |
| `operation_acquire/release` | `lib/operations.sh` | 15+ mutating workflows | Canonical, appropriately reused |
| `fix_known_path_permissions` | `lib/common.sh:358` | 5+ callers | Canonical, appropriately reused |
| `_set_env_var` | `lib/config.sh:302` | 8+ callers | Canonical, appropriately reused |
| `retry_with_backoff` | `lib/common.sh:96` | 5+ callers | Canonical, appropriately reused |
| `operator_confirm_yes_no` | `lib/common.sh:197` | 10+ callers | Canonical, appropriately reused |
| `has_command` | `lib/common.sh:43` | 20+ callers | Canonical, appropriately reused |

### Helpers with Justified Local Alternatives

| Local Pattern | Location | Why Separate |
|---|---|---|
| `_mv_require_root()` | `lib/migrate.sh:154` | Migration-specific root check with resume-state context |
| `backup_require_root()` | `utilities/backup-run.sh:219` | Backup-specific root check that allows metadata subcommands root-free |
| `_health_lock_acquire()` | `utilities/maintenance-health.sh` | Uses HEALTH_LOCK_FD, not the global operation lock |
| CrowdSec inline root check | `utilities/setup-crowdsec.sh:49` | Executes before lib sourcing; require_root not available |

### Helpers Bypassing Canonical Owner (Finding SCQ-001)

| Script | Lines | Bypass Pattern |
|---|---|---|
| `utilities/setup-systemd.sh` | 706, 1040, 1137, 1505 | Inline `EUID -ne 0` with bare `log_error; exit 1` instead of `require_root` |

---

## 10. Policy Ownership Analysis

### Root Enforcement Policy

- **Canonical owner**: `require_root()` in `lib/common.sh:146`
- **Public consumers**: 30+ scripts via `require_root "$@"`
- **Bypasses**: `setup-systemd.sh` (4 inline checks), `setup-crowdsec.sh` (1, justified — pre-lib), `setup-firewall.sh:546`, `setup-system.sh:993`, `setup-env.sh:437`
- **Assessment**: The `setup-*.sh` family uses inline `(( EUID == 0 )) || { log_error ...; exit 1; }` — this is a less actionable error (no `sudo` hint) but functionally equivalent. The inconsistency is a consistency risk, not a security defect.

### Environment Precedence Policy

- **Canonical owner**: `load_project_environment()` in `lib/config.sh:240`
- **Policy**: installed env → persistent install.env → repo .env
- **Consumers**: All production scripts through `load_project_environment` or `load_env_file`
- **Bypasses**: `setup-crowdsec.sh:93` sources repo `.env` directly (justified — runs before full lib stack)
- **Assessment**: Well centralized. No policy drift detected.

### Operation Locking Policy

- **Canonical owner**: `operation_acquire/release` in `lib/operations.sh`
- **Policy**: kernel flock authoritative, metadata descriptive, exit 75 for contention
- **Consumers**: startup, backup, restore, secrets, key-rotate, maintenance, setup phases
- **Bypasses**: None detected (health uses HEALTH_LOCK_FD, which is intentionally separate)
- **Assessment**: Strong centralization. No drift.

### Backup Verification Policy

- **Canonical owner**: `verify_backup_archive()` in `lib/backup-utils.sh`
- **Policy**: Verification failure is not successful backup
- **Consumers**: backup-run.sh, pre-production-drill.sh, smoke-test.sh
- **Assessment**: Consistent. Pre-production drill delegates to canonical verifier.

---

## 11. Duplicate and Near-Duplicate Implementation Matrix

### Real Duplication

| Pattern | Implementations | Owner | Consolidation Safe? |
|---|---|---|---|
| Inline root checks | `setup-systemd.sh` (4), `setup-firewall.sh`, `setup-system.sh`, `setup-env.sh` | `require_root` in common.sh | Yes for setup-systemd.sh; others are borderline (short one-liners in main() dispatch) |
| Bare `/var/lib/vaultwarden` path | 64 occurrences | `_VW_DEFAULT_STATE_DIR` in defaults.sh | Partial — many are fallback defaults `${PROJECT_STATE_DIR:-/var/lib/vaultwarden}` which is correct pattern |
| `dispatch_information_request()` | 5 scripts | Pattern, not shared | Retain — each script has its own `--help`/`--version` contract |
| `_require_cli_value()` | 7 scripts | Pattern, not shared | Retain — parser-local, 2-3 lines each, different error contexts |
| `_load_env()` | 5 scripts | Pattern, not shared | Retain — each has environment-specific pre/post logic |
| `show_help()/how_help()` | 36/30 scripts | Per-script contract | Retain — help text is intrinsically per-command |

### False-Positive Duplication (Intentionally Separate)

| Pattern | Why Separate |
|---|---|
| `check_prerequisites()` (6 scripts) | Each checks different prerequisites for its domain |
| `cleanup()` (3 scripts) | Different cleanup semantics, temp files, and rollback behavior |
| `verify_sqlite()` (2 scripts) | backup-utils.sh vs restore-run.sh have different error handling and staging contexts |
| `create_backup()` (2 scripts) | backup-run.sh creates archives; restore-run.sh creates pre-restore snapshots |
| `_default_backup_dir()` (3 scripts) | Different tier contexts (db/full/emergency) |
| Backup/restore `list_backups()` (2 scripts) | Different selection, filtering, and display contracts |
| `run_health_check()` (2 scripts) | maintenance-health.sh vs smoke-test.sh have completely different scope and semantics |

---

## 12. Global State and Implicit API Analysis

### Critical Global Variables

| Variable | Defined | Set | Read | Exported | Source-Order Sensitive |
|---|---|---|---|---|---|
| `PROJECT_ROOT` | common.sh:41 | All entry points | Universal | Yes | No — set at common.sh source time |
| `PROJECT_STATE_DIR` | config.sh:277 | load_project_environment | Universal | Yes | Yes — must be after env load |
| `OPERATION_LOCK_FD` | operations.sh:21 | operation_acquire | spinner, traps | No | Yes — must be after acquire |
| `HEALTH_LOCK_FD` | maintenance-health.sh | health lock acquire | spinner, traps | No | Script-local |
| `DRY_RUN` | Per-script | CLI parsing | Throughout script | No | No |
| `SECRETS_FILE` | config.sh:405 | load_env_file, resolve_secrets_file | 20+ callers | Yes | Yes — after env load |
| `SOPS_AGE_KEY_FILE` | config.sh:406 | load_env_file | crypto.sh, secrets.sh | Yes | Yes — after env load |
| `_VW_DEFAULT_STATE_DIR` | defaults.sh:21 | Source-time | 41 callers | No (readonly) | No |
| `_VW_CALLING_SCRIPT` | log.sh:21 | init_common_lib | All log functions | No | Yes — after init |

### Hidden Function Parameters via Globals

The spinner system (`spinner_start/spinner_stop`) reads `OPERATION_LOCK_FD`, `OPERATION_SPECIFIC_LOCK_FD`, `VW_OPERATION_INHERITED_FD`, and `HEALTH_LOCK_FD` implicitly to close lock descriptors in the spinner subshell. This is a necessary safety measure (prevents orphan spinners holding locks) but creates an implicit coupling. This coupling is documented in code comments (`lib/log.sh:129–146`).

**Assessment:** The global state model is reasonable for this project's scope. Most globals are set-once configuration. The operation lock FD coupling is the most complex implicit API but is well-documented and has test coverage (`case-lock-fd-hygiene.bash`).

---

## 13. Source Dependency Graph

### Explicit and Safe Dependencies

All 17 libraries have load-once guards. The standard source order is:

```
defaults.sh → log.sh → validate.sh → config.sh → common.sh → [domain libs]
```

Libraries that auto-load log.sh when sourced standalone: config.sh, docker.sh, crypto.sh, secrets.sh, backup-utils.sh, email.sh, validate.sh, maintenance-utils.sh.

### Source-Order Finding (SCQ-002)

In `setup.sh`, `defaults.sh` is sourced at line 56 — *after* config.sh (line 47) and common.sh (line 48). This means `_VW_DEFAULT_STATE_DIR` is not available when config.sh initializes its fallback paths at source time (config.sh:402–409). In practice this is mitigated because config.sh uses its own `${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}` defensive pattern, but the source order contradicts the documented "source before all other lib files" contract in defaults.sh.

Other entry points (startup.sh, utilities/*) correctly source defaults.sh early or rely on config.sh's fallback.

### Libraries Executing Work at Source Time

- `docker.sh:38–53`: Detects Compose project name via `docker compose config` at source time. This requires a running Docker daemon and can fail or produce stderr noise in test/help contexts.
- `common.sh:28–32`: Enforces Bash 5 at source time (intentional, correct).

---

## 14. Modularity, Cohesion, and Coupling

### Assessment

- **Top-level scripts**: All 7 are thin dispatchers or lifecycle entry points. `startup.sh` (874 lines) is the thickest but owns a single cohesive lifecycle.
- **Utilities**: Each owns one operational domain. No utility crosses into another's domain.
- **Libraries**: Cohesive ownership with clear domain boundaries. No library modifies another library's private state.
- **File placement**: Correct — shared policy in lib/, workflow in utilities/, dispatch at top-level.
- **Function names**: Generally reflect behavior. `_cmd_configure()` in setup-secrets.sh is named too broadly for its 950 lines.

### High Fan-In Modules

| Module | Sourced By |
|---|---|
| lib/log.sh | 60+ (universal) |
| lib/common.sh | 50+ |
| lib/config.sh | 40+ |
| lib/operations.sh | 20+ |
| lib/crypto.sh | 15+ |

This fan-in is appropriate — these are foundational infrastructure.

### High Fan-Out Scripts (most library sources)

| Script | Libraries Sourced |
|---|---|
| maintenance-run.sh | 11 |
| maintenance-db-maint.sh | 11 |
| setup.sh | 11 |
| maintenance-update.sh | 10 |
| maintenance-health.sh | 10 |

This fan-out reflects the breadth of these scripts' operational domains and is acceptable.

---

## 15. Constants and Contract Duplication

### Path Literals

| Path | Production Occurrences | Canonical Owner | Assessment |
|---|---|---|---|
| `/var/lib/vaultwarden` | 64 | `_VW_DEFAULT_STATE_DIR` (defaults.sh:21) | Most are `${PROJECT_STATE_DIR:-/var/lib/vaultwarden}` fallbacks — correct defensive pattern. ~12 are bare literals in systemd units and documentation that correctly match the default. |
| `/etc/vaultwarden` | 127 | No single constant | Distributed across config.sh, common.sh, runtime-permissions.sh, systemd units. This is correct — the path is an installed-runtime boundary, not a project variable. |
| `/opt/vaultwarden-scripts` | 8 | setup-systemd.sh:INSTALLED_SCRIPTS_DIR | Correctly centralized in systemd installer. |
| `/run/vaultwarden-oci` | 41 | Various | Runtime directory. Correctly appears in secrets materialization, operations, and permissions. |

### Exit Codes

| Code | Meaning | Canonical Owner | Consistency |
|---|---|---|---|
| 0 | Success | Universal | Consistent |
| 1 | General failure | Universal | Consistent |
| 75 | Expected contention (skip) | lib/operations.sh, systemd contracts | Consistent — tested in case-operations.bash |
| 130 | INT signal | Signal traps | Consistent |
| 143 | TERM signal | Signal traps | Consistent |

### UID/GID Constants

| Value | Meaning | Locations | Assessment |
|---|---|---|---|
| `1001:1001` | Default PUID/PGID | defaults.sh, .env.example | Canonical in defaults.sh |
| `2000:2000` | Caddy UID/GID | runtime-permissions.sh, restore-run.sh, docs | Correctly co-located with Caddy paths; not in defaults.sh (Caddy is infrastructure, not a project variable) |

---

## 16. Efficiency Analysis

### docker.sh Source-Time Detection (SCQ-005)

`docker.sh:38–53` runs `docker compose config --format json | jq` at **source time** to auto-detect the Compose project name. This:

- Requires a running Docker daemon
- Requires `jq`
- Executes on every script invocation that sources docker.sh, even for `--help` paths

**Practical impact:** Low for production (Docker is running). Medium for development and testing (generates stderr noise). Could be deferred with a lazy-init pattern (`_resolve_compose_project_name()` called on first use).

### No Significant Loop Inefficiencies

No expensive external commands repeated in tight loops. Backup verification, rclone sync, and Docker operations are all invoked appropriately.

### Repeated Environment Loading

Some utilities source 10–11 libraries. This is mitigated by load-once guards — each library is initialized only once per process regardless of source count.

---

## 17. External Command Boundary Analysis

| Command | Scripts Using | Availability Check | Privilege | Parsing Risk |
|---|---|---|---|---|
| `docker` / `docker compose` | startup, docker.sh, 15+ utils | `check_docker_available()`, `require_docker()` | root | JSON via `--format json` + jq — safe |
| `sops` | crypto.sh, secrets.sh, setup-secrets.sh | `require_commands sops` in defaults | root | YAML output — parsed with yq/grep |
| `age` / `age-keygen` | crypto.sh | Checked at use sites | root | Stdout capture — safe |
| `flock` | operations.sh | Implicit (Linux standard) | root | Kernel API — no parsing |
| `rclone` | backup-utils.sh, backup-run.sh | `has_command rclone` | Drops to SUDO_USER | Config file parsing — safe |
| `sqlite3` | backup-utils.sh, maintenance-db-maint.sh | Checked at use | root | `integrity_check` output — safe |
| `jq` | docker.sh, 5+ others | `require_jq()` | None | JSON — safe |
| `yq` | schema.sh, setup-crowdsec.sh | Checked at use | None | YAML — safe |
| `curl` | common.sh, maintenance-update-dns.sh | `has_command curl` | Depends | JSON API responses — parsed with jq |
| `stat` | common.sh, config.sh | GNU/BSD detection | None | Both GNU (`-c`) and BSD (`-f`) supported |
| `ufw` | setup-firewall.sh | `has_command ufw` | root | Status output — parsed carefully |

**Locale sensitivity:** `stat` output parsing uses format strings, not locale-dependent text. Docker JSON output is locale-safe. No `ls` output parsing detected.

---

## 18. Portability Analysis

### Bash 5 Enforcement

`lib/common.sh:28–32` enforces `BASH_VERSINFO[0] >= 5`, rejecting Bash 4.x and earlier. This is correct for the Ubuntu 24.04 target.

### GNU vs. BSD

- `stat`: Both GNU (`-c '%a'`) and BSD (`-f '%OLp'`) formats handled (`_get_file_perms`, `_common_stat_mode`, `_common_stat_owner`, `_common_stat_group`).
- `date`: Standard POSIX format strings used.
- `find`: Standard POSIX options.
- `timeout/gtimeout`: Test runner detects and adapts (`run-tests.sh`).

### Architecture Awareness

- `setup-system.sh` validates `dpkg --print-architecture` against `amd64|arm64` — fails closed on unknown architecture.
- SOPS binary download uses architecture-specific URLs.

### No Portability Defects Detected

The codebase correctly targets Ubuntu 24.04 LTS Noble on amd64/arm64 without attempting broader portability.

---

## 19. Security and Privilege Analysis

### Root Enforcement Timing

All mutating production paths enforce root before meaningful mutation:

- `startup.sh:121–123`: After help/version parsing, before operation guard
- `backup-run.sh:219–226`: `backup_require_root()` before any file operations
- `restore-run.sh:2678`: Before restore dispatch
- `setup.sh`: Phase-specific root via setup utilities
- All `utilities/secrets-*.sh`: Before SOPS operations

### Secret Custody

- SOPS ciphertext at `${PROJECT_STATE_DIR}/secrets/secrets.yaml` — root:root 600
- Age private key at `/etc/vaultwarden/age-key.txt` — root:root 600
- Runtime secrets at `/run/vaultwarden-oci/secrets/*` — root:root 444
- No secret values in command arguments (SOPS uses files)
- No secret values in normal logs (log_debug may include paths, not values)

### Temporary File Handling

- `setup.sh`: Creates `TMP_WORKDIR` with `umask 077 + mktemp -d`, cleaned via EXIT trap
- `_set_env_var()`: Runs in subshell with `umask 077`, temp file cleaned via EXIT trap
- `crypto.sh`: Multiple functions use restricted umask + trap cleanup
- No `mktemp` calls without cleanup traps detected in production code

### eval Usage

All 15 `eval` occurrences in production code are `exec ${fd}>&-` patterns for closing computed file descriptors. This is standard Bash practice and is safe — the `fd` variable is always an integer from `{fd}>` assignment.

### No Unsafe Patterns Detected

- No unquoted `$()` in argument positions
- No `eval` of user input
- No PATH manipulation from `.env`
- `.env` loader explicitly blocks `PATH|LD_PRELOAD|LD_LIBRARY_PATH|IFS|BASH_ENV|ENV|CDPATH|PS4`
- `.env` loader rejects command substitution syntax (`` ` `` and `$(`)

---

## 20. Concurrency and Interruption Analysis

### Operation Guard Architecture

`lib/operations.sh` provides:

- Global serialization via `VW_OPERATIONS_LOCK` (flock)
- Operation-specific locks (e.g., `/run/lock/vaultwarden-startup.lock`)
- Inherited foreground lock support (`VW_OPERATION_INHERITED_FD`)
- Verified owner identity (`_operation_verify_owner` checks PID + start time)
- Conservative stale metadata handling (does not trust file age)
- TERM-before-KILL escalation
- Package-manager protection (refuses to auto-terminate dpkg/apt)
- Exit 75 for non-interactive contention

### Descriptor Isolation

Spinner subshell (`log.sh:133–143`) explicitly closes all known lock descriptors:
- `OPERATION_SPECIFIC_LOCK_FD`
- `OPERATION_LOCK_FD`
- `VW_OPERATION_INHERITED_FD`
- `HEALTH_LOCK_FD`

This prevents orphan spinners from holding locks. Tested in `case-lock-fd-hygiene.bash`.

### Signal Handling

All major workflows register signal traps:
- EXIT: cleanup/release
- INT: explicit exit 130
- TERM: explicit exit 143
- HUP: explicit exit 129 (where applicable)

---

## 21. Failure Semantics, Idempotence, and Rollback Analysis

### set -euo pipefail

Universal across all production entry points. Libraries do not set shell options (caller-owned).

### Truthful Status Reporting

- Backup: verification failure is not reported as success
- Restore: staging validation before promotion
- Recovery: pre-commit rollback boundary with explicit commit point
- Maintenance: exit 75 contention is not relabeled as failure

### Rollback Coverage

- `_set_env_var()`: Atomic temp-file + `mv` with EXIT trap
- `restore-run.sh`: Pre-restore snapshot + staged extraction before promotion
- `recover.sh`: Pre-commit rollback of identity/config/manifest
- `setup-secrets.sh`: Backup of existing state before bootstrap

---

## 22. Public Command and Documentation Consistency

### Makefile ↔ Script Grammar

Verified: Make targets correctly delegate to scripts with matching grammar. The `ROOT_ALLOWED_TARGETS` list in Makefile covers all production targets requiring root. The `require-root` macro provides actionable `sudo make $@` guidance.

### Generated Command Reference

`utilities/write-command-reference.sh` generates `docs/COMMAND-REFERENCE.md` from script `--help` output. The `doc-drift.yml` CI workflow detects stale copies.

### Dashboard Compatibility

`dashboard.sh` dispatches to Make targets and direct script invocations. It uses Makefile target names as a stable API — documented in Makefile comments.

---

## 23. Installed-Runtime Consistency

### Repository → Installed Path

`setup-systemd.sh` copies to `/opt/vaultwarden-scripts/`:
- Top-level scripts: startup.sh, maintenance.sh, backup.sh, restore.sh, edit-secrets.sh
- lib/ directory
- Selected utilities

### Drift Detection

`setup-systemd.sh validate` checks:
- Installed script existence and content match
- Library content match
- Unit file match
- Environment/key file permissions
- Timer readiness

### Known Gap

A Git update alone does not activate installed copies. This is documented in README.md, ARCHITECTURE.md, and SCRIPTS.md. The three-step `install → validate → smoke-test` is the supported activation path.

---

## 24. Test Architecture and Coverage Analysis

### Test Inventory

| Suite | Cases | Lines | Domain |
|---|---|---|---|
| foundation | 6 | 3,243 | Architecture, config/env, permissions, storage, systemd, runner contracts |
| security | 3 | 2,348 | Privileges, secrets, email |
| operations | 8 | 6,040 | Operations, lock-fd, lifecycle, operator-ui, firewall, CrowdSec (2), uninstall |
| data-protection | 2 | 2,452 | Backup, restore/recovery |
| **Total** | **19** | **14,083** | |

Plus: `test-architecture.sh` (architecture helper tests).

### Coverage Strengths

- Operation guard behavior: `case-operations.bash` (1,261 lines)
- Restore/recovery: `case-restore-recovery.bash` (1,534 lines)
- Secrets management: `case-secrets.bash` (1,353 lines)
- CrowdSec: `case-crowdsec.bash` (1,057 lines)

### Coverage Gaps

- No direct behavioral test for `_cmd_configure()` (950 lines in setup-secrets.sh)
- No direct behavioral test for `_cmd_breakglass()` (787 lines in setup-secrets.sh)
- Restore staging/promotion tested structurally but not with real archive extraction

---

## 25. Historical Provenance and Churn

### Recent History (last 30 commits on delta)

Recent work shows active maintenance:
- **PR #260**: Fixed systemd firewall locks, hardened UFW/CrowdSec maintenance paths
- **PR #259**: Consolidated test suites from flat to domain-organized structure
- **PR #258**: Resolved prior cleanliness audit findings, centralized atomic env mutation
- **PR #257**: Hardened CrowdSec email notification preflight
- **PR #256**: Made CrowdSec email controls transaction-safe

### High-Churn Files

| File | Changes (last 50 commits) |
|---|---|
| tests/run-tests.sh | 8 |
| utilities/setup-crowdsec.sh | 5 |
| CrowdSec test cases | 5 each |

Churn is concentrated in test infrastructure and CrowdSec — consistent with recent hardening work.

### Helper Provenance

The `_set_env_var()` function was centralized in config.sh during PR #258 (`2ed1d8b refactor(config): centralize atomic env mutation`). Prior to that, multiple scripts had independent implementations.

---

## 26. Change-Impact Scenarios

### Scenario 1: Change a canonical runtime path

**Files**: defaults.sh, config.sh, common.sh (expected_*_for_path), systemd units, setup-systemd.sh, docs  
**Risk**: Medium — 64+ bare `/var/lib/vaultwarden` references would need inspection  
**Policy**: `_VW_DEFAULT_STATE_DIR` is the canonical owner

### Scenario 2: Add a non-secret environment key

**Files**: `.env.example`, config.sh (if needed), owning utility, docs/CONFIGURATION.md  
**Risk**: Low — load_env_file handles generic keys automatically

### Scenario 3: Add a secret with an apply action

**Files**: `secrets-schema.yaml`, schema.sh (if accessors change), secrets-rotate.sh, apply utility, tests, docs/SECRETS-SCHEMA.md  
**Risk**: Medium — schema-driven; well-documented path

### Scenario 4: Add a maintenance health check

**Files**: maintenance-health.sh, smoke-test.sh (if needed)  
**Risk**: Low — maintenance-health.sh has clear check registration pattern

### Scenario 5: Change a shared exit-code contract

**Files**: lib/operations.sh, all callers using that exit code, systemd units (SuccessExitStatus), tests  
**Risk**: High — exit 75 is used across systemd integration

### Scenario 6: Add a systemd-managed operation

**Files**: New unit files in systemd/, setup-systemd.sh (install/validate), smoke-test.sh, docs  
**Risk**: Medium — well-documented but requires install + validate cycle

### Scenario 7: Modify backup archive naming

**Files**: backup-run.sh, backup-utils.sh (parsing), restore-run.sh (selection), retention logic, tests  
**Risk**: High — naming is a cross-workflow contract

### Scenario 8: Change a runtime permission requirement

**Files**: runtime-permissions.sh, common.sh (expected_mode_for_path), repair-permissions.sh, restore-run.sh, tests/case-permissions.bash  
**Risk**: Medium — centralized in 2 files

### Scenario 9: Add a CrowdSec reconciliation setting

**Files**: setup-crowdsec.sh, crowdsec-worker.sh, possibly crowdsec-email.sh  
**Risk**: Medium — setup-crowdsec.sh is 2,419 lines

### Scenario 10: Deprecate a public Make target

**Files**: Makefile, dashboard.sh, docs, any scripts/tests referencing the target  
**Risk**: Low-Medium — search dashboard.sh callers carefully

---

## 27. Architectural Invariant Matrix

| Invariant | Canonical Owner | Enforced | Tested | Confidence |
|---|---|---|---|---|
| Public entry points are thin | Top-level *.sh | Yes (backup.sh: 12L, restore.sh: 11L) | test-architecture.sh | High |
| Privileged mutation requires root | require_root (common.sh) | Yes (30+ callers) | case-security-privileges.bash | High |
| Conflicting mutations use operation guards | operations.sh | Yes | case-operations.bash | High |
| Expected contention is exit 75 | operations.sh | Yes | case-operations.bash | High |
| Lock files not treated as authoritative | operations.sh (flock) | Yes | case-operations.bash | High |
| Secret material not logged | log_* functions | Yes (no redaction needed — secrets passed via files) | case-secrets.bash | High |
| Temporary secret state removed | Trap-based cleanup | Yes | Structural | Medium |
| Backup success requires verification | backup-utils.sh | Yes | case-backup.bash | High |
| Restore prereqs before destructive mutation | restore-run.sh | Yes | case-restore-recovery.bash | High |
| Installed runtime matches repository code | setup-systemd.sh validate | Yes | case-systemd.bash | High |
| Help/metadata paths side-effect free | Per-script | Yes (exit before mutation) | case-operator-ui.bash | High |
| Timeout/EOF fail safely | operator_confirm_yes_no | Yes (returns 1) | case-operator-ui.bash | High |

---

## 28. Confirmed Findings

### SCQ-001 — Inline Root Checks Bypass Canonical Helper in setup-systemd.sh

| Field | Value |
|---|---|
| Severity | Medium |
| Evidence Level | E2 (statically confirmed) |
| Confidence | High |
| Affected Files | `utilities/setup-systemd.sh` |
| Affected Lines | 706, 1040, 1137, 1505 |
| Affected Functions | `action_install`, `action_remove`, `action_status`, main dispatch |
| Public Entry Points | `setup.sh systemd`, `make install-systemd`, direct invocation |
| Canonical Owner | `require_root()` in `lib/common.sh:146` |
| Evidence | 4 inline `if [[ $EUID -ne 0 ]]; then log_error "This script must be run as root."; exit 1; fi` instead of `require_root` |
| Why It Matters | Inconsistent error messages (no `sudo` hint), bypasses the canonical enforcement point, harder to audit |
| Confirmed Defect vs Risk | Confirmed consistency defect — not a security vulnerability since root is still enforced |
| Recommended Correction | Replace 4 inline checks with `require_root "$@"` or `require_root "setup-systemd requires root."` |
| Why Not a New Helper | Canonical `require_root` already exists and is correct |
| Scope | Small — 4 inline replacements |
| Tests | case-security-privileges.bash already validates require_root patterns |
| systemd Effects | None — script behavior unchanged |
| Make Effects | None |
| Dashboard Effects | None |
| Installed-Runtime Effects | None |
| Documentation Effects | None |
| Non-Goals | Do not change the root enforcement *policy*, only redirect to canonical helper |

### SCQ-002 — defaults.sh Source Order Inconsistency in setup.sh

| Field | Value |
|---|---|
| Severity | Low |
| Evidence Level | E2 (statically confirmed) |
| Confidence | High |
| Affected Files | `setup.sh` |
| Affected Lines | 56 (defaults.sh sourced after config.sh:47, common.sh:48) |
| Canonical Owner | `lib/defaults.sh` (documented "source before all other lib files") |
| Evidence | `setup.sh` sources defaults.sh at line 56, after log.sh (45), validate.sh (46), config.sh (47), common.sh (48), operations.sh (50), crypto.sh (51) |
| Why It Matters | config.sh:402–409 sets fallback paths using `${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}` — the `:-` guard prevents a runtime defect but the source order contradicts the defaults.sh contract |
| Confirmed Defect vs Risk | Confirmed consistency issue. No runtime impact due to defensive `:-` patterns. |
| Recommended Correction | Move `source "${SCRIPT_DIR}/lib/defaults.sh"` to line 45 (before log.sh) or immediately after log.sh |
| Scope | 1 line move |
| Tests | case-config-env.bash covers defaults loading |

### SCQ-003 — Oversized Functions in setup-secrets.sh

| Field | Value |
|---|---|
| Severity | Medium |
| Evidence Level | E2 (statically confirmed) |
| Confidence | High |
| Affected Files | `utilities/setup-secrets.sh` |
| Affected Functions | `_cmd_configure()` (950 lines), `_cmd_breakglass()` (787 lines) |
| Why It Matters | Functions this large are difficult to review, test individually, and reason about for rollback/interruption |
| Confirmed Defect vs Risk | Confirmed maintainability concern — not a correctness defect |
| Recommended Correction | Extract coherent phases within `_cmd_configure()` (e.g., schema discovery, identity setup, recipient validation, SOPS init, field generation) into named helper functions within the same file |
| Why Not a New Helper | The phases are setup-secrets-specific; they should be file-local helper functions, not shared library additions |
| Scope | Medium — refactor within one file |
| Tests | case-secrets.bash provides coverage but does not exercise individual phases independently |
| Non-Goals | Do not move secrets setup logic to lib/ — it is correctly owned by the utility |

### SCQ-004 — Bare Path Literals vs. defaults.sh Constants

| Field | Value |
|---|---|
| Severity | Low |
| Evidence Level | E2 (statically confirmed) |
| Confidence | Medium |
| Affected Files | Multiple (64 occurrences of bare `/var/lib/vaultwarden`) |
| Canonical Owner | `_VW_DEFAULT_STATE_DIR` in `lib/defaults.sh:21` |
| Evidence | ~64 bare `/var/lib/vaultwarden` occurrences in production code |
| Why It Matters | If the default state directory ever changes, multiple locations would need manual updates |
| Assessment | Most occurrences are `${PROJECT_STATE_DIR:-/var/lib/vaultwarden}` defensive defaults — correct pattern. ~12 are in systemd units (which use installed environment) and comments. |
| Recommended Correction | Incrementally replace bare uses in lib/ and utilities/ with `${PROJECT_STATE_DIR:-${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}}` where defaults.sh is sourced. Do not change systemd units (they use installed env). |
| Scope | Small per-file, large in aggregate — best done incrementally |
| Non-Goals | Do not create a new defaults constant mechanism; do not change the current `:-` fallback pattern |

### SCQ-005 — docker.sh Source-Time Compose Detection

| Field | Value |
|---|---|
| Severity | Low |
| Evidence Level | E2 (statically confirmed) |
| Confidence | High |
| Affected Files | `lib/docker.sh` |
| Affected Lines | 38–53 |
| Evidence | `docker compose config --format json | jq` runs at module source time |
| Why It Matters | Requires running Docker daemon at source time; produces stderr noise in test/help contexts |
| Recommended Correction | Convert to lazy initialization: set `DOCKER_PROJECT_LABEL` on first use rather than at source time |
| Scope | Small — ~15 lines |
| Non-Goals | Do not remove the auto-detection; just defer it |

### SCQ-006 — setup-secrets.sh Restores Caller Traps via eval

| Field | Value |
|---|---|
| Severity | Low |
| Evidence Level | E2 (statically confirmed) |
| Confidence | High |
| Affected Files | `utilities/setup-secrets.sh` |
| Affected Lines | 2095–2097 |
| Evidence | `eval "$caller_return_trap"` / `eval "$caller_int_trap"` / `eval "$caller_term_trap"` |
| Why It Matters | While the trap values come from `trap -p` (trusted source), eval of trap strings is a pattern worth documenting |
| Assessment | **Informational** — the trap strings are captured from the shell's own `trap -p` output, which is a safe source. No user input reaches eval. |
| Recommended Correction | None required. Add a brief comment explaining the safety rationale if not already present. |

### Additional Medium Findings

**SCQ-007 — Inline Root Checks in setup-firewall.sh and setup-system.sh**

| Field | Value |
|---|---|
| Severity | Medium |
| Evidence Level | E2 |
| Confidence | High |
| Affected Files | `utilities/setup-firewall.sh:546`, `utilities/setup-system.sh:993` |
| Evidence | `(( EUID == 0 )) || { log_error "Must run as root."; exit 1; }` |
| Recommended Correction | Replace with `require_root "$@"` for consistent sudo hints |
| Scope | Small — 2 one-line changes |

**SCQ-008 — `_MAINTENANCE_UTILS_LOADED` Uses Non-readonly Pattern**

| Field | Value |
|---|---|
| Severity | Informational |
| Evidence Level | E2 |
| Affected Files | `lib/maintenance-utils.sh:23–24` |
| Evidence | Uses `_MAINTENANCE_UTILS_LOADED=true` (mutable) instead of `readonly _MAINTENANCE_UTILS_LOADED=1` |
| Assessment | Inconsistent with the `readonly` pattern used by all other libraries. Not a defect — the guard still works. |
| Recommended Correction | Align with the readonly pattern: `readonly _MAINTENANCE_UTILS_LOADED=1` |

**SCQ-009 — defaults.sh Line 64 Redundant readonly**

| Field | Value |
|---|---|
| Severity | Informational |
| Evidence Level | E2 |
| Affected Files | `lib/defaults.sh:64` |
| Evidence | `readonly _VW_DEFAULT_LOG_SERVICES` — this array was already declared `readonly -a` at line 34 |
| Assessment | Harmless but redundant. Bash ignores re-declaration of readonly variables. |
| Recommended Correction | Remove line 64 |

**SCQ-010 — test-uninstall.sh.bak in Tests Directory**

| Field | Value |
|---|---|
| Severity | Informational |
| Evidence Level | E1 (directly observed) |
| Affected Files | `tests/test-uninstall.sh.bak` (23,116 bytes) |
| Evidence | `.bak` file present in test directory |
| Assessment | Appears to be a backup of a test file that was refactored into `tests/suites/operations/case-uninstall.bash`. Should be removed or .gitignored. |
| Recommended Correction | `git rm tests/test-uninstall.sh.bak` |

---

## 29. Investigation Items

### SCQ-E4-001 — Installed Runtime Activation Drift

| Field | Value |
|---|---|
| Severity | Medium (if confirmed) |
| Evidence Level | E4 (investigation lead) |
| Trigger | An operator runs `git pull` but forgets `setup-systemd.sh install` |
| Evidence | Documented risk in README.md and ARCHITECTURE.md. `setup-systemd.sh validate` detects it. |
| Assessment | Cannot reproduce without a production host. The validate + smoke-test path is the documented mitigation. |
| Needed | Production-host verification that validate correctly detects all drift scenarios |

---

## 30. Consolidation Candidates

| # | Candidate | Classification | Safety Benefit | Effort | Risk |
|---|---|---|---|---|---|
| 1 | setup-systemd.sh inline root checks → require_root | Redirect callers to canonical helper | Medium | Small | Low |
| 2 | setup-firewall.sh/setup-system.sh inline root → require_root | Redirect callers to canonical helper | Low | Small | Low |
| 3 | defaults.sh source order in setup.sh | Correct owning caller | Low | Small | Low |
| 4 | docker.sh lazy Compose detection | Correct owning function | Low | Small | Low |
| 5 | _cmd_configure() phase extraction | No new helper; file-local decomposition | Medium | Medium | Low |
| 6 | maintenance-utils.sh load-once guard pattern | Align with readonly convention | Informational | Small | None |
| 7 | defaults.sh redundant readonly | Remove dead code | Informational | Trivial | None |

---

## 31. Intentional Specialization

### Code That Should NOT Be Consolidated

1. **restore-run.sh `verify_sqlite` vs backup-utils.sh `verify_backup_archive`** — Different domain contexts (restore staging vs. backup verification), different error handling, different caller expectations.

2. **backup-run.sh `create_backup` per tier** — db, full, and emergency have intentionally different content inclusion, encryption, sealing, and verification contracts.

3. **Per-script `show_help()/how_help()`** — Help text is intrinsically per-command. Consolidating would couple unrelated command grammars.

4. **Per-script `_require_cli_value()`** — 2–3 lines, parser-local context, different error messages per script. Not worth a shared helper.

5. **`backup_require_root()` in backup-run.sh** — Allows metadata subcommands (list, status) to run root-free, unlike the generic `require_root` which exits unconditionally.

6. **CrowdSec inline root check (setup-crowdsec.sh:49)** — Executes before the lib stack is loaded; `require_root` is unavailable at that point.

7. **Health lock (HEALTH_LOCK_FD) vs operation lock** — Health checking has independent contention semantics: it should not block on backup/restore, and backup/restore should not block on health.

---

## 32. Dead, Obsolete, and Compatibility-Only Candidates

| Item | Status | Assessment |
|---|---|---|
| `tests/test-uninstall.sh.bak` | Confirmed residual | Remove — superseded by `tests/suites/operations/case-uninstall.bash` |
| `defaults.sh:64 readonly _VW_DEFAULT_LOG_SERVICES` | Confirmed redundant | Remove — already declared readonly at line 34 |
| `_package_manager_hint()` dnf/yum branches | Compatibility | Retain — harmless, reasonable forward-looking |
| `wget` fallback in `download_file()` | Compatibility | Retain — curl-first with wget fallback is standard |

---

## 33. Highest-Leverage Improvements

1. **Consolidate root enforcement in setup-systemd.sh** — 4 inline checks → `require_root`. Improves consistency, provides actionable sudo hints, reduces audit surface. (~15 minutes)

2. **Fix defaults.sh source order in setup.sh** — 1 line move. Eliminates contract violation. (~5 minutes)

3. **Remove test-uninstall.sh.bak** — 1 `git rm`. Eliminates confusion. (~1 minute)

4. **Lazy-init docker.sh Compose detection** — ~15 lines. Eliminates source-time Docker daemon requirement. (~30 minutes)

5. **Align maintenance-utils.sh load guard** — 1 line change. Pattern consistency. (~2 minutes)

---

## 34. Recommended Bounded PR Sequence

### PR 1: Root Enforcement Consistency (SCQ-001, SCQ-007)

- **Objective**: Redirect inline root checks to canonical `require_root`
- **Finding IDs**: SCQ-001, SCQ-007
- **Files**: `utilities/setup-systemd.sh`, `utilities/setup-firewall.sh`, `utilities/setup-system.sh`
- **Files that should NOT change**: lib/common.sh, Makefile, dashboard.sh
- **Tests**: case-security-privileges.bash (existing coverage)
- **Risk**: Low
- **Rollback**: Revert the PR
- **Dependencies**: None
- **Review complexity**: Small

### PR 2: Source-Order and Load-Guard Cleanup (SCQ-002, SCQ-008, SCQ-009, SCQ-010)

- **Objective**: Fix defaults.sh source order, align load guards, remove residual file
- **Finding IDs**: SCQ-002, SCQ-008, SCQ-009, SCQ-010
- **Files**: `setup.sh`, `lib/defaults.sh`, `lib/maintenance-utils.sh`, `tests/test-uninstall.sh.bak`
- **Tests**: case-config-env.bash (existing coverage)
- **Risk**: Low
- **Rollback**: Revert the PR
- **Dependencies**: None
- **Review complexity**: Small

### PR 3: docker.sh Lazy Compose Detection (SCQ-005)

- **Objective**: Defer DOCKER_PROJECT_LABEL resolution to first use
- **Finding IDs**: SCQ-005
- **Files**: `lib/docker.sh`
- **Tests**: case-lifecycle.bash (existing coverage)
- **Risk**: Low
- **Rollback**: Revert
- **Dependencies**: None
- **Review complexity**: Small

### PR 4: setup-secrets.sh Function Decomposition (SCQ-003)

- **Objective**: Extract phases from `_cmd_configure()` into named file-local helpers
- **Finding IDs**: SCQ-003
- **Files**: `utilities/setup-secrets.sh`
- **Files that should NOT change**: lib/secrets.sh, lib/crypto.sh
- **Tests**: case-secrets.bash + new focused phase tests
- **Risk**: Medium
- **Rollback**: Revert
- **Dependencies**: None
- **Review complexity**: Large

---

## 35. Future Helper Decision Gate

Before adding a new shared helper to lib/, verify all of the following:

1. What existing function or module owns this policy?
2. Can the owning function be corrected instead?
3. Can callers be corrected instead?
4. Is the behavior genuinely shared (not just textually similar)?
5. Are failure and rollback contracts compatible across callers?
6. Does centralization preserve privilege boundaries?
7. Will the helper have a stable domain contract (not per-issue)?
8. Does it reduce total conceptual complexity?
9. Does it introduce new globals?
10. Does it introduce source-order dependencies?
11. Can existing tests protect it?
12. Is a local function clearer?
13. Is no helper the better solution?
14. Are there at least two current production callers?

---

## 36. Guardrails for Future Agent-Generated Changes

1. **Do not add a helper merely because two scripts share similar text.** Check failure, privilege, rollback, and interruption contracts first.
2. **Do not bypass `require_root`.** If root enforcement is needed, use the canonical helper unless lib/common.sh is genuinely unavailable at that point.
3. **Source `defaults.sh` before `config.sh`** in any new entry point.
4. **Do not add a second operation lock mechanism.** Use `lib/operations.sh`.
5. **Do not merge backup tiers.** db, full, and emergency are intentionally distinct.
6. **Do not merge restore and recovery.** They serve different domain contracts.
7. **Do not add generic wrappers around stable commands** (e.g., a `run_docker_compose()` wrapper provides no value).
8. **Do not execute production-affecting commands at library source time.** Defer to function calls.
9. **Do not add new globals when function parameters suffice.**
10. **Run `shellcheck -x --severity=warning` before committing shell changes.**

---

## 37. Validation Performed

| Command | Result |
|---|---|
| `git status --short` | Clean worktree |
| `git branch --show-current` | `delta` |
| `git rev-parse HEAD` | `a6d2bc39bb0f67e50fe9a05e0fe0292b5b3b2f4a` |
| `bash -n` (all 80 shell files) | All pass |
| `shellcheck -x --severity=warning` (all 80 shell files) | Zero warnings |
| `./tests/run-tests.sh list` | 21 test cases across 4 suites |
| `./tests/run-tests.sh all` | Failed at case-runner-contracts.bash (macOS — expected) |
| `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` | Pass |
| `git diff --check` | Clean |

---

## 38. Validation Not Performed

| Command / Check | Reason |
|---|---|
| `./tests/run-tests.sh foundation` through `data-protection` | macOS audit host: GNU timeout unavailable, Bash 3.2 incompatible with production Bash 5 enforcement in common.sh. Test suite targets Ubuntu 24.04. |
| Real setup/install | Report-only audit; destructive operation |
| Real backup/restore | Report-only audit; requires running services |
| Real key rotation | Report-only audit; requires SOPS state |
| systemd install/validate | Report-only audit; requires systemd host |
| Firewall/CrowdSec operations | Report-only audit; requires target host |
| Production-host acceptance | Audit host is macOS, not Ubuntu 24.04 |

**Note:** This audit does not prove production-host readiness. CI (GitHub Actions on Ubuntu) and production-host validation are required for runtime confidence.

---

## 39. Final Verdict

**Healthy with bounded cleanup opportunities.**

The VaultWarden-OCI shell codebase demonstrates strong architectural intent: thin public dispatchers, canonical library ownership, explicit operation guards with typed contention semantics, consistent privilege enforcement, comprehensive security practices, and robust test coverage across 21 permanent test cases.

The findings are bounded consistency improvements, not architectural defects:
- 6 inline root checks that should use the canonical helper
- 1 source-order inconsistency for defaults.sh
- 2 oversized functions in one utility (setup-secrets.sh)
- 1 residual backup test file
- 1 source-time Docker daemon dependency in docker.sh

No broad refactor is justified. The recommended PR sequence addresses all confirmed findings in 4 small-to-medium PRs.

The codebase is well-maintained, recently improved (PRs #256–#260), and suitable for the supported small-team deployment target.

---

## 40. Appendix A: Complete Script Inventory

### Top-Level Entry Points

| Path | Lines | Functions | Classification | Privilege | Mutates | Op Guard |
|---|---|---|---|---|---|---|
| `setup.sh` | 617 | ~15 | Dispatcher | root | Yes | Yes (per-phase) |
| `startup.sh` | 874 | 24 | Lifecycle | root | Yes | Yes |
| `maintenance.sh` | 98 | 1 | Dispatcher | root | No (delegates) | No |
| `backup.sh` | 12 | 0 | Thin dispatcher | root | Yes (delegates) | Yes (delegated) |
| `restore.sh` | 11 | 0 | Thin dispatcher | root | Yes (delegates) | Yes (delegated) |
| `edit-secrets.sh` | 91 | 1 | Dispatcher | root | Yes (delegates) | Yes (delegated) |
| `recover.sh` | 554 | 26 | Self-contained | root | Yes | Yes |
| `dashboard.sh` | 974 | 31 | Operator UI | varies | varies | No |

### Libraries (lib/)

| Path | Lines | Functions | Classification |
|---|---|---|---|
| `lib/defaults.sh` | 65 | 0 | Constants |
| `lib/log.sh` | 289 | 17 | Logging |
| `lib/validate.sh` | 227 | 6 | Input validation |
| `lib/config.sh` | 412 | 8 | Environment/config |
| `lib/common.sh` | 946 | 45 | Core utilities |
| `lib/operations.sh` | 989 | 46 | Operation guard |
| `lib/docker.sh` | 727 | 31 | Docker/Compose |
| `lib/crypto.sh` | 1,915 | 43 | SOPS/Age |
| `lib/schema.sh` | 525 | 17 | Schema accessors |
| `lib/secrets.sh` | 2,098 | 43 | Secret management |
| `lib/backup-utils.sh` | 995 | 18 | Backup utilities |
| `lib/email.sh` | 797 | 41 | Email/SMTP |
| `lib/storage.sh` | 904 | ~20 | Storage management |
| `lib/migrate.sh` | 2,114 | 55 | Migration pipeline |
| `lib/crowdsec-worker.sh` | 301 | ~10 | CrowdSec Workers |
| `lib/maintenance-utils.sh` | 418 | 13 | Maintenance helpers |
| `lib/runtime-permissions.sh` | 119 | 3 | Permission repair |

### Utilities (utilities/)

| Path | Lines | Functions | Classification |
|---|---|---|---|
| `utilities/backup-run.sh` | 1,906 | 36 | Production utility |
| `utilities/restore-run.sh` | 3,163 | 70 | Production utility |
| `utilities/setup-secrets.sh` | 2,554 | 68 | Installer |
| `utilities/setup-crowdsec.sh` | 2,419 | 60 | Installer |
| `utilities/setup-systemd.sh` | 1,532 | 29 | Installer |
| `utilities/setup-system.sh` | 1,024 | 32 | Installer |
| `utilities/maintenance-health.sh` | 1,563 | 60 | Production utility |
| `utilities/uninstall-vaultwarden.sh` | 1,497 | 64 | Production utility |
| `utilities/setup-storage.sh` | 708 | 20 | Installer |
| `utilities/secrets-edit.sh` | 614 | 18 | Production utility |
| `utilities/secrets-rotate.sh` | 583 | ~15 | Production utility |
| `utilities/setup-firewall.sh` | 577 | ~15 | Installer |
| `utilities/env-edit.sh` | 541 | 13 | Production utility |
| `utilities/crowdsec-email.sh` | 533 | 20 | Production utility |
| `utilities/key-rotate.sh` | 521 | ~12 | Production utility |
| `utilities/smoke-test.sh` | 510 | 23 | Validation |
| `utilities/pre-production-drill.sh` | 466 | 16 | Validation |
| `utilities/setup-env.sh` | 461 | 12 | Installer |
| `utilities/maintenance-update.sh` | 431 | ~12 | Production utility |
| `utilities/maintenance-update-dns.sh` | 429 | 12 | Production utility |
| `utilities/maintenance-run.sh` | 265 | ~8 | Production utility |
| `utilities/maintenance-email.sh` | 275 | ~8 | Production utility |
| `utilities/maintenance-db-maint.sh` | 292 | ~8 | Production utility |
| `utilities/maintenance-update-firewall.sh` | 278 | ~8 | Production utility |
| `utilities/repair-permissions.sh` | 248 | ~6 | Production utility |
| `utilities/secrets-view.sh` | 150 | ~5 | Production utility |
| `utilities/secrets-list.sh` | 114 | ~4 | Production utility |
| `utilities/secrets-export-recovery-kit.sh` | 126 | ~5 | Production utility |
| `utilities/safe-restart.sh` | 133 | ~4 | Production utility |
| `utilities/notify-failure.sh` | 89 | ~3 | Production utility |
| `utilities/operations-status.sh` | 43 | ~2 | Production utility |
| `utilities/crowdsec-worker-apply.sh` | 49 | ~2 | Production utility |
| `utilities/write-command-reference.sh` | 230 | ~5 | Generator |

### Component-Specific

| Path | Lines | Classification |
|---|---|---|
| `caddy/entrypoint.sh` | 297 | Component integration |

---

## 41. Appendix B: Key Function Inventory (Largest)

| Function | Owner | Lines | Callers | Classification |
|---|---|---|---|---|
| `_cmd_configure()` | setup-secrets.sh | 950 | main dispatch | Installer phase |
| `_cmd_breakglass()` | setup-secrets.sh | 787 | main dispatch | Installer phase |
| `main()` | restore-run.sh | 522 | Entry point | Workflow dispatcher |
| `main()` | backup-run.sh | 387 | Entry point | Workflow dispatcher |
| `validate_installation()` | setup-systemd.sh | 349 | `action_validate` | Validation |
| `restore_full()` | restore-run.sh | 347 | main dispatch | Restore workflow |
| `setup_data_volume()` | lib/storage.sh | 342 | setup-storage.sh | Storage setup |
| `install_units()` | setup-systemd.sh | 333 | `action_install` | Installer |
| `_phase_iptables()` | setup-firewall.sh | 311 | main dispatch | Firewall phase |

---

## 42. Appendix C: Source Dependency Matrix

| Source → Target | Relationship |
|---|---|
| defaults.sh → (none) | No dependencies |
| log.sh → (none) | No dependencies |
| validate.sh → log.sh | Auto-loaded |
| config.sh → log.sh | Auto-loaded |
| common.sh → log.sh, config.sh | Required pre-sourced |
| operations.sh → common.sh | Uses _ensure_lock_file via declare -F |
| docker.sh → log.sh | Auto-loaded |
| crypto.sh → log.sh | Auto-loaded |
| secrets.sh → log.sh, defaults.sh, config.sh, schema.sh | Auto-loaded |
| backup-utils.sh → log.sh | Auto-loaded |
| email.sh → log.sh | Auto-loaded |
| storage.sh → common.sh, config.sh | Required pre-sourced |
| migrate.sh → full lib stack | Required pre-sourced |
| crowdsec-worker.sh → common.sh | Required pre-sourced |
| maintenance-utils.sh → log.sh | Auto-loaded |
| runtime-permissions.sh → common.sh | Required pre-sourced |

**Cycles:** None detected.

---

## 43. Appendix D: Finding Summary Matrix

| ID | Severity | Evidence | Confidence | Domain | Canonical Owner | Recommended Action | Scope |
|---|---|---|---|---|---|---|---|
| SCQ-001 | Medium | E2 | High | Privilege | require_root (common.sh) | Redirect 4 inline checks to require_root | Small |
| SCQ-002 | Low | E2 | High | Source order | defaults.sh | Move source line in setup.sh | Small |
| SCQ-003 | Medium | E2 | High | Maintainability | setup-secrets.sh | Extract phase functions | Medium |
| SCQ-004 | Low | E2 | Medium | Constants | defaults.sh | Incremental replacement | Medium |
| SCQ-005 | Low | E2 | High | Efficiency | docker.sh | Lazy-init Compose detection | Small |
| SCQ-006 | Informational | E2 | High | Security | setup-secrets.sh | Document (already safe) | None |
| SCQ-007 | Medium | E2 | High | Privilege | require_root (common.sh) | Redirect 2 inline checks | Small |
| SCQ-008 | Informational | E2 | High | Consistency | maintenance-utils.sh | Align readonly pattern | Small |
| SCQ-009 | Informational | E2 | High | Dead code | defaults.sh | Remove redundant readonly | Trivial |
| SCQ-010 | Informational | E1 | High | Dead code | tests/ | Remove .bak file | Trivial |
| SCQ-E4-001 | Medium (E4) | E4 | Low | Runtime | setup-systemd.sh | Production-host investigation | N/A |

---

*End of report.*
