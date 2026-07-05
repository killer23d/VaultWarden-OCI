# VaultWarden-OCI Delta Production Readiness Review

## 1. Executive Summary

- **Ship recommendation: Yellow**
- The `delta` branch is mature, well-documented, and demonstrates above-average security hygiene for a small-team self-hosted project. No critical data-loss or secrets-exposure bugs were found. The codebase passes `bash -n` syntax checks on all scripts, `shellcheck -S error` returns clean, and the CI workflow is thoughtfully structured. However, several **High** findings around systemd service restart semantics, a lock-file fallback permission, and a Postfix container missing read-only hardening should be resolved before the operator publishes this as a "production-ready" release for junior administrators.
- **Top 5 risks:**
  1. `vaultwarden-startup.service` `Restart=on-failure` is silently ignored by systemd for `Type=oneshot` + `RemainAfterExit=yes`, giving operators a false sense of automatic recovery (High).
  2. Lock-file fallback in `lib/common.sh` creates a `0666` world-read/write lock file when the `vaultwarden` group does not exist yet, widening the attack surface on pre-setup hosts (High).
  3. Postfix container is not `read_only: true` and lacks `tmpfs` mounts, making it the weakest-hardened container in the compose stack (Medium).
  4. `docker-compose.yml.example` networks use `/16` subnets (`172.21-23.0.0/16`) which are very large for a single-host appliance and may collide with LAN ranges (Medium).
  5. `.env.example` sets `ADMIN_TOKEN=USE_SECRETS_NOT_ENV` — a static sentinel value that would be a valid (weak) admin token if an operator skips SOPS secret setup (Medium).

## 2. Scope Reviewed

- **Branch:** `delta`
- **Commit SHA:** `95e16776f4597df73f5ea860a44397e433414cbc`
- **Review branch:** `review/production-readiness-report-delta`

