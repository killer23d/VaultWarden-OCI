# Codex 5.x Implementation Prompt — VaultWarden-OCI Resilient State and Disaster Recovery

## Mission

Implement the resilient persistent-state, transient-secret, two-recipient SOPS, and junior-admin disaster-recovery workflow described below.

Work directly in:

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Base branch: `delta`
- Required starting commit: `3644b69932e16731f60574041477d060fd47bf35`

PR #180 is closed and unmerged. Ignore it completely:

- do not reference it;
- do not cherry-pick it;
- do not copy its branch;
- do not use it as an implementation baseline.

Create a new branch from the exact `delta` commit above, use a descriptive branch name such as `feat/resilient-recovery`, and open a **draft PR targeting `delta`** only after every required validation passes.

Do not stop at a plan. Inspect the current code, implement the changes, run validation, and open the draft PR.

---

## Context and design intent

This repository operates a self-hosted Vaultwarden deployment for a workgroup of about 10 people on OCI.

The disaster-recovery operator may be a junior administrator with limited Linux and Docker experience. Recovery must be executable from a single rendered and printed A5 card without interpretation.

Security and availability invariants:

1. Persistent non-secret configuration lives on the attached state volume.
2. The SOPS-encrypted secrets file lives on the attached state volume.
3. Decrypted Docker secret source files exist only under `/run/vaultwarden-oci/secrets/`.
4. The normal SOPS policy contains:
   - one operational Age recipient whose private key is stored on the server;
   - one offline recovery Age recipient whose private key stays on USB.
5. The offline USB private key is never copied to or installed on the server, including during recovery.
6. Recovery generates a new operational Age key on the replacement VM.
7. A reboot recreates transient `/run` secrets before the stack is reconciled.
8. Backups, secret editing, secret rotation, direct secret utilities, systemd, and documentation must remain internally consistent with the new paths.

Treat the behavior and acceptance criteria below as authoritative. Adapt them cleanly to the current implementation; do not paste snippets blindly when existing function boundaries require a safer equivalent.

---

## Work discipline

- Keep functions readable and multi-line. Do not collapse substantial logic into one-liners.
- Do not introduce unrelated refactors, renames, formatting passes, or dependency changes.
- Do not add a new testing framework.
- Do not use `eval`.
- Do not source untrusted manifest files in `recover.sh`.
- Use existing logging and helper conventions where applicable.
- Preserve existing user-visible behavior unless this prompt explicitly changes it.
- If a required implementation cannot be completed within the permitted file list, stop and report the exact blocker instead of silently expanding scope.
- Use logical commits so the PR is reviewable:
  1. persistent configuration and transient runtime secrets;
  2. SOPS recipients and recovery workflow;
  3. systemd, tests, and documentation.

---

# Permitted scope

Modify only these files:

```text
startup.sh
edit-secrets.sh
lib/config.sh
utilities/secrets-edit.sh
utilities/secrets-rotate.sh
utilities/secrets-view.sh
utilities/secrets-list.sh
utilities/secrets-export-recovery-kit.sh
utilities/setup-env.sh
utilities/setup-secrets.sh
utilities/setup-systemd.sh
utilities/setup-storage.sh
utilities/backup-run.sh
docker-compose.yml.example
.env.example
recover.sh                              # new
systemd/vaultwarden-startup.service     # new
tests/test-recover.sh                   # new
docs/recovery-card.md                   # new
docs/ARCHITECTURE.md                    # new
docs/OPERATIONS.md
docs/DEPLOYMENT.md
docs/CONFIGURATION.md
README.md
RUNBOOK.md
CHANGELOG.md
```

Do not modify `setup.sh`.

`OFFLINE_AGE_RECIPIENT`, when supplied to setup, is inherited by `utilities/setup-secrets.sh`; no `setup.sh` change is needed.

At the end, verify the changed-file list against this scope. No exception is allowed unless the PR description identifies the file, the exact reason, and why the requested behavior cannot work without it.

---

# Functional deliverables

Deliver exactly these six functional items, plus the directly supporting systemd, backup, test, and documentation changes described below:

1. Persistent `install.env` configuration on the state volume, with legacy fallback.
2. Persistent SOPS ciphertext on the state volume.
3. Plaintext Docker secret source files only under `/run`.
4. Operational plus offline Age recipients, preserved across reruns.
5. A fully standalone `recover.sh`.
6. A rendered, printable recovery card.

