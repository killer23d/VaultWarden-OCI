#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]


def rw(path, replacements=()):
    p = root / path
    text = p.read_text(encoding="utf-8")
    for old, new in replacements:
        text = text.replace(old, new)
    p.write_text(text, encoding="utf-8")

# Tests moved from tests/v2 to tests.
for p in (root / "tests").glob("*.py"):
    text = p.read_text(encoding="utf-8").replace(
        "Path(__file__).resolve().parents[2]", "Path(__file__).resolve().parents[1]"
    )
    p.write_text(text, encoding="utf-8")

# Retire tests that existed only for pre-release compatibility surfaces.
(root / "tests/test_install_phase6.py").unlink(missing_ok=True)
(root / "tests/test_phase8_surface.py").rename(root / "tests/test_release_surface.py")
(root / "tests/test_update_phase7.py").rename(root / "tests/test_update_workflow.py")

p = root / "tests/test_install.py"
text = p.read_text(encoding="utf-8")
text = re.sub(
    r"\n    def test_bootstrap_anchors_python_to_repository\(self\) -> None:.*?\n    def test_temp_root_install_layout_permissions_and_idempotency",
    "\n    def test_temp_root_install_layout_permissions_and_idempotency",
    text,
    flags=re.S,
)
text = text.replace("class Phase2InstallTests", "class InstallLayoutTests")
text = text.replace("systemd-v2", "systemd")
p.write_text(text, encoding="utf-8")

# Installed layout and systemd source path.
rw("vaultwarden_oci/install.py", [
    ('"""Phase 2+ host bootstrap and immutable installed-layout ownership."""', '"""Immutable installed-layout ownership for VaultWarden-OCI."""'),
    ('SYSTEMD_SOURCE_DIR = "systemd-v2"', 'SYSTEMD_SOURCE_DIR = "systemd"'),
    ('# VaultWarden-OCI V2 beta operator configuration.', '# VaultWarden-OCI operator configuration.'),
    ('required V2 systemd unit', 'required systemd unit'),
    ('Install the VaultWarden-OCI V2 immutable application layout', 'Install the VaultWarden-OCI immutable application layout'),
])

# Runtime identifier and user-facing labels.
for p in list((root / "vaultwarden_oci").glob("*.py")) + list((root / "tests").glob("*.py")):
    text = p.read_text(encoding="utf-8").replace("RuntimeErrorV2", "RuntimeOperationError")
    p.write_text(text, encoding="utf-8")

rw("vaultwarden_oci/runtime.py", [
    ('"""Vaultwarden + Caddy runtime rendering and lifecycle for V2."""', '"""Vaultwarden and Caddy runtime rendering and lifecycle."""'),
])
rw("vaultwarden_oci/cli.py", [
    ('"""VaultWarden-OCI V2 operator CLI and shared subprocess/lock primitives."""', '"""VaultWarden-OCI operator CLI and shared subprocess/lock primitives."""'),
    ('VaultWarden-OCI V2 operator CLI', 'VaultWarden-OCI operator CLI'),
    ('encrypted V2 recovery point', 'encrypted .vwrec recovery point'),
    ('supported CrowdSec beta path', 'supported CrowdSec path'),
    ('PASS: restored V2 recovery created', 'PASS: restored .vwrec recovery created'),
])
rw("vaultwarden_oci/notification.py", [
    ('Catalog-driven operational notification delivery for VaultWarden-OCI V2.', 'Catalog-driven operational notification delivery for VaultWarden-OCI.'),
    ('six V2 canonical providers', 'six canonical providers'),
    ('for V2 mail', 'for appliance mail'),
    ('VaultWarden-OCI/2', 'VaultWarden-OCI'),
])
rw("vaultwarden_oci/edge.py", [
    ('Cloudflare-only origin ingress and CrowdSec Cloudflare remediation for V2.', 'Cloudflare-only origin ingress and CrowdSec Cloudflare remediation.'),
    ('VaultWarden-OCI/2 cloudflare-edge-policy', 'VaultWarden-OCI cloudflare-edge-policy'),
    ('# Managed by VaultWarden-OCI V2 Phase 4.', '# Managed by VaultWarden-OCI.'),
    ('V2 requires Caddy-only acquisition', 'VaultWarden-OCI requires Caddy-only acquisition'),
])
rw("vaultwarden_oci/recovery.py", [
    ('VaultWarden-OCI V2 encrypted recovery and rclone publication owner.', 'Encrypted application recovery and rclone publication owner.'),
    ('restore supports the V2 recovery format only', 'restore supports .vwrec format version 2 only'),
])
rw("vaultwarden_oci/dashboard.py", [
    ('V1-inspired interactive presentation for the authoritative ``vwctl`` surface.', 'Interactive operations dashboard for the authoritative ``vwctl`` surface.'),
])
rw("vaultwarden_oci/update_versions.py", [
    ('"User-Agent": "vaultwarden-oci-v2"', '"User-Agent": "vaultwarden-oci"'),
])

# Neutralize systemd descriptions/comments without changing unit behavior.
for p in (root / "systemd").iterdir():
    if p.is_file():
        text = p.read_text(encoding="utf-8").replace("VaultWarden-OCI V2", "VaultWarden-OCI")
        p.write_text(text, encoding="utf-8")

# Current tests may still mention old source paths or stage names in fixtures.
for p in (root / "tests").glob("*.py"):
    text = p.read_text(encoding="utf-8").replace("systemd-v2", "systemd")
    text = text.replace("tests/v2", "tests")
    p.write_text(text, encoding="utf-8")

# Rename stage-labelled update fixture identifiers without changing tested versions.
p = root / "tests/test_update_workflow.py"
text = p.read_text(encoding="utf-8")
for old, new in {
    "PHASE6_VERSION": "BASELINE_VERSION",
    "PHASE7_VERSION": "CANDIDATE_VERSION",
    "phase6_versions_text": "baseline_versions_text",
    "phase6": "baseline_manifest",
    "Phase6": "Baseline",
    "Phase7": "Candidate",
}.items():
    text = text.replace(old, new)
p.write_text(text, encoding="utf-8")

# Remove this one-shot worker from the resulting tree.
(root / ".github/scripts/final-normalize.py").unlink()
(root / ".github/workflows/final-normalize.yml").unlink()
