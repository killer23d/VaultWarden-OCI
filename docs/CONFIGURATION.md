# Configuration

Configuration is split by lifetime and sensitivity.

1. `${PROJECT_STATE_DIR}/config/install.env` is the authoritative persistent non-secret environment on the state volume.
2. Repository `.env` is a compatibility and bootstrap copy for existing workflows.
3. `/etc/vaultwarden/vaultwarden.env` is an installed systemd bootstrap fallback.
4. `${PROJECT_STATE_DIR}/secrets/secrets.yaml` is the persistent SOPS-encrypted secrets file.
5. `/run/vaultwarden-oci/secrets/` contains transient decrypted Docker Compose secret source files recreated at startup.

Standalone tools load one complete environment in this order: persistent `install.env`, repository `.env`, installed systemd environment. If none exists, the tool fails with a clear error.