---

# 1. Shared configuration helpers

Modify `lib/config.sh` only to:

- update its `Provides` header;
- add the two focused functions below;
- add them to the existing `export -f` list.

Do not otherwise refactor `lib/config.sh`.

## `resolve_secrets_file`

Behavior:

1. `${PROJECT_STATE_DIR}/secrets/secrets.yaml` exists: use it.
2. Otherwise repository-local `${PROJECT_ROOT}/secrets/secrets.yaml` exists: use it and warn.
3. Neither exists: return the persistent path as the creation target.

Use a safe fallback when `lib/defaults.sh` has not been sourced.

Required warning:

```text
Using repository-local secrets file — migrate to <persistent path>
```

Equivalent implementation:

```bash
resolve_secrets_file() {
    local default_state_dir="${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}"
    local persistent="${PROJECT_STATE_DIR:-$default_state_dir}/secrets/secrets.yaml"
    local legacy="${PROJECT_ROOT}/secrets/secrets.yaml"

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

## `load_project_environment`

This is the canonical loader for standalone utilities.

Capture non-empty caller overrides for:

```text
PROJECT_STATE_DIR
DATA_VOLUME_DEVICE
DATA_VOLUME_MOUNT
SOPS_AGE_KEY_FILE
```

Discover the bootstrap state directory in this order:

1. non-empty caller-exported `PROJECT_STATE_DIR`;
2. `PROJECT_STATE_DIR` read with `awk` from repository `.env`;
3. `PROJECT_STATE_DIR` read with `awk` from `/etc/vaultwarden/vaultwarden.env`;
4. `${_VW_DEFAULT_STATE_DIR:-/var/lib/vaultwarden}`.

Do not source a bootstrap file merely to discover the state directory.

After discovery, load exactly one complete environment through the existing safe `load_env_file` parser:

1. `${PROJECT_STATE_DIR}/config/install.env`;
2. repository `.env`, with warning;
3. `/etc/vaultwarden/vaultwarden.env`, with warning;
4. otherwise return failure with a clear error.

Required repository fallback warning:

```text
Using repository .env — migrate to <persistent install.env path> for production use
```

Required installed-environment fallback warning:

```text
Using installed systemd environment — migrate to <persistent install.env path> for production use
```

After loading:

- restore every captured non-empty caller override;
- export the restored values;
- call `resolve_secrets_file`.

Every listed standalone entry point must call `load_project_environment` after sourcing its libraries and before using any configuration or secret path:

```text
edit-secrets.sh
utilities/secrets-edit.sh
utilities/secrets-rotate.sh
utilities/secrets-view.sh
utilities/secrets-list.sh
utilities/secrets-export-recovery-kit.sh
utilities/backup-run.sh
utilities/setup-systemd.sh
utilities/setup-secrets.sh
```

Do not duplicate this resolution logic in those files.

---

# 2. `startup.sh` persistent configuration

Replace the current `load_environment` behavior with a thin use of the shared loader:

1. Log that configuration is being loaded.
2. Preserve the current legacy `.env` ownership-remediation block:
   - real user/group resolution;
   - root-owned `.env` correction;
   - readability check.
3. Run that remediation only when repository `.env` exists.
4. Call `load_project_environment`.
5. Set and export:

```bash
DOCKER_SECRETS_DIR="/run/vaultwarden-oci/secrets"
```

Do not directly `source` either environment file. Use `load_env_file` through the shared helper.

An explicitly exported recovery value must survive environment loading, including:

```text
PROJECT_STATE_DIR
DATA_VOLUME_DEVICE
DATA_VOLUME_MOUNT
SOPS_AGE_KEY_FILE
```

Preserve all other `startup.sh` behavior unless another section explicitly requires a path change.

---

# 3. Persistent environment artifacts from `utilities/setup-env.sh`

Keep repository `.env` for compatibility, but make the state-volume copy authoritative.

After `create_env_file` completes, always refresh the derived state artifacts—even when the existing `.env` is already current.

Implement this as a focused local helper called by `main` after `create_env_file`; do not let the current idempotency fast path skip it.

## Resolve the rendered values once

Read the normalized values from the completed repository `.env`:

```text
DOMAIN
PROJECT_STATE_DIR
```

Define once:

```text
rendered_domain
rendered_state_dir
repo_commit
recovery_repo_url
existing_offline_recipient
```

Rules:

- `rendered_domain` must begin with `https://`.
- `rendered_state_dir` must be an absolute path.
- `repo_commit` must be the 40-character `git rev-parse HEAD`.
- `recovery_repo_url` defaults to:
  `https://github.com/killer23d/VaultWarden-OCI.git`
