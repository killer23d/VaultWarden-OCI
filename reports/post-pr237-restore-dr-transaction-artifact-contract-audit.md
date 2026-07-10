# Post-PR237 Restore / DR Transaction and Artifact Contract Audit

## Audit scope and evidence

Repository: `killer23d/VaultWarden-OCI`
Audited branch: `delta`
Audit branch: `audit/post-pr237-restore-dr-contracts`
Post-PR237 base evidence: PR #237 merged as `b8537aaf55abdd0324e579d27051d21107182e6a`; the audited `delta` ref was one commit ahead of that merge and that intervening commit changed only `CHANGELOG.md`. The audit branch was created directly from the then-current `delta` ref before this report was written.

This is a report-only static audit. No production code, tests, workflows, or existing reports were modified. No destructive restore was executed.

The audit followed the current `AGENTS.md` scope rules and traced the executable producer/consumer and promotion/error contracts together. Primary code reviewed:

- `restore.sh`
- `utilities/restore-run.sh`
- `utilities/backup-run.sh`
- `lib/backup-utils.sh`
- `recover.sh`
- `lib/crypto.sh`
- `lib/storage.sh`
- `lib/operations.sh`
- `lib/runtime-permissions.sh`
- `startup.sh`
- `tests/test-backup.sh`
- `tests/test-restore-recovery.sh`
- `docs/BACKUP-RESTORE.md`
- `docs/DISASTER-RECOVERY.md`
- `docs/RECOVERY-CARD.md`
- `docs/BOOTSTRAP_KEY_RECOVERY.md`

Directly related setup/dependency behavior in `utilities/setup-system.sh` was also inspected where required to distinguish documented fresh-host preparation from `restore.sh`'s own preflight contract.

`restore.sh` is only a dispatcher. The material restore risk surface is `utilities/restore-run.sh`.

## Executive conclusion

The audit confirmed seven bounded defects. Five are restore transaction/artifact/preflight defects that should be fixed before destructive live restore testing. Two are lower-severity operator-truth defects; one of those should also be included in the same focused fix PR because it affects the exit/status semantics of live test results.

The highest-risk results are:

1. an emergency passphrase archive can be uploaded remotely without its restore-critical `.meta` sidecar and still be described as having its primary backup delivered;
2. full/emergency safety-net restart eligibility is based only on SQLite integrity, even though broader state/config/key promotion can still be uncommitted or mixed-generation;
3. boot same-layout promotion has no rollback if the old state rename succeeds and the staged state rename fails;
4. selected dependencies are not fully closed before service stop on fresh-host default rekey and actual-mountpoint/`DATA_VOLUME_DEVICE`-unset paths;
5. legacy version-1 absolute archives bypass staging and extract directly to `/`.

These are narrow shell transaction and contract problems. None requires a transaction framework, workflow engine, registry, state database, or architectural rewrite.

---

## Backup → restore contract

| Backup type | Primary artifact | Filename / format | Metadata | Integrity sidecars | Encryption mode / decryption role | Restore consumer |
| --- | --- | --- | --- | --- | --- | --- |
| `db` | encrypted SQLite snapshot | `db-*.sqlite3.age` | `.meta`; descriptive/version fields | `.sha256`; optional `.sha256.hmac` | Age recipient; selected operational/old/offline matching private identity | `restore_db` |
| `full` | encrypted relative tar+zstd archive | `full-*.tar.zst.age`, current version 2 | `.meta`; source storage/layout and archive format | `.sha256`; optional `.sha256.hmac` | Age recipient; selected matching private identity | `restore_full_preflight` → `restore_full` |
| `emergency` passphrase | encrypted relative tar+zstd clone-grade archive | `emergency-*.tar.zst.age`, current version 2 | `.meta` contains `encryption_mode=age-passphrase` | `.sha256`; optional `.sha256.hmac` | `age -p`; operator emergency passphrase | `_age_decrypt_restore_backup` passphrase branch → `restore_full` |
| `emergency` Age recipient | encrypted relative tar+zstd clone-grade archive | `emergency-*.tar.zst.age`, current version 2 | `.meta` contains `encryption_mode=age-recipient` | `.sha256`; optional `.sha256.hmac` | independent emergency recipient identity, or selected matching identity under current fallback | `_age_decrypt_restore_backup` recipient branch → `restore_full` |

### Producer/consumer result

Current backup creation does not accept a current full/emergency artifact as successfully created unless metadata creation succeeds. `perform_full_backup` records `encryption_mode`, `archive_format`, storage information, and database snapshot metadata after the encrypted primary and integrity sidecars are created.

The restore consumer does not treat every metadata field equally:

- `archive_format` can be inferred for current `.tar.zst.age` artifacts;
- version can be `unknown`;
- `encryption_mode` is restore-critical for emergency passphrase artifacts because it selects whether `age` runs in interactive passphrase mode or with an identity;
- an unknown emergency `encryption_mode` is not rejected and falls through the identity decrypt path.

Therefore current `encryption_mode` is not advisory metadata. It is dispatch metadata.

---

## Local → remote artifact contract

| Artifact | Current remote transfer | Restore consumption | Classification |
| --- | --- | --- | --- |
| primary `.age` | required; upload failure returns hard failure | required | restore-critical |
| `.meta` for `db` | best-effort sidecar | optional/inferred fields | optional diagnostic/compatibility metadata |
| `.meta` for current `full` v2 | best-effort sidecar | format/layout information; current `.zst` format can partly infer | integrity/compatibility enhancing; not always strictly required |
| `.meta` for `emergency` passphrase | best-effort sidecar | selects passphrase decrypt dispatch | **restore-critical** |
| `.meta` for `emergency` recipient | best-effort sidecar | selects explicit recipient-mode semantics | restore-critical to unambiguous protection-mode dispatch |
| `.sha256` | best-effort sidecar | verified when present; warning and continue when absent | integrity-enhancing but not required |
| `.sha256.hmac` | best-effort sidecar | current remote pull does not download it; restore's inline checksum path does not authenticate the checksum sidecar | integrity-enhancing/authentication sidecar, not restore-critical to decryption |
| local current metadata | mandatory for current full/emergency backup creation | consumed by restore | producer-required |

`sync_to_rclone` uploads the primary first and sidecars independently. Any sidecar failure currently produces return code `2`; the caller records `synced with sidecar warnings` and logs that the primary backup was delivered. That is correct for an optional diagnostic sidecar, but not for emergency `.meta`.

The remote protocol does not need all sidecars to become mandatory. It needs type-aware classification of the companion artifacts that are necessary for supported restore dispatch.

---

## Metadata compatibility contract

### Current behavior

`read_meta_field` returns an empty/default value when `.meta` is absent.

For archive format:

- `.tar.zst.age` / `.zst.age` infers `relative`;
- version 2 infers `relative`;
- version 1 infers `absolute`;
- otherwise restore defaults to `relative` with a warning.

For emergency encryption mode:

- `age-passphrase` chooses `age -d -o ...` and lets Age prompt for the passphrase;
- `age-recipient` can choose the configured independent emergency identity;
- empty metadata is logged as `age-recipient (inferred)`;
- any other non-empty/unknown value also falls through `_age_decrypt_restore_backup` to the generic identity path.

### Compatibility judgment

Current archive-format fallback for current `.zst` artifacts is recoverable and conservative enough for version-2 filename grammar.

Current emergency protection-mode fallback is not fail-safe. The current producer has two modes with materially different Age invocation semantics. There is no artifact-level proof that missing mode metadata means recipient mode, and there is no proof that an unknown future/malformed mode is identity-decryptable.

Unknown emergency modes should be rejected explicitly. Missing current emergency metadata should be treated as ambiguous rather than silently mapped to an Age identity.

---

## Restore preflight closure

### Closed before destructive mutation

The current code closes these knowable prerequisites before service stop for current full/emergency version-2 paths:

- selected source artifact exists;
- remote primary is downloaded;
- `.sha256` is verified when present and verification is not skipped;
- selected archive compressor (`zstd`) is required;
- archive decrypt capability is exercised during full/emergency preflight;
- archive structure is listed;
- archive source root/storage mode is inspected;
- exactly one live database is required, excluding `.pre-restore-*` snapshot DBs;
- block-source → boot-target mismatch is rejected;
- mounted block target must be an actual writable mountpoint;
- traversal/member validation is performed for current relative archives;
- selected Age identity is resolved for identity-mode paths;
- PUID/PGID must be valid non-root numeric IDs.

### Not fully closed

Two selected-plan executable dependencies can still be first discovered after service stop or after live promotion:

1. `sops` on a fresh target with no live `${STATE_DIR}/secrets/secrets.yaml`, even though default post-restore key rotation/rekey uses `sops`;
2. `rsync` when `STATE_DIR` is an actual mountpoint but `DATA_VOLUME_DEVICE` is unset.

The documented replacement-host procedure runs `utilities/setup-system.sh --auto`, which normally installs these tools. That is good operational guidance, but it does not close the executable contract of a CLI that also advertises a fresh-server remote restore path.

---

## Restore transaction boundaries

| Restore type | Pre-destructive | Destructive start | Staged state | Live promotion starts | Current coherent/commit point | Safe startup point |
| --- | --- | --- | --- | --- | --- | --- |
| `db` | source/key/checksum selection and inspect | services stopped; `RESTORE_DESTRUCTIVE_PHASE_STARTED=true` | decrypted SQLite in secure restore temp | same-filesystem temp DB is copied then atomically renamed over live DB | successful atomic DB rename, integrity-valid DB, WAL/SHM purge | after successful DB promotion; DB restore intentionally preserves broader config/secrets |
| `full` v2 | decrypt, archive/layout preflight, target preparation, safety snapshot | services stopped | archive extracted under `$TMPDIR_RESTORE/stage` | payload state move/copy/rsync | **not represented explicitly today**; restore crosses payload, SOPS secrets, project config, rekey and key acknowledgement without a full-promotion commit state | after broader promotion and required rekey decision have completed coherently |
| `emergency` v2 | same plus emergency protection-mode/key dispatch | services stopped | archive extracted under staging, including optional staged `/etc/vaultwarden` | payload promotion, then secrets and emergency `/etc` material | **not represented explicitly today**; emergency key/config and SOPS rekey cross multiple live mutations | after broader promotion, emergency material, and required rekey/key-custody boundary are complete |
| `full`/`emergency` v1 absolute | decrypt and traversal check | services stopped | **none** | tar extraction directly to `/` | no transactional commit boundary | cannot be inferred from SQLite alone |

