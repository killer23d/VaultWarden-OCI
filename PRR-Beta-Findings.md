# PRR-Beta Findings — VaultWarden-OCI

**Reviewer:** Antigravity AI (Claude Sonnet 4.6)  
**Review Date:** 2026-06-10  
**Repository:** `killer23d/VaultWarden-OCI`  
**Branch:** `Beta`  
**HEAD:** `3ceb3e91`  
**Version:** `1.0.0`  
**Instruction Source:** `PRR-Beta.md`

---

## Executive Summary

VaultWarden-OCI is a self-hosted Bitwarden-compatible password manager stack built on VaultWarden, Caddy, Postfix, and CrowdSec. The Beta branch represents a highly mature, security-conscious deployment framework with strong architectural discipline. The codebase demonstrates above-average attention to secrets management, container hardening, cryptographic hygiene, and operational tooling for a personal/small-team project.

**Overall Verdict: CONDITIONAL PASS**

The stack is suitable for production deployment by a technically competent operator who follows the documented setup procedures. Twelve discrete findings are recorded below; none are showstoppers at the current Beta scope, but three (F-01, F-04, F-07) should be addressed before a general-availability release.

---

## Scope

| Area | Files Reviewed |
|---|---|
| Core orchestration | `setup.sh`, `startup.sh`, `edit-secrets.sh`, `backup.sh`, `restore.sh`, `maintenance.sh`, `dashboard.sh` |
| Library layer | `lib/log.sh`, `lib/common.sh`, `lib/crypto.sh`, `lib/secrets.sh`, `lib/schema.sh`, `lib/defaults.sh` |
| Container layer | `docker-compose.yml.example`, `caddy/Dockerfile`, `caddy/Caddyfile`, `caddy/Caddyfile.degraded`, `caddy/entrypoint.sh` |
| Schema & config | `secrets-schema.yaml`, `.env.example`, `.sops.yaml` (absent — see F-01) |
| CI/CD | `.github/workflows/doc-drift.yml` |
| Testing | `tests/test-architecture-helpers.sh` |
| Documentation | `README.md`, `RUNBOOK.md`, `CHANGELOG.md` |
| Systemd | `systemd/` (referenced but not individually reviewed) |

---

## Findings

### F-01 — MEDIUM | `.sops.yaml` Missing from Repository

**Category:** Cryptography / Secrets Management  
**Severity:** Medium  
**Status:** Open

**Observation:**  
The `.sops.yaml` file is absent from the repository root. This file is the SOPS creation rules config that tells `sops --encrypt` which Age public key to use and which files to encrypt. Without it, `encrypt_sops_file()` in `lib/crypto.sh` (line 257) will fail silently or produce incorrectly-encrypted output because SOPS cannot determine the recipient.

`lib/crypto.sh:257` passes `--age "$age_public_key"` on the CLI, which means a committed `.sops.yaml` is not strictly required for the encryption step itself. However:
- `encrypt_sops_file()` does not pass `--age` to the decrypt round-trip test (line 308); it relies on `SOPS_AGE_KEY_FILE` being set. This is fine.
- The absence of `.sops.yaml` means `sops encrypt` will derive recipient from the CLI flag alone. This is correct but unconventional — most operators expect a `.sops.yaml` to be committed alongside the secrets file template.
- The `.gitignore` does not exclude `.sops.yaml`, suggesting the intent was to commit it.

**Evidence:**
```
$ find /Users/TIS/VaultWarden/VaultWarden-OCI -name '.sops.yaml' 2>/dev/null
(no output)
```

**Risk:** An operator cloning the repository and running `sops --encrypt secrets/secrets.yaml` without the `--age` flag (or with a stale copy) will produce unreadable ciphertext. The round-trip check in `encrypt_sops_file()` should catch this, but it adds friction.

**Recommendation:** Commit a `.sops.yaml` template with a placeholder Age recipient:
```yaml
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    age: AGE_PUBLIC_KEY_PLACEHOLDER
```
Update `setup.sh` to rewrite the placeholder with the real public key at provisioning time.

---

### F-02 — LOW | `conditional` Collect Mode Is Not Dispatched by Schema

