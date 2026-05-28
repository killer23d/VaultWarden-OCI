I now have a thorough picture of the audit findings and all post-audit commits. Here is the complete agent prompt:

***

Here is the comprehensive agent prompt, incorporating all 32 audit findings from the report and accounting for post-audit commits made on 2026-05-27/28 that already addressed parts of `setup-crowdsec.sh` :

***

## Agent Prompt

```
# Task: Resolve AUDIT-BETA-FINAL-01 Findings & Refresh All Documentation
# Repository: killer23d/VaultWarden-OCI  |  Branch: Beta

---

## Context

The file `AUDIT-BETA-FINAL-01-Findings.md` (audited at commit fc55afc on 2026-05-26)
lists 32 findings across shell safety, systemd hardening, backup/restore integrity,
security, README quality, documentation accuracy, and optimization. Several commits
landed after the audit (commits 9dc0cf9 through ce6ef3f, 2026-05-27 – 2026-05-28)
that refactored `utilities/setup-crowdsec.sh` significantly. You MUST re-inspect every
finding that touches `setup-crowdsec.sh` against the current HEAD before deciding
whether it is resolved or still needs work.

---

## Absolute Requirements

- All changes must be consistent with the existing code style: 4-space indent in shell,
  snake_case function names, `_SCREAMING_SNAKE` for module-level constants, short
  descriptive `log_info`/`log_warn`/`log_error` messages using the existing `lib/`
  logging helpers, and the standard `source`-guard pattern used in every lib file.
- Never break existing interfaces: no renamed public functions, no removed CLI flags,
  no changed exit codes unless the finding explicitly requires it.
- Every changed shell file must pass `bash -n` (syntax check) and `shellcheck -S warning`.
- Documentation updates must be factually derived from the code — never from the old
  documentation. Read the actual script/Makefile target before writing the doc line.

---

## Phase 1 — Re-inspect Post-Audit Changes (Do This First)

Before touching anything, read the current HEAD of the following files and determine
the current status of each finding listed in Phase 2 that references them:

- `utilities/setup-crowdsec.sh`
- `lib/secrets.sh`
- `utilities/secrets-rotate.sh`
- `.env.example`
- `crowdsec/*.yaml.example` (all three)

For each finding below, annotate it as one of:
  [RESOLVED] – post-audit commits fully addressed it
  [PARTIAL]  – post-audit commits partially addressed it; describe what remains
  [OPEN]     – no change; implement the fix as described

---

## Phase 2 — Code Fixes (implement all OPEN and PARTIAL items)

Work through all 32 findings in priority order (Critical → Moderate → Minor).

### CRITICAL

**C-1 · CrowdSec bootstrap: curl|bash + unpinned versions**
File: `utilities/setup-crowdsec.sh`
Post-audit commits refactored credentials and idempotency but did NOT add version
pinning or remove `curl | bash`.  Re-inspect lines ~192, ~127-128, ~279, ~376 at HEAD.
If still present:
- Replace `curl -s ... | bash` with a two-step: download to temp file, verify SHA256
  against a pinned checksum or at minimum verify the script is from the expected
  hostname before executing.
- Set `CROWDSEC_VERSION` and `CF_BOUNCER_VERSION` to the latest stable pinned values
  (look them up from the GitHub releases API or hardcode the current stable versions).
- Replace `/releases/latest` GitHub API calls with `/releases/tags/${VERSION}`.
- Replace `@latest` Go package references with `@v${VERSION}`.
- The SHA256-verified GitHub tarball fallback path already exists — ensure all paths
  are consistent with it.

**C-2 · Remote sidecar upload failure not surfaced as partial-failure**
File: `utilities/backup-run.sh` ~lines 548–586
The `sync_to_rclone` function warns when sidecar uploads fail but then reports
"Offsite sync complete" unconditionally. Fix:
- Introduce a local `_sidecar_fail=0` counter.
- Increment on each failed sidecar upload.
- If `_sidecar_fail > 0` after the loop, return a distinct exit code (e.g. `return 2`)
  and emit `log_warn "Offsite sync completed with partial sidecar failures (${_sidecar_fail} file(s))"`
  instead of the success message.
- The caller in the `run` command path must propagate this as a partial-failure state
  (non-zero exit / warning summary line in the final report).

**C-3 · Full/emergency backup silently includes secrets/**
File: `utilities/backup-run.sh` ~lines 871–886 (`perform_full_backup`)
The tar archive includes the entire project root with no `--exclude` for `secrets/`.
Two sub-options — choose the one that matches documented intent:
  Option A (preferred if secrets SHOULD be excluded): add
    `--exclude="${SCRIPT_DIR#/}/secrets"`
  to the tar invocation and update docs accordingly (secrets are excluded).
  Option B (if secrets SHOULD be included in emergency only): gate the exclude
  on backup type, and fix the documentation to say emergency includes secrets,
  full does not.
Whichever option you choose, make `perform_full_backup` and the emergency path
consistent with each other and with the documentation you will write in Phase 3.

**C-4 · SMTP password exposed in curl process argv**
File: `lib/email.sh` ~line 605
Replace `--user "${SMTP_USERNAME}:${SMTP_PASSWORD}"` with a `--netrc-file` approach:
- Write credentials to a temp file in `/dev/shm` (e.g. `mktemp -p /dev/shm`).
- Set `chmod 600` on it immediately after creation.
- Use `--netrc-file "$tmpfile"` in the curl invocation.
- Trap cleanup in the function's local `trap … RETURN` so the file is always deleted.

---

### MODERATE

**M-5 · Lock paths differ: no single mutex across backup + health + maintenance**
Files: `utilities/maintenance-run.sh`, `maintenance-db-maint.sh`,
       `maintenance-health.sh`, `backup-run.sh`
Define a single shared lock path constant `VAULTWARDEN_OPS_LOCK=/run/lock/vaultwarden-ops.lock`
in `lib/` (suggest `lib/lock.sh` or add to `lib/common.sh`).
Each script should acquire this top-level lock (non-blocking, fail fast) in addition
to its own operation-specific lock. This prevents concurrent backup + health execution.
Follow the existing `exec {FD}>file ; flock -n` pattern precisely.

**M-6 · Lock file root:root 0660 blocks non-root service users**
Files: `utilities/maintenance-health.sh:131`, `backup-run.sh:1114`
Change lock file creation from `install -m 0660 -o root -g root` to
`install -m 0664 -o root -g $(id -gn)` or simply use `touch` + `chmod 664` so
the running service user can acquire it. Alternatively, use `/run/lock/` paths
which do not require pre-creation.

**M-7 · Backup services missing Requires=/Wants= on health unit**
Files: `systemd/vaultwarden-db-backup.service`, `systemd/vaultwarden-full-backup.service`
Add `Wants=vaultwarden-health.service` to both. Add `After=vaultwarden-health.service`
to `full-backup.service` (it already exists on `db-backup`).

**M-8 · Secrets rotation not atomic**
File: `utilities/secrets-rotate.sh` ~lines 288–301
After the per-service restart loop, add a rollback path:
- If any restart fails, iterate the services restarted so far in reverse order,
  restoring the backed-up secrets (the backup already exists per lines 112–125).
- Emit `log_error` with the failed service name and instructions to run
  `secrets-rotate.sh --restore-backup` (add this flag as a thin wrapper around
  the existing backup restore logic).

**M-9 · Cloudflare CIDR cache: no permissions, no TTL, no format validation**
File: `utilities/setup-firewall.sh` ~lines 143–175
- After writing the cache: `chmod 640 "$cf_cidr_cache"`.
- Add a TTL check: if cache mtime > 7 days, treat as stale and re-fetch.
  Use `find "$cf_cidr_cache" -mtime -7` or `stat` to check.
- Before inserting CIDRs into iptables/ufw, validate each line matches
  `^[0-9a-f.:]+/[0-9]+$` (basic CIDR regex). Log and skip invalid lines.

**M-10 · 6 inaccurate Make/script references in OPERATIONS.md**
(Doc-only fix — handled in Phase 3)

**M-11 · 5 wrong Make target descriptions in SCRIPTS.md**
(Doc-only fix — handled in Phase 3)

**M-12 · 4 factual errors in DISASTER-RECOVERY.md**
(Doc-only fix — handled in Phase 3)

**M-13 · README overloaded; no prominent "Start here" link**
File: `README.md`
- Within the first 30 lines, add a callout block:
  ```
  > **New here? Start with [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).**
  ```
- Move the install walkthrough (lines ~20–227), email architecture deep-dive
  (~231–282), script catalog (~285–347), and backup/Makefile reference (~357–395)
  to one-line summaries that link to the corresponding `docs/` file.
  Do not delete content — if the linked doc does not already cover it, it will be
  added in Phase 3.

**M-14 · Makefile: uninstall-dry-run target description wrong**
File: `Makefile` ~lines 1007–1008
Change the target help comment to:
  `uninstall-dry-run: ## Simulate uninstall without deleting anything (--dry-run mode)`
And update the target body to pass `--dry-run` to `uninstall-vaultwarden.sh` instead
of `--help`.

**M-15 · Remote prune only runs via rotate, not during normal run --rclone**
File: `utilities/backup-run.sh` ~lines 1063–1104
After a successful `--rclone` backup run, call `_prune_remote_backups "$KEEP_DAYS"`
unconditionally (matching the local prune behavior). The `rotate` subcommand should
remain as an explicit on-demand path.

**M-16 · Pre-production drill does not test full restore**
File: `utilities/pre-production-drill.sh` ~lines 153–273
Add a restore smoke-test step:
- Create a temporary directory.
- Call `restore-run.sh --dry-run` (or simulate by unpacking the latest backup
  to the temp dir and running integrity checks).
- Verify the docker-compose.yml and .env.example are present in the extracted archive.
- Report PASS/FAIL. Do not require a live Docker environment — a dry-run/file-check
  is sufficient for the drill.

**M-17 · Non-actionable error messages in backup/health/restore**
Files: `backup-run.sh:273-275,802-805,936-939`, `maintenance-health.sh:323-328`,
       `restore-run.sh:1722-1730`
Improve each message to include a "what to do next" hint:
- sqlite3 backup fail → append: `"(check disk space: df -h ${BACKUP_DIR}; check DB lock)"`
- Encryption fail → un-suppress stderr: remove `2>/dev/null`; append storage hint.
- Container unhealthy → append: `"(run: docker logs vaultwarden --tail=50)"`
- Checksum mismatch → append: `"(try an older backup from ${BACKUP_DIR} or re-download from offsite)"`

**M-18 · Missing EXIT and/or ERR traps in entry-point scripts**
Files: `startup.sh`, `utilities/maintenance-email.sh`, `maintenance-update.sh`,
       `maintenance-update-dns.sh`, `setup-systemd.sh`, `uninstall-vaultwarden.sh`
Add `trap 'cleanup' EXIT` and `trap 'on_error "$LINENO"' ERR` near the top of each
script, following the exact pattern used in `utilities/maintenance-run.sh`.
For `startup.sh`, also move the `command -v` prereq check block (currently ~line 214)
to before the first `docker compose down` call (~line 112).

**M-19 · vaultwarden-notify-failure.service missing DefaultDependencies=no**
File: `systemd/vaultwarden-notify-failure.service`
Add `DefaultDependencies=no` to the `[Unit]` section.

**M-20 · Firewall bouncer enable failure silently ignored**
File: `utilities/setup-crowdsec.sh` ~line 662
Re-inspect at HEAD (post-audit commits may have changed this).
If `|| true` still suppresses bouncer start failures:
Replace with an explicit check:
```bash
systemctl enable --now crowdsec-firewall-bouncer \
  || log_error "crowdsec-firewall-bouncer failed to start — enforcement is INACTIVE. \
Run: journalctl -u crowdsec-firewall-bouncer -n 30"
```
Do not `exit 1` here — allow setup to complete but make the failure loud.

**M-21 · make help: destructive targets not separated**
File: `Makefile` ~lines 977–1008
Move `clean-all`, `prune`, and `restore` (any target that overwrites or deletes
data) into the `⚠ DANGER ZONE` section alongside `uninstall`. Update their help
comments to include `[DESTRUCTIVE]` in the description string.

---

### MINOR

**m-22 · SECURITY.md: wrong CrowdSec bouncer service name**
(Doc-only — handled in Phase 3)

**m-23 · DEPLOYMENT.md: TLS prereq guidance references HTTP-01 not DNS-01**
(Doc-only — handled in Phase 3)

**m-24 · TROUBLESHOOTING.md: stale --quick-verify flag**
(Doc-only — handled in Phase 3)

**m-25 · Lock FDs not explicitly closed in EXIT trap**
Files: `utilities/maintenance-run.sh`, `maintenance-health.sh`, `backup-run.sh`
In each script's `cleanup()` function, add `exec {_LOCK_FD}>&-` (using the actual
FD variable name) before or after removing the lock file.

**m-26 · Unquoted $(...) in for loops**
File: `utilities/uninstall-vaultwarden.sh:336,344`
Quote the command substitutions:
```bash
for vol in $(docker volume ls ...); → for vol in "$(docker volume ls ...)"; 
# or better, use mapfile:
mapfile -t vols < <(docker volume ls ...)
for vol in "${vols[@]}"; do
```

**m-27 · startup.sh: Docker used before command -v check**
File: `startup.sh`
Move the `command -v docker` / prereq validation block to before line 112
(the first `docker compose down` call). This is also required by M-18.

**m-28 · Health polling duplicated with divergent semantics**
Files: `lib/docker.sh:618-646`, `utilities/setup-storage.sh:1204-1246`,
       `utilities/restore-run.sh:1874-1880`
Extract the canonical wait-for-healthy loop from `lib/docker.sh` into a
standalone function `docker_wait_healthy(container, timeout_sec)`. Replace the
copies in `setup-storage.sh` and `restore-run.sh` with calls to this function.
Ensure the timeout and polling interval are consistent (use the lib version's values).

**m-29 · PROJECT_STATE_DIR / DATA_VOLUME_MOUNT defaults scattered**
Files: 10+ locations across `lib/` and `utilities/`
Add two canonical constants to `lib/paths.sh` (or `lib/common.sh` if that file
already centralises defaults):
```bash
readonly _DEFAULT_PROJECT_STATE_DIR="/var/lib/vaultwarden"
readonly _DEFAULT_DATA_VOLUME_MOUNT="/opt/vaultwarden/data"
```
Replace every inline `${PROJECT_STATE_DIR:-/var/lib/vaultwarden}` and
`${DATA_VOLUME_MOUNT:-/opt/vaultwarden/data}` occurrence with
`${PROJECT_STATE_DIR:-$_DEFAULT_PROJECT_STATE_DIR}` etc.

**m-30 · CrowdSec uninstall can over-delete /etc/crowdsec**
File: `utilities/uninstall-vaultwarden.sh:877-885`
Before `rm -rf /etc/crowdsec`, check whether the directory contains files
not owned/created by this installer. A safe heuristic: only delete the specific
subdirectories/files created by `setup-crowdsec.sh` (list them explicitly)
rather than the entire `/etc/crowdsec` tree.

**m-31 · Dashboard missing last backup result and timer schedule**
File: `utilities/dashboard.sh` ~line 223
In the overview panel (before the menu), add:
- Last backup outcome: read the last line of the backup log (or a status file
  written by `backup-run.sh`) and display SUCCESS/FAILURE + timestamp.
- Timer schedule: a compact one-line-per-timer summary showing next trigger time,
  using `systemctl list-timers --no-pager | grep vaultwarden`.

---

## Phase 3 — Documentation Updates

Update every file in `docs/` and `README.md`. For each file listed below, the
specific inaccuracies to correct are given. After correcting those, also do a
general pass: verify every command, flag, and file path in the document still
exists and is correct at HEAD. If you find additional inaccuracies beyond those
listed, fix them.

### docs/DEPLOYMENT.md
- Line 23: Remove requirement to open ports 80/443 before setup. Replace with:
  "The default TLS path uses Cloudflare DNS-01 challenge — no inbound HTTP is
  required for certificate issuance."
- Line 47: Remove "grey-cloud DNS" prerequisite for Let's Encrypt. Clarify that
  grey-cloud/proxied mode is optional and only affects Cloudflare-proxied routing,
  not cert issuance.
- Line 255: Replace "`setup.sh install --force`" with a clear warning:
  "`--force` regenerates the Age key, which orphans all existing encrypted backups.
  To re-apply config changes without key rotation, use `setup.sh install` without
  `--force`."
- Add a "Next step" link at the end: "→ Proceed to [Operations](OPERATIONS.md)"

### docs/OPERATIONS.md
- Line 133: Correct `make logs` description to: "Follows logs for a single service.
  Usage: `make logs SERVICE=vaultwarden`"
- Line 137: Remove `make logs FOLLOW=true` — this flag does not exist.
- Line 138: Correct `make logs-tail` to: "Shows last 100 lines of logs for all
  services (non-following). Usage: `make logs-tail`"
- Line 308: Correct `./maintenance.sh update` to require a flag:
  `./maintenance.sh update --images` (containers only) or `--system` or `--all`
- Line 316: Correct `make update-system` to: "Updates OS packages only.
  For a full update (containers + system), use `make update`."
- Line 722: Replace `simple_verify_age_key` shell command reference with:
  "This is an internal library function in `lib/crypto.sh`; it is not a standalone CLI command."
- Add a "Next step" link at the end: "→ [Backup & Restore](BACKUP-RESTORE.md)"

### docs/BACKUP-RESTORE.md
- Lines 19–21 and 77–78: Correct backup type contents to match what the code
  actually includes/excludes after your Phase 2 C-3 fix. Be precise.
- Line 51: Change timestamp format from `YYYYMMDD-HHMMSS` to `YYYYMMDD_HHMMSS`
  (underscore, matching actual filenames).
- Line 169: Correct `make key-backup` description to:
  "`make key-backup` copies the Age key to `$HOME/age-key-backup-<timestamp>.txt`
  for offline safekeeping. It does NOT generate a PDF."
- Line 451: Replace `simple_verify_age_key` shell command reference with:
  "Call `make verify-key` or use the dashboard key-verify menu option."

### docs/DISASTER-RECOVERY.md
- Line 3 / intro: Remove the claim that secrets are out of scope. State accurately
  whether `secrets/` is included or excluded, consistent with your C-3 fix.
- Line 21: Correct whether `*.sh` scripts are excluded from the full backup
  (they are NOT excluded by `perform_full_backup()`).
- Lines 209–227: Correct full/emergency backup contents to match the actual
  `perform_full_backup()` implementation and restore behavior.
- Line 241: Remove `--puid` / `--pgid` flags (they do not exist in `setup.sh`).
  Replace with the correct re-run instruction.

### docs/SECURITY.md
- Line 82: Change `cs-cloudflare-bouncer` → `crowdsec-cloudflare-bouncer` (or
  `crowdsec-cloudflare-worker-bouncer` — verify the actual unit name at HEAD in
  `utilities/setup-crowdsec.sh` before writing).
- Line 791: Same service name correction.

### docs/SCRIPTS.md
- Line 408: Correct `make update` to: "Runs `./maintenance.sh update --all`
  (containers + system packages)."
- Line 409: Correct `make update-system` to: "Runs `./maintenance.sh update --system`
  (OS packages only)."
- Line 727: Remove `sudo` from `make up` / `make start` description.
- Line 736: Correct `make logs` to match OPERATIONS.md fix above.
- Line 737: Correct `make logs-tail` to match OPERATIONS.md fix above.
- Line 849: Replace `simple_key_resilience.sh` references with `lib/crypto.sh`.

### docs/TROUBLESHOOTING.md
- Line 616: Remove `--quick-verify` flag. Replace with: "Quick verify is the
  default behavior. For deep verification, use `--full-verification`."

### README.md
- First 30 lines: Add the "Start here → docs/DEPLOYMENT.md" callout (see M-13).
- Consolidate inline walkthroughs into one-line doc links (see M-13).
- Line 24, 50–52: Correct port 80/443 requirement for TLS (DNS-01 does not need
  inbound HTTP).
- Line 233: Change `lib/common.sh` → `lib/email.sh` for email implementation.
- Line 353: Change `maintenance.sh update` → `maintenance.sh update --images|--system|--all`.
- Line 390: Correct `make logs` description.

### Recommended Reading Order (add to docs/README.md index or a new NAVIGATION.md)
Add a one-paragraph navigation guide at the top of the `docs/` index (or inside
`README.md`'s docs table) recommending this reading order:
  1. DEPLOYMENT.md → 2. CONFIGURATION.md → 3. SECURITY.md → 4. OPERATIONS.md →
  5. BACKUP-RESTORE.md → 6. DISASTER-RECOVERY.md → 7. TROUBLESHOOTING.md

Add "Next step: →" footer links to: DEPLOYMENT.md, OPERATIONS.md, BACKUP-RESTORE.md,
SECURITY.md, EMAIL.md, and API.md.

---

## Phase 4 — Verification Checklist

Before opening the PR, confirm:
- [ ] `bash -n` passes on every modified `.sh` file
- [ ] `shellcheck -S warning` passes on every modified `.sh` file
- [ ] No `User=ubuntu` or `Group=ubuntu` in any systemd unit
- [ ] All docs reference only commands/flags that exist in the current codebase
- [ ] `make key-backup` description in all docs matches the Makefile target
- [ ] `make logs` and `make logs-tail` descriptions in all docs match the Makefile
- [ ] CrowdSec bouncer service name is consistent across all docs and scripts
- [ ] Backup type contents (full vs emergency vs db) are described identically in
     BACKUP-RESTORE.md, DISASTER-RECOVERY.md, and inline comments in backup-run.sh
- [ ] AUDIT-BETA-FINAL-01-Findings.md is updated with a "Resolution Status" table
     showing which findings were resolved in this PR, which were already resolved by
     prior commits, and which (if any) are deferred with justification

---

---

## Phase 5 — Drift Resistance Infrastructure

The audit found 26 documentation inaccuracies caused by code changing without
docs being updated. Add the following mechanisms so this cannot silently recur.

---

### 5-A · Makefile Command Reference Extraction

Create a new script: `utilities/generate-command-ref.sh`

Purpose: parse every `make` target's help comment and every `.sh` entry-point's
`--help` output, and write them to `docs/COMMAND-REFERENCE.md` automatically.
Structure:

```bash
#!/usr/bin/env bash
# Auto-generates docs/COMMAND-REFERENCE.md from Makefile help comments
# and script --help output. Run via: make docs or make command-ref
# DO NOT hand-edit COMMAND-REFERENCE.md — it is overwritten on each run.
set -euo pipefail
...
```

- Parse Makefile targets using the existing `## comment` convention
  (grep `^[a-zA-Z_-]*:.*##` and format as a table).
- For each entry-point script in root (`setup.sh`, `backup.sh`, `maintenance.sh`,
  `restore.sh`, `startup.sh`, `dashboard.sh`, `edit-secrets.sh`), capture
  `bash "$script" --help 2>&1 | head -60` and embed under a `###` heading.
- Write a header warning: `<!-- AUTO-GENERATED — do not edit. Run: make docs -->`
- Add a Makefile target:
  ```makefile
  docs: ## Regenerate docs/COMMAND-REFERENCE.md from live script --help and Makefile targets
      @bash utilities/generate-command-ref.sh
  ```

---

### 5-B · Doc Accuracy CI Check

Create `.github/workflows/doc-drift.yml`:

```yaml
name: Doc Drift Check
on:
  pull_request:
    paths:
      - 'docs/**'
      - 'utilities/**'
      - 'lib/**'
      - '*.sh'
      - 'Makefile'
      - 'systemd/**'

jobs:
  doc-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check for known stale terms
        run: |
          # Fail if any doc still references known-stale terms
          STALE_TERMS=(
            "simple_verify_age_key"
            "simple_key_resilience.sh"
            "--quick-verify"
            "cs-cloudflare-bouncer"
            "make logs FOLLOW=true"
            "--puid"
            "--pgid"
            "lib/common.sh.*email"
          )
          FAIL=0
          for term in "${STALE_TERMS[@]}"; do
            matches=$(grep -rn "$term" docs/ README.md 2>/dev/null || true)
            if [[ -n "$matches" ]]; then
              echo "STALE TERM FOUND: $term"
              echo "$matches"
              FAIL=1
            fi
          done
          [[ $FAIL -eq 0 ]] || exit 1

      - name: Verify Makefile targets referenced in docs exist
        run: |
          # Extract every `make <target>` mention from docs
          FAIL=0
          while IFS= read -r target; do
            if ! grep -q "^${target}:" Makefile; then
              echo "MISSING MAKEFILE TARGET referenced in docs: make $target"
              FAIL=1
            fi
          done < <(grep -roh 'make [a-z_-]\+' docs/ README.md | sed 's/make //' | sort -u)
          [[ $FAIL -eq 0 ]] || exit 1

      - name: Verify script flags referenced in docs exist
        run: |
          # Check a curated set of flags that have historically drifted
          check_flag() {
            local script="$1" flag="$2"
            if ! grep -q -- "$flag" "$script" 2>/dev/null; then
              echo "FLAG NOT FOUND: $flag in $script (referenced in docs)"
              return 1
            fi
          }
          FAIL=0
          check_flag utilities/backup-run.sh "--full-verification" || FAIL=1
          check_flag utilities/maintenance-update.sh "--images"     || FAIL=1
          check_flag utilities/maintenance-update.sh "--system"     || FAIL=1
          check_flag utilities/maintenance-update.sh "--all"        || FAIL=1
          check_flag setup.sh "--force"                             || FAIL=1
          check_flag utilities/uninstall-vaultwarden.sh "--dry-run" || FAIL=1
          [[ $FAIL -eq 0 ]] || exit 1
```

Add the workflow file to `.github/workflows/`. This runs on every PR that
touches docs, scripts, or the Makefile, and catches the three most common
drift categories: stale term references, missing Make targets, and removed flags.

---

### 5-C · COMMAND-REFERENCE.md Auto-Generation Guard

Add to the top of `docs/COMMAND-REFERENCE.md` (created by 5-A):

```markdown
<!-- AUTO-GENERATED by utilities/generate-command-ref.sh -->
<!-- DO NOT EDIT MANUALLY. Run `make docs` to regenerate. -->
<!-- Last generated: (timestamp inserted by script) -->
```

Add a CI step in `doc-drift.yml` that regenerates and fails if the committed
file differs from the freshly generated one:

```yaml
      - name: Verify COMMAND-REFERENCE.md is up to date
        run: |
          cp docs/COMMAND-REFERENCE.md docs/COMMAND-REFERENCE.md.committed
          bash utilities/generate-command-ref.sh
          if ! diff -q docs/COMMAND-REFERENCE.md docs/COMMAND-REFERENCE.md.committed; then
            echo "COMMAND-REFERENCE.md is stale. Run: make docs"
            diff docs/COMMAND-REFERENCE.md docs/COMMAND-REFERENCE.md.committed
            exit 1
          fi
```

---

### 5-D · Backup Content Manifest File

The audit's most dangerous finding was that BACKUP-RESTORE.md, DISASTER-RECOVERY.md,
and the actual tar command in `backup-run.sh` all described different sets of
included/excluded files.

Fix this permanently by extracting the include/exclude list into a single
source of truth:

1. In `utilities/backup-run.sh`, define the exclusion list as a bash array
   at the top of `perform_full_backup()`:

   ```bash
   local -a _BACKUP_EXCLUDES=(
     ".git"
     "backups"
     "logs"
     ".rate-limit"
     "*.sock"
     "*.lock"
     "*.tmp"
     "*.age.tmp"
     # Add "secrets" here if Option A was chosen in C-3
   )
   ```

   Use this array to build the `--exclude=` flags dynamically:
   ```bash
   local tar_exclude_args=()
   for excl in "${_BACKUP_EXCLUDES[@]}"; do
     tar_exclude_args+=("--exclude=${SCRIPT_DIR#/}/${excl}")
   done
   ```

2. Add a Makefile target that prints this list in human-readable form:
   ```makefile
   backup-manifest: ## Show what is included and excluded in a full backup
       @bash -c 'source utilities/backup-run.sh; print_backup_manifest'
   ```
   Where `print_backup_manifest()` is a thin function that loops `_BACKUP_EXCLUDES`
   and prints them with a header. This gives docs writers and operators a live
   source of truth.

3. In BACKUP-RESTORE.md and DISASTER-RECOVERY.md, replace the static
   include/exclude lists with a note:
   > "For the authoritative list of excluded paths, run `make backup-manifest`
   >  or see the `_BACKUP_EXCLUDES` array in `utilities/backup-run.sh`."

---

### 5-E · Systemd Unit Hardening Matrix Auto-Check

The audit's Part 4 hardening matrix was generated manually. Add a script to
generate it automatically and detect regressions:

Create `utilities/check-systemd-hardening.sh`:

```bash
#!/usr/bin/env bash
# Validates that all vaultwarden systemd units meet minimum hardening standards.
# Exits non-zero if any unit is missing a required directive.
# Run via: make check-hardening
set -euo pipefail

REQUIRED_DIRECTIVES=(PrivateTmp ProtectSystem NoNewPrivileges ProtectHome)
UNIT_DIR="${1:-systemd}"
FAIL=0

for unit in "$UNIT_DIR"/vaultwarden-*.service; do
  [[ "$unit" == *template* ]] && continue
  for directive in "${REQUIRED_DIRECTIVES[@]}"; do
    if ! grep -q "^${directive}=" "$unit"; then
      echo "MISSING $directive in $unit"
      FAIL=1
    fi
  done
done

[[ $FAIL -eq 0 ]] && echo "All units pass hardening check." || exit 1
```

Add to the Makefile:
```makefile
check-hardening: ## Verify all systemd units meet minimum hardening standards
    @bash utilities/check-systemd-hardening.sh systemd
```

Add this as a CI step in `doc-drift.yml` (or a separate `hardening.yml` workflow):
```yaml
      - name: Systemd unit hardening check
        run: bash utilities/check-systemd-hardening.sh systemd
```

---

### 5-F · Version-Pinning Enforcement

The audit found CrowdSec using `latest` everywhere. Add a CI check to prevent
any new `latest` references from creeping in:

Add to `doc-drift.yml`:
```yaml
      - name: Check for unpinned version references
        run: |
          FAIL=0
          # Fail on @latest in any shell script
          if grep -rn '@latest' utilities/ lib/ --include='*.sh'; then
            echo "UNPINNED: @latest Go reference found"
            FAIL=1
          fi
          # Fail on /releases/latest in any shell script
          if grep -rn '/releases/latest' utilities/ lib/ --include='*.sh'; then
            echo "UNPINNED: /releases/latest GitHub API call found"
            FAIL=1
          fi
          # Warn (not fail) on curl|bash patterns
          if grep -rn 'curl.*|.*bash' utilities/ lib/ --include='*.sh'; then
            echo "WARNING: curl|bash pattern found — review for safety"
            # Set FAIL=1 here if you want this to be a hard block
          fi
          [[ $FAIL -eq 0 ]] || exit 1
```

---

### 5-G · CHANGELOG Enforcement

Add a PR template at `.github/pull_request_template.md` that reminds contributors:

```markdown
## Checklist
- [ ] All changed shell scripts pass `bash -n` and `shellcheck -S warning`
- [ ] If any `make <target>` behavior changed, `docs/SCRIPTS.md` and `docs/OPERATIONS.md` are updated
- [ ] If any `--flag` was added or removed, all docs referencing that script are updated
- [ ] If backup include/exclude logic changed, `make backup-manifest` output was verified
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] If systemd units changed, `make check-hardening` passes
- [ ] `make docs` was run if any script `--help` text changed
```

This makes the drift-prevention steps explicit and human-reviewed on every PR,
complementing the automated CI checks.

---

### Phase 5 Verification Checklist (add to Phase 4 list)

- [ ] `.github/workflows/doc-drift.yml` exists and all steps pass on current HEAD
- [ ] `utilities/generate-command-ref.sh` generates valid Markdown without errors
- [ ] `docs/COMMAND-REFERENCE.md` is committed and matches `make docs` output
- [ ] `utilities/check-systemd-hardening.sh` passes on current systemd/ directory
- [ ] `make backup-manifest` prints the exclude list without errors
- [ ] `.github/pull_request_template.md` exists with the checklist above

## PR Instructions

- Title: `fix: resolve AUDIT-BETA-FINAL-01 findings and refresh all documentation`
- Body: reference the audit file, list each finding number with its resolution status
- Keep code and doc changes in separate commits where practical
- Do not alter test files, CI workflows, or the `secrets/` directory structure
```

***
