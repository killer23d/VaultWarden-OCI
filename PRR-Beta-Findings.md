# Production Readiness Review — Beta Findings

Repository: `killer23d/VaultWarden-OCI`  
Branch audited: `Beta`  
Audit basis: code only for Waves 1–6; documentation read directly for Wave 7.

## 1. Executive Summary

I reviewed all 88 tracked repository files. No files from the requested PRR scope were missing. Files present in the repo but not explicitly named in the wave scope lists were also reviewed: `.gitattributes`, `.gitignore`, `VERSION`, `PRR-Beta.md`, and `edit-secrets.sh`.

### High-level result
- **Production readiness for the stated target profile (cloud-agnostic, junior-admin, set-and-forget): `🔴 Not ready yet`**
- The repo has strong fundamentals: centralised libraries, good quoting discipline, atomic file-write patterns in many places, layered backup verification, degraded-mode handling in Caddy, and broad documentation coverage.
- The biggest blockers are operational, not architectural:
  1. **systemd concurrency protection is broken** because services use `PrivateTmp=yes` while coordination relies on `/tmp/.vw_maintenance.lock`.
  2. **Systemd service identity is not cloud-agnostic**: multiple units are hard-coded to `ubuntu`, and the installer falls back to `ubuntu` too.
  3. **Backup/offsite behavior is incomplete**: remote retention is not enforced, and remote checksum/metadata sidecar upload failures are ignored.
  4. **Security posture can fail open** when Cloudflare CIDR fetches fail.
  5. **Several docs drifted from Makefile behavior**, especially health-related targets.

---

## 2. Wave 1 — Foundation Libraries (`lib/`)

**Scope status:** all expected `lib/*.sh` files were present. No missing files.

### Critical Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| — | — | No confirmed Critical issues in Wave 1 | — | — |

### Moderate Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `lib/config.sh` | 177-188 | `_set_env_var()` updates live env files with `sed -i` and appends directly | An interrupted write can leave `.env` partially updated or corrupted; this is risky for a junior-admin-managed system | Write to a same-directory temp file, validate it, then `mv` atomically |
| `lib/secrets.sh` | 126-146 | `decrypt_secret()` returns plaintext on stdout and relies on caller discipline | The API is easy to misuse later in a way that exposes secrets via command-line args or logs | Prefer file-descriptor or temp-file based handoff helpers for sensitive values, or add safe wrapper helpers for common use cases |
| `lib/docker.sh` | 37-50 | Compose project-name autodetection suppresses parse errors with `|| true` and silently falls back to a default label | On renamed Compose projects, health/status helpers can inspect the wrong containers while hiding the detection failure | Log parse failure explicitly and distinguish “fallback used” from “project confirmed” |

### Minor Issues

- `lib/email.sh:56-65,210-211,255-256,546` uses `mktemp -t`; acceptable on this Linux target, but it is less portable and less consistent than the project’s newer same-filesystem temp-file pattern.
- `lib/secrets.sh:149-155` unsets `SOPS_AGE_KEY_FILE` before logging the “expected AGE key”, so the log message is less actionable than intended.

### What Passed

- Library load guards are present across the `lib/` tree.
- Quoting discipline is consistently strong.
- Logging is centralised instead of reimplemented ad hoc.
- Crypto helpers use secure temp-file creation and atomic replacement patterns in several sensitive paths.
- External command checks are common and generally explicit.

---

## 3. Wave 2 — Backup & Restore Pipeline

**Scope status:** all expected files were present: `backup.sh`, `restore.sh`, `lib/backup-utils.sh`, `lib/storage.sh`, `utilities/backup-run.sh`, `utilities/restore-run.sh`, `utilities/setup-storage.sh`.

### Critical Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| — | — | No confirmed Critical issues in Wave 2 | — | — |

### Moderate Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `utilities/backup-run.sh` | 525-533 | Remote `.meta` and `.sha256` uploads are soft-failed with `|| true` | Offsite backups can be reported as successful while the metadata needed for fast integrity validation is missing remotely | Treat sidecar upload failure as a partial-failure state and surface it clearly (like current `exit 2` behavior for remote copy failure) |
| `utilities/backup-run.sh` | 437-565, 930-945, 1097-1099 | Retention is enforced locally only; no remote pruning exists | Remote storage can grow without bound even while local retention appears healthy | Add remote retention logic (`rclone delete`/`deletefile`/listing-based prune) that mirrors local policy |
| `utilities/backup-run.sh` + `utilities/restore-run.sh` | `backup-run.sh:741-759`; `restore-run.sh:1520-1552` | Full backups archive the repo root, but full restore intentionally does **not** restore `secrets/` or `*.sh` | “Full backup” is not a self-contained DR artifact; recovery still depends on the repo checkout and a separate recovery kit | Either rename/document the scope more explicitly or restore scripts/secrets from full archives behind an explicit operator confirmation |

