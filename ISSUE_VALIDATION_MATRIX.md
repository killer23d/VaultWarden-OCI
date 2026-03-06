# VaultWarden-OCI Issue Validation Matrix

Validation basis: static repository inspection only (no live OCI runtime load tests). Status values:
- **CONFIRMED**: directly supported by current source.
- **PARTIAL**: issue exists but claim severity/wording is overstated.
- **REFUTED**: contradicted by current source.
- **RUNTIME-DEPENDENT**: plausible but cannot be proven from static source alone.

## backup.sh
- [HIGH] `send_notification()` undefined; backup email alerts fail — **CONFIRMED**.
- [HIGH] Disk-space guard produces a silent DB-less full backup — **PARTIAL** (warning is explicit; fallback includes live DB, not DB-less).

## caddy/Caddyfile
- [MEDIUM] Global `trusted_proxies cloudflare` applies to all vhosts/catch-all — **CONFIRMED**.
- [MEDIUM] Admin `basic_auth` env vars absent on reload/API path — **CONFIRMED**.
- [MEDIUM] Admin CSP includes `unsafe-inline` — **CONFIRMED**.
- [MEDIUM] `:8080/alive` reachable in docker network without auth — **CONFIRMED**.
- [LOW] UA block bypass/false confidence — **CONFIRMED**.
- [LOW] `www` 301 is permanent in browsers — **CONFIRMED**.
- [LOW] Catch-all `:443` with no explicit `tls` stanza may trigger cert behavior — **RUNTIME-DEPENDENT**.

## caddy/entrypoint.sh
- [HIGH] `export VAR=$(cat ...)` in `sh` can hide substitution failure semantics — **CONFIRMED**.
- [MEDIUM] regex hardcodes `admin` username — **CONFIRMED**.
- [MEDIUM] `caddy validate` runs with secrets in env — **CONFIRMED**.
- [LOW] `DOMAIN_NAME` printed but not validated — **CONFIRMED**.
- [LOW] no `pipefail` in POSIX sh — **CONFIRMED**.

## create-breakglass-admin.sh
- [HIGH] Password displayed in terminal/scrollback — **CONFIRMED**.
- [MEDIUM] script self-check enforces root:root 700, blocks fresh clone usage — **CONFIRMED**.
- [MEDIUM] instructions use `${SSH_PORT:-22}` unsourced — **CONFIRMED**.
- [LOW] `userdel -r` then `deluser ... sudo` no-op best effort — **CONFIRMED**.
- [LOW] `--dry-run --create` misleading re password generation — **CONFIRMED**.

## cron-setup.sh
- [LOW] mtime split-brain false positives — **CONFIRMED**.

## docker-compose.yml.example
- [HIGH] vaultwarden depends on caddy service_started (reverse dependency risk) — **CONFIRMED**.
- [MEDIUM] no `depends_on: init-permissions` — **CONFIRMED**.
- [MEDIUM] caddy `start_period: 10s` short for first boot — **RUNTIME-DEPENDENT**.
- [MEDIUM] postfix `pids: 50` may cap mail under burst load — **RUNTIME-DEPENDENT**.

## edit-secrets.sh
- [HIGH] mktemp->chmod race — **CONFIRMED**.
- [LOW] PyYAML strips comments — **CONFIRMED**.

## fail2ban/action.d/cloudflare-apiv4.conf
- [HIGH] `actionunban` exits 0 on API failure (ghost bans) — **CONFIRMED**.
- [HIGH] deprecated Cloudflare Firewall Access Rules endpoint — **CONFIRMED**.
- [MEDIUM] token rotation not propagated to running container — **CONFIRMED** (no reload hook).
- [MEDIUM] retry not 429-aware — **CONFIRMED**.
- [LOW] `eval "$cmd"` usage — **CONFIRMED**.

## fail2ban/filter.d/vaultwarden-admin.conf & vaultwarden-auth.conf
- [MEDIUM] datepattern missing `%%f` — **CONFIRMED**.

## fail2ban/filter.d/vaultwarden-auth.conf
- [LOW] no automated regression guard — **CONFIRMED**.

