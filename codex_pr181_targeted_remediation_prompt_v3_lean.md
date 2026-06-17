# Codex 5.x Remediation Prompt — Fix PR #181 Without Expanding Scope

## Mission

Repair the confirmed merge blockers in:

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Pull request: `#181`
- PR branch: `codex/validate-prompt-compliance-for-vaultwarden`
- Target branch: `delta`
- Current reviewed PR head: `420dbe91476a089f11f3f662fd29c5192a387d23`

Continue on the existing PR branch and update PR #181. Do **not** create a new branch or PR. Keep the PR in draft until every required validation passes.

The authoritative design and scope are in:

```text
resilient_recovery_prompt.md
```

on `delta`.

Read that file before editing. This prompt is a focused remediation pass over the existing implementation; it does not replace the original requirements.

If the PR head has advanced beyond the SHA above, inspect the newer commits first and preserve any valid fixes. Do not reset or discard newer work.

Do not stop after producing a plan. Implement the changes, test them, commit them in logical follow-up commits, push the existing branch, and update the existing PR description with exact validation results.

## Pre-flight — mandatory reads

Before touching any file, perform these reads in order and confirm each succeeded:

1. Run:

   ```bash
   git show delta:resilient_recovery_prompt.md
   ```

   Extract and record:

   - the `/run` permission model for `prepare_push_secret_placeholders`;
   - the ciphertext staging invariant;
   - the original recovery-test acceptance list.

2. Inspect the current PR implementations:

   ```bash
   git show HEAD:startup.sh | sed -n '/prepare_push_secret_placeholders()/,/^}/p'
   git show HEAD:recover.sh
   git show HEAD:tests/test-recover.sh
   ```

3. Record current line counts without assuming fixed values:

   ```bash
   git show HEAD:recover.sh | wc -l
   git show HEAD:tests/test-recover.sh | wc -l
   grep -cE '^[[:space:]]*(run_test|test_[A-Za-z0-9_]+)[[:space:]]' tests/test-recover.sh || true
   ```

4. Confirm the current branch and PR head:

   ```bash
   git branch --show-current
   git rev-parse HEAD
   ```

Do not begin implementation until these reads are complete. Include the observed line counts and current test-case count in the completion report.

## Target 0 — Establish the strict ShellCheck baseline

Before editing, run the exact repository CI command and preserve its output:

```bash
baseline_shellcheck_log="$(mktemp)"
baseline_shellcheck_rc=0
find . -type f -name '*.sh'   | xargs shellcheck -x --severity=warning   >"$baseline_shellcheck_log" 2>&1   || baseline_shellcheck_rc=$?

cat "$baseline_shellcheck_log"
printf 'Pre-edit ShellCheck exit status: %s\n' "$baseline_shellcheck_rc"
```

This pre-edit run is diagnostic; a nonzero status is expected while PR #181 is broken. Use it to distinguish existing PR warnings from warnings introduced during remediation.

After implementation, the same strict command must exit zero. Do not suppress or reclassify warnings, and do not edit files outside the remediation scope merely to clean unrelated historical style findings. If the baseline reveals a warning outside the remediation scope that also exists on `delta`, document it as a blocker rather than expanding scope.

---

# Remediation-pass scope

For this remediation pass, modify only:

```text
startup.sh
lib/config.sh
lib/secrets.sh                         # minimal existing PR scope exception only
utilities/setup-systemd.sh
utilities/setup-secrets.sh
utilities/setup-storage.sh
utilities/backup-run.sh
recover.sh
tests/test-recover.sh
docs/CONFIGURATION.md
systemd/vaultwarden-startup.service
```

Do not edit any other file during this pass.

`lib/secrets.sh` is permitted only because PR #181 already modified it as a supporting change. Limit work there to correcting warnings or defects introduced by PR #181; do not refactor it.

Do not modify:

```text
resilient_recovery_prompt.md
docker-compose.yml.example
docs/recovery-card.md
README.md
RUNBOOK.md
CHANGELOG.md
Makefile
.github/workflows/*
setup.sh
```

Do not change CI rules to make checks pass. Fix the code and unit instead.

If a confirmed blocker cannot be fixed within the target list, stop and report the exact blocker. Do not silently expand scope.

---