### Minor Issues

- `backup.sh` and `restore.sh` are thin dispatchers only; that is good, but it means almost all operational correctness is concentrated in `utilities/backup-run.sh` and `utilities/restore-run.sh`.
- `utilities/backup-run.sh:1097-1099` logs local retention cleanup failure as warning-only; local growth is still possible if pruning keeps failing silently over time.
- `utilities/restore-run.sh:556-560` also soft-fails remote sidecar download; restore can proceed with reduced integrity context.

### What Passed

- Local backup locking exists and is explicit.
- Backups are encrypted and checksummed.
- Restore verifies `.sha256` before decryption when the sidecar exists (`utilities/restore-run.sh:1708-1724`).
- DB backups use SQLite’s online backup API rather than blind file copy.
- Full restores are staged/atomic instead of unpacking directly into the live tree.

---

## 4. Wave 3 — Setup, Startup & Runtime

**Scope status:** all expected files were present, including all `systemd/*` units.

### Critical Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `systemd/vaultwarden-health.service`, `systemd/vaultwarden-db-backup.service`, `systemd/vaultwarden-full-backup.service`, `utilities/maintenance-run.sh`, `utilities/maintenance-db-maint.sh` | `health.service:18,27`; `db-backup.service:18,28`; `full-backup.service:16,25`; `maintenance-run.sh:117-119`; `maintenance-db-maint.sh:221-222` | systemd units check `/tmp/.vw_maintenance.lock`, but the same units also set `PrivateTmp=yes` | The health and backup services will not reliably see the maintenance lock file created by maintenance jobs, so the intended “don’t overlap maintenance” safety gate is broken | Move coordination to a shared path such as `/run/lock/…` (already writable in units) and use a single flock-based lock instead of `/tmp` marker files |
| `systemd/vaultwarden-health.service`, `systemd/vaultwarden-db-backup.service`, `systemd/vaultwarden-full-backup.service`, `systemd/vaultwarden-dns-update.service`, `utilities/setup-systemd.sh` | `health.service:21-22`; `db-backup.service:22-23`; `full-backup.service:19-20`; `dns-update.service:21-22`; `setup-systemd.sh:191-197` | Multiple services are hard-coded to `User=ubuntu` / `Group=ubuntu`, and installer fallback also hard-codes `ubuntu` | This breaks the stated cloud-agnostic goal on non-Ubuntu hosts (`debian`, `ec2-user`, `opc`, etc.) and creates install-time/runtime failures for a junior admin | Template units with `SERVICE_USER`/`SERVICE_GROUP`, render them during install, and fail fast if the chosen identity is absent |

### Moderate Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `startup.sh` | 691-695 | Startup treats email consistency, plaintext override warnings, orphan cleanup, egress NAT, and DNS update as warn-only | Startup can finish “successfully” while outbound connectivity or DNS maintenance is already broken | Keep cosmetic warnings non-fatal, but promote network/bootstrap-critical failures to actionable degraded exit states |
| `utilities/setup-crowdsec.sh` | 151, 224-245, 313-316 | CrowdSec bootstrap uses live upstream installer paths (`curl | bash`, GitHub `releases/latest`, `go install ...@latest`) | This reduces reproducibility and increases supply-chain/change-drift risk for a “set and forget” deployment | Pin versions, verify checksums/signatures, and prefer repository-packaged installs over live `latest` lookups |

### Minor Issues

- `setup.sh:23-30` still uses `mktemp -t` for its top-level temp workdir; not a blocker on Linux, but inconsistent with the project’s newer project-local temp-workdir pattern.
- The runtime path is split across repo, `/opt/vaultwarden-scripts`, and `/etc/vaultwarden`; the design is workable, but it increases drift risk after `git pull` unless the admin remembers to reinstall the systemd payload.

### What Passed

- `setup.sh` and most setup utilities are idempotent-minded.
- Image pull helpers in `lib/docker.sh` have retry/backoff logic.
- Systemd units consistently use `OnFailure=vaultwarden-notify-failure.service`.
- Separate-volume support is structurally sound and implemented with drop-ins rather than unit file mutation.
- Startup performs a real post-start health path rather than stopping at `docker compose up -d`.

