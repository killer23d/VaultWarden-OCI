from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from vaultwarden_oci import cli, edge


FIREWALL_POSTINST = Path("/var/lib/dpkg/info/crowdsec-firewall-bouncer-nftables.postinst")
CROWDSEC_POSTINST = Path("/var/lib/dpkg/info/crowdsec.postinst")


def command(argv, label: str, *, env=None) -> None:
    result = cli.run_command(argv, env=env)
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip() or result.kind
        raise RuntimeError(f"{label} failed: {detail}")


def active(service: str) -> bool:
    return cli.run_command(["systemctl", "is-active", "--quiet", service]).ok


def enabled(service: str) -> bool:
    return cli.run_command(["systemctl", "is-enabled", "--quiet", service]).ok


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("real CrowdSec package acceptance must run as root")
    if edge.POLICY_RC_D.exists():
        raise RuntimeError(
            f"refusing to overwrite existing host package policy {edge.POLICY_RC_D}"
        )

    edge._write_root_file(
        edge.FIREWALL_BOUNCER_LOCAL,
        edge.firewall_bouncer_bootstrap_local_text(),
        0o600,
    )

    installer = edge._download_installer()
    try:
        command(["/bin/sh", str(installer)], "CrowdSec repository setup")
    finally:
        installer.unlink(missing_ok=True)
    command(["apt-get", "update"], "apt metadata refresh")

    install_env = edge._package_install_env()
    if install_env.get("SYSTEMD_OFFLINE") != "1":
        raise RuntimeError("production package environment did not enable SYSTEMD_OFFLINE")

    try:
        with edge._suppress_package_service_starts(edge.POLICY_RC_D):
            edge._apt_command(
                cli.run_command,
                [
                    "apt-get",
                    "install",
                    "-y",
                    "crowdsec",
                    "crowdsec-firewall-bouncer-nftables",
                ],
                "real CrowdSec firewall package installation",
                env=install_env,
            )

        firewall_postinst = FIREWALL_POSTINST.read_text(encoding="utf-8")
        if "systemctl enable" not in firewall_postinst or "systemctl start" not in firewall_postinst:
            raise RuntimeError(
                "installed firewall-bouncer postinst no longer directly enables/starts systemd; re-audit package containment"
            )
        crowdsec_postinst = CROWDSEC_POSTINST.read_text(encoding="utf-8")
        if "systemctl" not in crowdsec_postinst or "start" not in crowdsec_postinst:
            raise RuntimeError(
                "installed CrowdSec postinst no longer contains direct systemd startup behavior; re-audit package containment"
            )

        base = edge.FIREWALL_BOUNCER_CONFIG.read_text(encoding="utf-8")
        if "nftables_hooks:" not in base or "forward" not in base.lower():
            raise RuntimeError(
                "installed upstream firewall-bouncer fixture no longer exposes the expected default forward hook; re-audit package semantics"
            )

        hooks = edge._effective_firewall_hooks(edge.EdgePaths(), cli.run_command)
        if hooks != ("input",):
            raise RuntimeError(f"pre-install safety override did not win merged config: hooks={hooks!r}")

        # The real package scripts attempted their systemctl operations, but the
        # apt child was offline to PID 1. Neither the engine nor firewall bouncer
        # may have become active before the project has written acquisition and
        # final firewall configuration.
        for service in (edge.CROWDSEC_SERVICE, edge.FIREWALL_BOUNCER_SERVICE):
            if active(service):
                raise RuntimeError(
                    f"{service} became active during the SYSTEMD_OFFLINE package transaction"
                )

        # Package scripts may still create enablement symlinks. Production must
        # reconcile those immediately before project-owned configuration starts.
        containment = edge._contain_package_bouncers(cli.run_command)
        if containment:
            raise RuntimeError("package service containment failed: " + "; ".join(containment))
        for service in (edge.CROWDSEC_SERVICE, edge.FIREWALL_BOUNCER_SERVICE):
            if active(service):
                raise RuntimeError(f"{service} remained active after package containment")
            if enabled(service):
                raise RuntimeError(f"{service} remained boot-enabled after package containment")
    finally:
        edge._contain_package_bouncers(cli.run_command)

    if edge.POLICY_RC_D.exists():
        raise RuntimeError("temporary package policy was not removed")
    print(
        "PASS: real CrowdSec/firewall maintainer scripts ran with SYSTEMD_OFFLINE, the pre-apt INPUT-only override won, and post-apt containment left services inactive/disabled"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
