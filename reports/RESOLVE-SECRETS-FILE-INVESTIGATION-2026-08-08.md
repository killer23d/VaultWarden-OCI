# `resolve_secrets_file()` investigation: legacy fallback can preserve split persistent state

Status: investigation only; no runtime behavior is changed by this branch.

Base examined: `delta` at `7c88a3cfa02e9159a7dee4a44f22e36850dddde0`.

## Why this report exists

A host test using the supported Ubuntu 24.04/arm64 path with dedicated storage configured at `/mnt/vw-data` repeatedly emitted:

```text
WARN Using repository-local secrets file — migrate to /mnt/vw-data/secrets/secrets.yaml
```

The warning is truthful, but the current code does not define or execute the migration it requests. Once a legacy repository-local ciphertext exists and the canonical state ciphertext does not, ordinary setup and secret-management paths can continue using the legacy file indefinitely.

This report records the observed fault, traces the relevant lifecycle, identifies adjacent contracts that need review, and proposes an investigation/test matrix. It intentionally does not select an implementation strategy.

## Current source-of-truth contract

Current documentation defines persistent encrypted secrets as:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

In dedicated-volume mode the documented storage identity is:

```text
DATA_VOLUME_MOUNT=/mnt/vw-data
PROJECT_STATE_DIR=/mnt/vw-data
```

`recover.sh` independently encodes the same contract: for `--state-dir DIR`, it sets `SECRETS_FILE="$STATE_DIR/secrets/secrets.yaml"` and fails if that file is missing. A state/data volume without this ciphertext is therefore not self-contained for the repository's state-directory disaster-recovery path.

Current permission policy also distinguishes the two locations:

- `${PROJECT_STATE_DIR}/secrets` and its ciphertext are root-owned persistent state;
- `${PROJECT_ROOT}/secrets` and the repository-local ciphertext are operator-owned authoring/legacy paths.

The resolver can switch between those custody domains solely on file existence.

## The resolver

Current `lib/config.sh` implements:

```bash
resolve_secrets_file() {
    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    local root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local persistent="${PROJECT_STATE_DIR:-$default_state_dir}/secrets/secrets.yaml"
    local legacy="${root}/secrets/secrets.yaml"

    if [[ -f "$persistent" ]]; then
        SECRETS_FILE="$persistent"
    elif [[ -f "$legacy" ]]; then
        SECRETS_FILE="$legacy"
        log_warn "Using repository-local secrets file — migrate to ${persistent}"
    else
        SECRETS_FILE="$persistent"
    fi
    export SECRETS_FILE
}
```

This is a selector, not a reconciler. It has no transaction, no source/destination comparison, no mount/sentinel gate, no ciphertext verification, no promotion, and no cleanup of the legacy source.

## Historical intent

Commit `002c3859bb3ef05dc3310600260640934bb6f125` (`Resolve secrets path after env load`, 2026-06-23) added a call to `resolve_secrets_file()` inside `load_env_file()` so direct env-file callers would follow the split-permission secrets layout.

That made path selection cross-cutting, but it did not establish who owns a transition from the legacy repository path to the state path. The current warning effectively exposes that missing ownership boundary.

## Reproducible state transition

The problematic state can be produced without corruption:

1. A valid legacy ciphertext exists at `${PROJECT_ROOT}/secrets/secrets.yaml` from an earlier lifecycle/version/boot-volume workflow.
2. Runtime storage identity is changed or migrated so `PROJECT_STATE_DIR=/mnt/vw-data`.
3. `/mnt/vw-data/secrets/` exists, but `/mnt/vw-data/secrets/secrets.yaml` does not.
4. `load_env_file()` / `load_project_environment()` invokes `resolve_secrets_file()`.
5. The resolver selects the legacy ciphertext and warns.
6. `utilities/setup-secrets.sh` then uses the already-selected `SECRETS_FILE`; its bootstrap/configure path can validate, rekey, or update that file in place.
7. Nothing creates the canonical persistent ciphertext.
8. The next invocation reaches the same state and selects the legacy file again.

The fallback is therefore stable rather than transitional.

## Why the normal first-install order does not eliminate the problem

