# Security Guide — VaultWarden-OCI

This guide reflects the current security posture of the project: OCI-aware network controls, Cloudflare-backed edge protection, encrypted secret management, recovery-first operations, and a script-driven deployment model designed to reduce configuration drift.

Related docs: [DEPLOYMENT.md](DEPLOYMENT.md) · [CONFIGURATION.md](CONFIGURATION.md) · [OPERATIONS.md](OPERATIONS.md)

---

## Security model

Security in this project is layered rather than dependent on a single control.

The core layers are:

- OCI network controls for inbound exposure.
- Cloudflare DNS and edge controls for public web traffic.
- Caddy for HTTPS termination and web policy enforcement.
- VaultWarden application settings for account and feature policy.
- Fail2ban for abuse detection and automated response.
- Age + SOPS for secret protection.
- Backup and recovery procedures that assume compromise or failure can happen.

---

## Network and edge controls

### OCI first

OCI networking must allow the intended traffic before the host can function correctly.

The standard deployment model expects:

- TCP `80` and `443` open so certificate bootstrap and web access work.
- TCP `22` open only to your intended management source range where possible.

For hardened deployments, restrict web ingress at OCI to Cloudflare IP ranges instead of leaving it fully open after bootstrap.

### Cloudflare staging and proxying

Use **DNS Only** during bootstrap so Caddy can complete certificate issuance cleanly. After the deployment is healthy, switch the DNS record to **Proxied** and use **Full (Strict)** SSL/TLS mode.

This keeps certificate issuance predictable and then restores the intended edge-protected posture.

---

## Caddy and HTTPS

Caddy is the project’s HTTPS and reverse-proxy layer.

Its role includes:

- TLS certificate management.
- Reverse proxying to VaultWarden.
- Web security headers.
- Admin-surface protection behavior.
- Request handling and edge-facing logging.

Changes to edge behavior should be made through the repository templates and then applied with `setup.sh`, `startup.sh`, and `health.sh`.

---

## Fail2ban and response model

Fail2ban remains part of the current security posture, but its purpose is aligned with the Cloudflare-backed deployment model.

For proxied web traffic, the design favors Cloudflare edge enforcement rather than relying on local host firewall blocks for the public application path. Host-level controls remain relevant for SSH and other non-proxied surfaces.

Common validation commands:

```bash
docker compose exec fail2ban fail2ban-client status
docker compose exec fail2ban fail2ban-client status vaultwarden-auth
docker compose logs fail2ban
```

---

## Host firewall and service exposure

UFW and host-level exposure controls still matter, but they are only one layer of the security model.

Use host firewalls to keep the local surface narrow, and use OCI plus Cloudflare to enforce the broader network policy. Avoid opening extra ports unless a documented use case requires them.

---

## Secrets protection

The project protects secret material through Age + SOPS rather than long-lived plaintext files.

Use only the supported secret workflows:

```bash
./setup-secrets.sh
./edit-secrets.sh
./edit-secrets.sh --test
./edit-secrets.sh --export-recovery-kit
```

Good practice:

- Keep secrets out of `.env` unless they are explicitly meant to be non-sensitive configuration.
- Do not leave decrypted secret files behind.
- Export recovery material and store it outside the server.
- Revalidate after secret changes with `startup.sh --force` and `health.sh`.

---

## Backup and recovery security

A secure deployment is not only about prevention; it is also about controlled recovery.

Current recovery-related protections include:

- Encrypted backup archives.
- Explicit recovery-kit export.
- Age-key preservation outside the host.
- Emergency backup workflows before risky changes.
- Restore tooling that is part of the normal documented operations model.

Recommended commands:

```bash
./backup.sh --type emergency
./edit-secrets.sh --export-recovery-kit
./health.sh --comprehensive
```

---

## Break-glass access

The break-glass admin flow exists for recovery scenarios such as console-based access when the normal administration path is unavailable.

Manage it deliberately:

```bash
./create-breakglass-admin.sh --create
./create-breakglass-admin.sh --status
./create-breakglass-admin.sh --remove
```

Treat this as a recovery control, not as the standard daily admin account model.

---

## Update security

Use `./update.sh` for normal upgrades because it wraps updates in a validation-aware workflow.

This is safer than ad-hoc container pulls because it fits the documented operational path and can be paired with backup and restore procedures when something goes wrong.

A conservative security posture also means preferring explicit version review over blind constant drift to latest images in production.

---

## Cron and automation hardening

Scheduled operations are part of the security posture because drift, stale jobs, and overlapping maintenance can all create operational risk.

Use:

```bash
sudo ./cron-setup.sh --install
sudo ./cron-setup.sh --validate
```

Important note: the lock directory `/run/vaultwarden-locks/` is cleared on reboot, so validation or recreation after restart is part of keeping the automation model safe and reliable.

---

## Template discipline

One of the easiest ways to weaken the security posture is to create undocumented local drift.

The safer pattern is:

1. Edit templates or encrypted secrets.
2. Reapply with `setup.sh` when template-backed files change.
3. Restart with `startup.sh --force`.
4. Validate with `health.sh`.

This keeps the runtime environment closer to what the repository actually documents and tests operationally.

---

## Practical hardening checklist

Use this as an ongoing checklist:

- Keep OCI ingress tight, especially SSH.
- Use Cloudflare proxying after initial certificate bootstrap.
- Disable open signup unless you have a specific reason not to.
- Protect admin access with the project’s configured controls.
- Keep secrets encrypted and recovery material external.
- Run scheduled health, backup, and maintenance automation.
- Review logs for authentication abuse and email failures.
- Test restore paths periodically, not just backups.
- Revisit customization and migration changes for hidden drift.

Security in this project comes from keeping the layers working together, not from any one feature alone.
