from __future__ import annotations

import os
from pathlib import Path

from vaultwarden_oci import cli, edge


TEST_DROPIN = Path(
    "/etc/systemd/system/crowdsec-firewall-bouncer.service.d/zz-vwoci-ci-block.conf"
)


def command(argv, label: str, *, env=None) -> None:
    result = cli.run_command(argv, env=env)
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip() or result.kind
        raise RuntimeError(f"{label} failed: {detail}")


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("real CrowdSec package acceptance must run as root")
    if edge.POLICY_RC_D.exists():
        raise RuntimeError(
            f"refusing to overwrite existing host package policy {edge.POLICY_RC_D}"
        )

    # The real Debian postinst directly calls systemctl enable/start.  Block
    # execution only in this CI fixture so the test can exercise those real
    # maintainer scripts without applying packet-filter rules to the runner.
    TEST_DROPIN.parent.mkdir(parents=True, exist_ok=True)
    TEST_DROPIN.write_text(
        "[Service]\nExecCondition=\nExecCondition=/bin/false\n",
        encoding="utf-8",
    )
    os.chmod(TEST_DROPIN, 0o644)
    command(["systemctl", "daemon-reload"], "test containment daemon-reload")

    try:
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

        install_env = dict(os.environ)
        install_env["DEBIAN_FRONTEND"] = "noninteractive"
        install_env["CROWDSEC_SETUP_UNATTENDED_DISABLE"] = "1"
        with edge._suppress_package_service_starts(edge.POLICY_RC_D):
            command(
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

        base = edge.FIREWALL_BOUNCER_CONFIG.read_text(encoding="utf-8")
        if "nftables_hooks:" not in base or "forward" not in base.lower():
            raise RuntimeError(
                "installed upstream firewall-bouncer fixture no longer exposes the expected default forward hook; re-audit package semantics"
            )

        hooks = edge._effective_firewall_hooks(edge.EdgePaths(), cli.run_command)
        if hooks != ("input",):
            raise RuntimeError(f"pre-install safety override did not win merged config: hooks={hooks!r}")

        enabled = cli.run_command(
            ["systemctl", "is-enabled", "--quiet", edge.FIREWALL_BOUNCER_SERVICE]
        )
        if not enabled.ok:
            raise RuntimeError(
                "real package postinst did not leave firewall bouncer enabled; fixture no longer proves direct-enable containment"
            )

        containment = edge._contain_package_bouncers(cli.run_command)
        if containment:
            raise RuntimeError("package bouncer containment failed: " + "; ".join(containment))
        if cli.run_command(
            ["systemctl", "is-enabled", "--quiet", edge.FIREWALL_BOUNCER_SERVICE]
        ).ok:
            raise RuntimeError("firewall bouncer remained boot-enabled after containment")
        if cli.run_command(
            ["systemctl", "is-active", "--quiet", edge.FIREWALL_BOUNCER_SERVICE]
        ).ok:
            raise RuntimeError("firewall bouncer remained active after containment")
    finally:
        # Never leave the test-only start blocker behind, but keep the real
        # package disabled before removing it.
        edge._contain_package_bouncers(cli.run_command)
        TEST_DROPIN.unlink(missing_ok=True)
        cli.run_command(["systemctl", "daemon-reload"])

    if edge.POLICY_RC_D.exists():
        raise RuntimeError("temporary package policy was not removed")
    print(
        "PASS: real firewall-bouncer maintainer scripts saw a pre-existing INPUT-only override and package enable/start was contained"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