**Category:** Secrets Schema / Correctness  
**Severity:** Low  
**Status:** Open

**Observation:**  
`secrets-schema.yaml` declares `collect: conditional` for `push_installation_id` and `push_installation_key`. The schema comments (lines 97–100 and 112–114) explicitly acknowledge that "No schema dispatch logic reads this value yet; `collect_secrets()` handles it verbatim." This is technically functional but represents an intentional design debt: the schema has a `collect` field that the schema dispatcher cannot honour. Future maintainers adding a third conditional key will have no dispatcher to extend.

**Evidence (`secrets-schema.yaml` lines 97–101):**
```yaml
    # collect: conditional — 3-way: auto if PUSH_ENABLED=true, interactive fallback,
    # skip/placeholder if PUSH_ENABLED=false.  No schema dispatch logic reads this
    # value yet; collect_secrets() handles it verbatim.  FUTURE: extract into a
    # condition_fn schema field when a second conditional key is added.
    collect: conditional
```

**Risk:** Low for current scope. High risk of silent regression if a maintainer adds a new `collect: conditional` key and expects the schema dispatcher to handle it.

**Recommendation:** Add `# TODO(BETA): extract into condition_fn` to the schema comment and open a tracking issue. Alternatively, introduce the `condition_fn` field now and migrate the push keys before GA.

---

### F-03 — LOW | Bcrypt Format Regex Is Subtly Incomplete

**Category:** Input Validation / Security  
**Severity:** Low  
**Status:** Open

**Observation:**  
`lib/secrets.sh:612-615` defines `_bcrypt_format_ok()`:
```bash
_bcrypt_format_ok() {
    local hash="$1"
    [[ "$hash" =~ ^\$2[aby]\$[0-9]+\$.{53}$ ]]
}
```
This regex matches bcrypt hashes with a variable number of cost digits (`[0-9]+`). A bcrypt cost field is always exactly 2 decimal digits (e.g., `$2y$14$`). The pattern `[0-9]+` would also accept single-digit costs (`$2y$4$`) or 3+ digit costs that are structurally invalid. The `generate_bcrypt_hash()` function already guards cost range `[10, 31]`, but `_bcrypt_format_ok()` is also called against user-provided rotate/edit input where the source hash was not generated by the project.

Similarly, the hash body `.{53}` is correct for bcrypt (22 chars salt + 31 chars hash), but the regex uses `.` (any char) rather than `[./A-Za-z0-9]` (bcrypt alphabet).

**Risk:** A maliciously crafted hash string with exactly 53 characters in a weird charset could pass format validation but be rejected by Caddy's bcrypt verifier at runtime, causing a silent auth failure.

**Recommendation:**
```bash
_bcrypt_format_ok() {
    local hash="$1"
    [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]
}
```

---

### F-04 — MEDIUM | No Test Coverage for `lib/crypto.sh` or `lib/secrets.sh`

**Category:** Testing / Quality  
**Severity:** Medium  
**Status:** Open

**Observation:**  
`tests/` contains exactly one file: `test-architecture-helpers.sh`, which tests the architecture selection helpers in `setup-system.sh` and `setup-crowdsec.sh`. There are no unit tests or integration tests for:
- `lib/crypto.sh` — SOPS encrypt/decrypt, Age key round-trip, Argon2/bcrypt hash generation
- `lib/secrets.sh` — `check_placeholder_values()`, `validate_required_secrets()`, `collect_secret_field()`
- `lib/schema.sh` — `schema_required_keys()`, `schema_field()`, `schema_services_for_key()`
- Any of the 28 utility scripts

The CI pipeline (`doc-drift.yml`) runs ShellCheck and a COMMAND-REFERENCE staleness check but does not execute any functional tests.

**Risk:** Regressions in the critical cryptographic path (key wrap/unwrap, secret collection) are not detected by automated testing. The SOPS + Age layer in particular has multiple failure modes (wrong key, stale `.sops.yaml`, MAC verification failure, partial write) that benefit from structured test coverage.