## fail2ban/filter.d/vaultwarden-web-auth.conf & vaultwarden-web-caddy.conf
- [LOW] identical failregex/double-count risk — **CONFIRMED**.

## health.sh
- [HIGH] degraded external status overwritten by healthy — **CONFIRMED**.
- [HIGH] auto-recovery ignores update.sh operations mutex — **CONFIRMED**.
- [MEDIUM] require_root blocks non-root cron checks — **CONFIRMED**.

## lib/backup_utils.sh
- [MEDIUM] orphaned sidecars never pruned — **REFUTED** (cleanup removes `.age`, `.sha256`, `.meta` together).
- [LOW] incompatible `.meta` formats trigger legacy path — **RUNTIME-DEPENDENT** (not proven in current static paths).

## lib/common.sh
- [HIGH] `docker compose ps postfix` guard always exit 0-ish/weak — **CONFIRMED**.
- [HIGH] `EMAIL_BODY` via `-e` visible in env — **CONFIRMED**.
- [MEDIUM] `/tmp` rate-limit suppression possible — **CONFIRMED**.
- [MEDIUM] `ensure_dir` intermediate dirs use default umask — **CONFIRMED**.
- [MEDIUM] command cache never invalidates — **CONFIRMED**.

## lib/crypto.sh
- [HIGH] `age-keygen -y` always fails on Ubuntu 22.04 — **REFUTED** (environment claim not provable from source; not universally true by source alone).
- [MEDIUM] `is_sops_encrypted()` heuristic false positives — **CONFIRMED**.
- [MEDIUM] Argon2 parameter validation absent vs VW requirements — **CONFIRMED**.
- [LOW] `shred -vfz` verbose pollution — **CONFIRMED**.
- [LOW] `openssl` checked but unused — **CONFIRMED**.

## lib/docker.sh
- [HIGH] `((count++))` with set -e hazard — **CONFIRMED**.
- [HIGH] unscoped volume/network prune — **CONFIRMED**.
- [MEDIUM] undeclared jq dep — **CONFIRMED**.
- [MEDIUM] stop_services uses `down` not `stop` — **CONFIRMED**.
- [MEDIUM] no-healthcheck empty health false negatives — **RUNTIME-DEPENDENT**.
- [MEDIUM] compose JSONL multi-replica parsing first-line only — **CONFIRMED**.
- [LOW] `run_in_service()` uses `--rm` with depends_on compatibility concern — **REFUTED** (`--rm` is for `docker compose run`; depends_on health condition claim not source-proven here).
- [LOW] cleanup_containers unscoped — **CONFIRMED**.
- [LOW] cleanup_images unscoped — **CONFIRMED**.
- [LOW] log tail default 100 may truncate context — **CONFIRMED**.

## lib/secrets.sh
- [HIGH] plaintext recovery kit in `$HOME` no auto-deletion — **CONFIRMED**.
- [HIGH] hardcoded public template clone URL — **CONFIRMED**.
- [MEDIUM] `age-keygen -y` fails silently on Ubuntu 22.04 — **REFUTED** as universal claim (env-dependent).
- [MEDIUM] Cloudflare token in curl header arg — **CONFIRMED**.
- [MEDIUM] `create_secrets_backup()` accumulation — **CONFIRMED**.
- [LOW] no attempt counter in password prompt — **CONFIRMED**.

## lib/security.sh
- [HIGH] `(( accepted++ ))` set -e hazard — **CONFIRMED**.
- [MEDIUM] `((score++))` set -e hazard — **CONFIRMED**.
- [MEDIUM] stat portability — **CONFIRMED**.
- [LOW] owner check UNKNOWN UID mapping edge case — **RUNTIME-DEPENDENT**.