# Guardrails — do not apply incorrect review suggestions

These are intentional and must remain:

1. `DOMAIN` includes `https://`.
   - Keep manifest validation requiring `https://`.
   - Keep the health URL as `${DOMAIN%/}/alive`.
   - Do not convert DOMAIN to a bare hostname.

2. The recovery commit check remains fatal.
   - Recovery must use the immutable `REPO_COMMIT` from the manifest.
   - Improve the error message to include the current commit, expected commit, and exact checkout command.
   - Do not downgrade the mismatch to a warning.

3. Do not restore the removed `/secrets/.docker_secrets` checks or the old `./secrets` init-container mount.
   - Those paths are obsolete under the `/run` architecture.
   - Startup must fail before Compose when runtime secret materialisation fails.

4. Keep `<DOMAIN>`, `<REPO_URL>`, and `<REPO_COMMIT>` in the repository recovery-card template.
   - The state-volume rendered copy replaces them.
   - Do not modify `docs/recovery-card.md` in this pass.

5. Post-edit `sops updatekeys` already exists in `utilities/secrets-edit.sh`.
   - Preserve its staged update/validation behavior.
   - Do not duplicate it in the root dispatcher.

6. Do not remove the prerequisite checks in `recover.sh`.
   - The recovery card runs `utilities/setup-system.sh` first.

---

# Target 1 — Keep runtime plaintext secrets host-private

## File: `startup.sh`

Fix `prepare_push_secret_placeholders()`.

Current defect:

- `export_docker_secrets()` establishes `/run/vaultwarden-oci/secrets` as `0700`.
- `prepare_push_secret_placeholders()` later changes the parent to `0755`, changes group ownership, and assigns push placeholders to `${PUID}:${PGID}`.
- Since runtime files are `0444`, ordinary host users can then traverse the parent and read secrets by path.

Required final state:

```text
root:root 0700  /run/vaultwarden-oci/secrets
root:root 0444  every regular file directly under that directory
```

Implementation requirements:

- Remove PUID/PGID lookup and ownership logic from `prepare_push_secret_placeholders`.
- Create or correct the parent as `root:root 0700`.
- Create missing:
  - `push_installation_id`
  - `push_installation_key`
- Ensure both placeholders are `root:root 0444`.
- Do not change the parent to `0755`.
- After the function completes, verify the parent is still `0700`.
- Keep dry-run behavior.
- Use readable multi-line logic and existing `_maybe_sudo` conventions.
- Do not alter unrelated startup behavior.

Add a focused assertion to an existing suitable test only if it can be done within the listed files; otherwise document the manual verification command in the PR.

---

# Target 2 — Make systemd use the authoritative persistent environment

## File: `utilities/setup-systemd.sh`

Current defect:

- The script calls `load_project_environment`, but installation still copies repository `.env` to `/etc/vaultwarden/vaultwarden.env`.
- A fresh recovery clone has no repository `.env`.
- The installer creates an empty environment file.
- The next boot cannot rediscover the state volume.

Required source order for the installed environment:

1. `${PROJECT_STATE_DIR}/config/install.env`
2. repository `.env` only as a legacy fallback
3. if neither exists, fail with a clear error
4. never create an empty `vaultwarden.env`

Implementation requirements:

- Resolve one `environment_source` after `load_project_environment`.
- Prefer the persistent `install.env`.
- Log the chosen source.
- Atomically install the full chosen source to:
  `/etc/vaultwarden/vaultwarden.env`
- Preserve current secure installed permissions.
- Treat persistent `install.env` as authoritative; do not retain stale installed values merely because the destination already exists.
- After installing the authoritative file, apply the existing systemd-owned adjustments such as:
  - canonical `SOPS_AGE_KEY_FILE`;
  - `RCLONE_CONFIG`, when configured.
- Preserve the current Age-key and rclone setup behavior unless directly required by this change.
- Update help text and status messages that still say the environment is copied only from repository `.env`.

Do not add a fallback that silently creates an empty environment.

---

# Target 3 — Integrate the startup unit into the complete systemd lifecycle

## Files

```text
systemd/vaultwarden-startup.service
utilities/setup-systemd.sh
```

## Unit hardening

Add the directives required by repository CI, using values compatible with the startup workflow:

```ini
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
NoNewPrivileges=true
```

Retain:

```ini
RequiresMountsFor=@PROJECT_STATE_DIR@
EnvironmentFile=-/etc/vaultwarden/vaultwarden.env
WorkingDirectory=@PROJECT_ROOT@
ExecStart=/bin/bash @PROJECT_ROOT@/startup.sh --skip-pull
```

Keep the template placeholders unresolved in the repository file.

Validate that these hardening values still allow:

- reading a repository under `/opt` or `/home`;
- writing under `/run`;
- writing to the state volume;
- communicating with Docker.

Do not weaken or remove `RequiresMountsFor`.

## Installer lifecycle

Continue rendering the startup service separately. Never send the unresolved template through the generic service-copy loop.

Add an explicit variable such as:

```bash
STARTUP_SERVICE="vaultwarden-startup.service"
```

Integrate the rendered unit into:

- install;
- remove;
- validate;
- status/reset-failed as appropriate.

Required behavior:

- `install` renders, atomically installs, daemon-reloads, and enables it;
- `remove` disables it, removes the rendered unit, and daemon-reloads;
- `validate` checks:
  - installed file exists;
  - no `@PROJECT_ROOT@` or `@PROJECT_STATE_DIR@` remains;
  - installed unit matches a freshly rendered expected copy;
  - unit is enabled;
- reset-failed includes the startup unit;
- status output reports it.

Do not add the template to the generic `SERVICES` array if doing so would copy it unrendered. Use explicit lifecycle handling.

---

# Target 4 — Make offline-recipient changes transactional

## File: `utilities/setup-secrets.sh`

Restrict edits to the bootstrap/configure recipient and ciphertext paths and focused local helpers needed for the transaction. Do not refactor unrelated break-glass, email, or credential logic.

## Recipient resolution

Preserve this resolution order:

1. explicit `OFFLINE_AGE_RECIPIENT`;
2. manifest;
3. existing policy;
4. TTY prompt;
5. empty for a genuinely new installation when skipped.

Fix validation behavior:

- A non-empty explicit `OFFLINE_AGE_RECIPIENT` with invalid format is a fatal configuration error.
- A non-empty invalid manifest value is a fatal consistency error; do not silently discard it and continue.
- Deduplicate recipients.
- Operational recipient must be first.
- More than one unknown non-operational policy recipient remains a fatal manual-review condition.
- A non-interactive rerun must never remove a previously configured valid offline recipient.

## Desired-state comparison

Determine the desired policy recipient set before deciding that `.sops.yaml` is current.

Do not consider the policy current merely because it contains the operational recipient and `creation_rules:`.

The current policy and existing ciphertext metadata must both contain the desired recipients before setup may skip rekeying.

Inspect ciphertext metadata with `yq` and verify the expected Age recipients are represented under SOPS metadata after rekeying.

## Transactional policy and ciphertext update

Never write live `.sops.yaml` directly.

Create the desired policy in a same-directory temporary file under the repository root.

For an existing `SECRETS_FILE`:

1. create ciphertext staging beside `SECRETS_FILE`;
2. copy live ciphertext into staging;
3. run:

```bash
SOPS_AGE_KEY_FILE="$operational_key" \
  sops --config "$policy_staging" \
    updatekeys --yes "$ciphertext_staging"
```

4. verify staged decryption with the operational key;
5. verify staged metadata contains the full desired recipient set;
6. retain backups/presence flags for:
   - existing ciphertext;
   - existing `.sops.yaml`;
   - existing manifest;
7. promote ciphertext, policy, and manifest with handled rollback;
8. retain backups until final validation succeeds.

If policy or manifest promotion fails after ciphertext promotion, restore all previously promoted artifacts.

Only update `OFFLINE_AGE_RECIPIENT` and `MANIFEST_UPDATED_AT` after the staged policy and ciphertext are valid.

## Existing ciphertext when a new offline recipient is added

A decryptable existing `secrets.yaml` must not cause an early return when the desired recipient set differs.

Force the staged `updatekeys` transaction whenever:

- an offline recipient is newly added;
- the offline recipient changes;
- policy recipients and ciphertext metadata differ.

Do not run `updatekeys` directly against live ciphertext.

---

# Target 5 — Remove persistent plaintext staging from bootstrap

