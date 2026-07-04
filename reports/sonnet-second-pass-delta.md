# VaultWarden-OCI Delta Sonnet Second-Pass Review

## Verdict

- **Recommendation: Green**
- **Current production-readiness status:** All eight findings from the first PRR (F-01 through F-08) are confirmed fixed. `docker compose config` validates cleanly. `bash -n` and `shellcheck --severity=warning` are both clean. One new Low finding (S2-01) and one Low finding (S2-02) were identified; neither is blocking.
- **Highest remaining risk:** Postfix `read_only: true` runtime compatibility cannot be proven from static review alone — this is a runtime validation limit, not a confirmed defect. The second-highest concern is the CI path-filter gap for `docker-compose.yml.example` (Low, no functional code defect, simple one-line fix).
- **Is the original PRR now stale after PR #216?** Partially. It accurately describes the pre-remediation state of commit `95e16776` and remains a valid historical record. Its F-01 through F-08 findings have been remediated. A small remediation note is recommended.

---

## Prior Report Baseline

- **Prior report used:** `reports/production-readiness-review-delta.md`
- **Prior commit reviewed:** `95e16776f4597df73f5ea860a44397e433414cbc`
- **Areas already covered:** All primary scripts (`setup.sh`, `startup.sh`, `backup.sh`, `restore.sh`, `maintenance.sh`, `edit-secrets.sh`, `recover.sh`), `docker-compose.yml.example`, `.env.example`, all `lib/*.sh`, key `utilities/` scripts, all `systemd/` units, `tests/` structure, `docs/`, `.github/workflows/doc-drift.yml`
- **Prior commands run:** `git status/log/grep`, `bash -n` (all scripts), `shellcheck -S error` (key scripts), placeholder and dangerous-pattern grep audits
- **Prior commands not run:** `shellcheck --severity=warning` (full), `make test-unit`, `docker compose config`, `sudo` operations, `sops -d` operations
- **Prior environment limitations:** macOS review host; no Docker runtime; no real `.env`, secrets, Age keys, rclone config, or production state; `make test-unit` not runnable (missing `sops`, `age`, `yq`)
- **Areas intentionally not re-audited:** Full re-read of `lib/crypto.sh`, `lib/secrets.sh`, `utilities/restore-run.sh`, `utilities/backup-run.sh`, `caddy/`, `crowdsec/`, documentation drift (already clean in prior report), security model for SOPS/Age/Docker secrets (already strong in prior report)

---

## Scope of This Second Pass

