# Restore Runtime Permissions

This document describes the post-restore runtime permission contract for full and emergency restores.

## Why this exists

Full and emergency archives are portable DR artifacts. They are extracted without preserving archive owners or modes so a backup created on one host can be restored on a replacement host without blindly trusting stale numeric UIDs, GIDs, or filesystem modes.

After extraction, restore must re-apply the target host's runtime permission contract before services start. This is especially important for Caddy, because the Caddy container runs as UID/GID `2000:2000` and must be able to write its mounted `/data`, `/config`, and `/var/log/caddy` paths for certificate storage, autosave, locks, OCSP cache, and access/security logs.

## Post-restore contract

After a full or emergency restore, `restore.sh` calls the shared runtime repair helper before the service-start gate.

The helper normalizes these paths when they exist:

| Path | Owner | Mode | Purpose |
| :-- | :-- | :-- | :-- |
| `${PROJECT_STATE_DIR}/data` | `${PUID}:${PGID}` | directories `0750`, files `0640` | VaultWarden app data and SQLite DB |
| `${PROJECT_STATE_DIR}/logs/vaultwarden` | `${PUID}:${PGID}` | directories `0750`, files `0640` | VaultWarden logs |
| `${PROJECT_STATE_DIR}/caddy/data` | `2000:2000` | directories `0750`, files `0640` | Caddy cert/storage state mounted at `/data` |
| `${PROJECT_STATE_DIR}/caddy/config` | `2000:2000` | directories `0750`, files `0640` | Caddy autosave/config state mounted at `/config` |
| `${PROJECT_STATE_DIR}/logs/caddy` | `2000:2000` | directories `0750`, files `0640` | Caddy logs mounted at `/var/log/caddy` |
| `${PROJECT_STATE_DIR}/config` | `root:root` | `0700` directory, `0600` private files | Installed runtime config and DR manifest |
| `${PROJECT_STATE_DIR}/secrets` | `root:root` | `0700` directory, `0600` `secrets.yaml` | Persistent encrypted SOPS secrets |
| `/etc/vaultwarden` | `root:root` | `0700` directory, `0600` private files | Installed root-operated config, Age key, rclone config |
| `/run/vaultwarden-oci/secrets` | `root:root` | `0700` directory, runtime secret files `0444` | Transient Docker runtime secrets |

The helper also removes `${PROJECT_STATE_DIR}/data/.permissions-initialized` after restore. That sentinel is safe during normal startup, but after DR it may have come from another host and can cause startup-time initialization to skip a permission scan that the replacement host actually needs.

## Operator workflow

For normal DR, restore handles this automatically:

```bash
sudo ./restore.sh latest full
# or
sudo ./restore.sh latest emergency
```

For a manual repair, or after pulling a repo update that introduces this contract, run:

```bash
sudo utilities/repair-permissions.sh
sudo docker compose restart caddy
sudo ./maintenance.sh health
```

`utilities/repair-permissions.sh --check` is non-mutating and reports drift for known paths:

```bash
sudo utilities/repair-permissions.sh --check
```

A healthy host should show the Caddy storage check as passing in health output:

```text
[pass] permissions:caddy-storage    Caddy storage/log permissions are correct
```

## Symptoms this prevents

If Caddy storage is restored as `root:root` or with overly restrictive modes, the container may start but fail to serve the origin TLS path correctly. Typical symptoms include:

- Cloudflare HTTP `525` on the public hostname.
- Local SNI HTTPS probe to `127.0.0.1` fails or returns HTTP `000`.
- Caddy logs mention permission errors for `/data/caddy`, `/config/caddy`, `/var/log/caddy`, certificate keys, autosave, or storage locks.

Quick validation with normal certificate and hostname verification:

```bash
DOMAIN="vault.example.com"

curl -fsS -v --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/alive" \
  -o /dev/null -w "local HTTPS /alive: HTTP %{http_code}\n"

curl -fsS -v --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/config" \
  -o /dev/null -w "local HTTPS /api/config: HTTP %{http_code}\n"

sudo docker logs vaultwarden_caddy --tail=120 2>&1 \
  | grep -Ei 'permission|certificate|tls|handshake|error|warn|storage|autosave' || true
```

Expected result after repair: local HTTPS `/alive` and `/api/config` return HTTP `200`, and `sudo ./maintenance.sh health` reports no Caddy storage permission drift.

## What not to do

Do not fix restore drift with broad permissions such as:

```bash
sudo chown -R 2000:2000 "$PROJECT_STATE_DIR"
sudo chmod -R 777 "$PROJECT_STATE_DIR"
```

Those commands can expose root-operated secrets, break encrypted SOPS state, or cause later restores to be harder to reason about. Use the explicit repair helper instead.