---

## 5. Wave 4 — Security, Secrets & Network

**Scope status:** all expected `utilities/secrets-*.sh`, `utilities/setup-firewall.sh`, and `crowdsec/*` files were present. Related file reviewed outside the strict scope because it is operationally coupled: `utilities/setup-crowdsec.sh`.

### Critical Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| — | — | No confirmed Critical issues in Wave 4 | — | — |

### Moderate Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `utilities/setup-firewall.sh` | 137-169 | If Cloudflare CIDR fetch fails, the script opens 80/443 to the world | A transient fetch failure weakens the origin protection model and may expose the real origin to direct traffic | Cache last-known-good CIDRs and fail closed (or require explicit operator override) instead of automatically broadening exposure |
| `utilities/setup-firewall.sh` | 189-197 | nftables conflicts are only warned about; the script still proceeds with iptables programming | On nftables-first hosts, the expected rules may not actually enforce the desired policy | Detect unsupported/mixed firewall state and fail fast unless the admin explicitly opts in |
| `utilities/setup-crowdsec.sh` | reviewed file; no allowlist bootstrap logic found | CrowdSec install/config flow does not automatically create an admin allowlist/whitelist | For a junior admin, self-lockout risk remains unless they discover and perform the manual whitelist step from the docs | Add an install-time prompt/flag for admin IP or CIDR allowlisting and write the CrowdSec whitelist automatically |

### Minor Issues

- `utilities/maintenance-update-firewall.sh:70-71` uses `mktemp -t`; not sensitive data, but inconsistent with the safer same-directory temp-file style used elsewhere.
- `crowdsec/profiles.yaml` is intentionally lean, but it leaves tuning/allowlisting burden to the operator rather than packaging a safe default for the stated junior-admin audience.

### What Passed

- Secret-edit/list/view/rotate utilities disable shell history (`HISTFILE=/dev/null`).
- Secret-edit/rotate workflows use backup-before-change and atomic replace patterns.
- Editor swap-file suppression is explicitly implemented for Vim-family editors.
- `utilities/setup-crowdsec.sh:597-608` does enable the **local** `crowdsec-firewall-bouncer`, so there is a local enforcement path even when Cloudflare bouncer integration is not enabled.
- Firewall setup handles IPv6, OCI FORWARD reject cleanup, and persistence via `netfilter-persistent`.

---

## 6. Wave 5 — Admin Experience, Caddy & Operational Completeness

**Scope status:** all expected files were present.

### Critical Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| — | — | No confirmed Critical issues in Wave 5 | — | — |

### Moderate Issues

| File | Line | Issue | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `caddy/Caddyfile`, `caddy/Caddyfile.degraded` | `Caddyfile:80-92`; `Caddyfile.degraded:77-89` | TLS blocks do not set an explicit minimum TLS version | Current behavior depends on Caddy defaults; that is less auditable and less future-proof than an explicit policy | Set `min_version tls1.2` or `tls1.3` explicitly in both TLS snippets |
| `dashboard.sh` | 427-428 | CrowdSec metrics menu item runs `"${REPO_ROOT}/sudo cscli metrics"` instead of `sudo cscli metrics` | The operator-facing dashboard contains a broken action in a core security menu | Fix the command string passed to `run_sudo_cmd` |

### Minor Issues

- `caddy/entrypoint.sh:154-155` permits `_` in `DOMAIN_NAME`; public DNS/TLS names with underscores are invalid in common production use, so the validator is more permissive than the real deployment requirements.
- `Makefile` itself is in good shape; the bigger admin-experience drift is in documentation, not in the target definitions.

### What Passed

- `Makefile` has a real help target and a broad `.PHONY` declaration.
- Status/timer/schedule targets exist.
- Maintenance scripts have dry-run support and plain-English output.
- `utilities/maintenance-db-maint.sh:94-112` takes a pre-maintenance DB safety backup.
- Caddy has strong security headers and explicit WebSocket handling for `/notifications/hub`.
- Degraded-mode handling for Caddy log-path failures is thoughtfully implemented.

---

## 7. Wave 6 — Synthesis

### Prioritized Fix List