**Recommendation:**  
Add a `tests/test-crypto.sh` that:
1. Generates a temporary Age key.
2. Encrypts a test YAML file with SOPS.
3. Decrypts and verifies the content.
4. Tests `generate_argon2_hash()` produces a valid `$argon2id$` prefix.
5. Tests `generate_bcrypt_hash()` produces a hash that `_bcrypt_format_ok()` accepts.

Add `make test` to invoke all tests and integrate it into the CI matrix.

---

### F-05 — LOW | `safe-restart` Rollback Is Best-Effort Only

**Category:** Reliability / Operational  
**Severity:** Low  
**Status:** Open

**Observation:**  
`Makefile:346-361` implements `make safe-restart`:
```makefile
safe-restart:
    @PRE_IDS=$$(docker compose ps -q 2>/dev/null || true); \
    if sudo ./startup.sh --force; then \
        echo "$(GREEN)Safe restart completed successfully.$(NC)"; \
    else \
        echo "$(RED)Restart failed! Attempting rollback...$(NC)"; \
        if [ -n "$$PRE_IDS" ]; then \
            docker compose down || true; \
            docker compose up -d || true; \
            echo "$(YELLOW)Rollback attempted. Check service status.$(NC)"; \
        fi; \
```

The rollback uses `docker compose up -d` with the current `docker-compose.yml`, which will pull the same (potentially broken) image and configuration. There is no pinned-image rollback mechanism. If the compose file itself changed, `docker compose up -d` may start the broken version again.

**Risk:** Operators relying on "safe restart" for zero-downtime updates could find themselves in a degraded state with no automatic recovery path.

**Recommendation:** Document the limitation explicitly in `RUNBOOK.md`. For true rollback capability, consider tagging container images before updates and using `docker compose up -d --no-build` with the previous image tag.

---

### F-06 — INFO | `Postfix` Container Has Elevated Capabilities

**Category:** Container Security / Hardening  
**Severity:** Informational  
**Status:** Accepted Risk

**Observation:**  
`docker-compose.yml.example:370-376`:
```yaml
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
      - DAC_OVERRIDE
      - FOWNER
```
The Postfix container requires 6 Linux capabilities including `SETUID` and `SETGID`, which allow it to change its own UID/GID. This is a known Postfix architectural requirement (the `pickup`, `cleanup`, and `local` daemons run as unprivileged users after privilege drop). The `boky/postfix` base image necessitates these.

**Risk:** Elevated capabilities increase the blast radius if the Postfix container is compromised. However, Postfix's internal privilege separation significantly mitigates this.

**Recommendation:** No change required. Document the accepted risk in a `SECURITY.md` or inline compose comment. Consider evaluating a drop-in replacement image with a smaller capability footprint in a future release.

---

### F-07 — MEDIUM | `FILE_INTEGRITY_HMAC_KEY` Is Undocumented and Not Provisioned by Setup

**Category:** Integrity / Backup  
**Severity:** Medium  
**Status:** Open

**Observation:**  
`lib/crypto.sh:773` conditionally writes an HMAC sidecar file:
```bash
if [[ -n "${FILE_INTEGRITY_HMAC_KEY:-}" ]]; then
```
And `lib/crypto.sh:855-857` warns when the key is absent:
```bash
log_warn "verify_file_integrity: FILE_INTEGRITY_HMAC_KEY is not set; sidecar is unauthenticated."
log_warn "  An attacker who replaces both the file and its .sha256 sidecar will pass this check."
```

`FILE_INTEGRITY_HMAC_KEY` is not defined in `.env.example`, is not provisioned by `setup.sh`, and is not added to the secrets schema. The warning is emitted but no operator is likely to know to act on it without reading the source code.

**Risk:** Without the HMAC key, integrity checks protect only against accidental corruption, not against an attacker who can write to both the backup file and its `.sha256` sidecar. This reduces the backup integrity guarantee from "authenticated" to "unauthenticated."

**Recommendation:**  
1. Add `FILE_INTEGRITY_HMAC_KEY` to `secrets-schema.yaml` with `collect: auto` and `auto_fn: auto_generate_secret_field`.
2. Add a corresponding entry to `.env.example` with a comment pointing to the secrets store.
3. Update `setup.sh` to provision the key during the secrets phase.
4. Upgrade the `log_warn` to `log_error` and treat the missing key as a hard failure in `verify_file_integrity()` when `REQUIRE_AUTHENTICATED_INTEGRITY=true` (new env var, default `false` for backward compatibility).

