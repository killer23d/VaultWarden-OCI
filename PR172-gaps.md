You are an expert Bash/shell engineer working on the VaultWarden-OCI project.
Repository: killer23d/VaultWarden-OCI
Branch to commit to: codex/address-beta-findings (PR #172)

You have GitHub API access. Fetch the current content of every file you
modify before writing it, and supply the correct SHA when updating.

---

## CONTEXT

PR #172 ("fix: address Beta readiness findings") introduced HMAC-authenticated
backup integrity sidecars and several other improvements. A post-merge review
identified the following issues that must be fixed in the same PR branch.
Fix ALL of them in a single additional commit. The commit message must be:

  fix: address HMAC and code-quality follow-ups from PR 172 review

---

## ISSUES TO FIX

### 1. [MEDIUM] openssl dgst -hmac exposes key in process args
File: lib/crypto.sh
Function: verify_file_integrity() and write_file_integrity()

CURRENT CODE (write side — similar pattern in verify side):
  openssl dgst -sha256 -hmac "${FILE_INTEGRITY_HMAC_KEY}" ...

PROBLEM: The -hmac flag passes the key as a command-line argument, which is
visible in /proc/<pid>/cmdline on Linux to any process that polls fast enough.

FIX: Use a pipe into openssl's stdin via the -mac HMAC and -macopt "hexkey:..."
form, OR pipe the key through a process substitution. The safest portable
approach for bash is to use -macopt with a hex-encoded key:

  # Hex-encode the key first, then use -macopt
  local hmac_key_hex
  hmac_key_hex=$(printf '%s' "${FILE_INTEGRITY_HMAC_KEY}" | xxd -p | tr -d '\n')
  openssl dgst -sha256 \
      -mac HMAC \
      -macopt "hexkey:${hmac_key_hex}" \
      ...

Apply this change to BOTH the write path (write_file_integrity) and the verify
path (verify_file_integrity). The hmac_key_hex local variable must be unset
immediately after use with: unset hmac_key_hex

Also add this to the test in tests/test-security-helpers.sh: after the
tampered-HMAC test passes, assert that the string FILE_INTEGRITY_HMAC_KEY
does NOT appear in /proc/*/cmdline during a write_file_integrity call (use a
simple grep in a subshell to verify no openssl -hmac is present).

---

### 2. [MEDIUM] Triplicate HMAC key generation logic
Files: lib/secrets.sh, utilities/setup-secrets.sh

PROBLEM: The file_integrity_hmac_key generation block (generate_secure_string 64)
appears verbatim in THREE places:
  a) lib/secrets.sh :: collect_secret_field()    — case file_integrity_hmac_key
  b) lib/secrets.sh :: auto_generate_secret_field() — case file_integrity_hmac_key
  c) utilities/setup-secrets.sh :: collect_secrets() — file_integrity_hmac_key block

The schema already declares auto_fn: "auto_generate_secret_field", so (a)
and (c) are redundant dispatch paths.

FIX:
  - In lib/secrets.sh :: collect_secret_field(): REMOVE the file_integrity_hmac_key
    case entirely. The schema-driven loop in setup-secrets.sh calls
    auto_generate_secret_field() directly via auto_fn; collect_secret_field is
    not invoked for auto keys. Add a comment in collect_secret_field's leading
    docblock: "auto keys are handled by auto_generate_secret_field(); do not
    add auto-collect cases here."
  - In utilities/setup-secrets.sh :: collect_secrets(): REMOVE the verbatim
    file_integrity_hmac_key case block. The schema dispatcher already handles
    collect: auto keys by invoking the function named in auto_fn. The verbatim
    block is unreachable dead code since the auto branch fires first.
  - Keep ONLY the case in lib/secrets.sh :: auto_generate_secret_field().
  - After removal, add a comment above the auto_generate_secret_field case:
    # Single source of truth for file_integrity_hmac_key generation.
    # collect_secret_field does NOT handle auto keys.

---

### 3. [MEDIUM] rclone_config_arg duplicated across two functions
File: utilities/backup-run.sh
Functions: sync_all_backups_to_rclone() and _prune_remote_backups()

PROBLEM: Both functions independently build their own rclone_config_arg array
by reading RCLONE_CONFIG and calling validate_rclone_config_path. This is
fragile — a future caller of _prune_remote_backups from a different context
would silently use an empty/wrong config array.

FIX: Extract the rclone config resolution into a new helper function:

  # Resolves and validates the rclone config path, then populates the caller's
  # rclone_config_arg array via a nameref. Returns 1 on failure.
  # Usage: _resolve_rclone_config_arg rclone_config_arg
  _resolve_rclone_config_arg() {
      local -n _out_arr="$1"
      local cfg
      cfg=$(get_config_value "RCLONE_CONFIG" "")
      if [[ -z "$cfg" ]]; then
          cfg=$(_resolve_rclone_config) || {
              log_error "No rclone config file found."
              return 1
          }
      fi
      validate_rclone_config_path "$cfg" || return 1
      cfg=$(realpath -e "$cfg")
      _out_arr=(--config "$cfg")
  }

Place this helper immediately above sync_all_backups_to_rclone.

Then refactor both sync_all_backups_to_rclone() and _prune_remote_backups()
to call it:

  local -a rclone_config_arg=()
  _resolve_rclone_config_arg rclone_config_arg || return 1

Remove the now-duplicate inline config resolution blocks from both functions.

---

### 4. [MEDIUM] No documented key rotation path for file_integrity_hmac_key
File: docs/SECRETS-SCHEMA.md

PROBLEM: The schema hint says "Rotate only after retaining old keys for legacy
backups" but gives no concrete steps. Operators have no guidance on how to
safely rotate this key without corrupting legacy backup verification.

FIX: Add a new section at the end of docs/SECRETS-SCHEMA.md titled:
## Rotating file_integrity_hmac_key

Content must cover:
  1. Why safe rotation requires a transition window: existing .sha256.hmac
     sidecars were generated with the old key, so verification will fail for
     old backups until new backups replace them.
  2. Rotation procedure (numbered steps):
     1. Set REQUIRE_AUTHENTICATED_INTEGRITY=false in .env temporarily.
     2. Run: sudo ./edit-secrets.sh rotate file_integrity_hmac_key
        This generates and stores a new 64-character key via SOPS.
     3. Run at least one backup of each type (db, full) to generate new
        sidecars signed with the new key:
          sudo ./backup.sh run db
          sudo ./backup.sh run full
     4. Confirm verification passes with the new key:
          sudo ./backup.sh verify
     5. Once all retained backups have been replaced by newly signed ones
        (after BACKUP_RETENTION_*_DAYS have elapsed), re-enable:
          REQUIRE_AUTHENTICATED_INTEGRITY=true
     6. Old remote sidecars: run sudo ./backup.sh sync to upload fresh sidecars.
  3. Emergency note: if the key is lost and REQUIRE_AUTHENTICATED_INTEGRITY=true,
     set it to false, re-bootstrap via edit-secrets.sh, and follow the above.

---

### 5. [MINOR] Stale function comment in backup-run.sh
File: utilities/backup-run.sh

PROBLEM: The comment block above _prune_remote_backups still reads
  # _prune_remote_backups BASE_DIR RETENTION_DAYS
after the function signature was changed to take no arguments.

FIX: Update the comment to:
  # _prune_remote_backups
  #
  # Prunes backup files older than the per-type configured retention from the
  # configured rclone remote. Reads retention per type from
  # _retention_days_for_type(). Mirrors the local cleanup_old_backups() policy.
  # Non-fatal: logs a warning and returns 1 on partial failures.

---

### 6. [MINOR] safe-restart.sh rollback dir uses /tmp instead of /dev/shm
File: utilities/safe-restart.sh

PROBLEM: The rollback_dir is created with:
  rollback_dir=$(mktemp -d -p /tmp vaultwarden-safe-restart.XXXXXXXXXX)

The /tmp directory is world-readable before chmod 700 is applied (TOCTOU
window). The Compose model snapshot may contain image digest references.
backup-run.sh uses /dev/shm for its own sensitive tmpdir.

FIX: Match the pattern used in backup-run.sh:
  rollback_dir=$(mktemp -d -p /dev/shm 2>/dev/null \
                 || mktemp -d -t vaultwarden-safe-restart.XXXXXXXXXX)
  chmod 700 "$rollback_dir"

The fallback (mktemp -t) is used when /dev/shm is unavailable (e.g., macOS
or a container without tmpfs). Keep the chmod 700 immediately after as it is.

---

### 7. [MINOR] HMAC/SHA-256 relationship not articulated in verify_file_integrity
File: lib/crypto.sh
Function: verify_file_integrity()

PROBLEM: A future maintainer reading verify_file_integrity() might not
understand WHY both the SHA-256 check and the HMAC check run, and in what
order.

FIX: Add a block comment immediately above the function's main verification
logic (after the parameter validation, before the sha256sum check) that
reads:

  # Verification pipeline (both steps must pass when HMAC is available):
  #   1. SHA-256: recompute sha256sum of $file and compare to $checksum_file.
  #      Catches file corruption or replacement.
  #   2. HMAC-SHA256 (when FILE_INTEGRITY_HMAC_KEY is set): recompute HMAC
  #      of the *checksum string* stored in $checksum_file and compare to
  #      $checksum_file.hmac. Catches sidecar tampering (an attacker who
  #      replaces both the file and its .sha256 would still fail this check
  #      because they cannot forge the HMAC without the key).
  # Note: HMAC authenticates the checksum, not the backup file directly.
  # Both checks are necessary; passing only HMAC means the .sha256 content
  # is authentic but the file it was computed from has not been verified.

---

## CODE QUALITY RULES (apply to ALL changes)

- Bash style: 4-space indentation, local variables declared before use,
  `|| return 1` error propagation, no errexit-hostile patterns.
- Every new helper function must have a leading comment block describing
  its purpose, parameters, and return value.
- New variables: always `local`; nameref variables (`local -n`) must use
  a `_`-prefixed nameref name to avoid collision with outer scope.
- Do not introduce new `eval` calls anywhere.
- ShellCheck must pass at --severity=warning for every modified file.
  Think through each change for SC2086 (unquoted variables), SC2155
  (combined declare+assign), and SC2046 (word splitting) before writing.
- Keep changes minimal and surgical — do not refactor unrelated code.
- Tests: update tests/test-security-helpers.sh to cover:
    a) The /proc cmdline check for HMAC key exposure (issue 1).
    b) Assert that the file_integrity_hmac_key case is absent from
       collect_secret_field (call collect_secret_field file_integrity_hmac_key
       and assert it returns non-zero / logs an error) (issue 2).
    c) A basic call to _resolve_rclone_config_arg with a mock config path
       to assert the array is populated (issue 3) — skip if rclone not installed.

---

## DELIVERABLES

Commit all changed files to branch codex/address-beta-findings in one commit
with message:
  fix: address HMAC and code-quality follow-ups from PR 172 review

Files expected to change:
  - lib/crypto.sh
  - lib/secrets.sh
  - utilities/backup-run.sh
  - utilities/safe-restart.sh
  - utilities/setup-secrets.sh
  - docs/SECRETS-SCHEMA.md
  - tests/test-security-helpers.sh

Do not create new files. Do not modify any file not listed above.
Fetch the current SHA of each file before updating it.