## File: `utilities/setup-secrets.sh`

Current defect:

- placeholder plaintext is created under `${PROJECT_ROOT}/secrets/`;
- ciphertext is written directly to live `SECRETS_FILE`.

Required implementation:

## Plaintext staging

Create plaintext temporary files only under tmpfs, for example:

```text
/run/vaultwarden-oci/
```

Requirements:

- parent `root:root 0700`;
- plaintext file mode `0600`;
- cleanup trap removes or securely shreds it on success, failure, INT, and TERM;
- never create plaintext under the repository or state volume.

Do not use the persistent `/run/vaultwarden-oci/secrets/` output directory for a filename that could be mistaken for a Docker secret. A dedicated protected tmpfs subdirectory is preferable.

## Ciphertext staging

- Create encrypted staging beside `SECRETS_FILE`.
- Encrypt using the staged desired policy.
- Run the staged `updatekeys` synchronization.
- Validate decryption.
- Validate recipients in SOPS metadata.
- Promote with one same-filesystem `mv`.
- Never write new ciphertext directly to live `SECRETS_FILE`.

Preserve ownership and mode expected for encrypted `secrets.yaml`.

Do not remove or redesign the existing operational Age-key storage model in this remediation pass.

---

# Target 6 — Repair recovery key promotion and rollback

## File: `recover.sh`

Keep the script fully standalone.

Preserve:

- `DOMAIN` requiring `https://`;
- fatal commit pinning;
- USB private key never copied to local storage;
- temporary SOPS policy;
- new operational key generation;
- persistent manifest and `install.env` updates.

## Readability

Rewrite compressed one-line functions and transaction blocks into readable multi-line functions.

At minimum, separate:

```text
argument parsing
prerequisite checks
manifest parsing and validation
backup creation
new-key generation
staged rekeying
artifact promotion
rollback
install.env update
manifest update
startup and health check
cleanup
```

Do not use `eval`.

Use `ERROR:`-prefixed plain-English failure messages.

## Required function structure

Rewrite `recover.sh` with, at minimum, these named multi-line functions:

```bash
parse_args()             # --state-dir, --key, --help
check_prerequisites()    # commands, root, Docker Compose, mountpoint
parse_manifest()         # read and validate manifest values with awk
create_backups()         # ciphertext/key/policy backups and existence flags
generate_new_key()       # generate private key and derive public recipient
run_staged_rekey()       # temporary policy plus updatekeys on staging
validate_staged()        # validate staged ciphertext and staged installed key
promote_artifacts()      # guarded ciphertext, key, and policy promotion
rollback()               # restore/remove according to promotion state
update_env_files()       # atomic install.env and manifest updates
run_startup_health()     # startup plus nonfatal health check
cleanup()                # trap target for all remaining temp/backup files
```

Equivalent additional helper functions are allowed, but do not merge these responsibilities back into compressed one-line blocks.

`rollback` must be safe to call after any promotion stage. Track both prior existence and successful-promotion state explicitly; do not infer them from whether a temporary filename is non-empty.

## Commit mismatch message

Keep mismatch fatal, but print:

- current commit;
- expected manifest commit;
- exact remediation command:

```text
sudo git -C <repo> checkout <expected commit>
```

## Staged active-key promotion

Do not install directly over the active key.

Required sequence:

1. Create `VW_ETC_DIR` securely.
2. Create the new installed-key staging file in `VW_ETC_DIR`, beside the final key.
3. Mode `0600`.
4. Validate staged key against staged ciphertext.
5. Preserve the prior active key and a presence flag.
6. Promote with:

```bash
mv "$staged_key" "$active_key"
```

The test suite must be able to fail this exact destination-aware `mv`.

## Complete rollback

Track and clean:

```text
ciphertext staging
temporary policy
new private-key temp
installed-key staging
ciphertext backup
active-key backup
policy backup
all presence flags
```

Handled failure behavior:

- updatekeys failure: no live artifact changed;
- ciphertext promotion failure: no other live artifact changes;
- key promotion failure:
  - restore ciphertext;
  - restore old key if it existed;
  - remove new key if no old key existed;
  - keep/restore old policy;
- policy promotion failure:
  - restore ciphertext;
  - restore/remove key according to prior existence;
  - restore/remove policy according to prior existence;