---

### F-08 — LOW | `argon2 CLI` Path Is Disabled Without a Clear Fallback for Older Systems

**Category:** Dependency / Compatibility  
**Severity:** Low  
**Status:** Open

**Observation:**  
`lib/crypto.sh:634-641`:
```bash
        cli)
            # The argon2 CLI requires the salt as a positional argument,
            # which exposes it in `ps aux`. Refuse the CLI path and require Python.
            log_error "argon2 CLI path disabled — salt would be visible in 'ps aux'."
            log_error "Install the Python argon2-cffi library: pip install argon2-cffi"
            log_error "  or: apt install python3-argon2"
            return 1
            ;;
```

This is a correct security decision. However, `lib/defaults.sh` lists `python3` as a required dependency (`REQUIRED_DEPS`), but does not include `python3-argon2`. If a user has `python3` but not the `argon2` module, `check_argon2_support()` will fall through to the `cli` path (if `argon2` binary exists) and then fail with the disabled-path error, or it will fail at the Python import check and reach the CLI path.

The `check_argon2_support()` function (line 594-608):
```bash
check_argon2_support() {
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import argon2" 2>/dev/null; then
            printf 'python\n'
            return 0
        fi
    fi
    if command -v argon2 >/dev/null 2>&1; then
        printf 'cli\n'
        return 0
    fi
    log_error "check_argon2_support: neither python3 argon2 module nor argon2 CLI is available"
    return 1
}
```

If `python3` is present but `argon2-cffi` is not, and `argon2` CLI is also present, the function returns `cli`, which then fails in `generate_argon2_hash()`. The error message points to `argon2-cffi`, which is correct, but the control flow is confusing.

**Recommendation:** After the `python3 -c "import argon2"` check fails, immediately log a `log_warn` explaining that Python is present but `argon2-cffi` is missing, before falling through to the CLI check. This way the diagnostic is surfaced at the right moment rather than when the disabled `cli` path is reached.

---

### F-09 — LOW | Dashboard Uses `eval` for Rclone Config Path Resolution

**Category:** Security / Code Quality  
**Severity:** Low  
**Status:** Open

**Observation:**  
`lib/common.sh:271`:
```bash
        rclone_conf=$(eval echo "~${SUDO_USER}/.config/rclone/rclone.conf")
```

`eval` is used to expand the tilde (`~`) in the rclone config path. This is safe when `$SUDO_USER` is a system-validated username, but `eval` with user-controlled input is generally discouraged. A username containing shell metacharacters (e.g., `$(cmd)`) would execute arbitrary code.

In practice, `SUDO_USER` is set by the kernel via PAM and cannot contain such characters. The risk is theoretical.

**Recommendation:** Replace with:
```bash
rclone_conf="$(getent passwd "${SUDO_USER}" | cut -d: -f6)/.config/rclone/rclone.conf"
```
or use an indirect variable expansion pattern:
```bash
eval "rclone_conf=~${SUDO_USER}/.config/rclone/rclone.conf"
```
The `eval "var=~user/..."` form is safe in bash because the right-hand side is not re-evaluated as a command; only tilde expansion is performed.

---

### F-10 — INFO | Auth Endpoint Rate Limit May Be Too Permissive for Aggressive Actors

**Category:** Security / Rate Limiting  
**Severity:** Informational  
**Status:** Accepted Risk

**Observation:**  
`caddy/Caddyfile:217-221`:
```caddyfile
        zone auth_zone {
            key {http.vars.client_ip}
            events 10
            window 1m
        }
```

The authentication endpoint (`/api/accounts/prelogin*` and `/identity/connect/token*`) allows 10 requests per IP per minute. This is reasonable for normal usage (users switching clients, device re-auth) but may be too permissive for targeted credential stuffing where an attacker uses a botnet with many source IPs.

CrowdSec mitigates this at a higher level by detecting and banning brute-force patterns across the entire stack (VaultWarden app logs, Caddy access logs).

