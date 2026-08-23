"""Small registration owner for the check-only update scheduler units."""
from __future__ import annotations

from . import install

UNITS = (
    "vaultwarden-oci-update-check.service",
    "vaultwarden-oci-update-check.timer",
)


def register() -> None:
    """Include the check-only scheduler in immutable installer/update ownership."""
    missing = tuple(unit for unit in UNITS if unit not in install.SYSTEMD_UNITS)
    if missing:
        install.SYSTEMD_UNITS = (*install.SYSTEMD_UNITS, *missing)
