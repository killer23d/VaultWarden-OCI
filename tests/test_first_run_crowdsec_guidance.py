from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from unittest import mock

from vaultwarden_oci import operator_output, setup_frontend


class FirstRunCrowdSecGuidanceTests(unittest.TestCase):
    def test_post_handoff_actions_put_crowdsec_setup_before_doctor(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(setup_frontend.sys.stdout, "isatty", return_value=False),
            redirect_stdout(output),
        ):
            setup_frontend._print_post_handoff_next_actions()

        rendered = output.getvalue()
        crowdsec = "ACTION run: sudo vwctl crowdsec setup, then follow its displayed remediation and Worker Route Fail Open steps"
        doctor = "ACTION run: sudo vwctl doctor"
        self.assertIn(crowdsec, rendered)
        self.assertIn(doctor, rendered)
        self.assertLess(rendered.index(crowdsec), rendered.index(doctor))

    def test_public_human_writer_adds_sudo_to_root_only_crowdsec_followups(self) -> None:
        output = io.StringIO()
        writer = operator_output.ColorizingWriter(output, enabled=False)

        writer.write("ACTION: run 'vwctl crowdsec remediation-start' to create one explicit Worker Route invocation\n")
        writer.write(
            "ACTION: set every bouncer-created Worker Route to Fail Open in Cloudflare, "
            "then run 'vwctl crowdsec confirm-fail-open'\n"
        )

        rendered = output.getvalue()
        self.assertIn("run 'sudo vwctl crowdsec remediation-start'", rendered)
        self.assertIn("then run 'sudo vwctl crowdsec confirm-fail-open'", rendered)
        self.assertNotIn("run 'vwctl crowdsec remediation-start'", rendered)
        self.assertNotIn("then run 'vwctl crowdsec confirm-fail-open'", rendered)


if __name__ == "__main__":
    unittest.main()