Current `setup.sh` orders storage setup before environment setup and secrets bootstrap. On a clean dedicated-volume first install, that should make the state path available before a new ciphertext is created.

However, compatibility/re-provision/migration cases can start with a pre-existing repository ciphertext. `setup-env.sh` creates `${PROJECT_STATE_DIR}/secrets/`, but does not promote a repository ciphertext. Once the directory exists but its ciphertext does not, the resolver still chooses the legacy file.

This suggests the defect is primarily a state-transition/compatibility gap, not the clean-install default path.

## Observed operator effects

### 1. Warning persists indefinitely

The warning says to migrate but no normal command owns that migration. Re-running secrets bootstrap/configure can continue operating on the legacy file.

### 2. Duplicate warning noise

`load_env_file()` invokes `resolve_secrets_file()`. `utilities/setup-crowdsec.sh` then explicitly invokes `resolve_secrets_file()` again. The same state can therefore produce two identical warnings during one command, which makes one condition look like two failures.

### 3. Disaster-recovery state is split

The configured state volume can contain runtime data, `config/install.env`, and the DR manifest while the encrypted secrets remain in the Git checkout. `recover.sh --state-dir /mnt/vw-data ...` expects the ciphertext under the state directory and fails when it is absent.

### 4. Custody/permission behavior changes with fallback

The current permission contract treats persistent state secrets as root-owned and repository secrets as operator-owned. A transparent fallback therefore changes which custody domain is authoritative. This deserves explicit treatment rather than being only an existence-based implementation detail.

### 5. Both-files-present state is silent

If both persistent and legacy ciphertexts exist, the resolver always selects the persistent file and emits no warning about the legacy copy. If the two files diverge, the repository can contain a stale alternative secret set without any split-brain diagnostic.

### 6. Explicit overrides and generic environment loading need review

`load_project_environment()` captures and reapplies an explicit caller `SECRETS_FILE` override after resolution, but `load_env_file()` itself calls the resolver directly. This raises two questions:

- can a direct `load_env_file()` caller have an explicit `SECRETS_FILE` overwritten by the resolver?
- can `load_project_environment()` emit a legacy warning during its internal `load_env_file()` call even when a caller override will later select a different path?

The resolver's placement inside a generic environment loader makes warning/path-selection side effects hard to reason about.

### 7. Missing-volume behavior must be audited

The resolver itself does not validate the storage mount/sentinel before deciding that the persistent path is absent. In dedicated-volume mode, an unavailable state volume plus an existing repository ciphertext can look identical to "persistent ciphertext has not been migrated yet." Callers that do not first enforce `require_project_state_ready()` may therefore fall back when the correct behavior should be to fail closed on missing storage.

This report does not claim every caller is vulnerable; the agent should map which public entry points gate storage before secret resolution/use.

### 8. Symlink/canonical-path policy is not expressed here

`[[ -f path ]]` follows a symlink to a regular file. `resolve_secrets_file()` itself does not reject a symlink or require either location to resolve beneath the expected canonical directory. Determine whether other owning layers reliably provide that guarantee and whether the resolver should remain deliberately ignorant of it.

## Related contract inconsistency to verify

Current `lib/common.sh` classifies `${PROJECT_STATE_DIR}/secrets/secrets.yaml` as `root:root 0600` and `${PROJECT_ROOT}/secrets/secrets.yaml` as operator-owned `0600`.

`utilities/setup-secrets.sh` has an encrypted-secret ownership repair path that should be reviewed specifically under legacy fallback. The agent should verify that bootstrap/configure cannot accidentally apply persistent root-owned semantics to the repository authoring path, or vice versa.

Do not change this contract based only on this report; determine the current intended ownership from executable behavior, permanent tests, runtime-permission helpers, and supported operator workflows.

## Related `setup-env.sh` audit target

`create_env_file()` currently decides that an existing `.env` is "already up-to-date" primarily from domain/email/version conditions. Storage identity arguments are not obviously part of that idempotency predicate.

This is not established as the cause of the reported host state (the warning itself proves the host currently resolves the target as `/mnt/vw-data`). It is nevertheless worth auditing because a storage transition must not be skipped merely because unrelated domain/email/version values already match.