- **Branch reviewed:** `review/sonnet-second-pass-delta`
- **Commit reviewed:** `34008ca1f1030afd35f953c824d8c242a0764bb7` (tip of `delta` post-PR #216)
- **Files inspected:**
  - `systemd/vaultwarden-startup.service` — F-01 verification
  - `lib/common.sh:370-404` — F-02 verification
  - `.env.example` — F-03 verification
  - `docker-compose.yml.example` — F-04, F-05, F-06 verification + compose parse
  - `startup.sh:100-125` — F-07 verification
  - `recover.sh:98-165` — F-08 verification
  - `.github/workflows/doc-drift.yml` — CI path-filter gap check
  - `tests/test-secrets-cli-help.sh` — test failure root-cause analysis
  - `lib/log.sh:45-57` — confirming `declare -gA` usage
- **Why these files were inspected:** Directly targeted at verifying F-01 through F-08 and the specific missed-issue areas called out in the review scope
- **Commands run:**
  ```bash
  git log --oneline -10
  git rev-parse HEAD
  git branch --show-current
  git show --stat 34008ca
  bash -n backup.sh restore.sh startup.sh recover.sh maintenance.sh setup.sh edit-secrets.sh
  find utilities lib -name '*.sh' -print0 | xargs -0 bash -n
  shellcheck -x --severity=warning $(find . -name '*.sh' -not -path './.git/*')
  grep -n 'Restart=' systemd/vaultwarden-startup.service
  git grep -n '0666' -- lib/common.sh
  grep -n '^ADMIN_TOKEN=' .env.example
  grep -n 'read_only:' docker-compose.yml.example
  grep -n 'mem_limit:' docker-compose.yml.example
  grep -n 'subnet:' docker-compose.yml.example
  grep -n 'docker-compose.yml.example' .github/workflows/doc-drift.yml
  docker compose -f docker-compose.yml.example config
  make test-unit
  bash tests/test-secrets-cli-help.sh
  /bin/bash -c 'declare -gA FOO=([DEBUG]=0)'  # macOS Bash 3.2 diagnosis
  ```
- **Commands not run and why:**
  - `sudo` operations — forbidden by review policy
  - `sops -d` — forbidden by review policy; no real secrets present
  - Full Docker container startup — no production state; destructive in a real environment
  - Postfix runtime smoke test — no Docker images pulled; static review confirms structure only

---

## PR #216 Remediation Check

| Finding | Status | Evidence | Notes |
|---|---|---|---|
| F-01 | **Fixed** | `systemd/vaultwarden-startup.service:14-17` | `Restart=on-failure` and `RestartSec=10` removed. Accurate comment added explaining health-timer recovery model. |
| F-02 | **Fixed** | `lib/common.sh:393-396` | `0666` replaced with `chown root:root` + `chmod 0660`. `git grep '0666' lib/common.sh` returns no matches. |
| F-03 | **Fixed** | `.env.example:32-34` | `ADMIN_TOKEN=` is now blank with a two-line comment explaining SOPS/`ADMIN_TOKEN_FILE` model. |
| F-04 | **Fixed (static)** | `docker-compose.yml.example:364-369` | `read_only: true` + tmpfs for `/tmp`, `/var/spool/postfix`, `/var/lib/postfix`, `/run` added to Postfix. `docker compose config` parses without error. Runtime smoke test recommended (see Runtime Validation Limits). |
| F-05 | **Fixed** | `docker-compose.yml.example:430,445,454` | All three subnets changed from `/16` to `/28`. `docker compose config` confirms parsed subnets as `/28`. |
| F-06 | **Fixed** | `docker-compose.yml.example:371-372` | `mem_limit: 256M` and `memswap_limit: 256M` added at top-level service scope for Postfix. Parsed by `docker compose config` as `268435456` bytes (256 MiB). |
| F-07 | **Fixed** | `startup.sh:112` | Guard is now `if [[ "${DRY_RUN}" != "true" \|\| "${DO_DOWN}" == "true" ]]`. `stop --dry-run` now correctly requires root. |
| F-08 | **Fixed** | `recover.sh:129-130` | `realpath -e` applied to both `STATE_DIR` and `KEY_FILE` after validation. `realpath` present in prerequisite list at `recover.sh:139`. |

All eight findings are confirmed fixed with direct file evidence.

---

## What the First Audit May Have Missed

### A. Docker Compose validation — now run

The first PRR explicitly did not run `docker compose config`. This second pass ran it.

**Result:** The compose file parses cleanly. No YAML errors. No Compose structural warnings. The warnings printed to stderr are all "variable is not set. Defaulting to blank" — expected when no `.env` is present on the review host.

Key confirmations from parsed output:

- Postfix `read_only: true` confirmed
- Postfix `mem_limit: 268435456` (256 MiB) confirmed
- Postfix `memswap_limit: 268435456` (256 MiB) confirmed
- All three subnets parsed as `/28` confirmed

### B. `make test-unit` — now run, macOS-only failure found

The first PRR explicitly did not run `make test-unit`. This second pass ran it.

**Result:** `make test-unit` fails on macOS with:

```
FAIL: edit-secrets.sh --help exited non-zero
```

Root cause: `tests/test-secrets-cli-help.sh:36-39` uses `env -i PATH="/usr/bin:/bin"` to create an isolated environment. On macOS, this resolves `bash` to `/bin/bash`, which is Bash 3.2.57. `lib/log.sh:52` uses `declare -gA` (global associative arrays), which requires Bash 4.0+. Bash 3.2 returns `declare: -g: invalid option` causing the script to exit non-zero before producing any output.

**Classification:** macOS-only test isolation issue. On the Ubuntu production target, `/bin/bash` is Bash 5.x, and `declare -gA` works correctly. The CI workflow (`doc-drift.yml`) runs on `ubuntu-latest`, which is unaffected. This is **not a project bug on the Ubuntu target**.

See §New Findings — S2-02.

### C. CI path-filter gap — confirmed

See §CI Path Filter Check.

### D. Postfix `read_only: true` runtime validation — confirmed gap

See §Runtime Validation Limits — RVL-01.

### E. `shellcheck --severity=warning` — now run

The first PRR ran `shellcheck -S error`. This second pass ran `--severity=warning` on all scripts.

**Result:** Clean — zero warnings or errors at warning severity.

---

## Original PRR Staleness Check

`reports/production-readiness-review-delta.md` should remain **unchanged** as a historical snapshot. It accurately describes the state of commit `95e16776` and the findings raised against it. The original "Yellow" recommendation was correct for that commit.

A small remediation note is recommended at the top of the original report to help future readers understand its context:

```markdown
> **Remediation note (added after PR #216):** PR #216 addressed F-01 through F-08 after
> this report was written. This report remains a historical snapshot of commit
> `95e16776f4597df73f5ea860a44397e433414cbc`. See
> `reports/sonnet-second-pass-delta.md` for the post-remediation verdict.
```

This note was **not** applied in this pass. It is a Low-priority suggestion the maintainer can apply manually. The new second-pass report is sufficient to convey the current post-PR #216 state.

---

## CI Path Filter Check

**Finding: S2-01 (Low)**

`.github/workflows/doc-drift.yml:3-14` defines the PR path filter. `docker-compose.yml.example` is not included:

```yaml
on:
  pull_request:
    paths:
      - 'docs/**'
      - 'utilities/**'
      - 'lib/**'
      - '*.sh'
      - 'Makefile'
      - 'systemd/**'
      - 'tests/**'
      - 'secrets-schema.yaml'
      - '.env.example'
      - '.gitignore'
      # docker-compose.yml.example is absent
```

PR #216 changed `docker-compose.yml.example` substantially. CI ran on that PR only because other watched files also changed in the same PR (`lib/common.sh`, `startup.sh`, `recover.sh`, `.env.example`, `systemd/`). A future PR that changes only the Compose file would skip CI entirely.

**Why it matters:** The Compose file controls container capabilities, read-only mounts, memory limits, network subnets, and secrets definitions. These are primary security surfaces. Skipping CI on compose-only changes is a process gap.

**Severity:** Low. No current defect. One-line fix.

#### Suggested remediation snippet

Target:

`.github/workflows/doc-drift.yml`

Suggested change:

```diff
       - '.env.example'
       - '.gitignore'
+      - 'docker-compose.yml.example'
```

#### Validation

```bash
grep 'docker-compose.yml.example' .github/workflows/doc-drift.yml
```

> Note: The existing `doc-drift` checks (stale terms, systemd hardening, shellcheck, `make test-unit`) would run on compose-only PRs after this fix. They do not directly validate Compose structure. A follow-up improvement would add a `docker compose config` step to the workflow.

---

## Runtime Validation Limits

### RVL-01: Postfix `read_only: true` runtime compatibility

**Status:** Cannot be proven from static review alone.

The `boky/postfix` image may need additional writable paths beyond the four tmpfs mounts added in PR #216 (`/tmp`, `/var/spool/postfix`, `/var/lib/postfix`, `/run`). Possible additional paths include `/etc/postfix` if the image rewrites config at startup.

The static fix is correct and consistent with the image documentation. A runtime smoke test is required before declaring this fully validated.

#### Suggested validation snippet

```bash
# Run on the Ubuntu target with a real .env
docker compose -f docker-compose.yml.example up postfix --no-deps -d
sleep 60   # allow start_period (configured as 60s)
docker inspect vaultwarden_postfix --format '{{.State.Health.Status}}'
# Expected: healthy
docker logs vaultwarden_postfix 2>&1 | grep -i 'error\|permission denied\|read.only'
# Expected: no permission-denied or read-only filesystem errors
```

Reason code is not proposed as a fix:

Static review confirms the tmpfs paths are consistent with `boky/postfix` documentation and match the original PRR remediation suggestion. No file evidence indicates additional writable paths are required. Validate on a disposable test environment before drawing further conclusions.

---

### RVL-02: Emergency backup passphrase round-trip

The first PRR noted no direct end-to-end emergency backup passphrase encryption/decryption test in CI. This remains a test coverage gap. No new evidence suggests an actual defect.

**Classification:** Future Test Gap. Not a current defect.

#### Suggested future test pseudocode

```bash
# Requires Docker, sops, age tooling, and a configured .env
make backup tier=emergency
# Retrieve the newest emergency backup from BACKUP_DIR/emergency/
# Decrypt with Age passphrase: age --decrypt -o decrypted.tar.gz emergency-*.tar.gz.age
# Verify archive: tar -tzf decrypted.tar.gz | grep db.sqlite3
```

---

### RVL-03: `make test-unit` on the Ubuntu production target

`make test-unit` fails on macOS due to the Bash 3.2 issue documented in S2-02. The CI workflow (`functional-tests` job) runs `make test-unit` on `ubuntu-latest`, where this passes. This review could not directly confirm CI pass status, but the root cause is macOS-only and the CI environment is unaffected.

---

### RVL-04: Systemd installation and runtime behavior

Systemd unit files were reviewed statically. Installation, timer registration, and runtime behavior require a live Ubuntu+systemd environment. The prior PRR's positive conclusions on timer structure remain current; PR #216 did not touch any `.timer` units.

---

## New Findings

### S2-01: CI path filter missing `docker-compose.yml.example`

Documented in §CI Path Filter Check.

- **Severity:** Low
- **Area:** CI / process
- **Evidence:** `.github/workflows/doc-drift.yml:3-14` — `docker-compose.yml.example` absent from `paths:` filter
- **Why it matters:** Compose-only PRs skip CI. The Compose file controls container security settings.
- **Recommended fix:** Add one line to the path filter (see §CI Path Filter Check for snippet).

---

### S2-02: `test-secrets-cli-help.sh` incompatible with macOS Bash 3.2

- **Severity:** Low (macOS developer ergonomics only; CI is unaffected)
- **Area:** Test tooling
- **Evidence:** `tests/test-secrets-cli-help.sh:36-39` — `env -i PATH="/usr/bin:/bin"` resolves to Bash 3.2 on macOS; `lib/log.sh:52` uses `declare -gA`, which requires Bash 4.0+
- **Why it matters:** `make test-unit` produces a spurious FAIL on macOS, which could mask real failures during local development.
- **Recommended fix:** Low priority. Extend the isolated PATH to include Homebrew bash.

#### Suggested remediation snippet

Target:

`tests/test-secrets-cli-help.sh`

Suggested change:

```diff
-run_clean() {
-    (
-        cd "$RUN_DIR"
-        env -i \
-            PATH="/usr/bin:/bin" \
-            HOME="$TEST_HOME" \
-            bash "$@"
-    ) 2>&1
-}
+run_clean() {
+    (
+        cd "$RUN_DIR"
+        # Extend PATH to include Homebrew bash on macOS (lib/log.sh uses declare -gA,
+        # which requires Bash 4+; macOS /bin/bash is 3.2).
+        env -i \
+            PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
+            HOME="$TEST_HOME" \
+            bash "$@"
+    ) 2>&1
+}
```

#### Validation

```bash
# On macOS with Homebrew bash installed:
bash tests/test-secrets-cli-help.sh
# Expected: "Standalone secrets CLI help tests passed."
```

> CI on Ubuntu is already passing. This is a follow-up improvement, not blocking.

---

## Notes

### N-01: PR #216 diff scope is minimal and correct

`git show --stat 34008ca` confirms PR #216 modified exactly 6 functional files plus the new report. No unintended files were changed. The diff is narrow and consistent with the 8 findings it addressed.

### N-02: `shellcheck-autofix` job scope is correct and unchanged

The `shellcheck-autofix` job (`doc-drift.yml:196-223`) only runs on pushes to `main`. This correctly prevents untrusted PR code from running with `contents: write` permission. PR #216 did not change this job.

### N-03: Original PRR "Yellow" verdict was accurate for `95e16776`

The original PRR's Yellow recommendation was justified by F-02 (lock-file 0666 fallback) and F-04 (Postfix missing hardening). Both are now resolved. Current branch state is Green.

### N-04: Emergency backup encryption safety unchanged

The original PRR noted that emergency backups explicitly reject encrypting solely to the operational recipient (`backup-run.sh:1245-1258`). This logic was not touched by PR #216 and remains correct.

### N-05: Docker Compose warnings are expected in the review environment

`docker compose config` emits "variable is not set. Defaulting to blank" warnings for `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `PUID`, `PGID`, and `DOMAIN`. These are expected — the review environment has no `.env`. In production, all required variables are populated before Compose is invoked. These warnings are not defects.

---

## Final Recommendation

**Delta is production-ready after PR #216.**

All eight PRR findings (F-01 through F-08) are confirmed fixed with direct evidence from the post-remediation code. No Critical, High, or Medium findings were identified in this second pass.

Two new Low findings were raised:
1. **S2-01** — `docker-compose.yml.example` absent from CI path filter. One-line workflow fix. No functional code impact.
2. **S2-02** — macOS Bash 3.2 test isolation issue. Developer ergonomics only; CI is unaffected.

The remaining gaps are **runtime validation recommendations**, not code defects:

- Postfix `read_only: true` runtime compatibility should be verified with a container smoke test on the Ubuntu target before the first production deployment (RVL-01).
- An end-to-end emergency backup passphrase round-trip test remains a future CI coverage improvement (RVL-02).

No functional code was changed in this review pass.

**Recommended pre-production actions (in order of priority):**

1. Run the Postfix runtime smoke test (RVL-01) on a disposable Ubuntu environment.
2. Optionally add `docker-compose.yml.example` to the CI path filter (S2-01, one-line change).
3. Optionally fix the macOS test isolation PATH (S2-02, follow-up improvement).

None of these are blocking for production deployment.
