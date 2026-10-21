import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('build_retention', ROOT / 'Scripts/build_retention.py')
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class BuildRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.packages = self.root / 'build/packages'
        self.reports = self.root / 'build/reports'
        self.packages.mkdir(parents=True)
        self.reports.mkdir()

    def package(self, number, awaiting=False):
        package = self.packages / f'LocalSeek-1.3.{number}-20261021-1200{number:02d}-fixture'
        (package / 'LocalSeek.app').mkdir(parents=True)
        (package / 'LocalSeek.app/model.gguf').write_bytes(b'model fixture')
        (package / 'DiskImage').mkdir()
        (package / 'DiskImage/model.gguf').write_bytes(b'duplicate fixture')
        for name in ('LocalSeek.zip', 'LocalSeek-notarized.zip'):
            (package / name).write_bytes(b'archive fixture')
        artifact = package / f'LocalSeek-1.3.{number}-arm64.dmg'
        artifact.write_bytes(b'image fixture')
        os.utime(artifact, (number * 1000, number * 1000))
        retention.record_package(self.root, package, awaiting_publication=awaiting)
        return package

    def bundle(self, number):
        bundle = self.reports / f'release-tests-{number:032x}.xcresult'
        bundle.mkdir()
        (bundle / 'fixture').write_bytes(b'test result')
        os.utime(bundle, (number * 1000, number * 1000))
        return bundle

    def test_keeps_two_packages_and_current_pointers_without_touching_caches(self):
        packages = [self.package(i) for i in range(1, 5)]
        # Both latest pointers remain valid even if a caller still references an older package.
        (self.root / 'build/latest-package.txt').write_text(str(packages[0] / 'LocalSeek.app'))
        (self.root / 'build/latest-artifact.txt').write_text(str(packages[-1] / 'LocalSeek-1.3.4-arm64.dmg'))
        for name in ('DerivedData', 'TestsDerivedData', 'SourcePackages', 'Dependencies', 'ci-model'):
            directory = self.root / 'build' / name
            directory.mkdir()
            (directory / 'keep').write_text('cache')
        output = self.root / 'build/LocalSeek.dmg'
        output.write_bytes(b'current downloadable artifact')
        retention.cleanup_packages(self.root, apply=True)
        self.assertTrue(packages[0].exists())
        self.assertFalse(packages[1].exists())
        for package in (packages[0], *packages[2:]):
            self.assertTrue((package / 'LocalSeek.app/model.gguf').exists())
            self.assertFalse((package / 'DiskImage').exists())
            self.assertFalse((package / 'LocalSeek.zip').exists())
            self.assertFalse((package / 'LocalSeek-notarized.zip').exists())
        self.assertEqual(output.read_bytes(), b'current downloadable artifact')
        for name in ('DerivedData', 'TestsDerivedData', 'SourcePackages', 'Dependencies', 'ci-model'):
            self.assertEqual((self.root / 'build' / name / 'keep').read_text(), 'cache')

    def test_pending_publication_retains_intermediates_until_the_workflow_finishes(self):
        package = self.package(1, awaiting=True)
        retention.cleanup_packages(self.root, apply=True)
        self.assertTrue((package / 'DiskImage').exists())
        self.assertTrue((package / 'LocalSeek.zip').exists())
        retention.record_package(self.root, package)
        retention.cleanup_packages(self.root, apply=True)
        self.assertFalse((package / 'DiskImage').exists())
        self.assertFalse((package / 'LocalSeek.zip').exists())
        self.assertEqual(retention.cleanup_packages(self.root, apply=True), [])

    def test_live_package_and_recent_failures_survive_but_abandoned_old_attempts_expire(self):
        now = time.time()
        active = self.package(1)
        (active / retention.ACTIVE).write_text(str(os.getpid()))
        recent = self.packages / 'LocalSeek-20261021-120000'
        recent.mkdir()
        stale = self.packages / 'LocalSeek-20261019-120000'
        stale.mkdir()
        (stale / retention.ACTIVE).write_text('not a pid')
        os.utime(stale, (now - 86401, now - 86401))
        self.package(2)
        self.package(3)
        retention.cleanup_packages(self.root, apply=True, now=now)
        self.assertTrue((active / 'DiskImage').exists())
        self.assertTrue(recent.exists())
        self.assertFalse(stale.exists())

    def test_only_three_reports_are_kept_with_receipt_and_live_test_exceptions(self):
        bundles = [self.bundle(i) for i in range(1, 7)]
        (self.reports / 'release-tests.json').write_text(json.dumps(dict(resultBundle=str(bundles[0]))))
        marker = self.reports / '.active-test-live.json'
        marker.write_text(json.dumps(dict(pid=os.getpid(), bundle=bundles[1].name)))
        stale = self.reports / '.active-test-stale.json'
        stale.write_text('invalid marker')
        summary = self.reports / 'test-summary.json'
        summary.write_text('keep summary')
        unrelated = self.reports / 'investigation.xcresult'
        unrelated.mkdir()
        retention.cleanup_reports(self.root, apply=True)
        self.assertTrue(bundles[0].exists())
        self.assertTrue(bundles[1].exists())
        self.assertFalse(bundles[2].exists())
        self.assertTrue(all(p.exists() for p in bundles[3:]))
        self.assertTrue(marker.exists())
        self.assertFalse(stale.exists())
        self.assertEqual(summary.read_text(), 'keep summary')
        self.assertTrue(unrelated.exists())

    def test_failed_test_context_keeps_recent_diagnostics_and_clears_its_live_marker(self):
        bundles = [self.bundle(i) for i in range(1, 5)]
        with self.assertRaisesRegex(RuntimeError, 'test failure'):
            with retention.active_test_bundle(self.root, bundles[-1]):
                marker = next(self.reports.glob('.active-test-*.json'))
                self.assertEqual(json.loads(marker.read_text())['bundle'], bundles[-1].name)
                raise RuntimeError('test failure')
        self.assertFalse(list(self.reports.glob('.active-test-*.json')))
        self.assertFalse(bundles[0].exists())
        self.assertTrue(all(p.exists() for p in bundles[1:]))

    def test_preview_does_not_delete_anything(self):
        packages = [self.package(i) for i in range(1, 4)]
        bundles = [self.bundle(i) for i in range(1, 5)]
        self.assertTrue(retention.cleanup_packages(self.root))
        self.assertTrue(retention.cleanup_reports(self.root))
        self.assertTrue(all(p.exists() for p in packages + bundles))
        self.assertTrue(all((p / 'DiskImage').exists() for p in packages))

    def test_symlink_targets_outside_artifacts_are_never_removed(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('important')
        linked = self.packages / 'LocalSeek-20261020-120000'
        linked.symlink_to(outside, target_is_directory=True)
        package = self.package(1)
        (package / 'DiskImage/external').symlink_to(outside, target_is_directory=True)
        (self.reports / ('release-tests-' + 'a' * 32 + '.xcresult')).symlink_to(outside, target_is_directory=True)
        retention.cleanup_packages(self.root, apply=True)
        retention.cleanup_reports(self.root, apply=True)
        self.assertEqual((outside / 'keep').read_text(), 'important')
        self.assertTrue(linked.is_symlink())
        self.assertFalse((package / 'DiskImage').exists())
        with self.assertRaises(ValueError):
            retention.record_package(self.root, linked)

    def test_refuses_symlinked_build_containers(self):
        other = self.root / 'other'
        (other / 'reports').mkdir(parents=True)
        alternate = self.root / 'alternate'
        alternate.mkdir()
        (alternate / 'build').symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            retention.cleanup_reports(alternate, apply=True)
        self.packages.rmdir()
        self.packages.symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            retention.cleanup_packages(self.root, apply=True)

    def test_legacy_archive_requires_matching_checksum_before_intermediate_cleanup(self):
        package = self.package(1)
        (package / retention.STATE).unlink()
        artifact = package / 'LocalSeek-1.3.1-arm64.dmg'
        checksum = artifact.with_suffix('.dmg.sha256')
        checksum.write_text('0' * 64 + '  ' + artifact.name + '\n')
        retention.cleanup_packages(self.root, apply=True)
        self.assertTrue((package / 'DiskImage').exists())
        checksum.write_text(hashlib.sha256(artifact.read_bytes()).hexdigest() + '  ' + artifact.name + '\n')
        retention.cleanup_packages(self.root, apply=True)
        self.assertFalse((package / 'DiskImage').exists())
        self.assertTrue(artifact.exists())


if __name__ == '__main__':
    unittest.main()
