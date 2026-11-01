"""Pure, source-level checks for the safe fresh-VM P0 read model."""
import importlib.util
from pathlib import Path
import unittest

source = Path(__file__).parent / 'host-acceptance' / 'production-new-host-preflight.py'
spec = importlib.util.spec_from_file_location('production_newhost_p0', source)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FreshHostP0Tests(unittest.TestCase):
    def test_only_blank_unmounted_candidate_can_be_classified_blank(self):
        self.assertEqual(module.disk_classification('', False, set()), 'BLANK_REVIEW')
        self.assertEqual(module.disk_classification('', True, set()), 'MOUNTED_REVIEW')
        self.assertEqual(module.disk_classification('ext4', False, {'ext4'}), 'EXISTING_FS_REVIEW')

    def test_existing_data_requires_review(self):
        self.assertEqual(module.disk_classification('ext4', False, {'ext4', 'gpt'}),
                         'UNKNOWN_SIGNATURES_REVIEW')
        self.assertEqual(module.disk_classification('xfs', False, {'xfs', 'LVM2_member'}),
                         'UNKNOWN_SIGNATURES_REVIEW')
        self.assertEqual(module.disk_classification('vfat', False, {'vfat'}),
                         'UNKNOWN_SIGNATURES_REVIEW')

    def test_unavailable_signature_probe_never_infers_blank(self):
        self.assertEqual(module.disk_classification('', False, None), 'UNPROVEN_SIGNATURES')
        self.assertEqual(module.disk_classification('ext4', False, None), 'UNPROVEN_SIGNATURES')

    def test_readonly_command_failure_is_reported_not_retried(self):
        self.assertEqual(module.read_command(['/no/such/command']), (None, ''))


if __name__ == '__main__':
    unittest.main()