## Existing regression coverage gap

`tests/suites/foundation/case-config-env.bash` covers canonical state-path resolution and caller override preservation, but the current suite does not appear to exercise the complete legacy lifecycle as a state machine.

At minimum, the investigation should cover these resolver states:

| Persistent file | Legacy file | Expected policy to decide |
|---|---|---|
| absent | absent | canonical destination for bootstrap |
| present | absent | persistent selected |
| absent | present | compatibility fallback vs guarded promotion |
| present | present, identical logical data | stale legacy cleanup/reporting policy |
| present | present, divergent logical data | fail-closed split-brain policy |
| state volume unavailable | legacy present | fail closed vs compatibility fallback |
| explicit caller override | either/both present | override precedence and warning behavior |
| persistent/legacy symlink | any | canonical/symlink safety policy |

Transition tests should also cover:

- boot-volume -> dedicated block-volume migration;
- re-running setup against a legacy checkout;
- `setup-secrets.sh bootstrap` and `configure` after the state path changes;
- direct `load_env_file()` callers versus `load_project_environment()` callers;
- secret edit/rotate/list/export entry points;
- startup Docker-secret export;
- CrowdSec secret consumption;
- backup/full-backup and restore behavior;
- `recover.sh --state-dir` disaster recovery;
- systemd-installed environment paths;
- interrupted promotion/rollback, if promotion is introduced.

## Questions the fixing agent should answer before coding

1. **Who owns migration?** Should the resolver remain a read-only selector while a mutating setup/storage/secrets workflow owns promotion, or should another existing workflow own it?
2. **When is automatic promotion safe?** What exact evidence proves the configured state directory is mounted/owned and the source ciphertext is valid?
3. **How are two ciphertexts compared?** Ciphertext bytes can differ while plaintext is logically identical. Any comparison must avoid leaking plaintext and must define recipient-policy differences correctly.
4. **What happens on divergence?** Silent preference is unsafe. Define the operator-visible, fail-closed recovery path.
5. **What happens to the legacy file after success?** Remove, retain with an explicit stale marker, or require operator cleanup? Leaving two authoritative-looking files recreates ambiguity.
6. **How are explicit `SECRETS_FILE` overrides treated?** They must not be silently migrated merely because a canonical path exists.
7. **How does missing storage differ from missing ciphertext?** Dedicated-volume absence should not silently degrade to boot/repository state if that violates the storage safety contract.
8. **Which ownership contract applies during promotion?** Preserve the current state-vs-repository privilege boundary.
9. **Should read-only status commands expose this drift?** Consider `env-edit.sh status`, storage verification, smoke tests, or a focused secret-location diagnostic rather than repeated warnings from every consumer.
10. **Should `load_env_file()` have secret-resolution side effects?** Evaluate whether generic env loading is the right abstraction boundary for selecting secret custody.

## Suggested acceptance criteria for a future fix

A future implementation should be considered complete only if it can demonstrate all of the following without secret disclosure:

- one unambiguous authoritative ciphertext path after a supported storage transition;
- no silent fallback when the configured dedicated volume is unavailable;
- no silent preference when persistent and legacy ciphertexts conflict;
- explicit caller overrides remain authoritative;
- the destination is created atomically with the current ownership/mode contract;
- staged ciphertext is decryptable with the intended operational key before promotion;
- interruption cannot destroy the only usable ciphertext;
- `recover.sh --state-dir` sees a complete state directory after successful migration;
- normal clean first-install behavior remains simple;
- boot-volume mode remains supported;
- warnings are emitted once at the owning boundary, not duplicated by nested loaders;
- permanent regression tests cover the state/transition matrix above.

## Non-goals for this investigation PR

- no automatic secret migration;
- no change to resolver precedence;
- no deletion of legacy ciphertext;
- no permission-policy change;
- no storage migration rewrite;
- no new secrets manager or state framework.

The purpose of this PR is to give the fixing agent a bounded evidence packet and to force the eventual solution to reconcile configuration loading, storage readiness, secret custody, backup/restore, and disaster recovery as one coherent contract.