### Exact safe automatic restart point

For a DB-only restore, the successful same-filesystem DB replacement plus SQLite integrity is sufficient evidence for the narrow restore type.

For current full/emergency restore, SQLite integrity is necessary but not sufficient. The narrow safe restart boundary is after:

1. `restore_full` has returned successfully;
2. the selected key-rotation/rekey decision has completed successfully or has been explicitly skipped by the operator/policy;
3. any required `SAVED` acknowledgement has completed.

At that point the current flow treats the restore as eligible for the normal start-policy gate. A full/emergency commit flag should model that exact point. It should not be set merely when the new DB exists.

Permission repair remains a post-promotion start-preparation step. A repair failure should be reported truthfully and should not cause a pre-commit safety-net restart.

---

## Promotion failure-boundary table

| Restore type | Storage layout | Mutation completed | Next failure | Rollback behavior | Autostart behavior | Final state |
| --- | --- | --- | --- | --- | --- | --- |
| DB | boot or block | live DB pre-copy created | decrypt/integrity fails before promotion | live DB untouched | services not yet stopped for preflight failure | old state |
| DB | boot or block | temp DB copied | atomic `mv` fails | temp removed; pre-restore DB copy is copied back | integrity predicate evaluates restored/old DB | old DB normally restored |
| DB | boot or block | atomic DB `mv` succeeds | later ordinary failure | DB-specific state is already committed | current DB-only integrity predicate may restart | coherent DB restore with existing config |
| Full/emergency v2 | mounted block | live `data/caddy/logs` moved into in-volume snapshot | payload `rsync` fails | `_rollback_payload_paths` removes created paths and moves tracked old payloads back | DB usually old/restored; safety net evaluates integrity | payload rollback attempted; protected paths untouched |
| Full/emergency v2 | mounted block | all allowlisted payload `rsync` succeeds | encrypted secrets install fails | payload rollback helper is already out of scope; no broader rollback | valid new DB can satisfy `_can_safe_restart` | new payload plus old/partial secrets/config; possible auto-start |
| Full/emergency v2 | mounted block | encrypted secrets promoted | project `.env`/compose/config copy fails | no rollback of secrets or payload | valid new DB can satisfy `_can_safe_restart` | mixed-generation state; possible auto-start |
| Emergency v2 | mounted block | `/etc/vaultwarden/age-key.txt` installed | later `/etc` or project config promotion fails | no rollback of installed emergency material | valid new DB can satisfy `_can_safe_restart` | mixed key/config generation; possible auto-start |
| Full/emergency v2 | boot same-layout | old `$STATE_DIR` renamed to sibling `.pre-restore-*` | staged state `mv` to `$STATE_DIR` fails | **no rollback in current code** | no live DB at expected path normally prevents autostart | live state path absent; old state stranded at sibling snapshot |
| Full/emergency v2 | non-mounted cross-root branch | `data/` copied successfully | `caddy/` copy fails | no cross-root payload ledger | new DB can satisfy `_can_safe_restart` | mixed payload generations; possible auto-start |
| Full/emergency v2 | any | payload/config promotion succeeds | default rekey reaches missing `sops` on fresh target | key rotation caller disables autostart after the late dependency failure | autostart explicitly prohibited | promoted state, services stopped, manual remediation |
| Full/emergency v2 | actual mounted `STATE_DIR`, device unset | services stopped and staging extracted | in-function `command -v rsync` fails | no live payload has moved yet | DB is still old/valid and current safety net may restart it | avoidable stop/restart cycle; dependency discovered late |
| Full/emergency v1 | any supported target | tar has overwritten one or more absolute-root members | tar extraction fails/receives signal | no staged restore rollback | valid old/new DB may satisfy SQLite-only predicate | partially overwritten root/project/state; possible auto-start |
| Full/emergency v2 | any | full promotion not committed | INT/HUP/TERM during secrets/config copy | signal trap enters the same safety net; no broader rollback | SQLite-only predicate may restart | materially same mixed-generation risk as ordinary failure |
| Full/emergency v2 | any | key rekey succeeds and required acknowledgement completes | later startup fails | key artifacts remain committed; startup returns nonzero | safety net may retry only while ERR trap remains armed | committed restore, service failure requires diagnosis |
| Any started restore | any | services start | critical `maintenance-health.sh` exits nonzero | no rollback is appropriate post-commit | services remain as started | current code warns, then prints `Restore complete.` and returns success |

---

## ERR and signal behavior

### Before destructive mutation

The top-level cleanup/operation-release traps run. Full/emergency preflight failures do not stop services and do not invoke the destructive safety-net restart.

### After service stop

`ERR`, `HUP`, `INT`, and `TERM` are all trapped by `_restore_safety_net`. The handler removes those traps, guards against re-entry, inspects `RESTORE_DESTRUCTIVE_PHASE_STARTED`, and under `START_POLICY=auto` calls `_can_safe_restart`.

### DB promotion

The DB path has its own temp-file/atomic-rename rollback handling. At this narrow scope, an integrity-valid live DB is an appropriate safety restart predicate.

### Full payload promotion

A mounted block target has a local payload rollback ledger only while the `data/caddy/logs` loops are active. The ledger is not available for later secrets, `/etc/vaultwarden`, project config, or rekey boundaries.

### Secrets and configuration promotion

Ordinary non-zero returns and signals can escape after one or more live files/directories have been changed. The shared safety net does not know whether broader promotion is committed.

### Rekey and key promotion

`_rotate_age_key` has its own transactional rollback behavior and its caller sets `RESTORE_PREVENT_AUTOSTART=true` when `_rotate_age_key` returns failure. However, a signal or ERR at a broader pre-commit boundary should not depend on every inner helper remembering to set that flag. An explicit full/emergency commit predicate is the correct outer contract.

### Signal-specific conclusion

A signal can leave state materially different from a clean failure because it can interrupt `cp -a`, `install`, or archive extraction in the middle of the external command's writes. The current trap then applies the same SQLite-only restart predicate used for an ordinary command failure. The missing commit state therefore affects both ordinary errors and INT/HUP/TERM.

The fix does not need signal-specific rollback machinery. The safety property is: an uncommitted full/emergency restore must not be automatically started after either class of failure.

---

## Safe restart contract

Current `_can_safe_restart` means:

> `$STATE_DIR/data/db.sqlite3` exists and `PRAGMA integrity_check` returns `ok`.

That is evidence about SQLite integrity only.

### DB restore

Sufficient, because DB restore deliberately leaves project config, SOPS secrets, operational Age identity, and storage layout in place.

### Full restore

Insufficient. Full restore may already have changed `data/` while secrets or project config are old/partial.

### Emergency restore

Insufficient. Emergency restore additionally may have installed a different `/etc/vaultwarden/age-key.txt`, `vaultwarden.env`, or `rclone.conf` generation before later failure.

### Design comparison required by Hypothesis B

#### 1. Restore-type-aware `_can_safe_restart` only

Better than the current generic predicate, but type awareness alone still needs a way to answer whether full/emergency promotion completed. Adding a growing list of filesystem probes would recreate an implicit subsystem registry and still would not model the actual transaction boundary.

#### 2. Explicit full/emergency promotion commit flag only

Accurately models broader restore state, but by itself loses the useful DB-specific SQLite integrity gate and can make the meaning of “committed” too broad across restore types.

#### 3. Small combination — recommended

Keep the SQLite integrity check. Add one explicit `RESTORE_FULL_PROMOTION_COMMITTED=false` state flag. `_can_safe_restart` branches by `RESTORE_TYPE`:

- `db`: integrity-valid DB is sufficient;
- `full|emergency`: commit flag must be true **and** DB integrity must pass.

Set the full/emergency flag only after `restore_full` and the post-restore key rotation/rekey decision/acknowledgement have completed.

This is four-state facts already present in the control flow—restore type, destructive started, full promotion committed, autostart prohibited—not a transaction framework.

---

## Storage-layout contract

| Layout | Live paths affected | Staging | Promotion | Rollback | Config/secrets behavior | Restart eligibility |
| --- | --- | --- | --- | --- | --- | --- |
| boot → boot same-layout | full `$STATE_DIR`, then secrets/project config | `$TMPDIR_RESTORE/stage` | old state directory rename, then staged state directory rename | none between the two renames | staged secrets/project config subsequently promoted | only after explicit full/emergency commit |
| block → mounted block | allowlisted `data/caddy/logs`; protected state metadata remains in place | `$TMPDIR_RESTORE/stage` | old payload moved into in-volume snapshot; `rsync` staged payload | explicit payload ledger during payload phase | `secrets` promoted separately; state `config` protected; project config promoted separately | only after explicit full/emergency commit |
| boot archive → mounted block target | mounted-target allowlist path | `$TMPDIR_RESTORE/stage`; preflight source root points at archived boot state | same mounted payload ledger/`rsync` path | payload rollback equivalent to block target | protected target metadata remains; archive secrets/project config handled separately | only after explicit full/emergency commit |
| non-mounted cross-root compatibility branch | allowlisted payload | `$TMPDIR_RESTORE/stage` | per-directory old rename + `cp -a` | no ledger | later secrets/project config promotion | only after explicit full/emergency commit |
| v1 absolute | arbitrary archived absolute-root members | none | direct tar extraction to `/` | none | archive controls affected legacy members subject to traversal check | must not use DB-only safety inference |

The mounted block path is materially stronger than boot same-layout and the non-mounted cross-root compatibility branch. Cosmetic symmetry is not required, but equivalent failure safety is.

For boot same-layout, a two-rename swap needs a local rollback if the second rename fails.

For broader full/emergency coherence, the primary requirement is not to roll back every promoted file automatically. The smallest safe correction is to prohibit automatic startup until broader promotion/rekey has crossed an explicit commit boundary. Existing pre-restore snapshots remain the operator recovery point for failures that are not cheaply reversible.

---

## Key-role separation