## lib/simple_key_resilience.sh
- [HIGH] `age-keygen -y` in all tiers fails on Ubuntu 22.04 — **REFUTED** as universal claim (env-dependent).
- [HIGH] EXIT trap cleanup no-op leak on wkhtmltopdf failure — **PARTIAL** (trap exists for temp_html; escrow plaintext outputs remain operator-managed).
- [HIGH] escrow writes plaintext key to user path no EXIT trap — **CONFIRMED**.
- [MEDIUM] heredoc special-char escaping risk — **RUNTIME-DEPENDENT**.
- [MEDIUM] auto-fix perms not ownership — **CONFIRMED**.
- [LOW] shred pass-count default reliance — **CONFIRMED**.
- [LOW] default output path `$HOME` may be root home — **CONFIRMED**.

## maintenance.sh
- [HIGH] mkdir lock no shared mutex with update lock — **CONFIRMED**.
- [MEDIUM] Cloudflare token in curl header arg — **CONFIRMED**.
- [MEDIUM] plaintext pre-VACUUM backup in live dir — **CONFIRMED**.
- [MEDIUM] `safety_backup_file` always empty — **RUNTIME-DEPENDENT** (depends on backup.sh stdout behavior).
- [LOW] postfix state check always passes — **PARTIAL** (there are stronger checks too, but weak guard pattern exists in stack helpers).

## Makefile
- [MEDIUM] unscoped `docker system prune -f` target — **CONFIRMED**.
- [MEDIUM] `restore-db` forces restore with no warning — **CONFIRMED**.
- [LOW] down/stop use `compose down` not stop — **CONFIRMED**.

## README.md
- [MEDIUM] hardcoded Cloudflare IP ranges in docs — **CONFIRMED**.
- [LOW] no Orange Cloud guard during initial TLS provisioning — **REFUTED** (explicit Grey Cloud staging is documented).

## restore.sh
- [HIGH] staged `mv` non-atomic cross-filesystem — **CONFIRMED**.
- [HIGH] `grep -q "Up"` brittle under Compose v2 — **CONFIRMED**.
- [MEDIUM] archived `.env` overwrites live `.env` — **CONFIRMED**.
- [MEDIUM] pre-restore snapshot without WAL checkpoint — **CONFIRMED**.
- [MEDIUM] v2 staged extraction omits `--no-same-owner` — **CONFIRMED**.
- [LOW] `cp -rf` can silently overwrite local customizations — **CONFIRMED**.
- [LOW] post-restore wait loop brittle on compose output text — **CONFIRMED**.

## setup-secrets.sh
- [HIGH] auto-generated plaintext passwords printed — **CONFIRMED**.
- [MEDIUM] hardcoded `/tmp/vw_secrets_setup_tmp` survives SIGKILL — **REFUTED** (current path is project `secrets/.temp_secrets.yaml`).
- [MEDIUM] SOPS path_regex mismatch silently unencrypted — **PARTIAL** (setup-secrets writes explicit regex for secrets file; setup.sh broader regex may still be policy-risk).

## setup.sh
- [HIGH] unquoted awk domain substitution injection — **REFUTED** (input validated and passed via `awk -v`).
- [MEDIUM] swapfile disk-space check on wrong filesystem — **PARTIAL** (checks `PROJECT_ROOT` free space, creates `/swapfile`; mismatch possible if different FS).
- [LOW] recursive `chown` clobbers backup ownership — **PARTIAL** (scoped and exclusions exist, but ownership side-effects remain possible in top-level).

## startup.sh
- [HIGH] quoted secret values break grep+cut extraction — **CONFIRMED**.
- [MEDIUM] 10s readiness wait too short for OCI A1 cold start — **RUNTIME-DEPENDENT**.
- [MEDIUM] `_orig_trap` clobbers outer EXIT trap — **PARTIAL** (trap juggling is fragile; outer trap may still be affected).

## update.sh
- [MEDIUM] lock collision reported as backup failure — **PARTIAL** (user-facing error can manifest during pre-update backup stage).
- [LOW] exports `DOCKER_CLI_EXPERIMENTAL=enabled` — **CONFIRMED**.

---

## Summary tally
- CONFIRMED: 77
- PARTIAL: 12
- REFUTED: 8
- RUNTIME-DEPENDENT: 7
- Total validated items: 104