1. **Replace `/tmp/.vw_maintenance.lock` coordination with a shared `/run/lock` flock-based lock across maintenance, health, and backup paths.** This is the highest-impact operational bug because it invalidates the intended no-overlap safety model under systemd hardening.
2. **Remove the hard-coded `ubuntu` service identity.** Parameterize `User=`/`Group=` at install time and stop falling back to `ubuntu` in `setup-systemd.sh`.
3. **Make offsite backup integrity first-class.** Fail or explicitly degrade when remote `.meta` / `.sha256` sidecars do not upload, and add remote retention pruning.
4. **Change firewall Cloudflare CIDR handling from fail-open to cached/fail-closed behavior.** A fetch failure should not silently widen origin exposure.
5. **Make `.env` updates atomic everywhere.** Start with `lib/config.sh` and the similar updater in `utilities/setup-crowdsec.sh`.
6. **Pin CrowdSec bootstrap artifacts and stop using live `latest` installers.** This reduces drift and supply-chain risk.
7. **Clarify or change full-backup/full-restore scope.** Either restore scripts/secrets from full archives or rename/document the current behavior much more explicitly.
8. **Add explicit TLS minimum version settings in both Caddyfiles and fix the dashboard CrowdSec metrics command.**
9. **Repair documentation drift around Makefile health targets and undocumented config fields.**

### Production Readiness Verdict

## 🔴 Not production-ready for the declared target profile

Why:
- The current build is **close** in many subsystems, but the broken maintenance/backup/health concurrency gate and the hard-coded Ubuntu service user are release blockers for a cloud-agnostic “set and forget” deployment.
- Security and operability are also weakened by fail-open firewall behavior and incomplete offsite-backup lifecycle management.

### Cloud-Agnostic Master Gap Table

| Gap | Evidence | Impact | Severity | Suggested Fix |
|---|---|---|---|---|
| Service user hard-coded to Ubuntu | `systemd/*` units set `User=ubuntu`; `utilities/setup-systemd.sh:191-197` falls back to `ubuntu` | Non-Ubuntu hosts fail or require manual surgery | Critical | Render units with discovered/configured service identity |
| Firewall backend assumes iptables is authoritative | `utilities/setup-firewall.sh:189-197` only warns when nftables is active | Mixed/nft-first systems may not enforce expected policy | Moderate | Support nftables explicitly or fail fast on mixed mode |
| CrowdSec install path depends on live upstream/latest content | `utilities/setup-crowdsec.sh:151,224-245,313-316` | Reproducibility and trust posture degrade over time | Moderate | Pin versions and verify artifacts |
| Origin restriction can broaden on fetch failure | `utilities/setup-firewall.sh:137-169` | Weakens Cloudflare-origin isolation | Moderate | Cache last-known-good CIDRs and require explicit override for fail-open |
| Service/runtime paths are split across repo, `/opt`, and `/etc` | installer design and systemd payload model | Drift after `git pull` is easy for a junior admin | Moderate | Add a clear post-update sync command/check and surface split-brain warnings prominently |

### Beta Architecture Change Risk Assessment

| Change Area | Risk | Assessment |
|---|---|---|
| Thin wrapper + utility split | Low | Good direction; keeps entry points simple and concentrates logic where it can be tested and reviewed |
| Central `lib/` abstraction | Low | Strong maintainability gain; biggest remaining risk is consistency in env-file mutation helpers |
| Systemd-first scheduling | Medium | Better than cron operationally, but the current hardening/locking interaction introduced a real concurrency bug |
| Backup/restore redesign | Medium | Verification and staging are strong, but the local/remote lifecycle and “full restore” semantics still need tightening |
| CrowdSec migration | Medium | Modernized stack, but install reproducibility and admin allowlisting are not yet “set and forget” |
| Separate-volume support | Medium | Good design, but it increases path/ownership/unit-drop-in complexity and needs careful documentation |

---

## 8. Wave 7 — Documentation Audit

### Document Health Summary

| Document | Health | Key Issues |
|---|---|---|
| `README.md` | Good | Utility count is stale; otherwise strong overview |
| `RUNBOOK.md` | Good | Operational commands mostly align with code |
| `CHANGELOG.md` | Good | Historical fail2ban references are appropriate, not stale |
| `utilities/README.md` | Good | Useful utility inventory |
| `docs/ADVANCED-CUSTOMIZATION.md` | Good | Helpful advanced overrides guidance |
| `docs/API.md` | Good | No major drift found |
| `docs/BACKUP-RESTORE.md` | Fair | Could more clearly emphasize what full restore intentionally does **not** restore |
| `docs/BOOTSTRAP_KEY_RECOVERY.md` | Fair | Age-key lifecycle is correct but still cognitively heavy for a junior admin |
| `docs/CONFIGURATION.md` | Fair | `INCOMPLETE_2FA_TIME_LIMIT` is shown but not explained |
| `docs/DEPLOYMENT.md` | Good | Mostly accurate |
| `docs/EMAIL.md` | Fair | “Stage” terminology conflicts with “Tier” elsewhere |
| `docs/MIGRATION.md` | Good | No major drift found |
| `docs/OPERATIONS.md` | Fair | Health target examples drift from Makefile behavior |
| `docs/SCRIPTS.md` | Fair | Health target mapping drifts from Makefile behavior |
| `docs/SECURITY.md` | Good | No critical drift found |
| `docs/TROUBLESHOOTING.md` | Good | Legacy cron note handled appropriately |
| `docs/VOLUME-MIGRATION.md` | Good | No major drift found |

