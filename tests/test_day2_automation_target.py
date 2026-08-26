from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr
from unittest import mock

from vaultwarden_oci import day2, storage, update_cli


class AutomationTargetTests(unittest.TestCase):
    @staticmethod
    def properties(unit: str, *, target_enabled: str = "enabled") -> dict[str, object]:
        if unit == day2.AUTOMATION_TARGET:
            return {
                "unit": unit,
                "load_state": "loaded",
                "active_state": "active",
                "sub_state": "active",
                "result": "success",
                "enabled": target_enabled,
                "next": None,
                "last_trigger": None,
            }
        if unit.endswith(".timer"):
            # Timers are pulled in by vaultwarden-oci.target's Wants= list. Their
            # individual UnitFileState may therefore remain disabled while the
            # enabled target still owns persistent activation across boot.
            return {
                "unit": unit,
                "load_state": "loaded",
                "active_state": "active",
                "sub_state": "waiting",
                "result": "success",
                "enabled": "disabled",
                "next": "tomorrow",
                "last_trigger": "today",
            }
        return {
            "unit": unit,
            "load_state": "loaded",
            "active_state": "inactive",
            "sub_state": "dead",
            "result": "success",
            "enabled": "static",
            "next": None,
            "last_trigger": None,
        }

    def test_enabled_active_target_makes_active_wanted_timers_persistent(self) -> None:
        with mock.patch(
            "vaultwarden_oci.day2._systemd_properties",
            side_effect=lambda unit: self.properties(unit),
        ):
            snapshot = day2.automation_snapshot()
        self.assertEqual(snapshot["overall"], "PASS")
        self.assertEqual(snapshot["target"]["health"], "PASS")
        self.assertTrue(all(row["health"] == "PASS" for row in snapshot["timers"]))

    def test_disabled_target_is_not_green_even_if_timers_are_currently_active(self) -> None:
        with mock.patch(
            "vaultwarden_oci.day2._systemd_properties",
            side_effect=lambda unit: self.properties(unit, target_enabled="disabled"),
        ):
            snapshot = day2.automation_snapshot()
        self.assertEqual(snapshot["overall"], "FAIL")
        self.assertEqual(snapshot["target"]["health"], "FAIL")


class NotificationStorageGateTests(unittest.TestCase):
    def test_notification_tests_refuse_root_backed_state_when_mount_is_missing(self) -> None:
        with (
            mock.patch("vaultwarden_oci.update_cli.storage.verify", side_effect=storage.StorageError("missing mount")),
            mock.patch("vaultwarden_oci.update_cli.cli.main") as routed,
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(update_cli.main(["notification", "test"]), 1)
            self.assertEqual(update_cli.main(["notification", "test", "--smtp"]), 1)
        routed.assert_not_called()


if __name__ == "__main__":
    unittest.main()