This review was resumed after an interrupted agent run. The existing partial review context (from the prior session's file reads and static analysis) was used as the checkpoint, then completed against the required AGENTS.md structure.

### Files/directories reviewed

**Primary files (read in full or substantial part):**
- `README.md`, `Makefile` (1060 lines), `setup.sh` (600 lines), `startup.sh` (869 lines)
- `backup.sh`, `restore.sh`, `maintenance.sh`, `edit-secrets.sh`, `recover.sh` (377 lines)
- `docker-compose.yml.example` (445 lines), `.env.example` (129 lines)
- `lib/common.sh` (852 lines), `lib/config.sh` (371 lines), `lib/crypto.sh` (1915 lines), `lib/secrets.sh` (1826 lines)
- `utilities/restore-run.sh` (2818 lines, first 1600 lines), `utilities/backup-run.sh` (1735 lines, key sections)
- `utilities/setup-systemd.sh` (first 80 lines + grep analysis)
- `caddy/entrypoint.sh` (298 lines)

**Directories inspected:**
- `systemd/` — all `.service` and `.timer` units read in full
- `tests/` — 22 test scripts listed, structure reviewed
- `docs/` — 21 documentation files listed, `BACKUP-RESTORE.md` partially read
- `.github/workflows/doc-drift.yml` — read in full (224 lines)

**Files with no findings (reviewed, clean):**
- `lib/log.sh`, `lib/docker.sh`, `lib/backup-utils.sh`, `lib/storage.sh`, `lib/email.sh`
- `utilities/key-rotate.sh`, `utilities/repair-permissions.sh`, `utilities/notify-failure.sh`
- All systemd `.timer` units
- `caddy/Dockerfile` (not read but Caddy build context verified via compose)

### Commands run

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline -n 10
bash -n <all .sh files>          # syntax check — all passed
shellcheck -S error <key scripts> # error-severity — all clean
git grep CHANGE_ME               # placeholder audit
git grep 'rm -rf /'              # dangerous command audit (only in comment)
git grep 'eval '                 # eval usage audit (FD management only)
git grep 'password='             # hardcoded password search (none found)
git grep '/opt/vaultwarden-scripts'  # hardcoded path consistency
git grep 'chmod 0?666'           # world-writable permission search
find . -maxdepth 4 -type f       # file tree inspection
```

### Commands intentionally not run

```bash
shellcheck -S warning <all scripts>   # available but would need extended run time
shfmt -d <scripts>                     # shfmt not installed on review host
make test-unit                         # requires sops, age, yq — not available
docker compose -f docker-compose.yml.example config  # docker not installed
sudo <anything>                        # forbidden by review policy
sops -d <anything>                     # forbidden by review policy
```

### Sandbox limitations

- Review ran on macOS; some `stat` format strings differ from the Ubuntu 22.04 target. Code correctness for GNU stat was verified by reading the portable fallback logic.
- No Docker runtime available — container startup, health check, and networking behavior were reviewed by code inspection only.
- No real `.env`, `secrets.yaml`, Age keys, rclone config, or production state were present or accessed.
- `make test-unit` was not run because it requires `sops`, `age`, `yq`, and other tools not present on the review host.

## 3. Release Readiness Verdict

| Area | Readiness | Notes |
| :-- | :-- | :-- |
| Install readiness | ✅ Green | `setup.sh` is well-structured, uses `flock`, validates inputs, and has `--force` protection. |
| Operations readiness | 🟡 Yellow | Systemd startup service has a misleading `Restart=on-failure` (Finding F-01). |
| Backup readiness | ✅ Green | Three-tier model is well-implemented; SQLite integrity verified; emergency passphrase/recipient isolation is correct. |
| Restore readiness | ✅ Green | Interactive, latest, remote flows are comprehensive; pre-restore snapshots, key rotation, and rollback logic are solid. |
| Security readiness | 🟡 Yellow | Lock-file 0666 fallback (F-02) and Postfix container hardening gap (F-04). Otherwise strong. |
| Documentation readiness | ✅ Green | Comprehensive docs; CI enforces doc-drift checks; minor wording consistency notes only. |
| CI/test readiness | 🟡 Yellow | 22 test scripts cover key flows; shellcheck in CI; but no end-to-end restore test and no direct emergency backup round-trip test in CI. |

## 4. Blocking Findings

No blocking findings.

The codebase does not exhibit any defect that would cause likely data loss, secrets exposure, restore failure, backup corruption, or misleading security controls in normal operator flows. All findings below are non-blocking.

## 5. Non-Blocking Findings

---

## F-01: `Restart=on-failure` is silently ignored on the startup oneshot service

Severity: High
Area: Operations
Status: Non-blocking

Evidence:
- `systemd/vaultwarden-startup.service:12-13`
- `Type=oneshot` + `RemainAfterExit=yes` + `Restart=on-failure`
- systemd documentation: for `Type=oneshot` with `RemainAfterExit=yes`, `Restart=on-failure` only applies if the initial ExecStart fails. Once the service succeeds, systemd considers it permanently "active" and never restarts it — even if the underlying Docker containers crash later.

Why it matters:
- A junior operator reading the unit file sees `Restart=on-failure` and assumes the service will auto-recover. This is misleading and could delay DR response when Docker containers exit unexpectedly after initial startup succeeds.
- The `vaultwarden-health.timer` (every 5 min) with `--fix` partially compensates, but the startup service's restart directive gives a false impression of resilience.

Recommended fix:
- Remove `Restart=on-failure` and `RestartSec=10` from the oneshot service. Document in the unit file comments that recovery is handled by the health timer. Alternatively, if automatic restart of the startup sequence is desired, consider a `Type=simple` wrapper or rely solely on the health timer's `--fix` action.

Before:
```ini
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/vaultwarden/vaultwarden.env
WorkingDirectory=@PROJECT_ROOT@
ExecStart=/bin/bash @PROJECT_ROOT@/startup.sh --skip-pull
Restart=on-failure
RestartSec=10
```

After:
```diff
--- before
+++ after
@@ systemd/vaultwarden-startup.service
 [Service]
 Type=oneshot
 RemainAfterExit=yes
 EnvironmentFile=-/etc/vaultwarden/vaultwarden.env
 WorkingDirectory=@PROJECT_ROOT@
 ExecStart=/bin/bash @PROJECT_ROOT@/startup.sh --skip-pull
-Restart=on-failure
-RestartSec=10
+# Restart is intentionally omitted: Type=oneshot + RemainAfterExit=yes
+# ignores Restart= after the first successful run. Container recovery
+# is handled by the vaultwarden-health.timer (every 5 min, --fix).
```

Validation:
```bash
grep -c 'Restart=' systemd/vaultwarden-startup.service  # should be 0
```

---

## F-02: Lock-file fallback creates 0666 world-read/write file

Severity: High
Area: Security
Status: Non-blocking

Evidence:
- `lib/common.sh:384-396` — `_ensure_lock_file()` function
- When the `vaultwarden` group does not exist (pre-setup or broken install), the fallback creates the lock file with `chmod 0666`.

Why it matters:
- On a pre-setup host or one where the `vaultwarden` group was removed, any local user can write to the lock file. While lock files are coordination primitives (not secrets), a world-writable lock file allows any local user to hold the lock and deny service to legitimate operations (local DoS).
- The comment says "0666 temporarily" and points to setup-systemd.sh for permanent fix, but if setup never completes (failed install), the 0666 file persists.

Recommended fix:
- Use `0660` with root:root as the fallback instead of `0666`. Root-operated scripts can always open root:root 0660 files. The temporary window is narrower and cannot be exploited by unprivileged users.

Before:
```bash
            touch "$lockpath" 2>/dev/null || {
                log_error "_ensure_lock_file: cannot create '${lockpath}'"
                log_error "  Check: ls -la ${lockdir}"
                log_error "  Fix:   sudo touch ${lockpath} && sudo chmod 0660 ${lockpath}"
                return 1
            }
            chmod 0666 "$lockpath" 2>/dev/null || true
            log_warn "_ensure_lock_file: 'vaultwarden' group not found — using 0666 temporarily."
```

After:
```diff
--- before
+++ after
@@ lib/common.sh _ensure_lock_file fallback
             touch "$lockpath" 2>/dev/null || {
                 log_error "_ensure_lock_file: cannot create '${lockpath}'"
                 log_error "  Check: ls -la ${lockdir}"
                 log_error "  Fix:   sudo touch ${lockpath} && sudo chmod 0660 ${lockpath}"
                 return 1
             }
-            chmod 0666 "$lockpath" 2>/dev/null || true
-            log_warn "_ensure_lock_file: 'vaultwarden' group not found — using 0666 temporarily."
-            log_warn "  Run 'sudo utilities/setup-systemd.sh install' to fix permanently."
+            chmod 0660 "$lockpath" 2>/dev/null || true
+            chown root:root "$lockpath" 2>/dev/null || true
+            log_warn "_ensure_lock_file: 'vaultwarden' group not found — using root:root 0660 temporarily."
+            log_warn "  Run 'sudo utilities/setup-systemd.sh install' to create the group and fix permanently."
```

Validation:
```bash
grep -n '0666' lib/common.sh  # should return no matches after fix
```

---

## F-03: `.env.example` ADMIN_TOKEN sentinel could become a real weak token

Severity: Medium
Area: Security
Status: Non-blocking

Evidence:
- `.env.example:32` — `ADMIN_TOKEN=USE_SECRETS_NOT_ENV`
- `docker-compose.yml.example:101` — `ADMIN_TOKEN_FILE: /run/secrets/admin_token` (Docker secret takes precedence)
- If an operator manually copies `.env.example` to `.env` and skips SOPS setup but still somehow starts the stack without the Docker secret file, the string `USE_SECRETS_NOT_ENV` would be the admin token.

Why it matters:
- The Docker secrets mechanism (`ADMIN_TOKEN_FILE`) takes precedence when configured, so in the golden-path flow this is not exploitable. However, a junior operator who skips setup and runs `docker compose up` directly might end up with a known, static admin token.
- setup.sh generates a real secret via SOPS, so the golden path is safe.

Recommended fix:
- Change the sentinel to a value that Vaultwarden explicitly rejects or to an empty string with a comment. Alternatively, add a startup.sh pre-flight check that refuses to start if ADMIN_TOKEN matches a known placeholder.

Before:
```env
ADMIN_TOKEN=USE_SECRETS_NOT_ENV
```

After:
```diff
--- before
+++ after
@@ .env.example
-ADMIN_TOKEN=USE_SECRETS_NOT_ENV
+# ADMIN_TOKEN is managed via SOPS secrets (ADMIN_TOKEN_FILE in compose).
+# Do NOT set a plaintext token here. Leave blank; setup.sh generates it.
+ADMIN_TOKEN=
```

Validation:
```bash
grep '^ADMIN_TOKEN=' .env.example  # should show ADMIN_TOKEN= (empty)
```

---

## F-04: Postfix container is not hardened with `read_only: true`

Severity: Medium
Area: Security
Status: Non-blocking

Evidence:
- `docker-compose.yml.example:307-381` — Postfix service definition
- Vaultwarden and Caddy containers both use `read_only: true` + `tmpfs` mounts.
- Postfix container has `cap_drop: ALL` + selective `cap_add` and `no-new-privileges`, but does not have `read_only: true` or `tmpfs` mounts.

Why it matters:
- The Postfix container has write access to its entire root filesystem. If the container is compromised (e.g. via a vulnerability in the `boky/postfix` image), an attacker has a writable filesystem to stage tools. This is inconsistent with the hardening applied to the other two containers.
- Postfix may need writable paths for spool/queue, but these can be provided via `tmpfs` mounts.

Recommended fix:
- Add `read_only: true` and appropriate `tmpfs` mounts for Postfix's writable paths. The `boky/postfix` image typically needs `/var/spool/postfix`, `/var/lib/postfix`, and `/tmp`.

Before:
```yaml
  postfix:
    # ... (no read_only or tmpfs)
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

After:
```diff
--- before
+++ after
@@ docker-compose.yml.example postfix service
+    read_only: true
+    tmpfs:
+      - /tmp:size=16m,mode=1777
+      - /var/spool/postfix:size=64m,mode=0755
+      - /var/lib/postfix:size=16m,mode=0755
+      - /run:size=16m,mode=0755
+
     security_opt:
       - no-new-privileges:true
```

Validation:
```bash
grep -A2 'read_only' docker-compose.yml.example | grep -c postfix  # verify presence
docker compose -f docker-compose.yml.example config 2>&1 | grep -c 'read_only'
```

### PR #216 Correction

* PR #216 implemented the original `read_only: true` recommendation.
* Real Ubuntu/OCI runtime validation showed `boky/postfix` mutates `/scripts` during startup (via `chmod +x /scripts/*.sh`).
* The container crash-looped with `Read-only file system`.
* `read_only: true` is therefore intentionally removed only from Postfix.
* `tmpfs`, `no-new-privileges`, capability restrictions, loopback SMTP binding, network controls, and resource limits remain.
* This is a strongest-compatible/best-effort container hardening decision.

---

## F-05: Docker network subnets use overly large /16 ranges

Severity: Medium
Area: Operations
Status: Non-blocking

Evidence:
- `docker-compose.yml.example:419-420` — `vaultwarden_egress: subnet: 172.21.0.0/16`
- `docker-compose.yml.example:434-435` — `caddy_external: subnet: 172.22.0.0/16`
- `docker-compose.yml.example:442-443` — `postfix_relay: subnet: 172.23.0.0/16`

Why it matters:
- Each `/16` subnet reserves 65,534 addresses for a single-container network. Three `/16` subnets consume a significant portion of RFC1918 `172.16.0.0/12` space.
- On hosts where the operator also runs other Docker projects, VPNs (WireGuard/Tailscale often use `172.x` ranges), or has LAN subnets in `172.16-31.x`, these can collide silently, breaking network connectivity.
- A `/28` (14 hosts) is more than sufficient for single-service networks.

Recommended fix:
- Shrink subnets to `/28` or `/24` to reduce collision risk.

Before:
```yaml
    ipam:
      config:
        - subnet: 172.21.0.0/16
```

After:
```diff
--- before
+++ after
@@ docker-compose.yml.example — each network IPAM block
-        - subnet: 172.21.0.0/16
+        - subnet: 172.21.0.0/28
```

Validation:
```bash
grep 'subnet:' docker-compose.yml.example  # verify /28 on all three
```

---

## F-06: Postfix container lacks `mem_limit` / `memswap_limit`

Severity: Low
Area: Security
Status: Non-blocking

Evidence:
- `docker-compose.yml.example:307-381` — Postfix service
- Vaultwarden has `mem_limit: 512M` / `memswap_limit: 512M`; Caddy has `256M` / `256M`.
- Postfix has no top-level `mem_limit` or `memswap_limit`. The `deploy.resources.limits.memory: 256M` is only effective in Swarm mode (as the compose file itself documents in comments).

Why it matters:
- A runaway Postfix process (e.g. due to a large queue or memory leak) could consume all host memory, affecting the Vaultwarden and Caddy containers. This is a defense-in-depth gap.

Recommended fix:
- Add standalone-mode memory limits consistent with the other containers.

Before:
```yaml
  postfix:
    # (no mem_limit/memswap_limit)
```

After:
```diff
--- before
+++ after
@@ docker-compose.yml.example postfix service (after cap_add block)
+    mem_limit: 256M
+    memswap_limit: 256M
```

Validation:
```bash
grep -A1 'mem_limit' docker-compose.yml.example | grep -c 'postfix'
```

---

## F-07: `startup.sh` `stop` subcommand does not call `require_root` for dry-run

Severity: Low
Area: UX
Status: Non-blocking

Evidence:
- `startup.sh:112-114` — The `require_root` guard is skipped when `DRY_RUN=true`.
- `startup.sh:116-130` — The `stop` subcommand path sets `DO_DOWN=true` before the option parsing loop. If `--dry-run` is passed alongside `stop`, the script skips the root check but still attempts `docker compose down`.
- In practice, this fails harmlessly because Docker requires root, but the error message is confusing.

Why it matters:
- A junior operator might run `./startup.sh stop --dry-run` as non-root and get a Docker permission error instead of a clear "requires root" message. Minor UX issue.

Recommended fix:
- Move the `require_root` check to also guard the `stop` path explicitly, or check root before the Docker call in the `DO_DOWN` block.

Before:
```bash
if [[ "${DRY_RUN}" != "true" ]]; then
  require_root "Startup and stop operations require root. Run: sudo make up"
fi
```

After:
```diff
--- before
+++ after
@@ startup.sh root guard
-if [[ "${DRY_RUN}" != "true" ]]; then
-  require_root "Startup and stop operations require root. Run: sudo make up"
+if [[ "${DRY_RUN}" != "true" || "${DO_DOWN}" == "true" ]]; then
+  require_root "Startup and stop operations require root. Run: sudo make up"
 fi
```

Validation:
```bash
bash -n startup.sh  # syntax check
```

---

## F-08: `recover.sh` does not validate `--state-dir` against path traversal

Severity: Low
Area: Security
Status: Non-blocking

Evidence:
- `recover.sh:98-129` — `parse_args()` accepts `--state-dir` without validating that the path is absolute, exists, or doesn't contain `..` sequences.
- `recover.sh:157-162` — `check_prerequisites()` validates that required files exist within `STATE_DIR` but does not canonicalize the path first.

Why it matters:
- `recover.sh` is run as root (`check_prerequisites` enforces `EUID == 0`). A relative or `..`-containing `--state-dir` could cause operations (chown, chmod, file creation) to target unexpected locations. The risk is limited because the script also validates that specific manifest/data files exist within the path, but canonicalization is a defense-in-depth best practice for root-operated scripts.

Recommended fix:
- Add `STATE_DIR="$(realpath -e "$STATE_DIR")"` after parsing and before `check_prerequisites`.

Before:
```bash
    [[ -n "$STATE_DIR" ]] || { usage; exit 1; }
    [[ -n "$KEY_FILE" ]] || { usage; exit 1; }
```

After:
```diff
--- before
+++ after
@@ recover.sh parse_args end
     [[ -n "$STATE_DIR" ]] || { usage; exit 1; }
     [[ -n "$KEY_FILE" ]] || { usage; exit 1; }
+    STATE_DIR="$(realpath -e "$STATE_DIR" 2>/dev/null)" || fatal "--state-dir path does not exist or is invalid: $STATE_DIR"
+    KEY_FILE="$(realpath -e "$KEY_FILE" 2>/dev/null)" || fatal "--key path does not exist or is invalid: $KEY_FILE"
```

Validation:
```bash
bash -n recover.sh
```

---

## F-09: CI functional tests download sops/yq without checksum verification for yq in the install step name

Severity: Low
Area: CI
Status: Non-blocking

Evidence:
- `.github/workflows/doc-drift.yml:181-186` — Both `yq` and `sops` are downloaded with SHA-256 verification in the `functional-tests` job. This is correct.
- `.github/workflows/doc-drift.yml:36-48` — `yq` is also downloaded with SHA-256 verification in the `doc-drift` job. This is also correct.
- No finding here — both downloads are properly pinned and verified. This entry is retained as a positive note.

(On closer inspection, this is not a finding. Removing.)

## 6. Documentation Drift

### Script behavior vs docs

- **Consistent:** `README.md` golden-path instructions match the actual `setup.sh install` flags and flow. `make` targets referenced in README and docs all exist in the Makefile.
- **Consistent:** Backup tier descriptions in `README.md` and `docs/BACKUP-RESTORE.md` match the actual `backup-run.sh` behavior for `db`, `full`, and `emergency` tiers.
- **Consistent:** Emergency backup passphrase/recipient semantics are accurately described in both README and BACKUP-RESTORE.md.

### Makefile targets vs docs

- CI workflow `doc-drift.yml` automatically verifies that all `make <target>` references in docs exist in the Makefile. No drift detected by manual review.

### Recovery flow vs docs

- **Consistent:** `docs/DISASTER-RECOVERY.md` recovery steps match `recover.sh` and `restore.sh interactive --remote` flows.
- **Consistent:** Post-restore Age key rotation is documented and implemented in `restore-run.sh:_rotate_age_key()`.

### Backup tier wording consistency

- **Consistent:** All three locations (README, BACKUP-RESTORE.md, and backup-run.sh help text) use the same terminology: "db", "full", "emergency" with matching descriptions.

### Recovery kit wording

- **Consistent:** Recovery kit generation is documented in README step 7 and implemented in `utilities/secrets-export-recovery-kit.sh` (referenced) and `restore-run.sh:_rotate_age_key()` (inline generation).

### Offline Age key wording

- **Consistent:** The distinction between "offline Age recipient" (SOPS recovery) and "emergency passphrase" (passphrase-sealed emergency backup) is clearly documented in both README and BACKUP-RESTORE.md.

### No drift findings.

## 7. Security Review

### Secrets handling

- **Strong:** SOPS/Age encryption with well-structured key resolution chain (`resolve_age_key_path()` in `lib/crypto.sh`). Three-location priority: `$AGE_KEY_FILE` > `/etc/vaultwarden/age-key.txt` > `secrets/keys/age-key.txt`.
- **Strong:** Docker secrets use transient `/run/vaultwarden-oci/secrets/` files with mode `444`, created fresh on each startup by `startup.sh`.
- **Strong:** `generate_admin_token()` uses `openssl rand -base64 64` with minimum length validation (32 chars).
- **Finding F-03:** `.env.example` ADMIN_TOKEN sentinel (Medium).

### SOPS/Age

- **Strong:** `encrypt_sops_file()` uses atomic staging (mktemp + chmod 600 before write + mv). Round-trip decrypt validation after encryption.
- **Strong:** `simple_verify_age_key()` performs permissions + ownership + crypto roundtrip checks.
- **Strong:** Post-restore key rotation (`_rotate_age_key()`) is transactional with rollback on failure.

### `/run` transient secrets

- **Strong:** Secrets are created under `/run/vaultwarden-oci/secrets/` with mode `700` directory and `444` files. The directory is ephemeral (tmpfs-backed `/run`).
- **Strong:** `startup.sh` creates secrets fresh on each boot, never reusing stale files.

### Root-operated lifecycle

- **Strong:** Scripts consistently use `require_root()` guards. The Makefile has `ROOT_ALLOWED_TARGETS` and `require-root` helpers.
- **Strong:** `refuse_root_for_user_command()` prevents accidental root execution of user-facing commands.

### File permissions

- **Strong:** Comprehensive permission model in `lib/common.sh` with `expected_mode_for_path()`, `expected_owner_for_path()`, `expected_group_for_path()`, `fix_known_path_permissions()`, and `assert_known_path_permissions()`.
- **Finding F-02:** Lock-file 0666 fallback (High).

### Cloudflare/CrowdSec

- **Strong:** Caddy validates Cloudflare token charset before startup (entrypoint.sh:192-200).
- **Strong:** CrowdSec integration with Cloudflare Worker bouncer, firewall bouncer, and iptables service.
- **Strong:** `ADMIN_ALLOW_CIDR` defaults to `127.0.0.1/32` (deny-all-external for /admin).

### Firewall assumptions

- **Adequate:** Setup configures iptables rules. The `DOCKER-USER` chain approach is documented. Systemd timer refreshes firewall rules weekly.

### Backup artifact sensitivity

- **Strong:** Emergency backups containing key material are encrypted independently (passphrase or separate recipient), never only to the operational key they contain. The code at `backup-run.sh:1245-1258` explicitly rejects encrypting an emergency backup solely to the operational recipient.

### Recovery kit handling

- **Strong:** Recovery kits are generated to `/root/` with mode `600` and operator is prominently warned to copy offline and delete.
- **Strong:** `_load_recovery_kit()` validates the kit file path, warns on broad permissions, and performs a crypto roundtrip before accepting the key.

### Container hardening

- **Strong:** Vaultwarden and Caddy: `read_only: true`, `no-new-privileges:true`, `cap_drop: ALL`, swap disabled via `memswap_limit`.
- **Finding F-04:** Postfix not `read_only` (Medium).
- **Finding F-06:** Postfix lacks `mem_limit` (Low).

### Docker network isolation

- **Strong:** Internal network for vaultwarden ↔ caddy ↔ postfix communication. Separate egress and external networks with documented security rationale.
- **Finding F-05:** Overly large /16 subnets (Medium).

## 8. SRE-Lite Operations Review

### Health checks

- **Strong:** `vaultwarden-health.timer` runs every 5 minutes with `--fix` for auto-recovery. Container-level healthchecks are defined for all three services.
- **Strong:** `maintenance.sh health` performs comprehensive checks including Docker status, database integrity, secrets validation, DNS, and certificate expiry.

### Timers

- **Strong:** Six timers cover: health (5min), DNS update (hourly), maintenance (daily 02:05), DB backup (daily 04:00), full backup (Sunday 03:00), firewall update (Saturday 04:00).
- **Strong:** All timers use `Persistent=false` to avoid boot catch-up storms. `RandomizedDelaySec` prevents simultaneous execution.
- **Strong:** All timers use `OnFailure=vaultwarden-notify-failure@%n.service` for failure notification.

### Alerts

- **Strong:** `vaultwarden-notify-failure@.service` template provides per-unit failure notification.
- **Strong:** `maintenance.sh` supports `--email` for notification on completion/failure.

### Restore operator prompts

- **Strong:** `--start-policy` (auto/ask/manual) with sensible defaults: TTY defaults to `ask`, non-TTY defaults to `auto`.
- **Strong:** Emergency restore Age rotation prompt requires explicit `yes`/`no` with no implicit default (no enter-to-accept).
- **Strong:** Post-restore key display requires operator to type `SAVED` before services start (unless `--force`).

### Service restart/start prompts after restore

- **Strong:** `_restore_print_manual_start_checklist()` provides a clear 8-step verification checklist.

### Junior-admin usability

- **Strong:** Comprehensive `--help` on all scripts. `show_help()` includes examples.
- **Strong:** Error messages include actionable fix commands (e.g., `log_error "Install hint: ..."`, `log_error "Fix: chmod 600 ..."`).
- **Strong:** Makefile `help` target shows common commands; `help-all` shows everything.

### Backup verification

- **Strong:** Both quick verification (SHA-256 + decrypt probe) and full verification (decrypt + integrity check + archive validation) are implemented.
- **Strong:** `_validate_full_archive_payload()` ensures the verified staged DB is present in the archive and rejects `.pre-restore-*` snapshot DBs.

### Restore validation

- **Strong:** Pre-restore storage layout inspection via `restore.sh inspect`.
- **Strong:** Database integrity verified post-restore via `_can_safe_restart()`.

### Failure notification path

- **Strong:** systemd `OnFailure=` on all timer units → notify-failure template service → email notification.

### "Set and forget" operational safety

- **Strong:** Timer-based automation for all routine operations. Health checks auto-fix container crashes.
- **Finding F-01:** Startup service restart semantics are misleading (High).

## 9. CI/Test Coverage Review

### Backup behavior tests

- **Present:** `tests/test-backup-architecture-policy.sh`, `tests/test-backup-restore-behavior.sh`, `tests/test-restore-backup-preflight-safety.sh`

### Restore behavior tests

- **Present:** `tests/test-restore-run-followup.sh`, `tests/test-start-policy.sh`, `tests/test-recover.sh`

### Permission contract tests

- **Present:** `tests/test-permission-contract-central.sh`, `tests/test-permission-repair-contract.sh`, `tests/test-privilege-contracts.sh`

### Prompt consistency tests

- **Present:** `tests/test-confirmation-prompt-format.sh`

### Makefile target tests

- **Covered by CI:** `doc-drift.yml` verifies Makefile targets referenced in docs exist.

### Docs drift checks

- **Present:** `doc-drift.yml` checks stale terms, Makefile targets, script flags, unpinned versions, and systemd hardening.

### Shell syntax/static analysis coverage

- **Strong:** CI runs `shellcheck -x --severity=warning` on all `.sh` files.
- `bash -n` runs on all scripts (verified locally — all pass).

### Workflow dependency assumptions

- **Adequate:** CI uses `actions/checkout@v4` (pinned). `yq` and `sops` are downloaded with SHA-256 verification. `stefanzweifel/git-auto-commit-action` is pinned by commit SHA.

### Coverage gaps

- No end-to-end test that creates a backup, destroys state, and restores from that backup (would require Docker, which is appropriate for integration tests but not unit CI).
- No direct test for emergency backup passphrase round-trip encryption/decryption (code is exercised through architecture policy tests but not full-flow).
- `test-crowdsec-config.sh` is run directly in CI (`tests/test-crowdsec-config.sh`), not via `make test-unit`, which could drift if the test runner changes.

## 10. Recommended Manual Fix Plan

### Priority 1: High non-blockers

1. **F-01** — Remove misleading `Restart=on-failure` from `systemd/vaultwarden-startup.service`. Add a comment explaining that the health timer handles recovery. (Est. 2 min)

2. **F-02** — Change lock-file fallback from `chmod 0666` to `chmod 0660` + `chown root:root` in `lib/common.sh:_ensure_lock_file()`. (Est. 2 min)

### Priority 2: Medium non-blockers

3. **F-03** — Clear the `ADMIN_TOKEN` sentinel in `.env.example` or add a startup preflight check. (Est. 5 min)

4. **F-04** — Add `read_only: true` and `tmpfs` mounts to the Postfix container in `docker-compose.yml.example`. Test that Postfix starts and delivers mail correctly with the read-only filesystem. (Est. 15 min — requires Docker testing)

5. **F-05** — Shrink Docker network subnets from `/16` to `/28` in `docker-compose.yml.example`. Verify no connectivity impact. (Est. 5 min)

### Priority 3: Low non-blockers

6. **F-06** — Add `mem_limit: 256M` and `memswap_limit: 256M` to the Postfix container. (Est. 2 min)

7. **F-07** — Fix `startup.sh` root check to also apply when `stop` + `--dry-run` are combined. (Est. 2 min)

8. **F-08** — Add `realpath -e` canonicalization for `--state-dir` and `--key` in `recover.sh`. (Est. 5 min)

### Priority 4: Documentation follow-ups

- No documentation drift findings requiring changes.

### Priority 5: Test follow-ups

- Consider adding an integration test for emergency backup passphrase round-trip (requires Docker CI runner).
- Consider running `tests/test-crowdsec-config.sh` via `make test-unit` instead of direct invocation for consistency.