- Do not derive the recovery URL from `git remote get-url origin`.
- Preserve a currently valid `OFFLINE_AGE_RECIPIENT` from an existing `dr-manifest.env`; otherwise use an empty value.
- Export `PROJECT_STATE_DIR="$rendered_state_dir"` before creating state artifacts.

Use the same resolved values for the manifest and rendered card so they cannot drift.

## Persistent `install.env`

Atomically copy the completed repository `.env` to:

```text
${PROJECT_STATE_DIR}/config/install.env
```

Requirements:

- create the config directory;
- create the temporary file in that same directory;
- mode `0600`;
- same owner/group as repository `.env`, so supported non-root utilities can read it;
- final same-directory `mv`;
- failure is fatal.

Do not use `root:root 0600` unless repository `.env` is itself root-owned.

## `dr-manifest.env`

Atomically replace:

```text
${PROJECT_STATE_DIR}/config/dr-manifest.env
```

This is project-managed state and contains exactly:

```text
DOMAIN=<normalized https URL>
REPO_URL=<canonical public HTTPS clone URL>
REPO_COMMIT=<full 40-character commit SHA>
OFFLINE_AGE_RECIPIENT=<preserved valid recipient or empty>
STATE_LAYOUT_VERSION=1
MANIFEST_UPDATED_AT=<UTC ISO-8601 timestamp>
```

Use mode `0644` and same-directory rename.

`utilities/setup-secrets.sh` updates `OFFLINE_AGE_RECIPIENT` after final recipient resolution.

## Rendered recovery card

Render `docs/recovery-card.md` to:

```text
${PROJECT_STATE_DIR}/config/recovery-card.md
```

Replace:

```text
<DOMAIN>
<REPO_URL>
<REPO_COMMIT>
```

Use a same-directory temporary file, mode `0644`, and final atomic `mv`.

The three replacements are validated project-controlled values. Avoid unnecessary complex escaping; still implement replacement safely.

---

# 4. SOPS ciphertext location and utility consistency

The canonical ciphertext is:

```text
${PROJECT_STATE_DIR}/secrets/secrets.yaml
```

Repository-local `secrets/secrets.yaml` remains a temporary legacy fallback only.

Every utility that creates, reads, edits, rotates, views, lists, exports, or backs up secrets must call the shared environment loader before using `SECRETS_FILE`.

In all repository utilities, set:

```bash
SOPS_CONFIG_FILE="${PROJECT_ROOT}/.sops.yaml"
```

In `recover.sh`, where `SCRIPT_DIR` is the repository root:

```bash
SOPS_CONFIG_FILE="${SCRIPT_DIR}/.sops.yaml"
```

Pass the SOPS config explicitly to operations that create ciphertext or update recipients.

Use SOPS global options before the command:

```bash
sops --config "$SOPS_CONFIG_FILE" updatekeys --yes "$staging"
```

Do not use:

```bash
sops updatekeys --yes --config ...
```

Decryption does not require a creation-policy config.

## Ciphertext staging invariant

Every ciphertext write must:

1. create the destination directory;
2. create the ciphertext staging file in that destination directory;
3. encrypt or copy into the staging file;
4. synchronize recipients on the staging file;
5. validate staged decryption;
6. promote with one same-filesystem `mv`.

Never run `updatekeys` against live `SECRETS_FILE`.

Canonical sequence:

```text
A. Produce encrypted staging ciphertext.
B. sops --config "$SOPS_CONFIG_FILE" updatekeys --yes "$staging"
C. SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops -d "$staging" >/dev/null
D. mv "$staging" "$SECRETS_FILE"
```

Apply this to:

- initial setup when applicable;
- interactive edit;
- rotation;
- adding an offline recipient to existing ciphertext.

Do not promote ciphertext if any preceding step fails.

---

# 5. Plaintext runtime secrets only under `/run`

Canonical runtime directory:

```text
/run/vaultwarden-oci/secrets
```

