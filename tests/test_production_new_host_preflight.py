"""Pure, source-level checks for the safe fresh-VM P0 read model."""
import importlib.util
from pathlib import Path
import unittest
from tempfile import TemporaryDirectory
from unittest import mock

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


    def test_legacy_no_argument_recovery_entrypoint_is_preserved(self):
        self.assertTrue(module.valid_candidate_args('0.1.0-rc.12', None, 'recovery'))
        self.assertFalse(module.valid_candidate_args('0.1.0-rc.12', None, 'fresh-install'))

    def test_future_fresh_install_must_use_reviewed_version_and_full_sha(self):
        pinned = 'a' * 40
        self.assertTrue(module.valid_candidate_args('0.1.0-rc.13', pinned, 'fresh-install'))
        self.assertTrue(module.valid_candidate_args('0.1.0', pinned, 'fresh-install'))
        for version, sha, purpose in (
            ('0.1.0-rc.13', None, 'fresh-install'),
            ('0.1.0-rc.13', 'a' * 39, 'fresh-install'),
            ('0.1.0-rc.13', 'G' * 40, 'fresh-install'),
            ('latest', pinned, 'fresh-install'),
            ('0.1.0-rc.13;rm -rf /', pinned, 'fresh-install'),
            ('0.1.0-rc.13', pinned, 'install'),
            ('0.1.0-rc.13', None, 'recovery'),
        ):
            with self.subTest(version=version, purpose=purpose):
                self.assertFalse(module.valid_candidate_args(version, sha, purpose))
        self.assertTrue(module.release_matches('0.1.0-rc.13', '0.1.0-rc.13'))
        self.assertFalse(module.release_matches('0.1.0-rc.12', '0.1.0-rc.13'))
        self.assertFalse(module.release_matches([], '0.1.0-rc.13'))

    def test_current_release_manifest_needs_exact_reviewed_pin(self):
        # Release-neutral G0 contract: the installed candidate follows
        # versions.toml, not a stale rc.13 fixture or a floating ref.
        import tomllib
        with (source.parents[2] / 'versions.toml').open('rb') as stream:
            version = tomllib.load(stream)['vaultwarden_oci']['version']
        pin = 'f' * 40
        self.assertTrue(module.valid_candidate_args(version, pin, 'fresh-install'))
        self.assertTrue(module.release_matches(version, version))
        self.assertFalse(module.valid_candidate_args(version, None, 'fresh-install'))
        self.assertFalse(module.valid_candidate_args('latest', pin, 'fresh-install'))
        self.assertFalse(module.release_matches('0.1.0-rc.13', version))

    def test_source_pin_requires_clean_commit_and_refuses_symlink_git(self):
        pinned = 'b' * 40
        with TemporaryDirectory() as temp:
            root = Path(temp)
            (root / '.git').mkdir()
            with mock.patch.object(module, 'SOURCE', root), \
                    mock.patch.dict(module.os.environ, {'SUDO_USER': 'ubuntu'}):
                with mock.patch.object(module, 'read_command', side_effect=[
                        (0, pinned + '\n'), (0, '')]) as run:
                    self.assertTrue(module.reviewed_source_pin(pinned))
                    self.assertEqual(run.call_count, 2)
                    command_prefix = ['runuser', '-u', 'ubuntu', '--', 'git',
                                      '--no-optional-locks', '-C', str(root)]
                    self.assertEqual(run.call_args_list[0].args[0],
                                     [*command_prefix, 'rev-parse', 'HEAD'])
                    self.assertEqual(run.call_args_list[1].args[0],
                                     [*command_prefix, 'status', '--porcelain',
                                      '--untracked-files=all'])
                with mock.patch.object(module, 'read_command', side_effect=[
                        (0, pinned + '\n'), (0, '?? other\n')]):
                    self.assertFalse(module.reviewed_source_pin(pinned))
                with mock.patch.object(module, 'read_command', side_effect=[
                        (0, pinned + '\n'), (128, '')]):
                    self.assertFalse(module.reviewed_source_pin(pinned))
                with mock.patch.object(module, 'read_command', return_value=(0, 'c' * 40 + '\n')):
                    self.assertFalse(module.reviewed_source_pin(pinned))
                self.assertFalse(module.reviewed_source_pin('broken'))
                (root / '.git').rmdir()
                (root / '.git').symlink_to(root)
                self.assertFalse(module.reviewed_source_pin(pinned))

    def test_root_invocation_without_real_operator_refuses_git_checkout(self):
        pinned = 'c' * 40
        with mock.patch.object(module, 'read_command') as run:
            with mock.patch.dict(module.os.environ, {'SUDO_USER': 'root'}):
                self.assertFalse(module.reviewed_source_pin(pinned))
            with mock.patch.dict(module.os.environ, {'SUDO_USER': ''}):
                self.assertFalse(module.reviewed_source_pin(pinned))
            run.assert_not_called()

    def test_fresh_target_only_blank_signature_can_qualify(self):
        self.assertEqual(module.disk_classification('', False, set()), 'BLANK_REVIEW')
        self.assertNotEqual(module.disk_classification('ext4', False, {'ext4'}), 'BLANK_REVIEW')
        self.assertNotEqual(module.disk_classification('xfs', True, {'xfs'}), 'BLANK_REVIEW')
        self.assertNotEqual(module.disk_classification('', False, None), 'BLANK_REVIEW')

if __name__ == '__main__':
    unittest.main()