### Critical Gaps

| Document | Line | Gap | Why It Matters | Suggested Fix |
|---|---:|---|---|---|
| `docs/CONFIGURATION.md` | 315 | `INCOMPLETE_2FA_TIME_LIMIT=3` is shown with no explanation | Junior admins cannot tell whether it is a VaultWarden setting, a project setting, or safe to change | Add a short explanatory row/paragraph for the variable |
| `docs/SCRIPTS.md` | 732-734 | Health-related Make targets are mapped to the wrong commands/descriptions | Operators following the reference will run the wrong checks | Update the table to match the actual Makefile |
| `docs/OPERATIONS.md` | 811-815 | Health examples drift from the actual Makefile behavior | Day-2 operations guidance is inaccurate in a high-touch area | Rewrite the health examples to match `make health`, `make health-quick`, `make health-report`, and `make health-email` |

### Accuracy Failures

| Document | Line | Documentation Claim | Code Reality | Impact |
|---|---:|---|---|---|
| `docs/SCRIPTS.md` | 733 | `make health-quick` => `./maintenance.sh health --comprehensive` | `Makefile:406-408` runs `./maintenance.sh health --quiet` | Admins are told the opposite of what the target does |
| `docs/SCRIPTS.md` | 734 | `make health-email` => `./maintenance.sh health --report` | `Makefile:414` makes `health-email` an alias of `test-email` | Admins are told it is a health-report target when it is actually an email test |
| `docs/OPERATIONS.md` | 812-815 | `health-quick` is described as both fast sanity check and comprehensive check; `health-email` is “Comprehensive + email” | `Makefile:406-414` defines `health-quick` as quiet health and `health-email` as email-test alias | Operational runbooks are contradictory |
| `README.md` | 308 | “17 standalone administrative and engine scripts” | `utilities/` currently contains 24 shell scripts | Inventory summary is stale and understates repo surface area |
| `docs/CONFIGURATION.md` | 315 | Variable is shown with no explanation | No explanatory text accompanies it | Operator confusion / undocumented knob |

### Flow & Friction Issues

- **Age-key lifecycle is still mentally expensive**: the repo-local key path and `/etc/vaultwarden/age-key.txt` path are both valid in different phases, but that lifecycle is easy to lose track of.
- **Email terminology is inconsistent**: `README.md` / `docs/CONFIGURATION.md` use **Tier**, while `docs/EMAIL.md` also uses **Stage**.
- **CrowdSec allowlisting is documented, but not surfaced early enough** for the stated junior-admin audience.
- **Health target naming drift** makes routine operational actions less trustworthy than they should be.

### Stale References

- **No missing scope docs were found.**
- **No live user docs still depend on Fail2Ban as an active component.** The references in `CHANGELOG.md` are historical and appropriate.
- **Legacy `cron-setup.sh` references are handled correctly as migration notes**, not stale active instructions (`docs/OPERATIONS.md:558`, `docs/DEPLOYMENT.md:197`, `docs/TROUBLESHOOTING.md:1039`, `docs/CONFIGURATION.md:403`, `docs/SCRIPTS.md:557`).
- **No stale Alpha branch references were confirmed in the live docs set.**

### Documentation Completeness Verdict

## 🟡 Mostly complete, but operationally drifted

Strengths:
- Coverage is broad.
- Cross-linking is generally good.
- Security, deployment, and backup concepts are documented in useful depth.

Blocking doc cleanup before calling the repo “junior-admin ready”:
- Fix health-target drift in `docs/SCRIPTS.md` and `docs/OPERATIONS.md`.
- Document `INCOMPLETE_2FA_TIME_LIMIT`.
- Refresh stale inventory counts in `README.md`.
- Consider adding a short “admin allowlist yourself in CrowdSec” step to the deployment/operations happy path.
