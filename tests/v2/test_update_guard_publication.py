from __future__ import annotations

import contextlib
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vaultwarden_oci import cli, install, recovery, update, update_appliance, update_versions


def digest(char: str) -> str:
    return "sha256:" + char * 64


def frozen() -> update_versions.FrozenVersions:
    return update_versions.FrozenVersions(
        "pinned",
        "amd64",
        "2.0.0",
        "1.40.0",
        "2.12.0",
        "v0.3.0",
        update_versions.ImagePin("vaultwarden", "vaultwarden/server", "1.40.0", digest("a")),
        update_versions.ImagePin("caddy_builder", "caddy", "2.12.0-builder-alpine", digest("b")),
        update_versions.ImagePin("caddy_runtime", "caddy", "2.12.0-alpine", digest("c")),
        caddy_cloudflare_ip="d" * 40,
        caddy_combine_ip_ranges="v0.0.2",
        caddy_ratelimit="v0.2.0",
    )


def command(argv, **_kwargs) -> cli.CommandResult:
    return cli.CommandResult(tuple(argv), "success", 0, "", "")


class GuardPublicationOrderingTests(unittest.TestCase):
    def test_guard_precedes_systemd_migration_and_candidate_pointer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            source = temp / "source"
            exact = temp / "exact"
            old = temp / "old"
            candidate = temp / "candidate"
            for path in (source, exact, old, candidate):
                path.mkdir()
            root = temp / "host"
            prepared = update_appliance.PreparedPlan(
                update.UpdatePlan(
                    source,
                    root,
                    Path("releases/1.0.0"),
                    "1.0.0",
                    "2.0.0",
                    frozen(),
                ),
                None,
                False,
            )
            artifact = temp / "pre.vwrec"
            artifact.write_bytes(b"guard-publication-regression")
            verified = recovery.VerifiedRecovery(
                artifact,
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
                artifact.stat().st_size,
                "2026-08-24T00:00:00Z",
            )
            events: list[str] = []

            @contextlib.contextmanager
            def exact_source(*_args, **_kwargs):
                yield exact

            guard_state = {
                "schema_version": 1,
                "recovery_required": True,
                "candidate_release": "2.0.0",
                "previous_release": "1.0.0",
                "recovery_artifact": str(artifact),
                "recovery_sha256": verified.sha256,
            }

            def record(_frozen, path: Path) -> None:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}\n", encoding="utf-8")

            with (
                mock.patch.object(install, "_frozen_source", exact_source),
                mock.patch.object(update, "_validate_source"),
                mock.patch.object(
                    update_appliance,
                    "_preflight",
                    return_value=mock.Mock(offline_recovery_recipient="age1" + "a" * 58),
                ),
                mock.patch.object(
                    update,
                    "_current",
                    return_value=(Path("releases/1.0.0"), "1.0.0", old),
                ),
                mock.patch.object(update, "_gate_current"),
                mock.patch.object(install, "ensure_lock_path", return_value=temp / "lock"),
                mock.patch.object(install, "stage_release", return_value=candidate),
                mock.patch.object(update, "_verify_coherent"),
                mock.patch.object(
                    update_appliance.update_guard,
                    "engage",
                    side_effect=lambda **_kwargs: events.append("guard"),
                ),
                mock.patch.object(
                    update_appliance.update_unit_migration,
                    "install_units",
                    side_effect=lambda *_args: events.append("units") or {},
                ),
                mock.patch.object(
                    update_appliance,
                    "_switch_current",
                    side_effect=lambda *_args: events.append("switch"),
                ),
                mock.patch.object(update, "_daemon_reload"),
                mock.patch.object(update, "_gate_activated"),
                mock.patch.object(update_appliance, "_start_update_timer"),
                mock.patch.object(update_appliance, "record_frozen", side_effect=record),
                mock.patch.object(update_appliance.update_guard, "load", return_value=guard_state),
                mock.patch.object(update_appliance.update_guard, "clear"),
            ):
                update_appliance.apply_prepared(
                    prepared,
                    runner=command,
                    activator=lambda *_args: events.append("activate"),
                    recovery_creator=lambda *_args, **_kwargs: verified,
                )

            self.assertLess(events.index("guard"), events.index("units"))
            self.assertLess(events.index("units"), events.index("switch"))
            self.assertLess(events.index("switch"), events.index("activate"))


if __name__ == "__main__":
    unittest.main()