- final live-decryption failure:
  - restore/remove all three live artifacts.

Do not delete rollback backups until the final live decryption with the active key succeeds.

Track the ciphertext staging file even though it is outside the general temporary work directory.

## SOPS error handling

Convert raw failures to clear messages, including:

```text
Decryption failed — wrong key or corrupted secrets file.
Key rotation failed — live recovery artifacts were not changed.
New operational key validation failed.
Ciphertext promotion failed.
Operational key promotion failed — recovery artifacts were rolled back.
SOPS policy promotion failed — recovery artifacts were rolled back.
Post-promotion decryption failed — recovery artifacts were rolled back.
```

Keep nonfatal health-check behavior.

---

# Target 7 — Add real recovery transaction tests

## File: `tests/test-recover.sh`

Replace the current shallow three-case suite with a deterministic mocked recovery suite.

Do not add a framework and do not touch `Makefile`.

Use:

```text
VW_RECOVER_ETC_DIR
VW_RECOVER_STARTUP_SCRIPT
```

Use temporary directories only. No test may modify real `/etc/vaultwarden`.

Mock or PATH-stub as needed:

```text
mountpoint
findmnt
sops
age-keygen
docker
curl
git
blkid
mv
```

The `mv` mock must fail by destination path, not invocation count, and delegate all other moves to the real `mv`.

Use `sudo env ... bash recover.sh` for root-required full-path cases when tests run as a non-root user.

## Mock behavior requirements

Write PATH-stub scripts for `age-keygen`, `sops`, and `mv` in a temporary
mock directory prepended to `PATH`.

`age-keygen` must:
- emit a distinct deterministic recipient string for the USB key versus the
  newly generated operational key, controlled by `MOCK_USB_KEY_PATH`;
- write a stub private-key file when called with `-o`.

The test harness must set `MOCK_USB_KEY_PATH` to the exact USB key path
passed to `recover.sh` through `--key`, and must assert it is non-empty before
running recovery.

`sops` must:
- parse `--config`, `updatekeys`, and `-d`/`--decrypt` by walking `"$@"`,
  not by positional index;
- fail `updatekeys` when `MOCK_SOPS_FAIL_OP=updatekeys`;
- fail decrypt of the staging file when
  `MOCK_SOPS_FAIL_OP=decrypt_staged` and the target matches
  `MOCK_CIPHER_STAGING`;
- fail decrypt of the live file when `MOCK_SOPS_FAIL_OP=decrypt_live`
  and the target matches `MOCK_LIVE_CIPHER`;
- on `updatekeys`, append a `# mock-age=<recipient>` marker to the target
  for the happy-path assertion.

`mv` must:
- fail with exit 1 when the final argument matches `MOCK_MV_FAIL_DEST`;
- delegate all other calls to `/bin/mv`.

The happy-path test must assert the promoted ciphertext contains the mock
recipient marker. Set
`MOCK_MV_FAIL_DEST="$VW_RECOVER_ETC_DIR/age-key.txt"` for key-promotion
failure, and use the exact live repository `.sops.yaml` path for
policy-promotion failure.

Required test cases:

1. missing `--state-dir` prints usage and fails;
2. missing `--key` prints usage and fails;
3. non-mounted state directory prints the exact required message;
4. `sops updatekeys` failure:
   - ciphertext byte-identical;
   - active key state unchanged;
   - policy state unchanged;
5. active-key promotion failure after ciphertext promotion:
   - ciphertext restored byte-for-byte;
   - old key restored, or new key absent when no old key existed;
   - policy unchanged;
6. policy promotion failure:
   - ciphertext restored;
   - key restored/removed according to prior existence;
   - policy restored/absent according to prior existence;
7. final live-decryption failure:
   - all three artifacts restored;
   - explicitly cover no-prior-key and no-prior-policy state;
8. successful fresh-clone recovery with no initial `.sops.yaml`:
   - exits zero;
   - prints `mock startup: OK`;
   - installs a new operational key;
   - changes ciphertext;
   - creates policy with operational and USB recipients;
   - retains USB recipient in ciphertext metadata;
   - updates `install.env`;
   - updates manifest recipient and timestamp.

After each test, assert real `/etc/vaultwarden` is unchanged.