| Key/material | Role | Current relevant behavior | Audit judgment |
| --- | --- | --- | --- |
| operational Age private key | live SOPS/normal backup identity | canonical production path `/etc/vaultwarden/age-key.txt` | role is explicit |
| offline recovery Age private key | off-host recovery identity | used in place by `recover.sh`; not installed as live operational key | contract closed |
| old backup Age identity | decrypt historical `db`/`full` artifact | selected via restore key-file/recovery-kit prompt | role is explicit |
| emergency Age recipient identity | independent emergency archive envelope | `_age_decrypt_restore_backup` recipient branch can use configured emergency identity | role is explicit when metadata is present |
| emergency passphrase | independent `age -p` envelope | selected only by `encryption_mode=age-passphrase` | mode selection depends on restore-critical metadata |
| archive decryption key | decrypt selected `.age` artifact | `RESTORE_DECRYPT_AGE_KEY_FILE` | separated from operational SOPS key |
| SOPS rekey source identity | decrypt promoted `secrets.yaml` during `sops updatekeys` | DB uses operational key; full/emergency chooses selected/restored key by mode | explicit and generally correct |
| generated replacement operational key | new live identity after restore | `_rotate_age_key` stages, validates, promotes, updates env, rolls back its own artifacts on failure | transaction contract closed locally |

No current path in `recover.sh` installs the offline USB key as the live operational key. The recovery transaction validates the offline recipient, generates a new operational key, stages rekeyed ciphertext/config, promotes under explicit artifact flags, and sets `RECOVERY_COMMITTED=true` only after promoted identity/config validation.

The restore defect is not key-role confusion inside `_rotate_age_key`. It is the outer restore transaction's lack of a commit predicate and emergency protection-mode ambiguity when `.meta` is missing.

---

## Required restore matrix

| Restore | Source | Target | Encryption / key | Sidecar state | Static result |
| --- | --- | --- | --- | --- | --- |
| DB | local | existing boot | operational/old Age key | all present | supported; atomic DB replacement |
| DB | remote | fresh/existing | recovery/old matching key | `.sha256` absent | restore warns and relies on Age/SQLite checks; supported by current policy |
| DB | remote | fresh/existing | recovery/old matching key | HMAC absent | restore does not consume remote HMAC sidecar; no dispatch impact |
| Full | local | boot same-layout | Age recipient | all present | preflight closes archive/layout; second rename rollback gap remains |
| Full | remote | mounted block | old/offline matching Age key | all present | mounted payload ledger is strong; broader commit/restart gap remains |
| Full | boot archive | mounted block target | cross-layout Age recipient | all present | preflight detects source root; mounted target uses allowlist/rsync ledger |
| Full | remote | mounted block | Age recipient | `.meta` absent | current zstd filename infers relative format; sidecar loss is not necessarily fatal |
| Full | remote | any | Age recipient | `.sha256` absent | warning; no pre-decrypt checksum, but Age and archive validation still run |
| Full | remote | any | Age recipient | HMAC absent | no current restore dispatch impact |
| Emergency | local | same-layout | passphrase | `.meta` present | correct passphrase prompt/decrypt dispatch |
| Emergency | remote | replacement host | passphrase | all present | correct passphrase dispatch |
| Emergency | remote | replacement host | passphrase | **`.meta` absent** | **incorrectly inferred as Age-recipient; identity path selected; supported restore fails** |
| Emergency | remote | replacement host | Age recipient | all present | recipient identity path supported |
| Emergency | remote | replacement host | Age recipient | `.meta` absent | recipient inference may happen to match, but artifact contract cannot prove the mode |
| Emergency | remote | replacement host | either | `.sha256` absent | warning; restore continues |
| Emergency | remote | replacement host | either | HMAC absent | current restore does not pull/use it |
| Emergency | remote | replacement host | passphrase | `.meta` upload failed but primary succeeded | backup caller reports primary delivered with sidecar warning; remote restore later lacks mode dispatch |
| Any remote | remote | any | any | one non-critical sidecar upload failed | primary can be delivered with sidecar warning; acceptable only for sidecars not required by restore |

### Emergency passphrase + remote + missing `.meta` first-priority trace

1. `perform_full_backup emergency` has no `EMERGENCY_BACKUP_AGE_RECIPIENT`.
2. It runs `age -p` and sets `encryption_mode=age-passphrase`.
3. The encrypted `.age` archive is moved to its final local path.
4. Metadata creation succeeds locally and writes `encryption_mode=age-passphrase`.
5. `sync_to_rclone` uploads the primary `.age` successfully.
6. The `.meta` `rclone copyto` fails.
7. `sync_to_rclone` increments its generic sidecar failure count and eventually returns `2`.
8. The backup caller records `offsite_status="synced with sidecar warnings"` and logs that the primary backup was delivered.
9. A replacement host selects the remote emergency `.age`; remote pull downloads the primary.
10. Remote `.meta` pull is best-effort and failure is ignored.
11. `read_meta_field` returns empty `encryption_mode`.
12. Restore logs `age-recipient (inferred)`.
13. Restore prompts/resolves an Age identity rather than choosing the `age -p` path.
14. `_age_decrypt_restore_backup` falls through to identity decryption.
15. The valid passphrase emergency archive is unusable through the supported remote restore flow until the missing mode metadata is restored.

---

# Confirmed findings

## [RDR-01] — Emergency protection mode is restore-critical but `.meta` is remotely optional

**Classification:**
Fix before live restore testing

**Severity:**
High

**Confidence:**
High

**Affected files and symbols:**
`utilities/backup-run.sh` — `perform_full_backup`, `sync_to_rclone`, backup run rclone result handling
`utilities/restore-run.sh` — `pull_remote_backup`, `read_meta_field`, `_restore_backup_encryption_mode`, `_age_decrypt_restore_backup`, `main`

Current references: `utilities/backup-run.sh` around `sync_to_rclone` and the `age-passphrase`/`age-recipient` metadata write; `utilities/restore-run.sh` around remote sidecar pull, metadata parsing, and emergency decrypt dispatch.

**Contract being violated:**
Producer/consumer and local→remote artifact contract. A primary offsite artifact must not be reported as safely delivered when a missing restore-critical companion prevents the supported restore consumer from selecting its decrypt mechanism.

**Current behavior:**
Current emergency backup creation writes `encryption_mode=age-passphrase` or `age-recipient` only to `.meta`. Remote sync treats `.meta`, `.sha256`, and `.sha256.hmac` uniformly as optional sidecars. A `.meta` upload failure returns the same partial-sidecar status used for integrity sidecars, and the caller says the primary backup was delivered.

Remote restore pulls `.meta` with `|| true`. Missing emergency mode is inferred as `age-recipient`. `_age_decrypt_restore_backup` uses passphrase mode only for the exact `age-passphrase` string; empty or unknown modes fall into an identity path.

**Concrete failure sequence:**

1. A valid emergency backup is created interactively without `EMERGENCY_BACKUP_AGE_RECIPIENT`.
2. `age -p` successfully encrypts the archive.
3. Local `.meta` successfully records `encryption_mode=age-passphrase`.
4. Rclone uploads the primary `.age` file.
5. Rclone fails to upload `${archive}.meta`.
6. `sync_to_rclone` returns its generic sidecar-warning status.
7. The backup run logs that the primary backup was delivered and does not classify offsite protection as failed.
8. The local host is later unavailable.
9. A replacement host selects the remote emergency primary.
10. Restore downloads the primary and silently fails to download `.meta`.
11. `backup_encryption_mode` is empty.
12. Restore reports recipient mode as inferred and resolves an Age identity.
13. `_age_decrypt_restore_backup` does not enter its passphrase branch.
14. Age identity decryption fails against the passphrase-encrypted artifact.
15. The valid remote archive cannot be restored through the documented supported workflow without reconstructing/restoring the missing metadata.

**Production impact:**
The operator can believe an emergency recovery point was delivered offsite even though the supported remote restore flow cannot determine its protection mode. In a host-loss event this converts a valid encrypted archive into an operationally unusable recovery point until metadata is recovered manually.

**Why existing tests do not close this:**
`tests/test-backup.sh` asserts that current emergency metadata contains `encryption_mode` and functionally checks metadata formatting. `tests/test-restore-recovery.sh` executes `_age_decrypt_restore_backup` for explicit `age-passphrase` and `age-recipient` values. Neither test injects a `.meta` rclone upload failure followed by a remote emergency pull, nor asserts that a passphrase primary without `.meta` is rejected before identity dispatch.

**Minimal fix direction:**
Recommend strategy 1: make `.meta` a mandatory offsite companion for emergency archives and fail closed when remote emergency metadata is missing/unknown.

Do not make every sidecar mandatory. `.sha256` and `.sha256.hmac` can retain their existing warning semantics.

### Special design comparison

1. **Mandatory emergency `.meta` offsite — recommended.** No primary format change; no secret exposure beyond metadata already created locally; deterministic operator status; easy to test. Rclone uploads are still individual operations, but the backup run can truthfully classify offsite delivery as failed until the restore-critical companion is present.
2. **Self-describing primary.** Strong long-term format property, but requires a new envelope/filename/header contract and compatibility migration across producer/consumer paths. Too broad for this defect.
3. **Try identity and passphrase modes.** Rejected. `age -p` is interactive, trial order can produce confusing prompts, and error-driven fallback blurs independent emergency key/passphrase roles.

Unknown non-empty `encryption_mode` values should also fail closed rather than fall through to the generic identity path.

**Proposed production code snippet:**

`utilities/backup-run.sh` — focused change inside `sync_to_rclone` and its caller:

```bash
# Inside sync_to_rclone()
local sidecar_fail_count=0
local critical_sidecar_failed=false
local suffix sidecar remote_sidecar

for suffix in .meta .sha256 .sha256.hmac; do
    sidecar="${local_file}${suffix}"
    [[ -f "$sidecar" ]] || continue
    remote_sidecar="${remote_dir}$(basename "$sidecar")"

    if ! rclone "${rclone_config_args[@]}" copyto "$sidecar" "$remote_sidecar"; then
        if [[ "$btype" == "emergency" && "$suffix" == ".meta" ]]; then
            critical_sidecar_failed=true
            backup_log_error \
                "Emergency metadata upload failed; remote archive protection mode is not recoverable through restore.sh."
        else
            sidecar_fail_count=$((sidecar_fail_count + 1))
            backup_log_warn "Failed to upload sidecar: $(basename "$sidecar")"
        fi
    fi
done

if [[ "$critical_sidecar_failed" == "true" ]]; then
    backup_log_error "Emergency primary exists remotely, but offsite delivery is incomplete until its .meta sidecar is uploaded."
    return 3
fi

if (( sidecar_fail_count > 0 )); then
    backup_log_warn "Primary backup archive was delivered with ${sidecar_fail_count} non-critical sidecar upload failure(s)."
    return 2
fi
```

