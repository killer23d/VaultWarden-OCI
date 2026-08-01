# Startup, Repair, and Image Ownership

VaultWarden-OCI separates routine startup from corrective reconciliation and image updates.

## Routine startup

```bash
sudo ./startup.sh
```

Routine startup validates the selected local configuration and starts with the images already present on the host. It does not repair permission drift, delete managed Docker orphans, change egress NAT, update external DNS, or pull images. Compose is invoked with a no-pull policy.

When a required condition is unsafe, startup stops before starting services and prints the supported correction. Common commands are:

```bash
sudo ./utilities/repair-permissions.sh
sudo ./utilities/setup-firewall.sh --phase iptables --auto
sudo ./utilities/maintenance-update-dns.sh
sudo ./utilities/maintenance-update.sh --images
```

## Explicit runtime repair

```bash
sudo ./startup.sh --repair
```

Repair mode runs under the existing startup operation guard. It performs the supported corrections in this deterministic order:

1. permission reconciliation;
2. managed-project orphan reconciliation;
3. VaultWarden egress NAT reconciliation;
4. DNS reconciliation.

Each step must succeed before the next step runs. Services start only after all repairs and the normal read-only validations succeed. Repair mode does not update container images, packages, storage, secrets, or image versions, and it never performs host-wide Docker cleanup.

## Image acquisition

Initial full setup acquires the pinned Compose image set after configuration is complete. Later image acquisition or refresh is always explicit:

```bash
sudo ./utilities/maintenance-update.sh --images
```

Ordinary startup and `startup.sh --repair` use only locally available pinned images. A missing image is a startup error and never triggers an implicit pull.

## Full setup preview

A full setup preview is read-only:

```bash
sudo ./setup.sh install \
  --domain vault.example.com \
  --email admin@example.com \
  --dry-run
```

The preview validates the public inputs and invokes setup phases only in their dry-run modes. It does not create the `vaultwarden` group, acquire the global or setup-specific operation lock, create operation-state files, change canonical lock metadata, execute secrets bootstrap state, or acquire images. Real setup still creates or validates the group before entering the existing operation guard.
