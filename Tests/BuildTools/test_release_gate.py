import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_tests', ROOT / 'Scripts/release-tests.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseGateTests(unittest.TestCase):
    def test_packaging_stops_at_failed_tests_before_apple_uploads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'Scripts'
            scripts.mkdir()
            for name in ('package.sh', 'local-build-config.sh'):
                shutil.copyfile(ROOT / 'Scripts' / name, scripts / name)
            (scripts / 'test-release.sh').write_text('touch gate-ran\nexit 42\n')
            tools = root / 'bin'
            tools.mkdir()
            # A direct packaging entry point must stop before signing or notarytool.
            for name in ('codesign', 'xcrun'):
                tool = tools / name
                tool.write_text('#!/bin/sh\ntouch upload-attempted\nexit 1\n')
                tool.chmod(0o700)
            result = subprocess.run(['bash', str(scripts / 'package.sh'), '--skip-build'], cwd=root,
                env={'PATH': str(tools) + os.pathsep + os.environ['PATH']}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
            self.assertTrue((root / 'gate-ran').exists())
            self.assertFalse((root / 'upload-attempted').exists())

    def test_changed_sources_system_or_expired_results_cannot_authorize_uploads(self):
        original = dict(commit='a' * 40, sourceSHA256='b' * 64, macOS='27.0.1', xcode='Xcode 27')
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / 'receipt.json'
            good = dict(inputs=original, completedAt=time.time(), passedTests=129,
                        failedTests=0, skippedTests=0, toolTests=11)
            receipt.write_text(json.dumps(good))
            with patch.object(gate, 'RECEIPT', receipt), patch.object(gate, 'inputs', return_value=original):
                self.assertEqual(gate.verify()['passedTests'], 129)
                for field in original:
                    with self.subTest(field=field), patch.object(gate, 'inputs',
                            return_value=original | {field: 'changed'}):
                        with self.assertRaises(RuntimeError):
                            gate.verify()
                for change in ({'completedAt': time.time() - 86401}, {'completedAt': time.time() + 60},
                               {'failedTests': 1}, {'skippedTests': 1}, {'passedTests': 0}, {'toolTests': 0}):
                    with self.subTest(change=change):
                        receipt.write_text(json.dumps(good | change))
                        with self.assertRaises(RuntimeError):
                            gate.verify()

    def test_failed_rerun_revokes_previous_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            receipt = reports / 'receipt.json'
            receipt.write_text('{"previous": "success"}')
            with patch.object(gate, 'REPORTS', reports), patch.object(gate, 'RECEIPT', receipt), \
                    patch.object(gate, 'inputs', return_value={}), \
                    patch.object(gate, 'logged', side_effect=RuntimeError('regression failed')):
                with self.assertRaisesRegex(RuntimeError, 'regression failed'):
                    gate.run_tests()
            self.assertFalse(receipt.exists(), 'A failed rerun must invalidate the earlier release permission')

    def test_only_a_complete_successful_test_run_is_accepted(self):
        good = dict(result='Passed', totalTestCount=129, passedTests=129,
                    failedTests=0, skippedTests=0, expectedFailures=0)
        self.assertEqual(gate.passed_swift_tests(good), 129)
        for change in ({'result': 'Failed'}, {'totalTestCount': 0, 'passedTests': 0},
                       {'passedTests': 128, 'failedTests': 1}, {'passedTests': 128, 'skippedTests': 1},
                       {'expectedFailures': 1}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                gate.passed_swift_tests(good | change)
        for field in good:
            incomplete = good.copy()
            del incomplete[field]
            with self.subTest(missing=field), self.assertRaises(RuntimeError):
                gate.passed_swift_tests(incomplete)


if __name__ == '__main__':
    unittest.main()