Use byte-for-byte comparisons for rollback assertions.

---

# Target 8 — Guard storage identity updates by actual volume mode

## File: `utilities/setup-storage.sh`

Fix `_update_install_env_after_storage`.

Current defect:

- `DATA_VOLUME_MOUNT` defaults to `/mnt/vw-data`;
- updater can write that value as `PROJECT_STATE_DIR` even in boot-volume mode.

Required behavior:

## Separate-volume mode

Only update state identity when all are true:

- `DATA_VOLUME_DEVICE` is non-empty;
- the configured mount is an active mountpoint;
- `findmnt` resolves the mounted source;
- existing-filesystem adoption or separate-volume setup completed successfully.

Then atomically replace or append:

```text
PROJECT_STATE_DIR=<actual mount>
DATA_VOLUME_MOUNT=<actual mount>
DATA_VOLUME_DEVICE=<UUID path when available>
SOPS_AGE_KEY_FILE=<intended existing key, when present>
```

## Boot-volume mode

When no separate device is configured:

- do not rewrite `PROJECT_STATE_DIR` to the default data mount;
- preserve `/var/lib/vaultwarden` or the current configured state directory;
- do not invent `DATA_VOLUME_DEVICE`.

Use only persistent `install.env` as the recovery-state update target when it exists. Do not silently redirect the update to repository `.env` during an existing-volume recovery.

Preserve unrelated keys, ownership, and mode.

---

# Target 9 — Distinguish true caller overrides from config defaults

## File: `lib/config.sh`

Keep the original prompt’s two public focused helpers:

```text
resolve_secrets_file
load_project_environment
```

Do not introduce additional public helpers or broad refactoring.

## Current defect — precise execution order

`lib/config.sh` contains module-level compile-time fallback assignments that execute while the file is sourced, including:

```bash
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/etc/vaultwarden/age-key.txt}"
```

When a caller did not supply `SOPS_AGE_KEY_FILE`, that assignment makes the variable non-empty before `load_project_environment` is called. The function then mistakes the module default for a caller override and restores it over the value loaded from persistent `install.env`.

## Required source-time capture

Capture the caller-provided state before any module-level fallback assignment executes. Place a private capture block at the top of `lib/config.sh`, before defaults can mutate these variables:

```bash
if [[ -z "${_VW_CALLER_OVERRIDES_CAPTURED:-}" ]]; then
    _VW_CALLER_PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
    _VW_CALLER_DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    _VW_CALLER_DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-}"
    _VW_CALLER_SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}"
    _VW_CALLER_OVERRIDES_CAPTURED=1
fi
```

Do not export these private variables.

`load_project_environment` must restore only the corresponding `_VW_CALLER_*` value when it was non-empty. It must not re-check the live variables after module defaults have been assigned.

Required outcomes:

- persistent `install.env` can set a custom `SOPS_AGE_KEY_FILE`;
- explicit overrides supplied by `recover.sh` or `PROJECT_STATE_DIR=... setup-systemd.sh install` survive loading;
- compile-time defaults never overwrite a loaded persistent value;
- repeated internal calls to `load_project_environment` remain idempotent.

To comply with the original two-public-helper rule:

- keep only `resolve_secrets_file` and `load_project_environment` as the new public functions;
- fold `_read_env_value_awk` into `load_project_environment`, or use inline `awk`;
- do not export any additional helper or sentinel.

Preserve safe `load_env_file` parsing and current precedence.

---

# Target 10 — Preserve backup integrity fallback semantics

## File: `utilities/backup-run.sh`

Current defect:

- with `set -euo pipefail`, an unguarded `sops | yq` command substitution can terminate the script before policy handling.

Refactor `_load_integrity_hmac_key` so the pipeline status is captured explicitly in a conditional.

Required behavior:

```text
decryption/parsing succeeds with a valid key
  -> export FILE_INTEGRITY_HMAC_KEY

decryption/parsing fails or value is empty/placeholder
  + REQUIRE_AUTHENTICATED_INTEGRITY=true
  -> clear error and return failure

decryption/parsing fails or value is empty/placeholder
  + authenticated integrity not required
  -> retain existing warning and SHA-256-only compatibility mode

dry run
  -> retain current no-write warning behavior
```

