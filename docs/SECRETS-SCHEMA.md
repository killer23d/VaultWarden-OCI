# secrets-schema.yaml Reference

## Overview
`secrets-schema.yaml` is the single source of truth for every secret key
managed by VaultWarden-OCI. It is committed unencrypted and contains no
secret values — only structural metadata.

## Adding or Renaming a Secret Key

1. Edit `secrets-schema.yaml` — add or rename the key entry
2. Run `./edit-secrets.sh edit` — type the value next to the key, save, quit

The key is then available to all consumers. No script edits required.

## Field Reference

| Field | Type | Description |
|---|---|---|
| `key` | string | Key name as it appears in `secrets.yaml` |
| `label` | string | Human-readable prompt shown during interactive collection |
| `hash` | enum | Post-collection transform: `argon2id` \| `bcrypt` \| `plain` \| `none` |
| `placeholder` | string | Value written by `bootstrap` before real secrets are set |
| `collect` | enum | Collection mode: `interactive` \| `auto` \| `conditional` \| `skip` |
| `auto_fn` | string | Bash function called when `collect: auto` (empty otherwise) |
| `services` | list | Docker Compose services to restart after rotation |
| `required` | bool | If true, `check_placeholder_values()` fails when still a placeholder |
| `hint` | string | Comment injected above the key in the editor during `edit` |

## schema_version
The file must begin with `schema_version: 1`. Scripts assert this value
and fail fast if it does not match.

## Dependencies
`lib/schema.sh` requires `yq` (v4+). Installed by `setup.sh` as a
prerequisite. Install manually: `sudo snap install yq`

## collect: conditional
Keys marked `collect: conditional` (currently `push_installation_id` and
`push_installation_key`) have 3-way collection logic handled verbatim in
`collect_secrets()`. The schema marker is a forward-declaration only.