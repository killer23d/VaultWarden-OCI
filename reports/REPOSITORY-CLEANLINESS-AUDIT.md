# Repository Cleanliness and Maintainability Audit

## 1. Audit Metadata

| Field | Value |
|---|---|
| Repository | `killer23d/VaultWarden-OCI` |
| Audited branch | `delta` |
| Audited SHA | `7f744f8c95036bd2085225c64c2f60ec3ba6a508` |
| Audited commit | `Merge pull request #256 from agent/simple-crowdsec-email-controls` |
| Audit date | 2026-07-15 |
| Model | Claude Opus 4.6 (Thinking) via Google Antigravity |
| Skill | `vaultwarden-repository-cleanliness-audit` v2.0.0 |
| Initial worktree | Clean (`git status --short` empty) |
| Final worktree | Clean except for this report |
| Report scope | Complete repository — all 149 tracked files |
| Refactoring performed | **None** — this is a report-only audit |

## 2. Executive Summary

### Overall assessment

VaultWarden-OCI is a **well-structured, security-conscious repository** with a mature Bash library architecture, comprehensive operation-guard serialization, strong test coverage, and clean static analysis results. The codebase demonstrates clear ownership boundaries across its major subsystems, consistent coding conventions, and production-aware safety patterns.

### Strongest qualities

1. **Operation-guard architecture** — every mutating entry point acquires the shared kernel-flock guard with consistent trap cleanup, identity-verified termination, and exit-75 contention semantics that align with systemd `SuccessExitStatus`.
2. **Clean static analysis** — zero ShellCheck warnings at `--severity=warning` across all `.sh` and `.bash` files; zero `bash -n` syntax errors.
3. **Comprehensive test suite** — 18 registered test cases totaling ~12,000 lines, organized into 4 logical suites, with inventory validation preventing unlisted test drift.
4. **Library load-once discipline** — every `lib/*.sh` file uses a `*_LOADED` guard variable and `return 0` pattern, preventing double-load hazards.
5. **Atomic file operations** — `.env` and configuration mutations throughout use temp-file + `mv` with `chmod --reference` / `chown --reference` for metadata preservation.
6. **CI doc-drift checking** — the single GitHub Actions workflow validates Makefile target references, stale terms, script flags, pinned versions, systemd hardening, and generated command-reference freshness.
7. **Docker Compose config validity** — `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` passes clean.

### Most consequential risks

1. **`.env` mutation duplication** — five separate `_set_env_var`-family implementations with subtly different escaping, error handling, and feature sets (DRY_RUN, key escaping, file targeting). Policy drift between these implementations is the highest-leverage maintainability risk.
2. **Large file cognitive load** — `restore-run.sh` (3163 lines), `setup-secrets.sh` (2568 lines), and `setup-crowdsec.sh` (2280 lines) each serve a coherent subsystem but are dense enough that individual reviewers must hold significant context.

### Broad refactoring advisory

**Broad refactoring is not advisable.** The repository is well-organized and follows its documented small-team model consistently. Targeted, narrow improvements to the `.env` mutation pattern and a few opportunistic cleanups would yield the highest return with the lowest regression risk.

### Findings by severity

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 6 |

### Recommendations by disposition

| Disposition | Count |
|---|---|
| Keep as-is | 4 |
| Opportunistic cleanup | 2 |
| Focused cleanup PR | 1 |
| Design proposal first | 1 |
| Targeted refactor | 0 |
| Immediate corrective action | 0 |

### Immediate actions

**None required.** No critical or high-severity findings were identified. No demonstrated production correctness, security, or data-protection issues were found.

### Conclusion

The repository is in strong condition for its documented operating model. The most impactful improvement would be consolidating the `.env` mutation pattern into a narrow, well-tested shared helper to prevent future policy drift across the five current implementations.

## 3. Repository Operating Boundary

The repository documents a **single-host, small-team (~10 users), root-operated** production model targeting:

- Ubuntu 24.04 LTS Noble on amd64/arm64
- Docker Engine with Docker Compose plugin
- Cloudflare DNS, proxy, and WAF
- Caddy (Cloudflare TLS module)
- Vaultwarden container
- Postfix sidecar for outbound mail
- CrowdSec with Cloudflare edge enforcement
- SOPS + Age encrypted secrets
- rclone offsite backup support
- systemd automation for recurring jobs

All cleanliness assessments in this report are judged against this boundary. Enterprise-scale abstractions, multi-node HA, or platform-agnostic layers are explicitly out of scope and not recommended.

## 4. Methodology and Limitations

### Inventory methods

- `git ls-files` manifest (149 tracked files)
- Directory tree traversal for classification
- `wc -l` for file size metrics
- `grep -rn` for cross-reference, call-graph, and pattern analysis

### Static analysis

- `bash -n` syntax validation on all `.sh` files: **all pass**
- `shellcheck -x --severity=warning` on all `.sh` and `.bash` files: **all pass, zero warnings**
- `docker compose config --quiet` with `.env.example`: **pass**
- `git diff --check`: **clean**

### Safe tests run

- Static analysis and syntax checks only (see §18 Validation Record)

### Areas not executed

- `./tests/run-tests.sh all` — not run because test cases invoke production library functions that rely on Linux-specific filesystem paths (`/proc`, `/run/lock`, systemd units) not available on the macOS audit host. Tests were inspected statically.
- No live Docker, Caddy, CrowdSec, Postfix, or Vaultwarden services were tested
- No network-connected operations (DNS, API, rclone) were executed
- No privilege-escalated or host-mutating commands were run