## Required implementation pattern

Use a conditional assignment so `set -e` does not terminate the script and `pipefail` still supplies the pipeline result. Do not toggle `set +e`/`set -e`, because that mutates shell state for the caller.

```bash
_load_integrity_hmac_key() {
    local raw_value=""
    local pipeline_rc=0

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        backup_log_warn "[DRY RUN] Backup integrity HMAC key is unavailable; no files will be written."
        return 0
    fi

    if raw_value="$(
        SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE"             sops -d "$SECRETS_FILE"             | yq -r '.file_integrity_hmac_key // ""'
    )"; then
        pipeline_rc=0
    else
        pipeline_rc=$?
    fi

    if [[ $pipeline_rc -ne 0 || -z "$raw_value" || "$raw_value" == CHANGE_ME* ]]; then
        unset FILE_INTEGRITY_HMAC_KEY

        if [[ "${REQUIRE_AUTHENTICATED_INTEGRITY:-false}" == "true" ]]; then
            log_error "Authenticated backup integrity is required, but file_integrity_hmac_key is unavailable."
            return 1
        fi

        backup_log_warn "Backup integrity HMAC key is unavailable; legacy SHA-256-only mode remains active."
        return 0
    fi

    FILE_INTEGRITY_HMAC_KEY="$raw_value"
    export FILE_INTEGRITY_HMAC_KEY
}
```

Retain any existing remediation messages that are still accurate.

Do not write the decrypted key to disk.

Do not use a naked `sops | yq` command substitution in this `set -euo pipefail` script.

Do not modify unrelated backup logic.

---

# Target 11 — Restore the configuration reference

## File: `docs/CONFIGURATION.md`

Restore the detailed configuration reference from `delta` before PR #181’s replacement.

A suitable starting operation is conceptually:

```bash
git show delta:docs/CONFIGURATION.md
```

Do not replace it with a short architecture summary.

Preserve the original detailed sections, including:

- settings reference;
- storage;
- secrets;
- mail routing;
- push notifications;
- backups;
- systemd;
- troubleshooting.

Then update only the affected architecture/path sections:

```text
authoritative ${PROJECT_STATE_DIR}/config/install.env
repository .env as compatibility/bootstrap fallback
/etc/vaultwarden/vaultwarden.env as installed bootstrap fallback
persistent encrypted ${PROJECT_STATE_DIR}/secrets/secrets.yaml
transient /run/vaultwarden-oci/secrets
operational plus offline Age recipients
reboot recreation by vaultwarden-startup.service
```

Remove current-documentation references to persistent `.docker_secrets`.

Do not delete unrelated documentation.

---

# Validation

Run from repository root.

## Baseline

```bash
git status --short
git rev-parse HEAD
git diff --check
```

## Syntax

Run separately and fail the validation block when any file fails:

```bash
syntax_files=(
  startup.sh
  recover.sh
  utilities/setup-systemd.sh
  utilities/setup-secrets.sh
  utilities/setup-storage.sh
  utilities/backup-run.sh
  tests/test-recover.sh
  lib/config.sh
  lib/secrets.sh
)

for file in "${syntax_files[@]}"; do
  printf '== bash -n %s ==\n' "$file"
  bash -n "$file" || exit 1
done
```

## Strict ShellCheck

```bash
shellcheck_rc=0
find . -type f -name '*.sh'   | xargs shellcheck -x --severity=warning   || shellcheck_rc=$?

printf 'ShellCheck exit status: %s\n' "$shellcheck_rc"
if (( shellcheck_rc != 0 )); then
  printf 'ShellCheck failed.\n' >&2
  exit "$shellcheck_rc"
fi
```

Any warning-level failure blocks completion. Do not hide it with `|| true`.

## Recovery tests

```bash
bash tests/test-recover.sh
```

All eight cases must run and pass.

## Existing focused tests

Run:

```bash
make test-unit
tests/test-crowdsec-config.sh
```

Also run any existing focused setup/storage/secrets/systemd tests that directly cover the modified functions.

## Systemd hardening check

Run the same check enforced by CI:

```bash
REQUIRED_DIRECTIVES=(PrivateTmp ProtectSystem ProtectHome NoNewPrivileges)
FAIL=0
for unit in systemd/vaultwarden-*.service; do
  [[ "$unit" == *template* ]] && continue
  for directive in "${REQUIRED_DIRECTIVES[@]}"; do
    [[ "$unit" == *iptables* && "$directive" == "NoNewPrivileges" ]] && continue
    grep -q "^${directive}=" "$unit" || {
      printf 'MISSING %s in %s\n' "$directive" "$unit"
      FAIL=1
    }
  done
done
(( FAIL == 0 ))
```

## Rendered unit validation

Render both placeholders:

```text
@PROJECT_ROOT@
@PROJECT_STATE_DIR@
```

into a temporary `.service` filename and run:

```bash
systemd-analyze verify "$rendered_unit"
```

A nonzero result caused by the rendered unit blocks completion. If the host lacks `systemd-analyze`, record the skip.

## Compose validation

Although this pass does not modify Compose, ensure the existing PR remains valid:

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

Record an explicit skip when Docker is unavailable.

## Obsolete-path audit

```bash
git grep -nE 'secrets/\.docker_secrets|\.docker_secrets' -- \
  ':!CHANGELOG.md'
```

Do not reintroduce old runtime paths.

## Documentation regression check

Confirm `docs/CONFIGURATION.md` retains the detailed reference rather than the 11-line stub.

Report:

```bash
wc -l docs/CONFIGURATION.md
git diff --stat delta -- docs/CONFIGURATION.md
```

## Remediation scope

This remediation pass may modify only:

```text
startup.sh
lib/config.sh
lib/secrets.sh
utilities/setup-systemd.sh
utilities/setup-secrets.sh
utilities/setup-storage.sh
utilities/backup-run.sh
recover.sh
tests/test-recover.sh
docs/CONFIGURATION.md
systemd/vaultwarden-startup.service
```

Before committing:

```bash
git diff --name-only
```

If another file changed, revert it or stop and explain why the requested fix cannot remain in scope.

---

# Commits

Create logical follow-up commits on the existing PR branch. Do not rewrite or squash the existing PR commit unless explicitly necessary.

Suggested grouping:

1. `fix: secure runtime secrets and persistent systemd state`
2. `fix: make SOPS setup and recovery transactions rollback-safe`
3. `test: cover recovery promotion and rollback paths`
4. `docs: restore configuration reference and pass validation`

Do not force-push unless the existing branch requires it and the reason is documented.

---

# PR update requirements

Keep PR #181 as draft while fixing it.

Update the existing PR description with:

1. each confirmed blocker and the implemented fix;
2. exact files changed in this remediation pass;
3. explicit confirmation that DOMAIN remains a normalized `https://` URL;
4. explicit confirmation that the commit mismatch remains fatal and actionable;
5. exact output and exit status of:
   - syntax checks;
   - strict ShellCheck;
   - `tests/test-recover.sh`;
   - existing focused tests;
   - systemd hardening;
   - rendered-unit validation;
   - Compose validation;
   - obsolete-path audit;
6. skipped checks and missing tools;
7. confirmation that the 11-line configuration stub was replaced with the restored detailed reference;
8. explanation that `lib/secrets.sh` is a minimal existing PR scope exception;
9. confirmation that no file outside the remediation-pass list changed.

Do not mark the PR ready for review until:

- all GitHub Actions checks are green;
- all eight recovery tests pass;
- strict ShellCheck passes;
- runtime parent permissions remain `0700`;
- fresh recovery installs the persistent environment into systemd;
- existing ciphertext is rekeyed when recipient state changes;
- bootstrap writes no plaintext to persistent storage;
- all handled recovery failures restore ciphertext, key, and policy;
- detailed configuration documentation is restored.

---

# Completion report

## Partial-completion protocol

If any target is blocked, keep PR #181 in draft and do not commit
half-finished transactions. For each incomplete target report:

- which target and which file/function work stopped at;
- the exact error or blocker;
- which validations did not run.

Do not describe any target as complete unless it is fully implemented
and its validation passed.

When finished, report:

- current branch;
- new commits;
- updated PR URL;
- exact changed-file list for this pass;
- validation summary;
- CI status;
- any skipped validation;
- any remaining caveat.

Do not claim PR #181 is merge-ready while a required check is red or any acceptance criterion above is unverified.