Caller:

```bash
sync_to_rclone "$backup_file" "$actual_type" || _sync_rc=$?
case "$_sync_rc" in
    0)
        offsite_status="synced"
        ;;
    2)
        offsite_status="synced with sidecar warnings"
        log_warn "Offsite sync completed with non-critical sidecar warnings."
        ;;
    3)
        rclone_failed=true
        offsite_status="failed; emergency restore metadata missing remotely"
        log_error "Offsite emergency delivery is incomplete — local backup is safe."
        _print_backup_run_summary \
            "$actual_type" "$backup_file" "$verification_status" "$offsite_status"
        exit 2
        ;;
    *)
        rclone_failed=true
        offsite_status="failed; local backup is safe"
        log_error "Offsite sync failed — see above. Local backup is safe."
        _print_backup_run_summary \
            "$actual_type" "$backup_file" "$verification_status" "$offsite_status"
        exit 2
        ;;
esac
```

`utilities/restore-run.sh` — require unambiguous emergency metadata after remote pull and reject unknown modes:

```bash
# In pull_remote_backup(), after the best-effort sidecar copies.
if [[ "$btype" == "emergency" && ! -s "${local_file}.meta" ]]; then
    log_error "Remote emergency backup metadata is missing: $(basename "${local_file}.meta")"
    log_error "Cannot determine whether this archive requires an emergency passphrase or an Age identity."
    log_error "Restore the matching .meta sidecar, then retry."
    return 1
fi
```

```bash
if [[ "$RESTORE_TYPE" == "emergency" ]]; then
    case "$backup_encryption_mode" in
        age-passphrase|age-recipient)
            ;;
        "")
            log_error "Emergency backup metadata does not declare encryption_mode."
            log_error "Refusing to guess between passphrase and Age-identity decryption."
            exit 1
            ;;
        *)
            log_error "Unsupported emergency encryption_mode: $backup_encryption_mode"
            exit 1
            ;;
    esac
fi
```

**Proposed regression test snippet:**

`tests/test-backup.sh`:

```bash
test_emergency_meta_upload_failure_is_offsite_failure() {
    local dir="$TMP/emergency-meta-upload"
    mkdir -p "$dir"
    local archive="$dir/emergency-vaultwarden-20260709-120000.tar.zst.age"
    _write_archive_with_sidecars "$archive"

    rclone() {
        local cmd="${1:-}"
        shift || true
        if [[ "$cmd" == "copyto" && "${1:-}" == *".meta" ]]; then
            return 42
        fi
        return 0
    }

    local rc=0
    sync_to_rclone "$archive" emergency || rc=$?
    [[ "$rc" -eq 3 ]] \
        || fail "emergency .meta upload failure must return restore-critical status"
}
```

`tests/test-restore-recovery.sh`:

```bash
test_remote_emergency_without_meta_fails_during_pull() {
    TMPDIR_RESTORE="$TMP/missing-emergency-meta"
    RCLONE_CONFIG_ARG=()
    BACKUP_FILE=""
    RESTORE_TYPE=""

    rclone() {
        local cmd="${1:-}" source="${2:-}" destination="${3:-}"
        [[ "$cmd" == "copy" ]] || return 1

        case "$source" in
            *.meta|*.sha256)
                return 42
                ;;
            *.age)
                mkdir -p "$destination"
                printf 'encrypted-primary\n' \
                    > "$destination/$(basename "$source")"
                return 0
                ;;
        esac
        return 1
    }

    local rc=0
    pull_remote_backup \
        "mock:vaultwarden_backups/emergency/emergency-vaultwarden-20260709-120000.tar.zst.age" \
        emergency || rc=$?

    [[ "$rc" -ne 0 ]] \
        || fail "remote emergency primary without .meta unexpectedly passed pull"
    [[ -z "$BACKUP_FILE" ]] \
        || fail "ambiguous emergency artifact was exposed to decrypt selection"
}
```

This executes the actual remote-pull boundary. The safety property is that an emergency primary with missing `.meta` never becomes the selected `BACKUP_FILE`, so no decrypt mode can be guessed later.

**Proposed documentation change:**

`docs/BACKUP-RESTORE.md`:

```markdown
For emergency backups, the matching `.meta` sidecar is restore-critical because it records whether the archive is sealed with an emergency passphrase or an independent Age recipient. An emergency primary is not considered completely delivered offsite until its `.meta` companion is present.
```

**Complexity assessment:**
One type-aware sidecar classification and one fail-closed restore validation are proportionate. This reuses the current metadata format, rclone flow, and error handling. It adds no storage protocol, manifest database, or remote transaction layer.

---

## [RDR-02] — Full/emergency safety-net restart has no broader promotion commit predicate

**Classification:**
Fix before live restore testing

**Severity:**
High

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — `_can_safe_restart`, `_restore_safety_net`, `restore_full`, `main`, `_rotate_age_key`, `_display_new_key`

Current references: `_can_safe_restart` around line 1602; `restore_full` around lines 2146–2428; `_restore_safety_net` around lines 2723–2758; key/rekey decision around lines 2858–2877.

**Contract being violated:**
Restore transaction and startup-eligibility contract. A full/emergency restore must not automatically start until broader state/config/secrets/key promotion is coherent enough for the normal startup path.

**Current behavior:**
`_can_safe_restart` checks only live SQLite existence and `PRAGMA integrity_check`. `_restore_safety_net` uses that predicate for all restore types.

Mounted block payload promotion has a local rollback ledger, but after that phase `restore_full` directly promotes encrypted SOPS secrets, emergency `/etc/vaultwarden` material, and project config. There is no outer full/emergency commit flag. A failure or signal after a valid new DB is live but before broader promotion/rekey completes can trigger `startup.sh --skip-pull`.

`startup.sh` immediately synchronizes environment, loads project configuration, prepares runtime secrets, and starts containers. SQLite integrity does not prove those inputs belong to a coherent restore generation.

**Concrete failure sequence:**

1. A valid full backup is selected with `START_POLICY=auto`.
2. Preflight decrypts and validates the archive and storage layout.
3. The pre-restore snapshot step returns success.
4. Services are stopped and `RESTORE_DESTRUCTIVE_PHASE_STARTED=true`.
5. On a mounted block target, live `data/caddy/logs` are moved to the in-volume snapshot.
6. All staged payload `rsync` operations succeed.
7. The restored DB at `$STATE_DIR/data/db.sqlite3` passes `PRAGMA integrity_check`.
8. Restored encrypted `secrets.yaml` is installed.
9. Project config promotion begins.
10. A later `cp -a` for `caddy/`, `crowdsec/`, or `nginx/` returns non-zero, or INT/TERM interrupts that command.
11. `restore_full` returns/aborts before the post-restore rekey decision is committed.
12. `RESTORE_PREVENT_AUTOSTART` is still false because the failure did not pass through `_rotate_age_key`'s explicit failure handling.
13. `_restore_safety_net` sees destructive work started and `START_POLICY=auto`.
14. `_can_safe_restart` sees the valid restored SQLite DB and returns success.
15. The safety net invokes `startup.sh --skip-pull`.
16. Startup synchronizes/loads the partially promoted environment and materializes runtime secrets against mixed-generation state.
17. Containers may start against a valid DB but incoherent project/secrets/key/config state.

**Production impact:**
A restore error can be followed by an automatic service start against mixed-generation state. Outcomes include failed secret materialization, Caddy/config mismatch, wrong key generation, stale compose/env values, or a service that starts enough to appear partially available while the restore transaction is incomplete.

**Why existing tests do not close this:**
`tests/test-restore-recovery.sh` structurally asserts that the safety-net trap exists and that the mounted payload path tracks moved/created payload paths. Its cross-layout harness executes a successful restore. It does not inject a failure after DB/payload promotion but before full/emergency commit and assert that startup is not called.

The same suite already uses concrete failure and INT/TERM injection for `recover.sh`, demonstrating an existing test style suitable for this boundary.

**Minimal fix direction:**
Use the small combination of a restore-type-aware `_can_safe_restart` and one explicit full/emergency promotion commit flag.

Do not add a subsystem registry or generic transaction object.

Initialize the flag before destructive work. Leave it false through `restore_full` and rekey/key acknowledgement. Set it true only after the current flow has completed the key-rotation decision successfully or explicitly skipped it. The safety net should require both that flag and SQLite integrity for full/emergency restores.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
# Near the existing restore state flags.
RESTORE_PREVENT_AUTOSTART=false
RESTORE_FULL_PROMOTION_COMMITTED=false
```

```bash
_can_safe_restart() {
    local db="$STATE_DIR/data/db.sqlite3"
    [[ -f "$db" ]] || return 1

    case "${RESTORE_TYPE:-}" in
        db)
            ;;
        full|emergency)
            [[ "${RESTORE_FULL_PROMOTION_COMMITTED:-false}" == "true" ]] \
                || return 1
            ;;
        *)
            return 1
            ;;
    esac

    sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx ok
}
```

Keep the destructive boundary explicit:

```bash
if [[ "$DRY_RUN" != "true" ]]; then
    operation_set_phase "stop" "Stopping VaultWarden services"
    log_info "Stopping services (up to 30s grace period)..."
    if ! timeout 35 docker compose stop --timeout 30; then
        log_warn "docker compose stop did not complete cleanly within 35s — forcing..."
        docker compose kill 2>/dev/null || true
    fi
    RESTORE_DESTRUCTIVE_PHASE_STARTED=true
fi
```

Set the broader commit flag only after the existing rekey decision/acknowledgement boundary:

```bash
local _rotate_decision_rc=0
_restore_should_rotate_age_key
_rotate_decision_rc=$?
if (( _rotate_decision_rc == 0 )); then
    if ! _rotate_age_key; then
        log_error "Age key rotation FAILED."
        log_error "The data restore itself succeeded, but key rotation/rekey did not complete safely."
        log_error "Live key artifacts were rolled back where needed; refusing to start services automatically."
        RESTORE_PREVENT_AUTOSTART=true
        exit 1
    fi
    _display_new_key || exit 1
elif (( _rotate_decision_rc == 1 )); then
    log_warn "Age key rotation was skipped; confirm this is intentional before starting services."
else
    log_error "Restore requires manual review before services are started."
    exit 1
fi

