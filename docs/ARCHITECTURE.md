# VaultWarden-OCI Resilient State Architecture

## Configuration precedence
Standalone tools call `load_project_environment`. It discovers `PROJECT_STATE_DIR` from a caller override, repository `.env`, `/etc/vaultwarden/vaultwarden.env`, then `/var/lib/vaultwarden`. It then loads one complete environment in this order: `${PROJECT_STATE_DIR}/config/install.env`, repository `.env`, installed systemd environment.

## State-volume layout
Persistent non-secret configuration is `${PROJECT_STATE_DIR}/config/install.env`. Disaster-recovery metadata is `${PROJECT_STATE_DIR}/config/dr-manifest.env`. The encrypted SOPS ciphertext is `${PROJECT_STATE_DIR}/secrets/secrets.yaml`. Application data, logs, backups, and Caddy state remain under `${PROJECT_STATE_DIR}`.

## Secret lifetimes
SOPS ciphertext is persistent. Decrypted Docker Compose secret source files are transient and are created only in `/run/vaultwarden-oci/secrets/`. `/run` is tmpfs, so reboot removes plaintext files.

## Recipients
The normal SOPS policy contains the operational Age recipient first and an offline recovery Age recipient second when configured. The path regex `.*\.yaml$` intentionally matches both `secrets.yaml` and staging names such as `secrets.ABC123.yaml` during atomic rewrites.

## Reboot flow
The `vaultwarden-startup.service` unit waits for the state volume through `RequiresMountsFor`, recreates runtime secrets under `/run/vaultwarden-oci/secrets/`, and reconciles containers with `startup.sh --skip-pull`.

## Recovery transaction
`recover.sh` uses the USB Age key only in place, generates a replacement operational key, updates a staged ciphertext with both recipients, validates staged decryptions, then promotes ciphertext, key, and policy with rollback backups retained until final validation passes.