No plaintext Docker secret source file may be written under the repository or state volume.

## Permission model

Include this exact rationale in the PR description:

> Docker Compose file-type secrets are bind mounts. The engine ignores uid/gid/mode in the secrets block. Non-root container processes (Vaultwarden PUID, Caddy UID 2000) reach files through the bind mount and require world-readable files. 0700 on the parent directory protects against ordinary host users. /run is a tmpfs; files are gone on reboot. The systemd startup unit recreates them.

Implementation:

- directory: `root:root`, mode `0700`;
- individual runtime secret files: `root:root`, mode `0444`.

Use `install -d -m 0700` and `install -m 0444` where practical.

Avoid a brittle unmatched glob. To normalize modes after export, use a safe mechanism such as:

```bash
find "$DOCKER_SECRETS_DIR" -maxdepth 1 -type f -exec chmod 0444 {} +
```

## `startup.sh`

Before export:

- create `/run/vaultwarden-oci/secrets`;
- ensure mode `0700`.

Export all Docker secret files there.

Update `prepare_push_secret_placeholders` to create:

```text
/run/vaultwarden-oci/secrets/push_installation_id
/run/vaultwarden-oci/secrets/push_installation_key
```

with mode `0444`, owner `root:root`.

Remove the old PGID ownership logic.

## `utilities/setup-secrets.sh`

During bootstrap and configure:

- resolve persistent `SECRETS_FILE`;
- never materialize plaintext under persistent storage;
- materialize runtime files only under `/run/vaultwarden-oci/secrets`;
- normalize directory/file permissions.

## `utilities/secrets-rotate.sh`

After successful staged ciphertext promotion:

- regenerate runtime files only under `/run/vaultwarden-oci/secrets`;
- do not write repository or state-volume `.docker_secrets`;
- preserve the offline recipient through the staged `updatekeys` sequence.

## Compose template

In `docker-compose.yml.example`:

- change every top-level file-backed secret source to:
  `/run/vaultwarden-oci/secrets/<name>`;
- remove the `./secrets:/secrets` mount from `init-permissions`;
- remove all `/secrets` checks, ownership changes, and placeholder creation from that service;
- remove any `.docker_secrets` bind mount or path.

Update `.env.example` comments accordingly.

---

# 6. Backup HMAC compatibility

`utilities/backup-run.sh` currently depends on a persistent plaintext `file_integrity_hmac_key`. That path is removed by this PR and must be fixed in the same PR.

After `load_project_environment`, obtain the key only in memory:

```bash
FILE_INTEGRITY_HMAC_KEY="$(
    SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" \
        sops -d "$SECRETS_FILE" \
        | yq -r '.file_integrity_hmac_key // ""'
)"
```

Requirements:

- no plaintext temp file;
- retain existing empty and placeholder validation;
- preserve the current authenticated-integrity policy:
  - fail when authenticated integrity is required;
  - otherwise retain the existing documented fallback behavior;
- make no unrelated changes to `utilities/backup-run.sh`.

---

# 7. Two-recipient SOPS policy

Every generated `.sops.yaml` uses:

```yaml
creation_rules:
  - path_regex: '.*\.yaml$'
    age: "<operational-recipient>[,<offline-recipient>]"
```

The regex must match both live ciphertext and staging names such as `secrets.ABC123.yaml`.

When an offline recipient is present, place this comment immediately above `age:`:

```yaml
# Offline recovery key — USB only, never stored on server
```

Do not write that comment when only the operational recipient exists.

Always deduplicate recipients and keep the operational recipient first.

## Offline-recipient resolution in `utilities/setup-secrets.sh`

Resolve in this order:

1. Non-empty `OFFLINE_AGE_RECIPIENT` environment value.
2. Valid value from `${PROJECT_STATE_DIR}/config/dr-manifest.env`.
3. Existing valid non-operational recipient from `.sops.yaml`.
4. TTY prompt.
5. Empty only when this is genuinely unconfigured and the operator skips it.

TTY prompt:

```text
Enter offline recovery Age public key (press Enter to skip):
```

Validation:

```bash
[[ "$offline_recipient" =~ ^age1[a-z0-9]{58}$ ]]
```

For policy recovery:

1. Derive the current operational public recipient:
   `age-keygen -y "$SOPS_AGE_KEY_FILE"`.