if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]]; then
    RESTORE_FULL_PROMOTION_COMMITTED=true
fi
```

The existing `_restore_safety_net` can keep calling `_can_safe_restart`; its meaning is now type-aware.

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_uncommitted_full_restore_never_autostarts() {
    local dir="$TMP/full-uncommitted"
    mkdir -p "$dir/state/data"
    sqlite3 "$dir/state/data/db.sqlite3" \
        'CREATE TABLE test(id INTEGER PRIMARY KEY);'

    RESTORE_TYPE=full
    STATE_DIR="$dir/state"
    START_POLICY=auto
    RESTORE_DESTRUCTIVE_PHASE_STARTED=true
    RESTORE_PREVENT_AUTOSTART=false
    RESTORE_FULL_PROMOTION_COMMITTED=false
    STARTUP_CALLED=false

    bash() {
        if [[ "${1:-}" == */startup.sh ]]; then
            STARTUP_CALLED=true
        fi
        return 0
    }

    if _can_safe_restart; then
        fail "uncommitted full restore was considered safe to restart"
    fi
    [[ "$STARTUP_CALLED" == "false" ]] \
        || fail "startup was called for uncommitted full restore"

    RESTORE_FULL_PROMOTION_COMMITTED=true
    _can_safe_restart \
        || fail "committed full restore with valid DB should pass restart predicate"
}
```

And a failure-injection harness should execute the promotion boundary, not only the predicate:

```bash
test_config_failure_after_full_db_promotion_does_not_start() {
    local dir
    dir="$(make_restore_case full block)"
    write_restore_mocks "$dir"

    if MOCK_CP_FAIL_DEST="$dir/repo/caddy" \
        run_restore_case "$dir"; then
        fail "injected config promotion failure unexpectedly succeeded"
    fi

    [[ -f "$dir/state/data/db.sqlite3" ]] \
        || fail "test did not reach post-DB-promotion boundary"
    ! grep -q '^startup$' "$dir/start-calls.log" \
        || fail "uncommitted full restore invoked startup"
}
```

Repeat the same harness with `MOCK_CP_SIGNAL_DEST=...` for INT and TERM and assert the same no-start property.

**Proposed documentation change:**

`docs/BACKUP-RESTORE.md`:

```markdown
For `full` and `emergency` restores, automatic error recovery may start services only after broader state/config/key promotion has crossed the restore commit boundary. A valid SQLite database alone is not sufficient evidence that a broader restore is startable.
```

**Complexity assessment:**
One boolean and a three-way restore-type branch model a real existing boundary. This mirrors the explicit commit-state philosophy already proven in `recover.sh` without copying its artifact ledger or introducing a generic transaction framework.

---

## [RDR-03] — Boot same-layout state swap does not roll back a failed second rename

**Classification:**
Fix before live restore testing

**Severity:**
Medium

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — `restore_full`, boot-only same-layout branch

Current reference: `restore_full` around the old-state `mv "$state_dir" "${state_dir}.pre-restore-${ts}"` followed by `mv "$staging/$rel_source" "$state_dir"`.

**Contract being violated:**
Storage-layout and promotion transaction contract. Equivalent restore safety requires that a failed two-step directory swap not leave the live state path absent when the old state is still immediately recoverable.

**Current behavior:**
The boot same-layout branch renames the current state directory to a sibling snapshot and then renames the staged state directory into place. The second `mv` is unguarded. If it fails, the function exits under `set -e`; no code moves the old state directory back.

The mounted block path has an explicit payload rollback ledger. The semantics do not need identical code, but the boot two-rename path can provide equivalent local safety with a four-line rollback.

**Concrete failure sequence:**

1. A valid version-2 full/emergency backup is selected for an existing boot-volume target.
2. Archive preflight succeeds.
3. Services stop.
4. The archive extracts successfully to staging.
5. `source_root == state_dir` and `state_dir` is not a mountpoint.
6. `mv "$state_dir" "${state_dir}.pre-restore-${ts}"` succeeds.
7. The filesystem now has no live `$state_dir`.
8. `mv "$staging/$rel_source" "$state_dir"` fails, for example because of an injected I/O error, permission/label problem, or signal.
9. `restore_full` exits.
10. `_can_safe_restart` normally cannot find `$STATE_DIR/data/db.sqlite3` and refuses restart.
11. The old coherent state still exists at the sibling `.pre-restore-*` path, but the supported restore path has not moved it back.
12. The operator is left with avoidable manual recovery and extended downtime.

**Production impact:**
No direct data loss is proven because the old state directory remains in the sibling snapshot. However, a single failed promotion rename removes the canonical live state path and requires manual recovery. For a junior operator during DR, this is a material failure-safety gap.

**Why existing tests do not close this:**
Current tests structurally require the mounted-volume rollback ledger and execute successful preflight/cross-layout behavior. They do not make the second boot same-layout `mv` fail after the first rename and assert that the old live state is restored.

**Minimal fix direction:**
Track the old-state snapshot path locally. If staged promotion fails and the live state path is absent, move the old state back. Do not create a general rollback ledger.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
if [[ "$source_root" == "$state_dir" ]]; then
    local _old_state=""
    if [[ -d "$state_dir" ]]; then
        _old_state="${state_dir}.pre-restore-${ts}"
        mv "$state_dir" "$_old_state"
    fi

    log_info "State payload restore phase: promoting staged state directory to live path..."
    if ! mv "$staging/$rel_source" "$state_dir"; then
        log_error "Failed to promote staged state directory: $state_dir"
        if [[ -n "$_old_state" && -d "$_old_state" && ! -e "$state_dir" ]]; then
            if mv "$_old_state" "$state_dir"; then
                log_warn "Rollback restored the previous state directory."
            else
                log_error "CRITICAL: could not restore previous state directory."
                log_error "Manual recovery: mv '$_old_state' '$state_dir'"
            fi
        fi
        return 1
    fi
else
    # Existing cross-root branch.
    ...
fi
```

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_boot_same_layout_second_mv_failure_restores_old_state() {
    local dir
    dir="$(make_restore_case full boot)"
    printf 'old\n' > "$dir/state/data/generation"
    printf 'new\n' > "$dir/stage/state/data/generation"

    local live_state="$dir/state"
    MOCK_MV_FAIL_SOURCE="$dir/stage/state" \
        run_restore_full_harness "$dir" && \
        fail "second state promotion mv unexpectedly succeeded"

    [[ -f "$live_state/data/generation" ]] \
        || fail "old live state path was not restored"
    grep -qx old "$live_state/data/generation" \
        || fail "rollback did not restore the old generation"
}
```

The mock `mv` should call the real `/bin/mv` except when its source matches the staged state path, following the existing `recover.sh` failure-injection mock style.

**Proposed documentation change:**

No operator workflow change is required. The existing transactional restore wording can remain after the implementation is corrected.

**Complexity assessment:**
This is a local rollback for a two-command swap. It uses one path variable and one guarded `mv`; it does not duplicate the mounted-volume ledger or introduce a general rollback mechanism.

---

## [RDR-04] — Selected dependency preflight is not closed for fresh-host rekey or actual-mountpoint rsync

**Classification:**
Fix before live restore testing

**Severity:**
Medium

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — `check_dependencies`, `check_archive_dependencies`, `_require_selected_archive_tools`, `restore_full`, `_require_sops_for_rekey`, `_rotate_age_key`, `main`
`lib/storage.sh` — `check_project_state_ready`

**Contract being violated:**
Selected-plan preflight contract. Knowable executables required by the selected restore plan must be checked before service stop or live-state promotion.

**Current behavior:**
`check_archive_dependencies` is called before destructive work and correctly requires `zstd` for zstd artifacts. Its `sops` condition is:

```bash
[[ "${ROTATE_AGE_KEY_POLICY:-}" != "skip" && -f "${STATE_DIR}/secrets/secrets.yaml" ]]
```

That tests whether a live target secret exists, not whether the selected restore plan will perform default key rotation/rekey. On a fresh replacement host the live secret can be absent even though the selected full/emergency archive contains encrypted `secrets/secrets.yaml`, which `restore_full` later promotes. Default rekey then reaches `_require_sops_for_rekey` only after promotion.

For `rsync`, main's selected check uses configured `DATA_VOLUME_DEVICE`. `check_project_state_ready` treats a blank device as boot-only and returns success for an accessible state directory without checking whether it is actually a mountpoint. Later `restore_full` independently tests `mountpoint -q "$state_dir"` and requires `rsync` inside the destructive restore function.

**Concrete failure sequence:**

Sequence A — `sops`:

1. A replacement host has the repository, Age, Docker, SQLite, zstd, but no `sops`.
2. `$STATE_DIR/secrets/secrets.yaml` does not exist because the target is fresh.
3. A valid remote full/emergency archive contains encrypted `secrets/secrets.yaml`.
4. `check_archive_dependencies` does not add `sops` because the live target secret is absent.
5. Archive decrypt/layout preflight succeeds.
6. The operator confirms; safety snapshot is skipped as a fresh target.
7. Services are stopped and destructive phase starts.
8. `restore_full` promotes state and the archived encrypted `secrets.yaml`.
9. The default key rotation decision chooses rotation.
10. `_rotate_age_key` reaches `_require_sops_for_rekey`.
11. `sops` is first rejected now, after live promotion.
12. The caller sets `RESTORE_PREVENT_AUTOSTART=true` and exits.
13. The promoted restore is left stopped for manual dependency installation/retry.

Sequence B — `rsync`:

1. `STATE_DIR` is an actual mounted block filesystem.
2. `DATA_VOLUME_DEVICE` is unset.
3. The state directory exists and is accessible.
4. `check_project_state_ready` takes its blank-device path and returns success.
5. Main's selected rsync check does not run because it keys off configured `DATA_VOLUME_DEVICE`.
6. Full/emergency preflight detects/prepares the mounted target successfully.
7. Services are stopped and destructive phase starts.
8. `restore_full` extracts the archive to staging.
9. `mountpoint -q "$state_dir"` is true.
10. `restore_full` first discovers that `rsync` is missing and returns failure.
11. No payload has moved, but the live stack was unnecessarily stopped and the safety net may restart the old valid DB.

**Production impact:**
The `sops` path can discover a mandatory default-rekey dependency only after broader state has been promoted. The `rsync` path creates an avoidable service stop/failure cycle. Both violate the restore plan's advertised preflight boundary and make fresh-host recovery less deterministic.