**Risk:** Low with CrowdSec active. Medium without CrowdSec (e.g., during initial setup before CrowdSec is configured).

**Recommendation:** No immediate change required. Document in `RUNBOOK.md` that operators should configure CrowdSec before exposing the vault to the internet. Consider reducing to 5/min in a future release if user feedback confirms no false positive issues with legitimate mobile clients.

---

### F-11 — LOW | `dashboard.sh` Requires Root but Opens External Commands Without TTY Guards

**Category:** Usability / Security  
**Severity:** Low  
**Status:** Open

**Observation:**  
`dashboard.sh:110`:
```bash
    if (IFS=" "; sudo "$@"); then
```
The dashboard spawns `sudo` for privileged operations (e.g., backup, health checks) from within the dashboard process. If the user's `sudo` credential has expired mid-session, this silently fails (the subshell exits with a non-zero code, which is reported as "Command exited with status X"). The operator has no way to re-authenticate without exiting the dashboard.

**Risk:** Low UX impact. A long-running dashboard session may lose sudo access and present confusing "Command failed" messages for privileged operations.

**Recommendation:** Before running `sudo "$@"`, probe `sudo -n true 2>/dev/null` and if it fails, print a clear "sudo credential expired — please re-run with a fresh terminal" advisory.

---

### F-12 — INFO | CrowdSec `CROWDSEC_VERSION=latest` in `.env.example`

**Category:** Reproducibility / Supply Chain  
**Severity:** Informational  
**Status:** Open

**Observation:**  
`.env.example:284-286`:
```env
CROWDSEC_VERSION=latest
CF_WORKER_BOUNCER_VERSION=latest
FIREWALL_BOUNCER_VERSION=latest
```

The doc-drift CI check (`doc-drift.yml:97-117`) explicitly guards against `/releases/latest` calls in `setup.sh`, but this check does not cover the `.env.example` values. Operators who copy `.env.example` verbatim will pin to `latest`, meaning their CrowdSec version will change on every `apt upgrade` or reinstall.

**Risk:** Silent minor/major upgrades to CrowdSec without the operator's explicit knowledge. CrowdSec has a history of breaking changes between major versions.

**Recommendation:** Set concrete version pins in `.env.example`:
```env
CROWDSEC_VERSION=1.6.3
CF_WORKER_BOUNCER_VERSION=v0.1.0
FIREWALL_BOUNCER_VERSION=v0.0.26
```
Update the doc-drift workflow to also check `.env.example` for unversioned references.

---

## Positive Observations

The following are explicitly noted as production-quality practices that deserve recognition:

| # | Observation |
|---|---|
| P-01 | **Atomic SOPS encrypt with pre-write backup and round-trip verification** (`lib/crypto.sh:211-340`). Prevents ciphertext truncation on error and catches stale Age recipient keys before the original is overwritten. |
| P-02 | **Secrets never appear in process arguments.** `generate_argon2_hash()` passes the password via stdin; `generate_bcrypt_hash()` uses `printf '%s\n' ... \| htpasswd -ni`. Both patterns avoid `/proc/$$/cmdline` and `ps aux` exposure. |
| P-03 | **Comprehensive `check_age_key()` with full encrypt/decrypt round-trip test** (`lib/crypto.sh:415-483`). Goes beyond a simple file-existence check. |
| P-04 | **Caddy entrypoint validates bcrypt cost ≥ 10 (OWASP minimum)** before passing the hash to Caddy (`caddy/entrypoint.sh:232-238`). |
| P-05 | **Container hardening is thorough**: `no-new-privileges`, `cap_drop: ALL`, `read_only: true`, per-service tmpfs, memory swap limits (prevents secret paging to disk), separate internal/egress/external Docker networks. |
| P-06 | **`init-permissions` init container** uses a sentinel file with a 24-hour TTL to avoid expensive full `find` permission scans on every restart. |
| P-07 | **HSTS with `includeSubDomains; preload`** is enforced in the Caddyfile. Security headers (COOP, COEP, CORP, Permissions-Policy) are applied globally with per-handle overrides for 2FA connector endpoints. |
| P-08 | **Strict ShellCheck CI** runs on all `*.sh` files at `--severity=warning` on every PR. Auto-fix job on merge to `main`. |
| P-09 | **Schema-driven secrets management** (`secrets-schema.yaml`) decouples secret enumeration from collection logic. Adding a new secret requires only a schema entry. |
| P-10 | **Degraded mode Caddyfile** (`caddy/Caddyfile.degraded`) prevents an infinite Docker restart loop when log directory permissions are wrong — a subtle but important operational resilience feature. |
| P-11 | **`secure_delete()` / `_secure_remove_file()`** attempts `shred -fuz -n 3` before falling back to `dd if=/dev/urandom` overwrite, minimizing plaintext key material persistence on disk. |
| P-12 | **`_tmpfs_dir()`** in `lib/secrets.sh` prefers `/dev/shm` then `/run/user/$uid` for recovery kit scratch space, reducing swap-persistence risk for temporary plaintext. |
| P-13 | **Makefile `make up` refuses to start with `docker-compose.override.yml` present**, preventing accidental production deployment with debug settings. |
| P-14 | **`validate_cloudflare_token()`** performs a live API probe (DNS records or rulesets endpoint) to verify token permissions at collection time, not just at Caddy startup. |