2. Read the comma-separated `age` value with `yq`.
3. Validate each recipient.
4. Exclude the operational recipient.
5. Exactly one remaining valid recipient: preserve it.
6. More than one remaining recipient: abort with:

```text
Multiple unknown recipients in .sops.yaml — review manually before continuing.
```

A non-interactive rerun must never remove an existing offline recipient.

Offline-recipient removal is not an implicit setup behavior. It requires a deliberate documented manual procedure using a staged ciphertext copy and explicit policy update.

After resolution, atomically replace or append `OFFLINE_AGE_RECIPIENT` in `dr-manifest.env`. Preserve the other manifest fields and update `MANIFEST_UPDATED_AT`.

If an existing encrypted file needs the new offline recipient, use the staged `updatekeys` sequence before promotion.

---

# 8. Standalone `recover.sh`

Create a readable, fully standalone root-level script.

Usage:

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /media/usb/age-key.txt
```

Requirements:

- `set -euo pipefail`;
- no `lib/` sourcing;
- no `eval`;
- do not source `install.env` or `dr-manifest.env`;
- parse manifest/env keys with `awk`;
- USB private key is never copied to local storage;
- a new operational Age key is generated on the replacement VM;
- use clear functions rather than compressed one-liners;
- comment non-obvious transaction and rollback logic.

Test-only path overrides:

```text
VW_RECOVER_ETC_DIR
VW_RECOVER_STARTUP_SCRIPT
```

Production defaults:

```text
/etc/vaultwarden
<repository>/startup.sh
```

## Argument and prerequisite checks

Require:

```text
mountpoint
findmnt
sops
age-keygen
awk
git
install
docker
curl
bash
blkid
mktemp
cp
mv
rm
chmod
```

Also require:

```bash
docker compose version
```

Reject missing option values with:

```text
Option --state-dir requires a value.
Option --key requires a value.
```

Require root.

Missing-argument output must include:

```text
Usage: ./recover.sh --state-dir DIR --key FILE
```

## Recovery guards

In order:

1. `--state-dir` and `--key` supplied.
2. `mountpoint -q "$state_dir"` succeeds, otherwise exact message:

```text
State directory is not a mounted volume. Attach the OCI block volume first.
```

3. Regular, non-symlink manifest exists:
   `${state_dir}/config/dr-manifest.env`
4. `${state_dir}/data` exists.
5. `${state_dir}/secrets/secrets.yaml` exists.
6. Regular, non-symlink `${state_dir}/config/install.env` exists.
7. key file exists.
8. repository contains `docker-compose.yml.example`.
9. manifest values validate:
   - `DOMAIN` begins with `https://`;
   - `REPO_COMMIT` is 40 lowercase hexadecimal characters;
   - `STATE_LAYOUT_VERSION=1`;
   - any offline recipient has valid Age format.
10. checked-out commit equals `REPO_COMMIT`.
11. create `docker-compose.yml` from the example when absent.
12. USB key decrypts the existing ciphertext:
    `SOPS_AGE_KEY_FILE="$key_file" sops -d "$secrets_file"`.

Do not assume `.sops.yaml` exists in a fresh clone. It is ignored by Git.

## USB recipient identity

Derive:

```bash
usb_public_recipient="$(age-keygen -y "$key_file")"
```

Rules:

- if the manifest has an offline recipient, it must equal the USB public recipient;
- mismatch is fatal with a clear error;
- if the manifest value is empty, adopt the USB public recipient as the offline recipient and update the manifest only after successful recovery.

The newly rekeyed ciphertext must always retain the USB recipient. Recovery must not eliminate offline recovery capability.

## Rekey transaction

Generate:

- a new operational private key in a temp file;
- its public recipient;
- a temporary SOPS policy containing:
  - new operational recipient;
  - USB offline recipient.

Pass the temporary policy directly to SOPS:

```bash
SOPS_AGE_KEY_FILE="$key_file" \
    sops --config "$temporary_policy" \
        updatekeys --yes "$ciphertext_staging"
```

Do not make the policy live before staged update and validation succeed.

Create and track:

```text
ciphertext staging file
new-key staging file
temporary policy
original ciphertext backup
original active-key backup, when present
original .sops.yaml backup, when present
presence flags for original key and policy
```

Backups must remain available until final live validation succeeds.

Validation before promotion:

1. USB key authorizes `updatekeys`.
2. new operational temp key decrypts staged ciphertext.
3. staged installed key decrypts staged ciphertext.

Promotion order:

1. ciphertext;
2. operational key;
3. `.sops.yaml`;
4. final decryption using the now-live operational key.

Handled failure requirements:

- ciphertext promotion failure: all live files unchanged;
- key promotion failure: restore original ciphertext;
- policy promotion failure: restore ciphertext and key, and restore/remove policy according to prior existence;
- final live validation failure: restore/remove all three live artifacts according to prior existence;
- when no old active key existed, rollback removes the newly installed key;
- when no old `.sops.yaml` existed, rollback removes the new policy;
- cleanup removes every unpromoted temp and backup file;
- do not delete any rollback backup before final live validation passes.

A crash between cross-filesystem promotions cannot be fully atomic. The retained USB recipient must still be able to decrypt the staged/new ciphertext, making the state recoverable.

## Persistent storage identity

After cryptographic promotion succeeds:

1. obtain the mounted source with `findmnt`;
2. obtain its UUID with `blkid`;
3. prefer `/dev/disk/by-uuid/<uuid>`, with the mounted source as fallback.

Atomically replace or append these keys in `install.env`:

```text
PROJECT_STATE_DIR
DATA_VOLUME_MOUNT
DATA_VOLUME_DEVICE
SOPS_AGE_KEY_FILE
```

Preserve unrelated keys and original file mode/ownership.

Also atomically update the manifest:

```text
OFFLINE_AGE_RECIPIENT=<USB public recipient>
MANIFEST_UPDATED_AT=<new UTC timestamp>
```

## Startup and health

Export:

```text
PROJECT_STATE_DIR
DATA_VOLUME_MOUNT
DATA_VOLUME_DEVICE
SOPS_AGE_KEY_FILE
```

Run:

```bash
bash "$VW_STARTUP_SCRIPT"
```

Health check:

```bash
curl -sf "${DOMAIN%/}/alive"
```

Do not abort solely because the health check fails.

Print either `Health check: PASS` or `Health check: FAIL`.

Final success line:

```text
Recovery complete. Vaultwarden is running at <DOMAIN>
```

When health fails, print the exact Docker Compose log command using the repository’s actual compose file.

---

# 9. Recovery card

Create `docs/recovery-card.md` as the canonical template.

It must be suitable for an A5 card, no more than two printed sides, and prioritize direct commands over explanation.

Top comment:

```html
<!-- TEMPLATE — do not print this file.
     The rendered copy with your site's real values is at:
       ${PROJECT_STATE_DIR}/config/recovery-card.md
     Fill in CONTACT_NAME and CONTACT_PHONE before printing.
-->
```

Required content:

```markdown
# Vaultwarden Recovery Card

Store this card with the offline Age key USB drive.

## Before you start

- This printed card with contact details filled in
- USB drive containing `age-key.txt`
- OCI console access

## Step 1 — Create a supported Ubuntu LTS VM

Use Ubuntu 24.04 LTS where available. Ubuntu 22.04 or later is supported.

## Step 2 — Attach the data volume and identify the device

```bash
lsblk
```

Find the attached volume device, for example `/dev/sdb`.

## Step 3 — Clone the recorded repository version

```bash
sudo git clone <REPO_URL> /opt/VaultWarden-OCI
sudo git -C /opt/VaultWarden-OCI checkout <REPO_COMMIT>
cd /opt/VaultWarden-OCI
```

## Step 4 — Install prerequisites and adopt the existing volume

```bash
sudo ./utilities/setup-system.sh --auto \
  --data-mount /mnt/vw-data

sudo DATA_VOLUME_EXISTING_FS_OK=true \
  ./utilities/setup-storage.sh \
    --mode setup \
    --data-device /dev/sdb \
    --data-mount /mnt/vw-data
```

Replace `/dev/sdb` with the device found through `lsblk`.

## Step 5 — Run recovery

```bash
sudo ./recover.sh \
  --state-dir /mnt/vw-data \
  --key /media/usb/age-key.txt
```

## Step 6 — Reinstall managed services

```bash
sudo PROJECT_STATE_DIR=/mnt/vw-data \
  ./utilities/setup-systemd.sh install