**Why existing tests do not close this:**
`tests/test-backup.sh` verifies that normal system setup owns `zstd`. Restore tests assert selected archive tools and storage preflight behavior, but they do not run a fresh-target archive-containing-secrets case with `sops` absent and assert failure before service stop. They also do not combine an actual mountpoint, blank `DATA_VOLUME_DEVICE`, and missing `rsync`.

**Minimal fix direction:**
Keep `check_archive_dependencies` as the existing owner of selected restore executables.

- Require `sops` whenever key rotation policy is not explicitly `skip`; that reflects the selected/default restore plan, not current live-file presence.
- For full/emergency restore, require `rsync` when the actual target is a mountpoint, regardless of whether `DATA_VOLUME_DEVICE` was populated.
- Keep the inner `restore_full` rsync check as defense in depth, but it must no longer be the first discovery on the supported path.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
check_archive_dependencies() {
    local backup_file="$1"
    local state_dir="${2:-${STATE_DIR:-}}"
    local -a hard=()
    local missing_hard=()

    case "$backup_file" in
        *.tar.zst.age|*.zst.age|*.tar.zst)
            hard+=(zstd)
            ;;
    esac

    if [[ "${ROTATE_AGE_KEY_POLICY:-}" != "skip" ]]; then
        hard+=(sops)
    fi

    if [[ "${RESTORE_TYPE:-}" =~ ^(full|emergency)$ ]] \
        && [[ -n "$state_dir" ]] \
        && mountpoint -q "$state_dir" 2>/dev/null; then
        hard+=(rsync)
    fi

    local _cmd
    for _cmd in "${hard[@]}"; do
        command -v "$_cmd" >/dev/null 2>&1 \
            || missing_hard+=("$_cmd")
    done

    if [[ ${#missing_hard[@]} -gt 0 ]]; then
        log_error "restore.sh: required tools are not installed: ${missing_hard[*]}"
        for _cmd in "${missing_hard[@]}"; do
            case "$_cmd" in
                sops) log_hint "Install through: sudo ./utilities/setup-system.sh --auto" ;;
                zstd) log_hint "Install through: sudo ./utilities/setup-system.sh --auto" ;;
                rsync) log_hint "Install through: sudo ./utilities/setup-system.sh --auto" ;;
            esac
        done
        return 1
    fi
}
```

Call it with the selected target:

```bash
resolve_backup_file || exit 1
[[ -f "$BACKUP_FILE" ]] \
    || { log_error "Backup file not found: $BACKUP_FILE"; exit 1; }
check_archive_dependencies "$BACKUP_FILE" "$STATE_DIR" || exit 1
```

Remove the later config-device-only selected rsync gate:

```bash
# Remove this as the primary selected-plan check:
# if [[ "$RESTORE_TYPE" =~ ^(full|emergency)$ ]] \
#     && [[ -n "$(get_config_value "DATA_VOLUME_DEVICE" "")" ]]; then
#     _require_command_for_path rsync ... || exit 1
# fi
```

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_fresh_full_default_rekey_requires_sops_before_stop() {
    local dir
    dir="$(make_restore_case full boot)"
    rm -f "$dir/state/secrets/secrets.yaml"

    if PATH="$dir/mockbin-no-sops:/usr/bin:/bin" \
        run_restore_case "$dir"; then
        fail "fresh full restore without sops unexpectedly succeeded"
    fi

    ! grep -q '^stop$' "$dir/docker-calls.log" \
        || fail "services were stopped before selected sops dependency failed"
    [[ -f "$dir/state/data/old-generation" ]] \
        || fail "live state changed before sops dependency failure"
}
```

```bash
test_actual_mountpoint_without_device_requires_rsync_before_stop() {
    local dir
    dir="$(make_restore_case full block)"
    DATA_VOLUME_DEVICE=""
    TEST_MOUNTPOINTS=":$dir/state:"

    if PATH="$dir/mockbin-no-rsync:/usr/bin:/bin" \
        DATA_VOLUME_DEVICE="" run_restore_case "$dir"; then
        fail "mounted restore without rsync unexpectedly succeeded"
    fi

    ! grep -q '^stop$' "$dir/docker-calls.log" \
        || fail "services were stopped before rsync dependency failure"
}
```

**Proposed documentation change:**

No prerequisite list change is required; `docs/DISASTER-RECOVERY.md` and `docs/RECOVERY-CARD.md` already direct replacement hosts through `utilities/setup-system.sh --auto`. A small clarification in `docs/BACKUP-RESTORE.md` is appropriate:

```markdown
`restore.sh` also validates executables required by the selected restore plan before stopping services. Running `utilities/setup-system.sh --auto` remains the supported replacement-host preparation path.
```

**Complexity assessment:**
This extends an existing selected-dependency helper with two actual plan predicates. It removes reliance on configuration as a proxy for the real mount layout and does not add a dependency registry.

---

## [RDR-05] — Legacy absolute archives bypass staging and can partially overwrite `/`

**Classification:**
Fix before live restore testing

**Severity:**
High

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — `restore_full`, `_tar_extract_archive`, metadata archive-format inference/preflight

Current reference: `restore_full` legacy `archive_format == "absolute"` branch around lines 2179–2192.

**Contract being violated:**
Historical artifact compatibility and restore transaction contract. A supported legacy restore path must not have a materially weaker partial-write/startup failure boundary merely because member names are absolute.

**Current behavior:**
Version-1 metadata infers `archive_format=absolute`. `restore_full` performs a traversal check and then calls `_tar_extract_archive "$dec_tar" / "$tar_filter"` directly. It does not stage the archive or use any version-2 promotion path.

The traversal check protects against `..`/path-escape semantics; it does not provide transactionality. Tar can successfully write earlier members before a later read/write failure or signal.

**Concrete failure sequence:**

1. A retained, valid version-1 full/emergency archive is selected.
2. Metadata selects `archive_format=absolute`.
3. Preflight and traversal checks pass.
4. Services are stopped and destructive phase starts.
5. `_tar_extract_archive` begins extracting directly to `/`.
6. Tar overwrites one or more archived state/project/config members.
7. A later archive read, filesystem write, ENOSPC, I/O error, INT, or TERM interrupts extraction.
8. `_tar_extract_archive` returns non-zero or the signal trap runs.
9. There is no staged legacy promotion and no rollback scope for members already overwritten.
10. If the expected live DB still exists and passes SQLite integrity, `_can_safe_restart` can currently authorize startup.
11. The host is left with a partially overwritten legacy restore generation and may auto-start.

**Production impact:**
A failed legacy restore can partially modify root-relative project/state content and then restart based solely on DB integrity. This is a stronger blast radius than the current version-2 path.

**Why existing tests do not close this:**
Current restore tests reject unsupported archive content and execute current relative-format layout/preflight behavior. No behavioral test injects failure during version-1 absolute extraction and asserts that live root/state content remains untouched. Structural tests also do not require legacy extraction to stage.

**Minimal fix direction:**
Keep version-1 compatibility, but stage the legacy archive instead of extracting to `/`.

The existing `check_traversal_only` remains mandatory. For legacy absolute member names, skip the relative-member validator if it intentionally rejects leading `/`, extract to `$TMPDIR_RESTORE/stage`, validate the expected staged source root, and continue through the same type/layout-aware promotion code used by current archives.

Do not write a separate legacy rollback engine.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
local legacy_absolute=false
if [[ "$archive_format" == "absolute" ]]; then
    legacy_absolute=true
    log_warn "Legacy archive format detected (version=1, absolute paths)."
    check_traversal_only "$dec_tar" || return 1
    log_success "Archive traversal check passed (legacy format)."
fi

if [[ "$SKIP_VERIFICATION" != "true" \
      && "$legacy_absolute" != "true" ]]; then
    tar_validate_members "$dec_tar" || return 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would stage-extract and promote archive."
    return 0
fi

local staging="$tmpdir/stage"
mkdir -p "$staging"
log_info "Extracting archive to staging directory..."
_tar_extract_archive "$dec_tar" "$staging" "$tar_filter"

local source_root="${RESTORE_PREFLIGHT_SOURCE_ROOT:-$state_dir}"
local rel_source="${source_root#/}"
if [[ ! -d "$staging/$rel_source" ]]; then
    log_error "Staging validation failed: expected source directory not found: $staging/$rel_source"
    return 1
fi

# Continue into the existing mounted / same-layout / cross-root promotion logic.
```

Delete the direct-to-root legacy branch:

```bash
# Remove:
# _tar_extract_archive "$dec_tar" / "$tar_filter"
# ...
# return 0
```

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_legacy_absolute_extract_failure_never_writes_live_root() {
    local dir
    dir="$(make_restore_case full boot)"
    printf 'old\n' > "$dir/state/data/generation"
    make_legacy_absolute_archive "$dir" "$dir/legacy.tar.gz.age"

    _tar_extract_archive() {
        local archive="$1" dest="$2"
        [[ "$dest" != "/" ]] \
            || fail "legacy restore attempted direct extraction to /"
        mkdir -p "$dest/var/lib/vaultwarden/data"
        printf 'new\n' > "$dest/var/lib/vaultwarden/data/generation"
        return 42
    }

    if run_restore_full_harness "$dir" absolute; then
        fail "injected legacy staging failure unexpectedly succeeded"
    fi

    grep -qx old "$dir/state/data/generation" \
        || fail "legacy pre-promotion failure changed live state"
}
```

A separate INT/TERM injection at the same staged-extraction boundary should assert the same live-state preservation.

**Proposed documentation change:**

No operator command change is required. Add a compatibility note to `docs/BACKUP-RESTORE.md`:

```markdown
Retained version-1 absolute-path archives are staged and validated before live promotion. Legacy member naming does not authorize direct extraction into `/`.
```

**Complexity assessment:**
This removes a special direct-write path and reuses the existing staging/promotion logic. It is simpler than maintaining a second legacy rollback mechanism and preserves current architecture.

---

## [RDR-06] — Snapshot operation phase says “Created” when snapshot was skipped or soft-failed

**Classification:**
Safe to validate during live testing

**Severity:**
Low

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — `create_pre_restore_snapshot`, `main`
`lib/operations.sh` — `operation_set_phase`, operation state fields

Current references: `create_pre_restore_snapshot` around lines 1997–2046; unconditional `operation_set_phase "snapshot" "Created pre-restore snapshot"` around line 2712; `operation_set_phase` writes `phase_name` to operation state.