### Uncertainty and dynamic-use limitations

- Some functions may be called dynamically via `declare -F` checks or Make variable expansion; static grep cannot prove non-use conclusively
- Installed-runtime paths under `/opt/vaultwarden-scripts/` were not inspected on a live host

## 5. Repository Map

| Area | Responsibility | Main Entry Points | Shared Dependencies | Relevant Tests | Notes |
|---|---|---|---|---|---|
| Root scripts | Operator entry points | `setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `recover.sh`, `maintenance.sh`, `edit-secrets.sh`, `dashboard.sh` | `lib/*` | All suites | Thin dispatchers (backup, restore, maintenance) or direct entry points |
| `lib/` | Reusable libraries (15 files) | Sourced by entry points | `log.sh` → `config.sh` → `common.sh` → domain libs | All suites | Clear load-once guards |
| `utilities/` | Implementation scripts (28 files) | Called by root dispatchers, Makefile, systemd | `lib/*` | All suites | Feature-owned |
| `tests/` | Test suites + runner | `run-tests.sh` | Fixture mode, production libs | Self-referential | 18 cases, inventory-validated |
| `systemd/` | Unit files (15) | Installed by `setup-systemd.sh` | N/A | `case-systemd.bash` | Template paths `@PROJECT_ROOT@` |
| `.github/workflows/` | CI (1 workflow) | PR trigger | N/A | N/A | Doc-drift, ShellCheck, functional tests |
| `caddy/` | Reverse proxy config | `Caddyfile`, `Dockerfile`, `entrypoint.sh` | N/A | N/A | Cloudflare TLS module build |
| `crowdsec/` | CrowdSec configuration | Templates + examples | N/A | `case-crowdsec*.bash` | YAML templates |
| `docs/` | Operator documentation (20 files) | N/A | N/A | Doc-drift workflow | Generated `COMMAND-REFERENCE.md` |
| `reports/` | Historical audit reports | N/A | N/A | N/A | Read-only evidence |
| `Makefile` | Operator CLI surface (989 lines) | Make targets | Scripts | N/A | Root-policy guard |

## 6. Cleanliness Scorecard

| Dimension | Rating | Evidence |
|---|---|---|
| Repository structure | **Strong** | Clear directory ownership; root dispatchers, `lib/` for reuse, `utilities/` for implementation, `tests/` for suites, `systemd/` for units |
| Responsibility separation | **Very good** | Each library has a focused header comment; entry points source specific libs; no circular dependencies observed |
| Shell consistency | **Strong** | Zero ShellCheck warnings; consistent `set -euo pipefail`; `#!/usr/bin/env bash`; Bash 5 enforcement in `common.sh` and test runner |
| Shared-helper ownership | **Good** | `lib/common.sh` owns privilege, lifecycle, cleanup; `lib/config.sh` owns env loading; `lib/operations.sh` owns lock serialization; minor duplication exists (CLN-001) |
| Configuration handling | **Good** | Canonical `load_env_file` with injection guards, permission checks, and `printf -v` (not `eval`); secondary parsers exist in `recover.sh` and `dashboard.sh` with justified reasons |
| Locking and concurrency | **Strong** | Comprehensive `operation_acquire/release` pattern; kernel `flock` authority; identity-verified termination; `exit 75` for contention; lock-FD hygiene tests |
| Transaction safety | **Very good** | Backup metadata cohort, restore staging/promotion, key rotation staging; temp-file + `mv` atomic pattern throughout |
| Process lifecycle | **Very good** | PID identity tracking; descendant capture; TERM-before-KILL; package-manager protection; descriptor closure before validators |
| Test architecture | **Strong** | 18 registered cases; inventory validation; 4 logical suites; fixture cleanup with traps; timeout enforcement; runner contract tests |
| Documentation consistency | **Very good** | CI-enforced Makefile target existence; stale-term detection; generated command-reference drift check; comprehensive docs/ |
| Generated-artifact hygiene | **Very good** | `write-command-reference.sh` generates `COMMAND-REFERENCE.md`; CI verifies freshness |
| Dead-code hygiene | **Very good** | No conclusively dead scripts or functions identified; compatibility aliases (`start`, `stop`, `health-email`) are documented |
| Security-boundary maintainability | **Strong** | `.env` injection guards; `PATH`/`LD_PRELOAD` refusal; umask-protected temp files; secret cleanup; `SOPS_AGE_KEY_FILE` unset after use; permission repair |
| CI coverage | **Good** | Doc-drift, ShellCheck, 4-suite functional tests with matrix; missing: no compose-config validation in CI |
| Commit and change discipline | **Very good** | Clean `.gitignore`; comprehensive secrets exclusion; no committed `.env` or keys |

## 7. Key Strengths

1. **Fail-closed confirmation** — `operator_confirm_yes_no` requires explicit `yes`/`no`; timeout and EOF both fail closed.
2. **Operation guard coherence** — all 14+ mutating entry points acquire the shared guard; systemd `SuccessExitStatus=0 75` treats expected contention as clean.
3. **Lock FD isolation** — dedicated test (`case-lock-fd-hygiene.bash`) verifies guard FDs are not inherited by descendant processes.
4. **Injection-resistant `.env` loading** — `load_env_file` uses `printf -v` assignment (not `eval`), rejects `$(` and backtick command substitution, and refuses to overwrite `PATH`, `LD_PRELOAD`, `IFS`, and other dangerous variables.
5. **Deterministic test inventory** — `run-tests.sh` validates that every `case-*.bash` file on disk is registered and vice versa; prevents unlisted test drift.
6. **Generated document verification** — CI regenerates `COMMAND-REFERENCE.md` and diffs against the committed version; stale docs fail the build.
7. **Atomic file operations** — consistent temp-file + `mv` with `chmod --reference` and `chown --reference` across configuration mutations.
8. **Test-mode hooks** — `VW_TEST_MODE`, `VAULTWARDEN_TEST_ALLOW_NON_ROOT` enable test coverage of root-guarded paths without actual privilege; hooks are narrowly scoped.
9. **Truthful success reporting** — backup verification failures are not presented as successful backups; restore preflight checks prevent post-destruction discovery of missing prerequisites.
10. **Pinned dependency CI** — workflow verifies no unintended `@latest` or `/releases/latest` usage; pinned SHA-256 checksums for `yq` and `sops` in CI.

## 8. Findings Summary

| ID | Title | Severity | Confidence | Disposition | Affected Area | PR Size |
|---|---|---|---|---|---|---|
| CLN-001 | `.env` mutation pattern duplicated across five implementations | Medium | High | Design proposal first | `lib/config.sh`, `lib/migrate.sh`, `utilities/setup-crowdsec.sh`, `utilities/setup-secrets.sh`, `utilities/crowdsec-email.sh`, `recover.sh` | M |
| CLN-002 | Docker Compose config validation missing from CI | Medium | High | Focused cleanup PR | `.github/workflows/doc-drift.yml` | XS |
| CLN-003 | `require_root` redefined locally in `crowdsec-email.sh` | Low | High | Opportunistic cleanup | `utilities/crowdsec-email.sh` | XS |
| CLN-004 | `defaults.sh` sourced after `storage.sh` in `setup.sh` | Low | Medium | Opportunistic cleanup | `setup.sh` | XS |
| CLN-005 | `Makefile` status target parses `.env` inline instead of using library | Low | Medium | Keep as-is | `Makefile` | N/A |
| CLN-006 | Large file hotspots — inherent complexity | Informational | High | Keep as-is | `restore-run.sh`, `setup-secrets.sh`, `setup-crowdsec.sh`, `migrate.sh` | N/A |
| CLN-007 | `recover.sh` standalone env helpers | Informational | High | Keep as-is | `recover.sh` | N/A |
| CLN-008 | Dashboard avoids full env loading | Informational | High | Keep as-is | `dashboard.sh` | N/A |
| CLN-009 | Comprehensive operation-guard and lock architecture | Informational | High | Strength | `lib/operations.sh` | N/A |
| CLN-010 | Clean static analysis across entire codebase | Informational | High | Strength | All `.sh` and `.bash` files | N/A |
| CLN-011 | Test suite architecture with inventory validation | Informational | High | Strength | `tests/run-tests.sh`, `tests/case-*.bash` | N/A |

## 9. Detailed Findings

### CLN-001 — `.env` mutation pattern duplicated across five implementations

**Severity:** Medium
**Confidence:** High
**Category:** Duplication and policy-drift risk
**Disposition:** Design proposal first

**Affected files/functions:**
- `lib/config.sh:302` — `_set_env_var()` (canonical, exported)
- `lib/migrate.sh:648` — `_mv_set_env_var()` (adds DRY_RUN support)
- `utilities/setup-crowdsec.sh:106` — `_cs_set_env_var()` (RETURN trap cleanup, no key escaping)
- `utilities/setup-secrets.sh:2035` — `_ss_set_env_var_in_file()` (parameterized file target, key escaping, error returns)
- `utilities/crowdsec-email.sh:106` — `write_flag()` (awk-based, different grammar entirely)
- `recover.sh:94` — `atomic_set_env()` (awk-based, chown --reference)

**Current behavior:**
Each implementation writes or updates a `KEY=VALUE` line in an `.env`-format file using temp-file + `mv`. They share the same core algorithm but differ in:
- Whether the key is regex-escaped for `sed` (only `_set_env_var` and `_ss_set_env_var_in_file`)
- Whether `DRY_RUN` is checked (only `_mv_set_env_var`)
- Whether the file target is hardcoded or parameterized
- Error-handling granularity (some return 1, some silently continue)
- Cleanup approach (RETURN trap vs. no explicit cleanup on `sed` failure)
- Grammar (`sed` vs. `awk` for the core operation)

**Evidence:**
- `_set_env_var` (canonical): uses `sed`, RETURN trap for temp cleanup, `chmod --reference` but not `chown --reference`
- `_mv_set_env_var`: identical `sed` logic but adds DRY_RUN guard and uses `chmod 0600` (not `--reference`)
- `_cs_set_env_var`: identical `sed` logic but no `escaped_key`, adds RETURN trap
- `_ss_set_env_var_in_file`: identical `sed` logic with explicit error returns `{ rm -f; return 1; }`
- `write_flag`: entirely different awk-based approach; single hardcoded key; includes `chown --reference`
- `atomic_set_env` (recover.sh): awk-based; includes `chown --reference`; standalone DR context

**Counter-evidence considered:**
- `recover.sh` is intentionally standalone for disaster recovery and should not source `lib/config.sh`
- `write_flag` in `crowdsec-email.sh` operates on a single known key with awk, which may be simpler for its use case
- The `_mv_set_env_var` DRY_RUN feature is migration-specific and not needed elsewhere
- `_ss_set_env_var_in_file` targets an arbitrary file, which `_set_env_var` does not currently support

**Why it matters:**
If a quoting, escaping, or permission-preservation bug is fixed in one implementation, the other four must be independently audited and patched. The `chown --reference` inconsistency is a concrete example: `_set_env_var` preserves mode but not ownership; `write_flag` and `atomic_set_env` preserve both.

**Current operational risk:** Low — all implementations produce correct output for typical `.env` values.
**Future maintenance risk:** Medium — the next `.env` escaping fix or permission-preservation change must be applied to 5 implementations independently.

**Recommended action:**
Design a narrow shared helper in `lib/config.sh` that accepts a file target, supports DRY_RUN awareness, preserves both `chmod --reference` and `chown --reference`, and handles error returns. Migrate the `sed`-based implementations first; leave `recover.sh` standalone.

**Recommended non-action:**
Do not create a generic transaction framework. Do not force `recover.sh` to source `lib/config.sh` — it is intentionally standalone for disaster recovery. Do not consolidate `write_flag` if the awk grammar is intentionally different.

**Suggested implementation boundary:**
One PR for the shared helper + tests; separate follow-up PRs per caller migration.

**Tests required:** Unit tests for the shared helper covering key creation, update, escaping, DRY_RUN, permission/ownership preservation, and error paths.
**Estimated PR size:** M (shared helper + 3-4 caller migrations)
**Dependencies:** None

---

### CLN-002 — Docker Compose config validation missing from CI

**Severity:** Medium
**Confidence:** High
**Category:** CI coverage gap
**Disposition:** Focused cleanup PR

**Affected files/functions:**
- `.github/workflows/doc-drift.yml`

**Current behavior:**
The CI workflow validates documentation drift, ShellCheck, and functional tests, but does not validate that `docker-compose.yml.example` with `.env.example` produces a valid Compose configuration. This validation passes locally (`docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` succeeds), but a PR could introduce a Compose syntax error without CI catching it.

**Evidence:**
- The workflow file contains no `docker compose config` step
- The validation passes locally on the audited commit

**Counter-evidence considered:**
- Docker Compose may not be trivially available in the CI runner without additional setup
- The example files change infrequently

**Why it matters:**
A broken Compose template would not be caught until an operator attempts first-time setup. Given the single-operator target audience, this could be a significant onboarding barrier.

**Current operational risk:** Low — the template validates clean today.
**Future maintenance risk:** Medium — Compose syntax changes or variable additions could silently break the template.

**Recommended action:** Add a `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` step to the CI workflow.

**Recommended non-action:** Do not add full container-spin-up integration tests to CI.

**Suggested implementation boundary:** One XS PR adding a single CI step.
**Tests required:** The CI step itself is the test.
**Estimated PR size:** XS
**Dependencies:** Docker must be available in the CI runner (Ubuntu latest has Docker pre-installed).

---

### CLN-003 — `require_root` redefined locally in `crowdsec-email.sh`

**Severity:** Low
**Confidence:** High
**Category:** Duplication
**Disposition:** Opportunistic cleanup

**Affected files/functions:**
- `utilities/crowdsec-email.sh:44` — local `require_root()` function

**Current behavior:**
`crowdsec-email.sh` defines its own `require_root()` that checks `$EUID -ne 0` with a `VAULTWARDEN_TEST_ALLOW_NON_ROOT` bypass. This shadows the canonical `require_root()` from `lib/common.sh` which uses `is_root()` and outputs via `log_error`/`log_hint`. The local version uses a local `error()` function and returns 1 instead of exiting.

**Evidence:**
- `crowdsec-email.sh:44` — `if [[ "$EUID" -ne 0 && "${VAULTWARDEN_TEST_ALLOW_NON_ROOT:-0}" != "1" ]]; then`
- `lib/common.sh:146` — `require_root() { if ! is_root; then ... exit 1; fi }`

**Counter-evidence considered:**
- `crowdsec-email.sh` intentionally does not source `lib/common.sh` — it only sources `lib/log.sh`, `lib/config.sh`, and `lib/operations.sh`
- The return-vs-exit difference is intentional: the script dispatches by subcommand and `require_root` is called per-subcommand

**Why it matters:** Minor — the behavioral difference (return vs exit) is justified. The duplication is small.

**Current operational risk:** None.
**Future maintenance risk:** Low — if the test-bypass convention changes, this copy must be updated independently.

**Recommended action:** When next modifying `crowdsec-email.sh`, consider sourcing `lib/common.sh` and adapting the call pattern.

**Recommended non-action:** Do not refactor merely to eliminate a 5-line function.

**Suggested implementation boundary:** Opportunistic, next time the file is modified.
**Tests required:** Existing test coverage (`case-crowdsec-notifications.bash`) is sufficient.
**Estimated PR size:** XS
**Dependencies:** None

---

### CLN-004 — `defaults.sh` sourced after `storage.sh` in `setup.sh`

**Severity:** Low
**Confidence:** Medium
**Category:** Source-order consistency
**Disposition:** Opportunistic cleanup

**Affected files/functions:**
- `setup.sh:56-57` — `source "${SCRIPT_DIR}/lib/storage.sh"` then `source "${SCRIPT_DIR}/lib/defaults.sh"`

**Current behavior:**
`setup.sh` sources `lib/storage.sh` at line 56 before `lib/defaults.sh` at line 57. However, `storage.sh` internally sources `defaults.sh` via its own load guard (`[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] || source "${_VW_STORAGE_LIB_DIR}/defaults.sh"`), so defaults are available when needed. The explicit source at line 57 is redundant but harmless.

**Evidence:**
- `setup.sh:56`: `source "${SCRIPT_DIR}/lib/storage.sh"`
- `setup.sh:57`: `source "${SCRIPT_DIR}/lib/defaults.sh"`
- `lib/storage.sh:30`: `[[ -n "${VAULTWARDEN_DEFAULTS_LOADED:-}" ]] || source "${_VW_STORAGE_LIB_DIR}/defaults.sh"`

**Counter-evidence considered:**
- The load-once guard makes the order operationally irrelevant
- The explicit source in `setup.sh` serves as documentation of the dependency

**Why it matters:** Negligible — no runtime impact due to load guards.

**Current operational risk:** None.
**Future maintenance risk:** None.

**Recommended action:** When next modifying `setup.sh`, move `source defaults.sh` before `source storage.sh` for clarity.

**Recommended non-action:** Do not create a PR solely for this change.

**Suggested implementation boundary:** Piggyback on the next `setup.sh` change.
**Tests required:** None — load-once guard makes this safe.
**Estimated PR size:** XS
**Dependencies:** None

---

### CLN-005 — `Makefile` status target parses `.env` inline

**Severity:** Low
**Confidence:** Medium
**Category:** Consistency
**Disposition:** Keep as-is

**Affected files/functions:**
- `Makefile:345-376` — inline `grep '^PROJECT_STATE_DIR=' .env` parsing

**Current behavior:**
The `status` Make target reads `PROJECT_STATE_DIR` and `BACKUP_DIR` from `.env` using inline `grep | cut` rather than sourcing through `lib/config.sh`. This is a simpler parser than the canonical `load_env_file`.

**Counter-evidence considered:**
- Make targets cannot easily source Bash libraries
- The values read are non-sensitive path defaults
- The Make config block at line 31-33 uses the same pattern consistently
- Refactoring Make to use a Bash helper would add complexity

**Why it matters:** The inline parser does not handle quoted values or malformed lines the same way as `load_env_file`. However, `PROJECT_STATE_DIR` and `BACKUP_DIR` are always simple paths without quotes in practice.

**Current operational risk:** None.
**Future maintenance risk:** Low.

**Recommended action:** Keep as-is.

**Recommended non-action:** Do not add a shell wrapper merely to share the parser.

---

## 10. Duplication and Policy-Drift Map

| Behavior | Implementations | Semantic Differences | Drift Risk | Consolidation Recommendation | Preferred Owner | Worthwhile? |
|---|---|---|---|---|---|---|
| `.env` KEY=VALUE write/update | `_set_env_var` (config.sh), `_mv_set_env_var` (migrate.sh), `_cs_set_env_var` (setup-crowdsec.sh), `_ss_set_env_var_in_file` (setup-secrets.sh), `write_flag` (crowdsec-email.sh), `atomic_set_env` (recover.sh) | DRY_RUN support, file target parameterization, key escaping, error handling, awk vs sed grammar, chown --reference | Medium | Design proposal, then consolidate sed-based variants | `lib/config.sh` | Yes for sed-based variants; `recover.sh` and `write_flag` may remain standalone |
| Root privilege check | `require_root` (common.sh), local `require_root` (crowdsec-email.sh) | Exit vs return; test bypass variable name | Low | Opportunistic: source common.sh | `lib/common.sh` | Minor benefit |
| `.env` value reading | `_read_env_value` (config.sh), `read_env_value` (recover.sh), `_read_env_var` (dashboard.sh), inline `grep` (Makefile) | grep+cut vs awk; quote stripping differences | Low | Keep separate: each justified by context | N/A | No |
| File permission stat | `_get_file_perms` (config.sh), `_common_stat_mode` (common.sh) | Identical core logic (stat -c vs stat -f fallback) | Low | Already separate for load-order reasons | `lib/common.sh` | Minor |

## 11. Complexity Hotspots

| File | Lines | Inherent Domain Complexity | Incidental Complexity | Global-State Coupling | Transaction Complexity | Process/Signal Complexity | Test Complexity |
|---|---|---|---|---|---|---|---|
| `utilities/restore-run.sh` | 3163 | **High** — full/db/emergency restore with staging, extraction, decryption, promotion, rollback, and start-policy | Low — coherent phases | Medium — reads env, modifies live state | **High** — multi-artifact staging, commit boundary, rollback | Medium — service stop/start | `case-restore-recovery.bash` (1531 lines) |
| `utilities/setup-secrets.sh` | 2568 | **High** — interactive credential collection, SOPS encryption, recovery kit, SMTP/API token rotation | Low — linear flow | Medium — reads/writes secrets.yaml, .sops.yaml, dr-manifest.env | Medium — staged credential write + policy update | Low | `case-secrets.bash` (1319 lines) |
| `utilities/setup-crowdsec.sh` | 2280 | **High** — CrowdSec install, LAPI config, bouncer enrollment, worker bouncer, version management | Low — subsystem-owned | Medium — writes .env, systemd units, bouncer configs | Medium — LAPI port cohort transaction | Low | `case-crowdsec.bash` (843 lines) |
| `lib/migrate.sh` | 2128 | **High** — volume migration with data copy, verification, fstab, rollback | Low | Medium — reads/writes .env, fstab, mounts | **High** — multi-phase migration with checkpoints | Low | `case-storage-setup.bash` (665 lines) |
| `lib/operations.sh` | 988 | **High** — kernel flock guard, identity verification, descendant management, contention handling | Low — well-structured | Low — self-contained state | Low | **High** — PID tracking, signal forwarding, FD management | `case-operations.bash` (1258 lines), `case-lock-fd-hygiene.bash` (146 lines) |

**Recommendation:** Do not split any of these files. Each contains one coherent subsystem with clear internal phases. Splitting would distribute transaction semantics across files, making review harder.

## 12. Shared-Helper Candidates

### Candidate: `env_set_var` — unified `.env` mutation helper

**Proposed responsibility:** Atomically set or update a `KEY=VALUE` line in any `.env`-format file with consistent escaping, permission/ownership preservation, DRY_RUN awareness, and error returns.

**Current implementations:** 5 (see CLN-001)

**Callers:**
- `setup-env.sh`, `env-edit.sh` via `_set_env_var`
- `lib/migrate.sh` via `_mv_set_env_var`
- `setup-crowdsec.sh` via `_cs_set_env_var`
- `setup-secrets.sh` via `_ss_set_env_var_in_file`

**API sketch:**
```bash
# env_set_var KEY VALUE FILE [--dry-run]
# Returns 0 on success, 1 on failure
# Preserves mode and ownership via chmod/chown --reference
env_set_var() {
    local key="$1" value="$2" file="$3" dry_run="${4:-}"
    ...
}
```

**Semantic differences that must remain:**
- `recover.sh` must stay standalone (DR context, no lib sourcing)
- `write_flag` (awk-based) may remain if its grammar is intentionally different

**Migration sequence:**
1. Add `env_set_var` to `lib/config.sh` with tests
2. Migrate `_cs_set_env_var` callers
3. Migrate `_mv_set_env_var` callers
4. Migrate `_ss_set_env_var_in_file` callers
5. Deprecate old functions

**Reasons to reject the extraction:**
- Adding DRY_RUN awareness to the canonical helper adds conditional logic
- The helper must handle both `chmod --reference` and `chown --reference`
- Scope creep risk: the helper should not grow into a generic config framework

**Final recommendation:** Proceed with design proposal. The 5 implementations and `chown --reference` inconsistency justify consolidation.

## 13. Refactor Risk Matrix

| Proposed Refactor | Benefit | Implementation Risk | Regression Blast Radius | Test Readiness | Operational Urgency | Recommended Timing | Should Not Attempt |
|---|---|---|---|---|---|---|---|
| CLN-001: Unified `env_set_var` | Eliminates 5-way policy drift | Low — narrow helper, clear API | Medium — touches setup, crowdsec, migration, secrets | Good — testable in isolation | Low — no current bug | Phase 2 | — |
| CLN-002: CI Compose validation | Catches template breakage | Very low — one CI step | None | Good — self-validating | Low | Phase 1 | — |
| CLN-003: Remove local `require_root` | Minor consistency | Very low | Very low | Existing tests | None | Opportunistic | — |

## 14. Prioritized Roadmap

### Phase 0 — Demonstrated correctness or security risks

No items. No critical or high-severity findings were identified.

### Phase 1 — Small cleanliness wins

**1. Add Docker Compose config validation to CI (CLN-002)**
- Disposition: Focused cleanup PR
- Affected files: `.github/workflows/doc-drift.yml`
- Expected benefit: Catches Compose template regressions before merge
- Prerequisites: None
- Validation: CI green after PR merge
- Suggested PR boundary: Single CI step addition
- Do not combine with: Any production code changes

### Phase 2 — Targeted refactors

**2. Design and implement unified `env_set_var` helper (CLN-001)**
- Disposition: Design proposal first
- Affected files: `lib/config.sh`, `lib/migrate.sh`, `utilities/setup-crowdsec.sh`, `utilities/setup-secrets.sh`
- Expected benefit: Single-source `.env` mutation with consistent escaping and permission preservation
- Prerequisites: Design proposal with API sketch and caller analysis
- Validation: New unit tests + existing suite green
- Suggested PR boundary: Helper + tests in one PR; caller migration in follow-up PRs
- Do not combine with: Any production behavior change

### Phase 3 — Optional architecture work requiring design discussion

No items identified. The current architecture serves its documented operating model well.

## 15. Proposed Issue Backlog

### Issue 1: Consolidate `.env` mutation pattern

**Title:** Consolidate `_set_env_var` implementations into a shared helper in `lib/config.sh`

**Problem:** Five implementations of atomic `.env` KEY=VALUE write/update exist with inconsistent escaping, error handling, and permission preservation. See CLN-001.

**Evidence:** `lib/config.sh:302`, `lib/migrate.sh:648`, `utilities/setup-crowdsec.sh:106`, `utilities/setup-secrets.sh:2035`, `utilities/crowdsec-email.sh:106`.

**Scope:** Design a shared helper; migrate the four sed-based implementations; leave `recover.sh` standalone.

**Out of scope:** Generic transaction framework; rewriting `recover.sh` to use libs; consolidating `write_flag` if its awk grammar is intentionally different.

**Acceptance criteria:** Single helper in `lib/config.sh` with tests; all sed-based callers migrated; `chown --reference` and `chmod --reference` both applied; DRY_RUN support.

**Risk:** Low — the helper is narrow and well-tested.

**Dependencies:** None.

---

### Issue 2: Add Docker Compose config validation to CI

**Title:** Add `docker compose config --quiet` validation to CI workflow

**Problem:** Docker Compose template validity is not checked in CI. See CLN-002.

**Evidence:** `.github/workflows/doc-drift.yml` contains no Compose validation step.

**Scope:** Add one CI step to validate `docker-compose.yml.example` with `.env.example`.

**Out of scope:** Container spin-up tests; live integration testing.

**Acceptance criteria:** CI fails if the Compose template is syntactically invalid.

**Risk:** Very low.

**Dependencies:** Docker available in CI runner (Ubuntu latest pre-installed).

## 16. Keep-as-is Decisions

### Makefile inline `.env` parsing (CLN-005)

The Makefile reads `PROJECT_STATE_DIR` and `BACKUP_DIR` from `.env` using inline `grep | cut`. This is simpler than the alternative (calling a Bash helper from Make) and the values are always simple paths. The inconsistency with `load_env_file` is accepted because Make cannot easily source Bash libraries, and the operational risk is negligible.

### `recover.sh` standalone helpers (CLN-007)

`recover.sh` defines its own `read_env_value()` and `atomic_set_env()` functions rather than sourcing `lib/config.sh`. This is intentional: `recover.sh` is a disaster-recovery bootstrap script that must work without relying on the library chain that may be damaged or unavailable during recovery. The duplication is justified.

### Dashboard minimal env loading (CLN-008)

`dashboard.sh` uses a lightweight `_read_env_var` function (5 lines of `grep | cut`) rather than `load_env_file`. This is intentional: the dashboard reads only a few display-relevant values (`PROJECT_STATE_DIR`, `BACKUP_DIR`, `TZ`) and avoids the security checks and side effects of full env loading, which could interfere with the interactive menu.

### Large file hotspots (CLN-006)

`restore-run.sh` (3163 lines), `setup-secrets.sh` (2568 lines), `setup-crowdsec.sh` (2280 lines), and `migrate.sh` (2128 lines) are each large but contain one coherent subsystem. Splitting any of them would distribute transaction semantics across files, making review and reasoning about rollback, cleanup, and error handling harder. The existing test coverage for each is substantial.

## 17. Anti-Goals

The following changes are explicitly **not recommended:**

1. **Repository-wide rewrite** — The codebase is well-structured and follows its documented model consistently.
2. **One giant cleanup PR** — Any consolidation work should be done in focused, independently reviewable PRs.
3. **Changing public commands during cleanup** — Make targets, CLI grammar, and operator-facing behavior must not change as part of cleanliness improvements.
4. **Replacing Bash solely for style** — Bash is the documented technology; the codebase demonstrates professional-grade Bash usage.
5. **Creating a generic transaction framework prematurely** — Each subsystem's transaction pattern is coherent and well-tested; a framework would add indirection without clear benefit.
6. **Reorganizing files without behavioral benefit** — The current directory structure is clear and conventional.
7. **Combining correctness changes with broad renaming** — The two identified action items (CLN-001, CLN-002) should be separate PRs.
8. **Deleting compatibility paths without deployment verification** — Aliases like `start`/`stop`/`health-email` may be used by operators or automation.

## 18. Validation Record

### Syntax and static checks

| Command | Result |
|---|---|
| `find . -path './.git' -prune -o -type f -name '*.sh' -print0 \| xargs -0 -n 1 bash -n` | **PASS** — zero errors |
| `find . -path './.git' -prune -o -type f -name '*.sh' -print0 \| xargs -0 shellcheck -x --severity=warning` | **PASS** — zero warnings |
| `find . -path './.git' -prune -o -type f -name '*.bash' -print0 \| xargs -0 shellcheck -x --severity=warning` | **PASS** — zero warnings |
| `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` | **PASS** |
| `git diff --check` | **PASS** — clean |

### Focused safe tests

None run — tests require Linux-specific paths (`/proc`, `/run/lock`) not available on macOS audit host.

### Full safe suites

Not run (see above). Tests were inspected statically for architecture, patterns, and coverage.

### Documentation checks

- Verified `COMMAND-REFERENCE.md` generator exists (`utilities/write-command-reference.sh`)
- Verified CI workflow checks for generated doc freshness
- Verified stale-term detection covers 7 known stale terms
- Verified Makefile target reference check in docs

### Commands intentionally not run

| Command | Reason |
|---|---|
| `./tests/run-tests.sh all` | Requires Linux `/proc`, `/run/lock`, systemd units |
| `sudo make up` / `sudo make health` | Requires live services, Docker daemon, root privilege |
| `sudo make backup` / `sudo make restore` | Destructive production operations |
| `./setup.sh install` | Host-mutating installation |
| Any `sudo`, `apt`, `systemctl` command | Prohibited by audit skill |

## 19. Appendices

### A. Largest files by line count

| Lines | File |
|---|---|
| 3163 | `utilities/restore-run.sh` |
| 2568 | `utilities/setup-secrets.sh` |
| 2281 | `utilities/setup-crowdsec.sh` |
| 2129 | `lib/migrate.sh` |
| 2099 | `lib/secrets.sh` |
| 1915 | `lib/crypto.sh` |
| 1906 | `utilities/backup-run.sh` |
| 1563 | `utilities/maintenance-health.sh` |
| 1532 | `utilities/setup-systemd.sh` |
| 1497 | `utilities/uninstall-vaultwarden.sh` |
| 1024 | `utilities/setup-system.sh` |
| 995 | `lib/backup-utils.sh` |
| 989 | `Makefile` |
| 988 | `lib/operations.sh` |
| 974 | `dashboard.sh` |

### B. Shell entry points

| Script | Type | Root Required | Operation Guard |
|---|---|---|---|
| `setup.sh` | Full installer | Yes (except help/version) | Via `operation_acquire` |
| `startup.sh` | Service lifecycle | Yes (except dry-run/help) | Yes — `startup` specific lock |
| `backup.sh` | Dispatcher → `backup-run.sh` | Yes (for run/verify/rotate) | Yes |
| `restore.sh` | Dispatcher → `restore-run.sh` | Yes | Yes |
| `recover.sh` | DR bootstrap | Yes | No (standalone) |
| `maintenance.sh` | Dispatcher → `maintenance-*.sh` | Yes | Yes (per subcommand) |
| `edit-secrets.sh` | Secrets editor | Yes | No |
| `dashboard.sh` | Interactive TUI | Sudo for commands | Via subcommands |

### C. Sourced-library map

```text
log.sh (standalone, no deps)
├── validate.sh (auto-loads log.sh)
├── defaults.sh (standalone, no deps)
├── config.sh (auto-loads log.sh)
│   └── defaults.sh (via canonical fallbacks)
├── common.sh (requires log.sh)
│   └── defaults.sh (via storage paths)
├── operations.sh (uses log.sh if available)
├── docker.sh (auto-loads log.sh)
├── storage.sh (auto-loads log.sh, defaults.sh)
├── crypto.sh (auto-loads log.sh)
├── schema.sh (auto-loads log.sh)
├── email.sh (auto-loads log.sh)
├── secrets.sh (auto-loads log.sh, defaults.sh; sources crypto.sh, schema.sh, email.sh)
├── backup-utils.sh (auto-loads log.sh)
├── crowdsec-worker.sh (auto-loads log.sh, config.sh, common.sh; sources secrets.sh)
├── runtime-permissions.sh (uses common.sh)
└── maintenance-utils.sh
```

### D. Lock inventory

| Lock | Owner | Type | Entry Points |
|---|---|---|---|
| `/run/lock/vaultwarden-operations.lock` | `lib/operations.sh` | Global flock guard | All mutating operations (14+ scripts) |
| `/run/lock/vaultwarden-startup.lock` | `startup.sh` | Specific flock | `startup.sh` |
| `/run/lock/vaultwarden-backup-*.lock` | `backup-run.sh` | Specific flock | `backup-run.sh` |
| `/run/lock/vaultwarden-health.lock` | `maintenance-health.sh` | Standalone flock | `maintenance-health.sh` |
| Notify lock file | `notify-failure.sh` | Standalone flock (FD 9) | `notify-failure.sh` |

### E. Environment-parser inventory

| Parser | File | Grammar | Use Case |
|---|---|---|---|
| `load_env_file` | `lib/config.sh` | Full: injection guard, malformed-line detection, permission check | Primary production env loading |
| `load_project_environment` | `lib/config.sh` | Orchestrator: tries installed env → persistent env → repo env | Multi-path env resolution |
| `_read_env_value` | `lib/config.sh` | Simple: `grep \| cut \| tr -d` | Single-key read |
| `read_env_value` | `recover.sh` | awk-based, handles quotes | DR standalone |
| `_read_env_var` | `dashboard.sh` | Simple: `grep \| cut \| head` | Dashboard display values |
| Inline `grep` | `Makefile` | `grep \| cut` in shell | Make-time config |

### F. Test-suite inventory

| Suite | Cases | Total Lines | Description |
|---|---|---|---|
| Foundation | 6 cases | ~2,973 | Architecture, config-env, permissions, storage, systemd, runner contracts |
| Security | 3 cases | ~2,307 | Security-privileges, secrets, email |
| Operations | 7 cases | ~4,533 | Operations, lock-FD hygiene, lifecycle, operator-UI, CrowdSec (2), uninstall |
| Data-protection | 2 cases | ~2,446 | Backup, restore-recovery |
| **Total** | **18 cases** | **~11,999** | Runner: `tests/run-tests.sh` (370 lines) |

### G. Report-generation notes

- This report was generated from static analysis and code inspection of the repository at SHA `7f744f8c95036bd2085225c64c2f60ec3ba6a508`
- No production code, tests, workflows, templates, configuration, or existing documentation was modified
- No credentials, tokens, private email addresses, hostnames, secret values, or local absolute paths from the audit environment are exposed in this report
- All file paths are relative to the repository root unless otherwise noted
- Finding counts were verified against the findings summary table and executive summary