```

## Step 7 — Verify

Open `<DOMAIN>` in a browser. If login works, recovery is complete.

## If something fails

The script prints the failure and stops.

Contact: `<CONTACT_NAME>` — `<CONTACT_PHONE>`
```

Do not include a command that reads `/mnt/vw-data` before the storage-adoption command has mounted it.

---

# 10. Systemd boot integration

Create `systemd/vaultwarden-startup.service` as a template.

Template placeholders:

```text
@PROJECT_ROOT@
@PROJECT_STATE_DIR@
```

Unit:

```ini
[Unit]
Description=VaultWarden-OCI startup - recreate runtime secrets and reconcile containers
Requires=docker.service
After=local-fs.target docker.service network-online.target
Wants=network-online.target
RequiresMountsFor=@PROJECT_STATE_DIR@

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/vaultwarden/vaultwarden.env
WorkingDirectory=@PROJECT_ROOT@
ExecStart=/bin/bash @PROJECT_ROOT@/startup.sh --skip-pull
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## `utilities/setup-systemd.sh`

- call `load_project_environment`;
- use persistent `install.env` as the canonical source for `/etc/vaultwarden/vaultwarden.env`;
- repository `.env` and installed env remain legacy/bootstrap fallbacks only;
- install the environment file securely;
- add the startup service to managed units;
- do not copy the template through the generic service loop;
- render both placeholders to a same-directory temp file;
- atomically install the rendered unit;
- run `systemctl daemon-reload`;
- enable `vaultwarden-startup.service`;
- the `install` action must perform the enable step.

Preserve existing timer/service behavior.

Include this exact explanation in the PR description:

> After Docker becomes available, this unit recreates `/run/vaultwarden-oci/secrets/` with the decrypted runtime secret files and runs `docker compose up -d` to reconcile and start containers, including any containers whose automatic restart policy initially failed because the transient source files were absent at that point. Achieving true pre-Docker secret materialization would require a separate service that does not call Docker.

## `utilities/setup-storage.sh`

After successfully adopting an existing filesystem:

- atomically replace or append:
  - `PROJECT_STATE_DIR`;
  - `DATA_VOLUME_MOUNT`;
  - `DATA_VOLUME_DEVICE`;
  - `SOPS_AGE_KEY_FILE` only when the intended key exists;
- use UUID-backed device path where available;
- preserve unrelated entries and file metadata;
- retain the existing Docker mount guard.

---

# 11. Documentation

Treat stale documentation as a bug, but do not rewrite unrelated sections.

Update:

## `README.md`

- persistent `install.env`;
- persistent encrypted secrets path;
- transient `/run` secret path;
- two-recipient SOPS policy;
- disaster-recovery summary and card link.

## `RUNBOOK.md`

- exact recovery command;
- offline-key add/rotate/remove procedure;
- reboot behavior and startup service;
- environment precedence;
- no old `.docker_secrets` paths.

## `docs/OPERATIONS.md`

- offline key lifecycle;
- explicit staged procedure for removal;
- transient runtime-secret recreation;
- persistent config precedence and migration;
- manifest lifecycle;
- when to reprint the rendered card.

## `docs/DEPLOYMENT.md`

- supported Ubuntu LTS wording;
- persistent artifacts created by setup;
- offline-recipient prompt;
- transient runtime secrets;
- recovery-card location.

## `docs/CONFIGURATION.md`

Correct the current two-file description. Document:

- repository `.env` as compatibility copy;
- state-volume `install.env` as authoritative;
- state-volume encrypted `secrets.yaml`;
- installed systemd environment as bootstrap fallback;
- precedence order;
- transient `/run` secret source files.

## `docs/ARCHITECTURE.md`

Create a focused architecture document covering:

- configuration discovery and precedence;
- state-volume layout;
- ciphertext and plaintext secret lifetimes;
- operational plus offline recipients;
- why `'.*\.yaml$'` matches staging files;
- reboot and startup-service flow;
- recovery key transaction.

## `docs/recovery-card.md`

Use the exact workflow above.

## `CHANGELOG.md`

- add the entry beneath the first, topmost `## [Unreleased]`;
- follow the existing style;
- do not restructure or deduplicate unrelated historical changelog content;
- summarize the six functional changes;
- do not enumerate every modified file.

All documentation must agree on paths, commands, Ubuntu support, environment precedence, and recipient behavior.

---

# 12. Tests