**Contract being violated:**
Operator truth contract. Descriptive operation state must not claim a recovery point was created when the owning function intentionally skipped it or converted failure to a soft warning.

**Current behavior:**
`create_pre_restore_snapshot` returns success when:

- `--no-backup` explicitly skips;
- a fresh full/emergency target has no live DB;
- dry-run skips mutation;
- backup creation fails and `RESTORE_SNAPSHOT_HARD_FAIL=false`;
- the backup runner is unavailable and hard-fail policy is false.

Main treats any zero return identically and writes `phase_name=Created pre-restore snapshot`.

`lib/operations.sh` persists the phase name in the operation state file displayed to operator tooling. It is descriptive metadata rather than the kernel lock authority, so the severity is low, but the claim is false.

**Concrete failure sequence:**

1. A fresh replacement host runs a full remote restore.
2. No live DB exists.
3. `create_pre_restore_snapshot` logs that the snapshot is skipped on the fresh target and returns `0`.
4. Main immediately calls `operation_set_phase "snapshot" "Created pre-restore snapshot"`.
5. The operation state file persists that phase name.
6. An operator inspecting the active/failed operation can see a claim that a safety snapshot exists when none was created.

The same false phase can follow a soft-failed backup.

**Production impact:**
No lock or rollback decision is automated from the phase string. The impact is operator confusion during incident review and possible incorrect assumptions about the existence of a pre-restore recovery point.

**Why existing tests do not close this:**
Tests assert that the restore plan and snapshot helper exist, but do not execute fresh-target or soft-failure snapshot outcomes and inspect the phase name written after the helper returns.

**Minimal fix direction:**
Have the snapshot helper set one small result string: `created`, `skipped`, or `soft-failed`. Main maps that result to truthful phase text. Do not change operation-state architecture.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
RESTORE_SNAPSHOT_RESULT="unknown"

create_pre_restore_snapshot() {
    local operational_sops_age_key_file="$1"
    local restore_type="$2"
    RESTORE_SNAPSHOT_RESULT="unknown"

    if [[ "$NO_PRE_BACKUP" == "true" ]]; then
        RESTORE_SNAPSHOT_RESULT="skipped"
        log_warn "Skipping pre-restore snapshot (--no-backup)."
        return 0
    fi

    if [[ "$restore_type" =~ ^(full|emergency)$ \
          && ! -f "$STATE_DIR/data/db.sqlite3" ]]; then
        RESTORE_SNAPSHOT_RESULT="skipped"
        log_info "Fresh target has no live database; pre-restore snapshot is not required."
        return 0
    fi

    if SOPS_AGE_KEY_FILE="$operational_sops_age_key_file" \
        "${PROJECT_ROOT}/utilities/backup-run.sh" run emergency --quiet; then
        RESTORE_SNAPSHOT_RESULT="created"
        return 0
    fi

    if [[ "$RESTORE_SNAPSHOT_HARD_FAIL" == "true" ]]; then
        RESTORE_SNAPSHOT_RESULT="failed"
        return 1
    fi

    RESTORE_SNAPSHOT_RESULT="soft-failed"
    log_warn "Pre-restore snapshot failed; continuing because hard-fail policy is disabled."
    return 0
}
```

Main:

```bash
create_pre_restore_snapshot \
    "$OPERATIONAL_SOPS_AGE_KEY_FILE" "$RESTORE_TYPE" || exit 1

case "$RESTORE_SNAPSHOT_RESULT" in
    created)
        operation_set_phase "snapshot" "Created pre-restore snapshot"
        ;;
    skipped)
        operation_set_phase "snapshot" "Pre-restore snapshot skipped"
        ;;
    soft-failed)
        operation_set_phase "snapshot" "Pre-restore snapshot failed; continuing by policy"
        ;;
    *)
        log_error "Unknown pre-restore snapshot result: $RESTORE_SNAPSHOT_RESULT"
        exit 1
        ;;
esac
```

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_fresh_target_snapshot_phase_is_truthful() {
    local dir="$TMP/snapshot-phase"
    mkdir -p "$dir/state/data"

    STATE_DIR="$dir/state"
    RESTORE_TYPE=full
    NO_PRE_BACKUP=false
    PHASE_NAME=""

    operation_set_phase() {
        PHASE_NAME="$2"
    }

    create_pre_restore_snapshot "$dir/key.txt" "$RESTORE_TYPE" \
        || fail "fresh target snapshot skip should succeed"

    case "$RESTORE_SNAPSHOT_RESULT" in
        skipped) ;;
        *) fail "fresh target snapshot result was not skipped" ;;
    esac

    operation_set_phase "snapshot" "Pre-restore snapshot skipped"
    [[ "$PHASE_NAME" == "Pre-restore snapshot skipped" ]] \
        || fail "snapshot phase falsely claimed creation"
}
```

Add a sibling case where the backup stub fails and `RESTORE_SNAPSHOT_HARD_FAIL=false`; assert `soft-failed`, not `created`.

**Proposed documentation change:**

No documentation change is required. This corrects runtime status to match existing documented skip/failure policy.

**Complexity assessment:**
One local result string makes a three-way function outcome explicit. This is proportionate operator-state bookkeeping, not a workflow state machine.

---

## [RDR-07] — Critical post-restore health failure is warned, then final success is printed and returned

**Classification:**
Fix before live restore testing

**Severity:**
Medium

**Confidence:**
High

**Affected files and symbols:**
`utilities/restore-run.sh` — post-start health block and final success reporting in `main`
`startup.sh` — `run_health_check` exit semantics, used as comparison
`recover.sh` — `run_startup_health`, used as comparison

**Contract being violated:**
Operator truth and completion-status contract. A committed restore whose critical post-restore health command fails must not be reported as fully successful or return an indistinguishable success status.

**Current behavior:**
After successful `startup.sh`, restore clears the ERR trap. It waits for `vaultwarden_app` health and treats timeout as a warning. It then invokes `utilities/maintenance-health.sh`; any non-zero exit is swallowed by an `|| { log_warn ...; }` block. Main always reaches:

```bash
_print_post_restore_summary
log_success "Restore complete."
```

and returns `0`.

By comparison, `startup.sh` distinguishes health exit `1` warnings from exit `2+` critical failures. `recover.sh` returns non-zero after committed startup/health failure while explicitly preserving committed artifacts.

**Concrete failure sequence:**

1. A full/emergency restore crosses its normal promotion/rekey boundary.
2. `startup.sh --skip-pull` returns success.
3. `utilities/maintenance-health.sh` runs.
4. It returns a critical non-zero status, for example `2`.
5. Restore logs `Health check reported issues after restore`.
6. The non-zero status is swallowed.
7. Main prints the post-restore summary.
8. Main logs `Restore complete.` with success severity.
9. The restore process returns `0`.
10. An operator or live-test harness sees successful command completion despite a critical health result that requires investigation.

**Production impact:**
Live restore testing can record a false success. Operators and automation can move to later DR/cutover steps while the stack has critical health failures.

**Why existing tests do not close this:**
The consolidated restore suite checks confirmation, decrypt dispatch, preflight, and structural safety-net contracts. It does not stub `maintenance-health.sh` to return a critical code and assert a non-zero restore result/no final success line.

The recovery tests explicitly cover startup and health failure after commit and assert non-zero truthful status.

**Minimal fix direction:**
Preserve the current post-commit rule: do not roll back committed restore artifacts because startup/health failed.

Capture the maintenance health exit code. Reuse the same `0` / `1` / `2+` interpretation already used by `startup.sh`:

- `0`: healthy;
- `1`: warnings; print `completed with warnings`, not a clean success claim;
- `2+`: critical failure; print committed-state/manual-diagnosis guidance and return non-zero.

The safety-net ERR trap is already cleared after services start, so a final `return 1` will not trigger an automatic restart.

**Proposed production code snippet:**

`utilities/restore-run.sh`:

```bash
local _restore_health_rc=0
local _restore_completed_with_warnings=false

if [[ -x "${PROJECT_ROOT}/utilities/maintenance-health.sh" ]]; then
    log_info "Running post-restore health check..."
    log_info "Invoking: ${PROJECT_ROOT}/utilities/maintenance-health.sh"
    "${PROJECT_ROOT}/utilities/maintenance-health.sh" \
        || _restore_health_rc=$?

    case "$_restore_health_rc" in
        0)
            ;;
        1)
            _restore_completed_with_warnings=true
            log_warn "Post-restore health completed with warnings."
            ;;
        *)
            log_error "Post-restore health reported critical failures (exit ${_restore_health_rc})."
            log_error "Restore artifacts remain committed; investigate before cutover."
            log_error "Inspect with: docker compose logs --tail=50"
            ;;
    esac
fi

echo ""
auto_fix_critical_permissions "$PROJECT_ROOT"
_print_post_restore_summary

if (( _restore_health_rc >= 2 )); then
    log_error "Restore artifacts were committed, but post-restore health failed."
    return 1
fi

if [[ "$_restore_completed_with_warnings" == "true" ]]; then
    log_warn "Restore completed with warnings; review the health output above."
else
    log_success "Restore complete."
fi
```

**Proposed regression test snippet:**

`tests/test-restore-recovery.sh`:

```bash
test_critical_post_restore_health_is_not_success() {
    local dir
    dir="$(make_restore_case full boot)"
    write_restore_mocks "$dir"

    cat > "$dir/repo/utilities/maintenance-health.sh" <<'HEALTH'
#!/usr/bin/env bash
exit 2
HEALTH
    chmod +x "$dir/repo/utilities/maintenance-health.sh"

    if run_restore_case "$dir" >"$dir/out" 2>&1; then
        fail "critical post-restore health failure returned success"
    fi

    grep -q 'Restore artifacts were committed, but post-restore health failed.' "$dir/out" \
        || fail "committed-health failure guidance missing"
    ! grep -q 'SUCCESS.*Restore complete\.' "$dir/out" \
        || fail "critical health failure was presented as clean restore success"
    [[ -f "$dir/state/data/db.sqlite3" ]] \
        || fail "committed restore artifacts were incorrectly rolled back"
}
```

Add a warning-only sibling with health exit `1`; assert return `0` and `Restore completed with warnings`, not a clean `Restore complete.` success line.

**Proposed documentation change:**

`docs/BACKUP-RESTORE.md`:

```markdown
After restore artifacts are committed, a critical post-restore health failure returns non-zero without rolling the restored artifacts back. Treat the host as not ready for cutover until the reported health failures are resolved. Warning-only health status is reported as “completed with warnings,” not as a clean restore success.
```

**Complexity assessment:**
This is a local exit-code/status fix that follows semantics already used by `startup.sh` and `recover.sh`. It does not add rollback after commit or create a new health framework.

---

## Test audit and required behavioral coverage

Structural assertions remain appropriate for:

- ensuring `restore.sh` remains a thin dispatcher;
- option-scope/parser grammar;
- presence of operation guards;
- conservative payload allowlist ownership;
- explicit skip of runtime decrypted secrets;
- source/target layout preflight messages;
- durable key-role variable separation.

Behavioral failure injection is required for transaction claims where the safety property depends on **when** a command fails or a signal arrives.

The current `recover.sh` tests already provide the repository pattern: extracted-function/full-script harnesses, PATH-injected command stubs, destination-specific `mv` failures, SOPS failure modes, and INT/TERM injection. Restore does not need a massive integration framework.

Required focused regressions:

1. Cross-root/cross-layout data promotion succeeds, then Caddy promotion fails; assert no startup while full promotion is uncommitted.
2. Boot same-layout old-state rename succeeds, then staged-state promotion fails; assert old state returns to the canonical path.
3. Encrypted secrets promotion succeeds, then later project config promotion fails; assert no safety-net startup.
4. Failure after DB promotion but before full/emergency commit; assert DB integrity alone does not authorize restart.
5. Safety net does not autostart an uncommitted full/emergency restore.
6. Remote passphrase emergency primary is present but `.meta` is absent; assert failure before any decrypt-mode attempt.
7. Fresh selected restore defaults to SOPS rekey but `sops` is unavailable; assert failure before `docker compose stop`.
8. `STATE_DIR` is an actual mountpoint requiring `rsync` while `DATA_VOLUME_DEVICE` is unset; assert failure before `docker compose stop`.
9. INT and TERM during secrets/config promotion; assert no startup before full/emergency commit.
10. Legacy absolute archive extraction failure; assert the live state/root is not written before staged promotion.
11. Critical post-restore health exit; assert committed artifacts remain but the restore command returns non-zero and does not print clean success.
12. Fresh-target and soft-failed snapshot paths; assert operation phase text does not say `Created`.

---

## Useful non-blocking observations

1. **Mounted payload rollback is a real closed contract within its scope.** The current `data/caddy/logs` allowlist tracks moved and created paths and attempts rollback on move/rsync failure. The finding is that this scope ends before broader full/emergency coherence is committed.
2. **DB-only restore transaction is materially stronger than the broad safety predicate suggests.** It decrypts/validates the candidate, writes a same-filesystem temporary DB, atomically renames, and attempts rollback from the pre-restore copy on write failure.
3. **Key rotation itself has explicit rollback logic.** `_rotate_age_key` is not the source of the outer transaction defect; the missing state is broader restore commit eligibility.
4. **`recover.sh` correctly separates offline and operational key roles.** Its explicit artifact-promotion flags and `RECOVERY_COMMITTED` boundary are useful philosophy evidence, but `restore.sh` should not copy that complete transaction or merge the two tools.
5. **HMAC sidecars are not restore-critical dispatch metadata.** They improve checksum authenticity when the verifier has the HMAC key and authenticated-integrity policy. Current remote restore does not download the HMAC sidecar, so the report does not recommend making it mandatory merely for symmetry.
6. **Normal replacement-host documentation already installs dependencies first.** That reduces field likelihood of RDR-04 but does not close `restore.sh`'s own preflight contract.
7. **Permission repair remains important live-test evidence.** Static analysis proves the helper targets root-operated config/secrets, Vaultwarden PUID/PGID paths, Caddy UID/GID 2000 paths, and the init-permissions sentinel. Actual restored filesystem ownership/ACL/mount behavior still needs host validation.

---

## Hypothesis results

### Hypothesis A — confirmed

Emergency passphrase `encryption_mode` is restore-critical metadata. Remote upload semantics currently treat `.meta` as optional and can report the primary as delivered after `.meta` failure. Remote restore then infers recipient mode.

Finding: RDR-01.

### Hypothesis B — confirmed

SQLite integrity alone does not prove full/emergency coherence. Failure after broader partial promotion can reach the safety net while the DB is valid.

Finding: RDR-02.

### Hypothesis C — confirmed, with an important closed sub-boundary

Rollback guarantees differ materially.

- Mounted block payload promotion has a strong explicit local rollback ledger.
- Boot same-layout has no rollback between its two state-directory renames.
- Secrets/emergency `/etc`/project config promotion is outside the mounted payload ledger.
- Boot archive → mounted block target correctly uses the mounted-target allowlist/rsync ledger; the audit does **not** claim that supported cross-layout block promotion lacks the mounted payload rollback.

Findings: RDR-02 and RDR-03.

### Hypothesis D — confirmed

Fresh-target default rekey can miss `sops` in preflight because the current dependency predicate looks for an already-live `secrets.yaml`. Actual mounted state can require `rsync` even when configured `DATA_VOLUME_DEVICE` is blank.

Finding: RDR-04.

### Hypothesis E — confirmed

`create_pre_restore_snapshot` has successful skip/soft-failure outcomes, but main unconditionally writes `Created pre-restore snapshot`.

Finding: RDR-06.

---

## Explicitly disproven hypotheses

No complete starting hypothesis A–E was disproven; each identified a real contract gap.

The following narrower suspected failure modes were explicitly closed by current code:

1. **DB-only restore does not need a broad full-state commit flag.** Its same-filesystem temp + atomic DB rename and SQLite validation form an appropriate narrow transaction.
2. **Mounted block payload movement is not blindly destructive.** The current allowlist excludes `.vw-data-volume`, `lost+found`, backups, secrets, and config, tracks moved/created payload paths, and attempts rollback on payload move/rsync failure.
3. **Boot archive → mounted block target does not use the unguarded non-mounted cross-root branch.** Because the target is an actual mountpoint, it uses the mounted payload ledger.
4. **`zstd` is not a remaining selected-archive dependency gap.** Current selected archive dependency checking requires it for `.zst` artifacts before destructive work, and normal system setup owns/validates it.
5. **SOPS key rotation does not install the offline USB key as the live operational key.** `recover.sh` generates a replacement operational key; restore's key-role variables separate backup decrypt identity from the rekey source and live key.
6. **`_rotate_age_key` does not silently continue after its own failure.** It has transactional key-artifact handling, and the caller sets `RESTORE_PREVENT_AUTOSTART=true` on returned rotation failure.
7. **Full/emergency preflight does not accept multiple live DBs.** Archive inspection requires exactly one live DB path after excluding `.pre-restore-*` snapshot DBs.
8. **Block-source full restore does not silently target boot storage.** Current preflight rejects the source/target storage mismatch.

---

## Production readiness verdict

`Restore requires a focused fix PR before destructive live testing`

### Required before live testing

1. Fix RDR-02: add type-aware safety restart eligibility with an explicit full/emergency promotion commit boundary.
2. Fix RDR-01: make emergency `.meta` restore-critical for offsite delivery and fail closed on missing/unknown emergency protection mode.
3. Fix RDR-05: remove direct-to-`/` legacy extraction and stage legacy absolute archives before current promotion logic.
4. Fix RDR-03: roll back the first boot same-layout rename when staged state promotion fails.
5. Fix RDR-04: close selected `sops` and actual-mountpoint `rsync` dependencies before service stop/live promotion.
6. Fix RDR-07 in the same PR so critical post-restore health failure returns non-zero and live-test results cannot record a false clean success.

RDR-06 is low severity and does not independently block destructive testing, but it is small and adjacent enough to include if the implementation remains focused.

### Validate during live testing

1. Real Ubuntu 24.04 Noble boot → boot full restore with service stop, rekey, permission repair, startup, login, attachments/Sends, and health acceptance.
2. Real mounted OCI block-volume full restore, including in-volume pre-restore snapshot behavior and target sentinel preservation.
3. Boot archive → prepared mounted block target, proving the preflight source root and mounted target payload allowlist on the actual filesystem.
4. Emergency passphrase remote restore with primary + required `.meta` present, including the real Age passphrase prompt.
5. Emergency independent Age recipient restore with the matching emergency identity and no operational/offline key-role confusion.
6. Real SOPS `updatekeys` against restored encrypted `secrets.yaml`, followed by decryption with the newly installed operational key.
7. Runtime permission repair on restored Vaultwarden/Caddy paths and removal of a restored `.permissions-initialized` sentinel.
8. Start-policy `ask` and `manual` behavior over a real SSH/TTY, including `SAVED` acknowledgement timeout/EOF handling.
9. Post-commit startup/health failure reporting on a disposable host, proving artifacts remain committed while the command reports non-success.
10. Historical version-1 archive restore only if retained production v1 artifacts actually exist; otherwise validate the new staging harness behavior in CI and retire unsupported artifacts deliberately.

### Recommended implementation PR scope

Create one bounded restore-contract PR implementing:

- RDR-01 emergency restore-critical metadata delivery/dispatch;
- RDR-02 full/emergency commit-aware safety restart;
- RDR-03 boot same-layout second-rename rollback;
- RDR-04 selected dependency preflight closure;
- RDR-05 staged legacy absolute restore;
- RDR-07 truthful critical post-restore health result;
- optionally RDR-06 truthful snapshot phase text if it stays a small adjacent change.

Likely production files:

- `utilities/backup-run.sh`
- `utilities/restore-run.sh`

Likely focused tests:

- `tests/test-backup.sh`
- `tests/test-restore-recovery.sh`

Likely documentation updates:

- `docs/BACKUP-RESTORE.md`
- narrowly `docs/DISASTER-RECOVERY.md` only if status wording needs alignment.

Keep out of scope:

- merging `recover.sh` and `restore-run.sh`;
- generic rollback/transaction frameworks;
- dependency registries;
- state databases;
- new backup container formats;
- workflow engines;
- broad storage refactors;
- unrelated systemd, secrets-schema, CrowdSec, or Makefile cleanup;
- enterprise HA/clustering/orchestration;
- destructive production testing in the implementation PR.

The confirmed defects can be closed cleanly in one focused PR with explicit shell state, local rollback at the two-rename boundary, type-aware artifact/dependency classification, and behavioral failure-injection tests.