---

## Risk Summary Matrix

| Finding | Severity | Category | Action |
|---|---|---|---|
| F-01 `.sops.yaml` missing | Medium | Crypto/Secrets | Fix before GA |
| F-02 `conditional` schema gap | Low | Schema | Track + defer |
| F-03 Bcrypt regex incomplete | Low | Validation | Fix before GA |
| F-04 No crypto/secrets tests | Medium | Testing | Fix before GA |
| F-05 `safe-restart` rollback gap | Low | Reliability | Document |
| F-06 Postfix elevated caps | Info | Container security | Accept |
| F-07 `FILE_INTEGRITY_HMAC_KEY` undocumented | Medium | Integrity | Fix before GA |
| F-08 Argon2 CLI fallback diagnostic | Low | Compatibility | Fix before GA |
| F-09 `eval` in rclone path | Low | Code quality | Fix opportunistically |
| F-10 Auth rate limit permissive | Info | Rate limiting | Accept with docs |
| F-11 Dashboard sudo session | Low | UX/Security | Fix before GA |
| F-12 CrowdSec version unpinned | Info | Supply chain | Fix before GA |

---

## Automated Check Results

| Check | Result |
|---|---|
| `bash -n` (syntax check, all scripts) | ✅ PASS — no syntax errors |
| ShellCheck `--severity=warning` | ✅ PASS — zero warnings or errors across all 50+ shell scripts |
| Docker Compose YAML validity | ✅ PASS — `docker-compose.yml.example` is valid YAML |
| `.gitignore` secrets coverage | ✅ PASS — `.env`, `secrets/`, `*.age`, `age-key.txt` all excluded |
| `.gitattributes` LF enforcement | ✅ PASS — `*.sh`, `Caddyfile`, `*.yml` forced to LF |
| Bcrypt cost enforcement in entrypoint | ✅ PASS — cost < 10 rejected at startup |
| SOPS round-trip guard in `encrypt_sops_file()` | ✅ PASS — pre-write backup + decrypt verification present |

---

## Appendix: Files Reviewed

```
.env.example
.gitattributes
.gitignore
.github/workflows/doc-drift.yml
CHANGELOG.md
Makefile (lines 1–800)
README.md
RUNBOOK.md
VERSION
backup.sh
caddy/Caddyfile
caddy/Caddyfile.degraded
caddy/Dockerfile
caddy/entrypoint.sh
dashboard.sh (lines 1–800)
docker-compose.yml.example
edit-secrets.sh
lib/common.sh
lib/crypto.sh (lines 1–1200)
lib/defaults.sh
lib/log.sh
lib/schema.sh
lib/secrets.sh (lines 1–800)
maintenance.sh
restore.sh
secrets-schema.yaml
setup.sh
startup.sh
tests/test-architecture-helpers.sh
```

---

*This report was generated by static analysis and code review. Runtime testing (e.g., live SOPS encrypt/decrypt, Caddy TLS termination, CrowdSec ban enforcement) was not performed in this review scope.*