Create `tests/test-recover.sh` using shell mocks and temporary directories only. Do not add a framework.

Production script test overrides:

```text
VW_RECOVER_ETC_DIR
VW_RECOVER_STARTUP_SCRIPT
```

Mock or PATH-stub as required:

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

An `mv` mock must fail based on the destination path, not “the second invocation,” and delegate all other moves to the real command.

The mock startup script prints:

```text
mock startup: OK
```

Every test:

- cleans up;
- does not modify real `/etc/vaultwarden`;
- compares pre/post real `/etc/vaultwarden` state.

Required tests:

1. missing `--state-dir` fails with usage;
2. missing `--key` fails with usage;
3. non-mounted state directory emits the exact required message;
4. `updatekeys` failure leaves ciphertext, active key, and policy unchanged;
5. key-promotion failure after ciphertext promotion restores ciphertext and prior key state;
6. post-promotion live-decryption failure restores ciphertext, key, and policy, including the no-prior-key/no-prior-policy case;
7. happy path from a fresh-clone state with no `.sops.yaml`:
   - exits zero;
   - prints mock startup output;
   - changes ciphertext;
   - installs new operational key;
   - creates valid `.sops.yaml`;
   - retains the USB public recipient;
   - updates manifest and `install.env`.

Use byte-for-byte comparisons for rollback assertions.

---

# 13. Validation

Run all validation from the repository root.

## Baseline and scope

```bash
git rev-parse HEAD
git diff --check
git diff --name-only delta...HEAD
```

Confirm the starting commit and verify every changed file is permitted.

## Syntax

Run `bash -n` separately for every modified shell file:

```bash
syntax_files=(
  startup.sh
  recover.sh
  edit-secrets.sh
  utilities/secrets-edit.sh
  utilities/secrets-rotate.sh
  utilities/secrets-view.sh
  utilities/secrets-list.sh
  utilities/secrets-export-recovery-kit.sh
  utilities/setup-env.sh
  utilities/setup-secrets.sh
  utilities/setup-systemd.sh
  utilities/setup-storage.sh
  utilities/backup-run.sh
  tests/test-recover.sh
)

for file in "${syntax_files[@]}"; do
  printf '== bash -n %s ==\n' "$file"
  bash -n "$file"
  printf 'exit status: %s\n' "$?"
done
```

## ShellCheck

When installed:

```bash
shellcheck "${syntax_files[@]}"
```

If absent, report the skip.

## Recovery tests

```bash
bash tests/test-recover.sh
```

## Rendered systemd validation

Do not validate the unresolved template.

Render both placeholders into a temporary `.service` file and run:

```bash
systemd-analyze verify "$rendered_unit"
```

A nonzero status blocks the PR. Do not suppress it with `|| true`.

If `systemd-analyze` is absent, report the skip.

## Compose validation

When Docker is available:

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

If Docker is absent, report the skip.

## Static path audit

Run:

```bash
git grep -nE 'secrets/\.docker_secrets|\.docker_secrets' -- \
  ':!CHANGELOG.md'
```

Any remaining live-code or current-documentation reference must be justified or removed.

## Existing relevant tests

Run any existing repository tests that directly exercise modified setup, storage, secrets, backup, or systemd behavior. Report each command and result. Do not invent or add an unrelated test framework.

Every non-skipped validation must exit zero before opening the PR.

---

# 14. PR requirements

Open a draft PR targeting `delta`.

The PR description must include:

1. each of the six functional deliverables and modified files;
2. configuration and secret-path fallback warnings;
3. environment precedence;
4. offline-recipient order:
   environment → manifest → policy → TTY → skip;
5. USB-key identity verification during recovery;
6. the exact `/run` permission rationale;
7. the exact systemd explanation above;
8. exact `recover.sh` usage;
9. systemd installation command;
10. verified CrowdSec bouncer-regeneration command for this repository;
11. what remains manual;
12. exact output and exit status from every validation;
13. each skipped validation and missing tool;
14. final changed-file scope confirmation;
15. one sentence per updated documentation file.

Do not claim a validation passed unless its recorded command exited zero.

Do not open the PR when a required validation fails.

---

# Completion report

When finished, provide:

- branch name;
- commit list;
- draft PR URL;
- concise changed-file summary;
- validation summary;
- any skipped checks;
- any residual caveat that could not be eliminated within scope.
